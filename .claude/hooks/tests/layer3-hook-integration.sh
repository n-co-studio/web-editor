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
# Per-session state dir (Decision 0030): state files live under
# wt-sessions/{sid}/, not the flat .claude/.state/. The sid is stable across
# reset_phase, so this resolves once and stays valid for the whole layer.
STATE_DIR="$(get_session_state_dir)"
TEST_SID="$(get_test_session_id)"

# --- Substance-aware _advance wrapper ---
# Pre-writes state files required by _advance substance checks (Brief 1).
# Without these, _advance returns non-zero and set -e kills the script.
_advance() {
  local phase="$1"
  local sd
  sd="$(get_session_state_dir)"
  local sid
  sid=$(cat "$SB/.claude/.session-id")
  case "$phase" in
    plan)
      # Decision 0038: a drift-check phase sits immediately before plan in
      # standard (after init) and taskgroup (after contract-init). Walk through
      # it first whenever the sequence places it directly before plan and we are
      # not already on it.
      case " $(get_phases_for_type "$(get_session_type)") " in
        *" drift-check plan "*)
          if [ "$(get_phase)" != "drift-check" ]; then
            advance_phase "drift-check" 2>/dev/null || true
          fi
          ;;
      esac
      # Pragmatist sign-off precedes operator approval (Decision 0025), so seed
      # it: the plan-approval hook advances approval->build, and the approval
      # step is gated on pragmatist-signed.
      printf 'timestamp: test\nagent: pragmatist\nsession_id: %s\ndispatch_phase: plan\nGATE_RESULT: APPROVED\n' "$sid" > "$sd/pragmatist-signed"
      ;;
    approval)
      printf 'timestamp: test\nagent: pragmatist\nsession_id: %s\ndispatch_phase: plan\nGATE_RESULT: APPROVED\n' "$sid" > "$sd/pragmatist-signed"
      printf 'timestamp: test\nsession_id: %s\nmode: auto\n' "$sid" > "$sd/plan-approved"
      ;;
    verify)
      # Critic combined mode (Decision 0039) writes BOTH cohesion-reviewed and
      # diff-review-complete; the A5 commit gate requires both. Seed both.
      printf 'timestamp: test\nagent: critic\nsession_id: %s\ndispatch_phase: review\nGATE_RESULT: APPROVED\n' "$sid" > "$sd/cohesion-reviewed"
      printf 'timestamp: test\nagent: critic\nsession_id: %s\ndispatch_phase: review\nMODE: diff-review\nGATE_RESULT: APPROVED\n' "$sid" > "$sd/diff-review-complete"
      ;;
    commit)
      printf 'timestamp: test\nagent: qa-verifier\nsession_id: %s\ndispatch_phase: verify\nGATE_RESULT: APPROVED\n' "$sid" > "$sd/qa-verified"
      ;;
  esac
  advance_phase "$phase" 2>/dev/null
}

# ============================================================
# L3.1 — write-guard.sh Section 3 (PreToolUse Edit/Write bash-guard gates)
# ============================================================
tap_section "L3.1: write-guard.sh Section 3 — phase gate and branch protection"

# --- Gate 2: Phase gate blocks in init/plan ---
reset_phase "standard"
# Phase is init — edit to source file should be blocked
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_hook_blocks "$_LAST_RC" "write-guard blocks edit in init phase"

reset_phase "standard"
_advance "plan" 2>/dev/null
# Phase is plan — still blocked
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_hook_blocks "$_LAST_RC" "write-guard blocks edit in plan phase"

# --- Gate 2: Allows edit in build phase ---
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "write-guard allows edit in build phase"

# --- Gate 2: Allows edit in later phases (review, verify, commit) ---
_advance "review" 2>/dev/null
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "write-guard allows edit in review phase"

# --- Gate 2: Path exemptions in init phase ---
reset_phase "standard"
# .claude/.state/ is exempt (bootstrap writes)
REPO_OS_SKIP_STATE_GUARD=1 REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/.claude/.state/test-file")"
assert_ok "$_LAST_RC" "write-guard allows .claude/.state/ edit in init phase"

# .claude/local/sessions/ is exempt (per-session log files)
run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/.claude/local/sessions/session-test.md")"
assert_ok "$_LAST_RC" "write-guard allows .claude/local/sessions/ edit in init phase"

# docs/ai/governance/ is exempt (skip mode-guard — not carved out in template mode)
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/docs/ai/governance/spec-compiled")"
assert_ok "$_LAST_RC" "write-guard allows docs/ai/governance/ edit in init phase"

# docs/ai/task-groups/ is exempt (skip mode-guard — not carved out in template mode)
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/docs/ai/task-groups/test.yaml")"
assert_ok "$_LAST_RC" "write-guard allows docs/ai/task-groups/ edit in init phase"

# --- Gate 2: Session type exemptions ---
reset_phase "experiment"
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "write-guard allows edit for experiment session type"

reset_phase "prototype-napkin"
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "write-guard allows edit for prototype-napkin session type"

reset_phase "prototype-spike"
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "write-guard allows edit for prototype-spike session type"

reset_phase "prototype-poc"
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "write-guard allows edit for prototype-poc session type"

# --- Gate 2: Fail-open when no phase-state ---
rm -f "$STATE_DIR/phase-state"
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "write-guard fails open when no phase-state"

# --- Gate 1: Main branch protection ---
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
switch_sandbox_branch "main"
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_hook_blocks "$_LAST_RC" "write-guard blocks edit on main branch"

# REPO_OS_ALLOW_MAIN=1 override
REPO_OS_ALLOW_MAIN=1 REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "write-guard allows edit on main with REPO_OS_ALLOW_MAIN=1"

switch_sandbox_branch "feature/test"

# --- REPO_OS_RECOVER=1 bypasses all gates ---
reset_phase "standard"
# Phase is init (would normally block)
REPO_OS_RECOVER=1 REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "write-guard allows edit with REPO_OS_RECOVER=1"

# --- Gate 5: Closed branch protection ---
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
mkdir -p "$SB/.claude/local"
echo "feature/test" > "$SB/.claude/local/closed-branches"
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_hook_blocks "$_LAST_RC" "write-guard blocks edit on closed branch"

# REPO_OS_SKIP_BRANCH_REUSE=1 override
REPO_OS_SKIP_BRANCH_REUSE=1 REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "write-guard allows edit on closed branch with REPO_OS_SKIP_BRANCH_REUSE=1"

# Clean up closed-branches for subsequent tests
rm -f "$SB/.claude/local/closed-branches"

# ============================================================
# L3.1b — write-guard.sh Gate 2 (phase-type): session-type write-phase enforcement
# ============================================================
tap_section "L3.1b: write-guard.sh Gate 2 phase-type — session-type write-phase enforcement"

# --- finish-loop: blocked in assess phase ---
reset_phase "finish-loop"
_advance "assess" 2>/dev/null
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_hook_blocks "$_LAST_RC" "write-guard blocks edit in finish-loop assess phase"

# --- finish-loop: blocked in reassess phase ---
reset_phase "finish-loop"
_advance "assess" 2>/dev/null
_advance "fix" 2>/dev/null
_advance "reassess" 2>/dev/null
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_hook_blocks "$_LAST_RC" "write-guard blocks edit in finish-loop reassess phase"

# --- finish-loop: allowed in fix phase ---
reset_phase "finish-loop"
_advance "assess" 2>/dev/null
_advance "fix" 2>/dev/null
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "write-guard allows edit in finish-loop fix phase"

# --- finish-loop: allowed in commit phase ---
reset_phase "finish-loop"
_advance "assess" 2>/dev/null
_advance "fix" 2>/dev/null
_advance "reassess" 2>/dev/null
_advance "commit" 2>/dev/null
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "write-guard allows edit in finish-loop commit phase"

# --- standard: build still allowed (regression check) ---
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "write-guard still allows edit in standard build phase (regression)"

# --- finish-loop assess: path exemptions still work ---
reset_phase "finish-loop"
_advance "assess" 2>/dev/null
# docs/ai/governance/ exempt (skip mode-guard — not carved out in template mode)
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/docs/ai/governance/evidence.md")"
assert_ok "$_LAST_RC" "write-guard allows docs/ai/governance/ edit in finish-loop assess (path exempt)"
# docs/ai/task-groups/ exempt (skip mode-guard — not carved out in template mode)
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/docs/ai/task-groups/test.yaml")"
assert_ok "$_LAST_RC" "write-guard allows docs/ai/task-groups/ edit in finish-loop assess (path exempt)"

# --- REPO_OS_SKIP_PLAN_GATE=1 overrides phase-type gate ---
reset_phase "finish-loop"
_advance "assess" 2>/dev/null
REPO_OS_SKIP_PLAN_GATE=1 REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "write-guard allows edit in finish-loop assess with REPO_OS_SKIP_PLAN_GATE=1"

# --- editor-live: all phases exempt from phase-type gate ---
reset_phase "editor-live"
_advance "build" 2>/dev/null
_advance "commit" 2>/dev/null
_advance "review" 2>/dev/null
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "write-guard allows edit for editor-live (all phases exempt)"

# ============================================================
# L3.2 — bash-guard.sh (PreToolUse Bash)
# ============================================================
tap_section "L3.2: bash-guard.sh — bash write-target gate"

# --- Fast-exit for non-write Bash commands ---
reset_phase "standard"
# No redirect/tee, no file_path → fast-exit allow
run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "git status")"
assert_ok "$_LAST_RC" "bash-guard allows bash without write target (git status)"

run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "npm test")"
assert_ok "$_LAST_RC" "bash-guard allows bash without write target (npm test)"

# --- Gate 2: Bash with in-repo write target in init phase → blocks ---
reset_phase "standard"
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_hook_blocks "$_LAST_RC" "bash-guard blocks bash redirect in init phase"

# --- Gate 2: Bash with write target in build phase → allows ---
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_ok "$_LAST_RC" "bash-guard allows bash redirect in build phase"

# --- experiment/* branch exemption ---
reset_phase "standard"
switch_sandbox_branch "experiment/test"
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_ok "$_LAST_RC" "bash-guard allows bash redirect on experiment/* branch"
switch_sandbox_branch "feature/test"

# --- Session type without plan gate → allows ---
reset_phase "advisory-init"
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_ok "$_LAST_RC" "bash-guard allows bash redirect for advisory-init (no plan gate)"

# --- Gate 1: Main branch protection ---
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
switch_sandbox_branch "main"
run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_hook_blocks "$_LAST_RC" "bash-guard blocks bash redirect on main branch"
switch_sandbox_branch "feature/test"

# --- REPO_OS_SKIP_PLAN_GATE=1 override ---
reset_phase "standard"
REPO_OS_SKIP_PLAN_GATE=1 REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_ok "$_LAST_RC" "bash-guard allows bash redirect with REPO_OS_SKIP_PLAN_GATE=1"

# --- REPO_OS_RECOVER=1 override ---
reset_phase "standard"
REPO_OS_RECOVER=1 run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_ok "$_LAST_RC" "bash-guard allows bash redirect with REPO_OS_RECOVER=1"

# --- Out-of-repo write target → allows ---
reset_phase "standard"
run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "echo test > /tmp/outside.txt")"
assert_ok "$_LAST_RC" "bash-guard allows bash redirect to out-of-repo path"

# ============================================================
# L3.3 — plan-approval.sh (PostToolUse AskUserQuestion)
# ============================================================
tap_section "L3.3: plan-approval.sh — plan approval detection and phase advance"

# --- Plan question + affirmative → writes state + advances ---
reset_phase "standard"
_advance "plan" 2>/dev/null
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
_advance "plan" 2>/dev/null
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
_advance "plan" 2>/dev/null
rm -f "$STATE_DIR/plan-approved"
run_hook_rc "plan-approval.sh" \
  "$(fixture_posttooluse_ask "Which library should we use?" "React,Vue" "React")"
assert_ok "$_LAST_RC" "plan-approval exits 0 on non-plan question"
assert_file_not_exists "$STATE_DIR/plan-approved" "plan-approval does not write state for non-plan question"

# --- Auto mode detection ---
reset_phase "standard"
_advance "plan" 2>/dev/null
rm -f "$STATE_DIR/plan-approved"
run_hook_rc "plan-approval.sh" \
  "$(fixture_posttooluse_ask "Do you approve this plan?" "Yes auto,No revise" "Yes auto")"
mode_after=$(get_phase_mode)
assert_eq "$mode_after" "auto" "plan-approval sets mode to auto when answer contains 'auto'"

