#!/usr/bin/env bash
# Layer 2 — Lifecycle walk tests for _phase-helper.sh.
# Exercises init_phase, advance_phase, assert_phase, get_phase through
# complete phase sequences for all 14 session types in a sandbox.
# Tests loops, session-ID binding, auto mode, and error paths.
#
# Bash 3.2 compatible. No external dependencies.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/test-helpers.sh"

setup_sandbox

# Seed the substance file(s) advance_phase's gate requires for <phase>, in the
# per-session state dir (Decision 0030). Defensive: extra files are ignored by
# ungated phases. Mirrors the inline pattern used in L2.2.
_l2_seed() {
  local _sd _sid
  _sd="$(get_session_state_dir)"
  _sid=$(get_session_id "$_REPO_OS_ROOT" 2>/dev/null)
  [ -z "$_sid" ] && _sid=$(cat "$(get_sandbox)/.claude/.session-id" 2>/dev/null)
  case "$1" in
    approval) printf 'GATE_RESULT: APPROVED\nsession_id: %s\n' "$_sid" > "$_sd/pragmatist-signed"
              printf 'session_id: %s\nmode: auto\n' "$_sid" > "$_sd/plan-approved" ;;
    verify)   printf 'GATE_RESULT: APPROVED\nsession_id: %s\n' "$_sid" > "$_sd/cohesion-reviewed" ;;
    commit)   printf 'GATE_RESULT: APPROVED\nsession_id: %s\n' "$_sid" > "$_sd/qa-verified" ;;
  esac
}

# ============================================================
# L2.1 — init_phase creates correct state for all 14 types
# ============================================================
tap_section "L2.1: init_phase — creates correct state for all types"

for stype in $SESSION_TYPES; do
  # Reset phase-state for each type
  rm -f "$(get_session_state_dir)/phase-state"

  init_phase "$stype"
  rc=$?
  assert_ok "$rc" "init_phase '$stype' succeeds"

  state_file="$(get_session_state_dir)/phase-state"

  # Verify fields
  assert_file_contains "$state_file" "^session_type: ${stype}$" "init '$stype' sets session_type"
  assert_file_contains "$state_file" "^current_phase: init$" "init '$stype' sets current_phase to init"
  assert_file_contains "$state_file" "^cycle: 1$" "init '$stype' sets cycle to 1"
  assert_file_contains "$state_file" "^mode: review$" "init '$stype' sets mode to review"
  assert_file_contains "$state_file" "^solo: false$" "init '$stype' sets solo to false"
  assert_file_contains "$state_file" "^tag: agent$" "init '$stype' sets tag to agent (init phase)"
  assert_file_contains "$state_file" "^session_id: " "init '$stype' sets session_id"
  assert_file_contains "$state_file" "^timestamp: " "init '$stype' sets timestamp"
done

# ============================================================
# L2.2 — Full forward walk for all 14 types
# ============================================================
tap_section "L2.2: advance_phase — full forward walk for all types"

for stype in $SESSION_TYPES; do
  rm -f "$(get_session_state_dir)/phase-state"
  init_phase "$stype"

  phases=$(get_phases_for_type "$stype")
  prev_phase="init"
  walk_ok=true

  # Skip init (already set), walk through remaining phases
  first=true
  for phase in $phases; do
    if [ "$first" = true ]; then
      first=false
      continue
    fi

    # Pre-write substance files required by advance_phase checks
    _l2_sd="$(get_session_state_dir)"
    _l2_sid=$(cat "$(get_sandbox)/.claude/.session-id")
    case "$phase" in
      approval)
        if has_plan_gate "$stype"; then
          printf 'timestamp: test\nagent: pragmatist\nsession_id: %s\nGATE_RESULT: APPROVED\n' "$_l2_sid" > "$_l2_sd/pragmatist-signed"
        fi
        printf 'timestamp: test\nsession_id: %s\nmode: auto\n' "$_l2_sid" > "$_l2_sd/plan-approved"
        ;;
      verify)
        printf 'timestamp: test\nagent: critic\nsession_id: %s\nGATE_RESULT: APPROVED\n' "$_l2_sid" > "$_l2_sd/cohesion-reviewed"
        ;;
      commit)
        printf 'timestamp: test\nagent: qa-verifier\nsession_id: %s\nGATE_RESULT: APPROVED\n' "$_l2_sid" > "$_l2_sd/qa-verified"
        ;;
    esac

    advance_phase "$phase" 2>/dev/null
    rc=$?
    if [ "$rc" -ne 0 ]; then
      _tap_fail "advance_phase '$stype' $prev_phase -> $phase" "exit code $rc"
      walk_ok=false
      break
    fi

    # Verify current phase
    current=$(get_phase)
    if [ "$current" != "$phase" ]; then
      _tap_fail "get_phase after advance '$stype' -> $phase" "expected '$phase', got '$current'"
      walk_ok=false
      break
    fi

    prev_phase="$phase"
  done

  if [ "$walk_ok" = true ]; then
    _tap_pass "full forward walk '$stype' — all transitions succeed"

    # Verify final phase is close
    final=$(get_phase)
    assert_eq "$final" "close" "'$stype' ends at close"
  fi
