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
    file_sid=$(grep '^session_id: ' "$file" 2>/dev/null | sed 's/^session_id: *//')
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
cleanup_session_files() {
  local repo_root="$1"
  local close_stype="${2:-}"
  local closing_sid="${3:-}"

  # Clean session-scoped marker files (no session_id field — unconditional)
  rm -f "$repo_root/.claude/.hvst-fail-count"
  rm -f "$repo_root/.claude/.deferrals-pending"
  cleanup_old_analytics "$repo_root"

  # Session-bound identity files: only delete if content matches closing session
  # Sessions with REPO_OS_SESSION_ID (worktree/daemon) use env var, not file (Decision 0030)
  if [ -n "${REPO_OS_SESSION_ID:-}" ]; then
    : # No .session-id file to delete — identity is via REPO_OS_SESSION_ID env var
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
    _delete_if_owned "$state_dir/qa-verified" "$closing_sid"
    _delete_if_owned "$state_dir/reviewer-signed" "$closing_sid"
    _delete_if_owned "$state_dir/security-signed" "$closing_sid"
    _delete_if_owned "$state_dir/pragmatist-signed" "$closing_sid"
    _delete_if_owned "$state_dir/phase-state" "$closing_sid"

    # Non-session-bound files: unconditional delete.
    # governance-checked and high-risk-detected are idempotent commit-gate
    # markers (re-created on each gate run). No session_id field — concurrent
    # deletion is benign because the gate re-checks on the next commit attempt.
    rm -f "$state_dir/scope-risk-gain"
    rm -f "$state_dir/high-risk-detected"
    rm -f "$state_dir/governance-checked"
    rm -f "$state_dir/overrides.log"
    rm -f "$repo_root/.claude/local/task-contract.yaml"
    rm -f "$state_dir/merge-source-branch"
    rm -f "$state_dir/.stop-attempt-count"
    rm -f "$state_dir/brief-has-taskgroup"
    _delete_if_owned "$state_dir/session-resume.yaml" "$closing_sid"
    # Clean completion markers when merge brief closes (parallel groups)
    # Markers are cross-session: written by content briefs in their per-session dirs.
    if [ "$close_stype" = "taskgroup-merge" ]; then
      clean_cross_session_markers "tg-*-brief-*.complete"
    fi

    # Remove per-session state directory if now empty (all sessions use per-session dirs)
    # Only rmdir if it's a per-session subdir, not the flat .claude/.state/ root
    case "$state_dir" in
      */wt-sessions/*)
        rmdir "$state_dir" 2>/dev/null || true
        ;;
    esac
  fi
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