# --- Review mode wins if both present ---
reset_phase "standard"
_advance "plan" 2>/dev/null
rm -f "$STATE_DIR/plan-approved"
run_hook_rc "plan-approval.sh" \
  "$(fixture_posttooluse_ask "Do you approve this plan?" "Yes auto,Review mode" "Yes approve review")"
mode_after=$(get_phase_mode)
assert_eq "$mode_after" "review" "plan-approval sets mode to review when both auto and review in answer"

# --- Regression: "Approve"-only wording (no "yes"/"proceed") still confirms ---
# Guards the fix for the Gate 2 regex bug where the trailing word boundary in
# `approv\b` prevented "approve"/"approval"/"approved" from ever matching, so a
# question/options worded only with "Approve" silently failed to write state.
# The fixture question keeps the word "plan" so Gate 1 (plan|brief|task) passes
# and execution actually reaches the Gate 2 path under test.
reset_phase "standard"
_advance "plan" 2>/dev/null
rm -f "$STATE_DIR/plan-approved"
run_hook_rc "plan-approval.sh" \
  "$(fixture_posttooluse_ask "Approve this plan?" "Approve,Adjust" "Approve")"
assert_ok "$_LAST_RC" "plan-approval exits 0 on Approve-only wording (PostToolUse never blocks)"
assert_file_exists "$STATE_DIR/plan-approved" "plan-approval writes state on Approve-only wording (no 'yes'/'proceed')"
phase_after=$(get_phase)
assert_eq "$phase_after" "build" "plan-approval advances to build on Approve-only wording"

# --- Regression: bare "Auto"/"Review" option selection counts as affirmative ---
# The canonical plan-approval template (Prompt B / orchestrator.md) offers the
# options "Auto" and "Review" — both are approvals. Guards the fix for the bug
# where the affirmative-answer regex matched only yes/approve/proceed/etc, so a
# bare "Auto" or "Review" selection silently failed to write plan-approved and
# blocked advance_phase build. The question keeps "plan"+"Approve" so Gates 1+2
# pass and execution reaches the Gate 3 affirmative check under test.
reset_phase "standard"
_advance "plan" 2>/dev/null
rm -f "$STATE_DIR/plan-approved"
run_hook_rc "plan-approval.sh" \
  "$(fixture_posttooluse_ask "Approve this plan?" "Auto,Review" "Auto")"
assert_file_exists "$STATE_DIR/plan-approved" "plan-approval writes state on bare 'Auto' selection"
assert_eq "$(get_phase_mode)" "auto" "plan-approval sets auto mode on bare 'Auto' selection"
assert_eq "$(get_phase)" "build" "plan-approval advances to build on bare 'Auto' selection"

reset_phase "standard"
_advance "plan" 2>/dev/null
rm -f "$STATE_DIR/plan-approved"
run_hook_rc "plan-approval.sh" \
  "$(fixture_posttooluse_ask "Approve this plan?" "Auto,Review" "Review")"
assert_file_exists "$STATE_DIR/plan-approved" "plan-approval writes state on bare 'Review' selection"
assert_eq "$(get_phase_mode)" "review" "plan-approval sets review mode on bare 'Review' selection"

# --- Spec session: approval advances to governance ---
reset_phase "spec-fresh"
_advance "interview" 2>/dev/null
_advance "write" 2>/dev/null
rm -f "$STATE_DIR/plan-approved"
# Pragmatist sign-off precedes operator approval (Decision 0025); spec-fresh
# reaches approval via write (not the standard plan phase), so seed it here so
# plan-approval's internal approval->governance advance is not gate-blocked.
printf 'GATE_RESULT: APPROVED\nagent: pragmatist\nsession_id: %s\ndispatch_phase: plan\n' "$TEST_SID" > "$STATE_DIR/pragmatist-signed"
run_hook_rc "plan-approval.sh" \
  "$(fixture_posttooluse_ask "Do you approve this plan?" "Yes approve,No revise" "Yes approve")"
phase_after=$(get_phase)
assert_eq "$phase_after" "governance" "plan-approval advances spec-fresh to governance after approval"

# --- R28: Gates 1+2 pass but answer not affirmative → WARNING, no state written ---
# Before R28 this path exited 0 silently. The operator got a not_approved hook
# event log entry but zero stderr feedback — the previous plan-approved on disk
# looked current and the only trace was in the event log.
reset_phase "standard"
_advance "plan" 2>/dev/null
rm -f "$STATE_DIR/plan-approved"
run_hook_rc "plan-approval.sh" \
  "$(fixture_posttooluse_ask "Do you approve this plan?" "All four, reaping first (Recommended),Revise" "All four, reaping first (Recommended)")"
assert_ok "$_LAST_RC" "plan-approval exits 0 even when answer is non-affirmative (PostToolUse never blocks)"
assert_file_not_exists "$STATE_DIR/plan-approved" "plan-approval does not write state when answer has no affirmative keyword"
assert_contains "$_LAST_OUTPUT" "WARNING" "plan-approval emits WARNING on non-affirmative answer to plan question"
assert_contains "$_LAST_OUTPUT" "NOT recorded" "plan-approval WARNING names the failure"

# --- R28: Gate 1 miss with Gate 2 present → WARNING (Decision t-0058) ---
# A question about "units of work" (no plan/brief/task) with approval language
# in the options previously exited 0 with no trace at all. Under t-0058, when
# Gate 2 passes but Gate 1 does not, a WARNING is emitted so the operator knows
# the approval was not captured.
reset_phase "standard"
_advance "plan" 2>/dev/null
rm -f "$STATE_DIR/plan-approved"
run_hook_rc "plan-approval.sh" \
  "$(fixture_posttooluse_ask "Which units of work should we proceed with?" "Approve all,Adjust" "Approve all")"
assert_ok "$_LAST_RC" "plan-approval exits 0 on Gate-1 miss (PostToolUse never blocks)"
assert_file_not_exists "$STATE_DIR/plan-approved" "plan-approval does not write state on Gate-1 miss"
assert_contains "$_LAST_OUTPUT" "WARNING" "plan-approval emits WARNING when Gate 2 passes but Gate 1 does not (Decision t-0058)"

# --- R28: non-approval question (Gate 2 also misses) → no WARNING, silent exit ---
# A bare non-plan, non-approval question must still exit silently — the warning
# must not fire on every AskUserQuestion call, only when approval intent is present.
reset_phase "standard"
_advance "plan" 2>/dev/null
rm -f "$STATE_DIR/plan-approved"
run_hook_rc "plan-approval.sh" \
  "$(fixture_posttooluse_ask "Which library should we use?" "React,Vue" "React")"
assert_ok "$_LAST_RC" "plan-approval exits 0 on non-plan non-approval question"
case "$_LAST_OUTPUT" in
  *WARNING*) assert_fail "0" "no WARNING on non-plan non-approval question (got: '$_LAST_OUTPUT')" ;;
  *) assert_ok "0" "no WARNING on non-plan non-approval question (silent as before)" ;;
esac

# --- R28: written plan-approved includes stale_check field ---
reset_phase "standard"
_advance "plan" 2>/dev/null
rm -f "$STATE_DIR/plan-approved"
run_hook_rc "plan-approval.sh" \
  "$(fixture_posttooluse_ask "Do you approve this plan?" "Yes approve,No revise" "Yes approve")"
assert_file_contains "$STATE_DIR/plan-approved" "stale_check:" "plan-approved includes stale_check hint"

# ============================================================
# L3.4 — state-writer.sh (SubagentStop)
# ============================================================
tap_section "L3.4: state-writer.sh — governance agent state capture and phase advance"

# --- critic APPROVED → writes cohesion-reviewed + advances review→verify ---
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
_advance "review" 2>/dev/null
rm -f "$STATE_DIR/cohesion-reviewed"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "critic" $'Review complete.\nGATE_RESULT: APPROVED')"
assert_ok "$_LAST_RC" "state-writer exits 0 (never blocks)"
assert_file_exists "$STATE_DIR/cohesion-reviewed" "state-writer writes cohesion-reviewed on critic APPROVED"
phase_after=$(get_phase)
assert_eq "$phase_after" "verify" "state-writer advances review→verify on critic APPROVED"

# --- t-0059: a critic dispatched LATE is accepted, with the discrepancy recorded ---
# Between 2026-10-20 and 22, twenty verdicts were discarded on the dispatch-phase
# check. Every one was at or after the expected phase — a critic dispatched from
# `verify` or `commit` while expecting `review` — and every one carried
# GATE_RESULT: APPROVED. Discarding them made the gate they fed unsatisfiable,
# and with no backward edge from `commit` five sessions were stuck and lost
# their work. Accepting at-or-after is the fix; see the EARLY case below for the
# half that must still be refused.
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
_advance "review" 2>/dev/null
_advance "verify" 2>/dev/null
rm -f "$STATE_DIR/cohesion-reviewed"
# Pin the precondition. Without this the case passes trivially whenever the
# advance to `verify` did not take: the phase stays at `review`, there is no
# mismatch to forgive, and the verdict is accepted by the ordinary path — so the
# assertion below would be green with or without the fix. Assert the phase is
# actually ahead of `review` before invoking the hook.
assert_eq "$(get_phase)" "verify" "t-0059: precondition — phase is ahead of review before dispatch"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "critic" $'Review complete.\nGATE_RESULT: APPROVED')"
assert_file_exists "$STATE_DIR/cohesion-reviewed" "t-0059: critic dispatched from verify is ACCEPTED (was discarded)"
# Assert the phase NAME, not just the prefix. A prefix-only assertion passed
# while the line read "dispatched from -e" — a mangled substitution that made
# the record useless for the reader it exists for, and the test could not see it.
assert_file_contains "$STATE_DIR/cohesion-reviewed" "dispatch_phase_discrepancy: dispatched from verify, expected review" "t-0059: the discrepancy names the actual phases"
assert_file_contains "$STATE_DIR/cohesion-reviewed" "GATE_RESULT:" "t-0059: the discrepancy line does not displace GATE_RESULT"

# --- t-0059: the COMBINED write path records the phases too ---
# The case above exercises only the single-mode write. Combined mode is the
# DEFAULT critic dispatch (t-0039) and writes two files through a separate
# printf, so an `-e`-style regression reintroduced there alone would pass the
# suite green — which is exactly how the first one survived.
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
_advance "review" 2>/dev/null
_advance "verify" 2>/dev/null
rm -f "$STATE_DIR/cohesion-reviewed" "$STATE_DIR/diff-review-complete"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "critic" $'## Cohesion Brief\nNo incoherence found.\nGATE_RESULT: APPROVED\n\n## Diff-Review Brief\nNo mechanical defects.\nGATE_RESULT: APPROVED')"
assert_file_contains "$STATE_DIR/cohesion-reviewed" "dispatch_phase_discrepancy: dispatched from verify, expected review" "t-0059: combined mode records the phases in cohesion-reviewed"
assert_file_contains "$STATE_DIR/diff-review-complete" "dispatch_phase_discrepancy: dispatched from verify, expected review" "t-0059: combined mode records the phases in diff-review-complete"

# --- t-0059: a critic dispatched EARLY is still refused ---
# This is the half that must not be relaxed. A critic dispatched at `plan`, before
# the code exists, would review an empty diff and return APPROVED — and the commit
# gates check only that `dispatch_phase:` is present, never its value. Accepting
# that would make A5 satisfiable without the built code ever being reviewed.
reset_phase "standard"
_advance "plan" 2>/dev/null
rm -f "$STATE_DIR/cohesion-reviewed"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "critic" $'Looks fine.\nGATE_RESULT: APPROVED')"
assert_file_not_exists "$STATE_DIR/cohesion-reviewed" "t-0059: critic dispatched from plan (EARLY) is still refused"

# --- t-0059: the override restores exact-match behaviour ---
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
_advance "review" 2>/dev/null
_advance "verify" 2>/dev/null
rm -f "$STATE_DIR/cohesion-reviewed"
REPO_OS_STRICT_DISPATCH_PHASE=1 run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "critic" $'Review complete.\nGATE_RESULT: APPROVED')"
assert_file_not_exists "$STATE_DIR/cohesion-reviewed" "t-0059: REPO_OS_STRICT_DISPATCH_PHASE=1 restores strict rejection"

# --- critic BLOCKED → writes file but does NOT advance phase ---
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
_advance "review" 2>/dev/null
rm -f "$STATE_DIR/cohesion-reviewed"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "critic" $'Issues found.\nGATE_RESULT: BLOCKED - 3 critical findings')"
assert_file_exists "$STATE_DIR/cohesion-reviewed" "state-writer writes cohesion-reviewed on critic BLOCKED"
phase_after=$(get_phase)
assert_eq "$phase_after" "review" "state-writer does NOT advance phase on critic BLOCKED"