done

# ============================================================
# L2.3 — assert_phase works at each point in sequence
# ============================================================
tap_section "L2.3: assert_phase — correct pass/fail at each point"

# Use standard as representative test
rm -f "$(get_session_state_dir)/phase-state"
init_phase "standard"

# At init, assert_phase init should pass, plan should fail
assert_phase "init" && rc=0 || rc=$?
assert_ok "$rc" "assert_phase 'init' passes when at init"

assert_phase "plan" && rc=0 || rc=$?
assert_fail "$rc" "assert_phase 'plan' fails when at init"

# Advance to build
advance_phase "drift-check" 2>/dev/null
advance_phase "plan" 2>/dev/null
_l2_seed approval
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null

# At build, assert_phase init/plan/approval/build should all pass (>= semantics)
assert_phase "init" && rc=0 || rc=$?
assert_ok "$rc" "assert_phase 'init' passes when at build (>= semantics)"

assert_phase "plan" && rc=0 || rc=$?
assert_ok "$rc" "assert_phase 'plan' passes when at build"

assert_phase "build" && rc=0 || rc=$?
assert_ok "$rc" "assert_phase 'build' passes when at build"

# But review/verify/commit should fail
assert_phase "review" && rc=0 || rc=$?
assert_fail "$rc" "assert_phase 'review' fails when at build"

assert_phase "verify" && rc=0 || rc=$?
assert_fail "$rc" "assert_phase 'verify' fails when at build"

# ============================================================
# L2.4 — Illegal backward transitions are blocked
# ============================================================
tap_section "L2.4: advance_phase — illegal backward transitions blocked"

# Standard: at review, cannot go back to plan or approval (not in loop set)
rm -f "$(get_session_state_dir)/phase-state"
init_phase "standard"
advance_phase "drift-check" 2>/dev/null
advance_phase "plan" 2>/dev/null
_l2_seed approval
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
advance_phase "review" 2>/dev/null

advance_phase "plan" 2>/dev/null && rc=0 || rc=$?
assert_fail "$rc" "standard: cannot go back from review to plan"

advance_phase "approval" 2>/dev/null && rc=0 || rc=$?
assert_fail "$rc" "standard: cannot go back from review to approval"

advance_phase "init" 2>/dev/null && rc=0 || rc=$?
assert_fail "$rc" "standard: cannot go back from review to init"

# Experiment: at commit, cannot go back to build (no loops defined)
rm -f "$(get_session_state_dir)/phase-state"
init_phase "experiment"
advance_phase "build" 2>/dev/null
_l2_seed commit
advance_phase "commit" 2>/dev/null

advance_phase "build" 2>/dev/null && rc=0 || rc=$?
assert_fail "$rc" "experiment: cannot go back from commit to build (no loops)"

# advisory-init: at synthesize, cannot go back to dispatch
rm -f "$(get_session_state_dir)/phase-state"
init_phase "advisory-init"
advance_phase "tier-select" 2>/dev/null
advance_phase "dispatch" 2>/dev/null
advance_phase "synthesize" 2>/dev/null

advance_phase "dispatch" 2>/dev/null && rc=0 || rc=$?
assert_fail "$rc" "advisory-init: cannot go back from synthesize to dispatch"

# ============================================================
# L2.5 — Legal loops succeed and increment cycle counter
# ============================================================
tap_section "L2.5: advance_phase — legal loops increment cycle"

# Standard: review→build loop
rm -f "$(get_session_state_dir)/phase-state"
init_phase "standard"
advance_phase "drift-check" 2>/dev/null
advance_phase "plan" 2>/dev/null
_l2_seed approval
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
advance_phase "review" 2>/dev/null

# Check cycle is 1 before loop
state_file="$(get_session_state_dir)/phase-state"
cycle=$(grep '^cycle:' "$state_file" | sed 's/^cycle: *//')
assert_eq "$cycle" "1" "standard cycle = 1 before review→build loop"

# Loop: review→build
advance_phase "build" 2>/dev/null
rc=$?
assert_ok "$rc" "standard: review→build loop succeeds"

current=$(get_phase)
assert_eq "$current" "build" "standard: after review→build, phase is build"

