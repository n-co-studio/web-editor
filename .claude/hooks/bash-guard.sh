#!/usr/bin/env bash
# Bash guard — unified Bash PreToolUse hook.
# Replaced the former branch-guard.sh — consolidates write-guard.sh (Sections
# 1-2) and branch-guard gates into a single hook for Bash calls. Eliminates
# duplicate stdin reads, JSON parses, and library sourcing that occurred when
# both hooks fired on every Bash call.
#
# Phase 3a of stop-hook optimization (exec-summary.md).
#
# Logical ordering (preserves Decision 0012 point 12):
#   1. Pre-source fast-exits (builtins only — no library sourcing)
#      a. Gate 7: Task group merge protection pattern detection
#      b. Override pre-checks (REPO_OS_SKIP_STATE_GUARD, REPO_OS_RECOVER, REPO_OS_SKIP_MODE_GUARD)
#      c. Phase 1b: Knowledge graph search advisory (Decision 0034)
#      d. Phase 1c: Daemon-safe branching guard (Decision 0036)
#      e. Phase 1e: Worktree ref-move guard (Decision 0030 — blocks git branch -f main etc. from worktrees)
#      f. Combined fast-exit: no Gate 7/daemon match AND no write patterns AND all guards skipped
#   2. Source libraries (single sourcing of _analytics-helper.sh + _phase-helper.sh)
#   3. Gate 7 enforcement (task group merge protection — Decision 0018)
#   4. Fast-exit for no-write-target Bash commands
#   5. JSON parse (single jq invocation for file_path + command)
#   6. Bash write-target scoping (exit if no in-repo write targets)
#   7. State-guard (blocks writes to .claude/.state/ and .claude/.session-id)
#   8. Mode-guard (enforces operating mode restrictions)
#   9. Branch-guard gates:
#      - Gate 1: Main branch protection
#      - Gate 2: Phase gate / plan approval
#      - Gate 6: Session overlap (Decision 0013)
#      - Gate 5: Session branch isolation (Decision 0013)
#
# Overrides (state-guard scope):
#   REPO_OS_SKIP_STATE_GUARD=1  — skip state-guard checks
#   REPO_OS_RECOVER=1           — allow recovery writes to .state/ + bypass branch-guard gates
#   .claude/.state/.recover-signal — file-based recovery (autonomous mode)
#
# Overrides (mode-guard scope):
#   REPO_OS_SKIP_MODE_GUARD=1   — skip mode-guard checks entirely
#   REPO_OS_MODE=<mode>         — force operating mode
#   REPO_OS_UNLOCK_PATH=<path>  — single-file governance unlock
#
# Overrides (branch-guard scope):
#   REPO_OS_ALLOW_MAIN=1        — allow edits on main
#   REPO_OS_SKIP_PLAN_GATE=1    — skip phase gate
#   REPO_OS_SKIP_OVERLAP_CHECK=1 — skip overlap check
#   REPO_OS_SKIP_BRANCH_REUSE=1 — skip branch isolation check
#   REPO_OS_SKIP_MERGE_GUARD=1  — skip task group merge protection gate

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ============================================================
# Phase 1: Read stdin + Pre-source fast-exits (builtins only)
# ============================================================

INPUT=$(cat)

# --- Harness session_id plumbing (must precede first get_session_id call) ---
export _REPO_OS_STDIN_SID
_REPO_OS_STDIN_SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"

# --- Override pre-checks (before sourcing — for potential fast exit) ---
SKIP_STATE_GUARD=false
_RECOVER_VIA_SIGNAL=false
RECOVER_SIGNAL_FILE="$(cd "$(dirname "$0")/../.." && pwd)/.claude/.state/.recover-signal"
if [ "${REPO_OS_SKIP_STATE_GUARD:-0}" = "1" ]; then
  SKIP_STATE_GUARD=true
fi
if [ "${REPO_OS_RECOVER:-0}" = "1" ]; then
  SKIP_STATE_GUARD=true
elif [ -f "$RECOVER_SIGNAL_FILE" ]; then
  _RECOVER_VIA_SIGNAL=true
  SKIP_STATE_GUARD=true
fi

SKIP_MODE_GUARD=false
if [ "${REPO_OS_SKIP_MODE_GUARD:-0}" = "1" ] || [ "${REPO_OS_RECOVER:-0}" = "1" ] || [ "$_RECOVER_VIA_SIGNAL" = true ]; then
  SKIP_MODE_GUARD=true
fi

# --- Gate 7: Pattern detection (builtins only — no sourcing needed) ---
# Uses [[ ]] built-in string matching: no jq, no subshells, no sourced functions.
_TG_MERGE_BLOCK=false
_TG_MERGE_REASON=""

# Inline branch detection (no sourced deps)
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

if [ "${REPO_OS_RECOVER:-0}" != "1" ] && [ "$_RECOVER_VIA_SIGNAL" != true ] && [ "${REPO_OS_SKIP_MERGE_GUARD:-0}" != "1" ]; then
  if [[ "$INPUT" == *'git checkout main'* ]] || [[ "$INPUT" == *'git switch main'* ]]; then
    if [[ "$INPUT" != *'git checkout main-'* ]] && [[ "$INPUT" != *'git checkout main/'* ]] \
    && [[ "$INPUT" != *'git switch main-'* ]] && [[ "$INPUT" != *'git switch main/'* ]]; then
      _TG_MERGE_BLOCK=true
      _TG_MERGE_REASON="checkout_main"
    fi
  fi
  if [ "$_TG_MERGE_BLOCK" = false ] && [ "$CURRENT_BRANCH" = "main" ]; then
    if [[ "$INPUT" == *'git merge'* ]] \
    && [[ "$INPUT" != *'git merge --abort'* ]] && [[ "$INPUT" != *'git merge-base'* ]]; then
      _TG_MERGE_BLOCK=true
      _TG_MERGE_REASON="merge_on_main"
    fi
  fi
fi