# --- qa-verifier APPROVED → writes qa-verified + advances verify→commit ---
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
_advance "review" 2>/dev/null
_advance "verify" 2>/dev/null
rm -f "$STATE_DIR/qa-verified"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "qa-verifier" $'All gates pass.\nGATE_RESULT: APPROVED')"
assert_file_exists "$STATE_DIR/qa-verified" "state-writer writes qa-verified on qa-verifier APPROVED"
phase_after=$(get_phase)
assert_eq "$phase_after" "commit" "state-writer advances verify→commit on qa-verifier APPROVED"

# --- qa-verifier BLOCKED → writes file but does NOT advance ---
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
_advance "review" 2>/dev/null
_advance "verify" 2>/dev/null
rm -f "$STATE_DIR/qa-verified"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "qa-verifier" $'Gate B2 failed.\nGATE_RESULT: BLOCKED - gate failures')"
assert_file_exists "$STATE_DIR/qa-verified" "state-writer writes qa-verified on qa-verifier BLOCKED"
phase_after=$(get_phase)
assert_eq "$phase_after" "verify" "state-writer does NOT advance phase on qa-verifier BLOCKED"

# --- reviewer → writes reviewer-signed, no phase advance ---
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
_advance "review" 2>/dev/null
_advance "verify" 2>/dev/null
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
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
_advance "review" 2>/dev/null
rm -f "$STATE_DIR/cohesion-reviewed"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "critic" "")"
assert_file_not_exists "$STATE_DIR/cohesion-reviewed" "state-writer skips on empty last_message"

# --- No GATE_RESULT sentinel → skip ---
rm -f "$STATE_DIR/cohesion-reviewed"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "critic" "Review done but no sentinel line")"
assert_file_not_exists "$STATE_DIR/cohesion-reviewed" "state-writer skips without GATE_RESULT sentinel"

# --- Critic combined output (Decision 0039) → writes BOTH state files ---
# Combined output has both '## Cohesion Brief' and '## Diff-Review Brief' headers,
# each terminating with its own GATE_RESULT. state-writer.sh splits at the
# diff-review header and routes per-section verdicts to separate state files.
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
_advance "review" 2>/dev/null
rm -f "$STATE_DIR/cohesion-reviewed" "$STATE_DIR/diff-review-complete"
_combined_body=$'## Cohesion Brief\n\nFindings: none\nCOMPLETENESS: 2/2 criteria met\nCOMPLETENESS_GATE: APPROVED\n\nGATE_RESULT: APPROVED\n\n## Diff-Review Brief\n\nFindings: none\n\nMODE: diff-review\nGATE_RESULT: APPROVED'
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "critic" "$_combined_body")"
assert_ok "$_LAST_RC" "state-writer exits 0 on combined output"
assert_file_exists "$STATE_DIR/cohesion-reviewed" "combined output writes cohesion-reviewed"
assert_file_exists "$STATE_DIR/diff-review-complete" "combined output writes diff-review-complete"
phase_after=$(get_phase)
assert_eq "$phase_after" "verify" "combined output (cohesion APPROVED) advances review→verify"
# Cohesion file captures the cohesion-section GATE_RESULT and completeness sentinels
grep -q '^GATE_RESULT: APPROVED' "$STATE_DIR/cohesion-reviewed" \
  && grep -q '^COMPLETENESS_GATE: APPROVED' "$STATE_DIR/cohesion-reviewed" \
  && _combined_co_ok=1 || _combined_co_ok=0
assert_eq "$_combined_co_ok" "1" "cohesion-reviewed contains GATE_RESULT + COMPLETENESS_GATE"

# --- Combined output with cohesion BLOCKED → both files written, no phase advance ---
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
_advance "review" 2>/dev/null
rm -f "$STATE_DIR/cohesion-reviewed" "$STATE_DIR/diff-review-complete"
_combined_blocked=$'## Cohesion Brief\n\nFindings: broken ref\n\nGATE_RESULT: BLOCKED reason="broken-ref"\n\n## Diff-Review Brief\n\nFindings: none\n\nMODE: diff-review\nGATE_RESULT: APPROVED'
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "critic" "$_combined_blocked")"
assert_file_exists "$STATE_DIR/cohesion-reviewed" "combined cohesion-BLOCKED still writes cohesion-reviewed"
assert_file_exists "$STATE_DIR/diff-review-complete" "combined cohesion-BLOCKED still writes diff-review-complete"
phase_after=$(get_phase)
assert_eq "$phase_after" "review" "combined cohesion-BLOCKED does NOT advance phase"
grep -q '^GATE_RESULT: BLOCKED' "$STATE_DIR/cohesion-reviewed" && _combined_block_ok=1 || _combined_block_ok=0
assert_eq "$_combined_block_ok" "1" "cohesion-reviewed records BLOCKED verdict"

# --- Combined output with diff-review BLOCKED → both files written, cohesion advances ---
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
_advance "review" 2>/dev/null
rm -f "$STATE_DIR/cohesion-reviewed" "$STATE_DIR/diff-review-complete"
_combined_diff_blocked=$'## Cohesion Brief\n\nFindings: none\n\nGATE_RESULT: APPROVED\n\n## Diff-Review Brief\n\nFindings: broken import\n\nMODE: diff-review\nGATE_RESULT: BLOCKED reason="broken-import"'
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "critic" "$_combined_diff_blocked")"
assert_file_exists "$STATE_DIR/cohesion-reviewed" "diff-BLOCKED still writes cohesion-reviewed"
assert_file_exists "$STATE_DIR/diff-review-complete" "diff-BLOCKED still writes diff-review-complete"
grep -q '^GATE_RESULT: BLOCKED' "$STATE_DIR/diff-review-complete" && _combined_diff_block_ok=1 || _combined_diff_block_ok=0
assert_eq "$_combined_diff_block_ok" "1" "diff-review-complete records BLOCKED verdict"

# --- Combined output missing a GATE_RESULT in one section → skip writes ---
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
_advance "review" 2>/dev/null
rm -f "$STATE_DIR/cohesion-reviewed" "$STATE_DIR/diff-review-complete"
_combined_malformed=$'## Cohesion Brief\n\nFindings: none\n\n## Diff-Review Brief\n\nFindings: none\n\nMODE: diff-review\nGATE_RESULT: APPROVED'
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "critic" "$_combined_malformed")"
assert_file_not_exists "$STATE_DIR/cohesion-reviewed" "malformed combined output does not write cohesion-reviewed"
assert_file_not_exists "$STATE_DIR/diff-review-complete" "malformed combined output does not write diff-review-complete"

# --- Legacy single diff-review mode (MODE: diff-review only) still routes correctly ---
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
_advance "review" 2>/dev/null
rm -f "$STATE_DIR/cohesion-reviewed" "$STATE_DIR/diff-review-complete"
_legacy_diff=$'## Diff-Review Brief\n\nFindings: none\n\nMODE: diff-review\nGATE_RESULT: APPROVED'
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "critic" "$_legacy_diff")"
assert_file_not_exists "$STATE_DIR/cohesion-reviewed" "legacy diff-review output does NOT write cohesion-reviewed"
assert_file_exists "$STATE_DIR/diff-review-complete" "legacy diff-review output writes diff-review-complete"

# ============================================================
# L3.4b — state-writer.sh: discarded verdicts are reported, not silent
# ============================================================
tap_section "L3.4b: state-writer.sh — every rejection path writes an escalation"
# Before 2026-09-01 only the phase-mismatch path wrote a verdict-rejected escalation.
# The two formatting rejections logged an NDJSON 'skip' line and nothing else, so a
# discarded review was indistinguishable from an agent that had not finished yet —
# two real BLOCKED verdicts were lost this way during the t-0047 work.
#
# These tests assert the REPORTING is present. The parse contract still holds:
# Decision t-0039 requires GATE_RESULT: to be the terminal MEANINGFUL line of each
# section, so trailing prose, headings or table rows must still be rejections. The
# one deliberate relaxation is content-free punctuation — a bare horizontal rule —
# which `_last_meaningful_line` skips; see combined_separator below.
_ESC_DIR="$SB/.claude/.automation/escalations"

# --- no_sentinel: trailing prose after GATE_RESULT → rejected AND escalated ---
reset_phase "standard"
_advance "plan" 2>/dev/null; _advance "approval" 2>/dev/null
_advance "build" 2>/dev/null; _advance "review" 2>/dev/null
rm -f "$STATE_DIR/cohesion-reviewed"
rm -rf "$_ESC_DIR"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "critic" $'Review complete.\nGATE_RESULT: APPROVED\n\nRelevant files: foo.sh')"
assert_ok "$_LAST_RC" "state-writer exits 0 on no_sentinel (never blocks)"
assert_file_not_exists "$STATE_DIR/cohesion-reviewed" \
  "no_sentinel still rejects the verdict (t-0039 contract intact)"
if ls "$_ESC_DIR"/verdict-rejected-critic-* >/dev/null 2>&1; then
  _tap_pass "no_sentinel writes a verdict-rejected escalation"
else
  _tap_fail "no_sentinel writes a verdict-rejected escalation" "no escalation file in $_ESC_DIR"
fi

# --- combined_separator: a bare horizontal rule between sections is ACCEPTED ---
# This case previously asserted rejection. It was changed deliberately: a bare
# `---` between the two sections is punctuation, not verdict content, and
# treating it as content discarded seven real reviews across critic (3),
# qa-verifier (2) and security-privacy (2). On 2026-10-12 a critic emitted this
# exact shape and BOTH verdicts were thrown away — including a correctly
# terminated diff-review section — then it re-emitted the same shape on
# re-dispatch, looping the brief until it was force-stopped. Decision t-0039's
# contract is that GATE_RESULT: is TERMINAL, i.e. no verdict content after it;
# `_last_meaningful_line` in state-writer.sh now skips blanks and bare rules
# only. The combined_trailing_prose case below keeps the contract covered.
reset_phase "standard"
_advance "plan" 2>/dev/null; _advance "approval" 2>/dev/null
_advance "build" 2>/dev/null; _advance "review" 2>/dev/null
rm -f "$STATE_DIR/cohesion-reviewed" "$STATE_DIR/diff-review-complete"
rm -rf "$_ESC_DIR"
_split_out=$'## Cohesion Brief\n\nFindings: none\n\nGATE_RESULT: APPROVED\n\n---\n\n## Diff-Review Brief\n\nFindings: none\n\nMODE: diff-review\nGATE_RESULT: APPROVED'
run_hook_rc "state-writer.sh" "$(fixture_subagentstop "critic" "$_split_out")"
assert_file_exists "$STATE_DIR/cohesion-reviewed" \
  "combined_separator accepts the cohesion verdict despite a trailing ---"
assert_file_exists "$STATE_DIR/diff-review-complete" \
  "combined_separator accepts the diff-review verdict too"
if ls "$_ESC_DIR"/verdict-rejected-critic-* >/dev/null 2>&1; then
  _tap_fail "combined_separator writes NO verdict-rejected escalation" "escalation written for a well-formed review"
else
  _tap_pass "combined_separator writes NO verdict-rejected escalation"
fi

# --- combined_trailing_prose: real content after the sentinel → still rejected ---
# Replaces the coverage the separator case used to provide. Prose after
# GATE_RESULT: means the agent kept talking, which is what t-0039 forbids.
reset_phase "standard"
_advance "plan" 2>/dev/null; _advance "approval" 2>/dev/null
_advance "build" 2>/dev/null; _advance "review" 2>/dev/null
rm -f "$STATE_DIR/cohesion-reviewed" "$STATE_DIR/diff-review-complete"
rm -rf "$_ESC_DIR"
_prose_out=$'## Cohesion Brief\n\nFindings: none\n\nGATE_RESULT: APPROVED\n\nOne further thought on naming.\n\n## Diff-Review Brief\n\nFindings: none\n\nMODE: diff-review\nGATE_RESULT: APPROVED'
run_hook_rc "state-writer.sh" "$(fixture_subagentstop "critic" "$_prose_out")"
assert_file_not_exists "$STATE_DIR/cohesion-reviewed" \
  "combined_trailing_prose still rejects both verdicts (t-0039 contract intact)"
if ls "$_ESC_DIR"/verdict-rejected-critic-* >/dev/null 2>&1; then
  _tap_pass "combined_trailing_prose writes a verdict-rejected escalation"
