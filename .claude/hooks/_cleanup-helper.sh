#!/usr/bin/env bash
# Shared cleanup helper — session state file cleanup and branch sealing.
# Sourced by session-close-check.sh and runner.sh.
# Extracted to eliminate duplicate cleanup logic (audit finding C5).
#
# Depends on (must be sourced before this file):
#   _analytics-helper.sh — get_repo_root, get_session_type, get_branch,
#                           unregister_session, cleanup_old_analytics,
#                           is_session_active
#
# ## Consumers (auto-generated — run .claude/tools/hook-dep-map.sh for live data)
#   Hooks: session-close-check
#   Automation: runner.sh, queue-cli.sh, intake.sh

# --- The session's evidence set (known-issue R40) ---
# Every per-session governance verdict and gate marker, in ONE place, because it
# has two consumers that must not drift apart:
#
#   1. cleanup_session_files() below, at session close.
#   2. init_phase() in _phase-helper.sh, on an authorised same-session re-init.
#
# Consumer 2 is why this list exists. init_phase used to rewrite phase-state and
# remove NOTHING, so a second work unit in one session inherited the first's
# approvals — same session_id, valid dispatch_phase, every commit-gate check
# satisfied. Two work units were gated on one unit's verdicts before this was
# found, and it reproduced twice while being fixed.
#
# NOT in this list, deliberately: phase-state, phase-state.gates and
# session-resume.yaml. Close deletes those too, but a re-init must not: clearing
# them would either be redundant or destroy the state the re-init is building.
# They stay as explicit calls in close.
#
# Precisely, because an earlier draft of this comment said init_phase "rewrites
# all three" and that is only true of a re-init that SUCCEEDS: phase-state is
# rewritten early, while write_resume_marker and compute_phase_gates run near
# the end of init_phase, after the ancestry check's `return 1` paths. A re-init
# that fails there leaves phase-state.gates and session-resume.yaml holding the
# previous unit's contents. Neither carries an approval — the gates file holds
# branch and overlap verdicts — so this is a staleness wart, not an inheritance
# hole, but it is not what "rewrites all three" implies.
#
# criteria-verdicts.yaml IS here. t-0048 keeps it out of the evidence MANIFEST
# (manifest entries read as integrity tracking and that sidecar is advisory),
# which is a different question from whether a new work unit should inherit it —
# it should not. An earlier write-up of R40 confused the two and said t-0048
# required excluding it; that was wrong and is corrected in the entry.
#
# Order is irrelevant: every entry is an independent _delete_if_owned.
_SESSION_EVIDENCE_FILES="plan-approved pragmatist-signed cohesion-reviewed diff-review-complete qa-verified reviewer-signed security-signed functional-verified kg-updated criteria-verdicts.yaml"

# --- Clear this session's evidence (known-issue R40) ---
# Removes only files this session owns, via _delete_if_owned, and logs each one
# WITH its verdict. The log matters: a re-init silently erasing a
# `GATE_RESULT: BLOCKED` would leave no trace otherwise, since compare_manifest
# is advisory and the re-init re-baselines the manifest a moment later. An
# erased block is a self-inflicted re-review, not a bypass — the gates treat an
# absent verdict file as blocking — but it should still be visible.
#
# Arguments:
#   $1 — state directory
#   $2 — session id that owns the clear
# Always returns 0: a failed clear must not abort init.
# _is_prewritten_evidence <file> — 0 when the file was placed there legitimately
# BEFORE this session's agent ran, rather than earned by it.
#
# Three writers do this, and all of them are the reason a first init must not
# clear indiscriminately:
#   state-manager.sh      plan-approved      `source: runner` / `runner-auto`
#   _headless-plan-approve.sh                `question_hash: headless-runner`
#   _phase-helper.sh      plan-approved AND pragmatist-signed via a handoff
#                                            bundle: `source: handoff-bundle`
#
# The runner pre-writes plan-approved precisely so the hooks do not block, and
# state-manager.sh states that phase-state is NOT pre-seeded — the agent calls
# init_phase itself. So for every daemon-run and task-group brief, the agent's
# init IS a first init with a pre-written approval already on disk. Clearing it
# would strand the brief at "plan-approved missing", which is exactly how brief
# 2+ of every task group stalled earlier this month.
#
# Matched per FILE rather than by filename, because the handoff bundle writes
# pragmatist-signed the same way; a filename allowlist would have missed it.
_is_prewritten_evidence() {
  local file="$1"
  [ -f "$file" ] || return 1
  grep -qE '^(source: (runner|handoff-bundle)|question_hash: (runner-auto|headless-runner))$' \
    "$file" 2>/dev/null
}