# --- Phase 1b: Knowledge graph search advisory (Decision 0034) ---
# Detects broad codebase searches (grep -r, find) during build phase and
# emits a one-time advisory nudging the agent to consult graph context first.
# Uses builtins + minimal file checks only (no sourcing). Advisory only.
_KG_ADVISORY_EMITTED=false
if [ "$_TG_MERGE_BLOCK" = false ]; then
  # Quick pattern match: broad search commands targeting repo root
  _IS_BROAD_SEARCH=false
  if [[ "$INPUT" == *'grep -r'* ]] || [[ "$INPUT" == *'grep -R'* ]] \
  || [[ "$INPUT" == *'grep --recursive'* ]] \
  || [[ "$INPUT" == *'find .'* ]] || [[ "$INPUT" == *'find "'* ]]; then
    _IS_BROAD_SEARCH=true
  fi
  if [ "$_IS_BROAD_SEARCH" = true ]; then
    # Check if graph context exists and advisory not yet fired (builtins + stat only)
    _HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
    _BG_REPO_ROOT="$(cd "$_HOOK_DIR/../.." && pwd)"
    _BG_STATE_DIR="$_BG_REPO_ROOT/.claude/.state"
    if [ -f "$_BG_STATE_DIR/kg-relevance-context" ] \
    && [ ! -f "$_BG_STATE_DIR/kg-search-advisory-fired" ]; then
      # Verify we're in build phase (read phase-state with builtins)
      _BG_PHASE=""
      if [ -f "$_BG_STATE_DIR/phase-state" ]; then
        while IFS= read -r _ps_line; do
          case "$_ps_line" in
            "current_phase: "*) _BG_PHASE="${_ps_line#current_phase: }"; break ;;
          esac
        done < "$_BG_STATE_DIR/phase-state"
      fi
      if [ "$_BG_PHASE" = "build" ]; then
        echo "Advisory: Broad codebase search detected. Knowledge graph context is available at .claude/.state/kg-relevance-context — check graph connections before searching." >&2
        printf 'fired\n' > "$_BG_STATE_DIR/kg-search-advisory-fired" 2>/dev/null || true
        _KG_ADVISORY_EMITTED=true
      fi
    fi
  fi
fi

