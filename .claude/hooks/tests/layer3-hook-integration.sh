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
# L3.6 — write-guard.sh: state protection (PreToolUse Edit/Write/Bash)
# ============================================================
tap_section "L3.6: write-guard.sh — .state/ write protection"

# --- Edit targeting .claude/.state/ → blocks ---
run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/.claude/.state/plan-approved")"
assert_fail "$_LAST_RC" "state-guard blocks Edit to .claude/.state/"

# --- Write targeting .claude/.state/ → blocks ---
run_hook_rc "write-guard.sh" "$(fixture_pretooluse_write "$SB/.claude/.state/qa-verified")"
assert_fail "$_LAST_RC" "state-guard blocks Write to .claude/.state/"

# --- Bash redirect to .claude/.state/ → blocks ---
run_hook_rc "write-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/.claude/.state/plan-approved")"
assert_fail "$_LAST_RC" "state-guard blocks Bash redirect to .claude/.state/"

# --- Non-.state/ path → allows (skip mode-guard to isolate state-guard behavior) ---
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "state-guard allows Edit to non-.state/ path"

REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_ok "$_LAST_RC" "state-guard allows Bash redirect to non-.state/ path"

# --- REPO_OS_SKIP_STATE_GUARD=1 → allows ---
REPO_OS_SKIP_STATE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/.claude/.state/plan-approved")"
assert_ok "$_LAST_RC" "state-guard allows .state/ Edit with REPO_OS_SKIP_STATE_GUARD=1"

# --- REPO_OS_RECOVER=1 → allows ---
REPO_OS_RECOVER=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/.claude/.state/plan-approved")"
assert_ok "$_LAST_RC" "state-guard allows .state/ Edit with REPO_OS_RECOVER=1"

# ============================================================
# L3.7 — write-guard.sh: mode restrictions (PreToolUse Edit/Write/Bash)
# ============================================================
tap_section "L3.7: write-guard.sh — operating mode restrictions"

# Sandbox is in template mode (set by setup_hook_sandbox)

# --- Template mode: product path → blocks ---
run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_fail "$_LAST_RC" "mode-guard blocks product path in template mode"

# --- Template mode: carved-out governance path → allows ---
run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/.claude/hooks/test-hook.sh")"
assert_ok "$_LAST_RC" "mode-guard allows .claude/hooks/ in template mode"

run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/docs/ai/decisions/0001-test.md")"
assert_ok "$_LAST_RC" "mode-guard allows docs/ai/decisions/ in template mode"

run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/AI.md")"
assert_ok "$_LAST_RC" "mode-guard allows AI.md in template mode"

# --- Template mode: immune path → blocks (no override possible) ---
run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/.claude/repo-mode")"
assert_fail "$_LAST_RC" "mode-guard blocks .claude/repo-mode (immune path)"

run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/.claude/hooks/write-guard.sh")"
assert_fail "$_LAST_RC" "mode-guard blocks .claude/hooks/write-guard.sh (immune path)"

# --- REPO_OS_UNLOCK_PATH override ---
REPO_OS_UNLOCK_PATH="$SB/docs/spec/compiled/product.md" \
  run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/docs/spec/compiled/product.md")"
assert_ok "$_LAST_RC" "mode-guard allows specific governance path with REPO_OS_UNLOCK_PATH"

# --- REPO_OS_SKIP_MODE_GUARD=1 → allows everything ---
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "mode-guard allows product path with REPO_OS_SKIP_MODE_GUARD=1"

# --- Child mode: fast-exit for product code ---
REPO_OS_MODE=child run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "mode-guard allows product path in child mode"

# --- Child mode: immune path still blocks ---
REPO_OS_MODE=child run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/.claude/repo-mode")"
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
# L3.10 — session-close-check.sh (Stop)
# ============================================================
tap_section "L3.10: session-close-check.sh — session close verification"

# --- Local helpers for L3.10+ ---
# Compute session log hash using the same portable fallback as the hook.
_compute_log_hash() {
  portable_hash < "$SB/.claude/local/session-log.md"
}

# Temp file for capturing hook output without losing _LAST_RC.
# NOTE: output=$(run_hook_rc ...) runs in a subshell — _LAST_RC is lost.
# Use: run_hook_rc ... > "$_L3_OUT" 2>&1  then read "$_L3_OUT".
_L3_OUT="$SB/.claude/.test-hook-output"

