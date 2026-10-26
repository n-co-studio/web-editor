#!/usr/bin/env bash
# Shared analytics capture — sourced by all hooks.
# Writes one NDJSON event per hook invocation to ~/.local/share/repo-os-analytics/<repo>/events/<date>.ndjson.
# All writes are fail-silent (|| true) — analytics never blocks enforcement.
#
# Usage (in hook scripts):
#   REPO_ROOT="$(get_repo_root)"
#   START_MS=$(now_ms)
#   ... hook logic ...
#   log_hook_event "hook-name" "PreToolUse" "Edit" "allow" "$START_MS" "reason_code"
#
# ## Consumers (auto-generated — run .claude/tools/hook-dep-map.sh for live data)
#   Hooks: agent-git-guard, bash-guard, hvst-failure-tracker,
#          permission-request, plan-approval, pre-commit-gates, pre-push-gates,
#          pretooluse-permission (unconditional), session-close-check,
#          state-writer, write-guard
#   Automation: runner.sh, queue-cli.sh, intake.sh

# --- Portable millisecond timestamp ---
# GNU date supports %N (nanoseconds); macOS date does not — it outputs literal "N".
# Detect platform once at source-time to avoid repeated probe overhead.
case "${OSTYPE:-}" in
  darwin*)  _REPO_OS_HAS_GNU_DATE=false ;;
  linux*)   _REPO_OS_HAS_GNU_DATE=true ;;
  *)
    # Unknown platform: probe once at source time
    if [[ "$(date +%s%3N 2>/dev/null)" =~ ^[0-9]+$ ]]; then
      _REPO_OS_HAS_GNU_DATE=true
    else
      _REPO_OS_HAS_GNU_DATE=false
    fi
    ;;
esac

# --- jq availability (probed once at source-time) ---
# Security-critical hooks (agent-git-guard, bash-guard, write-guard) fail-closed
# when jq is absent. Analytics and HVST tracking degrade gracefully.
_REPO_OS_HAS_JQ=false
command -v jq &>/dev/null && _REPO_OS_HAS_JQ=true

# --- Hash command availability (probed once at source-time) ---
# Eliminates per-call command probing in portable_hash().
_REPO_OS_HASH_CMD=""
if command -v shasum &>/dev/null; then
  _REPO_OS_HASH_CMD="shasum"
elif command -v sha256sum &>/dev/null; then
  _REPO_OS_HASH_CMD="sha256sum"
else
  _REPO_OS_HASH_CMD="openssl"
fi

now_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    # Bash 5+: zero-fork millisecond timestamp
    local sec="${EPOCHREALTIME%%.*}"
    local frac="${EPOCHREALTIME#*.}"
    frac="${frac}000"
    echo "${sec}${frac:0:3}"
  elif [ "$_REPO_OS_HAS_GNU_DATE" = true ]; then
    date +%s%3N
  else
    echo $(( $(date +%s) * 1000 ))
  fi
}

# --- Portable SHA-256 (stdin-based) ---
# Uses cached _REPO_OS_HASH_CMD (probed at source-time). Reads stdin, outputs hex digest.
portable_hash() {
  case "$_REPO_OS_HASH_CMD" in
    shasum)    shasum -a 256 | awk '{print $1}' ;;
    sha256sum) sha256sum | awk '{print $1}' ;;
    *)         openssl sha256 | awk '{print $NF}' ;;
  esac
}