# --- Phase 1c: Daemon-safe branching guard (Decision 0036) ---
# Blocks git checkout/switch/reset --hard on the main working tree when the
# automation daemon is active. File restores (git checkout -- <file>) and
# commands run from a worktree context are exempt.
_DAEMON_BRANCH_BLOCK=false
if [ "${REPO_OS_RECOVER:-0}" != "1" ] && [ "$_RECOVER_VIA_SIGNAL" != true ]; then
  _IS_BRANCH_SWITCH=false
  # Detect branch-switching patterns; exempt git checkout -- <file> (file restores)
  if [[ "$INPUT" == *'git checkout '* ]] && [[ "$INPUT" != *'git checkout -- '* ]]; then
    _IS_BRANCH_SWITCH=true
  elif [[ "$INPUT" == *'git switch '* ]]; then
    _IS_BRANCH_SWITCH=true
  elif [[ "$INPUT" == *'git reset --hard'* ]]; then
    _IS_BRANCH_SWITCH=true
  fi
  if [ "$_IS_BRANCH_SWITCH" = true ]; then
    # Exempt: command run from within a worktree context (git dir path contains "worktrees")
    _D_GIT_DIR=$(git rev-parse --git-dir 2>/dev/null || echo "")
    if [[ "$_D_GIT_DIR" != *"worktrees"* ]]; then
      # Locate repo root relative to this hook (self-referential — no sourced deps).
      # Honour the test seam (same dual-guard as _analytics-helper.sh) so the
      # daemon guard reads the sandbox's runner.pid / repo path under test mode,
      # not the real repo's (hooks always live in the real repo tree).
      _D_HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
      if [ "${REPO_OS_TEST_MODE:-0}" = "1" ] && [ -n "${_REPO_OS_TEST_ROOT:-}" ]; then
        case "$_REPO_OS_TEST_ROOT" in
          /tmp/*|/private/tmp/*) _D_REPO_ROOT="$_REPO_OS_TEST_ROOT" ;;
          *)                     _D_REPO_ROOT="$(cd "$_D_HOOK_DIR/../.." && pwd)" ;;
        esac
      else
        _D_REPO_ROOT="$(cd "$_D_HOOK_DIR/../.." && pwd)"
      fi
      _D_PID_FILE="$_D_REPO_ROOT/.claude/.automation/runner.pid"
      _DAEMON_ACTIVE=false
      # Check PID file first (no subprocess required)
      if [ -f "$_D_PID_FILE" ]; then
        _D_PID=$(cat "$_D_PID_FILE" 2>/dev/null || echo "")
        if [ -n "$_D_PID" ] && kill -0 "$_D_PID" 2>/dev/null; then
          _DAEMON_ACTIVE=true
        fi
      fi
      # Fallback: pgrep check when PID file absent or stale.
      # Repo-scoped: match only THIS repo's daemon by its absolute argv path.
      # ($_D_REPO_ROOT is a normalized cd/pwd path used as a pgrep -f regex; the
      # only realistic metachar is '.', whose any-char match is a harmless
      # over-match given the rest of the path is fully specified.)
      # queue-cli.sh launches the daemon as `nohup "$AUTOMATION_DIR/runner.sh"
      # --daemon` with AUTOMATION_DIR absolute, so the repo path is in the
      # process argv. An unscoped `runner.sh --daemon` pattern would match a
      # daemon belonging to ANY repo on the machine and false-positive-block
      # branch ops here.
      if [ "$_DAEMON_ACTIVE" = false ] && command -v pgrep >/dev/null 2>&1; then
        if pgrep -f "$_D_REPO_ROOT/.claude/.automation/runner.sh --daemon" >/dev/null 2>&1; then
          _DAEMON_ACTIVE=true
        fi
      fi
      if [ "$_DAEMON_ACTIVE" = true ]; then
        _DAEMON_BRANCH_BLOCK=true
      fi
    fi
  fi
fi

if [ "$_DAEMON_BRANCH_BLOCK" = true ]; then
  echo "GATE-RECOVERABLE: Daemon is running — halt it first (queue-cli.sh halt) or use worktree isolation. Branch switches on the main working tree corrupt active daemon sessions. (override: REPO_OS_RECOVER=1)" >&2
  exit 2
fi

# --- Phase 1e: Worktree ref-move guard (Decision 0030) ---
# Blocks git commands that move the 'main' branch ref when running from a worktree:
#   git branch -f main / --force main
#   git checkout -B main
#   git update-ref refs/heads/main
#   git fetch . <ref>:main
#
# Moving the main ref from a worktree is silent data-loss: the ref pointer
# advances to the new commit, but the main working tree's index and content
# remain frozen at the old state. 'git status' on main then shows staged
# reverts of the merged work, and merged code is absent from disk even though
# 'git log' looks correct. This is how merged governance code has been
# inactive without any alert.
#
# Correct path for worktree sessions: let session-close-check.sh (solo merge
# path) or runner.sh handle the merge via 'git -C <main-repo> merge'. Call
# write_merge_signal '<branch>' to signal that the agent close phase is done
# and let the stop hook skip a redundant merge.
#
# Exempt: main repo context (not a worktree) — those callers are already in the
# right working tree and a merge/ref-update is safe.
# Exempt: REPO_OS_RECOVER=1 recovery bypass.
if [ "${REPO_OS_RECOVER:-0}" != "1" ] && [ "$_RECOVER_VIA_SIGNAL" != true ]; then
  _WRM_DETECTED=false
  if [[ "$INPUT" == *'git branch -f main'* ]] \
  || [[ "$INPUT" == *'git branch --force main'* ]] \
  || [[ "$INPUT" == *'git checkout -B main'* ]] \
  || [[ "$INPUT" == *'git update-ref refs/heads/main'* ]]; then
    _WRM_DETECTED=true
  elif [[ "$INPUT" == *'git fetch . '* ]] && [[ "$INPUT" == *':main'* ]]; then
    _WRM_DETECTED=true
  fi
  if [ "$_WRM_DETECTED" = true ]; then
    # Reuse _D_GIT_DIR if Phase 1c already computed it; otherwise compute fresh.
    _WRM_GIT_DIR="${_D_GIT_DIR:-$(git rev-parse --git-dir 2>/dev/null || echo "")}"
    if [[ "$_WRM_GIT_DIR" == *"worktrees"* ]]; then
      echo "GATE-RECOVERABLE: Ref-move commands targeting 'main' are blocked from a worktree. Moving the main ref from a worktree leaves the main working tree stale (index/tree frozen at old state while HEAD advances — merged code is absent from disk). NEXT: Let session-close-check.sh handle the merge (solo=true is set), or use 'git -C <main-repo-path> merge <branch>' from the runner context. Call write_merge_signal '<branch>' to signal close completion. (Decision 0030; override: REPO_OS_RECOVER=1)" >&2
      exit 2
    fi
  fi
fi

# --- Write-detection pre-filter (pre-source inline copy) ---
# Returns 0 (true) if the raw input string may contain write targets; 1 otherwise.
# Canonical definition: _analytics-helper.sh::_is_bash_write_candidate(), adjacent
# to extract_write_targets(). Keep this copy byte-for-byte identical.
#
# This copy exists because the Phase 1d write-check (~line 239) and combined
# pre-source fast-exit (~line 310) run BEFORE the library sourcing at Phase 2.
# Sourcing _analytics-helper.sh here would defeat the fast-exit
# optimization (~14ms, ~56% of Bash calls). The inline copy is intentional —
# NOT a drift risk, because the canonical definition is the single place to change.
#
# Tokens tested (must match what extract_write_targets() acts on):
#   "file_path" — Edit/Write tool JSON field
#   >           — shell redirect (including >>)
#   tee         — tee pipe (tee or tee -a)
_bg_is_write_candidate() {
  local input="$1"
  [[ "$input" == *'"file_path"'* ]] || [[ "$input" == *'>'* ]] || [[ "$input" == *'tee '* ]]
}

# --- Phase 1d: Inter-session governance version check (Decision 0041) ---
# Fires on first Bash-write call of session. Predicate: governance evidence
# files exist AND embedded spec_version matches manifest.json `active`.
# Marker-first-fire: once predicate matches, marker suppresses subsequent
# runs. On predicate fail (mismatch or missing), marker is NOT written (and
# any pre-existing marker is deleted), so the warning re-surfaces on the
# next Bash-write call until the operator re-runs Prompt 0 / Prompt A.
# Advisory only — does not block. Gated to feature/fix/hotfix/release branches.
_GV_IS_WRITE=false
if _bg_is_write_candidate "$INPUT"; then
  _GV_IS_WRITE=true
fi
# Skip Phase 1d entirely on recover, taskgroup-merge block, or when jq is
# absent (the JSON parse of manifest.json is mandatory — without jq we cannot
# evaluate the predicate, so do nothing rather than risk a false-positive
# match that would suppress legitimate warnings).
if [ "$_GV_IS_WRITE" = true ] \
   && [ "$_TG_MERGE_BLOCK" = false ] \
   && [ "${REPO_OS_RECOVER:-0}" != "1" ] \
   && [ "$_RECOVER_VIA_SIGNAL" != true ] \
   && command -v jq >/dev/null 2>&1; then
  case "$CURRENT_BRANCH" in
    feature/*|fix/*|hotfix/*|release/*|live-editor-*)
      _GV_HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
      _GV_REPO_ROOT="$(cd "$_GV_HOOK_DIR/../.." && pwd)"
      _GV_STATE_DIR="$_GV_REPO_ROOT/.claude/.state"
      _GV_MARKER="$_GV_STATE_DIR/governance-bash-fired"
      if [ ! -f "$_GV_MARKER" ]; then
        _GV_MANIFEST="$_GV_REPO_ROOT/docs/spec/compiled/manifest.json"
        _GV_GOV_DIR="$_GV_REPO_ROOT/docs/ai/governance"
        _GV_ACTIVE=""
        if [ -f "$_GV_MANIFEST" ]; then
          _GV_ACTIVE=$(jq -r '.active // ""' "$_GV_MANIFEST" 2>/dev/null || echo "")
        fi
        _GV_ANY_FAIL=false
        _GV_WARN=""
        for _GV_EV in spec-compiled advisory-reviewed; do
          _GV_EVFILE="$_GV_GOV_DIR/$_GV_EV"
          if [ "$_GV_EV" = "spec-compiled" ]; then
            _GV_PROMPT="Prompt 0"
          else
            _GV_PROMPT="Prompt A"
          fi
          if [ ! -f "$_GV_EVFILE" ]; then
            _GV_WARN="${_GV_WARN}Advisory: docs/ai/governance/$_GV_EV not found — $_GV_PROMPT may not have completed governance write.\n"
            _GV_ANY_FAIL=true
            continue
          fi
          _GV_EVVER=$(awk -F': *' '
            /^spec_version:[[:space:]]*/ {
              v=$2
              gsub(/^["'\'']|["'\'']$/, "", v)
              gsub(/[[:space:]]+$/, "", v)
              if (v == "null" || v == "~") v=""
              print v
              exit
            }
          ' "$_GV_EVFILE")
          if [ "$_GV_EVVER" != "$_GV_ACTIVE" ]; then
            _GV_WARN="${_GV_WARN}Advisory: $_GV_PROMPT not re-run since spec v${_GV_EVVER:-<none>} → v${_GV_ACTIVE:-<none>} — re-run to refresh docs/ai/governance/$_GV_EV.\n"
            _GV_ANY_FAIL=true
          fi
        done
        if [ -n "$_GV_WARN" ]; then
          printf '%b' "$_GV_WARN" >&2
        fi
        if [ "$_GV_ANY_FAIL" = false ]; then
          mkdir -p "$_GV_STATE_DIR" 2>/dev/null || true
          printf 'fired\n' > "$_GV_MARKER" 2>/dev/null || true
        else
          rm -f "$_GV_MARKER" 2>/dev/null || true
        fi
      fi
      ;;
  esac