cycle=$(grep '^cycle:' "$state_file" | sed 's/^cycle: *//')
assert_eq "$cycle" "2" "standard: cycle incremented to 2 after review→build"

# Continue to review again, then loop again
advance_phase "review" 2>/dev/null
advance_phase "build" 2>/dev/null
rc=$?
assert_ok "$rc" "standard: second review→build loop succeeds"

cycle=$(grep '^cycle:' "$state_file" | sed 's/^cycle: *//')
assert_eq "$cycle" "3" "standard: cycle incremented to 3 after second loop"

# Standard: verify→build loop
advance_phase "review" 2>/dev/null
_l2_seed verify
advance_phase "verify" 2>/dev/null
advance_phase "build" 2>/dev/null
rc=$?
assert_ok "$rc" "standard: verify→build loop succeeds"

cycle=$(grep '^cycle:' "$state_file" | sed 's/^cycle: *//')
assert_eq "$cycle" "4" "standard: cycle incremented to 4 after verify→build"

# Taskgroup: review→build loop
rm -f "$(get_session_state_dir)/phase-state"
init_phase "taskgroup"
advance_phase "contract-init" 2>/dev/null
advance_phase "drift-check" 2>/dev/null
advance_phase "plan" 2>/dev/null
_l2_seed approval
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
advance_phase "review" 2>/dev/null
advance_phase "build" 2>/dev/null
rc=$?
assert_ok "$rc" "taskgroup: review→build loop succeeds"

cycle=$(grep '^cycle:' "$state_file" | sed 's/^cycle: *//')
assert_eq "$cycle" "2" "taskgroup: cycle incremented to 2"

# Hotfix: verify→build loop (only loop available)
rm -f "$(get_session_state_dir)/phase-state"
init_phase "hotfix"
advance_phase "plan" 2>/dev/null
_l2_seed approval
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
_l2_seed verify
advance_phase "verify" 2>/dev/null
advance_phase "build" 2>/dev/null
rc=$?
assert_ok "$rc" "hotfix: verify→build loop succeeds"

cycle=$(grep '^cycle:' "$state_file" | sed 's/^cycle: *//')
assert_eq "$cycle" "2" "hotfix: cycle incremented to 2"

# Hotfix: review→build should NOT work (hotfix has no review phase)
# This is implicitly covered by the fact that hotfix has no review phase at all

# ============================================================
# L2.6 — Session-ID mismatch produces stale-state behavior
# ============================================================
tap_section "L2.6: session-ID mismatch — stale state detection"

rm -f "$(get_session_state_dir)/phase-state"
init_phase "standard"
advance_phase "drift-check" 2>/dev/null
advance_phase "plan" 2>/dev/null

# Verify current phase works with matching session ID
current=$(get_phase)
assert_eq "$current" "plan" "get_phase returns 'plan' with matching session ID"

# Change session ID to simulate new session
set_test_session_id "different-session-id"

# get_phase should return empty (stale)
current=$(get_phase)
assert_eq "$current" "" "get_phase returns empty after session-ID mismatch"

# assert_phase should fail
assert_phase "plan" && rc=0 || rc=$?
assert_fail "$rc" "assert_phase fails after session-ID mismatch"

# advance_phase should fail
advance_phase "approval" 2>/dev/null && rc=0 || rc=$?
assert_fail "$rc" "advance_phase fails after session-ID mismatch"

# get_tag should return empty
tag=$(get_tag)
assert_eq "$tag" "" "get_tag returns empty after session-ID mismatch"

# get_phase_mode defaults to review
mode=$(get_phase_mode)
assert_eq "$mode" "review" "get_phase_mode defaults to review after mismatch"

# get_solo defaults to false
solo=$(get_solo)
assert_eq "$solo" "false" "get_solo defaults to false after mismatch"

# Restore session ID for remaining tests
set_test_session_id "test-session-$(date +%s)"

# ============================================================
# L2.7 — Auto mode: forward jump past op-review
# ============================================================
tap_section "L2.7: auto mode — forward jump past op-review"

# Standard: jump from commit directly to close (skipping op-review)
rm -f "$(get_session_state_dir)/phase-state"
init_phase "standard"
advance_phase "drift-check" 2>/dev/null
advance_phase "plan" 2>/dev/null
_l2_seed approval
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
advance_phase "review" 2>/dev/null
_l2_seed verify
advance_phase "verify" 2>/dev/null
_l2_seed commit
advance_phase "commit" 2>/dev/null

# Skip op-review, go directly to close
advance_phase "close" 2>/dev/null
rc=$?
assert_ok "$rc" "standard: commit→close (skipping op-review) succeeds"