# clear_session_evidence <state_dir> <sid> [scope]
#
# scope:
#   all                (default) clear every owned evidence file. Used by an
#                      authorised same-session re-init, where the previous work
#                      unit's approvals must not carry into the next one.
#   preserve-prewrites clear owned evidence EXCEPT files a runner or handoff
#                      bundle legitimately placed before the agent ran. Used by
#                      a first init, where leftover verdicts from a close that
#                      never ran should go but the brief's own pre-approval
#                      must survive.
clear_session_evidence() {
  local state_dir="$1"
  local sid="$2"
  local scope="${3:-all}"
  [ -n "$state_dir" ] || return 0
  [ -d "$state_dir" ] || return 0

  local file verdict cleared="" skipped="" preserved=""
  for file in $_SESSION_EVIDENCE_FILES; do
    [ -f "$state_dir/$file" ] || continue
    if [ "$scope" = "preserve-prewrites" ] && _is_prewritten_evidence "$state_dir/$file"; then
      preserved="${preserved}${file} "
      continue
    fi
    # Captured BEFORE deletion, and tolerant of files that carry no verdict
    # line (kg-updated uses `result:`, the sidecar carries neither).
    verdict=$(grep -h '^GATE_RESULT:' "$state_dir/$file" 2>/dev/null | head -1 | sed 's/^GATE_RESULT: *//' || true)
    [ -n "$verdict" ] || verdict="no-verdict-line"
    if _delete_if_owned "$state_dir/$file" "$sid" && [ ! -f "$state_dir/$file" ]; then
      cleared="${cleared}${file}=${verdict} "
    else
      # Still present after the attempt. The usual cause is the one worth
      # reporting — _delete_if_owned found a DIFFERENT session_id and correctly
      # refused, because one session must not delete another's evidence — but it
      # is NOT the only cause, so neither the label nor the message claims it is:
      # an unwritable state directory, or a session_id value carrying a trailing
      # space or CR, lands here too. _delete_if_owned compares the raw field
      # while the commit gate normalises with `tr -d '[:space:]'`, so a whitespace
      # difference can make this refuse a file the gate accepts as ours.
      #
      # Whether the next unit actually INHERITS the file depends on the gate, not
      # on this clear: the gate validates against its own resolved id, so it
      # rejects a genuinely foreign file as stale. The inheritance case is the
      # narrow one where the gate's id matches the file and init's id does not —
      # the daemon session-id cache disagreement this repo has seen before. So
      # the message says "may be inherited", not "would be".
      skipped="${skipped}${file}=${verdict} "
    fi
  done

  if [ -n "$preserved" ]; then
    # Not a warning: this is the runner's or the handoff bundle's own pre-write
    # doing its job. Logged so a brief that later fails a plan gate can be told
    # apart from one whose approval was cleared out from under it.
    log_hook_event "clear-session-evidence" "init_phase" "" "allow" "0" "prewritten_evidence_preserved" "$preserved" 2>/dev/null || true
  fi
  # The two scopes are named apart in both the message and the event. They were
  # not: a first-init clear announced itself as a re-init and logged
  # `reinit_cleared`, so nothing downstream could tell "a second work unit
  # re-earns its approvals" from "a stale verdict was swept before a fresh
  # session started" — two different things to read in an audit.
  local _cse_what="re-init" _cse_reason="reinit_cleared"
  if [ "$scope" = "preserve-prewrites" ]; then
    _cse_what="first init"; _cse_reason="first_init_cleared"
  fi
  if [ -n "$cleared" ]; then
    echo "WARNING: $_cse_what cleared this session's governance evidence — this work unit must earn its own: $cleared" >&2
    log_hook_event "clear-session-evidence" "init_phase" "" "allow" "0" "$_cse_reason" "$cleared" 2>/dev/null || true
  fi
  if [ -n "$skipped" ]; then
    # Deliberately NOT "GATE-RECOVERABLE", and the event outcome is not "block":
    # this path blocks nothing — clear_session_evidence always returns 0 and
    # init_phase continues. In this repo that token and that outcome accompany an
    # actual refusal (hooks block on exit 2 only), so using them here would both
    # mislead a reader and break the pairing with the real blocking events.
    echo "WARNING: re-init could NOT clear some evidence — most likely it records a different session_id, which _delete_if_owned correctly refuses to delete. Whether the next work unit inherits it depends on which id the commit gate resolves; it may be inherited. NEXT: inspect $state_dir and remove the stale files by hand if they are not another live session's. Files: $skipped" >&2
    log_hook_event "clear-session-evidence" "init_phase" "" "advisory" "0" "reinit_evidence_not_cleared" "$skipped" 2>/dev/null || true
  fi
  return 0
}

