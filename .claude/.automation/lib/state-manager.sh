#!/usr/bin/env bash
# State manager — pre-launch state setup for headless runner sessions.
# Sourced by runner.sh. NOT executed standalone.
# Decision 0016: runner-writes-state invariant.
# Decision 0014: phase model — does NOT call init_phase (agent-initiated).
#
# Fail-closed parity (Decision 0019):
#   The runner pre-seeds .claude/.session-id (via get_session_id) so the
#   agent's init_phase() call binds to the correct session. Phase-state
#   itself is NOT pre-seeded — the agent calls init_phase() via Bash as
#   its first action (instructed by the orchestrator), which fast-exits
#   branch-guard.sh (no redirect/tee — Decision 0019 §5). Edits before
#   init_phase() are blocked when the .fail-closed-enforced sentinel is
#   present. Custom runner implementations MUST ensure init_phase() is
#   called before any Edit/Write tool use; the canonical runner achieves
#   this by relying on the orchestrator's init phase sequence.
#
# Depends on (sourced by runner.sh before this file):
#   _analytics-helper.sh — get_session_id, get_repo_root, unregister_session,
#                           cleanup_old_analytics, register_session
#   _phase-helper.sh     — get_phases_for_type (session type validation)
#   _cleanup-helper.sh   — cleanup_session_files (audit C5: shared cleanup)

set -euo pipefail

# --- Pre-launch state setup ---
# Creates session ID, writes plan-approved state, registers session.
# Arguments:
#   $1 — repo_root (absolute path)
#   $2 — session_type (Decision 0014 enum)
state_manager_setup() {
  local repo_root="$1"
  local session_type="$2"

  local state_dir="$repo_root/.claude/.state"
  mkdir -p "$state_dir" 2>/dev/null || true

  # Ensure session ID exists
  get_session_id "$repo_root" > /dev/null

  # Write plan-approved state (runner pre-writes this so hooks don't block)
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf 'timestamp: %s\nquestion_hash: runner-auto\nlarge-scope: true\nmode: auto\nsource: runner\n' \
    "$timestamp" \
    > "$state_dir/plan-approved" 2>/dev/null || true

  # Register session in the session registry (Decision 0013 overlap awareness).
  # Uses the canonical register_session() which includes overlap advisory checks.
  register_session "$session_type" || true
}

# --- External cleanup (when Stop hook didn't fire) ---
# Delegates to shared cleanup_session_files() from _cleanup-helper.sh.
# Audit C5: shared cleanup eliminates divergence risk with session-close-check.sh.
# Arguments:
#   $1 — repo_root (absolute path)
runner_external_cleanup() {
  local repo_root="$1"

  # Capture session type before cleaning state files (phase-state deleted below)
  local close_stype
  close_stype=$(get_session_type)

  # Unregister from session registry (before .session-id removal — needs ID)
  unregister_session || true

  # Delegate to shared cleanup
  cleanup_session_files "$repo_root" "$close_stype"

  # Update baseline for next session
  git rev-parse HEAD > "$repo_root/.claude/.session-baseline-sha" 2>/dev/null || true
}