current=$(get_phase)
assert_eq "$current" "close" "standard: phase is close after skipping op-review"

# Taskgroup: same forward jump
rm -f "$(get_session_state_dir)/phase-state"
init_phase "taskgroup"
advance_phase "contract-init" 2>/dev/null
advance_phase "drift-check" 2>/dev/null
advance_phase "plan" 2>/dev/null
_l2_seed approval
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
advance_phase "review" 2>/dev/null
_l2_seed verify
advance_phase "verify" 2>/dev/null
_l2_seed commit
advance_phase "commit" 2>/dev/null
advance_phase "contract-update" 2>/dev/null

# Skip op-review, go directly to close
advance_phase "close" 2>/dev/null
rc=$?
assert_ok "$rc" "taskgroup: contract-update→close (skipping op-review) succeeds"

# advisory-init: synthesize→validate (skipping op-review)
rm -f "$(get_session_state_dir)/phase-state"
init_phase "advisory-init"
advance_phase "tier-select" 2>/dev/null
advance_phase "dispatch" 2>/dev/null
advance_phase "synthesize" 2>/dev/null

advance_phase "validate" 2>/dev/null
rc=$?
assert_ok "$rc" "advisory-init: synthesize→validate (skipping op-review) succeeds"

# audit: synthesize→close (skipping op-review)
rm -f "$(get_session_state_dir)/phase-state"
init_phase "audit"
advance_phase "scope" 2>/dev/null
advance_phase "dispatch" 2>/dev/null
advance_phase "synthesize" 2>/dev/null

advance_phase "close" 2>/dev/null
rc=$?
assert_ok "$rc" "audit: synthesize→close (skipping op-review) succeeds"

# taskdef-brief: synthesize→approval→output (approval is now a gated phase, Decision 0029)
rm -f "$(get_session_state_dir)/phase-state"
init_phase "taskdef-brief"
advance_phase "dispatch" 2>/dev/null
advance_phase "synthesize" 2>/dev/null

# approval phase requires plan-approved state file (substance check)
_l2_seed approval
advance_phase "approval" 2>/dev/null
rc=$?
assert_ok "$rc" "taskdef-brief: synthesize→approval succeeds"

# output requires plan-approved (post-approval gate)
printf 'timestamp: test\nsession_id: %s\n' "$(get_test_session_id)" > "$(get_session_state_dir)/plan-approved"
advance_phase "output" 2>/dev/null
rc=$?
assert_ok "$rc" "taskdef-brief: approval→output succeeds (with plan-approved)"

# ============================================================
# L2.8 — Error paths
# ============================================================
tap_section "L2.8: error paths"

# Empty phase-state (no file)
rm -f "$(get_session_state_dir)/phase-state"

current=$(get_phase)
assert_eq "$current" "" "get_phase returns empty when no phase-state exists"

assert_phase "init" && rc=0 || rc=$?
assert_fail "$rc" "assert_phase fails when no phase-state exists"

advance_phase "plan" 2>/dev/null && rc=0 || rc=$?
assert_fail "$rc" "advance_phase fails when no phase-state exists"

# Unknown session type
init_phase "unknown-type" 2>/dev/null && rc=0 || rc=$?
assert_fail "$rc" "init_phase rejects unknown session type"

# Invalid phase for the session type
rm -f "$(get_session_state_dir)/phase-state"
init_phase "experiment"
advance_phase "plan" 2>/dev/null && rc=0 || rc=$?
assert_fail "$rc" "advance_phase rejects invalid phase 'plan' for experiment"

advance_phase "review" 2>/dev/null && rc=0 || rc=$?
assert_fail "$rc" "advance_phase rejects invalid phase 'review' for experiment"

# Missing session-id file
rm -f "$(get_session_state_dir)/phase-state"
init_phase "standard"

# Remove session-id file
rm -f "$(get_sandbox)/.claude/.session-id"

# get_phase should return empty (cannot validate session)
current=$(get_phase)
assert_eq "$current" "" "get_phase returns empty when .session-id missing"

# advance_phase should fail
advance_phase "plan" 2>/dev/null && rc=0 || rc=$?
assert_fail "$rc" "advance_phase fails when .session-id missing"

# Restore session-id for any remaining tests
echo "test-restore-$(date +%s)" > "$(get_sandbox)/.claude/.session-id"

# ============================================================
# L2.9 — phases_completed accumulates correctly
# ============================================================
tap_section "L2.9: phases_completed — accumulates through walk"

rm -f "$(get_session_state_dir)/phase-state"
init_phase "standard"

state_file="$(get_session_state_dir)/phase-state"