# --- Session-bound file deletion helper ---
# Reads session_id from a state file. If the field exists and does NOT match
# the closing session's ID, the file is skipped (owned by another session).
# If the field is absent or matches, the file is deleted.
# Arguments:
#   $1 — file path
#   $2 — closing session ID
_delete_if_owned() {
  local file="$1"
  local closing_sid="$2"
  [ -f "$file" ] || return 0
  if [ -n "$closing_sid" ]; then
    local file_sid
    # set -euo pipefail safe (P1): grep exits 1 on no-match; with pipefail the
    # command-substitution assignment propagates that 1 and trips set -e,
    # aborting the close hook for any state file that lacks a session_id: line
    # (e.g. phase-state.gates, which uses GATES_SESSION_ID=). `|| true` absorbs
    # the no-match exit so the GATES_SESSION_ID fallback below stays reachable.
    # Normalised exactly as _validate_state_session_id in pre-commit-gates.sh
    # does — including its `head -1`, which is a no-op there and here because
    # `tr -d '[:space:]'` has already removed the newlines (two session_id lines
    # concatenate into one token that matches nothing, so such a file is kept).
    # It is copied rather than tidied so the two cannot drift.
    # Without the `tr -d` the raw field
    # keeps a trailing space or CR and a file the GATE treats as this session's
    # own is refused here as another session's — so close would leave it behind
    # and a re-init would report it as unclearable, both for a reason that is not
    # true. The gate is the reference for what "owned by this session" means;
    # this must not disagree with it.
    file_sid=$(grep '^session_id:' "$file" 2>/dev/null | sed 's/^session_id: *//' | tr -d '[:space:]' | head -1 || true)
    # Decision 0042: phase-state.gates uses shell-sourceable KEY=VALUE format.
    # Fall back to the GATES_SESSION_ID='<sid>' line when the YAML field is absent.
    if [ -z "$file_sid" ]; then
      file_sid=$(grep "^GATES_SESSION_ID=" "$file" 2>/dev/null | sed -E "s/^GATES_SESSION_ID='?([^']*)'?$/\1/" || true)
    fi
    if [ -n "$file_sid" ] && [ "$file_sid" != "$closing_sid" ]; then
      # Owned by another session — skip
      return 0
    fi
  fi
  rm -f "$file"
}

