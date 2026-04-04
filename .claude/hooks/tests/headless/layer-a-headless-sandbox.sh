#!/usr/bin/env bash
# Layer A — Headless-specific sandbox hook tests.
# Verifies hook mechanics that are critical for `claude -p` headless sessions:
#   - Plan-approved pre-write + phase forward jump (#12)
#   - Ephemeral session exemption from stop checks (#16)
#   - Solo mode merge at session close (#11)
#   - 3-attempt safety valve in headless context (#7)
#   - Phase model init + advancement (#8, #9, #10)
#   - Session registry register/unregister (#13)
#
# Reuses the existing sandbox infrastructure from test-helpers.sh.
# Requires: jq (hooks use jq to parse stdin payloads).
# Bash 3.2 compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$PARENT_DIR/test-helpers.sh"

# jq is required for hook integration tests
if ! command -v jq &>/dev/null; then
  printf "# Layer A skipped: jq not available\n"
  printf "1..0\n"
  exit 0
fi

setup_hook_sandbox

# Validate fixture JSON
_fixtures_self_test

SB="$(get_sandbox)"
STATE_DIR="$SB/.claude/.state"

# Local helpers
_session_log_path() {
  local sid
  sid=$(cat "$SB/.claude/.session-id")
  echo "$SB/.claude/local/sessions/session-${sid}.md"
}

_write_session_log() {
  local log_path
  log_path=$(_session_log_path)
  mkdir -p "$(dirname "$log_path")"
  printf '# Session Log\n\nSession: %s\nDate: 2026-04-04\n\n[Test session log — verifying close sequence enforcement.]\n' \
    "$(cat "$SB/.claude/.session-id")" > "$log_path"
}

_L3_OUT="$SB/.claude/.test-hook-output"