# After init, phases_completed should be empty
completed=$(grep '^phases_completed:' "$state_file" | sed 's/^phases_completed: *//')
assert_eq "$completed" "" "phases_completed empty after init"

# Advance through several phases
advance_phase "drift-check" 2>/dev/null
advance_phase "plan" 2>/dev/null
completed=$(grep '^phases_completed:' "$state_file" | sed 's/^phases_completed: *//')
assert_eq "$completed" "init,drift-check" "phases_completed = 'init,drift-check' after advancing to plan"

_l2_seed approval
advance_phase "approval" 2>/dev/null
completed=$(grep '^phases_completed:' "$state_file" | sed 's/^phases_completed: *//')
assert_eq "$completed" "init,drift-check,plan" "phases_completed = 'init,drift-check,plan' after advancing to approval"

advance_phase "build" 2>/dev/null
completed=$(grep '^phases_completed:' "$state_file" | sed 's/^phases_completed: *//')
assert_eq "$completed" "init,drift-check,plan,approval" "phases_completed accumulates through build"

# ============================================================
# L2.10 — Tag updates on advance
# ============================================================
tap_section "L2.10: tag updates correctly on advance"

rm -f "$(get_session_state_dir)/phase-state"
init_phase "standard"

tag=$(get_tag)
assert_eq "$tag" "agent" "tag = agent at init"

advance_phase "drift-check" 2>/dev/null
advance_phase "plan" 2>/dev/null
tag=$(get_tag)
assert_eq "$tag" "agent" "tag = agent at plan"

_l2_seed approval
advance_phase "approval" 2>/dev/null
tag=$(get_tag)
assert_eq "$tag" "operator" "tag = operator at approval"

advance_phase "build" 2>/dev/null
tag=$(get_tag)
assert_eq "$tag" "agent" "tag = agent at build"

advance_phase "review" 2>/dev/null
_l2_seed verify
advance_phase "verify" 2>/dev/null
_l2_seed commit
advance_phase "commit" 2>/dev/null
advance_phase "op-review" 2>/dev/null
tag=$(get_tag)
assert_eq "$tag" "operator" "tag = operator at op-review"

advance_phase "close" 2>/dev/null
tag=$(get_tag)
assert_eq "$tag" "agent" "tag = agent at close"

# ============================================================
# L2.11 — set_phase_mode and set_solo
# ============================================================
tap_section "L2.11: set_phase_mode and set_solo"

rm -f "$(get_session_state_dir)/phase-state"
init_phase "standard"

# Default mode is review
mode=$(get_phase_mode)
assert_eq "$mode" "review" "default mode is review"

# Set to auto
set_phase_mode "auto"
mode=$(get_phase_mode)
assert_eq "$mode" "auto" "mode set to auto"

# Set back to review
set_phase_mode "review"
mode=$(get_phase_mode)
assert_eq "$mode" "review" "mode set back to review"

# Invalid mode rejected
set_phase_mode "invalid" 2>/dev/null && rc=0 || rc=$?
assert_fail "$rc" "set_phase_mode rejects invalid value"

# Solo mode
solo=$(get_solo)
assert_eq "$solo" "false" "default solo is false"

set_solo "true"
solo=$(get_solo)
assert_eq "$solo" "true" "solo set to true"

set_solo "false"
solo=$(get_solo)
assert_eq "$solo" "false" "solo set back to false"

# Invalid solo rejected
set_solo "maybe" 2>/dev/null && rc=0 || rc=$?
assert_fail "$rc" "set_solo rejects invalid value"

# ============================================================
# L2.12 — a same-session re-init clears the previous unit's evidence (R40)
# ============================================================
# init_phase used to rewrite phase-state and remove NOTHING, so a second work
# unit in one session inherited the first's verdicts: matching session_id, valid
# dispatch_phase, every commit-gate check satisfied. Two units were gated on one
# unit's sign-off before this was found.
tap_section "L2.12: re-init clears session evidence (R40)"

_l2_sd="$(get_session_state_dir)"
_l2_sid=$(get_session_id "$_REPO_OS_ROOT" 2>/dev/null)
[ -n "$_l2_sid" ] || _l2_sid=$(cat "$(get_sandbox)/.claude/.session-id" 2>/dev/null)

# Seed a complete set of APPROVED verdicts, as a finished work unit leaves.
_l2_seed_evidence() {
  local f
  for f in plan-approved pragmatist-signed cohesion-reviewed diff-review-complete \
           qa-verified reviewer-signed security-signed functional-verified; do
    printf 'GATE_RESULT: APPROVED\nsession_id: %s\ndispatch_phase: verify\n' "$_l2_sid" > "$_l2_sd/$f"
  done
  printf 'result: PASSED\nsession_id: %s\n' "$_l2_sid" > "$_l2_sd/kg-updated"
  printf 'rounds: []\nsession_id: %s\n' "$_l2_sid" > "$_l2_sd/criteria-verdicts.yaml"
}