# --- Repo root (derived from this file's location — eliminates CWD dependency) ---
# _analytics-helper.sh lives at .claude/hooks/ — repo root is always two levels up.
# Eliminates: CWD dependency, stale PID-based /tmp/ cache.
# Test seam: _REPO_OS_TEST_ROOT overrides repo root, but ONLY when
# REPO_OS_TEST_MODE=1 is also set (dual guard prevents accidental env leaks).
# Path prefix guard: _REPO_OS_TEST_ROOT must start with /tmp/ or /private/tmp/
# to bound the redirect surface to temp directories only.
#
# WORKTREE BEHAVIOR (empirically established 2026-08-07 — Decision 0028 correction):
# Decision 0028 claimed "_REPO_OS_ROOT always resolves to the main repo" because
# "hooks are registered by absolute path in settings.json". This is INCORRECT.
# settings.json uses RELATIVE paths (.claude/hooks/...). Claude Code resolves
# them relative to the launch directory (CWD). In full worktree sessions the runner
# does `(cd "$worktree_dir" && claude -p ...)`, so CWD = worktree. Therefore:
#   • BASH_SOURCE[0] = relative path → resolved against worktree CWD
#   • _REPO_OS_ROOT = WORKTREE root (not the main repo root)
# The runner, which sources hooks via absolute path ($REPO_ROOT/.claude/hooks/...),
# resolves _REPO_OS_ROOT to the MAIN REPO root. This creates a two-root divergence:
#   • Runner writes governance state to: main_repo/.claude/.state/wt-sessions/{sid}/
#   • Agent hooks read/write to:         worktree/.claude/.state/wt-sessions/{sid}/
# These are DIFFERENT directories. The runner also writes plan-approved and registers
# the session under the main-repo path, which agent hooks cannot see.
#
# Mitigations implemented (2026-08-07):
#   1. runner.sh state_manager_setup: write state to the WORKTREE path by passing
#      the worktree dir as REPO_ROOT when calling init_phase helpers.
#   2. get_main_repo_root(): resolves to the main repo via git-common-dir regardless
#      of whether we are in the worktree or the main repo.
#   3. _handoff_bundle_path() uses get_main_repo_root() so bundles written by
#      Prompt T (in main repo context) are visible to Prompt B (in worktree context).
#   4. Escalation writes in headless sessions use the main repo path so the daemon
#      (which runs in the main repo) sees them.
if [ "${REPO_OS_TEST_MODE:-0}" = "1" ] && [ -n "${_REPO_OS_TEST_ROOT:-}" ]; then
  case "$_REPO_OS_TEST_ROOT" in
    /tmp/*|/private/tmp/*)
      _REPO_OS_ROOT="$_REPO_OS_TEST_ROOT"
      ;;
    *)
      echo "WARNING: _REPO_OS_TEST_ROOT rejected — must start with /tmp/ or /private/tmp/ (got: $_REPO_OS_TEST_ROOT)" >&2
      _REPO_OS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
      ;;
  esac
else
  _REPO_OS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

get_repo_root() {
  echo "$_REPO_OS_ROOT"
}

# --- Main repo root (always the primary worktree, even from a worktree session) ---
# In a worktree, git rev-parse --git-common-dir returns an absolute path to the
# main repo's .git/ directory (e.g. /path/to/main/.git). In the main repo it
# returns ".git" (relative). dirname of the absolute path gives the main repo root.
# Falls back to _REPO_OS_ROOT (safe no-op when already in the main repo or in
# test mode where git is mocked). Used for cross-session shared paths that are
# written by the runner in the main-repo context and must be visible from within
# worktree sessions (handoff-bundles, escalations, daemon queue).
_CACHED_MAIN_REPO_ROOT=""
get_main_repo_root() {
  if [ -n "$_CACHED_MAIN_REPO_ROOT" ]; then
    echo "$_CACHED_MAIN_REPO_ROOT"
    return
  fi
  local common_dir gitdir
  common_dir=$(git rev-parse --git-common-dir 2>/dev/null || true)
  gitdir=$(git rev-parse --git-dir 2>/dev/null || true)
  if [ -n "$common_dir" ] && [ -n "$gitdir" ] \
     && [ "$common_dir" != "$gitdir" ] \
     && [ "${common_dir:0:1}" = "/" ]; then
    # In a worktree: common_dir is absolute path to main repo's .git/
    _CACHED_MAIN_REPO_ROOT="$(dirname "$common_dir")"
    # Test seam (known-issue R41): this answer comes from the CWD, not from
    # _REPO_OS_ROOT, so a suite run from inside a worktree of the REAL repo — the
    # way agent and reverify sessions run — would route the registry, handoff
    # bundles and control dir to the real main while every other path is
    # sandboxed. When the seam is active and the CWD's repo is outside the
    # seam's own /tmp prefix rule, it is not a test repo: stay in the sandbox.
    # Test worktrees live under /tmp, so they still resolve as worktrees.
    if [ "${REPO_OS_TEST_MODE:-0}" = "1" ] && [ "$_REPO_OS_ROOT" = "${_REPO_OS_TEST_ROOT:-}" ]; then
      case "$_CACHED_MAIN_REPO_ROOT" in
        /tmp/*|/private/tmp/*) ;;
        *) _CACHED_MAIN_REPO_ROOT="$_REPO_OS_ROOT" ;;
      esac
    fi
  else
    # In the main repo (or test mode): _REPO_OS_ROOT is already correct
    _CACHED_MAIN_REPO_ROOT="$_REPO_OS_ROOT"
  fi
  echo "$_CACHED_MAIN_REPO_ROOT"
}

# --- Worktree detection (Decision 0028) ---
# Returns 0 if the current process is running inside a git worktree.
# Uses git rev-parse --git-common-dir vs --git-dir (available since git 2.5).
# NOTE: This detects whether the CWD is in a worktree, not whether the hook
# file is in a worktree. Hooks always live in the main repo. When a worktree
# subagent fires a hook, its CWD is the worktree path.
_CACHED_IS_WORKTREE=""
is_worktree() {
  if [ -z "$_CACHED_IS_WORKTREE" ]; then
    local git_dir common_dir
    git_dir=$(git rev-parse --git-dir 2>/dev/null || echo "")
    common_dir=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
    # Resolve both to absolute physical paths before comparing. git returns
    # these in DIFFERENT formats depending on cwd: from a subdirectory
    # --git-dir is absolute (/repo/.git) while --git-common-dir stays relative
    # (../../.git). Comparing the raw strings therefore reported "worktree" for
    # an ordinary repo whenever a hook ran with cwd below the root — which
    # routed session state to .claude/.state/wt-sessions/ instead of sessions/.
    # (--path-format=absolute would do this in one call but needs git 2.31+,
    # above the supported floor — see AI.md § Tooling Floor — so resolve by
    # cd'ing instead.)
    if [ -n "$git_dir" ]; then
      git_dir=$(cd "$git_dir" 2>/dev/null && pwd -P) || git_dir=""
    fi
    if [ -n "$common_dir" ]; then
      common_dir=$(cd "$common_dir" 2>/dev/null && pwd -P) || common_dir=""
    fi
    if [ -n "$git_dir" ] && [ -n "$common_dir" ] && [ "$git_dir" != "$common_dir" ]; then
      _CACHED_IS_WORKTREE="true"
    else
      _CACHED_IS_WORKTREE="false"
    fi
  fi
  [ "$_CACHED_IS_WORKTREE" = "true" ]
}

# --- Full worktree session detection (Decision 0030, amended 2026-08-31) ---
# Returns 0 if the current process is a full worktree session with an
# independent governance lifecycle. Distinguishes from subagent worktrees
# (isolation: "worktree") which also have is_worktree()=true but no
# independent session — they are spawned into fresh worktrees and never
# call init_phase, so no phase-state file exists in their resolved state dir.
#
# Two signals (either suffices):
#   1. REPO_OS_SESSION_ID env var — set by `claude --worktree` launcher.
#      Preserved as primary/override for backward compatibility.
#   2. phase-state file present in resolved state dir — written by init_phase
#      at session start. A subagent worktree never calls init_phase, so no
#      phase-state exists in its _REPO_OS_ROOT-rooted state dir.
#      Covers sessions launched via EnterWorktree (harness tool) that do not
#      inject REPO_OS_SESSION_ID. See Decision 0030 Amendment 2026-08-31.
is_full_worktree_session() {
  is_worktree || return 1
  # Signal 1: REPO_OS_SESSION_ID (canonical override — claude --worktree)
  [ -n "${REPO_OS_SESSION_ID:-}" ] && return 0
  # Signal 2: phase-state exists in resolved state dir (written by init_phase).
  # get_session_state_dir() routes to _REPO_OS_ROOT/.claude/.state/wt-sessions/{sid}/
  # For EnterWorktree sessions: _REPO_OS_ROOT = worktree root, init_phase creates
  # the phase-state here. For subagent worktrees: no init_phase has run in the
  # fresh worktree, so the dir/file does not exist — correctly returns false.
  # get_session_state_dir always returns 0 (returns a path even when the dir is
  # absent — the caller handles that via the [ -f ... ] check below). The || return 1
  # guard is a forward-compatible safety net for if get_session_state_dir gains a
  # failure path in future. Stderr suppressed to keep state-writer.sh non-blocking.
  local _fws_state_dir
  _fws_state_dir=$(get_session_state_dir 2>/dev/null) || return 1
  [ -f "${_fws_state_dir}/phase-state" ]
}

# --- Portable path normalization (macOS-safe) ---
# Collapses .., ., and duplicate slashes without resolving symlinks.
# Fast-path: if no special components, return as-is (zero forks).
# Fallback: python3 os.path.normpath for edge cases (.., ., //).
# NOTE: python3 is recommended for reliable path normalization. Without it,
# paths containing .. components pass through un-normalized, which may weaken
# is_in_repo() boundary checks (a path like /repo/../outside/file would not
# be collapsed and could pass the prefix check incorrectly).
normalize_path() {
  local raw="$1"
  case "$raw" in
    */./*|*/../*|*//*|./*|../*)
      # Has components needing normalization — fall back to Python
      if command -v python3 &>/dev/null; then
        python3 -c "import os.path,sys; print(os.path.normpath(sys.argv[1]))" "$raw" 2>/dev/null || echo "$raw"
      else
        # Output raw path so callers under set -e get usable output,
        # but return 1 and emit warning so fail-closed callers can detect degradation
        echo "$raw"
        echo "GATE-FINAL: normalize_path requires python3 for paths with .. or . components — python3 not found. Path normalization skipped (fail-closed)." >&2
        return 1
      fi
      ;;
    *)
      # Common case: clean path, return as-is
      echo "$raw"
      ;;
  esac
}

# --- Resolve path to absolute (no symlink resolution) ---
# Converts relative paths to absolute using $PWD. Fast-path for absolute
# paths (zero forks). Falls back to normalize_path for relative paths or
# paths with special components.
resolve_path() {
  local raw="$1"
  local result
  if [[ "$raw" == /* ]]; then
    # Absolute — normalize only if it has special components
    result=$(normalize_path "$raw") || result="$raw"
  else
    # Relative — prepend PWD then normalize
    result=$(normalize_path "$PWD/$raw") || result="$PWD/$raw"
  fi
  echo "$result"
}

# --- Check if a resolved absolute path is within the repo tree ---
# Returns 0 if the path is under REPO_ROOT, 1 otherwise.
is_in_repo() {
  local abs_path="$1"
  local repo_root="${2:-$(get_repo_root)}"
  local root_prefix="${repo_root}/"
  if [[ "$abs_path" == "$root_prefix"* || "$abs_path" == "$repo_root" ]]; then
    return 0
  fi
  return 1
}

# --- Write-detection pre-filter ---
# Returns 0 (true) if the raw input string may contain write targets; 1 otherwise.
# Tests for the three token classes that extract_write_targets() acts on:
#   "file_path" — Edit/Write tool JSON field
#   >           — shell redirect (including >>)
#   tee         — tee pipe (tee or tee -a)
#
# SYNC INVARIANT: This pre-filter and extract_write_targets() below share
# responsibility for the same write-detection surface. Widening the extractor
# without updating this pre-filter means commands containing the new pattern
# never reach the extractor — a silent no-op. Update both together.
#
# bash-guard.sh carries a pre-source inline copy of this function
# (_bg_is_write_candidate, defined before library sourcing). Update that copy
# whenever changing these tokens or the logic below.
#
# Known non-goal: the detected set is deliberately narrow (Decision t-0012 §9,
# known-issues.md R2). Do not widen this pre-filter without a corresponding
# widening of extract_write_targets().
_is_bash_write_candidate() {
  local input="$1"
  [[ "$input" == *'"file_path"'* ]] || [[ "$input" == *'>'* ]] || [[ "$input" == *'tee '* ]]
}

# --- Extract write targets from a Bash command string ---
# Parses redirect (>, >>), file-descriptor redirects ([0-9]>, [0-9]>>), tee,
# and cp/mv destination (last positional token via awk '{print $NF}') from a command.
# Applies filter set: skip /dev/*, skip tokens with < > =, skip tokens without / or .
# Outputs one path per line. Callers handle resolve_path/is_in_repo.
#
# Known limitations (residual gaps — not detectable via regex):
#   - Here-documents (<<EOF ... EOF)
#   - Process substitution (>(cmd), <(cmd))
#   - Multi-source cp: cp -r a b dest/ — only the destination (last token) is captured
#   - curl -o, install, python -c open() — not detected
extract_write_targets() {
  local cmd="$1"
  local redir tee_targets cp_mv_dest
  # Match [N]> and [N]>> redirects (standard + file-descriptor)
  redir=$(echo "$cmd" | grep -oE '[0-9]?[>]{1,2}\s*[^ |;&]+' | sed 's/^[0-9]//' | sed 's/[>]*//' | sed 's/^[[:space:]]*//' || true)
  tee_targets=$(echo "$cmd" | grep -oE 'tee\s+(-a\s+)?[^ |;&]+' | sed 's/tee\s*//' | sed 's/-a\s*//' || true)
  # cp/mv destination: last positional token of any cp or mv segment
  cp_mv_dest=$(echo "$cmd" | grep -oE '(^|[;&|] *)(cp|mv) [^;&|]+' | awk '{print $NF}' || true)
  local wt
  while IFS= read -r wt; do
    [ -z "$wt" ] && continue
    [[ "$wt" == /dev/* ]] && continue
    [[ "$wt" == *"<"* || "$wt" == *">"* || "$wt" == *"="* ]] && continue
    [[ "$wt" != *"/"* && "$wt" != *"."* ]] && continue
    echo "$wt"
  done < <(printf '%s\n%s\n%s\n' "$redir" "$tee_targets" "$cp_mv_dest")
}

# --- Centralized analytics directory for this repo ---
# All repos write to ~/.local/share/repo-os-analytics/<repo-name>/events/.
# Repo name derived from basename (same convention as register_repo).
get_analytics_dir() {
  local repo_root="${1:-$_REPO_OS_ROOT}"
  local repo_name
  repo_name="$(basename "$repo_root")"
  echo "$HOME/.local/share/repo-os-analytics/$repo_name/events"
}

# --- Durable per-process id (per-process session identity) ---
# The long-lived `claude` process that spawns each hook subprocess is identified
# by $PPID: stable across a window's turns (so identity survives context-window
# turnover) and distinct per concurrent window (so two windows don't alias). We
# key interactive identity on it via per-process sidecar files (.session-id.<dpid>)
# rather than the single shared .session-id, which collapses concurrent processes.
# Tests inject _REPO_OS_DURABLE_PID because the hook test harness runs hooks in a
# subshell pipeline, giving them an ephemeral, unpredictable $PPID (see L4.9c).
# Fall back to $$ when $PPID is 0/1/unavailable (mirrors register_session).
_resolve_durable_pid() {
  if [ -n "${_REPO_OS_DURABLE_PID:-}" ]; then
    echo "$_REPO_OS_DURABLE_PID"
    return
  fi
  local p="${PPID:-0}"
  if [ "$p" -le 1 ] 2>/dev/null || ! kill -0 "$p" 2>/dev/null; then
    p="$$"
  fi
  echo "$p"
}

# --- Is a given session id live (by any signal)? ---
# Returns 0 (true) if the session is provably alive; 1 (false) otherwise.
# Checks two independent signals in priority order:
#   1. REPO_OS_SESSION_ID env var — set by daemon and worktree sessions. These
#      sessions are authoritative from an external process tree and never write
#      a sidecar (Decision 0030), so the env var is the only signal available.
#   2. Per-process sidecars (.session-id.<pid>) — written by interactive sessions.
#      A sidecar with a live pid is the decisive signal for interactive sessions.
# Called by sweep_stale_sessions from both its registry arm and the orphaned-
# state-dir loop, so the two halves share a single liveness test (R29).
_session_is_live() {
  local sid="$1"
  local repo_root="${2:-$_REPO_OS_ROOT}"
  # Env check: daemon/worktree sessions set REPO_OS_SESSION_ID. This is only
  # useful when the sweep itself runs inside that same process tree, but it is
  # cost-free and prevents a daemon from evicting its own current session.
  if [ -n "${REPO_OS_SESSION_ID:-}" ] && [ "$REPO_OS_SESSION_ID" = "$sid" ]; then
    return 0
  fi
  # Sidecar check: an interactive session writes .session-id.<pid>.
  local _sl_sc
  for _sl_sc in "$repo_root"/.claude/.session-id.*; do
    [ -f "$_sl_sc" ] || continue
    local _sl_pid="${_sl_sc##*.}"
    case "$_sl_pid" in
      ''|*[!0-9]*) continue ;;
    esac
    kill -0 "$_sl_pid" 2>/dev/null || continue
    local _sl_content
    _sl_content=$(cat "$_sl_sc" 2>/dev/null)
    [ "$_sl_content" = "$sid" ] && return 0
  done
  return 1
}

# --- Is a given session id already claimed by a DIFFERENT, LIVE process? ---
# Scans the per-process sidecars .claude/.session-id.<pid>. Returns 0 (true) iff
# some sidecar for a pid != our dpid, whose process is still alive, holds the id.
# Sidecar presence is written synchronously inside get_session_id (bootstrap/mint),
# so it is a race-safe concurrency signal independent of register_session timing.
# Intentionally does NOT consult the session registry: a registry-only "foreign"
# owner (no sidecar) is treated as adoptable, so the close-time foreign-state guard
# in session-close-check.sh remains the safety net for that case (keeps L4.9a green).
_sid_claimed_by_live_foreign() {
  local claim_id="$1" dpid="$2" repo_root="$3"
  local f base fpid content
  for f in "$repo_root"/.claude/.session-id.*; do
    [ -f "$f" ] || continue
    base="${f##*/}"            # .session-id.<pid>
    fpid="${base##*.}"         # <pid>
    case "$fpid" in
      ''|*[!0-9]*) continue ;;  # skip non-numeric suffixes
    esac
    [ "$fpid" = "$dpid" ] && continue
    kill -0 "$fpid" 2>/dev/null || continue
    content=$(cat "$f" 2>/dev/null)
    [ "$content" = "$claim_id" ] && return 0
  done
  return 1
}