fi

# --- Combined pre-source fast-exit ---
# When no Gate 7 match AND no write patterns → exit 0 without sourcing.
# Saves ~14ms sourcing overhead for the majority of Bash calls (~56%).
if [ "$_TG_MERGE_BLOCK" = false ] && ! _bg_is_write_candidate "$INPUT"; then
  exit 0
fi

# ============================================================
# Phase 2: Source libraries (single sourcing)
# ============================================================

source "$SCRIPT_DIR/_analytics-helper.sh"
source "$SCRIPT_DIR/_phase-helper.sh"
source "$SCRIPT_DIR/_mode-guard-helper.sh"
START_MS=$(now_ms)

# Prime _CACHED_BRANCH from pre-source git rev-parse result (I1 — avoids redundant git call)
_CACHED_BRANCH="$CURRENT_BRANCH"

REPO_ROOT="$_REPO_OS_ROOT"

# Log overrides that were detected pre-source
if [ "${REPO_OS_SKIP_STATE_GUARD:-0}" = "1" ]; then
  log_override "state-guard" "REPO_OS_SKIP_STATE_GUARD"
  log_hook_event "state-guard" "PreToolUse" "Bash" "allow" "$START_MS" "skip_override"
fi
if [ "${REPO_OS_RECOVER:-0}" = "1" ]; then
  log_override "state-guard" "REPO_OS_RECOVER"
  log_hook_event "state-guard" "PreToolUse" "Bash" "allow" "$START_MS" "recovery_bypass"
  # Durable audit trail for headless/auto recovery use (security hardening).
  # Written to a TRACKED path so recovery events are visible in git history.
  # || true ensures audit write never blocks recovery.
  if [ "${CLAUDE_HEADLESS:-0}" = "1" ]; then
    _AUDIT_LOG="$REPO_ROOT/docs/ai/logs/recovery-audit.log"
    _AUDIT_CMD=$(printf '%s' "${COMMAND:-}" | head -c 60 | tr '\n' ' ')
    _AUDIT_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
    _AUDIT_SID=$(get_session_id "$REPO_ROOT" 2>/dev/null || echo "unknown")
    _AUDIT_BR=$(get_branch 2>/dev/null || echo "unknown")
    printf '%s | session=%s | branch=%s | cmd=%s\n' \
      "$_AUDIT_TS" "$_AUDIT_SID" "$_AUDIT_BR" "$_AUDIT_CMD" \
      >> "$_AUDIT_LOG" 2>/dev/null || true
  fi
fi
if [ "$_RECOVER_VIA_SIGNAL" = true ]; then
  log_override "state-guard" "recover-signal-file"
  log_hook_event "state-guard" "PreToolUse" "Bash" "allow" "$START_MS" "recovery_signal_file"
  rm -f "$RECOVER_SIGNAL_FILE"
  echo "Recovery signal consumed — bypassing state-guard and bash-guard gates" >&2
fi
if [ "${REPO_OS_SKIP_MODE_GUARD:-0}" = "1" ]; then
  log_override "mode-guard" "REPO_OS_SKIP_MODE_GUARD"
  log_hook_event "mode-guard" "PreToolUse" "Bash" "allow" "$START_MS" "skip_override"
fi

# ============================================================
# Phase 3: Ephemeral/taskdef session fast-exit (Phase 3b)
# ============================================================
# Ephemeral, taskdef-query, taskdef-brief, and queue-triage sessions skip
# mode-guard and all branch-guard gates (they operate on main by design).
# State-guard still runs (protect .claude/.state/ in all session types).
_EPHEMERAL_FAST_EXIT=false
_BG_SESSION_TYPE=$(get_session_type)
if [ "$_BG_SESSION_TYPE" = "ephemeral" ] || [ "$_BG_SESSION_TYPE" = "taskdef-query" ] || [ "$_BG_SESSION_TYPE" = "taskdef-brief" ] || [ "$_BG_SESSION_TYPE" = "queue-triage" ]; then
  _EPHEMERAL_FAST_EXIT=true
  SKIP_MODE_GUARD=true
fi

# ============================================================
# Phase 3c: Cycle cap advisory (Decision: session cycle cap)
# ============================================================
# Surface advisory when cycle count >= 5 on first Bash call of that cycle.
# Uses _load_phase_state cache populated by get_session_type above (zero forks).
# Advisory only — never blocks.
if [ "$_EPHEMERAL_FAST_EXIT" = false ] && [ -n "$_PS_CYCLE" ] && [ "$_PS_CYCLE" -ge 5 ] 2>/dev/null; then
  _cycle_marker="$(get_session_state_dir)/cycle-advisory-$_PS_CYCLE"
  if [ ! -f "$_cycle_marker" ]; then
    echo "Advisory: Session cycle count is $_PS_CYCLE (threshold: 5). Consider whether continued looping is productive." >&2
    printf '%s\n' "$_PS_CYCLE" > "$_cycle_marker" 2>/dev/null || true
  fi
fi

# ============================================================
# Phase 4: Gate 7 enforcement (uses sourced functions)
# ============================================================