else
  _tap_fail "combined_trailing_prose writes a verdict-rejected escalation" "no escalation file in $_ESC_DIR"
fi

# --- phase mismatch escalation names the EXPECTED phase, not just dispatch/current ---
reset_phase "standard"
_advance "plan" 2>/dev/null; _advance "approval" 2>/dev/null
_advance "build" 2>/dev/null; _advance "review" 2>/dev/null
rm -f "$STATE_DIR/security-signed"
rm -rf "$_ESC_DIR"
# security-privacy must be dispatched from verify; dispatching at review is a caller error.
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "security-privacy" $'No findings.\nGATE_RESULT: APPROVED')"
assert_file_not_exists "$STATE_DIR/security-signed" \
  "security-privacy verdict rejected when dispatched outside verify"
_esc_match=$(grep -l 'expected_phase=verify' "$_ESC_DIR"/verdict-rejected-security-privacy-* 2>/dev/null | head -1)
if [ -n "$_esc_match" ]; then
  _tap_pass "phase-mismatch escalation names the expected phase"
else
  _tap_fail "phase-mismatch escalation names the expected phase" "expected_phase=verify not found in escalation"
fi

# --- happy path unchanged: well-formed verdict still writes, no escalation ---
reset_phase "standard"
_advance "plan" 2>/dev/null; _advance "approval" 2>/dev/null
_advance "build" 2>/dev/null; _advance "review" 2>/dev/null
rm -f "$STATE_DIR/cohesion-reviewed"
rm -rf "$_ESC_DIR"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "critic" $'Review complete.\nGATE_RESULT: APPROVED')"
assert_file_exists "$STATE_DIR/cohesion-reviewed" "well-formed verdict still writes its state file"
if ls "$_ESC_DIR"/verdict-rejected-* >/dev/null 2>&1; then
  _tap_fail "accepted verdict writes no rejection escalation" "unexpected escalation file"
else
  _tap_pass "accepted verdict writes no rejection escalation"
fi
rm -rf "$_ESC_DIR"

# ============================================================
# L3.5 — pre-commit-gates.sh (PreToolUse Bash git commit)
# ============================================================
tap_section "L3.5: pre-commit-gates.sh — commit gate verification"

# --- Phase at commit + all state files → allows ---
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
_advance "review" 2>/dev/null
_advance "verify" 2>/dev/null
_advance "commit" 2>/dev/null
# Create all required state files
printf 'timestamp: test\nsession_id: %s\n' "$TEST_SID" > "$STATE_DIR/plan-approved"
printf 'timestamp: test\nagent: critic\nsession_id: %s\ndispatch_phase: review\nGATE_RESULT: APPROVED\n' "$TEST_SID" > "$STATE_DIR/cohesion-reviewed"
printf 'timestamp: test\nagent: qa-verifier\nsession_id: %s\ndispatch_phase: verify\nGATE_RESULT: APPROVED\n' "$TEST_SID" > "$STATE_DIR/qa-verified"
# Stage a clean file (no secrets)
stage_sandbox_file "src/clean.ts" "export const x = 1;"
run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "test commit")"
assert_ok "$_LAST_RC" "pre-commit-gates allows commit at commit phase with all state files"

# --- Phase before commit → blocks ---
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
printf 'timestamp: test\nsession_id: %s\n' "$TEST_SID" > "$STATE_DIR/plan-approved"
printf 'timestamp: test\nagent: critic\nsession_id: %s\ndispatch_phase: review\nGATE_RESULT: APPROVED\n' "$TEST_SID" > "$STATE_DIR/cohesion-reviewed"
printf 'timestamp: test\nagent: qa-verifier\nsession_id: %s\ndispatch_phase: verify\nGATE_RESULT: APPROVED\n' "$TEST_SID" > "$STATE_DIR/qa-verified"
stage_sandbox_file "src/clean2.ts" "export const y = 2;"
run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "test commit")"
assert_hook_blocks "$_LAST_RC" "pre-commit-gates blocks commit when phase is build (not commit)"

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
assert_hook_blocks "$_LAST_RC" "pre-commit-gates blocks when no phase-state and state files missing"

# --- No phase-state + all state files → blocks (fail-closed, Brief 1) ---
# Brief 1 made phase-state mandatory for non-exempt session types. State files
# alone no longer suffice — init_phase() must have been called.
_cur_sid=$(cat "$SB/.claude/.session-id")
rm -f "$STATE_DIR/phase-state"
printf 'timestamp: test\nsession_id: %s\n' "$_cur_sid" > "$STATE_DIR/plan-approved"
printf 'timestamp: test\nagent: critic\nsession_id: %s\ndispatch_phase: review\nGATE_RESULT: APPROVED\n' "$_cur_sid" > "$STATE_DIR/cohesion-reviewed"
printf 'timestamp: test\nagent: qa-verifier\nsession_id: %s\ndispatch_phase: verify\nGATE_RESULT: APPROVED\n' "$_cur_sid" > "$STATE_DIR/qa-verified"
stage_sandbox_file "src/withstate.ts" "export const v = 5;"
run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "test commit")"
assert_hook_blocks "$_LAST_RC" "pre-commit-gates blocks when no phase-state even with all state files (fail-closed)"

# --- Hotfix branch: skips cohesion-reviewed check ---
reset_phase "hotfix"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
_advance "verify" 2>/dev/null
_advance "commit" 2>/dev/null
switch_sandbox_branch "hotfix/test"
printf 'timestamp: test\nsession_id: %s\n' "$TEST_SID" > "$STATE_DIR/plan-approved"
rm -f "$STATE_DIR/cohesion-reviewed"
printf 'timestamp: test\nagent: qa-verifier\nsession_id: %s\ndispatch_phase: verify\nGATE_RESULT: APPROVED\n' "$TEST_SID" > "$STATE_DIR/qa-verified"
stage_sandbox_file "src/hotfix.ts" "export const h = 6;"
run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "hotfix commit")"
assert_ok "$_LAST_RC" "pre-commit-gates allows hotfix commit without cohesion-reviewed"
switch_sandbox_branch "feature/test"

# --- Phase passed + missing state files → blocks (defense-in-depth) ---
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
_advance "review" 2>/dev/null
_advance "verify" 2>/dev/null
_advance "commit" 2>/dev/null
rm -f "$STATE_DIR/plan-approved" "$STATE_DIR/cohesion-reviewed" "$STATE_DIR/qa-verified"
stage_sandbox_file "src/phasepass.ts" "export const p = 7;"
run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "test commit")"
assert_hook_blocks "$_LAST_RC" "pre-commit-gates blocks when phase passed but state files missing (defense-in-depth)"

# --- REPO_OS_RECOVER=1 → skips state checks ---
rm -f "$STATE_DIR/phase-state" "$STATE_DIR/plan-approved" "$STATE_DIR/cohesion-reviewed" "$STATE_DIR/qa-verified"
stage_sandbox_file "src/recover.ts" "export const r = 8;"
REPO_OS_RECOVER=1 run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "recover commit")"
assert_ok "$_LAST_RC" "pre-commit-gates allows commit with REPO_OS_RECOVER=1"

# --- A3.4: SKIP_FUNC_CHECK=1 bypasses functional verification ---
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
_advance "review" 2>/dev/null
_advance "verify" 2>/dev/null
_advance "commit" 2>/dev/null
printf 'timestamp: test\nsession_id: %s\n' "$TEST_SID" > "$STATE_DIR/plan-approved"
printf 'timestamp: test\nagent: critic\nsession_id: %s\ndispatch_phase: review\nGATE_RESULT: APPROVED\n' "$TEST_SID" > "$STATE_DIR/cohesion-reviewed"
printf 'timestamp: test\nagent: critic\nsession_id: %s\ndispatch_phase: review\nMODE: diff-review\nGATE_RESULT: APPROVED\n' "$TEST_SID" > "$STATE_DIR/diff-review-complete"
printf 'timestamp: test\nagent: qa-verifier\nsession_id: %s\ndispatch_phase: verify\nGATE_RESULT: APPROVED\n' "$TEST_SID" > "$STATE_DIR/qa-verified"
# Create package.json with a test script that exits non-zero
printf '{"name":"test-pkg","scripts":{"test":"node -e '\''process.exit(1)'\''"}}\n' > "$SB/package.json"
(cd "$SB" && git add package.json 2>/dev/null || true)
stage_sandbox_file "src/a34skip.ts" "export const a34s = 1;"
SKIP_FUNC_CHECK=1 run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "a34 skip test")"
assert_ok "$_LAST_RC" "pre-commit-gates: SKIP_FUNC_CHECK=1 bypasses A3.4 even with failing package.json scripts"
(cd "$SB" && git rm --cached package.json 2>/dev/null; rm -f "$SB/package.json") || true

# --- A3.4: CLAUDE_HEADLESS=1 + SKIP_FUNC_CHECK=1 → ignored, gate still blocks ---
# Amendment 1 (Decision t-0044): SKIP_FUNC_CHECK=1 is interactive-only; headless ignores it.
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
_advance "review" 2>/dev/null
_advance "verify" 2>/dev/null
_advance "commit" 2>/dev/null
printf 'timestamp: test\nsession_id: %s\n' "$TEST_SID" > "$STATE_DIR/plan-approved"
printf 'timestamp: test\nagent: critic\nsession_id: %s\ndispatch_phase: review\nGATE_RESULT: APPROVED\n' "$TEST_SID" > "$STATE_DIR/cohesion-reviewed"
printf 'timestamp: test\nagent: critic\nsession_id: %s\ndispatch_phase: review\nMODE: diff-review\nGATE_RESULT: APPROVED\n' "$TEST_SID" > "$STATE_DIR/diff-review-complete"
printf 'timestamp: test\nagent: qa-verifier\nsession_id: %s\ndispatch_phase: verify\nGATE_RESULT: APPROVED\n' "$TEST_SID" > "$STATE_DIR/qa-verified"
# Create package.json with a test script that exits non-zero
printf '{"name":"test-pkg","scripts":{"test":"node -e '\''process.exit(1)'\''"}}' > "$SB/package.json"
(cd "$SB" && git add package.json 2>/dev/null || true)
stage_sandbox_file "src/a34hls.ts" "export const a34h = 3;"
# Remove escalation dir first so we can detect it was created by the hook
rm -rf "$SB/.claude/.automation/escalations"
CLAUDE_HEADLESS=1 SKIP_FUNC_CHECK=1 run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "a34 headless skip ignored")"
assert_hook_blocks "$_LAST_RC" "pre-commit-gates: CLAUDE_HEADLESS=1 + SKIP_FUNC_CHECK=1 — gate NOT bypassed (Amendment 1)"
if ls "$SB/.claude/.automation/escalations/"a34-skip-ignored-* >/dev/null 2>&1; then
  _tap_pass "pre-commit-gates: headless SKIP_FUNC_CHECK=1 ignored — escalation file written"
else
  _tap_fail "pre-commit-gates: headless SKIP_FUNC_CHECK=1 ignored — escalation file MISSING"
fi
(cd "$SB" && git rm --cached package.json 2>/dev/null; rm -f "$SB/package.json") || true
rm -rf "$SB/.claude/.automation/escalations"

# --- A3.4: no package.json in headless → _A34_APPLICABLE=false → binding gate skipped ---
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
_advance "review" 2>/dev/null
_advance "verify" 2>/dev/null
_advance "commit" 2>/dev/null
printf 'timestamp: test\nsession_id: %s\n' "$TEST_SID" > "$STATE_DIR/plan-approved"
printf 'timestamp: test\nagent: critic\nsession_id: %s\ndispatch_phase: review\nGATE_RESULT: APPROVED\n' "$TEST_SID" > "$STATE_DIR/cohesion-reviewed"
printf 'timestamp: test\nagent: critic\nsession_id: %s\ndispatch_phase: review\nMODE: diff-review\nGATE_RESULT: APPROVED\n' "$TEST_SID" > "$STATE_DIR/diff-review-complete"
printf 'timestamp: test\nagent: qa-verifier\nsession_id: %s\ndispatch_phase: verify\nGATE_RESULT: APPROVED\n' "$TEST_SID" > "$STATE_DIR/qa-verified"
rm -f "$SB/package.json"
stage_sandbox_file "src/a34nopkg.ts" "export const a34n = 2;"
CLAUDE_HEADLESS=1 run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "a34 no pkg test")"
assert_ok "$_LAST_RC" "pre-commit-gates: headless + no package.json → A3.4 _A34_APPLICABLE=false, binding gate skipped, commit allowed"