# --- Clean all session-scoped state files ---
# Removes governance state, phase state, and session markers.
# Session-bind guard (Decision 0013): files containing a session_id field
# are only deleted if that ID matches the closing session. Files without
# session_id (or when closing_sid is empty) are deleted unconditionally.
# Arguments:
#   $1 — repo_root (absolute path)
#   $2 — close_stype (session type captured before phase-state deletion)
#   $3 — closing_sid (session ID of the closing session; optional for backward compat)
#   $4 — is_closing (true|false, default true). When false, identity files
#         (.session-id, .session-type) are preserved — used by pause Stop paths
#         to keep session identity stable across turns (belt-and-suspenders with
#         the pause guard in session-close-check.sh).
cleanup_session_files() {
  local repo_root="$1"
  local close_stype="${2:-}"
  local closing_sid="${3:-}"
  local is_closing="${4:-true}"

  # Clean session-scoped marker files (no session_id field — unconditional)
  rm -f "$repo_root/.claude/.hvst-fail-count"
  rm -f "$repo_root/.claude/.deferrals-pending"
  cleanup_old_analytics "$repo_root"

  # Session-bound identity files: only delete if content matches closing session
  # AND the caller has confirmed this is a genuine close (not a pause Stop).
  # Sessions with REPO_OS_SESSION_ID (worktree/daemon) use env var, not file (Decision 0030)
  if [ -n "${REPO_OS_SESSION_ID:-}" ]; then
    : # No .session-id file to delete — identity is via REPO_OS_SESSION_ID env var
  elif [ "$is_closing" = "false" ]; then
    : # Pause Stop — preserve identity files to keep session stable across turns
  elif [ -n "$closing_sid" ]; then
    local sid_file="$repo_root/.claude/.session-id"
    local sid_was_ours=false
    if [ -f "$sid_file" ]; then
      local file_content
      file_content=$(cat "$sid_file" 2>/dev/null)
      if [ "$file_content" = "$closing_sid" ]; then
        rm -f "$sid_file"
        sid_was_ours=true
      fi
    fi
    local stype_file="$repo_root/.claude/.session-type"
    if [ -f "$stype_file" ] && [ "$sid_was_ours" = true ]; then
      # .session-type has no session_id field — only delete if we confirmed
      # .session-id ownership above (sid_was_ours flag). This avoids deleting
      # .session-type when .session-id was absent at entry (not ours to infer).
      rm -f "$stype_file"
    fi
  else
    # No closing_sid — unconditional (backward compat)
    rm -f "$repo_root/.claude/.session-id"
    rm -f "$repo_root/.claude/.session-type"
  fi

  # Clean governance state files (session-scoped — Decision 0030)
  local state_dir
  state_dir="$(get_session_state_dir)"
  if [ -d "$state_dir" ]; then
    # Session-bound files: check session_id before deleting.
    # The evidence set is the shared list, so close and re-init cannot drift
    # apart (known-issue R40). phase-state, phase-state.gates and
    # session-resume.yaml are NOT in it: init_phase rewrites all three, so a
    # re-init must not clear them, while close must.
    local _csf_file
    for _csf_file in $_SESSION_EVIDENCE_FILES; do
      _delete_if_owned "$state_dir/$_csf_file" "$closing_sid"
    done
    _delete_if_owned "$state_dir/phase-state" "$closing_sid"
    _delete_if_owned "$state_dir/phase-state.gates" "$closing_sid"

    # Non-session-bound files: unconditional delete.
    # governance-checked and high-risk-detected are idempotent commit-gate
    # markers (re-created on each gate run). No session_id field — concurrent
    # deletion is benign because the gate re-checks on the next commit attempt.
    rm -f "$state_dir/scope-risk-gain"
    rm -f "$state_dir/high-risk-detected"
    rm -f "$state_dir/mechanism-change-detected"
    rm -f "$state_dir/governance-checked"
    rm -f "$state_dir/governance-bash-fired"
    rm -f "$state_dir/overrides.log"
    rm -f "$repo_root/.claude/local/task-contract.yaml"
    rm -f "$state_dir/merge-source-branch"
    rm -f "$state_dir/.stop-attempt-count"
    rm -f "$state_dir/brief-has-taskgroup"
    rm -f "$state_dir/cycle-escalation"
    rm -f "$state_dir"/cycle-advisory-*
    rm -f "$state_dir/finish-loop-cache.yaml"
    rm -f "$repo_root/.claude/.state/kg-relevance-context"
    rm -f "$repo_root/.claude/.state/kg-search-advisory-fired"
    rm -f "$repo_root/.claude/.state/cross-session-context"
    _delete_if_owned "$state_dir/session-resume.yaml" "$closing_sid"

    # Remove per-session state directory if now empty (all sessions use per-session dirs)
    # Only rmdir if it's a per-session subdir, not the flat .claude/.state/ root
    case "$state_dir" in
      */wt-sessions/*)
        rmdir "$state_dir" 2>/dev/null || true
        ;;
    esac
  fi

  # Clean completion markers when merge brief closes (parallel groups).
  # P2: kept OUTSIDE the `[ -d "$state_dir" ]` gate above — these markers are
  # cross-session (written by content briefs into THEIR per-session dirs) and
  # clean_cross_session_markers scans every per-session dir itself; it has no
  # dependency on the closing session's own state_dir. Gating it on the closing
  # session's state_dir was a latent bug: when state_dir mis-resolves (identity
  # file already deleted above and no env/stdin id to re-resolve from), the
  # markers in other sessions' dirs would survive. Delta files (Decision 0034
  # Amendment 5) are likewise cross-session — content briefs write per-brief
  # deltas to the shared state path, the merge brief aggregates them. Clean both
  # classes after aggregation has been applied (the merge brief is closing —
  # aggregation already ran during its close phase or was attempted and logged).
  if [ "$close_stype" = "taskgroup-merge" ]; then
    clean_cross_session_markers "tg-*-brief-*.complete"
    clean_cross_session_markers "tg-*-brief-*.kg-delta.yaml"
    rm -f "$repo_root/.claude/.state/kg-aggregation-conflicts.log"
  fi

  # P3: cleanup is best-effort — return success explicitly so a falsey trailing
  # command (e.g. a no-match `[ -d ]` test) cannot propagate rc=1 to the close
  # hook under set -euo pipefail.
  return 0
}

# --- Record closed branch (Decision 0013: session isolation) ---
# Accepts an optional branch argument; if omitted, reads HEAD.
# Appends branch to closed-branches ledger so future sessions can't reuse it.
# Skips main (protected by write-guard/bash-guard Gate 1 separately).
# Idempotent: won't add duplicate entries.
# Arguments:
#   $1 — branch name (optional; defaults to current branch via get_branch)
record_closed_branch() {
  local branch="${1:-}"
  if [ -z "$branch" ]; then
    branch=$(get_branch)
  fi
  [ -z "$branch" ] && return
  [ "$branch" = "main" ] && return
  local repo_root
  repo_root="$(get_repo_root)"
  local closed_file="$repo_root/.claude/local/closed-branches"
  mkdir -p "$(dirname "$closed_file")" 2>/dev/null || true

  # Atomic append under lock (Decision 0030: concurrent worktree close safety)
  local lock_file="$repo_root/.claude/.state/.closed-branches-lock"
  mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true
  if command -v flock > /dev/null 2>&1; then
    (
      flock -w 5 9 2>/dev/null || true
      if ! grep -qxF "$branch" "$closed_file" 2>/dev/null; then
        echo "$branch" >> "$closed_file"
      fi
    ) 9>"$lock_file"
  else
    # No flock — best-effort (existing behavior preserved)
    if ! grep -qxF "$branch" "$closed_file" 2>/dev/null; then
      echo "$branch" >> "$closed_file"
    fi
  fi
}

# --- Delete a merged session branch (Decision 0045) ---
# Close cleanup: once a session branch has been merged to main AND recorded in
# the closed-branches ledger, delete the now-redundant local branch ref so
# branches do not accumulate. Uses `git branch -d` (merged-only — never force)
# so an unmerged branch is never deleted; a no-op if the branch is the current
# HEAD or not fully merged. An `git merge-base --is-ancestor` precheck provides
# an explicit merged-status log signal before attempting the delete.
# Scoped to session branch prefixes only: other refs (taskgroup merge branches,
# maintenance branches, etc.) are never touched, so their close/seal behavior
# is unchanged. This does NOT alter record_closed_branch (shared contract).
# Arguments:
#   $1 — branch name (required)
#   $2 — optional repo dir (worktree close paths; defaults to current repo)
delete_merged_session_branch() {
  local branch="${1:-}"
  local repo_dir="${2:-}"
  [ -z "$branch" ] && return 0
  case "$branch" in
    feature/*|fix/*|hotfix/*|experiment/*|live-editor-[0-9]*) ;;
    *) return 0 ;;
  esac
  # Ancestor precheck — explicit merged-status verification before delete
  if [ -n "$repo_dir" ]; then
    git -C "$repo_dir" merge-base --is-ancestor "$branch" main > /dev/null 2>&1 || return 0
    git -C "$repo_dir" branch -d "$branch" > /dev/null 2>&1 || true
  else
    git merge-base --is-ancestor "$branch" main > /dev/null 2>&1 || return 0
    git branch -d "$branch" > /dev/null 2>&1 || true
  fi
  return 0
}
# Backward-compat alias (Decision 0023 Amendment 2 callers)
delete_merged_editor_live_branch() { delete_merged_session_branch "$@"; }

# --- Seal orphaned merged editor-live branches (Decision 0023 Amendment 2 — fallback) ---
# Fallback for the editor-live close path. The normal close has the agent merge
# the live-editor-N branch to main and then call write_merge_signal, which the
# Stop hook reads to seal the branch. If the agent omits write_merge_signal, the
# Stop hook fires while HEAD is on main, where record_closed_branch skips main —
# so the branch would never be sealed (a silent gap; editor-live is solo=false,
# so the hook's own solo-merge block does not fire either).
# This scans for live-editor-N branches already merged into main, seals each in
# the closed-branches ledger (record_closed_branch — shared contract, CALLED not
# modified), and deletes the redundant ref (git branch -d, merged-only/safe).
# Idempotent: record_closed_branch dedups and `-d` no-ops on an already-deleted
# branch. Strictly scoped to live-editor-N names AND only invoked on the
# editor-live close path (session-close-check.sh) when no merge signal was
# recorded, so feature/fix/hotfix/taskgroup branches are never affected.
# Arguments:
#   $1 — optional repo dir (worktree close paths; defaults to current repo)
seal_orphaned_editor_live_branches() {
  local repo_dir="${1:-}"
  local cur merged b
  if [ -n "$repo_dir" ]; then
    cur=$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  else
    cur=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  fi
  # Only meaningful once on main (the post-manual-merge state).
  [ "$cur" = "main" ] || return 0
  if [ -n "$repo_dir" ]; then
    merged=$(git -C "$repo_dir" branch --merged main 2>/dev/null | tr -d ' *' | grep -E '^live-editor-[0-9]+$' || true)
  else
    merged=$(git branch --merged main 2>/dev/null | tr -d ' *' | grep -E '^live-editor-[0-9]+$' || true)
  fi
  [ -z "$merged" ] && return 0
  while IFS= read -r b; do
    [ -z "$b" ] && continue
    record_closed_branch "$b"
    if [ -n "$repo_dir" ]; then
      git -C "$repo_dir" branch -d "$b" > /dev/null 2>&1 || true
    else
      git branch -d "$b" > /dev/null 2>&1 || true
    fi
  done <<< "$merged"
}

# ============================================================
# Task group worktree lifetime (Decision 0054)
# ============================================================
# A sequential task group gets ONE worktree for the whole life of its branch:
# brief 1 creates it, briefs 2..N reuse it, and it is removed only after the
# final brief merges and seals, when the group fails or is abandoned, or when
# the stale sweep finds it orphaned. Standalone sessions keep the per-session
# worktree of Decision 0033; parallel task groups keep the per-brief branches
# and worktrees of Decision 0032.
#
# Paths resolve against the MAIN repo (get_main_repo_root) so the runner, the
# daemon and every worktree session agree on one worktree and one lock.

# --- Sanitize a task group name into one safe path component ---
# Whitelist: [a-zA-Z0-9_-]. Everything else becomes -, consecutive dashes
# collapse, leading/trailing dashes are stripped, result truncated to 80 chars.
# Deliberately narrower than sanitize_branch_name() in branch-manager.sh: that
# one keeps "/" because branch names are hierarchical, which here would silently
# nest the worktree a level deeper than every lookup expects.
# Arguments:
#   $1 — raw group name
# Output: sanitized name on stdout (empty when nothing survives)
_sanitize_group_name() {
  local clean
  clean=$(printf '%s' "${1:-}" | tr -c 'a-zA-Z0-9_\-\n' '-')
  while true; do
    case "$clean" in
      *--*) clean="${clean//--/-}" ;;
      *) break ;;
    esac
  done
  clean="${clean#-}"
  clean="${clean%-}"
  printf '%s' "${clean:0:80}"
}

# --- Resolve a task group's worktree path ---
# Arguments:
#   $1 — group name
# Output: absolute path on stdout. Returns 1 when the group name is unusable.
group_worktree_path() {
  local group
  group=$(_sanitize_group_name "${1:-}")
  [ -z "$group" ] && return 1
  printf '%s/.worktrees/tg-%s' "$(get_main_repo_root)" "$group"
}

# --- Resolve a task group's occupancy lock directory ---
# Arguments:
#   $1 — group name
# Output: absolute path on stdout. Returns 1 when the group name is unusable.
_group_worktree_lock_dir() {
  local group _state
  group=$(_sanitize_group_name "${1:-}")
  [ -z "$group" ] && return 1
  _state="$(get_main_repo_root)/.claude"
  printf '%s/.state/.tg-worktree-%s.lock.dir' "$_state" "$group"
}

# --- Name of the group worktree the caller is standing in ---
# Derived from the worktree root's basename (tg-<group>) rather than by parsing
# the task group contract, so any hook can resolve it with no contract lookup.
# Output: group name on stdout. Returns 1 when not inside a group worktree.
current_group_worktree_name() {
  local root base
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$root" ] || return 1
  base="${root##*/}"
  case "$base" in
    tg-?*) printf '%s' "${base#tg-}" ;;
    *) return 1 ;;
  esac
}