# --- Session ID (created on first hook fire, cleaned by Stop hook) ---
_CACHED_SESSION_ID=""
get_session_id() {
  local repo_root="$1"
  # Env var injection (Decision 0030): worktree and daemon sessions set
  # REPO_OS_SESSION_ID, and it is AUTHORITATIVE — so it is checked BEFORE the
  # cache, and overrides it when the two diverge.
  #
  # This order is load-bearing. The automation daemon is ONE long-lived process
  # that sources this library once and re-exports REPO_OS_SESSION_ID per brief.
  # With the cache consulted first, brief 1 of a run became the identity for
  # every brief after it: state_manager_setup wrote plan-approved under the
  # stale key, the runner's worktree mirror found nothing at the new key, and
  # the brief deadlocked in the `plan` phase — writes gated, advance_phase
  # refusing without plan-approved, and AskUserQuestion unavailable in headless
  # mode. It exited having done nothing and the runner logged review:dirty-noop.
  # Only the FIRST brief of a daemon run could ever complete, which is exactly
  # why single-brief tests never caught it. Diagnosed 2026-10-12, hit again
  # 2026-10-13 on brief 3 of a 6-brief group after ~45 minutes of work.
  #
  # The cache is NOT removed: it still serves interactive sessions, which never
  # set this variable, and that path is what keeps identity stable across a
  # context-window turnover (the 2026-06-18 sidecar fix, 3647acf). Both
  # requirements are pinned by layer4 L4.11 and L4.15.
  if [ -n "${REPO_OS_SESSION_ID:-}" ]; then
    if [ "$_CACHED_SESSION_ID" != "$REPO_OS_SESSION_ID" ]; then
      _CACHED_SESSION_ID="$REPO_OS_SESSION_ID"
      # Derived from the id, so it cannot be allowed to outlive it — a stale
      # dir cache is this same bug wearing a different hat, and is what
      # actually mis-routes plan-approved. Cleared ONLY on divergence: doing it
      # unconditionally would defeat the cache on every hook call in a worktree
      # session.
      _CACHED_SESSION_STATE_DIR=""
    fi
    echo "$_CACHED_SESSION_ID"
    return
  fi
  if [ -n "$_CACHED_SESSION_ID" ]; then
    echo "$_CACHED_SESSION_ID"
    return
  fi
  # Harness stdin contract: hook entrypoints extract session_id from the JSON
  # payload into _REPO_OS_STDIN_SID before sourcing libraries. The stdin SID is
  # used for validation/analytics only — it is NOT authoritative for file-path
  # keying. First-writer-wins (fix for the editor-live identity drift regressed
  # by 9b6ec01): the on-disk .session-id is the durable identity once written,
  # so it keys the per-session state dir, session-log filename, and cycle
  # counter stably across turns even when the harness rotates session_id on a
  # context-window turnover. We therefore write-through ONLY when no durable
  # identity file exists yet; when the file is present it wins, regardless of
  # the stdin value. (Cross-session bleed is prevented by close-gated deletion
  # of .session-id, not by overwriting it mid-session.)
  if [ -n "${_REPO_OS_STDIN_SID:-}" ]; then
    local dpid pp_file flat_file
    dpid="$(_resolve_durable_pid)"
    pp_file="$repo_root/.claude/.session-id.$dpid"
    flat_file="$repo_root/.claude/.session-id"

    # (a) This process already has a durable per-process identity — it wins.
    # Stable across context-window turnover (same $PPID maps back to the same
    # id even when the harness rotates the stdin SID); distinct per window
    # (a second window has a different $PPID, hence a different sidecar). The
    # turnover mismatch is benign, so the advisory is REPO_OS_DEBUG-gated to
    # avoid a per-turn stderr nag. Default: silent.
    if [ -f "$pp_file" ]; then
      _CACHED_SESSION_ID=$(cat "$pp_file" 2>/dev/null)
      if [ "${REPO_OS_DEBUG:-0}" = "1" ] && [ "$_CACHED_SESSION_ID" != "$_REPO_OS_STDIN_SID" ]; then
        echo "Warning: session-id mismatch: file=$_CACHED_SESSION_ID, stdin=$_REPO_OS_STDIN_SID. Using file value." >&2
      fi
      echo "$_CACHED_SESSION_ID"
      return
    fi

    # (b) No per-process file yet, but a flat .session-id exists. ADOPT it as
    # the durable identity (a prior turn whose $PPID is now unknowable — e.g. the
    # test harness, an in-flight pre-sidecar session, or a legacy/orphan file)
    # UNLESS a DIFFERENT, currently-live process already claims it. In that case
    # this is a concurrent peer (second window / in-place daemon on main): we must
    # NOT alias onto its identity — MINT a fresh per-process id from the harness
    # stdin SID and claim it via our sidecar. Adoption is cache-only (does not
    # write a sidecar) so it never disturbs the flat-file path the integration
    # tests and pre-sidecar sessions resolve through.
    if [ -f "$flat_file" ]; then
      local flat_id
      flat_id=$(cat "$flat_file" 2>/dev/null)
      if [ -n "$flat_id" ] && _sid_claimed_by_live_foreign "$flat_id" "$dpid" "$repo_root"; then
        _CACHED_SESSION_ID="$_REPO_OS_STDIN_SID"
        echo "$_CACHED_SESSION_ID" > "$pp_file" 2>/dev/null || true
        echo "$_CACHED_SESSION_ID"
        return
      fi
      _CACHED_SESSION_ID="$flat_id"
      if [ "${REPO_OS_DEBUG:-0}" = "1" ] && [ "$_CACHED_SESSION_ID" != "$_REPO_OS_STDIN_SID" ]; then
        echo "Warning: session-id mismatch: file=$_CACHED_SESSION_ID, stdin=$_REPO_OS_STDIN_SID. Using file value." >&2
      fi
      echo "$_CACHED_SESSION_ID"
      return
    fi

    # (c) Neither per-process nor flat file — this hook is the first initializer.
    # Seed BOTH: the per-process sidecar (durable identity for this window) and
    # the flat file (legacy/compat anchor and the stable anchor that hook fires
    # with an unknowable $PPID resolve through). Cross-session bleed is prevented
    # by close-gated deletion of both, not by overwriting them mid-session.
    _CACHED_SESSION_ID="$_REPO_OS_STDIN_SID"
    echo "$_CACHED_SESSION_ID" > "$pp_file" 2>/dev/null || true
    echo "$_CACHED_SESSION_ID" > "$flat_file" 2>/dev/null || true
    echo "$_CACHED_SESSION_ID"
    return
  fi
  local sid_file="$repo_root/.claude/.session-id"
  if [ -f "$sid_file" ]; then
    _CACHED_SESSION_ID=$(cat "$sid_file")
  else
    # Sub-second uniqueness: EPOCHREALTIME fractional (Bash 5+), PID fallback
    if [ -n "${EPOCHREALTIME:-}" ]; then
      local _frac="${EPOCHREALTIME#*.}"
      _CACHED_SESSION_ID="$(date +%Y%m%d-%H%M%S)-${_frac:0:4}"
    else
      _CACHED_SESSION_ID="$(date +%Y%m%d-%H%M%S)-$$"
    fi
    echo "$_CACHED_SESSION_ID" > "$sid_file" 2>/dev/null || true
  fi
  echo "$_CACHED_SESSION_ID"
}