rm -f "$_l2_sd/phase-state"
init_phase standard > /dev/null 2>&1
_l2_seed_evidence
assert_file_exists "$_l2_sd/qa-verified" "L2.12 setup: evidence seeded"

# The re-init itself.
REPO_OS_ALLOW_REINIT=1 init_phase standard > /dev/null 2>&1
_l2_rc=$?
assert_ok "$_l2_rc" "re-init with ALLOW_REINIT succeeds"

for _l2_f in plan-approved pragmatist-signed cohesion-reviewed diff-review-complete \
             qa-verified reviewer-signed security-signed functional-verified \
             kg-updated criteria-verdicts.yaml; do
  assert_file_not_exists "$_l2_sd/$_l2_f" "re-init cleared $_l2_f"
done

# phase-state and session-resume.yaml are REWRITTEN by init, never cleared —
# clearing them would destroy the state the re-init is building.
assert_file_exists "$_l2_sd/phase-state" "re-init rewrote phase-state rather than clearing it"
assert_file_contains "$_l2_sd/phase-state" "^current_phase: init$" "re-init reset the phase to init"

# --- A FIRST init clears leftover verdicts but PRESERVES pre-writes ---
# The operator asked that a first init clear leftover evidence too — a close
# that never ran, or a safety-valve close, otherwise hands the next session the
# previous one's verdicts. The condition attached was "assuming this doesn't
# break the task group chain", and that condition is load-bearing:
# state-manager.sh pre-writes plan-approved for every daemon and task-group
# brief and deliberately does NOT pre-seed phase-state, so those briefs reach
# init_phase as a FIRST init with an approval already on disk. Clearing it
# indiscriminately would strand each one at "plan-approved missing".
rm -f "$_l2_sd/phase-state"
init_phase standard > /dev/null 2>&1
_l2_seed_evidence
rm -f "$_l2_sd/phase-state"          # no phase-state => first init
init_phase standard > /dev/null 2>&1
assert_file_not_exists "$_l2_sd/qa-verified" \
  "a FIRST init clears a leftover verdict (close that never ran)"
assert_file_not_exists "$_l2_sd/plan-approved" \
  "...including an operator-approved plan-approved with no pre-write marker"

# THE REGRESSION GUARD for the task group chain. Each of the three legitimate
# pre-writes must survive a first init, or every headless brief breaks.
for _l2_pre in 'source: runner' 'source: handoff-bundle' 'question_hash: runner-auto' 'question_hash: headless-runner'; do
  rm -f "$_l2_sd/phase-state"
  init_phase standard > /dev/null 2>&1
  printf 'timestamp: t\n%s\nlarge-scope: true\nmode: auto\nsession_id: %s\n' "$_l2_pre" "$_l2_sid" \
    > "$_l2_sd/plan-approved"
  printf 'GATE_RESULT: APPROVED\nsession_id: %s\ndispatch_phase: verify\n' "$_l2_sid" \
    > "$_l2_sd/qa-verified"
  rm -f "$_l2_sd/phase-state"
  init_phase standard > /dev/null 2>&1
  assert_file_exists "$_l2_sd/plan-approved" \
    "first init PRESERVES a plan-approved marked '$_l2_pre'"
  assert_file_not_exists "$_l2_sd/qa-verified" \
    "...while still clearing the stale verdict beside it ('$_l2_pre')"
done

# pragmatist-signed arrives via the handoff bundle the same way, which is why
# the marker is matched per FILE rather than by filename.
rm -f "$_l2_sd/phase-state"
init_phase standard > /dev/null 2>&1
printf 'GATE_RESULT: APPROVED\nsession_id: %s\nsource: handoff-bundle\n' "$_l2_sid" \
  > "$_l2_sd/pragmatist-signed"
rm -f "$_l2_sd/phase-state"
init_phase standard > /dev/null 2>&1
assert_file_exists "$_l2_sd/pragmatist-signed" \
  "first init PRESERVES a handoff-bundle pragmatist-signed (not just plan-approved)"

# An authorised re-init still clears everything, pre-write markers included:
# a second work unit must re-earn its approval whatever wrote the first one.
rm -f "$_l2_sd/phase-state"
init_phase standard > /dev/null 2>&1
printf 'timestamp: t\nsource: runner\nmode: auto\nsession_id: %s\n' "$_l2_sid" > "$_l2_sd/plan-approved"
REPO_OS_ALLOW_REINIT=1 init_phase standard > /dev/null 2>&1
assert_file_not_exists "$_l2_sd/plan-approved" \
  "an authorised RE-init clears even a runner pre-write (scope=all)"