# Reinitialize sandbox state after cleanup_session() destroys session files.
_reinit_close_sandbox() {
  echo "test-session-$(date +%s)-$$" > "$SB/.claude/.session-id"
  # Clear caches (analytics-helper caches session ID and branch)
  _CACHED_SESSION_ID=""
  _CACHED_BRANCH=""
  rm -f "$SB/.claude/.state/.stop-attempt-count"
  rm -f "$SB/.claude/.hvst-fail-count"
  rm -f "$SB/.claude/.deferrals-pending"
  # Ensure clean git working tree (earlier tests may leave staged/modified files).
  # git reset --hard clears both index and working tree; git clean removes untracked.
  (cd "$SB" && git reset --hard HEAD 2>/dev/null || true)
  (cd "$SB" && git clean -fd -e .claude/ 2>/dev/null || true)
  reset_phase "standard"
}

# Create session log if missing (template mode uses .claude/local/).
mkdir -p "$SB/.claude/local"
if [ ! -f "$SB/.claude/local/session-log.md" ]; then
  printf '# Session Log (Template Development)\n\nRolling cap: last 5 sessions.\n\n---\n' \
    > "$SB/.claude/local/session-log.md"
fi

# Ensure we're on a feature branch (not main).
switch_sandbox_branch "feature/test"

# --- Test 1: Zero-change session → allow ---
_reinit_close_sandbox
# Store current HEAD as baseline (no new commits = zero-change)
git -C "$SB" rev-parse HEAD > "$SB/.claude/.session-baseline-sha"
# Set hash to current value (not modified)
_compute_log_hash > "$SB/.claude/.session-log-hash"
run_hook_rc "session-close-check.sh" "$(fixture_stop)" > "$_L3_OUT"
assert_ok "$_LAST_RC" "session-close-check allows zero-change session"
assert_contains "$(cat "$_L3_OUT")" "zero-change" "session-close-check emits zero-change advisory"

# --- Test 2: Commits + session log modified → allow ---
_reinit_close_sandbox
# Set a stale hash so current content differs (= modified)
echo "stale-hash-value" > "$SB/.claude/.session-log-hash"
# Invalid baseline SHA → treated as non-zero session (baseline-missing)
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
run_hook_rc "session-close-check.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "session-close-check allows when session log modified and commits exist"

# --- Test 3: Commits + session log NOT modified → block ---
_reinit_close_sandbox
# Hash matches current (not modified)
_compute_log_hash > "$SB/.claude/.session-log-hash"
# Invalid baseline = non-zero session
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
run_hook_rc "session-close-check.sh" "$(fixture_stop)" > "$_L3_OUT"
assert_fail "$_LAST_RC" "session-close-check blocks when session log not modified (non-zero session)"
assert_contains "$(cat "$_L3_OUT")" "Session log not updated" "session-close-check reports session log issue"

# --- Test 4: SKIP_SESSION_LOG=1 override → allow ---
_reinit_close_sandbox
_compute_log_hash > "$SB/.claude/.session-log-hash"
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
SKIP_SESSION_LOG=1 run_hook_rc "session-close-check.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "session-close-check allows with SKIP_SESSION_LOG=1"

# --- Test 5: 3-attempt safety valve → unconditional allow ---
_reinit_close_sandbox
# Set attempt counter to 2 (hook increments to 3, triggers valve)
mkdir -p "$SB/.claude/.state"
echo "2" > "$SB/.claude/.state/.stop-attempt-count"
# Would normally block (log not modified + commits)
_compute_log_hash > "$SB/.claude/.session-log-hash"
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
run_hook_rc "session-close-check.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "session-close-check forces exit after 3 stop attempts (safety valve)"

# --- Test 6: Task group non-final brief → branch NOT sealed ---
_reinit_close_sandbox
echo "stale-hash-value" > "$SB/.claude/.session-log-hash"
# Invalid baseline → non-zero session (avoids zero-change short-circuit)
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
# Set up as taskgroup session
reset_phase "taskgroup"
advance_phase "contract-init" 2>/dev/null
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
# Create a contract with in_progress brief that has next_brief (= non-final)
mkdir -p "$SB/.claude/local/task-groups"
cat > "$SB/.claude/local/task-groups/test-group.yaml" <<'YAML'
name: test-group
briefs:
  - sequence: 1
    branch: "feature/test"
    status: in_progress
    next_brief: "Brief 2"
  - sequence: 2
    status: pending
    next_brief: ""