# --- Session-scoped state directory (Decision 0030) ---
# Routes ALL session types to per-session state directories:
#   .claude/.state/wt-sessions/{sid}/
# This eliminates shared-state collision vectors between concurrent sessions.
# Backward compat: if per-session dir does not exist but flat .claude/.state/
# contains a phase-state matching the current session ID, the flat dir is
# returned (pre-migration session — valid for that session only).
# Cached per-process to avoid repeated function calls.
_CACHED_SESSION_STATE_DIR=""
get_session_state_dir() {
  if [ -n "$_CACHED_SESSION_STATE_DIR" ]; then
    echo "$_CACHED_SESSION_STATE_DIR"
    return
  fi
  local repo_root="$_REPO_OS_ROOT"
  local sid
  sid=$(get_session_id "$repo_root")
  # Sanitize: strip path components to prevent directory traversal (Decision 0030 security)
  sid="${sid//\//_}"
  sid="${sid//\.\./_}"
  local per_session="$repo_root/.claude/.state/wt-sessions/$sid"

  if [ -d "$per_session" ]; then
    # Per-session dir exists — use it
    _CACHED_SESSION_STATE_DIR="$per_session"
  else
    # Backward compat: check flat state for matching session ID (pre-migration)
    local flat_state="$repo_root/.claude/.state/phase-state"
    if [ -f "$flat_state" ]; then
      local flat_sid
      flat_sid=$(grep '^session_id:' "$flat_state" 2>/dev/null | sed 's/^session_id: *//' | tr -d '[:space:]' | head -1)
      if [ -n "$flat_sid" ] && [ "$flat_sid" = "$sid" ]; then
        _CACHED_SESSION_STATE_DIR="$repo_root/.claude/.state"
        echo "$_CACHED_SESSION_STATE_DIR"
        return
      fi
    fi
    # No matching flat state — use per-session dir (init_phase will create it)
    _CACHED_SESSION_STATE_DIR="$per_session"
  fi
  echo "$_CACHED_SESSION_STATE_DIR"
}

# --- Cross-session marker scan ---
# Completion markers (tg-*-brief-*.complete) are cross-session: written by
# content brief sessions, read by merge brief sessions and cohesion triggers.
# With per-session state dirs, these markers live in each content brief's dir.
# This helper scans ALL per-session dirs (and flat dir for backward compat)
# to find markers matching a glob pattern.
# Arguments:
#   $1 — glob pattern (e.g., "tg-*-brief-*.complete" or "tg-mygroup-brief-*.complete")
# Output: count on stdout
count_cross_session_markers() {
  local pattern="$1"
  local repo_root="$_REPO_OS_ROOT"
  local count=0

  # Scan per-session dirs
  local wt_dir="$repo_root/.claude/.state/wt-sessions"
  if [ -d "$wt_dir" ]; then
    local session_dir
    for session_dir in "$wt_dir"/*/; do
      [ -d "$session_dir" ] || continue
      local marker
      for marker in "$session_dir"/$pattern; do
        [ -f "$marker" ] || continue
        count=$((count + 1))
      done
    done
  fi

  # Backward compat: also check flat dir
  local marker
  for marker in "$repo_root/.claude/.state"/$pattern; do
    [ -f "$marker" ] || continue
    count=$((count + 1))
  done

  echo "$count"
}

# --- Clean cross-session markers ---
# Removes completion markers from ALL per-session dirs and flat dir.
# Called by cleanup_session_files for taskgroup-merge sessions.
# Arguments:
#   $1 — glob pattern (e.g., "tg-*-brief-*.complete")
clean_cross_session_markers() {
  local pattern="$1"
  local repo_root="$_REPO_OS_ROOT"

  # Clean from per-session dirs
  local wt_dir="$repo_root/.claude/.state/wt-sessions"
  if [ -d "$wt_dir" ]; then
    local session_dir
    for session_dir in "$wt_dir"/*/; do
      [ -d "$session_dir" ] || continue
      rm -f "$session_dir"/$pattern 2>/dev/null || true
      # Remove now-empty session dir
      rmdir "$session_dir" 2>/dev/null || true
    done
  fi

  # Backward compat: also clean flat dir
  rm -f "$repo_root/.claude/.state"/$pattern 2>/dev/null || true
}

# --- Cached branch name (avoid repeated git calls) ---
_CACHED_BRANCH=""
get_branch() {
  if [ -z "$_CACHED_BRANCH" ]; then
    _CACHED_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  fi
  echo "$_CACHED_BRANCH"
}

# --- Cached operating mode ---
_CACHED_MODE=""
get_mode() {
  if [ -z "$_CACHED_MODE" ]; then
    local repo_root
    repo_root="$_REPO_OS_ROOT"
    _CACHED_MODE="${REPO_OS_MODE:-}"
    if [ -z "$_CACHED_MODE" ]; then
      local mode_file="$repo_root/.claude/repo-mode"
      if [ -f "$mode_file" ]; then
        _CACHED_MODE=$(head -1 "$mode_file" | tr -d '[:space:]')
      fi
    fi
    _CACHED_MODE="${_CACHED_MODE:-child}"
  fi
  echo "$_CACHED_MODE"
}

# --- Session type from phase-state (with session ID validation) ---
# Reads session_type from phase-state if present and current (session ID match).
# Falls back to .session-type file. Returns empty string if neither exists.
# Cached per-process to avoid repeated file I/O on each hook invocation.
# Uses boolean sentinel (not empty-string check) because empty result is
# valid — session type is legitimately absent before init_phase().
_CACHED_SESSION_TYPE=""
_CACHED_SESSION_TYPE_SET=false
# Audit C7: process-scoped overlap check cache (avoids redundant globs per invocation)
# PID-bound: cache only valid for the same process (prevents stale results across invocations)
_SESSION_OVERLAP_CHECKED=false
_SESSION_OVERLAP_CHECK_PID=""
get_session_type() {
  # Fast-path (R13): if _phase-helper.sh already validated, use its cached result
  # Guard: _PS_VALIDATED is only set when _phase-helper.sh is sourced
  if [ -n "${_PS_VALIDATED+x}" ] && [ "$_PS_VALIDATED" = true ]; then
    echo "$_PS_SESSION_TYPE"
    return
  fi

  if [ "$_CACHED_SESSION_TYPE_SET" = true ]; then
    echo "$_CACHED_SESSION_TYPE"
    return
  fi

  local repo_root
  repo_root="$_REPO_OS_ROOT"
  local state_file="$(get_session_state_dir)/phase-state"
  local result=""

  # Try phase-state first (with session ID validation)
  if [ -f "$state_file" ]; then
    local sid
    sid=$(grep '^session_id:' "$state_file" 2>/dev/null | sed 's/^session_id: *//')
    local current_sid
    if [ -n "${REPO_OS_SESSION_ID:-}" ]; then
      current_sid="$REPO_OS_SESSION_ID"
    else
      # Per-process identity (not the shared flat .session-id): state_file is
      # resolved via get_session_state_dir (sidecar-aware), so a concurrent
      # window must validate against its OWN id or it loses its session type.
      current_sid=$(get_session_id "$repo_root")
    fi
    if [ -n "$sid" ] && [ "$sid" = "$current_sid" ]; then
      result=$(grep '^session_type:' "$state_file" 2>/dev/null | sed 's/^session_type: *//')
    fi
  fi

  # Fallback to .session-type file
  if [ -z "$result" ]; then
    local type_file="$repo_root/.claude/.session-type"
    if [ -f "$type_file" ]; then
      result=$(head -1 "$type_file" 2>/dev/null | tr -d '[:space:]')
    fi
  fi

  _CACHED_SESSION_TYPE="$result"
  _CACHED_SESSION_TYPE_SET=true
  echo "$_CACHED_SESSION_TYPE"
}