# --- A refused re-init must not clear either ---
# Without the override the guard returns 1 before the clear site is reached.
# Re-seeded explicitly: the preceding cases consume this state, and an earlier
# version of this case inherited whatever they left, which made it pass or fail
# on sequencing rather than on the behaviour it names.
rm -f "$_l2_sd/phase-state"
init_phase standard > /dev/null 2>&1
_l2_seed_evidence
_l2_rc=0
init_phase standard > /dev/null 2>&1 || _l2_rc=$?
assert_fail "$_l2_rc" "re-init without ALLOW_REINIT is still refused"
assert_file_exists "$_l2_sd/qa-verified" "a REFUSED re-init leaves evidence untouched"

# --- A re-init that FAILS after the rewrite must not leave stale approvals ---
# The clear's placement before the phase-state rewrite is the property most
# likely to be undone by a later refactor, and moving the clear below the
# ancestry block would keep every other case in this suite green. So drive the
# failure directly: _check_main_ancestry is a plain function, so the test
# overrides it to fail. (An earlier version of this log claimed building this
# case needed a non-main-rooted sandbox branch and skipped it. It did not.)
rm -f "$_l2_sd/phase-state"
init_phase standard > /dev/null 2>&1
_l2_seed_evidence
_l2_real_ancestry=$(declare -f _check_main_ancestry)
_check_main_ancestry() { return 1; }
_l2_rc=0
REPO_OS_ALLOW_REINIT=1 init_phase standard > /dev/null 2>&1 || _l2_rc=$?
eval "$_l2_real_ancestry"          # restore before any later case
assert_fail "$_l2_rc" "a re-init with failing ancestry is refused"
assert_file_not_exists "$_l2_sd/qa-verified" \
  "a re-init that fails AFTER the rewrite still cleared the approvals (no fresh phase beside stale verdicts)"
assert_file_not_exists "$_l2_sd/plan-approved" \
  "...and plan-approved too, so the next attempt re-earns approval"

# --- Characterization: close must delete exactly the pre-refactor set ---
# Pins close's BEHAVIOUR, not the variable. An earlier version of this case
# compared $_SESSION_EVIDENCE_FILES against a hard-coded string, which would
# have stayed green if the loop in cleanup_session_files were deleted outright —
# the close path still had no test exercising it. This seeds every one of the 13
# files the pre-refactor close block deleted, runs the real function, and
# asserts each is gone.
rm -f "$_l2_sd/phase-state"
init_phase standard > /dev/null 2>&1
_l2_seed_evidence
_l2_close_set="plan-approved pragmatist-signed cohesion-reviewed diff-review-complete qa-verified reviewer-signed security-signed functional-verified kg-updated criteria-verdicts.yaml phase-state phase-state.gates session-resume.yaml"
for _l2_f in $_l2_close_set; do
  printf 'session_id: %s\n' "$_l2_sid" > "$_l2_sd/$_l2_f"
done

if type cleanup_session_files > /dev/null 2>&1; then
  # Signature is (repo_root, close_stype, closing_sid, is_closing). An earlier
  # version of this case passed the sid as the FIRST argument, which left
  # closing_sid empty — so _delete_if_owned deleted unconditionally and the
  # ownership guard was never exercised. It still passed, because state_dir comes
  # from get_session_state_dir rather than repo_root, which is exactly the kind
  # of pass-for-the-wrong-reason this case exists to avoid.
  #
  # REPO_OS_SESSION_ID must be exported for the call, and that is a harness
  # requirement rather than a product one: cleanup_session_files resolves its own
  # state directory through get_session_state_dir, which cannot see the synthetic
  # `test-session-<n>` id this sandbox installs and instead derives a fresh
  # timestamp id — so the function would clean a DIFFERENT directory and this case
  # would fail for a reason that has nothing to do with close. Measured both ways
  # before concluding that: with the env var set the seeded files are deleted,
  # without it the function resolves `wt-sessions/<new-timestamp-id>` and leaves
  # them. Production sessions carry REPO_OS_SESSION_ID or a per-process sidecar,
  # so this is not evidence of a defect in close.
  ( export REPO_OS_SESSION_ID="$_l2_sid"
    cleanup_session_files "$(get_sandbox)" "standard" "$_l2_sid" "true" > /dev/null 2>&1 || true )
  _l2_left=""
  for _l2_f in $_l2_close_set; do
    [ -f "$_l2_sd/$_l2_f" ] && _l2_left="${_l2_left}${_l2_f} "
  done
  assert_eq "$_l2_left" "" "close deletes every file the pre-refactor block deleted (13), with the real signature"

  # ...and close must REFUSE a file owned by another session, which is the other
  # half of the guard and the behaviour the skipped branch below reports on.
  rm -f "$_l2_sd/phase-state"
  init_phase standard > /dev/null 2>&1
  printf 'GATE_RESULT: APPROVED\nsession_id: some-other-session\n' > "$_l2_sd/qa-verified"
  ( export REPO_OS_SESSION_ID="$_l2_sid"
    cleanup_session_files "$(get_sandbox)" "standard" "$_l2_sid" "true" > /dev/null 2>&1 || true )
  assert_file_exists "$_l2_sd/qa-verified" "close leaves a file owned by a DIFFERENT session alone"
  rm -f "$_l2_sd/qa-verified"