if [ "$_TG_MERGE_BLOCK" = true ]; then
  _TG_PHASE=$(get_phase)
  _TG_SESSION_TYPE=$(get_session_type)
  if [ "$_TG_SESSION_TYPE" = "taskgroup" ] || [ "$_TG_SESSION_TYPE" = "taskgroup-merge" ]; then
    if [ "$_TG_PHASE" = "close" ]; then
      log_hook_event "branch-guard" "PreToolUse" "Bash" "allow" "$START_MS" "tg_merge_close_phase" "$_TG_MERGE_REASON"
    else
      log_hook_event "branch-guard" "PreToolUse" "Bash" "block" "$START_MS" "tg_merge_blocked" "$_TG_MERGE_REASON"
      echo "GATE-RECOVERABLE: Task group merge outside close phase. NEXT: Wait for close phase — merge happens automatically at session close. (override: REPO_OS_SKIP_MERGE_GUARD=1)" >&2
      exit 2
    fi
  fi
elif [ "${REPO_OS_SKIP_MERGE_GUARD:-0}" = "1" ]; then
  log_override "branch-guard" "REPO_OS_SKIP_MERGE_GUARD"
fi

# ============================================================
# Phase 5: Fast-exit for no-write-target Bash (post-sourcing)
# ============================================================
# Commands that triggered Gate 7 detection but weren't blocked land here.
if ! _bg_is_write_candidate "$INPUT"; then
  log_hook_event "bash-guard" "PreToolUse" "Bash" "allow" "$START_MS" "bash_no_write_target"
  exit 0
fi

# ============================================================
# Phase 6: JSON parse (single jq invocation)
# ============================================================

if [ "$_REPO_OS_HAS_JQ" = false ]; then
  echo "GATE-FINAL: jq is required for bash-guard but was not found." >&2
  echo "  Install jq (https://jqlang.github.io/jq/download/) and retry. (no override)" >&2
  exit 2
fi

# Single jq invocation for both fields (halves subprocess count)
_jq_out=$(echo "$INPUT" | jq -r '[.tool_input.file_path // "", .tool_input.command // ""] | join("\t")')
_TAB=$(printf '\t')
FILE_PATH="${_jq_out%%${_TAB}*}"
COMMAND="${_jq_out#*${_TAB}}"

# Cache extract_write_targets once (R11 — pure function, same input → same output)
WRITE_TARGETS=""
if [ -n "$COMMAND" ]; then
  WRITE_TARGETS=$(extract_write_targets "$COMMAND")
fi

# ============================================================
# Phase 7: Bash write-target scoping
# ============================================================
# For Bash calls: extract write targets, resolve paths, check if any are in-repo.
# If no in-repo write targets, exit 0 (no gates needed for state/mode/branch).
if [ -z "$FILE_PATH" ] && [ -n "$COMMAND" ]; then
  HAS_INREPO_WRITE=false
  while IFS= read -r WT; do
    [ -z "$WT" ] && continue
    _wt_abs=$(resolve_path "$WT")
    if is_in_repo "$_wt_abs" "$REPO_ROOT"; then
      HAS_INREPO_WRITE=true
      break
    fi
  done <<< "$WRITE_TARGETS"
  if [ "$HAS_INREPO_WRITE" = false ]; then
    log_hook_event "bash-guard" "PreToolUse" "Bash" "allow" "$START_MS" "bash_out_of_repo"
    exit 0
  fi
fi

# If neither file_path nor command, nothing to guard
if [ -z "$FILE_PATH" ] && [ -z "$COMMAND" ]; then
  exit 0
fi

# ============================================================
# Phase 8: State-Guard (blocks writes to .claude/.state/ and .claude/.session-id)
# ============================================================

if [ "$SKIP_STATE_GUARD" = false ]; then
  TARGETS_STATE=false
  STATE_TARGET_PATH=""

  if [ -n "$COMMAND" ]; then
    while IFS= read -r SG_WT; do
      [ -z "$SG_WT" ] && continue
      if [[ "$SG_WT" == *".claude/.state/"* ]] || [[ "$SG_WT" == *".claude/.session-id"* ]]; then
        _sg_abs=$(resolve_path "$SG_WT")
        if is_in_repo "$_sg_abs" "$REPO_ROOT"; then
          TARGETS_STATE=true
          STATE_TARGET_PATH="$SG_WT"
          break
        fi
      fi
    done <<< "$WRITE_TARGETS"
  fi

  # --- Indirect path construction hardening ---
  # Detect variable assignments that concatenate to form .state or .session-id paths.
  # Heuristic defense-in-depth — emits GATE-RECOVERABLE, not GATE-FINAL.
  if [ "$TARGETS_STATE" = false ] && [ -n "$COMMAND" ]; then
    if [[ "$COMMAND" =~ [A-Za-z_][A-Za-z0-9_]*=.*\.sta.*te.*\.claude ]] \
    || [[ "$COMMAND" =~ [A-Za-z_][A-Za-z0-9_]*=.*\.claude.*\.sta.*te ]] \
    || [[ "$COMMAND" =~ [A-Za-z_][A-Za-z0-9_]*=.*\.sess.*ion-id.*\.claude ]] \
    || [[ "$COMMAND" =~ [A-Za-z_][A-Za-z0-9_]*=.*\.claude.*\.sess.*ion-id ]]; then
      log_hook_event "state-guard" "PreToolUse" "Bash" "block" "$START_MS" "indirect_path_construction"
      echo "GATE-RECOVERABLE: Detected possible indirect path construction targeting .state/ or .session-id. NEXT: Use direct file paths instead of variable concatenation. (override: REPO_OS_SKIP_STATE_GUARD=1)" >&2
      exit 2
    fi
  fi

  if [ "$TARGETS_STATE" = true ]; then
    STATE_FILE_NAME="${STATE_TARGET_PATH##*.claude/.state/}"
    if [[ "$STATE_TARGET_PATH" == *".claude/.session-id"* ]]; then
      STATE_FILE_NAME=".session-id"
    fi
    log_hook_event "state-guard" "PreToolUse" "Bash" "block" "$START_MS" "state_path_protected" "" "$STATE_FILE_NAME"
    echo "GATE-FINAL: .claude/.state/ is write-protected — state files are managed by governance hooks only. (override: REPO_OS_RECOVER=1)" >&2
    exit 2
  fi
fi

# ============================================================
# Phase 9: Mode-Guard (enforces operating mode restrictions)
# ============================================================