# --- Cached analytics directory and date (avoid redundant forks per invocation) ---
_CACHED_ANALYTICS_DIR=""
_CACHED_TODAY=""

# --- Write analytics event ---
# v2 signature: log_hook_event "hook" "evt" "tool" "out" "$START_MS" "reason" ["detail"] ["path"]
# detail and path are optional v2 enrichment fields.
# mode and branch are auto-appended from git state.
log_hook_event() {
  local hook="$1"
  local event="$2"
  local tool="${3:-}"
  local outcome="${4:-allow}"
  local start_ms="${5:-0}"
  local reason="${6:-}"
  local detail="${7:-}"
  local path="${8:-}"

  local repo_root
  repo_root="$_REPO_OS_ROOT"
  local sid
  sid="$(get_session_id "$repo_root")"
  local end_ms
  end_ms=$(now_ms)
  local dur=$(( end_ms - start_ms ))

  # Cached analytics directory (avoids basename fork on every call)
  if [ -z "$_CACHED_ANALYTICS_DIR" ]; then
    _CACHED_ANALYTICS_DIR="$(get_analytics_dir "$repo_root")"
  fi
  local events_dir="$_CACHED_ANALYTICS_DIR"
  mkdir -p "$events_dir" 2>/dev/null || true

  # Cached date (avoids date fork on every call — stable within a session)
  if [ -z "$_CACHED_TODAY" ]; then
    _CACHED_TODAY="$(date +%Y-%m-%d)"
  fi
  local today="$_CACHED_TODAY"

  # Auto-resolve v2 enrichment fields
  local mode
  mode="$(get_mode)"
  local branch
  branch="$(get_branch)"

  # Sanitize all string values interpolated into JSON (escape \ and ", strip control chars)
  local _v
  _v="$sid";      _v="${_v//\\/\\\\}"; _v="${_v//\"/\\\"}"; _v="${_v//$'\n'/}"; _v="${_v//$'\r'/}"; _v="${_v//$'\t'/}"; sid="$_v"
  _v="$hook";     _v="${_v//\\/\\\\}"; _v="${_v//\"/\\\"}"; _v="${_v//$'\n'/}"; _v="${_v//$'\r'/}"; _v="${_v//$'\t'/}"; hook="$_v"
  _v="$event";    _v="${_v//\\/\\\\}"; _v="${_v//\"/\\\"}"; _v="${_v//$'\n'/}"; _v="${_v//$'\r'/}"; _v="${_v//$'\t'/}"; event="$_v"
  _v="$tool";     _v="${_v//\\/\\\\}"; _v="${_v//\"/\\\"}"; _v="${_v//$'\n'/}"; _v="${_v//$'\r'/}"; _v="${_v//$'\t'/}"; tool="$_v"
  _v="$outcome";  _v="${_v//\\/\\\\}"; _v="${_v//\"/\\\"}"; _v="${_v//$'\n'/}"; _v="${_v//$'\r'/}"; _v="${_v//$'\t'/}"; outcome="$_v"
  _v="$reason";   _v="${_v//\\/\\\\}"; _v="${_v//\"/\\\"}"; _v="${_v//$'\n'/}"; _v="${_v//$'\r'/}"; _v="${_v//$'\t'/}"; reason="$_v"
  _v="$mode";     _v="${_v//\\/\\\\}"; _v="${_v//\"/\\\"}"; _v="${_v//$'\n'/}"; _v="${_v//$'\r'/}"; _v="${_v//$'\t'/}"; mode="$_v"
  _v="$branch";   _v="${_v//\\/\\\\}"; _v="${_v//\"/\\\"}"; _v="${_v//$'\n'/}"; _v="${_v//$'\r'/}"; _v="${_v//$'\t'/}"; branch="$_v"
  _v="$detail";   _v="${_v//\\/\\\\}"; _v="${_v//\"/\\\"}"; _v="${_v//$'\n'/}"; _v="${_v//$'\r'/}"; _v="${_v//$'\t'/}"; detail="$_v"
  _v="$path";     _v="${_v//\\/\\\\}"; _v="${_v//\"/\\\"}"; _v="${_v//$'\n'/}"; _v="${_v//$'\r'/}"; _v="${_v//$'\t'/}"; path="$_v"

  # Build v2 event with optional fields (omit empty fields to keep events compact)
  local json
  json=$(printf '{"v":2,"ts":%s,"sid":"%s","hook":"%s","evt":"%s","tool":"%s","out":"%s","dur":%s,"reason":"%s","mode":"%s","branch":"%s"' \
    "$end_ms" "$sid" "$hook" "$event" "$tool" "$outcome" "$dur" "$reason" "$mode" "$branch")

  # Append optional v2 fields only when populated
  if [ -n "$detail" ]; then
    json="$json,\"detail\":\"$detail\""
  fi
  if [ -n "$path" ]; then
    json="$json,\"path\":\"$path\""
  fi

  # Session type from cached getter (avoids redundant file I/O per invocation)
  local stype
  stype="$(get_session_type)"
  if [ -n "$stype" ]; then
    stype="${stype//\\/\\\\}"; stype="${stype//\"/\\\"}"
    stype="${stype//$'\n'/}"; stype="${stype//$'\r'/}"; stype="${stype//$'\t'/}"
    json="$json,\"session_type\":\"$stype\""
  fi

  # Automation context (set by runner before claude -p invocation)
  if [ -n "${REPO_OS_AUTOMATION_ENTRY:-}" ]; then
    local auto_entry="${REPO_OS_AUTOMATION_ENTRY}"
    auto_entry="${auto_entry//\\/\\\\}"; auto_entry="${auto_entry//\"/\\\"}"
    auto_entry="${auto_entry//$'\n'/}"; auto_entry="${auto_entry//$'\r'/}"; auto_entry="${auto_entry//$'\t'/}"
    json="$json,\"automation_context\":\"$auto_entry\""
  fi

  json="$json}"
  printf '%s\n' "$json" >> "$events_dir/$today.ndjson" 2>/dev/null || true
}

# --- Log override usage for session audit ---
# Appends to .claude/.state/overrides.log (gitignored, session-scoped).
# Session-close hook reads this for override audit summary.
log_override() {
  local hook="$1"
  local env_var="$2"

  local repo_root
  repo_root="$_REPO_OS_ROOT"
  local state_dir
  state_dir="$(get_session_state_dir)"
  mkdir -p "$state_dir" 2>/dev/null || true

  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s %s %s\n' "$ts" "$hook" "$env_var" \
    >> "$state_dir/overrides.log" 2>/dev/null || true
}

# --- KPI event (Phase 3c — monitoring baseline) ---
# Lightweight wrapper around log_hook_event for KPI metrics.
# Reuses existing NDJSON infrastructure. KPI events use "kpi" as the event type
# and the kpi_name as the reason field for easy filtering.
# Usage: log_kpi_event "session_kpi_summary" "blocks:0,retries:1,valve:0,tokens:0" "standard" "$START_MS"
log_kpi_event() {
  local kpi_name="$1"
  local value="$2"
  local context="${3:-}"
  local start_ms="${4:-0}"
  log_hook_event "kpi" "kpi" "" "metric" "$start_ms" "$kpi_name" "$value" "$context"
}

# --- Invalidate session type cache (Phase 3b — upgrade support) ---
# Called by upgrade_session_type() when ephemeral→standard conversion changes
# the session type in phase-state. Forces get_session_type() to re-read on
# next call instead of returning the stale cached value.
invalidate_session_type_cache() {
  _CACHED_SESSION_TYPE=""
  _CACHED_SESSION_TYPE_SET=false
}

# --- Cleanup: delete event files older than 90 days ---
cleanup_old_analytics() {
  local repo_root="$1"
  local events_dir
  events_dir="$(get_analytics_dir "$repo_root")"
  [ -d "$events_dir" ] && find "$events_dir" -name "*.ndjson" -type f -mtime +90 -delete 2>/dev/null || true
}

# --- Auto-register repo in global analytics registry ---
register_repo() {
  # Test-mode guard: prevent test harness from polluting the real registry
  [ "${REPO_OS_TEST_MODE:-0}" = "1" ] && return 0

  local repo_root="$1"
  local registry_dir="$HOME/.local/share/repo-os-analytics"
  local registry="$registry_dir/registry.json"

  # Skip if already registered (check by path)
  if [ -f "$registry" ] && grep -q "\"$repo_root\"" "$registry" 2>/dev/null; then
    return 0
  fi

  mkdir -p "$registry_dir" 2>/dev/null || true

  # Derive repo name from directory
  local repo_name
  repo_name="$(basename "$repo_root")"

  if [ ! -f "$registry" ]; then
    # Create new registry
    printf '{"schema_version":"1.0.0","repos":[{"name":"%s","path":"%s"}]}\n' \
      "$repo_name" "$repo_root" > "$registry" 2>/dev/null || true
  else
    # Append to existing registry (jq if available, otherwise skip)
    if command -v jq &>/dev/null; then
      local tmp="$registry.tmp"
      jq --arg name "$repo_name" --arg path "$repo_root" \
        '.repos += [{"name": $name, "path": $path}]' "$registry" > "$tmp" 2>/dev/null && \
        mv "$tmp" "$registry" 2>/dev/null || true
    fi
  fi
}