# --- A4: Secret scanning blocks ---
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
_advance "review" 2>/dev/null
_advance "verify" 2>/dev/null
_advance "commit" 2>/dev/null
printf 'timestamp: test\nsession_id: %s\n' "$TEST_SID" > "$STATE_DIR/plan-approved"
printf 'timestamp: test\nagent: critic\nsession_id: %s\ndispatch_phase: review\nGATE_RESULT: APPROVED\n' "$TEST_SID" > "$STATE_DIR/cohesion-reviewed"
printf 'timestamp: test\nagent: qa-verifier\nsession_id: %s\ndispatch_phase: verify\nGATE_RESULT: APPROVED\n' "$TEST_SID" > "$STATE_DIR/qa-verified"
stage_sandbox_file "src/secrets.ts" "const key = 'sk_live_abc123def456';"
run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "test commit")"
assert_hook_blocks "$_LAST_RC" "pre-commit-gates blocks commit with secret pattern in staged file"

# Clean up staged secret file
(cd "$SB" && git reset HEAD src/secrets.ts 2>/dev/null && rm -f src/secrets.ts) || true

# ============================================================
# L3.6 — write-guard.sh: state protection (PreToolUse Edit/Write/Bash)
# ============================================================
tap_section "L3.6: write-guard.sh — .state/ write protection"

# --- Edit targeting .claude/.state/ → blocks ---
run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/.claude/.state/plan-approved")"
assert_hook_blocks "$_LAST_RC" "state-guard blocks Edit to .claude/.state/"

# --- Write targeting .claude/.state/ → blocks ---
run_hook_rc "write-guard.sh" "$(fixture_pretooluse_write "$SB/.claude/.state/qa-verified")"
assert_hook_blocks "$_LAST_RC" "state-guard blocks Write to .claude/.state/"

# --- Bash redirect to .claude/.state/ → blocks ---
run_hook_rc "write-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/.claude/.state/plan-approved")"
assert_hook_blocks "$_LAST_RC" "state-guard blocks Bash redirect to .claude/.state/"

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
assert_hook_blocks "$_LAST_RC" "mode-guard blocks product path in template mode"

# --- Template mode: carved-out governance path → allows ---
run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/.claude/hooks/test-hook.sh")"
assert_ok "$_LAST_RC" "mode-guard allows .claude/hooks/ in template mode"

run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/docs/ai/decisions/t-0001-test.md")"
assert_ok "$_LAST_RC" "mode-guard allows docs/ai/decisions/t-*.md in template mode"

run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/AI.md")"
assert_ok "$_LAST_RC" "mode-guard allows AI.md in template mode"

# --- Template mode: immune path → blocks (no override possible) ---
run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/.claude/repo-mode")"
assert_hook_blocks "$_LAST_RC" "mode-guard blocks .claude/repo-mode (immune path)"

run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/.claude/hooks/write-guard.sh")"
assert_hook_blocks "$_LAST_RC" "mode-guard blocks .claude/hooks/write-guard.sh (immune path)"

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
assert_hook_blocks "$_LAST_RC" "mode-guard blocks immune path even in child mode"

# --- Child mode: template decision (t-*.md) → blocks (Decision 0022) ---
REPO_OS_MODE=child run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/docs/ai/decisions/t-0001-test.md")"
assert_hook_blocks "$_LAST_RC" "mode-guard blocks template decision (t-*.md) in child mode"

# --- Child mode: child decision (0100+) → allows ---
REPO_OS_MODE=child run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/docs/ai/decisions/0100-test.md")"
assert_ok "$_LAST_RC" "mode-guard allows child decision (0100+) in child mode"

# --- Autonomous mode: template decision (t-*.md) → blocks (Decision 0022) ---
REPO_OS_MODE=autonomous run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/docs/ai/decisions/t-0001-test.md")"
assert_hook_blocks "$_LAST_RC" "mode-guard blocks template decision (t-*.md) in autonomous mode"

# ============================================================
# L3.8 — State chain integration (full lifecycle)
# ============================================================
tap_section "L3.8: State chain integration — full standard session lifecycle"

# Full standard session lifecycle:
# init → plan → (plan-approval fires) → build → review →
# (state-writer critic APPROVED) → verify → (state-writer qa APPROVED) →
# commit → (pre-commit-gates passes)

reset_phase "standard"
_advance "plan" 2>/dev/null

# Plan approval fires (PostToolUse AskUserQuestion)
rm -f "$STATE_DIR/plan-approved"
run_hook_rc "plan-approval.sh" \
  "$(fixture_posttooluse_ask "Do you approve this plan?" "Yes approve,No revise" "Yes approve")"
phase_after=$(get_phase)
assert_eq "$phase_after" "build" "lifecycle: plan-approval advances to build"
assert_file_exists "$STATE_DIR/plan-approved" "lifecycle: plan-approved state file written"

# Agent does build work, then advances to review
_advance "review" 2>/dev/null

# Critic fires (SubagentStop) — combined mode writes cohesion-reviewed AND
# diff-review-complete (Decision 0039), both required by the A5 commit gate.
rm -f "$STATE_DIR/cohesion-reviewed" "$STATE_DIR/diff-review-complete"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "critic" $'## Cohesion Brief\n\nNo issues found.\n\nGATE_RESULT: APPROVED\n\n## Diff-Review Brief\n\nNo bugs found.\n\nMODE: diff-review\nGATE_RESULT: APPROVED')"
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
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
_advance "review" 2>/dev/null

# Critic returns BLOCKED — phase stays at review
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "critic" $'3 findings.\nGATE_RESULT: BLOCKED - critical issues')"
phase_after=$(get_phase)
assert_eq "$phase_after" "review" "loop: critic BLOCKED keeps phase at review"

# Orchestrator loops: review→build (defined loop in standard)
_advance "build" 2>/dev/null
phase_after=$(get_phase)
assert_eq "$phase_after" "build" "loop: review→build loop succeeds"

# Agent fixes issues, advances back to review
_advance "review" 2>/dev/null

# Critic runs again — this time APPROVED
rm -f "$STATE_DIR/cohesion-reviewed"
run_hook_rc "state-writer.sh" \
  "$(fixture_subagentstop "critic" $'All clear.\nGATE_RESULT: APPROVED')"
phase_after=$(get_phase)
assert_eq "$phase_after" "verify" "loop: second critic APPROVED advances to verify"

# ============================================================
# L3.8c — Editor-live session type: loop mechanics + gate profile
# ============================================================
tap_section "L3.8c: Editor-live — loop mechanics, gate profile, write-guard exemption"

# --- Loop mechanics: init → build → commit → (loop commit→build) → review → verify ---
reset_phase "editor-live"
_advance "build" 2>/dev/null
phase_after=$(get_phase)
assert_eq "$phase_after" "build" "editor-live: init→build succeeds"

_advance "commit" 2>/dev/null
phase_after=$(get_phase)
assert_eq "$phase_after" "commit" "editor-live: build→commit succeeds"

# commit→build loop (defined in get_loops_for_type)
_advance "build" 2>/dev/null
phase_after=$(get_phase)
assert_eq "$phase_after" "build" "editor-live: commit→build loop succeeds"

# Verify cycle incremented (should be 2 after one loop)
_load_phase_state "$STATE_DIR/phase-state"
assert_eq "$_PS_CYCLE" "2" "editor-live: cycle increments on commit→build loop"

# Second iteration: build → commit → build (cycle 3)
_advance "commit" 2>/dev/null
_advance "build" 2>/dev/null
_load_phase_state "$STATE_DIR/phase-state"
assert_eq "$_PS_CYCLE" "3" "editor-live: cycle increments to 3 on second loop"

# Exit loop: build → commit → review → verify
_advance "commit" 2>/dev/null
_advance "review" 2>/dev/null
_advance "verify" 2>/dev/null
phase_after=$(get_phase)
assert_eq "$phase_after" "verify" "editor-live: commit→review→verify succeeds (exit loop)"

# verify→build loop
_advance "build" 2>/dev/null
phase_after=$(get_phase)
assert_eq "$phase_after" "build" "editor-live: verify→build loop succeeds"
_load_phase_state "$STATE_DIR/phase-state"
assert_eq "$_PS_CYCLE" "4" "editor-live: cycle increments on verify→build loop"

# --- Per-loop commit (A4 only): no plan-approved/cohesion-reviewed/qa-verified needed ---
reset_phase "editor-live"
_advance "build" 2>/dev/null
_advance "commit" 2>/dev/null
# No state files — per-loop commit should pass (A4 only)
rm -f "$STATE_DIR/plan-approved" "$STATE_DIR/cohesion-reviewed" "$STATE_DIR/qa-verified"
stage_sandbox_file "src/el-loop.ts" "export const loop = 1;"
run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "editor-live per-loop commit")"
assert_ok "$_LAST_RC" "editor-live per-loop commit allows without state files (A4 only)"

# --- Per-loop commit: A4 still blocks secrets ---
reset_phase "editor-live"
_advance "build" 2>/dev/null
_advance "commit" 2>/dev/null
stage_sandbox_file "src/el-secret.ts" "const key = 'sk_live_abc123def456';"
run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "editor-live secret commit")"
assert_hook_blocks "$_LAST_RC" "editor-live per-loop commit blocks on A4 secret detection"
# Clean up staged secret file
(cd "$SB" && git reset HEAD src/el-secret.ts 2>/dev/null && rm -f src/el-secret.ts) || true

# --- Close commit (post-review): requires cohesion-reviewed + qa-verified, no plan-approved ---
reset_phase "editor-live"
_advance "build" 2>/dev/null
_advance "commit" 2>/dev/null
_advance "review" 2>/dev/null
_advance "verify" 2>/dev/null
_advance "op-review" 2>/dev/null
_advance "close" 2>/dev/null
# At close phase (review IS in phases_completed)
# pre-commit-gates checks phases_completed for review
# Provide cohesion-reviewed + qa-verified but NO plan-approved
rm -f "$STATE_DIR/plan-approved"
printf 'timestamp: test\nagent: critic\nsession_id: %s\ndispatch_phase: review\nGATE_RESULT: APPROVED\n' "$TEST_SID" > "$STATE_DIR/cohesion-reviewed"
printf 'timestamp: test\nagent: qa-verifier\nsession_id: %s\ndispatch_phase: verify\nGATE_RESULT: APPROVED\n' "$TEST_SID" > "$STATE_DIR/qa-verified"
stage_sandbox_file "src/el-close.ts" "export const close = 1;"
run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "editor-live close commit")"
assert_ok "$_LAST_RC" "editor-live close commit allows without plan-approved (with cohesion + qa)"

# --- Close commit: blocks without cohesion-reviewed ---
reset_phase "editor-live"
_advance "build" 2>/dev/null
_advance "commit" 2>/dev/null
_advance "review" 2>/dev/null
_advance "verify" 2>/dev/null
_advance "op-review" 2>/dev/null
_advance "close" 2>/dev/null
rm -f "$STATE_DIR/plan-approved" "$STATE_DIR/cohesion-reviewed"
printf 'timestamp: test\nagent: qa-verifier\nsession_id: %s\ndispatch_phase: verify\nGATE_RESULT: APPROVED\n' "$TEST_SID" > "$STATE_DIR/qa-verified"
stage_sandbox_file "src/el-close2.ts" "export const close2 = 2;"
run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "editor-live close commit")"
assert_hook_blocks "$_LAST_RC" "editor-live close commit blocks without cohesion-reviewed"

# --- Close commit: blocks without qa-verified ---
reset_phase "editor-live"
_advance "build" 2>/dev/null
_advance "commit" 2>/dev/null
_advance "review" 2>/dev/null
_advance "verify" 2>/dev/null
_advance "op-review" 2>/dev/null
_advance "close" 2>/dev/null
rm -f "$STATE_DIR/plan-approved" "$STATE_DIR/qa-verified"
printf 'timestamp: test\nagent: critic\nsession_id: %s\ndispatch_phase: review\nGATE_RESULT: APPROVED\n' "$TEST_SID" > "$STATE_DIR/cohesion-reviewed"
stage_sandbox_file "src/el-close3.ts" "export const close3 = 3;"
run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "editor-live close commit")"
assert_hook_blocks "$_LAST_RC" "editor-live close commit blocks without qa-verified"