# --- Acquire a task group's single-occupancy lock ---
# Only one session may run in a group worktree at a time. The session registry
# writes one file per session id, so it can report overlap but cannot prevent
# it — which is why its task-group overlap check is advisory. This lock supplies
# the missing mutual exclusion.
#
# mkdir-based rather than the flock pattern used for the merge lock: that lock
# is held for seconds inside a single process, whereas occupancy must persist
# for a whole session and stay observable from short-lived hook processes that
# cannot inherit a file descriptor. Liveness is therefore recorded, not implied
# — a lock whose holder pid is gone is stale and broken on sight. Session
# metadata is NOT duplicated here: the lock stores only a holder pointer (pid +
# session id) and the registry remains the source of truth for the session.
#
# Arguments:
#   $1 — group name
#   $2 — holder pid (default: $$)
#   $3 — session id (optional; recorded for release-by-session and diagnostics)
# Returns: 0 acquired (or already held by this holder), 1 held by a live
#          foreign session, 2 unusable group name
acquire_group_worktree_lock() {
  local group="${1:-}"
  local holder_pid="${2:-$$}"
  local sid="${3:-}"
  local lock_dir
  lock_dir=$(_group_worktree_lock_dir "$group") || return 2
  mkdir -p "$(dirname "$lock_dir")" 2>/dev/null || true

  local attempts=0
  while [ "$attempts" -lt 3 ]; do
    attempts=$((attempts + 1))
    if mkdir "$lock_dir" 2>/dev/null; then
      printf '%s\n' "$holder_pid" > "$lock_dir/pid" 2>/dev/null || true
      printf '%s\n' "$sid" > "$lock_dir/session_id" 2>/dev/null || true
      date -u +%Y-%m-%dT%H:%M:%SZ > "$lock_dir/acquired_at" 2>/dev/null || true
      return 0
    fi

    local cur_pid
    cur_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")

    # Re-entrant: this holder already owns the lock.
    if [ -n "$cur_pid" ] && [ "$cur_pid" = "$holder_pid" ]; then
      return 0
    fi

    # Stale: the recorded holder is gone (crash, kill, force-halt). Break and
    # retry — without this a crashed brief would wedge its group permanently.
    if [ -z "$cur_pid" ] || ! kill -0 "$cur_pid" 2>/dev/null; then
      echo "WARNING: Breaking stale group worktree lock for '$group' (holder pid ${cur_pid:-unknown} not live)" >&2
      rm -rf "$lock_dir" 2>/dev/null || true
      continue
    fi

    # Live foreign holder — block immediately. Waiting is wrong here: the
    # holder owns the worktree for a whole session, so the caller should defer
    # or escalate rather than spin.
    return 1
  done
  return 1
}