# --- Portable ISO 8601 to epoch seconds ---
# macOS date cannot parse ISO 8601 natively. Uses python3 if available,
# falls back to GNU date -d. Returns empty string on failure.
# Fail-silent: callers skip age checks when conversion fails.
_iso_to_epoch() {
  local iso="$1"
  if command -v python3 &>/dev/null; then
    python3 -c "
import sys, datetime
try:
    dt = datetime.datetime.strptime(sys.argv[1], '%Y-%m-%dT%H:%M:%SZ')
    print(int(dt.replace(tzinfo=datetime.timezone.utc).timestamp()))
except:
    pass
" "$iso" 2>/dev/null
  elif date -d "$iso" +%s &>/dev/null 2>&1; then
    date -d "$iso" +%s 2>/dev/null
  else
    echo ""
  fi
}

# --- Portable epoch seconds to ISO 8601 (UTC) ---
# BSD/macOS date takes -r, GNU date takes -d @<epoch>; neither accepts the
# other's form. Echoes the input unchanged when both fail, so a caller
# formatting a timestamp for display always gets something printable.
# Used by the operator-notes delivery paths (Decision t-0055 clause 13), where
# a note's send time is carried by the <epoch> prefix of its filename.
epoch_to_iso() {
  local epoch="$1"
  case "$epoch" in
    ''|*[!0-9]*) printf '%s' "$epoch"; return 0 ;;
  esac
  date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf '%s' "$epoch"
}

# --- Register session in the session registry ---
# Writes a YAML file to .claude/.state/sessions/{session-id}.yaml.
# Called at session init (from init_phase in _phase-helper.sh).
# Checks for same-branch overlap and emits an advisory warning.
# Fail-silent: registry failures never block session start.
register_session() {
  local repo_root
  repo_root="$_REPO_OS_ROOT"
  local sid
  sid="$(get_session_id "$repo_root")"
  local stype="${1:-}"
  local branch
  branch="$(get_branch)"
  # Durable PID: use _resolve_durable_pid() — the same function the sidecar
  # writer uses — so the registry and the sidecar agree on what "the process"
  # is. _resolve_durable_pid respects _REPO_OS_DURABLE_PID for test injection,
  # prefers $PPID (the long-lived claude process that spawns each hook
  # subprocess) over $$ (the short-lived subprocess itself), and falls back to
  # $$ when $PPID is 0/1/unavailable. Using the shared helper is what keeps the
  # two halves of sweep_stale_sessions from disagreeing about liveness (R29).
  local pid
  pid="$(_resolve_durable_pid)"
  local started_at
  started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local sessions_dir="$repo_root/.claude/.state/sessions"
  mkdir -p "$sessions_dir" 2>/dev/null || true

  # Preserve operator-control fields already on the record (Decision t-0055).
  # runner.sh writes them before launching `claude -p`; this function then runs
  # inside the launched session's init_phase. The write below replaces the whole
  # file, so without this the control fields would be dropped the moment the
  # session it describes started. Only bites when the runner and the session
  # resolve _REPO_OS_ROOT to the same path (no worktree isolation) — under
  # worktree isolation the runner's record is the main repo's and is untouched
  # here — but the cost of being unconditional is one grep.
  local preserved_control=""
  if [ -f "$sessions_dir/${sid}.yaml" ]; then
    preserved_control=$(grep -E '^(entry_id|work_order_id|claude_session_id|child_pid|worktree|control_state):' \
      "$sessions_dir/${sid}.yaml" 2>/dev/null || true)
  fi

  # Write session file (add worktree_path for full worktree sessions — Decision 0030)
  {
    printf 'session_id: %s\nsession_type: %s\nbranch: %s\npid: %s\nstarted_at: %s\n' \
      "$sid" "$stype" "$branch" "$pid" "$started_at"
    if is_full_worktree_session; then
      printf 'worktree_path: %s\n' "$PWD"
    fi
    if [ -n "$preserved_control" ]; then
      printf '%s\n' "$preserved_control"
    fi
  } > "$sessions_dir/${sid}.yaml" 2>/dev/null || true

  # Check for same-branch overlap (advisory at registration time)
  local overlap_file
  for overlap_file in "$sessions_dir"/*.yaml; do
    [ -f "$overlap_file" ] || continue
    local other_sid
    other_sid=$(basename "$overlap_file" .yaml)
    [ "$other_sid" = "$sid" ] && continue

    local other_branch
    other_branch=$(grep '^branch: ' "$overlap_file" 2>/dev/null | sed 's/^branch: *//')
    [ "$other_branch" = "$branch" ] || continue

    local other_type
    other_type=$(grep '^session_type: ' "$overlap_file" 2>/dev/null | sed 's/^session_type: *//')
    echo "Warning: Session $other_sid (type: $other_type) is also active on branch '$branch'. Concurrent edits may cause conflicts." >&2
  done
}

# --- Operator session control record (Decision t-0055) ---
# The control half of the session registry: the fields runner.sh writes so the
# operator (and Massimo's Task details header) can see which entry a session is
# running, which claude session id it can be resumed with, which process is
# running it, and whether it is running, stopping or stopped.
#
# Resolved against the MAIN repo root, not _REPO_OS_ROOT. The runner writes the
# record from the main repo while the session it describes runs in a worktree,
# where _REPO_OS_ROOT is the worktree root (Decision 0028 two-root divergence).
# Routing both parties through get_main_repo_root() means one record per session
# id, readable from either side — the same treatment as handoff bundles, the
# daemon queue, and the control directory below.
#
# Arguments:
#   $1 — session id (required)
# Output: absolute path to the record on stdout
session_record_path() {
  local sid="${1:-}"
  [ -n "$sid" ] || return 1
  # Sanitize: strip path components to prevent directory traversal
  sid="${sid//\//_}"
  sid="${sid//\.\./_}"
  printf '%s/.claude/.state/sessions/%s.yaml\n' "$(get_main_repo_root)" "$sid"
}

# --- Merge-write fields into a session record ---
# Replaces the named fields and preserves every other line, so the base fields
# written by register_session() and any field this version does not know about
# survive. Creates the record when absent.
#
# Arguments:
#   $1    — session id
#   $2... — one or more `name=value` pairs. Names must be [a-zA-Z0-9_].
#           Newlines in a value are collapsed to spaces (a record is line-based).
# Returns: 0 on success, 1 on bad arguments or write failure.
session_record_set() {
  local sid="${1:-}"
  shift 2>/dev/null || true
  [ -n "$sid" ] || return 1
  [ "$#" -gt 0 ] || return 1

  local record
  record="$(session_record_path "$sid")" || return 1
  [ -n "$record" ] || return 1
  mkdir -p "$(dirname "$record")" 2>/dev/null || return 1

  # Space-padded list of the field names being replaced, so the copy loop below
  # can test membership with a substring match (no associative arrays — bash 3.2).
  local names=" "
  local kv name
  for kv in "$@"; do
    # A pair with no `=` is not a clear — `${kv#*=}` would return the name as
    # the value and write `child_pid: child_pid`. Skip it rather than guess.
    case "$kv" in
      *=*) ;;
      *) continue ;;
    esac
    name="${kv%%=*}"
    case "$name" in
      ''|*[!a-zA-Z0-9_]*) continue ;;
    esac
    names="${names}${name} "
  done
  [ "$names" != " " ] || return 1

  local tmp="${record}.tmp.$$"
  : > "$tmp" 2>/dev/null || return 1

  local line key
  if [ -f "$record" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      key="${line%%:*}"
      # Not a plain `name: value` line (blank, comment, nested) — keep verbatim.
      # Also keeps $key free of glob metacharacters before the match below.
      case "$key" in
        ''|*[!a-zA-Z0-9_]*)
          printf '%s\n' "$line" >> "$tmp"
          continue
          ;;
      esac
      case "$names" in
        *" $key "*) continue ;;
      esac
      printf '%s\n' "$line" >> "$tmp"
    done < "$record"
  fi

  local value
  for kv in "$@"; do
    case "$kv" in
      *=*) ;;
      *) continue ;;
    esac
    name="${kv%%=*}"
    case "$name" in
      ''|*[!a-zA-Z0-9_]*) continue ;;
    esac
    value="${kv#*=}"
    value="${value//$'\n'/ }"
    value="${value//$'\r'/ }"
    if [ -n "$value" ]; then
      printf '%s: %s\n' "$name" "$value" >> "$tmp"
    else
      # No trailing space on a cleared field — `child_pid:` reads as empty to a
      # YAML parser and to the repo's line-oriented readers alike.
      printf '%s:\n' "$name" >> "$tmp"
    fi
  done

  if ! mv -f "$tmp" "$record" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