else
  assert_eq "missing" "cleanup_session_files" "cleanup_session_files is available to exercise"
fi

# --- A re-init must REPORT evidence it could not clear ---
# The skipped branch had no test at all: deleting it outright left every other
# case green. It matters because the outcome is R40's shape — a verdict the next
# unit did not earn surviving a clear meant to remove it — so silence is the one
# unacceptable behaviour here.
rm -f "$_l2_sd/phase-state"
init_phase standard > /dev/null 2>&1
printf 'GATE_RESULT: APPROVED\nsession_id: a-different-session\n' > "$_l2_sd/qa-verified"
printf 'GATE_RESULT: APPROVED\nsession_id: %s\n' "$_l2_sid" > "$_l2_sd/cohesion-reviewed"
_l2_clear_err=$(REPO_OS_ALLOW_REINIT=1 init_phase standard 2>&1 >/dev/null || true)
assert_file_exists "$_l2_sd/qa-verified" \
  "re-init does NOT delete evidence owned by another session"
assert_file_not_exists "$_l2_sd/cohesion-reviewed" \
  "...while still clearing the files this session owns"
assert_contains "$_l2_clear_err" "could NOT clear" \
  "re-init reports the evidence it could not clear"
assert_contains "$_l2_clear_err" "qa-verified" \
  "...and names the file"
rm -f "$_l2_sd/qa-verified"

# --- The structured log, not just the stderr line ---
# The log_hook_event calls are wrapped in `2>/dev/null || true`, so a wrong
# signature or an unavailable logger fails silently — and that event is the only
# durable trace of a discarded verdict, since compare_manifest is advisory and
# the re-init re-baselines the manifest moments later. The stderr half was
# already asserted above; this reads the event stream back.
rm -f "$_l2_sd/phase-state"
init_phase standard > /dev/null 2>&1
_l2_seed_evidence
printf 'GATE_RESULT: BLOCKED reason="probe"\nsession_id: %s\ndispatch_phase: verify\n' "$_l2_sid" \
  > "$_l2_sd/qa-verified"
_l2_events="$(get_analytics_dir "$(get_sandbox)")/$(date +%Y-%m-%d).ndjson"
REPO_OS_ALLOW_REINIT=1 init_phase standard > /dev/null 2>&1

if [ -f "$_l2_events" ]; then
  _l2_ev=$(grep 'reinit_cleared' "$_l2_events" 2>/dev/null | tail -1 || true)
  assert_contains "$_l2_ev" "reinit_cleared" \
    "the clear writes a reinit_cleared event to the analytics stream"
  # The discarded verdict must be recoverable from the event, not just its name:
  # a BLOCKED verdict silently removed is the case this logging exists for.
  assert_contains "$_l2_ev" "qa-verified=BLOCKED" \
    "...carrying the discarded verdict, so a removed BLOCKED is recoverable"

  # A first-init clear must be distinguishable in the stream from a re-init one:
  # "a second work unit re-earns its approvals" and "a stale verdict was swept
  # before a fresh session" are different events to read in an audit.
  rm -f "$_l2_sd/phase-state"
  init_phase standard > /dev/null 2>&1
  printf 'GATE_RESULT: APPROVED\nsession_id: %s\n' "$_l2_sid" > "$_l2_sd/qa-verified"
  rm -f "$_l2_sd/phase-state"
  init_phase standard > /dev/null 2>&1
  _l2_ev2=$(grep 'first_init_cleared' "$_l2_events" 2>/dev/null | tail -1 || true)
  assert_contains "$_l2_ev2" "first_init_cleared" \
    "a first-init clear logs first_init_cleared, not reinit_cleared"
else
  assert_eq "missing" "$_l2_events" "analytics event file exists after a clear"
fi

# ============================================================
# Summary
# ============================================================
finish_tests