# --- Close commit at commit phase (realistic: after verify:build loop) ---
# After verify:build loop, current_phase=commit but review IS in phases_completed.
# This is the realistic close-gate scenario (vs close phase used in tests above).
reset_phase "editor-live"
_advance "build" 2>/dev/null
_advance "commit" 2>/dev/null
_advance "review" 2>/dev/null
_advance "verify" 2>/dev/null
# verify:build loop — goes back to build, then forward to commit
_advance "build" 2>/dev/null   # loop
_advance "commit" 2>/dev/null  # now at commit with review in phases_completed
rm -f "$STATE_DIR/plan-approved"
printf 'timestamp: test\nagent: critic\nsession_id: %s\ndispatch_phase: review\nGATE_RESULT: APPROVED\n' "$TEST_SID" > "$STATE_DIR/cohesion-reviewed"
printf 'timestamp: test\nagent: qa-verifier\nsession_id: %s\ndispatch_phase: verify\nGATE_RESULT: APPROVED\n' "$TEST_SID" > "$STATE_DIR/qa-verified"
stage_sandbox_file "src/el-close-realistic.ts" "export const closeR = 1;"
run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "editor-live close commit at commit phase")"
assert_ok "$_LAST_RC" "editor-live close commit at commit phase (after verify:build loop)"

# --- Write-guard exemption: edit allowed in init phase ---
reset_phase "editor-live"
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "write-guard allows edit in init phase for editor-live"

# --- bash-guard: editor-live has no plan gate → allows bash redirect in init ---
reset_phase "editor-live"
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_ok "$_LAST_RC" "bash-guard allows bash redirect for editor-live (no plan gate)"

# --- has_plan_gate verification ---
if has_plan_gate "editor-live"; then
  _tap_fail "editor-live has no plan gate" "has_plan_gate returned true"
else
  _tap_pass "editor-live has no plan gate"
fi

# ============================================================
# L3.9 — Error / edge case tests
# ============================================================
tap_section "L3.9: Error and edge case tests"

# --- Corrupt phase-state (empty file) → hooks fail-open ---
echo "" > "$STATE_DIR/phase-state"
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "write-guard fails open on corrupt (empty) phase-state"

# --- Wrong session ID → hooks fail-open ---
reset_phase "standard"
set_test_session_id "different-session-id"
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "write-guard fails open on session-ID mismatch"

# Also test bash-guard
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_ok "$_LAST_RC" "bash-guard fails open on session-ID mismatch"

# Restore session ID
set_test_session_id "test-session-$(date +%s)"

# --- Missing phase-state file entirely → hooks fail-open ---
rm -f "$STATE_DIR/phase-state"
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "write-guard fails open when phase-state missing"

REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_ok "$_LAST_RC" "bash-guard fails open when phase-state missing"

# Pre-commit-gates without phase-state → blocks (fail-closed, Brief 1)
_cur_sid=$(cat "$SB/.claude/.session-id")
rm -f "$STATE_DIR/phase-state"
printf 'timestamp: test\nsession_id: %s\n' "$_cur_sid" > "$STATE_DIR/plan-approved"
printf 'timestamp: test\nagent: critic\nsession_id: %s\ndispatch_phase: review\nGATE_RESULT: APPROVED\n' "$_cur_sid" > "$STATE_DIR/cohesion-reviewed"
printf 'timestamp: test\nagent: qa-verifier\nsession_id: %s\ndispatch_phase: verify\nGATE_RESULT: APPROVED\n' "$_cur_sid" > "$STATE_DIR/qa-verified"
stage_sandbox_file "src/nophase.ts" "export const np = 1;"
run_hook_rc "pre-commit-gates.sh" "$(fixture_pretooluse_commit "test commit")"
assert_hook_blocks "$_LAST_RC" "pre-commit-gates blocks when no phase-state even with state files (fail-closed)"

# ============================================================
# L3.10 — session-close-check.sh (Stop)
# ============================================================
tap_section "L3.10: session-close-check.sh — session close verification"

# --- Local helpers for L3.10+ ---
# Get the per-session log path for the current test session.
_session_log_path() {
  local sid
  sid=$(cat "$SB/.claude/.session-id")
  echo "$SB/.claude/local/sessions/session-${sid}.md"
}

# Write a per-session log with sufficient content (>100 bytes).
_write_session_log() {
  local log_path
  log_path=$(_session_log_path)
  mkdir -p "$(dirname "$log_path")"
  printf '# Session Log\n\nSession: %s\nDate: 2026-04-04\n\n[Test session log — verifying close sequence enforcement.]\n' \
    "$(cat "$SB/.claude/.session-id")" > "$log_path"
}

# Temp file for capturing hook output without losing _LAST_RC.
# NOTE: output=$(run_hook_rc ...) runs in a subshell — _LAST_RC is lost.
# Use: run_hook_rc ... > "$_L3_OUT" 2>&1  then read "$_L3_OUT".
_L3_OUT="$SB/.claude/.test-hook-output"

# Reinitialize sandbox state after cleanup_session() destroys session files.
_reinit_close_sandbox() {
  echo "test-session-$(date +%s)-$$" > "$SB/.claude/.session-id"
  # Clear caches (analytics-helper caches session ID, branch, and state dir)
  _CACHED_SESSION_ID=""
  _CACHED_BRANCH=""
  _CACHED_SESSION_STATE_DIR=""
  rm -f "$SB/.claude/.state/.stop-attempt-count"
  rm -f "$SB/.claude/.hvst-fail-count"
  rm -f "$SB/.claude/.deferrals-pending"
  # Clean per-session state dirs from prior test iterations
  rm -rf "$SB/.claude/.state/wt-sessions" 2>/dev/null || true
  # Clean per-session log files from prior test iterations
  rm -rf "$SB/.claude/local/sessions" 2>/dev/null || true
  # Ensure clean git working tree (earlier tests may leave staged/modified files).
  # git reset --hard clears both index and working tree; git clean removes untracked.
  (cd "$SB" && git reset --hard HEAD 2>/dev/null || true)
  (cd "$SB" && git clean -fd -e .claude/ 2>/dev/null || true)
  reset_phase "standard"
}

# Force the current session into a closing phase so session-close-check runs the
# FULL close sequence. The interactive pause-Stop guard (Decision 0023 Amdt 1)
# otherwise treats an init-phase Stop as a pause and exits before the
# zero-change / session-log output these tests assert on. (Direct phase-state
# edit avoids walking the gated sequence just to reach a closing phase.)
_mark_closing() {
  local _cs
  _cs="$(get_session_state_dir)/phase-state"
  [ -f "$_cs" ] || return 0
  sed 's/^current_phase: .*/current_phase: close/' "$_cs" > "$_cs.tmp" && mv "$_cs.tmp" "$_cs"
}

# Create per-session log directory (template mode uses .claude/local/sessions/).
mkdir -p "$SB/.claude/local/sessions"

# Ensure we're on a feature branch (not main).
switch_sandbox_branch "feature/test"

# --- Test 1: Zero-change session → allow ---
_reinit_close_sandbox
_mark_closing
# Store current HEAD as baseline (no new commits = zero-change)
git -C "$SB" rev-parse HEAD > "$SB/.claude/.session-baseline-sha"
# Set hash to current value (not modified)
# (no per-session log file written — simulates unmodified state)
run_hook_rc "session-close-check.sh" "$(fixture_stop)" > "$_L3_OUT"
assert_ok "$_LAST_RC" "session-close-check allows zero-change session"
assert_contains "$(cat "$_L3_OUT")" "zero-change" "session-close-check emits zero-change advisory"

# --- Test 2: Commits + session log modified → allow ---
_reinit_close_sandbox
_mark_closing
# Set a stale hash so current content differs (= modified)
_write_session_log  # creates per-session file with >100 bytes
# Invalid baseline SHA → treated as non-zero session (baseline-missing)
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
run_hook_rc "session-close-check.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "session-close-check allows when session log modified and commits exist"

# --- Test 3: Commits + session log NOT modified → block ---
_reinit_close_sandbox
_mark_closing
# Hash matches current (not modified)
# (no per-session log file written — simulates unmodified state)
# Invalid baseline = non-zero session
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
run_hook_rc "session-close-check.sh" "$(fixture_stop)" > "$_L3_OUT"
# Phase 2a: block path exits 0 with JSON {decision:"block"} on stdout (jq present)
# or exits 2 with stderr (jq absent). Test the JSON path.
assert_ok "$_LAST_RC" "session-close-check blocks when session log not modified (non-zero session)"
assert_contains "$(cat "$_L3_OUT")" "block" "session-close-check emits block decision"
assert_contains "$(cat "$_L3_OUT")" "Session log not updated" "session-close-check reports session log issue"

# --- Test 4: SKIP_SESSION_LOG=1 override → allow ---
_reinit_close_sandbox
# (no per-session log file written — simulates unmodified state)
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
SKIP_SESSION_LOG=1 run_hook_rc "session-close-check.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "session-close-check allows with SKIP_SESSION_LOG=1"

# --- Test 5: 3-attempt safety valve → unconditional allow ---
_reinit_close_sandbox
# Set attempt counter to 2 (hook increments to 3, triggers valve)
mkdir -p "$SB/.claude/.state"
echo "2" > "$SB/.claude/.state/.stop-attempt-count"
# Would normally block (log not modified + commits)
# (no per-session log file written — simulates unmodified state)
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
run_hook_rc "session-close-check.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "session-close-check forces exit after 3 stop attempts (safety valve)"

# --- Test 6: Task group non-final brief → branch NOT sealed ---
_reinit_close_sandbox
_write_session_log  # creates per-session file with >100 bytes
# Invalid baseline → non-zero session (avoids zero-change short-circuit)
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
# Set up as taskgroup session
reset_phase "taskgroup"
_advance "contract-init" 2>/dev/null
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
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
_write_session_log  # creates per-session file with >100 bytes
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
reset_phase "taskgroup"
_advance "contract-init" 2>/dev/null
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
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
_mark_closing
run_hook_rc "session-close-check.sh" "$(fixture_session_end)"
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

# The no-init fast-exit SEAL path is a headless/automation behavior. An
# interactive no-init Stop (no REPO_OS_SESSION_ID) is correctly treated as a
# pause (Decision 0023 Amdt 1) and exits before the seal ever runs, so these
# two tests run headless: REPO_OS_SESSION_ID set to the on-disk .session-id
# (env- and file-resolution then key the SAME per-session state dir) plus an
# invalid baseline SHA (non-zero session) so the early zero-change fast-exit is
# not taken and control reaches the no-init seal block.

# --- Test 1: No-init SessionEnd does NOT seal branch (Decision 0047) ---
# Pre-t-0047 the Stop path sealed on no-init close. Decision t-0047 §7 intentionally
# removes this: sealing retires a branch nobody finished with, stranding whatever
# is on it. The no-init guard in the SessionEnd dispatch checks for phase-state
# and skips seal when absent.
_reinit_close_sandbox
export REPO_OS_SESSION_ID="$(cat "$SB/.claude/.session-id")"
rm -f "$(get_session_state_dir)/phase-state"
rm -f "$SB/.claude/local/closed-branches"
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
run_hook_rc "session-close-check.sh" "$(fixture_session_end)"
unset REPO_OS_SESSION_ID
assert_ok "$_LAST_RC" "no-init SessionEnd exits 0"
if [ -f "$SB/.claude/local/closed-branches" ] && grep -qxF "feature/test" "$SB/.claude/local/closed-branches" 2>/dev/null; then
  _tap_fail "no-init SessionEnd does not seal branch (Decision 0047)" "branch found in closed-branches"
else
  _tap_pass "no-init SessionEnd does not seal branch (Decision 0047)"
fi

# --- Test 2: No-init SessionEnd detects verified agent merge signal ---
# SessionEnd verifies the merge signal via git merge-base --is-ancestor before
# recording it. The branch must actually be merged into main in the sandbox repo.
_reinit_close_sandbox
export REPO_OS_SESSION_ID="$(cat "$SB/.claude/.session-id")"
rm -f "$(get_session_state_dir)/phase-state"
rm -f "$SB/.claude/local/closed-branches"
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
# Create and merge feature/merged-source into main so is-ancestor check passes
(cd "$SB" && git checkout -q -b feature/merged-source 2>/dev/null || true)
(cd "$SB" && git checkout -q main && git merge --ff-only feature/merged-source 2>/dev/null || \
  git merge --no-ff -m "Merge feature/merged-source" feature/merged-source 2>/dev/null || true)
(cd "$SB" && git checkout -q feature/test 2>/dev/null || true)
mkdir -p "$(get_session_state_dir)"
echo "feature/merged-source" > "$(get_session_state_dir)/merge-source-branch"
run_hook_rc "session-close-check.sh" "$(fixture_session_end)"
unset REPO_OS_SESSION_ID
assert_ok "$_LAST_RC" "no-init SessionEnd allows close with verified agent merge"
assert_file_contains "$SB/.claude/local/closed-branches" "feature/merged-source" \
  "no-init SessionEnd records verified agent-merged branch"

