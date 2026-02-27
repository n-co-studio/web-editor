#!/usr/bin/env bash
# Layer 3 — Hook integration tests.
# Exercises every hook at the phase transitions where it fires.
# Verifies allow/block/advance behavior and inter-hook state chains.
#
# Requires: jq (hooks use jq to parse stdin payloads).
# Bash 3.2 compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/test-helpers.sh"

# jq is required for hook integration tests (hooks parse JSON with jq)
if ! command -v jq &>/dev/null; then
  printf "# Layer 3 skipped: jq not available\n"
  printf "1..0\n"
  exit 0
fi

setup_hook_sandbox

# Validate fixture JSON before running tests
_fixtures_self_test

# Shorthand for sandbox paths
SB="$(get_sandbox)"
STATE_DIR="$SB/.claude/.state"

# ============================================================
# L3.1 — branch-guard-edit.sh (PreToolUse Edit/Write)
# ============================================================
tap_section "L3.1: branch-guard-edit.sh — phase gate and branch protection"

# --- Gate 2: Phase gate blocks in init/plan ---
reset_phase "standard"
# Phase is init — edit to source file should be blocked
run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_fail "$_LAST_RC" "branch-guard-edit blocks edit in init phase"

reset_phase "standard"
advance_phase "plan" 2>/dev/null
# Phase is plan — still blocked
run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_fail "$_LAST_RC" "branch-guard-edit blocks edit in plan phase"

# --- Gate 2: Allows edit in build phase ---
reset_phase "standard"
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "branch-guard-edit allows edit in build phase"

# --- Gate 2: Allows edit in later phases (review, verify, commit) ---
advance_phase "review" 2>/dev/null
run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "branch-guard-edit allows edit in review phase"

# --- Gate 2: Path exemptions in init phase ---
reset_phase "standard"
# .claude/.state/ is exempt (bootstrap writes)
run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/.claude/.state/test-file")"
assert_ok "$_LAST_RC" "branch-guard-edit allows .claude/.state/ edit in init phase"

# .claude/local/ is exempt (session-scoped)
run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/.claude/local/session-log.md")"
assert_ok "$_LAST_RC" "branch-guard-edit allows .claude/local/ edit in init phase"

# docs/ai/governance/ is exempt
run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/docs/ai/governance/spec-compiled")"
assert_ok "$_LAST_RC" "branch-guard-edit allows docs/ai/governance/ edit in init phase"

# docs/ai/task-groups/ is exempt
run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/docs/ai/task-groups/test.yaml")"
assert_ok "$_LAST_RC" "branch-guard-edit allows docs/ai/task-groups/ edit in init phase"

# --- Gate 2: Session type exemptions ---
reset_phase "experiment"
run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "branch-guard-edit allows edit for experiment session type"

reset_phase "prototype-napkin"
run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "branch-guard-edit allows edit for prototype-napkin session type"

reset_phase "prototype-spike"
run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "branch-guard-edit allows edit for prototype-spike session type"

reset_phase "prototype-poc"
run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "branch-guard-edit allows edit for prototype-poc session type"

# --- Gate 2: Fail-open when no phase-state ---
rm -f "$STATE_DIR/phase-state"
run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "branch-guard-edit fails open when no phase-state"

# --- Gate 1: Main branch protection ---
reset_phase "standard"
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
switch_sandbox_branch "main"
run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_fail "$_LAST_RC" "branch-guard-edit blocks edit on main branch"

# REPO_OS_ALLOW_MAIN=1 override
REPO_OS_ALLOW_MAIN=1 run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "branch-guard-edit allows edit on main with REPO_OS_ALLOW_MAIN=1"

switch_sandbox_branch "feature/test"

# --- REPO_OS_RECOVER=1 bypasses all gates ---
reset_phase "standard"
# Phase is init (would normally block)
REPO_OS_RECOVER=1 run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "branch-guard-edit allows edit with REPO_OS_RECOVER=1"

# --- Gate 5: Closed branch protection ---
reset_phase "standard"
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
mkdir -p "$SB/.claude/local"
echo "feature/test" > "$SB/.claude/local/closed-branches"
run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_fail "$_LAST_RC" "branch-guard-edit blocks edit on closed branch"