if [ "$SKIP_MODE_GUARD" = false ]; then

  if [ -z "$COMMAND" ]; then
    # No command means nothing to check for mode-guard on Bash calls
    log_hook_event "mode-guard" "PreToolUse" "Bash" "allow" "$START_MS" "no_command"
  else
    # --- Resolve operating mode (via get_mode from _analytics-helper.sh) ---
    if [ -n "${REPO_OS_MODE:-}" ]; then
      log_override "mode-guard" "REPO_OS_MODE"
    fi
    MODE=$(get_mode)

    case "$MODE" in
      template|child|autonomous) ;;
      *)
        echo "WARNING: Unknown mode '$MODE' in .claude/repo-mode — defaulting to child" >&2
        MODE="child"
        ;;
    esac

    # --- Path helpers (make_relative, is_immune sourced from _mode-guard-helper.sh) ---

    # --- Child/autonomous mode checks ---
    # In child/autonomous modes, product code always passes. Immune paths,
    # template decisions, and non-carved-out governance paths are blocked.
    # Carved-out governance paths fall through to branch-guard.
    if [ "$MODE" != "template" ]; then
      # Immune path check on Bash write targets
      if [ -n "$COMMAND" ]; then
        while IFS= read -r MG_WT; do
          [ -z "$MG_WT" ] && continue
          MG_WT_ABS=$(resolve_path "$MG_WT")
          if is_in_repo "$MG_WT_ABS" "$REPO_ROOT"; then
            MG_WT_REL=$(make_relative "$MG_WT")
            if is_immune "$MG_WT_REL"; then
              log_hook_event "mode-guard" "PreToolUse" "Bash" "block" "$START_MS" "bash_immune_path" "" "$MG_WT_REL"
              echo "GATE-FINAL: $MG_WT_REL is an immune path — cannot be modified in any mode. (no override)" >&2
              exit 2
            fi
            # Template decision protection (Decision 0022)
            case "$MG_WT_REL" in
              docs/ai/decisions/t-*.md)
                log_hook_event "mode-guard" "PreToolUse" "Bash" "block" "$START_MS" "bash_template_decision" "" "$MG_WT_REL"
                echo "GATE-FINAL: $MG_WT_REL is a template decision (t-* prefix) — immutable in '$MODE' mode. (override: REPO_OS_UNLOCK_PATH=$MG_WT_REL or REPO_OS_SKIP_MODE_GUARD=1)" >&2
                exit 2
                ;;
            esac
            # Governance path check for child/autonomous modes (edit-time enforcement)
            if is_governance "$MG_WT_REL"; then
              if ! is_carved_out "$MODE" "$MG_WT_REL"; then
                # Check REPO_OS_UNLOCK_PATH override before blocking
                if [ -n "${REPO_OS_UNLOCK_PATH:-}" ]; then
                  _UNLOCK_REL_MG=$(make_relative "$REPO_OS_UNLOCK_PATH")
                  if [ "$MG_WT_REL" = "$_UNLOCK_REL_MG" ]; then
                    log_override "mode-guard" "REPO_OS_UNLOCK_PATH"
                    log_hook_event "mode-guard" "PreToolUse" "Bash" "allow" "$START_MS" "unlock_path" "" "$MG_WT_REL"
                    exit 0
                  fi
                fi
                log_hook_event "mode-guard" "PreToolUse" "Bash" "block" "$START_MS" "bash_governance_${MODE}" "" "$MG_WT_REL"
                echo "GATE-FINAL: $MG_WT_REL is a governance path — not editable in '$MODE' mode (override: REPO_OS_UNLOCK_PATH=$MG_WT_REL or REPO_OS_SKIP_MODE_GUARD=1)" >&2
                exit 2
              fi
              # Governance AND carved out — fall through
            fi
          fi
        done <<< "$WRITE_TARGETS"
      fi
      log_hook_event "mode-guard" "PreToolUse" "Bash" "allow" "$START_MS" "fast_exit_${MODE}"
    else
      # Template mode — full path classification
      # (is_governance, is_carved_out sourced from _mode-guard-helper.sh)

      check_path() {
        local rel="$1" context="$2"
        # Immune check first — unconditional, no override (structural anchor)
        if is_immune "$rel"; then
          log_hook_event "mode-guard" "PreToolUse" "Bash" "block" "$START_MS" "${context}_immune_path" "" "$rel"
          echo "GATE-FINAL: $rel is an immune path — cannot be modified in any mode. (no override)" >&2
          exit 2
        fi
        # Belt-and-suspenders: unresolved shell variable — cannot classify, fail-closed.
        # The caller loop catches this first; this handles any path that slips through.
        if has_unresolved_var "$rel"; then
          log_hook_event "mode-guard" "PreToolUse" "Bash" "block" "$START_MS" "${context}_unresolved_var" "" "$rel"
          echo "GATE-RECOVERABLE: write target '$rel' contains an unresolved shell variable — the mode guard cannot determine the target location. Use a literal path instead. (override: REPO_OS_SKIP_MODE_GUARD=1)" >&2
          exit 2
        fi
        # Belt-and-suspenders: absolute path outside repo — no mode-guard jurisdiction.
        if is_out_of_repo "$rel"; then
          log_hook_event "mode-guard" "PreToolUse" "Bash" "allow" "$START_MS" "${context}_out_of_repo_bs" "" "$rel"
          return 0
        fi
        if [ -n "${REPO_OS_UNLOCK_PATH:-}" ]; then
          UNLOCK_REL=$(make_relative "$REPO_OS_UNLOCK_PATH")
          if [ "$rel" = "$UNLOCK_REL" ]; then
            log_override "mode-guard" "REPO_OS_UNLOCK_PATH"
            log_hook_event "mode-guard" "PreToolUse" "Bash" "allow" "$START_MS" "unlock_path" "" "$rel"
            return 0
          fi
        fi
        if is_governance "$rel"; then
          if ! is_carved_out "$MODE" "$rel"; then
            log_hook_event "mode-guard" "PreToolUse" "Bash" "block" "$START_MS" "${context}_governance_${MODE}" "" "$rel"
            echo "GATE-RECOVERABLE: $rel is a governance path — not editable in '$MODE' mode. NEXT: Switch to a mode that allows this path, or unlock it. (override: REPO_OS_UNLOCK_PATH=$rel or REPO_OS_SKIP_MODE_GUARD=1)" >&2
            exit 2
          fi
        else
          if [ "$MODE" = "template" ]; then
            log_hook_event "mode-guard" "PreToolUse" "Bash" "block" "$START_MS" "${context}_product_in_template" "" "$rel"
            echo "GATE-RECOVERABLE: $rel is a product path — not editable in 'template' mode. NEXT: Use child or autonomous mode for product code. (override: REPO_OS_SKIP_MODE_GUARD=1)" >&2
            exit 2
          fi
        fi
      }

      ALLOW_PATH=""
      if [ -n "$COMMAND" ]; then
        while IFS= read -r MG_WT; do
          [ -z "$MG_WT" ] && continue
          # Sub-case 2: unresolved shell variable — cannot classify, fail-closed.
          # Must check before resolve_path, which would misinterpret $VAR as relative.
          if has_unresolved_var "$MG_WT"; then
            log_hook_event "mode-guard" "PreToolUse" "Bash" "block" "$START_MS" "bash_unresolved_var" "" "$MG_WT"
            echo "GATE-RECOVERABLE: write target '$MG_WT' contains an unresolved shell variable — the mode guard cannot determine the target location. Use a literal path instead. (override: REPO_OS_SKIP_MODE_GUARD=1)" >&2
            exit 2
          fi
          MG_WT_ABS=$(resolve_path "$MG_WT")
          # Sub-case 1: path outside repo — no mode-guard jurisdiction; log and skip.
          if ! is_in_repo "$MG_WT_ABS" "$REPO_ROOT"; then
            log_hook_event "mode-guard" "PreToolUse" "Bash" "allow" "$START_MS" "bash_out_of_repo_skip" "" "$MG_WT"
            continue
          fi
          MG_WT_REL=$(make_relative "$MG_WT")
          [ -z "$ALLOW_PATH" ] && ALLOW_PATH="$MG_WT_REL"
          check_path "$MG_WT_REL" "bash"
        done <<< "$WRITE_TARGETS"
      fi

      log_hook_event "mode-guard" "PreToolUse" "Bash" "allow" "$START_MS" "pass_${MODE}" "" "$ALLOW_PATH"
    fi
  fi