# --- Release a task group's occupancy lock ---
# Releases when EITHER the recorded holder pid or the recorded session id
# matches. The pid path covers the runner (one process across the brief); the
# session-id path covers hooks, which run as separate short-lived processes and
# can only identify themselves by session id.
# Arguments:
#   $1 — group name
#   $2 — holder pid (optional)
#   $3 — session id (optional)
# Returns: 0 released or nothing to release, 1 held by a different session
release_group_worktree_lock() {
  local group="${1:-}"
  local holder_pid="${2:-}"
  local sid="${3:-}"
  local lock_dir
  lock_dir=$(_group_worktree_lock_dir "$group") || return 0
  [ -d "$lock_dir" ] || return 0

  local cur_pid cur_sid
  cur_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
  cur_sid=$(cat "$lock_dir/session_id" 2>/dev/null || echo "")

  local owned=false
  if [ -n "$holder_pid" ] && [ "$cur_pid" = "$holder_pid" ]; then
    owned=true
  elif [ -n "$sid" ] && [ -n "$cur_sid" ] && [ "$cur_sid" = "$sid" ]; then
    owned=true
  elif [ -z "$cur_pid" ] && [ -z "$cur_sid" ]; then
    # Malformed lock (dir created, holder pointer never written) — reclaim it.
    owned=true
  fi

  [ "$owned" = true ] || return 1
  rm -rf "$lock_dir" 2>/dev/null || true
  return 0
}