# --- Test 3: No-init SessionEnd does not seal active taskgroup branch ---
# Uses fixture_session_end so the SessionEnd path runs. No phase-state is present,
# so the no-init guard in session-close-check.sh's SessionEnd dispatch skips
# seal_branch_if_applicable entirely — sealing would retire a branch nobody
# finished with. The active taskgroup contract provides belt-and-suspenders
# evidence that this is not a completed governed session, but the primary guard
# being exercised here is the no-init guard (Decision 0047).
_reinit_close_sandbox
export REPO_OS_SESSION_ID="$(cat "$SB/.claude/.session-id")"
rm -f "$(get_session_state_dir)/phase-state"
rm -f "$SB/.claude/local/closed-branches"
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
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
run_hook_rc "session-close-check.sh" "$(fixture_session_end)"
unset REPO_OS_SESSION_ID
assert_ok "$_LAST_RC" "no-init SessionEnd allows close for active taskgroup branch"
if [ -f "$SB/.claude/local/closed-branches" ] && grep -qxF "feature/test" "$SB/.claude/local/closed-branches" 2>/dev/null; then
  _tap_fail "no-init SessionEnd does not seal active taskgroup branch (Decision 0047)" "branch found in closed-branches"
else
  _tap_pass "no-init SessionEnd does not seal active taskgroup branch (Decision 0047)"
fi
rm -rf "$SB/.claude/local/task-groups"

# --- Test 4: Zero-change session seals branch ---
_reinit_close_sandbox
git -C "$SB" rev-parse HEAD > "$SB/.claude/.session-baseline-sha"
# (no per-session log file written — simulates unmodified state)
rm -f "$SB/.claude/local/closed-branches"
_mark_closing
run_hook_rc "session-close-check.sh" "$(fixture_session_end)" > "$_L3_OUT"
assert_ok "$_LAST_RC" "zero-change session allows close with seal"
assert_file_contains "$SB/.claude/local/closed-branches" "feature/test" \
  "zero-change session seals branch"

# --- Test 5: Zero-change SessionEnd detects verified agent merge signal ---
# SessionEnd verifies the merge signal via git merge-base --is-ancestor before
# recording it. The branch must actually be merged into main in the sandbox repo.
_reinit_close_sandbox
git -C "$SB" rev-parse HEAD > "$SB/.claude/.session-baseline-sha"
# (no per-session log file written — simulates unmodified state)
rm -f "$SB/.claude/local/closed-branches"
# Create and merge feature/zero-merged into main so is-ancestor check passes
(cd "$SB" && git checkout -q -b feature/zero-merged 2>/dev/null || true)
(cd "$SB" && git checkout -q main && git merge --ff-only feature/zero-merged 2>/dev/null || \
  git merge --no-ff -m "Merge feature/zero-merged" feature/zero-merged 2>/dev/null || true)
(cd "$SB" && git checkout -q feature/test 2>/dev/null || true)
echo "feature/zero-merged" > "$(get_session_state_dir)/merge-source-branch"
_mark_closing
run_hook_rc "session-close-check.sh" "$(fixture_session_end)" > "$_L3_OUT"
assert_ok "$_LAST_RC" "zero-change SessionEnd allows close with verified agent merge"
assert_file_contains "$SB/.claude/local/closed-branches" "feature/zero-merged" \
  "zero-change SessionEnd records verified agent-merged branch"

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

# --- Valid branch: live-editor-N → allow ---
switch_sandbox_branch "live-editor-7"
run_hook_rc "pre-push-gates.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "pre-push-gates allows live-editor-N branch"

# --- Invalid live-editor branch (non-digit suffix) → block ---
switch_sandbox_branch "live-editor-foo"
run_hook_rc "pre-push-gates.sh" "$(fixture_pretooluse_bash "git push origin live-editor-foo")" > "$_L3_OUT"
assert_hook_blocks "$_LAST_RC" "pre-push-gates blocks live-editor branch with non-digit suffix"
assert_contains "$(cat "$_L3_OUT")" "live-editor-N" "pre-push-gates B1 error names live-editor-N as valid form"

# --- main → allow (skips naming check) ---
switch_sandbox_branch "main"
run_hook_rc "pre-push-gates.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "pre-push-gates allows main branch (skips naming check)"

# --- Invalid branch name → block ---
switch_sandbox_branch "invalid_no_category"
run_hook_rc "pre-push-gates.sh" "$(fixture_pretooluse_bash "git push origin invalid_no_category")" > "$_L3_OUT"
assert_hook_blocks "$_LAST_RC" "pre-push-gates blocks invalid branch name"
assert_contains "$(cat "$_L3_OUT")" "GATE B1 FAILED" "pre-push-gates reports B1 failure for invalid name"

# --- Bare category without slash-description → block ---
# Use 'release' (not 'feature') because git can't create 'feature' when
# 'feature/test' exists (ref directory conflict).
switch_sandbox_branch "release"
run_hook_rc "pre-push-gates.sh" "$(fixture_pretooluse_bash "git push origin release")"
assert_hook_blocks "$_LAST_RC" "pre-push-gates blocks bare category without description"

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

# --- L3.14.2: write-guard blocks on session overlap ---
_reinit_close_sandbox
rm -rf "$SESSIONS_DIR"
_CACHED_BRANCH=""
reset_phase "standard"
# Advance to build so Gate 2 (phase gate) doesn't block
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
# Current session is registered by init_phase; create overlapping session
SID_L314="$(cat "$SB/.claude/.session-id")"
create_fake_session "overlap-l314" "standard" "feature/test" "$$"
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")" > "$_L3_OUT" 2>&1
assert_hook_blocks "$_LAST_RC" "write-guard blocks on session overlap"
assert_contains "$(cat "$_L3_OUT")" "BLOCKED" "write-guard overlap emits BLOCKED"
rm -f "$SESSIONS_DIR/overlap-l314.yaml"

# --- L3.14.3: write-guard allows task group overlap (advisory) ---
_reinit_close_sandbox
rm -rf "$SESSIONS_DIR"
_CACHED_BRANCH=""
reset_phase "taskgroup"
_advance "contract-init" 2>/dev/null
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
SID_L314="$(cat "$SB/.claude/.session-id")"
create_fake_session "overlap-tg-l314" "taskgroup" "feature/test" "$$"
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")" > "$_L3_OUT" 2>&1
assert_ok "$_LAST_RC" "write-guard allows task group overlap"
assert_contains "$(cat "$_L3_OUT")" "Advisory" "task group overlap emits Advisory"
rm -f "$SESSIONS_DIR/overlap-tg-l314.yaml"

# --- L3.14.4: taskgroup-merge + taskgroup overlap is advisory ---
_reinit_close_sandbox
rm -rf "$SESSIONS_DIR"
_CACHED_BRANCH=""
reset_phase "taskgroup-merge"
_advance "contract-init" 2>/dev/null
_advance "cohesion" 2>/dev/null
SID_L314="$(cat "$SB/.claude/.session-id")"
create_fake_session "overlap-tgm-l314" "taskgroup" "feature/test" "$$"
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")" > "$_L3_OUT" 2>&1
assert_ok "$_LAST_RC" "write-guard allows taskgroup-merge + taskgroup overlap"
assert_contains "$(cat "$_L3_OUT")" "Advisory" "taskgroup-merge + taskgroup overlap emits Advisory"
rm -f "$SESSIONS_DIR/overlap-tgm-l314.yaml"

# --- L3.14.5: taskgroup-merge + taskgroup-merge overlap is advisory ---
_reinit_close_sandbox
rm -rf "$SESSIONS_DIR"
_CACHED_BRANCH=""
reset_phase "taskgroup-merge"
_advance "contract-init" 2>/dev/null
_advance "cohesion" 2>/dev/null
SID_L314="$(cat "$SB/.claude/.session-id")"
create_fake_session "overlap-tgm2-l314" "taskgroup-merge" "feature/test" "$$"
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")" > "$_L3_OUT" 2>&1
assert_ok "$_LAST_RC" "write-guard allows taskgroup-merge + taskgroup-merge overlap"
assert_contains "$(cat "$_L3_OUT")" "Advisory" "taskgroup-merge + taskgroup-merge overlap emits Advisory"
rm -f "$SESSIONS_DIR/overlap-tgm2-l314.yaml"

# --- L3.14.6 (was .4): bash-guard blocks on session overlap (bash redirect) ---
_reinit_close_sandbox
rm -rf "$SESSIONS_DIR"
_CACHED_BRANCH=""
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
SID_L314="$(cat "$SB/.claude/.session-id")"
create_fake_session "overlap-bg-l314" "standard" "feature/test" "$$"
run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/foo.ts")" > "$_L3_OUT" 2>&1
assert_hook_blocks "$_LAST_RC" "bash-guard blocks on session overlap (bash redirect)"
rm -f "$SESSIONS_DIR/overlap-bg-l314.yaml"

# --- L3.14.7 (was .5): REPO_OS_SKIP_OVERLAP_CHECK=1 bypasses in write-guard ---
_reinit_close_sandbox
rm -rf "$SESSIONS_DIR"
_CACHED_BRANCH=""
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
SID_L314="$(cat "$SB/.claude/.session-id")"
create_fake_session "overlap-skip-l314" "standard" "feature/test" "$$"
REPO_OS_SKIP_MODE_GUARD=1 REPO_OS_SKIP_OVERLAP_CHECK=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "REPO_OS_SKIP_OVERLAP_CHECK=1 bypasses overlap in write-guard"
rm -f "$SESSIONS_DIR/overlap-skip-l314.yaml"

# --- L3.14.8 (was .6): REPO_OS_RECOVER=1 bypasses overlap check ---
_reinit_close_sandbox
rm -rf "$SESSIONS_DIR"
_CACHED_BRANCH=""
reset_phase "standard"
SID_L314="$(cat "$SB/.claude/.session-id")"
create_fake_session "overlap-recover-l314" "standard" "feature/test" "$$"
REPO_OS_SKIP_MODE_GUARD=1 REPO_OS_RECOVER=1 run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/src/foo.ts")"
assert_ok "$_LAST_RC" "REPO_OS_RECOVER=1 bypasses overlap check in write-guard"
rm -f "$SESSIONS_DIR/overlap-recover-l314.yaml"

# --- L3.14.9 (was .7): session-close-check unregisters session ---
_reinit_close_sandbox
rm -rf "$SESSIONS_DIR"
_CACHED_BRANCH=""
# Set up a zero-change session so session-close-check allows close
reset_phase "standard"
SID_L314="$(cat "$SB/.claude/.session-id")"
git -C "$SB" rev-parse HEAD > "$SB/.claude/.session-baseline-sha"
# (no per-session log file written — simulates unmodified state)
# Verify session file exists (registered by init_phase → register_session)
if [ -f "$SESSIONS_DIR/${SID_L314}.yaml" ]; then
  _tap_pass "session file exists before close"
else
  _tap_fail "session file exists before close" "not found: $SESSIONS_DIR/${SID_L314}.yaml"
fi
_mark_closing
run_hook_rc "session-close-check.sh" "$(fixture_session_end)" > /dev/null 2>&1
assert_file_not_exists "$SESSIONS_DIR/${SID_L314}.yaml" "session-close-check unregisters session"

# ============================================================
# L3.2b — bash-guard.sh (Phase 3a — consolidated Bash PreToolUse)
# ============================================================
tap_section "L3.2b: bash-guard.sh — consolidated Bash PreToolUse"

# Clean up any closed-branches from prior tests (L3.10b seals branches)
rm -f "$SB/.claude/local/closed-branches"

# --- Fast-exit for non-write Bash commands ---
reset_phase "standard"
run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "git status")"
assert_ok "$_LAST_RC" "bash-guard allows bash without write target (git status)"

run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "npm test")"
assert_ok "$_LAST_RC" "bash-guard allows bash without write target (npm test)"

# NOTE: REPO_OS_SKIP_MODE_GUARD=1 is used below to isolate bash-guard behavior
# from mode-guard. Mode-guard tests are covered in L3.7 (write-guard.sh).

# --- Gate 2: Bash with in-repo write target in init phase → blocks ---
reset_phase "standard"
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_hook_blocks "$_LAST_RC" "bash-guard blocks bash redirect in init phase"

# --- Gate 2: Bash with write target in build phase → allows ---
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_ok "$_LAST_RC" "bash-guard allows bash redirect in build phase"