fi  # end SKIP_MODE_GUARD

# ============================================================
# Phase 10: Branch-Guard Gates
# ============================================================

# Ephemeral sessions skip all branch-guard gates (Phase 3b)
if [ "$_EPHEMERAL_FAST_EXIT" = true ]; then
  log_hook_event "bash-guard" "PreToolUse" "Bash" "allow" "$START_MS" "ephemeral_skip_branch_guard"
  exit 0
fi

# --- REPO_OS_RECOVER override (bypass all branch-guard gates) ---
if [ "${REPO_OS_RECOVER:-0}" = "1" ] || [ "$_RECOVER_VIA_SIGNAL" = true ]; then
  if [ "${REPO_OS_RECOVER:-0}" = "1" ]; then
    log_override "branch-guard" "REPO_OS_RECOVER"
  else
    log_override "branch-guard" "recover-signal-file"
  fi
  log_hook_event "branch-guard" "PreToolUse" "Bash" "allow" "$START_MS" "recovery_bypass"
  echo "Recovery mode — bypassing bash-guard gates" >&2
  exit 0
fi

# --- Gate 1: Main branch protection ---
ALLOW_REASON="pass"
if [ "$CURRENT_BRANCH" = "main" ] && [ "${REPO_OS_ALLOW_MAIN:-0}" != "1" ]; then
  log_hook_event "branch-guard" "PreToolUse" "Bash" "block" "$START_MS" "main_branch"
  echo "GATE-RECOVERABLE: On main branch. NEXT: Create a feature branch with git checkout -b feature/<description>. (override: REPO_OS_ALLOW_MAIN=1)" >&2
  exit 2
fi
if [ "$CURRENT_BRANCH" = "main" ] && [ "${REPO_OS_ALLOW_MAIN:-0}" = "1" ]; then
  log_override "branch-guard" "REPO_OS_ALLOW_MAIN"
  ALLOW_REASON="main_override"
fi

