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
    file_sid=$(grep '^session_id: ' "$file" 2>/dev/null | sed 's/^session_id: *//' || true)
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
    # Session-bound files: check session_id before deleting
    _delete_if_owned "$state_dir/plan-approved" "$closing_sid"
    _delete_if_owned "$state_dir/cohesion-reviewed" "$closing_sid"
    _delete_if_owned "$state_dir/diff-review-complete" "$closing_sid"
    _delete_if_owned "$state_dir/qa-verified" "$closing_sid"
    _delete_if_owned "$state_dir/reviewer-signed" "$closing_sid"
    _delete_if_owned "$state_dir/security-signed" "$closing_sid"
    _delete_if_owned "$state_dir/pragmatist-signed" "$closing_sid"
    _delete_if_owned "$state_dir/functional-verified" "$closing_sid"
    _delete_if_owned "$state_dir/phase-state" "$closing_sid"
    _delete_if_owned "$state_dir/phase-state.gates" "$closing_sid"

    # Non-session-bound files: unconditional delete.
    # governance-checked and high-risk-detected are idempotent commit-gate
    # markers (re-created on each gate run). No session_id field — concurrent
    # deletion is benign because the gate re-checks on the next commit attempt.
    rm -f "$state_dir/scope-risk-gain"
    rm -f "$state_dir/high-risk-detected"
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

# --- Delete a merged editor-live branch (Decision 0023 Amendment 2) ---
# Editor-live-scoped close cleanup: once a live-editor-N branch has been merged
# to main AND recorded in the closed-branches ledger, delete the now-redundant
# local branch ref so live-editor branches do not accumulate. Uses
# `git branch -d` (merged-only — never force) so an unmerged branch is never
# deleted; a no-op if the branch is the current HEAD or not fully merged.
# Strictly scoped to live-editor-N names: feature/fix/hotfix/taskgroup branches
# are never touched, so their close/seal behavior is unchanged. This does NOT
# alter record_closed_branch (shared contract, 13 call sites).
# Arguments:
#   $1 — branch name (required)
#   $2 — optional repo dir (worktree close paths; defaults to current repo)
delete_merged_editor_live_branch() {
  local branch="${1:-}"
  local repo_dir="${2:-}"
  [ -z "$branch" ] && return 0
  case "$branch" in
    live-editor-[0-9]*) ;;
    *) return 0 ;;
  esac
  if [ -n "$repo_dir" ]; then
    git -C "$repo_dir" branch -d "$branch" > /dev/null 2>&1 || true
  else
    git branch -d "$branch" > /dev/null 2>&1 || true
  fi
}

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