YAML
rm -f "$SB/.claude/local/closed-branches"
run_hook_rc "session-close-check.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "session-close-check allows taskgroup non-final brief"
# Branch should NOT be in closed-branches ledger
if [ -f "$SB/.claude/local/closed-branches" ] && grep -qxF "feature/test" "$SB/.claude/local/closed-branches" 2>/dev/null; then
  _tap_fail "taskgroup non-final brief does not seal branch" "branch found in closed-branches"
else
  _tap_pass "taskgroup non-final brief does not seal branch"
fi

# --- Test 7: Task group final brief → branch sealed ---
_reinit_close_sandbox
echo "stale-hash-value" > "$SB/.claude/.session-log-hash"
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
reset_phase "taskgroup"
advance_phase "contract-init" 2>/dev/null
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
# Contract with in_progress brief that has empty next_brief (= final brief)
mkdir -p "$SB/.claude/local/task-groups"
cat > "$SB/.claude/local/task-groups/test-group.yaml" <<'YAML'
name: test-group
briefs:
  - sequence: 1
    status: complete
    next_brief: "Brief 2"
  - sequence: 2
    branch: "feature/test"
    status: in_progress
    next_brief: ""
YAML
rm -f "$SB/.claude/local/closed-branches"
run_hook_rc "session-close-check.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "session-close-check allows taskgroup final brief"
assert_file_contains "$SB/.claude/local/closed-branches" "feature/test" \
  "taskgroup final brief seals branch in closed-branches ledger"

# Clean up task group fixtures
rm -rf "$SB/.claude/local/task-groups"
rm -f "$SB/.claude/local/closed-branches"

# ============================================================
# L3.10b — session-close-check.sh early-exit branch sealing
# ============================================================
tap_section "L3.10b: session-close-check.sh — early-exit branch seal"

# --- Test 1: No-init fast exit seals non-taskgroup branch ---
_reinit_close_sandbox
rm -f "$SB/.claude/.state/phase-state"
rm -f "$SB/.claude/local/closed-branches"
run_hook_rc "session-close-check.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "no-init fast exit allows close"
assert_file_contains "$SB/.claude/local/closed-branches" "feature/test" \
  "no-init fast exit seals branch"

# --- Test 2: No-init fast exit detects agent merge signal ---
_reinit_close_sandbox
rm -f "$SB/.claude/.state/phase-state"
rm -f "$SB/.claude/local/closed-branches"
mkdir -p "$SB/.claude/.state"
echo "feature/merged-source" > "$SB/.claude/.state/merge-source-branch"
run_hook_rc "session-close-check.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "no-init fast exit allows close with agent merge"
assert_file_contains "$SB/.claude/local/closed-branches" "feature/merged-source" \
  "no-init fast exit records agent-merged branch"

# --- Test 3: No-init fast exit skips seal for active taskgroup branch ---
_reinit_close_sandbox
rm -f "$SB/.claude/.state/phase-state"
rm -f "$SB/.claude/local/closed-branches"
mkdir -p "$SB/.claude/local/task-groups"
cat > "$SB/.claude/local/task-groups/active-group.yaml" <<'YAML'
identity:
  group_name: active-group
briefs:
  - sequence: 1
    branch: "feature/test"
    status: in_progress
    next_brief: "Brief 2"
  - sequence: 2
    status: pending
    next_brief: ""
YAML
run_hook_rc "session-close-check.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "no-init fast exit allows close for active taskgroup branch"
if [ -f "$SB/.claude/local/closed-branches" ] && grep -qxF "feature/test" "$SB/.claude/local/closed-branches" 2>/dev/null; then
  _tap_fail "no-init fast exit skips seal for active taskgroup branch" "branch found in closed-branches"
else
  _tap_pass "no-init fast exit skips seal for active taskgroup branch"
fi
rm -rf "$SB/.claude/local/task-groups"

