#!/usr/bin/env bash
# Shared cleanup helper — session state file cleanup and branch sealing.
# Sourced by session-close-check.sh and runner.sh.
# Extracted to eliminate duplicate cleanup logic (audit finding C5).
#
# Depends on (must be sourced before this file):
#   _analytics-helper.sh — get_repo_root, get_session_type, get_branch,
#                           unregister_session, cleanup_old_analytics
#
# ## Consumers (auto-generated — run .claude/tools/hook-dep-map.sh for live data)
#   Hooks: session-close-check
#   Automation: runner.sh, queue-cli.sh, intake.sh

# --- Clean all session-scoped state files ---
# Removes governance state, phase state, and session markers.
# Arguments:
#   $1 — repo_root (absolute path)
#   $2 — close_stype (session type captured before phase-state deletion)
cleanup_session_files() {
  local repo_root="$1"
  local close_stype="${2:-}"

  # Clean session-scoped marker files
  rm -f "$repo_root/.claude/.hvst-fail-count"
  rm -f "$repo_root/.claude/.session-id"
  rm -f "$repo_root/.claude/.session-type"
  rm -f "$repo_root/.claude/.deferrals-pending"
  cleanup_old_analytics "$repo_root"

  # Clean governance state files
  local state_dir="$repo_root/.claude/.state"
  if [ -d "$state_dir" ]; then
    rm -f "$state_dir/plan-approved"
    rm -f "$state_dir/cohesion-reviewed"
    rm -f "$state_dir/qa-verified"
    rm -f "$state_dir/reviewer-signed"
    rm -f "$state_dir/security-signed"
    rm -f "$state_dir/pragmatist-signed"
    rm -f "$state_dir/scope-risk-gain"
    rm -f "$state_dir/high-risk-detected"
    rm -f "$state_dir/governance-checked"
    rm -f "$state_dir/phase-state"
    rm -f "$state_dir/overrides.log"
    rm -f "$state_dir/task-contract.yaml"
    rm -f "$repo_root/.claude/local/task-contract.yaml"
    rm -f "$state_dir/merge-source-branch"
    rm -f "$state_dir/.stop-attempt-count"
    # Clean completion markers when merge brief closes (parallel groups)
    if [ "$close_stype" = "taskgroup-merge" ]; then
      rm -f "$state_dir"/tg-*-brief-*.complete
    fi
  fi
}

# --- Record closed branch (Decision 0013: session isolation) ---
# Accepts an optional branch argument; if omitted, reads HEAD.
# Appends branch to closed-branches ledger so future sessions can't reuse it.
# Skips main (protected by branch-guard Gate 1 separately).
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
  if ! grep -qxF "$branch" "$closed_file" 2>/dev/null; then
    echo "$branch" >> "$closed_file"
  fi
}