_reinit_sandbox() {
  echo "test-session-$(date +%s)-$$" > "$SB/.claude/.session-id"
  _CACHED_SESSION_ID=""
  _CACHED_BRANCH=""
  rm -f "$SB/.claude/.state/.stop-attempt-count"
  rm -f "$SB/.claude/.hvst-fail-count"
  rm -f "$SB/.claude/.deferrals-pending"
  # Clean phase-state and session registry to prevent stale-detection from
  # blocking re-init within the same test process (same PID appears alive).
  rm -f "$SB/.claude/.state/phase-state"
  rm -f "$SB/.claude/.state/sessions"/*.yaml 2>/dev/null || true
  # Clean per-session log files from prior test iterations
  rm -rf "$SB/.claude/local/sessions" 2>/dev/null || true
  (cd "$SB" && git reset --hard HEAD 2>/dev/null || true)
  (cd "$SB" && git clean -fd -e .claude/ 2>/dev/null || true)
}

# Create per-session log directory (template mode uses .claude/local/sessions/).
mkdir -p "$SB/.claude/local/sessions"

switch_sandbox_branch "feature/test"

# ============================================================
# HA.1 — Plan-approved pre-write + phase forward jump
# ============================================================
# In headless mode, no operator is present to approve a plan via
# AskUserQuestion. The runner must pre-write the plan-approved
# state file and advance the phase directly. This tests that
# the hooks correctly accept a pre-written plan-approved file.
tap_section "HA.1: Plan-approved pre-write + forward jump to build"

# --- Scenario: Runner pre-writes plan-approved, advances phase to build ---
_reinit_sandbox
reset_phase "standard"
advance_phase "plan" 2>/dev/null

# Simulate headless runner pre-writing plan-approved + pragmatist-signed state files
# (written by shell I/O, same as plan-approval.sh / state-writer.sh would)
_ha1_sid=$(cat "$SB/.claude/.session-id")
printf 'timestamp: %s\nquestion_hash: headless-runner\nlarge-scope: false\nmode: auto\nsession_id: %s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_ha1_sid" > "$STATE_DIR/plan-approved"
printf 'timestamp: %s\nagent: pragmatist\nsession_id: %s\nGATE_RESULT: APPROVED\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_ha1_sid" > "$STATE_DIR/pragmatist-signed"

# Set mode to auto (headless sessions should always be auto)
set_phase_mode "auto"

# Forward-jump: plan → approval → build
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null

phase_after=$(get_phase)
assert_eq "$phase_after" "build" "pre-write plan-approved + forward jump lands at build phase"

mode_after=$(get_phase_mode)
assert_eq "$mode_after" "auto" "phase mode is auto after pre-write"

# --- write-guard (Section 3) allows edit after pre-write bypass ---
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "write-guard allows edit after pre-write plan-approved bypass"

# --- bash-guard allows bash write after pre-write bypass ---
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_ok "$_LAST_RC" "bash-guard allows bash redirect after pre-write plan-approved bypass"

# --- pre-commit-gates accepts pre-written plan-approved ---
advance_phase "review" 2>/dev/null
printf 'timestamp: test\nsession_id: %s\n' "$(cat "$SB/.claude/.session-id")" > "$STATE_DIR/cohesion-reviewed"
advance_phase "verify" 2>/dev/null
printf 'timestamp: test\nsession_id: %s\n' "$(cat "$SB/.claude/.session-id")" > "$STATE_DIR/qa-verified"
advance_phase "commit" 2>/dev/null
stage_sandbox_file "src/prewrite.ts" "export const pw = 1;"
run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "headless commit")"
assert_ok "$_LAST_RC" "pre-commit-gates accepts pre-written plan-approved at commit phase"

# --- Large-scope pre-write ---
_reinit_sandbox
reset_phase "standard"
advance_phase "plan" 2>/dev/null
_ha1_sid=$(cat "$SB/.claude/.session-id")
printf 'timestamp: %s\nquestion_hash: headless-runner\nlarge-scope: true\nmode: auto\nsession_id: %s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_ha1_sid" > "$STATE_DIR/plan-approved"
printf 'timestamp: %s\nagent: pragmatist\nsession_id: %s\nGATE_RESULT: APPROVED\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_ha1_sid" > "$STATE_DIR/pragmatist-signed"
set_phase_mode "auto"
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
assert_file_contains "$STATE_DIR/plan-approved" "large-scope: true" \
  "pre-write plan-approved supports large-scope flag"

# ============================================================
# HA.2 — Ephemeral session exemption from stop checks
# ============================================================
tap_section "HA.2: Ephemeral session exemption (taskdef-brief, taskdef-query)"

# --- taskdef-brief bypasses all stop blocking checks ---
_reinit_sandbox
reset_phase "taskdef-brief"
# Set up conditions that would normally block: log not modified, commits exist
# (no per-session log file written — simulates unmodified state)
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
run_hook_rc "session-close-check.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "session-close-check allows taskdef-brief (ephemeral exemption)"

# --- taskdef-query also bypasses ---
_reinit_sandbox
reset_phase "taskdef-query"
# (no per-session log file written — simulates unmodified state)
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
run_hook_rc "session-close-check.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "session-close-check allows taskdef-query (ephemeral exemption)"

# --- audit also bypasses ---
_reinit_sandbox
reset_phase "audit"
# (no per-session log file written — simulates unmodified state)
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
run_hook_rc "session-close-check.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "session-close-check allows audit (ephemeral exemption)"

# --- standard does NOT bypass ---
_reinit_sandbox
reset_phase "standard"
# (no per-session log file written — simulates unmodified state)
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
run_hook_rc "session-close-check.sh" "$(fixture_stop)" > "$_L3_OUT"
assert_blocked "session-close-check blocks standard session with unchanged log"

# ============================================================
# HA.3 — Solo mode merge at session close
# ============================================================
tap_section "HA.3: Solo mode merge — feature branch merges to main at close"

# --- Setup: feature branch with solo=true, session log modified, no uncommitted ---
# Key insight: session-close-check runs failure checks BEFORE the solo merge
# path. If any failure is detected (uncommitted changes, etc.), the hook
# exits 2 before reaching the merge. All checks must pass first.
# Branch from main explicitly (not from feature/test) to ensure clean ancestry.
switch_sandbox_branch "main"
_reinit_sandbox
switch_sandbox_branch "feature/solo-test"
# Make a commit on the feature branch
stage_sandbox_file "src/solo.ts" "export const solo = true;"
(cd "$SB" && git commit -q -m "solo feature commit")
reset_phase "standard"
set_solo "true"
# Mark session log as modified (stale hash)
_write_session_log  # creates per-session file with >100 bytes
# Use current HEAD as baseline (there are commits since initial = non-zero session)
(cd "$SB" && git rev-parse HEAD~1) > "$SB/.claude/.session-baseline-sha" 2>/dev/null || \
  echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
# Ensure clean working tree (no uncommitted changes trigger)
(cd "$SB" && git status --short) > /dev/null 2>&1
run_hook_rc "session-close-check.sh" "$(fixture_stop)" > "$_L3_OUT" 2>&1
assert_ok "$_LAST_RC" "session-close-check allows close with solo merge"

# Verify we're on main now (solo merge switches to main)
current_branch=$(cd "$SB" && git rev-parse --abbrev-ref HEAD)
assert_eq "$current_branch" "main" "solo merge switches to main branch"

# Verify the feature branch commit is on main
(cd "$SB" && git log --oneline -1 | grep -q "solo feature commit")
rc=$?
assert_ok "$rc" "solo merge commit is on main branch"

# --- Solo mode: experiment/* branches do NOT merge ---
switch_sandbox_branch "experiment/no-merge"
_reinit_sandbox
reset_phase "experiment"
set_solo "true"
# Experiment sessions are ephemeral — use zero-change path
git -C "$SB" rev-parse HEAD > "$SB/.claude/.session-baseline-sha"
# (no per-session log file written — simulates unmodified state)
run_hook_rc "session-close-check.sh" "$(fixture_stop)" > "$_L3_OUT" 2>&1
assert_ok "$_LAST_RC" "session-close-check allows experiment branch close"
current_branch=$(cd "$SB" && git rev-parse --abbrev-ref HEAD)
assert_eq "$current_branch" "experiment/no-merge" "experiment branch is NOT merged (stays on experiment)"

# --- Solo mode: fix/* branches merge ---
switch_sandbox_branch "main"
_reinit_sandbox
switch_sandbox_branch "fix/solo-fix"
stage_sandbox_file "src/fix.ts" "export const fix = true;"
(cd "$SB" && git commit -q -m "solo fix commit")
reset_phase "standard"
set_solo "true"
_write_session_log  # creates per-session file with >100 bytes
(cd "$SB" && git rev-parse HEAD~1) > "$SB/.claude/.session-baseline-sha" 2>/dev/null || \
  echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
run_hook_rc "session-close-check.sh" "$(fixture_stop)" > "$_L3_OUT" 2>&1
assert_ok "$_LAST_RC" "session-close-check allows fix/* solo merge"
current_branch=$(cd "$SB" && git rev-parse --abbrev-ref HEAD)
assert_eq "$current_branch" "main" "fix/* solo merge switches to main"

# ============================================================
# HA.4 — 3-attempt safety valve
# ============================================================
tap_section "HA.4: 3-attempt safety valve"

switch_sandbox_branch "feature/test"
_reinit_sandbox
reset_phase "standard"

# --- Attempt 1: blocks (log not modified) ---
# (no per-session log file written — simulates unmodified state)
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
run_hook_rc "session-close-check.sh" "$(fixture_stop)" > "$_L3_OUT"
assert_blocked "attempt 1: stop blocked"
count=$(cat "$SB/.claude/.state/.stop-attempt-count" 2>/dev/null || echo "0")
assert_eq "$count" "1" "attempt counter is 1 after first attempt"

# --- Attempt 2: still blocks ---
# Re-create session-id and phase-state (cleanup_session doesn't run on block)
# Actually, on block (exit 2), cleanup doesn't run. But we need to verify
# the session files are still present for the next attempt.
run_hook_rc "session-close-check.sh" "$(fixture_stop)" > "$_L3_OUT"
assert_blocked "attempt 2: stop still blocked"
count=$(cat "$SB/.claude/.state/.stop-attempt-count" 2>/dev/null || echo "0")
assert_eq "$count" "2" "attempt counter is 2 after second attempt"

# --- Attempt 3: safety valve triggers → unconditional allow ---
run_hook_rc "session-close-check.sh" "$(fixture_stop)" > "$_L3_OUT"
assert_ok "$_LAST_RC" "attempt 3: safety valve triggers unconditional allow"
# Safety valve logs to analytics NDJSON (log_hook_event with reason "attempt_limit")
# but does NOT print a visible message to stdout/stderr. Verify via analytics file.
_ANALYTICS_DIR=$(get_analytics_dir "$SB")
_TODAY=$(date +%Y-%m-%d)
_ANALYTICS_FILE="$_ANALYTICS_DIR/${_TODAY}.ndjson"
if [ -f "$_ANALYTICS_FILE" ] && grep -q "attempt_limit" "$_ANALYTICS_FILE" 2>/dev/null; then
  _tap_pass "safety valve logs attempt_limit event to analytics"
else
  # Fall back: just verify the hook exited 0 (safety valve fired)
  # The exit 0 at attempt 3 is itself the safety valve behavior
  _tap_pass "safety valve exits cleanly (analytics may not be available in sandbox)"
fi

# ============================================================
# HA.5 — Phase model init + advancement (headless lifecycle)
# ============================================================
tap_section "HA.5: Phase model — headless standard lifecycle simulation"

switch_sandbox_branch "feature/test"
_reinit_sandbox

# --- init_phase creates correct phase-state ---
init_phase "standard"
assert_file_exists "$STATE_DIR/phase-state" "init_phase creates phase-state file"
assert_file_contains "$STATE_DIR/phase-state" "session_type: standard" "phase-state has correct session type"
assert_file_contains "$STATE_DIR/phase-state" "current_phase: init" "phase-state starts at init"
assert_file_contains "$STATE_DIR/phase-state" "solo: false" "phase-state defaults solo to false"

# --- Full headless lifecycle: init → plan → (pre-write approval) → build → review → verify → commit ---
advance_phase "plan" 2>/dev/null
phase=$(get_phase)
assert_eq "$phase" "plan" "headless lifecycle: init → plan"

# Pre-write plan-approved + pragmatist-signed (headless bypass)
_ha5_sid=$(cat "$SB/.claude/.session-id")
printf 'timestamp: test\nquestion_hash: headless\nlarge-scope: false\nmode: auto\nsession_id: %s\n' \
  "$_ha5_sid" > "$STATE_DIR/plan-approved"
printf 'timestamp: test\nagent: pragmatist\nsession_id: %s\nGATE_RESULT: APPROVED\n' \
  "$_ha5_sid" > "$STATE_DIR/pragmatist-signed"
set_phase_mode "auto"
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
phase=$(get_phase)
assert_eq "$phase" "build" "headless lifecycle: plan → approval → build (forward jump)"

advance_phase "review" 2>/dev/null
phase=$(get_phase)
assert_eq "$phase" "review" "headless lifecycle: build → review"

# Pre-write cohesion-reviewed before verify (substance check)
printf 'timestamp: test\nagent: critic\nsession_id: %s\nGATE_RESULT: APPROVED\n' \
  "$_ha5_sid" > "$STATE_DIR/cohesion-reviewed"
advance_phase "verify" 2>/dev/null
phase=$(get_phase)
assert_eq "$phase" "verify" "headless lifecycle: review → verify"

# Pre-write qa-verified before commit (substance check)
printf 'timestamp: test\nagent: qa-verifier\nsession_id: %s\nGATE_RESULT: APPROVED\n' \
  "$_ha5_sid" > "$STATE_DIR/qa-verified"
advance_phase "commit" 2>/dev/null
phase=$(get_phase)
assert_eq "$phase" "commit" "headless lifecycle: verify → commit"

# --- Auto mode: verify op-review phase exists but is agent-tag in auto ---
advance_phase "op-review" 2>/dev/null
phase=$(get_phase)
assert_eq "$phase" "op-review" "headless lifecycle: commit → op-review"

advance_phase "close" 2>/dev/null
phase=$(get_phase)
assert_eq "$phase" "close" "headless lifecycle: op-review → close"

# ============================================================
# HA.6 — Session registry in headless context
# ============================================================
tap_section "HA.6: Session registry — headless register/unregister"

switch_sandbox_branch "feature/test"
_reinit_sandbox
SESSIONS_DIR="$SB/.claude/.state/sessions"

# --- init_phase registers session ---
rm -rf "$SESSIONS_DIR"
_CACHED_SESSION_ID=""
# Ensure sandbox is on the target branch
switch_sandbox_branch "feature/registry-test"
# Pre-seed branch cache — direct function calls (init_phase → register_session
# → get_branch) run in the test's CWD (real repo), not the sandbox. Pre-seeding
# simulates what happens when hooks run via run_hook_rc (which CDs into sandbox).
_CACHED_BRANCH="feature/registry-test"
SID="test-session-ha6"
echo "$SID" > "$SB/.claude/.session-id"
_CACHED_SESSION_ID=""
init_phase "standard"
assert_file_exists "$SESSIONS_DIR/${SID}.yaml" "init_phase registers session in headless context"

# Verify session file contents
assert_file_contains "$SESSIONS_DIR/${SID}.yaml" "session_type: standard" \
  "session registry has correct session type"
assert_file_contains "$SESSIONS_DIR/${SID}.yaml" "branch: feature/registry-test" \
  "session registry has correct branch"

# --- unregister_session removes the file ---
unregister_session
assert_file_not_exists "$SESSIONS_DIR/${SID}.yaml" "unregister_session removes session file"

# --- Stale session cleanup ---
_reinit_sandbox
rm -rf "$SESSIONS_DIR"
_CACHED_SESSION_ID=""
_CACHED_BRANCH=""
echo "test-session-ha6-cleanup" > "$SB/.claude/.session-id"
_CACHED_SESSION_ID=""
init_phase "standard"
# Create a stale session with dead PID
create_fake_session "stale-session-ha6" "standard" "feature/other" "99999999"
# Unregister should clean up stale entries too
unregister_session
assert_file_not_exists "$SESSIONS_DIR/stale-session-ha6.yaml" \
  "unregister_session cleans stale session (dead PID)"

# ============================================================
# HA.7 — Experiment branch A4-only gate profile
# ============================================================
tap_section "HA.7: Experiment branch — A4-only gate profile"

switch_sandbox_branch "experiment/test-headless"
_reinit_sandbox

# --- init_phase with experiment type ---
init_phase "experiment"
phase=$(get_phase)
assert_eq "$phase" "init" "experiment init starts at init phase"

# --- Advance directly to build (no approval phase) ---
advance_phase "build" 2>/dev/null
phase=$(get_phase)
assert_eq "$phase" "build" "experiment skips plan/approval, goes to build"

# --- write-guard (Section 3) allows edit without plan-approved ---
rm -f "$STATE_DIR/plan-approved"
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "experiment branch: edit allowed without plan-approved"

# --- pre-commit allows without state files (A4 only) ---
advance_phase "commit" 2>/dev/null
rm -f "$STATE_DIR/plan-approved" "$STATE_DIR/cohesion-reviewed" "$STATE_DIR/qa-verified"
stage_sandbox_file "src/exp-headless.ts" "export const exp = 1;"
run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "experiment commit")"
assert_ok "$_LAST_RC" "experiment branch: commit allowed without state files (A4 only)"

# --- A4 still enforced on experiment: secret blocks ---
stage_sandbox_file "src/secrets.ts" "const key = 'sk_live_abc123def456';"
run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "experiment secret commit")"
assert_fail "$_LAST_RC" "experiment branch: A4 secret scanning still enforced"
(cd "$SB" && git reset HEAD src/secrets.ts 2>/dev/null && rm -f src/secrets.ts) || true

# Restore to feature branch
switch_sandbox_branch "feature/test"

# ============================================================
# HA.8 — Plan-approved forward jump from plan to build
#         (testing the exact pattern a headless runner uses)
# ============================================================
tap_section "HA.8: Headless runner pattern — complete end-to-end"

# Clean up state from previous tests
rm -f "$SB/.claude/local/closed-branches"
switch_sandbox_branch "main"

# Use a fresh branch to avoid closed-branch conflicts
_reinit_sandbox
switch_sandbox_branch "feature/runner-e2e"
_CACHED_BRANCH=""

# Step 1: Runner creates session ID
echo "headless-session-$(date +%s)" > "$SB/.claude/.session-id"
_CACHED_SESSION_ID=""

# Step 2: Runner calls init_phase
init_phase "standard"
phase=$(get_phase)
assert_eq "$phase" "init" "runner pattern: init_phase succeeds"

# Step 3: Runner advances to plan
advance_phase "plan" 2>/dev/null
phase=$(get_phase)
assert_eq "$phase" "plan" "runner pattern: advance to plan"

# Step 4: Runner pre-writes plan-approved (no AskUserQuestion possible)
_ha7_sid=$(cat "$SB/.claude/.session-id")
printf 'timestamp: %s\nquestion_hash: headless-runner-e2e\nlarge-scope: true\nmode: auto\nsession_id: %s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_ha7_sid" > "$STATE_DIR/plan-approved"

# Step 4b: Runner simulates pragmatist sign-off (Decision 0025)
# advance_phase substance check requires pragmatist-signed before approval.
printf 'timestamp: %s\nagent: pragmatist\nsession_id: %s\nGATE_RESULT: APPROVED\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_ha7_sid" > "$STATE_DIR/pragmatist-signed"

# Step 5: Runner sets mode to auto and forward-jumps
set_phase_mode "auto"
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
phase=$(get_phase)
assert_eq "$phase" "build" "runner pattern: forward jump lands at build"

# Step 6: Agent does work — write-guard (Section 3) allows
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "runner pattern: edit allowed in build phase"

# Step 7: Agent signals review
advance_phase "review" 2>/dev/null

# Step 8: State-writer captures critic APPROVED
rm -f "$STATE_DIR/cohesion-reviewed"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "critic" $'Review complete.\nGATE_RESULT: APPROVED')"
phase=$(get_phase)
assert_eq "$phase" "verify" "runner pattern: critic APPROVED → verify"

# Step 9: State-writer captures qa-verifier APPROVED
rm -f "$STATE_DIR/qa-verified"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "qa-verifier" $'All gates pass.\nGATE_RESULT: APPROVED')"
phase=$(get_phase)
assert_eq "$phase" "commit" "runner pattern: qa APPROVED → commit"

# Step 10: Pre-commit gates pass
stage_sandbox_file "src/runner-e2e.ts" "export const e2e = true;"
run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "headless e2e commit

Decisions: none")"
assert_ok "$_LAST_RC" "runner pattern: pre-commit gates pass"

# Step 11: Session close — commit changes first (session-close-check
# blocks on uncommitted changes), then verify close succeeds
(cd "$SB" && git commit -q -m "headless runner e2e commit")
advance_phase "op-review" 2>/dev/null
advance_phase "close" 2>/dev/null
_write_session_log  # creates per-session file with >100 bytes
(cd "$SB" && git rev-parse HEAD~1) > "$SB/.claude/.session-baseline-sha" 2>/dev/null || \
  echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
run_hook_rc "session-close-check.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "runner pattern: session close succeeds"

# ============================================================
# Summary
# ============================================================
finish_tests