# --- Read one field from a session record ---
# A missing record and a missing field are both "empty", not errors: records
# written before a field existed must still load.
#
# Arguments:
#   $1 — session id
#   $2 — field name
# Output: the value on stdout (empty when absent)
# Returns: 0 unless the arguments are unusable
session_record_get() {
  local sid="${1:-}"
  local field="${2:-}"
  [ -n "$sid" ] && [ -n "$field" ] || return 1
  case "$field" in
    *[!a-zA-Z0-9_]*) return 1 ;;
  esac

  local record
  record="$(session_record_path "$sid")" || return 1
  [ -f "$record" ] || return 0

  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$field":*)
        line="${line#*:}"
        line="${line# }"
        printf '%s\n' "$line"
        return 0
        ;;
    esac
  done < "$record"
  return 0
}

# --- Per-entry control directory (Decision t-0055) ---
# `.claude/.state/control/<entry-id>/` — where the operator's control flags for
# one queue entry live (`STOP`, `FORCE`, and a `notes/` subdirectory). Flags are
# files rather than signals so that one set while nothing is watching is still
# honoured when something starts, matching the existing daemon-wide HALT and
# FORCE-HALT flags.
#
# Resolved against the MAIN repo root for the same reason as the session record
# above: the operator writes a flag from the main repo and the session that must
# observe it is running inside a worktree.
#
# Arguments:
#   $1 — entry id (required)
# Output: absolute path on stdout. Does NOT create the directory.
get_control_dir() {
  local entry_id="${1:-}"
  [ -n "$entry_id" ] || return 1
  # Sanitize: strip path components to prevent directory traversal
  entry_id="${entry_id//\//_}"
  entry_id="${entry_id//\.\./_}"
  printf '%s/.claude/.state/control/%s\n' "$(get_main_repo_root)" "$entry_id"
}

# --- Create the control directory for an entry ---
# Arguments:
#   $1 — entry id
# Output: the directory path on stdout
# Returns: 0 on success, 1 on bad argument or mkdir failure
ensure_control_dir() {
  local dir
  dir="$(get_control_dir "${1:-}")" || return 1
  [ -n "$dir" ] || return 1
  mkdir -p "$dir" 2>/dev/null || return 1
  printf '%s\n' "$dir"
}

# --- Sweep stale session registry entries ---
# Removes entries with dead PIDs (kill -0 fails) or age >24h.
# Also enforces SESSION_MAX_TTL (default 6h): live sessions exceeding the TTL
# are transitioned to failed with an escalation (C7 orphan TTL patch).
# Called at session init, close, and daemon startup crash recovery.
# Fail-silent: sweep failures never block session operations.
#
# Arguments:
#   $1 — exclude_sid (optional). When provided, skip the registry entry AND
#         per-session state dir for this session ID. Used by init_phase to
#         prevent the current session from evicting itself during its own sweep
#         (the durable PPID may appear dead if the hook runs from a subprocess).
#
# Configurable: SESSION_MAX_TTL env var (seconds, default 21600 = 6h).
sweep_stale_sessions() {
  local exclude_sid="${1:-}"
  local repo_root
  repo_root="$_REPO_OS_ROOT"

  # Clean per-process identity sidecars (.session-id.<pid>) whose owning process
  # is dead. These are written synchronously by get_session_id (bootstrap/mint);
  # a crash before close leaves one behind. Sweeping dead-pid sidecars caps
  # accumulation and shrinks the (already narrow) PID-reuse aliasing window. Live
  # sidecars — including the current session's — are preserved by the kill -0
  # check, so no exclude_sid handling is needed here. Runs BEFORE the registry-dir
  # guard below so sidecars are reaped even when no session registry dir exists.
  local sidecar base scpid
  for sidecar in "$repo_root"/.claude/.session-id.*; do
    [ -f "$sidecar" ] || continue
    base="${sidecar##*/}"        # .session-id.<pid>
    scpid="${base##*.}"          # <pid>
    case "$scpid" in
      ''|*[!0-9]*) continue ;;    # skip non-numeric suffixes (defensive)
    esac
    kill -0 "$scpid" 2>/dev/null || rm -f "$sidecar" 2>/dev/null || true
  done

  local sessions_dir="$repo_root/.claude/.state/sessions"
  [ -d "$sessions_dir" ] || return 0

  local max_ttl="${SESSION_MAX_TTL:-21600}"
  # Cap TTL below the 24h unconditional removal threshold to avoid silent skip
  [ "$max_ttl" -gt 86400 ] 2>/dev/null && max_ttl=86400

  local stale_file
  for stale_file in "$sessions_dir"/*.yaml; do
    [ -f "$stale_file" ] || continue

    # Skip the current session — do not evict ourselves during our own sweep
    local _sw_sid
    _sw_sid=$(basename "$stale_file" .yaml)
    if [ -n "$exclude_sid" ] && [ "$_sw_sid" = "$exclude_sid" ]; then
      continue
    fi

    local file_pid
    file_pid=$(grep '^pid: ' "$stale_file" 2>/dev/null | sed 's/^pid: *//')

    # PID check: if process is dead, remove stale entry
    if [ -n "$file_pid" ] && ! kill -0 "$file_pid" 2>/dev/null; then
      # Dead registry pid — but confirm the session is truly gone before
      # evicting. The registry pid can be dead while the session is alive:
      # register_session is called from a hook subprocess, and even using
      # _resolve_durable_pid() the recorded pid can die if $PPID itself is a
      # short-lived wrapper (tool-call context). The sidecar is the decisive
      # signal for interactive sessions; REPO_OS_SESSION_ID covers daemon/
      # worktree sessions that have no sidecar (Decision 0030). Using the same
      # _session_is_live helper as the orphaned-state-dir loop below means the
      # two halves cannot disagree — one shared notion of "live" (R29).
      if _session_is_live "$_sw_sid" "$repo_root"; then
        echo "WARNING: Session $_sw_sid has a dead registry pid ($file_pid) but its process is still live via sidecar or env — leaving its registry entry intact." >&2
        continue
      fi
      rm -f "$stale_file" 2>/dev/null || true
      continue
    fi

    # Age guard: if started_at is older than 24h, remove regardless of PID
    local file_started
    file_started=$(grep '^started_at: ' "$stale_file" 2>/dev/null | sed 's/^started_at: *//')
    if [ -n "$file_started" ]; then
      local file_epoch
      file_epoch=$(_iso_to_epoch "$file_started")
      local now_epoch
      now_epoch=$(date +%s)
      if [ -n "$file_epoch" ] && [ $(( now_epoch - file_epoch )) -gt 86400 ]; then
        # Age alone is NOT grounds for eviction while the process is alive.
        # Reaching this point means the dead-pid arm above did not remove the
        # entry — either because the pid is live, or because the entry carries
        # no `pid:` line at all, which is why the liveness test is repeated here
        # rather than assumed. (An earlier version of this comment claimed the
        # pid must be live; an entry with an empty pid falsifies that, and
        # overclaimed warrants are the exact failure this round was fixing.)
        # Removing a live session's
        # registry entry also costs it its state directory, because the
        # orphaned-state-dir loop below keys on "no registry entry" — so this
        # used to delete a long-running session's plan approval and every
        # recorded verdict, after which write-guard refused all of its edits.
        # Observed 2026-10-21 against a ~16h interactive session.
        #
        # Residual: `kill -0` cannot see pid REUSE, so a dead session whose pid
        # was recycled keeps its entry. The decisive liveness test in this repo
        # is the per-process sidecar, and the sidecar reap earlier in this
        # function already handles that class. An entry that outlives its
        # process is a smaller problem than a live session losing its state.
        if [ -n "$file_pid" ] && kill -0 "$file_pid" 2>/dev/null; then
          echo "WARNING: Session $_sw_sid is over 24h old but its process ($file_pid) is still alive — leaving its registry entry and state intact." >&2
        else
          rm -f "$stale_file" 2>/dev/null || true
        fi
        continue
      fi

      # TTL guard (C7): session exceeding max TTL → escalation
      #
      # Written once per session, not once per sweep. Removing the registry
      # entry used to provide that bound implicitly; now that a live session
      # keeps its entry, the escalation needs its own marker or every session
      # init, every close and every daemon start writes another one for the same
      # long-lived session — with a timestamp-unique id, so they accumulate and
      # retention only prunes RESOLVED escalations.
      if [ -n "$file_epoch" ] && [ $(( now_epoch - file_epoch )) -gt "$max_ttl" ] \
         && ! grep -q '^ttl_escalated_at: ' "$stale_file" 2>/dev/null; then
        local _ttl_sid
        _ttl_sid=$(basename "$stale_file" .yaml)
        local _ttl_age_h=$(( (now_epoch - file_epoch) / 3600 ))
        echo "WARNING: Session $_ttl_sid exceeded TTL (${_ttl_age_h}h > $((max_ttl / 3600))h) — writing escalation" >&2
        local _esc_dir="$repo_root/.claude/.automation/escalations"
        mkdir -p "$_esc_dir" 2>/dev/null || true
        local _esc_id="esc-ttl-${_ttl_sid}-$(date +%Y%m%d-%H%M%S)"
        {
          printf 'escalation:\n'
          printf '  id: "%s"\n' "$_esc_id"
          printf '  queue_entry_id: "%s"\n' "$_ttl_sid"
          printf '  type: "gate-failure"\n'
          printf '  severity: "blocking"\n'
          printf '  phase_at_exit: "unknown"\n'
          printf '  tag_at_exit: "agent"\n'
          printf '  message: "Session exceeded max TTL (%sh) — likely orphaned"\n' "$((max_ttl / 3600))"
          printf '  context: "session_id: %s, age_hours: %s, max_ttl_seconds: %s"\n' "$_ttl_sid" "$_ttl_age_h" "$max_ttl"
          printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          printf '  resolved: false\n'
          printf '  resolution: ""\n'
        } > "$_esc_dir/${_esc_id}.yaml" 2>/dev/null || true
        # The escalation is the whole point here — it tells the operator a
        # session has outlived its TTL. Removing the registry entry is NOT, and
        # must not happen while the process is live: it takes the session's
        # state directory with it (see the 24h arm above for why) and so breaks
        # the very session the escalation is reporting. A TTL overrun is a
        # signal, not a licence to evict.
        if [ -n "$file_pid" ] && kill -0 "$file_pid" 2>/dev/null; then
          echo "WARNING: Session $_ttl_sid is over TTL but still alive ($file_pid) — escalation written, registry entry and state left intact." >&2
          # Mark the entry so the next sweep does not escalate it again. Append
          # rather than rewrite: this file belongs to a LIVE session and a
          # rewrite would race its own writers.
          printf 'ttl_escalated_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$stale_file" 2>/dev/null || true
        else
          rm -f "$stale_file" 2>/dev/null || true
        fi
      fi
    fi
  done

  # Clean orphaned per-session state directories whose owning session
  # is no longer in the registry (dead PID or removed entry).
  local wt_sessions_dir="$repo_root/.claude/.state/wt-sessions"
  if [ -d "$wt_sessions_dir" ]; then
    local state_subdir
    for state_subdir in "$wt_sessions_dir"/*/; do
      [ -d "$state_subdir" ] || continue
      local dir_sid
      dir_sid=$(basename "$state_subdir")
      # Skip the current session — do not evict our own state dir
      if [ -n "$exclude_sid" ] && [ "$dir_sid" = "$exclude_sid" ]; then
        continue
      fi
      # Check if a registry entry exists for this session
      if [ ! -f "$sessions_dir/${dir_sid}.yaml" ]; then
        # A missing registry entry is NOT sufficient on its own. This loop is
        # where state actually gets destroyed, and until 2026-10-21 it was the
        # only ungated step in the function: any path that removed a live
        # session's registry entry took its whole state directory — plan
        # approval, every verdict — with it on the same pass. The two arms that
        # did that are now liveness-gated, but gating them is not the same as
        # guarding the deletion, so check liveness here too, at the point of no
        # return. The per-process sidecar is this repo's decisive test and does
        # not depend on a registry entry existing.
        if _session_is_live "$dir_sid" "$repo_root"; then
          echo "WARNING: State dir for $dir_sid has no registry entry but its process is still live — leaving it intact." >&2
        else
          rm -rf "$state_subdir" 2>/dev/null || true
        fi
      fi
    done
  fi
}

# --- Unregister session from the session registry ---
# Removes this session's YAML file and sweeps stale entries.
# Called by cleanup_session() in session-close-check.sh.
# Fail-silent: cleanup failures are non-fatal.
unregister_session() {
  local repo_root
  repo_root="$_REPO_OS_ROOT"
  local sid
  sid="$(get_session_id "$repo_root")"

  local sessions_dir="$repo_root/.claude/.state/sessions"

  # Remove this session's file
  rm -f "$sessions_dir/${sid}.yaml" 2>/dev/null || true

  # Remove this session's per-process identity sidecar(s) by content-match. The
  # owning process (this window) is still alive, so the dead-pid sweep below will
  # NOT reap it; without this, the same window's next session would fast-path onto
  # the closed id and bleed identity across sessions. Mirrors the close-gated
  # deletion of the flat .session-id in cleanup_session_files.
  local _us_sidecar _us_content
  for _us_sidecar in "$repo_root"/.claude/.session-id.*; do
    [ -f "$_us_sidecar" ] || continue
    _us_content=$(cat "$_us_sidecar" 2>/dev/null)
    [ "$_us_content" = "$sid" ] && rm -f "$_us_sidecar" 2>/dev/null || true
  done

  # Sweep remaining stale entries. Exclude the current session id: although its
  # registry file was just removed above, the orphan-state-dir loop in
  # sweep_stale_sessions would otherwise see the now-registry-less per-session
  # state dir and rm it out from under cleanup_session_files (which runs after
  # this and performs the ordered governance-file cleanup + rmdir). Passing
  # exclude_sid keeps that teardown ordering intact.
  sweep_stale_sessions "$sid"
}

# --- Check if another session is active on a given branch ---
# Query helper for session-bind guards (cleanup, seal).
# Returns 0 if any session OTHER than the current one is active on the
# given branch with a live PID. Returns 1 otherwise.
# Dead-PID entries are cleaned up opportunistically.
# Arguments:
#   $1 — branch name to check
is_session_active() {
  local target_branch="$1"
  [ -z "$target_branch" ] && return 1

  local repo_root
  repo_root="$_REPO_OS_ROOT"
  local sessions_dir="$repo_root/.claude/.state/sessions"
  [ -d "$sessions_dir" ] || return 1

  local sid
  sid="$(get_session_id "$repo_root")"

  local check_file
  for check_file in "$sessions_dir"/*.yaml; do
    [ -f "$check_file" ] || continue
    local other_sid
    other_sid=$(basename "$check_file" .yaml)
    [ "$other_sid" = "$sid" ] && continue

    local other_branch
    other_branch=$(grep '^branch: ' "$check_file" 2>/dev/null | sed 's/^branch: *//')
    [ "$other_branch" = "$target_branch" ] || continue

    # Same branch — check PID liveness
    local other_pid
    other_pid=$(grep '^pid: ' "$check_file" 2>/dev/null | sed 's/^pid: *//')
    if [ -n "$other_pid" ] && ! kill -0 "$other_pid" 2>/dev/null; then
      # Dead PID — clean up opportunistically
      rm -f "$check_file" 2>/dev/null || true
      continue
    fi

    # Live session found on this branch
    return 0
  done

  return 1
}