# --- experiment/* branch exemption ---
reset_phase "standard"
switch_sandbox_branch "experiment/test"
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_ok "$_LAST_RC" "bash-guard allows bash redirect on experiment/* branch"
switch_sandbox_branch "feature/test"

# --- Session type without plan gate → allows ---
reset_phase "advisory-init"
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_ok "$_LAST_RC" "bash-guard allows bash redirect for advisory-init (no plan gate)"

# --- Gate 1: Main branch protection ---
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
switch_sandbox_branch "main"
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_hook_blocks "$_LAST_RC" "bash-guard blocks bash redirect on main branch"
switch_sandbox_branch "feature/test"

# --- REPO_OS_RECOVER=1 override ---
reset_phase "standard"
REPO_OS_RECOVER=1 run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_ok "$_LAST_RC" "bash-guard allows bash redirect with REPO_OS_RECOVER=1"

# --- Out-of-repo write target → allows ---
reset_phase "standard"
run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "echo test > /tmp/outside.txt")"
assert_ok "$_LAST_RC" "bash-guard allows bash redirect to out-of-repo path"

# --- State-guard: blocks .state/ writes ---
run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/.claude/.state/plan-approved")"
assert_hook_blocks "$_LAST_RC" "bash-guard blocks bash redirect to .claude/.state/"

# --- Ephemeral session fast-exit (Phase 3b) ---
reset_phase "ephemeral"
_advance "conversation" 2>/dev/null
run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_ok "$_LAST_RC" "bash-guard allows bash redirect for ephemeral session (fast-exit)"

# --- Closed branch protection (Gate 5) ---
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
mkdir -p "$SB/.claude/local"
echo "feature/test" > "$SB/.claude/local/closed-branches"
REPO_OS_SKIP_MODE_GUARD=1 run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "echo test > $SB/src/output.txt")"
assert_hook_blocks "$_LAST_RC" "bash-guard blocks bash redirect on closed branch"
rm -f "$SB/.claude/local/closed-branches"

# ============================================================
# L3.10c — session-close-check.sh ephemeral session (Phase 3b)
# ============================================================
tap_section "L3.10c: session-close-check.sh — ephemeral session exempt path"

# --- Ephemeral session → unconditional allow, no branch seal ---
_reinit_close_sandbox
reset_phase "ephemeral"
_advance "conversation" 2>/dev/null
rm -f "$SB/.claude/local/closed-branches"
run_hook_rc "session-close-check.sh" "$(fixture_stop)"
assert_ok "$_LAST_RC" "session-close-check allows ephemeral session unconditionally"
# Ephemeral sessions should NOT seal the branch
if [ -f "$SB/.claude/local/closed-branches" ] && grep -qxF "feature/test" "$SB/.claude/local/closed-branches" 2>/dev/null; then
  _tap_fail "ephemeral session does not seal branch" "branch found in closed-branches"
else
  _tap_pass "ephemeral session does not seal branch"
fi

# ============================================================
# L3.10c2 — session-close-check.sh editor-live pause-Stop (Decision 0023 Amdt 1)
# ============================================================
tap_section "L3.10c2: session-close-check.sh — editor-live pause vs close Stop"

# Editor-live Stops mid-loop are pauses, not closes. The guard must exit early
# WITHOUT running cleanup/seal/merge, so .session-id (identity), the branch, and
# phase-state all survive across pauses. This sandbox uses file-based identity
# (.session-id, no REPO_OS_SESSION_ID) — the exact interactive scenario the bug
# manifested in. Guards the fix for the "every Stop = close" identity-churn bug.
switch_sandbox_branch "feature/test"

# --- Pause Stop (current_phase=build, review NOT completed) → no close work ---
_reinit_close_sandbox
reset_phase "editor-live"
_advance "build" 2>/dev/null
_el_sd="$(get_session_state_dir)"
rm -f "$SB/.claude/local/closed-branches" "$_el_sd/.stop-attempt-count"
run_hook_rc "session-close-check.sh" "$(fixture_stop)" > /dev/null 2>&1
assert_ok "$_LAST_RC" "editor-live pause Stop allows (no block)"
assert_file_exists "$SB/.claude/.session-id" \
  "editor-live pause Stop preserves .session-id (no identity churn)"
assert_file_exists "$_el_sd/phase-state" \
  "editor-live pause Stop preserves phase-state (cleanup not run)"
assert_file_not_exists "$_el_sd/.stop-attempt-count" \
  "editor-live pause Stop exits before the 3-attempt counter"
if [ -f "$SB/.claude/local/closed-branches" ] && grep -qxF "feature/test" "$SB/.claude/local/closed-branches" 2>/dev/null; then
  _tap_fail "editor-live pause Stop does not seal branch" "branch found in closed-branches"
else
  _tap_pass "editor-live pause Stop does not seal branch"
fi

# --- Close Stop (review in phases_completed) → falls through past the guard ---
# Advancing build→commit→review marks the close sequence begun. The guard must
# NOT short-circuit; the hook runs into the close path and increments the
# 3-attempt counter (written immediately after the guard).
_reinit_close_sandbox
reset_phase "editor-live"
_advance "build" 2>/dev/null
_advance "commit" 2>/dev/null
_advance "review" 2>/dev/null
_el_sd="$(get_session_state_dir)"
rm -f "$_el_sd/.stop-attempt-count"
run_hook_rc "session-close-check.sh" "$(fixture_stop)" > /dev/null 2>&1
assert_file_exists "$_el_sd/.stop-attempt-count" \
  "editor-live close Stop falls through the pause guard into close logic"

# Clean up any seal from the close-path test
rm -f "$SB/.claude/local/closed-branches"

# ============================================================
# L3.10d — session-close-check.sh spec/prototype session log exemption
# ============================================================
tap_section "L3.10d: session-close-check.sh — spec/prototype session log exemption"

# Ensure we're on a feature branch
switch_sandbox_branch "feature/test"

# --- Test 1: spec-fresh with commits closes without session-log block ---
_reinit_close_sandbox
# Hash matches current (not modified) — would normally block
# (no per-session log file written — simulates unmodified state)
# Invalid baseline → non-zero session
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
reset_phase "spec-fresh"
_advance "interview" 2>/dev/null
_advance "write" 2>/dev/null
run_hook_rc "session-close-check.sh" "$(fixture_stop)" > "$_L3_OUT"
assert_ok "$_LAST_RC" "session-close-check allows spec-fresh without session log update"
# Verify it did NOT emit a block decision
if grep -q '"block"' "$_L3_OUT" 2>/dev/null; then
  _tap_fail "spec-fresh does not block on session log" "got block decision"
else
  _tap_pass "spec-fresh does not block on session log"
fi

# --- Test 2: prototype-poc with commits closes without session-log block ---
_reinit_close_sandbox
# (no per-session log file written — simulates unmodified state)
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
reset_phase "prototype-poc"
_advance "build" 2>/dev/null
run_hook_rc "session-close-check.sh" "$(fixture_stop)" > "$_L3_OUT"
assert_ok "$_LAST_RC" "session-close-check allows prototype-poc without session log update"
if grep -q '"block"' "$_L3_OUT" 2>/dev/null; then
  _tap_fail "prototype-poc does not block on session log" "got block decision"
else
  _tap_pass "prototype-poc does not block on session log"
fi

# --- Test 3: standard session still blocks on missing session log ---
_reinit_close_sandbox
# (no per-session log file written — simulates unmodified state)
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
reset_phase "standard"
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
_mark_closing
run_hook_rc "session-close-check.sh" "$(fixture_stop)" > "$_L3_OUT"
assert_ok "$_LAST_RC" "session-close-check blocks standard session (JSON exit 0)"
assert_contains "$(cat "$_L3_OUT")" "block" "standard session emits block for missing session log"

# --- Test 4: spec-fresh with uncommitted changes still blocks ---
_reinit_close_sandbox
# Session log is "modified" (stale hash) so log check passes
_write_session_log  # creates per-session file with >100 bytes
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
reset_phase "spec-fresh"
_advance "interview" 2>/dev/null
_advance "write" 2>/dev/null
# Create uncommitted changes (use repo root — src/ may not exist in sandbox)
echo "uncommitted content" > "$SB/uncommitted-file.txt"
(cd "$SB" && git add uncommitted-file.txt 2>/dev/null)
_mark_closing
run_hook_rc "session-close-check.sh" "$(fixture_stop)" > "$_L3_OUT"
assert_ok "$_LAST_RC" "spec-fresh with uncommitted changes returns (JSON exit 0)"
assert_contains "$(cat "$_L3_OUT")" "block" "spec-fresh blocks on uncommitted changes"
assert_contains "$(cat "$_L3_OUT")" "Uncommitted" "spec-fresh reports uncommitted issue"
# Clean up staged file
(cd "$SB" && git reset HEAD uncommitted-file.txt 2>/dev/null; rm -f uncommitted-file.txt)

# ============================================================
# L3.15 — Parallel task group: merge brief mechanics
# ============================================================
tap_section "L3.15: Parallel task group — merge brief mechanics"

# Ensure we're on a feature branch
switch_sandbox_branch "feature/test"

# --- Test 1: Parallel content brief never seals branch ---
_reinit_close_sandbox
_write_session_log  # creates per-session file with >100 bytes
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
reset_phase "taskgroup"
_advance "contract-init" 2>/dev/null
_advance "plan" 2>/dev/null
_advance "approval" 2>/dev/null
_advance "build" 2>/dev/null
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
_write_session_log  # creates per-session file with >100 bytes
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
reset_phase "taskgroup-merge"
_advance "contract-init" 2>/dev/null
_advance "cohesion" 2>/dev/null
_advance "verify" 2>/dev/null
_advance "commit" 2>/dev/null
# Create completion markers in per-session state dir
_TSD="$(get_session_state_dir)"
mkdir -p "$_TSD"
echo "2026-01-01T00:00:00Z" > "$_TSD/tg-parallel-group-brief-1.complete"
echo "2026-01-01T00:00:00Z" > "$_TSD/tg-parallel-group-brief-2.complete"
rm -f "$SB/.claude/local/closed-branches"
_mark_closing
run_hook_rc "session-close-check.sh" "$(fixture_session_end)"
assert_ok "$_LAST_RC" "session-close-check allows merge brief with markers"
assert_file_contains "$SB/.claude/local/closed-branches" "feature/test" \
  "merge brief with markers seals branch"

# --- Test 3: Merge brief without markers does NOT seal ---
_reinit_close_sandbox
# Use zero-change path so hook doesn't block on session log
git -C "$SB" rev-parse HEAD > "$SB/.claude/.session-baseline-sha"
# (no per-session log file written — simulates unmodified state)
reset_phase "taskgroup-merge"
# Remove any markers from per-session state dir
rm -f "$(get_session_state_dir)"/tg-*-brief-*.complete
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
# (no per-session log file written — simulates unmodified state)
reset_phase "taskgroup-merge"
_TSD="$(get_session_state_dir)"
mkdir -p "$_TSD"
echo "2026-01-01T00:00:00Z" > "$_TSD/tg-test-group-brief-1.complete"
echo "2026-01-01T00:00:00Z" > "$_TSD/tg-test-group-brief-2.complete"
_mark_closing
run_hook_rc "session-close-check.sh" "$(fixture_session_end)" > /dev/null 2>&1
assert_ok "$_LAST_RC" "session-close-check completes for taskgroup-merge cleanup test"
# Markers should be cleaned up (per-session dir may also be removed)
if ls "$_TSD"/tg-*-brief-*.complete 2>/dev/null | grep -q .; then
  _tap_fail "taskgroup-merge cleanup removes completion markers" "markers still exist"
else
  _tap_pass "taskgroup-merge cleanup removes completion markers"
fi

# --- Test 5: Markers preserved for taskgroup (non-merge) ---
_reinit_close_sandbox
# Zero-change session
git -C "$SB" rev-parse HEAD > "$SB/.claude/.session-baseline-sha"
# (no per-session log file written — simulates unmodified state)
reset_phase "taskgroup"
_TSD="$(get_session_state_dir)"
mkdir -p "$_TSD"
echo "2026-01-01T00:00:00Z" > "$_TSD/tg-test-group-brief-1.complete"
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
assert_file_exists "$_TSD/tg-test-group-brief-1.complete" \
  "taskgroup session preserves completion markers"

# Clean up parallel test fixtures
rm -rf "$SB/.claude/local/task-groups"
rm -f "$SB/.claude/local/closed-branches"
rm -f "$_TSD"/tg-*-brief-*.complete 2>/dev/null || true

# ============================================================
# Summary
# ============================================================
finish_tests