# REPO_OS_SKIP_BRANCH_REUSE=1 override
REPO_OS_SKIP_BRANCH_REUSE=1 run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "branch-guard-edit allows edit on closed branch with REPO_OS_SKIP_BRANCH_REUSE=1"

# Clean up closed-branches for subsequent tests
rm -f "$SB/.claude/local/closed-branches"

# ============================================================
# L3.2 — branch-guard.sh (PreToolUse Bash)
# ============================================================
tap_section "L3.2: branch-guard.sh — bash write-target gate"

# --- Fast-exit for non-write Bash commands ---
reset_phase "standard"
# No redirect/tee, no file_path → fast-exit allow
run_hook_rc "branch-guard.sh" "$(fixture_pretooluse_bash "git status")"
assert_ok "$_LAST_RC" "branch-guard allows bash without write target (git status)"

run_hook_rc "branch-guard.sh" "$(fixture_pretooluse_bash "npm test")"
assert_ok "$_LAST_RC" "branch-guard allows bash without write target (npm test)"

# --- Gate 2: Bash with in-repo write target in init phase → blocks ---
reset_phase "standard"
run_hook_rc "branch-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_fail "$_LAST_RC" "branch-guard blocks bash redirect in init phase"

# --- Gate 2: Bash with write target in build phase → allows ---
reset_phase "standard"
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
run_hook_rc "branch-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_ok "$_LAST_RC" "branch-guard allows bash redirect in build phase"