# --- Session id recorded against a group worktree's lock ---
# Arguments:
#   $1 — group name
# Output: holder session id on stdout (empty when no lock or none recorded)
group_worktree_lock_holder_session() {
  local group="${1:-}"
  local lock_dir
  lock_dir=$(_group_worktree_lock_dir "$group" 2>/dev/null) || return 0
  [ -d "$lock_dir" ] || return 0
  cat "$lock_dir/session_id" 2>/dev/null || true
}

# --- Release a group worktree lock left behind by an ended session ---
# Close-path net for a lock whose owning SESSION has ended. Two release
# conditions, both scoped to a matching session id:
#
#   1. The recorded holder process is gone (orphan — crash, kill, force-halt).
#   2. The recorded holder IS this session's own process (`owner_pid`).
#
# Condition 2 exists for interactive sessions (Decision 0054 Amendment): they
# claim the lock in init_phase() under the durable claude pid, which is still
# alive at SessionEnd, so condition 1 alone would never fire and the lock would
# outlive every interactive brief.
#
# What neither condition releases is the headless case: `runner.sh` holds the
# lock under the RUNNER's pid across its own post-session merge/seal step, so no
# other session can claim the worktree mid-merge. That pid is live and is not
# `owner_pid`, so this function leaves it alone and the runner releases it.
# Arguments:
#   $1 — group name
#   $2 — closing session id
#   $3 — owner pid (optional; this session's own durable pid)
# Returns: 0 released or nothing to do, 1 left in place (held by someone else)
release_group_worktree_lock_if_orphaned() {
  local group="${1:-}"
  local sid="${2:-}"
  local owner_pid="${3:-}"
  local lock_dir
  lock_dir=$(_group_worktree_lock_dir "$group" 2>/dev/null) || return 0
  [ -d "$lock_dir" ] || return 0

  local cur_pid cur_sid
  cur_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
  cur_sid=$(cat "$lock_dir/session_id" 2>/dev/null || echo "")

  # Not ours — leave it to whoever owns it.
  if [ -n "$sid" ] && [ -n "$cur_sid" ] && [ "$cur_sid" != "$sid" ]; then
    return 1
  fi

  # Our own process holds it (interactive claim) — release.
  if [ -n "$owner_pid" ] && [ -n "$cur_pid" ] && [ "$cur_pid" = "$owner_pid" ]; then
    rm -rf "$lock_dir" 2>/dev/null || true
    return 0
  fi

  # Holder still running and not us — it will release the lock itself.
  if [ -n "$cur_pid" ] && kill -0 "$cur_pid" 2>/dev/null; then
    return 1
  fi

  rm -rf "$lock_dir" 2>/dev/null || true
  return 0
}