# --- Check for concurrent session overlap on the same branch ---
# Called by write-guard.sh (Section 3) and bash-guard.sh on each Edit/Write/Bash.
# Returns: 0 = no overlap or advisory only, 2 = blocking overlap.
# Advisory for task group sharing; BLOCKING for non-task-group overlap.
# Override: REPO_OS_SKIP_OVERLAP_CHECK=1
# Exempt session types: taskdef-query, taskdef-brief (Prompt T reads only).
check_session_overlap() {
  # Override
  if [ "${REPO_OS_SKIP_OVERLAP_CHECK:-0}" = "1" ]; then
    log_override "overlap-check" "REPO_OS_SKIP_OVERLAP_CHECK"
    return 0
  fi

  # Audit C7: skip redundant checks after first successful pass (PID-bound)
  if [ "$_SESSION_OVERLAP_CHECKED" = true ] && [ "$_SESSION_OVERLAP_CHECK_PID" = "$$" ]; then
    return 0
  fi

  local repo_root
  repo_root="$_REPO_OS_ROOT"
  local sessions_dir="$repo_root/.claude/.state/sessions"
  [ -d "$sessions_dir" ] || return 0

  local sid
  sid="$(get_session_id "$repo_root")"
  local branch
  branch="$(get_branch)"

  # Get current session type
  local my_type
  my_type="$(get_session_type)"

  # Exempt session types (Prompt T — read-only, no file writes)
  case "$my_type" in
    taskdef-query|taskdef-brief) return 0 ;;
  esac

  local check_file
  for check_file in "$sessions_dir"/*.yaml; do
    [ -f "$check_file" ] || continue
    local other_sid
    other_sid=$(basename "$check_file" .yaml)
    [ "$other_sid" = "$sid" ] && continue

    local other_branch
    other_branch=$(grep '^branch: ' "$check_file" 2>/dev/null | sed 's/^branch: *//')
    [ "$other_branch" = "$branch" ] || continue

    # Same branch — check if the other session is still alive
    local other_pid
    other_pid=$(grep '^pid: ' "$check_file" 2>/dev/null | sed 's/^pid: *//')
    if [ -n "$other_pid" ] && ! kill -0 "$other_pid" 2>/dev/null; then
      # Stale entry — clean up opportunistically
      rm -f "$check_file" 2>/dev/null || true
      continue
    fi

    # Check other session type
    local other_type
    other_type=$(grep '^session_type: ' "$check_file" 2>/dev/null | sed 's/^session_type: *//')

    # Skip exempt types in the other session too
    case "$other_type" in
      taskdef-query|taskdef-brief) continue ;;
    esac

    # Task group sharing is advisory only (taskgroup and taskgroup-merge can coexist)
    if { [ "$my_type" = "taskgroup" ] || [ "$my_type" = "taskgroup-merge" ]; } && \
       { [ "$other_type" = "taskgroup" ] || [ "$other_type" = "taskgroup-merge" ]; }; then
      echo "Advisory: Task group session overlap — session $other_sid is also active on branch '$branch'." >&2
      return 0
    fi

    # Non-task-group overlap — BLOCK
    echo "BLOCKED: Session $other_sid (type: $other_type) is already active on branch '$branch'. Concurrent non-task-group sessions on the same branch are not allowed. (override: REPO_OS_SKIP_OVERLAP_CHECK=1)" >&2
    return 2
  done

  # Audit C7: cache successful check to skip redundant globs on subsequent calls
  _SESSION_OVERLAP_CHECKED=true
  _SESSION_OVERLAP_CHECK_PID="$$"
  return 0
}