# --- Test 4: Zero-change session seals branch ---
_reinit_close_sandbox
git -C "$SB" rev-parse HEAD > "$SB/.claude/.session-baseline-sha"
_compute_log_hash > "$SB/.claude/.session-log-hash"
rm -f "$SB/.claude/local/closed-branches"
run_hook_rc "session-close-check.sh" "$(fixture_stop)" > "$_L3_OUT"
assert_ok "$_LAST_RC" "zero-change session allows close with seal"
assert_file_contains "$SB/.claude/local/closed-branches" "feature/test" \
  "zero-change session seals branch"

# --- Test 5: Zero-change session detects agent merge signal ---
_reinit_close_sandbox
git -C "$SB" rev-parse HEAD > "$SB/.claude/.session-baseline-sha"
_compute_log_hash > "$SB/.claude/.session-log-hash"
rm -f "$SB/.claude/local/closed-branches"
mkdir -p "$SB/.claude/.state"
echo "feature/zero-merged" > "$SB/.claude/.state/merge-source-branch"
run_hook_rc "session-close-check.sh" "$(fixture_stop)" > "$_L3_OUT"
assert_ok "$_LAST_RC" "zero-change session allows close with agent merge"
assert_file_contains "$SB/.claude/local/closed-branches" "feature/zero-merged" \
  "zero-change session records agent-merged branch"

# Clean up
rm -f "$SB/.claude/local/closed-branches"

# ============================================================
# L3.11 — hvst-failure-tracker.sh (PostToolUse / PostToolUseFailure)
# ============================================================
tap_section "L3.11: hvst-failure-tracker.sh — HVST failure counter"

# --- First failure → counter = 1, no HVST warning ---
_reinit_close_sandbox
rm -f "$SB/.claude/.hvst-fail-count"
run_hook_rc "hvst-failure-tracker.sh" "$(fixture_hvst_event "PostToolUseFailure")"
assert_ok "$_LAST_RC" "hvst-tracker exits 0 on first failure"
assert_file_exists "$SB/.claude/.hvst-fail-count" "hvst-tracker creates counter file on failure"
count=$(cat "$SB/.claude/.hvst-fail-count")
assert_eq "$count" "1" "hvst-tracker sets counter to 1 on first failure"

# --- Second failure → counter = 2, emits HVST warning ---
run_hook_rc "hvst-failure-tracker.sh" "$(fixture_hvst_event "PostToolUseFailure")" > "$_L3_OUT"
assert_ok "$_LAST_RC" "hvst-tracker exits 0 on second failure"
count=$(cat "$SB/.claude/.hvst-fail-count")
assert_eq "$count" "2" "hvst-tracker increments counter to 2"
assert_contains "$(cat "$_L3_OUT")" "HVST" "hvst-tracker emits HVST warning at 2 failures"

# --- Third failure → counter = 3, still warns ---
run_hook_rc "hvst-failure-tracker.sh" "$(fixture_hvst_event "PostToolUseFailure")"
assert_ok "$_LAST_RC" "hvst-tracker exits 0 on third failure"
count=$(cat "$SB/.claude/.hvst-fail-count")
assert_eq "$count" "3" "hvst-tracker increments counter to 3"

# --- Success resets counter ---
run_hook_rc "hvst-failure-tracker.sh" "$(fixture_hvst_event "PostToolUse")"
assert_ok "$_LAST_RC" "hvst-tracker exits 0 on success"
count=$(cat "$SB/.claude/.hvst-fail-count")
assert_eq "$count" "0" "hvst-tracker resets counter to 0 on success"

# --- Success when counter already 0 → no crash ---
run_hook_rc "hvst-failure-tracker.sh" "$(fixture_hvst_event "PostToolUse")"
assert_ok "$_LAST_RC" "hvst-tracker exits 0 on success when already at 0"

# --- No counter file + success → no crash ---
rm -f "$SB/.claude/.hvst-fail-count"
run_hook_rc "hvst-failure-tracker.sh" "$(fixture_hvst_event "PostToolUse")"
assert_ok "$_LAST_RC" "hvst-tracker exits 0 when no counter file and success event"

# ============================================================
# L3.12 — pre-push-gates.sh (PreToolUse Bash git push)
# ============================================================
tap_section "L3.12: pre-push-gates.sh — push gate branch naming"