# --- Is this path a worktree git knows about? ---
# A bare directory at the worktree path (left by a hard crash, or created by
# hand) is NOT a worktree and must never be treated as one.
#
# Compares PHYSICAL paths, not raw strings. `git worktree list` reports paths
# with symlinks resolved, while the caller's path is built from
# get_main_repo_root() and may carry a symlinked prefix (on macOS /tmp is a
# symlink to /private/tmp). String comparison reported a perfectly good
# worktree as unregistered, which made _resolve_group_worktree escalate
# "unregistered" and refuse to start the brief. Same resolve-before-compare
# treatment as is_worktree() in _analytics-helper.sh.
# Arguments:
#   $1 — worktree directory
# Returns: 0 registered, 1 not
is_registered_worktree() {
  local wt_dir="${1:-}"
  [ -n "$wt_dir" ] || return 1
  local main_repo wt_phys listed line line_phys
  main_repo="$(get_main_repo_root)"
  wt_phys=$(cd "$wt_dir" 2>/dev/null && pwd -P) || wt_phys=""
  listed=$(git -C "$main_repo" worktree list --porcelain 2>/dev/null \
    | grep '^worktree ' | sed 's/^worktree //' || true)
  [ -n "$listed" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$line" = "$wt_dir" ] && return 0
    if [ -n "$wt_phys" ]; then
      line_phys=$(cd "$line" 2>/dev/null && pwd -P) || line_phys=""
      if [ -n "$line_phys" ] && [ "$line_phys" = "$wt_phys" ]; then
        return 0
      fi
    fi
  done <<< "$listed"
  return 1
}

# --- Branch currently checked out in a worktree ---
# Arguments:
#   $1 — worktree directory
# Output: branch name on stdout (empty when detached or not a worktree)
group_worktree_branch() {
  local wt_dir="${1:-}"
  [ -d "$wt_dir" ] || return 0
  git -C "$wt_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true
}

# --- Clean-start check for a reused group worktree ---
# A brief must start from a clean committed state even when it inherits a
# worktree. Tracked AND untracked changes both disqualify; gitignored files do
# NOT (git status --porcelain omits them without --ignored), which is exactly
# the point — dependency installs, build output and caches are what the reused
# worktree exists to preserve.
# Arguments:
#   $1 — worktree directory
#   $2 — expected branch (HEAD must equal this branch's tip)
# Output: on failure, a one-line reason on stdout
# Returns: 0 clean, 1 dirty or diverged
check_group_worktree_clean() {
  local wt_dir="${1:-}"
  local branch="${2:-}"
  if [ ! -d "$wt_dir" ]; then
    echo "worktree directory missing: $wt_dir"
    return 1
  fi

  local dirty
  dirty=$(git -C "$wt_dir" status --porcelain 2>/dev/null || true)
  if [ -n "$dirty" ]; then
    echo "uncommitted changes: $(printf '%s' "$dirty" | tr '\n' ',' | sed 's/,$//')"
    return 1
  fi

  if [ -n "$branch" ]; then
    local head_sha branch_sha
    head_sha=$(git -C "$wt_dir" rev-parse HEAD 2>/dev/null || echo "")
    branch_sha=$(git -C "$wt_dir" rev-parse "$branch" 2>/dev/null || echo "")
    if [ -z "$head_sha" ] || [ "$head_sha" != "$branch_sha" ]; then
      echo "HEAD ($head_sha) does not match tip of $branch ($branch_sha)"
      return 1
    fi
  fi
  return 0
}

# --- Remove a task group's worktree and release its lock ---
# Called only on terminal paths: final brief merged + sealed, work order failed
# or abandoned, or the stale sweep. Refuses to remove the worktree the caller is
# standing in — that case is left to the sweep.
# Arguments:
#   $1 — group name
#   $2 — holder pid (optional, for lock release)
#   $3 — session id (optional, for lock release)
# Returns: 0 removed or nothing to remove, 1 refused (caller inside the tree)
remove_group_worktree() {
  local group="${1:-}"
  local holder_pid="${2:-$$}"
  local sid="${3:-}"
  local wt_dir main_repo
  wt_dir=$(group_worktree_path "$group") || return 0
  main_repo="$(get_main_repo_root)"

  if [ -d "$wt_dir" ]; then
    case "$PWD" in
      "$wt_dir"|"$wt_dir"/*)
        echo "WARNING: Refusing to remove group worktree '$wt_dir' from inside it — left for the stale sweep" >&2
        return 1
        ;;
    esac
    git -C "$main_repo" worktree remove --force "$wt_dir" > /dev/null 2>&1 \
      || rm -rf "$wt_dir" 2>/dev/null \
      || true
    git -C "$main_repo" worktree prune > /dev/null 2>&1 || true
  fi

  release_group_worktree_lock "$group" "$holder_pid" "$sid" || true
  return 0
}