# --- Gate 2: Phase gate / plan approval (blocking) ---
# Provenance note (Decision 0038): the `plan-approved` state file may be written
# by either plan-approval.sh (legacy AskUserQuestion path) or by drift_check
# from a valid handoff bundle (bundle path). Both write the same schema with a
# matching session_id, so this gate's presence check covers both provenances
# uniformly — no code change needed here.
if [ "$ALLOW_REASON" = "pass" ]; then
  if [[ "$CURRENT_BRANCH" == experiment/* ]]; then
    ALLOW_REASON="experiment_branch"
  elif [[ -n "$FILE_PATH" && "$FILE_PATH" == "$REPO_ROOT/.claude/.state/"* ]]; then
    ALLOW_REASON="state_file_exempt"
  elif [[ -n "$FILE_PATH" && "$FILE_PATH" == "$REPO_ROOT/.claude/local/"* ]]; then
    ALLOW_REASON="local_file_exempt"
  elif [[ -n "$FILE_PATH" && "$FILE_PATH" == "$REPO_ROOT/docs/ai/governance/"* ]]; then
    ALLOW_REASON="governance_exempt"
  elif [[ -n "$FILE_PATH" && "$FILE_PATH" == "$REPO_ROOT/docs/ai/task-groups/"* ]]; then
    ALLOW_REASON="task_group_path_exempt"
  elif [ "${REPO_OS_SKIP_PLAN_GATE:-0}" = "1" ]; then
    log_override "branch-guard" "REPO_OS_SKIP_PLAN_GATE"
    ALLOW_REASON="plan_gate_override"
  else
    CURRENT_PHASE=$(get_phase)
    if [ -n "$CURRENT_PHASE" ]; then
      SESSION_TYPE=$(get_session_type)
      if has_plan_gate "$SESSION_TYPE"; then
        if assert_phase "build"; then
          ALLOW_REASON="phase_gate_pass"
        else
          log_hook_event "branch-guard" "PreToolUse" "Bash" "block" "$START_MS" "phase_gate" "phase:$CURRENT_PHASE"
          # R13 diagnostic: distinguish "hook didn't fire" from "approval not given".
          # When phase is plan/approval but plan-approved file is absent, the
          # plan-approval.sh PostToolUse hook likely failed to fire after
          # AskUserQuestion (known VS Code extension issue — see R13).
          if [ "$CURRENT_PHASE" = "drift-check" ]; then
            # Decision 0038: drift-check phase must call drift_check before
            # any Bash writes that aren't path-exempt. Direct the agent to
            # the bundle path, not the legacy AskUserQuestion flow.
            echo "GATE-RECOVERABLE: Session in 'drift-check' phase — Bash writes blocked. NEXT: source .claude/hooks/_analytics-helper.sh and _phase-helper.sh, then call drift_check. On return 0: advance_phase \"build\" (skips plan/approval). On non-zero return: advance_phase \"plan\" and use the legacy AskUserQuestion flow. (override: REPO_OS_SKIP_PLAN_GATE=1)" >&2
          elif [ ! -f "$(get_session_state_dir)/plan-approved" ] && \
             { [ "$CURRENT_PHASE" = "plan" ] || [ "$CURRENT_PHASE" = "approval" ]; }; then
            echo "GATE-RECOVERABLE: Session in '$CURRENT_PHASE' phase and plan-approved state file is missing — plan-approval.sh hook may not have fired after AskUserQuestion (see known-issues.md R13). NEXT: Create recovery signal (touch .claude/.state/.recover-signal) or set REPO_OS_SKIP_PLAN_GATE=1." >&2
          else
            echo "GATE-RECOVERABLE: Session in '$CURRENT_PHASE' phase — Bash writes blocked until plan approved. NEXT: Call AskUserQuestion with your plan summary. Include options: \"Auto — proceed autonomously\" and \"Review — pause for my review before commit\". Conversational confirmation does NOT trigger the approval hook. (override: REPO_OS_SKIP_PLAN_GATE=1)" >&2
          fi
          exit 2
        fi
      else
        ALLOW_REASON="session_type_no_plan_gate"
      fi
    else
      if [ -f "$REPO_ROOT/docs/ai/decisions/.fail-closed-enforced" ]; then
        log_hook_event "branch-guard" "PreToolUse" "Bash" "block" "$START_MS" "phase_gate_no_state"
        echo "GATE-RECOVERABLE: No phase-state — session not initialized. NEXT: Call init_phase() via the orchestrator to initialize the session. (override: REPO_OS_SKIP_PLAN_GATE=1)" >&2
        exit 2
      else
        log_hook_event "branch-guard" "PreToolUse" "Bash" "warn" "$START_MS" "phase_gate_no_state_advisory"
        echo "Advisory: No phase-state found — session may not be initialized. Consider calling init_phase() via the orchestrator." >&2
        ALLOW_REASON="no_phase_state"
      fi
    fi
  fi
fi

# --- Gate 2b: Taskgroup brief mismatch check (Decision 0026) ---
# Blocks if brief contains ### Task Group but session type is not taskgroup/taskgroup-merge.
check_taskgroup_brief_mismatch "$START_MS"

# --- Gates 5 + 6: Session overlap + branch isolation (Decision 0013) ---
# Decision 0042: read pre-computed verdicts from <state_dir>/phase-state.gates
# when the cache is fresh. Cache miss falls through to inline checks. Override
# env vars are checked first in each branch (overrides are per-invocation policy).
_GATES_CACHE_HIT=0
if [ "${REPO_OS_SKIP_OVERLAP_CHECK:-0}" != "1" ] || [ "${REPO_OS_SKIP_BRANCH_REUSE:-0}" != "1" ]; then
  if read_phase_gates; then
    _GATES_CACHE_HIT=1
  fi
fi

# --- Gate 6: Session overlap check (Decision 0013) ---
if [ "$_GATES_CACHE_HIT" = "1" ]; then
  if [ "${REPO_OS_SKIP_OVERLAP_CHECK:-0}" = "1" ]; then
    log_override "branch-guard" "REPO_OS_SKIP_OVERLAP_CHECK"
  elif [ "$GATES_SESSION_OVERLAP" = "blocked" ]; then
    [ -n "$GATES_SESSION_OVERLAP_DETAIL" ] && echo "$GATES_SESSION_OVERLAP_DETAIL" >&2
    log_hook_event "branch-guard" "PreToolUse" "Bash" "block" "$START_MS" "session_overlap" "cache:hit"
    exit 2
  elif [ "$GATES_SESSION_OVERLAP" = "advisory" ] && [ -n "$GATES_SESSION_OVERLAP_DETAIL" ]; then
    # Surface advisory message — parity with check_session_overlap inline path.
    echo "$GATES_SESSION_OVERLAP_DETAIL" >&2
  fi
else
  if ! check_session_overlap; then
    log_hook_event "branch-guard" "PreToolUse" "Bash" "block" "$START_MS" "session_overlap"
    exit 2
  fi
fi

# --- Gate 5: Session branch isolation (Decision 0013) ---
if [ "$_GATES_CACHE_HIT" = "1" ]; then
  if [ "$GATES_BRANCH_ISOLATION" = "blocked" ]; then
    if [ "${REPO_OS_SKIP_BRANCH_REUSE:-0}" = "1" ]; then
      log_override "branch-guard" "REPO_OS_SKIP_BRANCH_REUSE"
    else
      log_hook_event "branch-guard" "PreToolUse" "Bash" "block" "$START_MS" "branch_reused" "cache:hit"
      echo "GATE-RECOVERABLE: Branch '$CURRENT_BRANCH' sealed by a previous session. NEXT: Create a new branch with git checkout -b <category>/<description>. (override: REPO_OS_SKIP_BRANCH_REUSE=1)" >&2
      exit 2
    fi
  fi
else
  CLOSED_BRANCHES_FILE="$REPO_ROOT/.claude/local/closed-branches"
  if [ -f "$CLOSED_BRANCHES_FILE" ] && grep -qxF "$CURRENT_BRANCH" "$CLOSED_BRANCHES_FILE" 2>/dev/null; then
    if [ "${REPO_OS_SKIP_BRANCH_REUSE:-0}" = "1" ]; then
      log_override "branch-guard" "REPO_OS_SKIP_BRANCH_REUSE"
    else
      log_hook_event "branch-guard" "PreToolUse" "Bash" "block" "$START_MS" "branch_reused"
      echo "GATE-RECOVERABLE: Branch '$CURRENT_BRANCH' sealed by a previous session. NEXT: Create a new branch with git checkout -b <category>/<description>. (override: REPO_OS_SKIP_BRANCH_REUSE=1)" >&2
      exit 2
    fi
  fi
fi

log_hook_event "bash-guard" "PreToolUse" "Bash" "allow" "$START_MS" "$ALLOW_REASON"
exit 0