# --- Valid branch: feature/* → allow ---
_reinit_close_sandbox
switch_sandbox_branch "feature/valid-name"
run_hook_rc "pre-push-gates.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "pre-push-gates allows feature/* branch"

# --- Valid branch: fix/* → allow ---
switch_sandbox_branch "fix/bugfix"
run_hook_rc "pre-push-gates.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "pre-push-gates allows fix/* branch"

# --- Valid branch: hotfix/* → allow ---
switch_sandbox_branch "hotfix/urgent"
run_hook_rc "pre-push-gates.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "pre-push-gates allows hotfix/* branch"

# --- Valid branch: experiment/* → allow ---
switch_sandbox_branch "experiment/spike"
run_hook_rc "pre-push-gates.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "pre-push-gates allows experiment/* branch"

# --- main → allow (skips naming check) ---
switch_sandbox_branch "main"
run_hook_rc "pre-push-gates.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "pre-push-gates allows main branch (skips naming check)"

# --- Invalid branch name → block ---
switch_sandbox_branch "invalid_no_category"
run_hook_rc "pre-push-gates.sh" "$(fixture_stop)" > "$_L3_OUT"
assert_fail "$_LAST_RC" "pre-push-gates blocks invalid branch name"
assert_contains "$(cat "$_L3_OUT")" "GATE B1 FAILED" "pre-push-gates reports B1 failure for invalid name"

# --- Bare category without slash-description → block ---
# Use 'release' (not 'feature') because git can't create 'feature' when
# 'feature/test' exists (ref directory conflict).
switch_sandbox_branch "release"
run_hook_rc "pre-push-gates.sh" "$(fixture_stop)"
assert_fail "$_LAST_RC" "pre-push-gates blocks bare category without description"

# --- REPO_OS_RECOVER=1 → bypass all checks ---
switch_sandbox_branch "invalid_no_category"
REPO_OS_RECOVER=1 run_hook_rc "pre-push-gates.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "pre-push-gates allows invalid branch with REPO_OS_RECOVER=1"

# Restore to feature branch
switch_sandbox_branch "feature/test"

# ============================================================
# L3.13 — Agent frontmatter compliance (static analysis)
# ============================================================
tap_section "L3.13: Agent frontmatter compliance — git-guard on Bash-capable agents"

# Rule: agents with Bash access (in tools, not in disallowedTools) must have
# agent-git-guard.sh in their frontmatter hooks (Decision 0003).
AGENTS_DIR="$_HOOKS_DIR/../agents"
COMPLIANCE_FAILURES=""

for agent_file in "$AGENTS_DIR"/*.md; do
  [ -f "$agent_file" ] || continue
  agent_name=$(basename "$agent_file" .md)
  # Skip underscore-prefixed files (shared docs, not standalone agents)
  case "$agent_name" in _*) continue ;; esac
  # Skip orchestrator (top-level agent, not a subagent)
  [ "$agent_name" = "orchestrator" ] && continue

  # Extract frontmatter fields (between first pair of --- delimiters)
  tools_line=$(sed -n '/^---$/,/^---$/{ /^tools:/p; }' "$agent_file" | head -1)
  disallowed_line=$(sed -n '/^---$/,/^---$/{ /^disallowedTools:/p; }' "$agent_file" | head -1)

  # Check if Bash is available (in tools but not disallowed)
  has_bash=false
  case "$tools_line" in *Bash*) has_bash=true ;; esac
  bash_disallowed=false
  case "$disallowed_line" in *Bash*) bash_disallowed=true ;; esac

  if [ "$has_bash" = true ] && [ "$bash_disallowed" = false ]; then
    if ! grep -q "agent-git-guard.sh" "$agent_file" 2>/dev/null; then
      COMPLIANCE_FAILURES="${COMPLIANCE_FAILURES}${agent_name} "
    fi
  fi
done

if [ -z "$COMPLIANCE_FAILURES" ]; then
  _tap_pass "all Bash-capable agents have agent-git-guard.sh hook"
else
  _tap_fail "Bash-capable agents missing agent-git-guard.sh: $COMPLIANCE_FAILURES" \
    "agents with Bash access must have agent-git-guard.sh in frontmatter hooks"
fi

# ============================================================
# L3.14 — Session registry integration
# ============================================================
tap_section "L3.14: Session registry — registration, overlap, and cleanup"

# Ensure we're on a feature branch
switch_sandbox_branch "feature/test"
SESSIONS_DIR="$SB/.claude/.state/sessions"

# --- L3.14.1: init_phase registers session in registry ---
rm -rf "$SESSIONS_DIR"
_CACHED_SESSION_ID=""
_CACHED_BRANCH=""
echo "test-session-l314" > "$SB/.claude/.session-id"
_CACHED_SESSION_ID=""
reset_phase "standard"
if [ -f "$SESSIONS_DIR/test-session-l314.yaml" ]; then
  _tap_pass "init_phase registers session in registry"
else
  _tap_fail "init_phase registers session in registry" "session file not found"
fi

# --- L3.14.2: branch-guard-edit blocks on session overlap ---
_reinit_close_sandbox
rm -rf "$SESSIONS_DIR"
_CACHED_BRANCH=""
reset_phase "standard"
# Advance to build so Gate 2 (phase gate) doesn't block
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
# Current session is registered by init_phase; create overlapping session
SID_L314="$(cat "$SB/.claude/.session-id")"
create_fake_session "overlap-l314" "standard" "feature/test" "$$"
run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")" > "$_L3_OUT" 2>&1
assert_fail "$_LAST_RC" "branch-guard-edit blocks on session overlap"
assert_contains "$(cat "$_L3_OUT")" "BLOCKED" "branch-guard-edit overlap emits BLOCKED"
rm -f "$SESSIONS_DIR/overlap-l314.yaml"

# --- L3.14.3: branch-guard-edit allows task group overlap (advisory) ---
_reinit_close_sandbox
rm -rf "$SESSIONS_DIR"
_CACHED_BRANCH=""
reset_phase "taskgroup"
advance_phase "contract-init" 2>/dev/null
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
SID_L314="$(cat "$SB/.claude/.session-id")"
create_fake_session "overlap-tg-l314" "taskgroup" "feature/test" "$$"
run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")" > "$_L3_OUT" 2>&1
assert_ok "$_LAST_RC" "branch-guard-edit allows task group overlap"
assert_contains "$(cat "$_L3_OUT")" "Advisory" "task group overlap emits Advisory"
rm -f "$SESSIONS_DIR/overlap-tg-l314.yaml"

# --- L3.14.4: taskgroup-merge + taskgroup overlap is advisory ---
_reinit_close_sandbox
rm -rf "$SESSIONS_DIR"
_CACHED_BRANCH=""
reset_phase "taskgroup-merge"
advance_phase "contract-init" 2>/dev/null
advance_phase "cohesion" 2>/dev/null
SID_L314="$(cat "$SB/.claude/.session-id")"
create_fake_session "overlap-tgm-l314" "taskgroup" "feature/test" "$$"
run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")" > "$_L3_OUT" 2>&1
assert_ok "$_LAST_RC" "branch-guard-edit allows taskgroup-merge + taskgroup overlap"
assert_contains "$(cat "$_L3_OUT")" "Advisory" "taskgroup-merge + taskgroup overlap emits Advisory"
rm -f "$SESSIONS_DIR/overlap-tgm-l314.yaml"

# --- L3.14.5: taskgroup-merge + taskgroup-merge overlap is advisory ---
_reinit_close_sandbox
rm -rf "$SESSIONS_DIR"
_CACHED_BRANCH=""
reset_phase "taskgroup-merge"
advance_phase "contract-init" 2>/dev/null
advance_phase "cohesion" 2>/dev/null
SID_L314="$(cat "$SB/.claude/.session-id")"
create_fake_session "overlap-tgm2-l314" "taskgroup-merge" "feature/test" "$$"
run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")" > "$_L3_OUT" 2>&1
assert_ok "$_LAST_RC" "branch-guard-edit allows taskgroup-merge + taskgroup-merge overlap"
assert_contains "$(cat "$_L3_OUT")" "Advisory" "taskgroup-merge + taskgroup-merge overlap emits Advisory"
rm -f "$SESSIONS_DIR/overlap-tgm2-l314.yaml"

# --- L3.14.6 (was .4): branch-guard blocks on session overlap (bash redirect) ---
_reinit_close_sandbox
rm -rf "$SESSIONS_DIR"
_CACHED_BRANCH=""
reset_phase "standard"
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
SID_L314="$(cat "$SB/.claude/.session-id")"
create_fake_session "overlap-bg-l314" "standard" "feature/test" "$$"
run_hook_rc "branch-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/foo.ts")" > "$_L3_OUT" 2>&1
assert_fail "$_LAST_RC" "branch-guard blocks on session overlap (bash redirect)"
rm -f "$SESSIONS_DIR/overlap-bg-l314.yaml"

# --- L3.14.7 (was .5): REPO_OS_SKIP_OVERLAP_CHECK=1 bypasses in branch-guard-edit ---
_reinit_close_sandbox
rm -rf "$SESSIONS_DIR"
_CACHED_BRANCH=""
reset_phase "standard"
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
SID_L314="$(cat "$SB/.claude/.session-id")"
create_fake_session "overlap-skip-l314" "standard" "feature/test" "$$"
REPO_OS_SKIP_OVERLAP_CHECK=1 run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "REPO_OS_SKIP_OVERLAP_CHECK=1 bypasses overlap in branch-guard-edit"
rm -f "$SESSIONS_DIR/overlap-skip-l314.yaml"

# --- L3.14.8 (was .6): REPO_OS_RECOVER=1 bypasses overlap check ---
_reinit_close_sandbox
rm -rf "$SESSIONS_DIR"
_CACHED_BRANCH=""
reset_phase "standard"
SID_L314="$(cat "$SB/.claude/.session-id")"
create_fake_session "overlap-recover-l314" "standard" "feature/test" "$$"
REPO_OS_RECOVER=1 run_hook_rc "branch-guard-edit.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "REPO_OS_RECOVER=1 bypasses overlap check in branch-guard-edit"
rm -f "$SESSIONS_DIR/overlap-recover-l314.yaml"

# --- L3.14.9 (was .7): session-close-check unregisters session ---
_reinit_close_sandbox
rm -rf "$SESSIONS_DIR"
_CACHED_BRANCH=""
# Set up a zero-change session so session-close-check allows close
reset_phase "standard"
SID_L314="$(cat "$SB/.claude/.session-id")"
git -C "$SB" rev-parse HEAD > "$SB/.claude/.session-baseline-sha"
_compute_log_hash > "$SB/.claude/.session-log-hash"
# Verify session file exists (registered by init_phase → register_session)
if [ -f "$SESSIONS_DIR/${SID_L314}.yaml" ]; then
  _tap_pass "session file exists before close"
else
  _tap_fail "session file exists before close" "not found: $SESSIONS_DIR/${SID_L314}.yaml"
fi
run_hook_rc "session-close-check.sh" "$(fixture_stop)" > /dev/null 2>&1
assert_file_not_exists "$SESSIONS_DIR/${SID_L314}.yaml" "session-close-check unregisters session"

# ============================================================
# L3.15 — Parallel task group: merge brief mechanics
# ============================================================
tap_section "L3.15: Parallel task group — merge brief mechanics"

# Ensure we're on a feature branch
switch_sandbox_branch "feature/test"

# --- Test 1: Parallel content brief never seals branch ---
_reinit_close_sandbox
echo "stale-hash-value" > "$SB/.claude/.session-log-hash"
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
reset_phase "taskgroup"
advance_phase "contract-init" 2>/dev/null
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
# Contract with execution: parallel and in_progress + pending briefs
mkdir -p "$SB/.claude/local/task-groups"
cat > "$SB/.claude/local/task-groups/parallel-group.yaml" <<'YAML'
identity:
  group_name: parallel-group
  execution: parallel
briefs:
  - sequence: 1
    branch: "feature/test"
    status: in_progress
    next_brief: "Brief 2"
  - sequence: 2
    status: pending
    next_brief: "Brief 3"
  - sequence: 3
    status: pending
    next_brief: ""
YAML
rm -f "$SB/.claude/local/closed-branches"
run_hook_rc "session-close-check.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "session-close-check allows parallel content brief"
if [ -f "$SB/.claude/local/closed-branches" ] && grep -qxF "feature/test" "$SB/.claude/local/closed-branches" 2>/dev/null; then
  _tap_fail "parallel content brief does not seal branch" "branch found in closed-branches"
else
  _tap_pass "parallel content brief does not seal branch"
fi

# --- Test 2: Merge brief with markers seals branch ---
_reinit_close_sandbox
echo "stale-hash-value" > "$SB/.claude/.session-log-hash"
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
reset_phase "taskgroup-merge"
advance_phase "contract-init" 2>/dev/null
advance_phase "cohesion" 2>/dev/null
advance_phase "verify" 2>/dev/null
advance_phase "commit" 2>/dev/null
# Create completion markers
mkdir -p "$SB/.claude/.state"
echo "2026-01-01T00:00:00Z" > "$SB/.claude/.state/tg-parallel-group-brief-1.complete"
echo "2026-01-01T00:00:00Z" > "$SB/.claude/.state/tg-parallel-group-brief-2.complete"
rm -f "$SB/.claude/local/closed-branches"
run_hook_rc "session-close-check.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "session-close-check allows merge brief with markers"
assert_file_contains "$SB/.claude/local/closed-branches" "feature/test" \
  "merge brief with markers seals branch"

# --- Test 3: Merge brief without markers does NOT seal ---
_reinit_close_sandbox
# Use zero-change path so hook doesn't block on session log
git -C "$SB" rev-parse HEAD > "$SB/.claude/.session-baseline-sha"
_compute_log_hash > "$SB/.claude/.session-log-hash"
reset_phase "taskgroup-merge"
# Remove any markers
rm -f "$SB/.claude/.state"/tg-*-brief-*.complete
rm -f "$SB/.claude/local/closed-branches"
run_hook_rc "session-close-check.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "session-close-check allows merge brief without markers (zero-change)"
if [ -f "$SB/.claude/local/closed-branches" ] && grep -qxF "feature/test" "$SB/.claude/local/closed-branches" 2>/dev/null; then
  _tap_fail "merge brief without markers does not seal branch" "branch found in closed-branches"
else
  _tap_pass "merge brief without markers does not seal branch"
fi

# --- Test 4: Marker cleanup for taskgroup-merge ---
_reinit_close_sandbox
# Zero-change session so hook allows close
git -C "$SB" rev-parse HEAD > "$SB/.claude/.session-baseline-sha"
_compute_log_hash > "$SB/.claude/.session-log-hash"
reset_phase "taskgroup-merge"
mkdir -p "$SB/.claude/.state"
echo "2026-01-01T00:00:00Z" > "$SB/.claude/.state/tg-test-group-brief-1.complete"
echo "2026-01-01T00:00:00Z" > "$SB/.claude/.state/tg-test-group-brief-2.complete"
run_hook_rc "session-close-check.sh" "$(fixture_stop)" > /dev/null 2>&1
assert_ok "$_LAST_RC" "session-close-check completes for taskgroup-merge cleanup test"
# Markers should be cleaned up
if ls "$SB/.claude/.state"/tg-*-brief-*.complete 2>/dev/null | grep -q .; then
  _tap_fail "taskgroup-merge cleanup removes completion markers" "markers still exist"
else
  _tap_pass "taskgroup-merge cleanup removes completion markers"
fi

# --- Test 5: Markers preserved for taskgroup (non-merge) ---
_reinit_close_sandbox
# Zero-change session
git -C "$SB" rev-parse HEAD > "$SB/.claude/.session-baseline-sha"
_compute_log_hash > "$SB/.claude/.session-log-hash"
reset_phase "taskgroup"
mkdir -p "$SB/.claude/.state"
echo "2026-01-01T00:00:00Z" > "$SB/.claude/.state/tg-test-group-brief-1.complete"
# Need a contract so is_final_brief doesn't return n/a
mkdir -p "$SB/.claude/local/task-groups"
cat > "$SB/.claude/local/task-groups/test-group.yaml" <<'YAML'
identity:
  group_name: test-group
  execution: parallel
briefs:
  - sequence: 1
    branch: "feature/test"
    status: in_progress
    next_brief: "Brief 2"
  - sequence: 2
    status: pending
    next_brief: ""
YAML
run_hook_rc "session-close-check.sh" "$(fixture_stop)" > /dev/null 2>&1
assert_ok "$_LAST_RC" "session-close-check completes for taskgroup marker preservation test"
assert_file_exists "$SB/.claude/.state/tg-test-group-brief-1.complete" \
  "taskgroup session preserves completion markers"

# Clean up parallel test fixtures
rm -rf "$SB/.claude/local/task-groups"
rm -f "$SB/.claude/local/closed-branches"
rm -f "$SB/.claude/.state"/tg-*-brief-*.complete

# ============================================================
# Summary
# ============================================================
finish_tests