# --- experiment/* branch exemption ---
reset_phase "standard"
switch_sandbox_branch "experiment/test"
run_hook_rc "branch-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_ok "$_LAST_RC" "branch-guard allows bash redirect on experiment/* branch"
switch_sandbox_branch "feature/test"

# --- Session type without plan gate → allows ---
reset_phase "advisory-init"
run_hook_rc "branch-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_ok "$_LAST_RC" "branch-guard allows bash redirect for advisory-init (no plan gate)"

# --- Gate 1: Main branch protection ---
reset_phase "standard"
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
switch_sandbox_branch "main"
run_hook_rc "branch-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_fail "$_LAST_RC" "branch-guard blocks bash redirect on main branch"
switch_sandbox_branch "feature/test"

# --- REPO_OS_SKIP_PLAN_GATE=1 override ---
reset_phase "standard"
REPO_OS_SKIP_PLAN_GATE=1 run_hook_rc "branch-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_ok "$_LAST_RC" "branch-guard allows bash redirect with REPO_OS_SKIP_PLAN_GATE=1"

# --- REPO_OS_RECOVER=1 override ---
reset_phase "standard"
REPO_OS_RECOVER=1 run_hook_rc "branch-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_ok "$_LAST_RC" "branch-guard allows bash redirect with REPO_OS_RECOVER=1"

# --- Out-of-repo write target → allows ---
reset_phase "standard"
run_hook_rc "branch-guard.sh" "$(fixture_pretooluse_bash "echo test > /tmp/outside.txt")"
assert_ok "$_LAST_RC" "branch-guard allows bash redirect to out-of-repo path"

# ============================================================
# L3.3 — plan-approval.sh (PostToolUse AskUserQuestion)
# ============================================================
tap_section "L3.3: plan-approval.sh — plan approval detection and phase advance"

# --- Plan question + affirmative → writes state + advances ---
reset_phase "standard"
advance_phase "plan" 2>/dev/null
rm -f "$STATE_DIR/plan-approved"
run_hook_rc "plan-approval.sh" \
  "$(fixture_posttooluse_ask "Do you approve this plan?" "Yes approve,No revise" "Yes approve")"
assert_ok "$_LAST_RC" "plan-approval exits 0 (PostToolUse never blocks)"
assert_file_exists "$STATE_DIR/plan-approved" "plan-approval writes plan-approved state file"

# Verify phase advanced to build
phase_after=$(get_phase)
assert_eq "$phase_after" "build" "plan-approval advances phase to build"

# --- Plan question + negative answer → no state written ---
reset_phase "standard"
advance_phase "plan" 2>/dev/null
rm -f "$STATE_DIR/plan-approved"
run_hook_rc "plan-approval.sh" \
  "$(fixture_posttooluse_ask "Do you approve this plan?" "Yes approve,No revise" "No, please revise")"
assert_ok "$_LAST_RC" "plan-approval exits 0 on negative answer"
assert_file_not_exists "$STATE_DIR/plan-approved" "plan-approval does not write state on negative answer"

# Phase should remain at plan
phase_after=$(get_phase)
assert_eq "$phase_after" "plan" "plan-approval does not advance phase on negative answer"

# --- Non-plan question → no action ---
reset_phase "standard"
advance_phase "plan" 2>/dev/null
rm -f "$STATE_DIR/plan-approved"
run_hook_rc "plan-approval.sh" \
  "$(fixture_posttooluse_ask "Which library should we use?" "React,Vue" "React")"
assert_ok "$_LAST_RC" "plan-approval exits 0 on non-plan question"
assert_file_not_exists "$STATE_DIR/plan-approved" "plan-approval does not write state for non-plan question"

# --- Auto mode detection ---
reset_phase "standard"
advance_phase "plan" 2>/dev/null
rm -f "$STATE_DIR/plan-approved"
run_hook_rc "plan-approval.sh" \
  "$(fixture_posttooluse_ask "Do you approve this plan?" "Yes auto,No revise" "Yes auto")"
mode_after=$(get_phase_mode)
assert_eq "$mode_after" "auto" "plan-approval sets mode to auto when answer contains 'auto'"

# --- Review mode wins if both present ---
reset_phase "standard"
advance_phase "plan" 2>/dev/null
rm -f "$STATE_DIR/plan-approved"
run_hook_rc "plan-approval.sh" \
  "$(fixture_posttooluse_ask "Do you approve this plan?" "Yes auto,Review mode" "Yes approve review")"
mode_after=$(get_phase_mode)
assert_eq "$mode_after" "review" "plan-approval sets mode to review when both auto and review in answer"

# --- Spec session: approval advances to governance ---
reset_phase "spec-fresh"
advance_phase "interview" 2>/dev/null
advance_phase "write" 2>/dev/null
rm -f "$STATE_DIR/plan-approved"
run_hook_rc "plan-approval.sh" \
  "$(fixture_posttooluse_ask "Do you approve this plan?" "Yes approve,No revise" "Yes approve")"
phase_after=$(get_phase)
assert_eq "$phase_after" "governance" "plan-approval advances spec-fresh to governance after approval"

# ============================================================
# L3.4 — state-writer.sh (SubagentStop)
# ============================================================
tap_section "L3.4: state-writer.sh — governance agent state capture and phase advance"

# --- critic APPROVED → writes cohesion-reviewed + advances review→verify ---
reset_phase "standard"
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
advance_phase "review" 2>/dev/null
rm -f "$STATE_DIR/cohesion-reviewed"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "critic" $'Review complete.\nGATE_RESULT: APPROVED')"
assert_ok "$_LAST_RC" "state-writer exits 0 (never blocks)"
assert_file_exists "$STATE_DIR/cohesion-reviewed" "state-writer writes cohesion-reviewed on critic APPROVED"
phase_after=$(get_phase)
assert_eq "$phase_after" "verify" "state-writer advances review→verify on critic APPROVED"

# --- critic BLOCKED → writes file but does NOT advance phase ---
reset_phase "standard"
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
advance_phase "review" 2>/dev/null
rm -f "$STATE_DIR/cohesion-reviewed"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "critic" $'Issues found.\nGATE_RESULT: BLOCKED - 3 critical findings')"
assert_file_exists "$STATE_DIR/cohesion-reviewed" "state-writer writes cohesion-reviewed on critic BLOCKED"
phase_after=$(get_phase)
assert_eq "$phase_after" "review" "state-writer does NOT advance phase on critic BLOCKED"

# --- qa-verifier APPROVED → writes qa-verified + advances verify→commit ---
reset_phase "standard"
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
advance_phase "review" 2>/dev/null
advance_phase "verify" 2>/dev/null
rm -f "$STATE_DIR/qa-verified"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "qa-verifier" $'All gates pass.\nGATE_RESULT: APPROVED')"
assert_file_exists "$STATE_DIR/qa-verified" "state-writer writes qa-verified on qa-verifier APPROVED"
phase_after=$(get_phase)
assert_eq "$phase_after" "commit" "state-writer advances verify→commit on qa-verifier APPROVED"

# --- qa-verifier BLOCKED → writes file but does NOT advance ---
reset_phase "standard"
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
advance_phase "review" 2>/dev/null
advance_phase "verify" 2>/dev/null
rm -f "$STATE_DIR/qa-verified"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "qa-verifier" $'Gate B2 failed.\nGATE_RESULT: BLOCKED - gate failures')"
assert_file_exists "$STATE_DIR/qa-verified" "state-writer writes qa-verified on qa-verifier BLOCKED"
phase_after=$(get_phase)
assert_eq "$phase_after" "verify" "state-writer does NOT advance phase on qa-verifier BLOCKED"

# --- reviewer → writes reviewer-signed, no phase advance ---
reset_phase "standard"
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
advance_phase "review" 2>/dev/null
advance_phase "verify" 2>/dev/null
rm -f "$STATE_DIR/reviewer-signed"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "reviewer" $'Code looks good.\nGATE_RESULT: APPROVED')"
assert_file_exists "$STATE_DIR/reviewer-signed" "state-writer writes reviewer-signed"
# reviewer does not advance phase (sub-step within verify)
phase_after=$(get_phase)
assert_eq "$phase_after" "verify" "state-writer does not advance phase for reviewer"

# --- security-privacy → writes security-signed, no phase advance ---
rm -f "$STATE_DIR/security-signed"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "security-privacy" $'No issues.\nGATE_RESULT: APPROVED')"
assert_file_exists "$STATE_DIR/security-signed" "state-writer writes security-signed"

# --- Non-governance agent → early exit, no file written ---
rm -f "$STATE_DIR/cohesion-reviewed" "$STATE_DIR/qa-verified" "$STATE_DIR/reviewer-signed" "$STATE_DIR/security-signed"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "builder" "Implementation complete.")"
assert_ok "$_LAST_RC" "state-writer exits 0 for non-governance agent"
assert_file_not_exists "$STATE_DIR/cohesion-reviewed" "state-writer writes nothing for builder agent"
assert_file_not_exists "$STATE_DIR/qa-verified" "state-writer writes nothing for builder agent (qa)"

# --- Empty last_message → skip ---
reset_phase "standard"
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
advance_phase "review" 2>/dev/null
rm -f "$STATE_DIR/cohesion-reviewed"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "critic" "")"
assert_file_not_exists "$STATE_DIR/cohesion-reviewed" "state-writer skips on empty last_message"

# --- No GATE_RESULT sentinel → skip ---
rm -f "$STATE_DIR/cohesion-reviewed"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "critic" "Review done but no sentinel line")"
assert_file_not_exists "$STATE_DIR/cohesion-reviewed" "state-writer skips without GATE_RESULT sentinel"

# ============================================================
# L3.5 — pre-commit-gates.sh (PreToolUse Bash git commit)
# ============================================================
tap_section "L3.5: pre-commit-gates.sh — commit gate verification"

# --- Phase at commit + all state files → allows ---
reset_phase "standard"
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
advance_phase "review" 2>/dev/null
advance_phase "verify" 2>/dev/null
advance_phase "commit" 2>/dev/null
# Create all required state files
echo "timestamp: test" > "$STATE_DIR/plan-approved"
echo "timestamp: test" > "$STATE_DIR/cohesion-reviewed"
echo "timestamp: test" > "$STATE_DIR/qa-verified"
# Stage a clean file (no secrets)
stage_sandbox_file "src/clean.ts" "export const x = 1;"
run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "test commit")"
assert_ok "$_LAST_RC" "pre-commit-gates allows commit at commit phase with all state files"

# --- Phase before commit → blocks ---
reset_phase "standard"
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
echo "timestamp: test" > "$STATE_DIR/plan-approved"
echo "timestamp: test" > "$STATE_DIR/cohesion-reviewed"
echo "timestamp: test" > "$STATE_DIR/qa-verified"
stage_sandbox_file "src/clean2.ts" "export const y = 2;"
run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "test commit")"
assert_fail "$_LAST_RC" "pre-commit-gates blocks commit when phase is build (not commit)"

# --- Experiment branch → A4 only, skip state checks ---
reset_phase "experiment"
switch_sandbox_branch "experiment/test"
rm -f "$STATE_DIR/plan-approved" "$STATE_DIR/cohesion-reviewed" "$STATE_DIR/qa-verified"
stage_sandbox_file "src/exp.ts" "export const z = 3;"
run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "experiment commit")"
assert_ok "$_LAST_RC" "pre-commit-gates allows experiment branch without state files (A4 only)"
switch_sandbox_branch "feature/test"

# --- No phase-state + missing state files → blocks ---
rm -f "$STATE_DIR/phase-state" "$STATE_DIR/plan-approved" "$STATE_DIR/cohesion-reviewed" "$STATE_DIR/qa-verified"
stage_sandbox_file "src/nostate.ts" "export const w = 4;"
run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "test commit")"
assert_fail "$_LAST_RC" "pre-commit-gates blocks when no phase-state and state files missing"

# --- No phase-state + all state files → allows ---
rm -f "$STATE_DIR/phase-state"
echo "timestamp: test" > "$STATE_DIR/plan-approved"
echo "timestamp: test" > "$STATE_DIR/cohesion-reviewed"
echo "timestamp: test" > "$STATE_DIR/qa-verified"
stage_sandbox_file "src/withstate.ts" "export const v = 5;"
run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "test commit")"
assert_ok "$_LAST_RC" "pre-commit-gates allows when no phase-state but all state files present"

# --- Hotfix branch: skips cohesion-reviewed check ---
reset_phase "hotfix"
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
advance_phase "verify" 2>/dev/null
advance_phase "commit" 2>/dev/null
switch_sandbox_branch "hotfix/test"
echo "timestamp: test" > "$STATE_DIR/plan-approved"
rm -f "$STATE_DIR/cohesion-reviewed"
echo "timestamp: test" > "$STATE_DIR/qa-verified"
stage_sandbox_file "src/hotfix.ts" "export const h = 6;"
run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "hotfix commit")"
assert_ok "$_LAST_RC" "pre-commit-gates allows hotfix commit without cohesion-reviewed"
switch_sandbox_branch "feature/test"

# --- Phase passed + missing state files → advisory (not blocking) ---
reset_phase "standard"
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
advance_phase "review" 2>/dev/null
advance_phase "verify" 2>/dev/null
advance_phase "commit" 2>/dev/null
rm -f "$STATE_DIR/plan-approved" "$STATE_DIR/cohesion-reviewed" "$STATE_DIR/qa-verified"
stage_sandbox_file "src/phasepass.ts" "export const p = 7;"
output=$(run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "test commit")")
assert_ok "$_LAST_RC" "pre-commit-gates allows when phase passed even with missing state files"
assert_contains "$output" "Advisory" "pre-commit-gates emits advisory warnings for missing state files"

# --- REPO_OS_RECOVER=1 → skips state checks ---
rm -f "$STATE_DIR/phase-state" "$STATE_DIR/plan-approved" "$STATE_DIR/cohesion-reviewed" "$STATE_DIR/qa-verified"
stage_sandbox_file "src/recover.ts" "export const r = 8;"
REPO_OS_RECOVER=1 run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "recover commit")"
assert_ok "$_LAST_RC" "pre-commit-gates allows commit with REPO_OS_RECOVER=1"

# --- A4: Secret scanning blocks ---
reset_phase "standard"
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
advance_phase "review" 2>/dev/null
advance_phase "verify" 2>/dev/null
advance_phase "commit" 2>/dev/null
echo "timestamp: test" > "$STATE_DIR/plan-approved"
echo "timestamp: test" > "$STATE_DIR/cohesion-reviewed"
echo "timestamp: test" > "$STATE_DIR/qa-verified"
stage_sandbox_file "src/secrets.ts" "const key = 'sk_live_abc123def456';"
run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "test commit")"
assert_fail "$_LAST_RC" "pre-commit-gates blocks commit with secret pattern in staged file"

# Clean up staged secret file
(cd "$SB" && git reset HEAD src/secrets.ts 2>/dev/null && rm -f src/secrets.ts) || true

# ============================================================
# L3.6 — state-guard.sh (PreToolUse Edit/Write/Bash)
# ============================================================
tap_section "L3.6: state-guard.sh — .state/ write protection"

# --- Edit targeting .claude/.state/ → blocks ---
run_hook_rc "state-guard.sh" "$(fixture_pretooluse_edit "$SB/.claude/.state/plan-approved")"
assert_fail "$_LAST_RC" "state-guard blocks Edit to .claude/.state/"

# --- Write targeting .claude/.state/ → blocks ---
run_hook_rc "state-guard.sh" "$(fixture_pretooluse_write "$SB/.claude/.state/qa-verified")"
assert_fail "$_LAST_RC" "state-guard blocks Write to .claude/.state/"

# --- Bash redirect to .claude/.state/ → blocks ---
run_hook_rc "state-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/.claude/.state/plan-approved")"
assert_fail "$_LAST_RC" "state-guard blocks Bash redirect to .claude/.state/"

# --- Non-.state/ path → allows ---
run_hook_rc "state-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "state-guard allows Edit to non-.state/ path"

run_hook_rc "state-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_ok "$_LAST_RC" "state-guard allows Bash redirect to non-.state/ path"

# --- REPO_OS_SKIP_STATE_GUARD=1 → allows ---
REPO_OS_SKIP_STATE_GUARD=1 run_hook_rc "state-guard.sh" "$(fixture_pretooluse_edit "$SB/.claude/.state/plan-approved")"
assert_ok "$_LAST_RC" "state-guard allows .state/ Edit with REPO_OS_SKIP_STATE_GUARD=1"

# --- REPO_OS_RECOVER=1 → allows ---
REPO_OS_RECOVER=1 run_hook_rc "state-guard.sh" "$(fixture_pretooluse_edit "$SB/.claude/.state/plan-approved")"
assert_ok "$_LAST_RC" "state-guard allows .state/ Edit with REPO_OS_RECOVER=1"

# ============================================================
# L3.7 — mode-guard.sh (PreToolUse Edit/Write/Bash)
# ============================================================
tap_section "L3.7: mode-guard.sh — operating mode restrictions"

# Sandbox is in template mode (set by setup_hook_sandbox)

# --- Template mode: product path → blocks ---
run_hook_rc "mode-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_fail "$_LAST_RC" "mode-guard blocks product path in template mode"

# --- Template mode: carved-out governance path → allows ---
run_hook_rc "mode-guard.sh" "$(fixture_pretooluse_edit "$SB/.claude/hooks/test-hook.sh")"
assert_ok "$_LAST_RC" "mode-guard allows .claude/hooks/ in template mode"

run_hook_rc "mode-guard.sh" "$(fixture_pretooluse_edit "$SB/docs/ai/decisions/0001-test.md")"
assert_ok "$_LAST_RC" "mode-guard allows docs/ai/decisions/ in template mode"

run_hook_rc "mode-guard.sh" "$(fixture_pretooluse_edit "$SB/AI.md")"
assert_ok "$_LAST_RC" "mode-guard allows AI.md in template mode"

# --- Template mode: immune path → blocks (no override possible) ---
run_hook_rc "mode-guard.sh" "$(fixture_pretooluse_edit "$SB/.claude/repo-mode")"
assert_fail "$_LAST_RC" "mode-guard blocks .claude/repo-mode (immune path)"

run_hook_rc "mode-guard.sh" "$(fixture_pretooluse_edit "$SB/.claude/hooks/mode-guard.sh")"
assert_fail "$_LAST_RC" "mode-guard blocks .claude/hooks/mode-guard.sh (immune path)"

# --- REPO_OS_UNLOCK_PATH override ---
REPO_OS_UNLOCK_PATH="$SB/docs/spec/compiled/product.md" \
  run_hook_rc "mode-guard.sh" "$(fixture_pretooluse_edit "$SB/docs/spec/compiled/product.md")"
assert_ok "$_LAST_RC" "mode-guard allows specific governance path with REPO_OS_UNLOCK_PATH"

# --- REPO_OS_SKIP_MODE_GUARD=1 → allows everything ---
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "mode-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "mode-guard allows product path with REPO_OS_SKIP_MODE_GUARD=1"

# --- Child mode: fast-exit for product code ---
REPO_OS_MODE=child run_hook_rc "mode-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "mode-guard allows product path in child mode"

# --- Child mode: immune path still blocks ---
REPO_OS_MODE=child run_hook_rc "mode-guard.sh" "$(fixture_pretooluse_edit "$SB/.claude/repo-mode")"
assert_fail "$_LAST_RC" "mode-guard blocks immune path even in child mode"

# ============================================================
# L3.8 — State chain integration (full lifecycle)
# ============================================================
tap_section "L3.8: State chain integration — full standard session lifecycle"

# Full standard session lifecycle:
# init → plan → (plan-approval fires) → build → review →
# (state-writer critic APPROVED) → verify → (state-writer qa APPROVED) →
# commit → (pre-commit-gates passes)

reset_phase "standard"
advance_phase "plan" 2>/dev/null

# Plan approval fires (PostToolUse AskUserQuestion)
rm -f "$STATE_DIR/plan-approved"
run_hook_rc "plan-approval.sh" \
  "$(fixture_posttooluse_ask "Do you approve this plan?" "Yes approve,No revise" "Yes approve")"
phase_after=$(get_phase)
assert_eq "$phase_after" "build" "lifecycle: plan-approval advances to build"
assert_file_exists "$STATE_DIR/plan-approved" "lifecycle: plan-approved state file written"

# Agent does build work, then advances to review
advance_phase "review" 2>/dev/null

# Critic fires (SubagentStop)
rm -f "$STATE_DIR/cohesion-reviewed"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "critic" $'No issues found.\nGATE_RESULT: APPROVED')"
phase_after=$(get_phase)
assert_eq "$phase_after" "verify" "lifecycle: critic APPROVED advances review→verify"

# QA-verifier fires (SubagentStop)
rm -f "$STATE_DIR/qa-verified"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "qa-verifier" $'All gates pass.\nGATE_RESULT: APPROVED')"
phase_after=$(get_phase)
assert_eq "$phase_after" "commit" "lifecycle: qa-verifier APPROVED advances verify→commit"

# Pre-commit gates pass
stage_sandbox_file "src/lifecycle.ts" "export const lifecycle = true;"
run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "lifecycle commit")"
assert_ok "$_LAST_RC" "lifecycle: pre-commit-gates passes at commit phase"

# --- Critic BLOCKED loop path ---
tap_section "L3.8b: State chain — critic BLOCKED loop"

reset_phase "standard"
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
advance_phase "review" 2>/dev/null

# Critic returns BLOCKED — phase stays at review
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "critic" $'3 findings.\nGATE_RESULT: BLOCKED - critical issues')"
phase_after=$(get_phase)
assert_eq "$phase_after" "review" "loop: critic BLOCKED keeps phase at review"

# Orchestrator loops: review→build (defined loop in standard)
advance_phase "build" 2>/dev/null
phase_after=$(get_phase)
assert_eq "$phase_after" "build" "loop: review→build loop succeeds"

# Agent fixes issues, advances back to review
advance_phase "review" 2>/dev/null

# Critic runs again — this time APPROVED
rm -f "$STATE_DIR/cohesion-reviewed"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "critic" $'All clear.\nGATE_RESULT: APPROVED')"
phase_after=$(get_phase)
assert_eq "$phase_after" "verify" "loop: second critic APPROVED advances to verify"

# ============================================================
# L3.9 — Error / edge case tests
# ============================================================
tap_section "L3.9: Error and edge case tests"

# --- Corrupt phase-state (empty file) → hooks fail-open ---
echo "" > "$STATE_DIR/phase-state"
run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "branch-guard-edit fails open on corrupt (empty) phase-state"

# --- Wrong session ID → hooks fail-open ---
reset_phase "standard"
set_test_session_id "different-session-id"
run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "branch-guard-edit fails open on session-ID mismatch"

# Also test branch-guard
run_hook_rc "branch-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_ok "$_LAST_RC" "branch-guard fails open on session-ID mismatch"

# Restore session ID
set_test_session_id "test-session-$(date +%s)"

# --- Missing phase-state file entirely → hooks fail-open ---
rm -f "$STATE_DIR/phase-state"
run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "branch-guard-edit fails open when phase-state missing"

run_hook_rc "branch-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_ok "$_LAST_RC" "branch-guard fails open when phase-state missing"

# Pre-commit-gates without phase-state falls back to state file checks
rm -f "$STATE_DIR/phase-state"
echo "timestamp: test" > "$STATE_DIR/plan-approved"
echo "timestamp: test" > "$STATE_DIR/cohesion-reviewed"
echo "timestamp: test" > "$STATE_DIR/qa-verified"
stage_sandbox_file "src/nophase.ts" "export const np = 1;"
run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "test commit")"
assert_ok "$_LAST_RC" "pre-commit-gates falls back to state files when phase-state missing"

# ============================================================
# Summary
# ============================================================
finish_tests