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

# ============================================================
# L2.1 — init_phase creates correct state for all 14 types
# ============================================================
tap_section "L2.1: init_phase — creates correct state for all types"

for stype in $SESSION_TYPES; do
  # Reset phase-state for each type
  rm -f "$(get_sandbox)/.claude/.state/phase-state"

  init_phase "$stype"
  rc=$?
  assert_ok "$rc" "init_phase '$stype' succeeds"

  state_file="$(get_sandbox)/.claude/.state/phase-state"

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
  rm -f "$(get_sandbox)/.claude/.state/phase-state"
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
rm -f "$(get_sandbox)/.claude/.state/phase-state"
init_phase "standard"

# At init, assert_phase init should pass, plan should fail
assert_phase "init" && rc=0 || rc=$?
assert_ok "$rc" "assert_phase 'init' passes when at init"

assert_phase "plan" && rc=0 || rc=$?
assert_fail "$rc" "assert_phase 'plan' fails when at init"

# Advance to build
advance_phase "plan" 2>/dev/null
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
rm -f "$(get_sandbox)/.claude/.state/phase-state"
init_phase "standard"
advance_phase "plan" 2>/dev/null
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
rm -f "$(get_sandbox)/.claude/.state/phase-state"
init_phase "experiment"
advance_phase "build" 2>/dev/null
advance_phase "commit" 2>/dev/null

advance_phase "build" 2>/dev/null && rc=0 || rc=$?
assert_fail "$rc" "experiment: cannot go back from commit to build (no loops)"

# advisory-init: at synthesize, cannot go back to dispatch
rm -f "$(get_sandbox)/.claude/.state/phase-state"
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
rm -f "$(get_sandbox)/.claude/.state/phase-state"
init_phase "standard"
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
advance_phase "review" 2>/dev/null

# Check cycle is 1 before loop
state_file="$(get_sandbox)/.claude/.state/phase-state"
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
advance_phase "verify" 2>/dev/null
advance_phase "build" 2>/dev/null
rc=$?
assert_ok "$rc" "standard: verify→build loop succeeds"

cycle=$(grep '^cycle:' "$state_file" | sed 's/^cycle: *//')
assert_eq "$cycle" "4" "standard: cycle incremented to 4 after verify→build"

# Taskgroup: review→build loop
rm -f "$(get_sandbox)/.claude/.state/phase-state"
init_phase "taskgroup"
advance_phase "contract-init" 2>/dev/null
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
advance_phase "review" 2>/dev/null
advance_phase "build" 2>/dev/null
rc=$?
assert_ok "$rc" "taskgroup: review→build loop succeeds"

cycle=$(grep '^cycle:' "$state_file" | sed 's/^cycle: *//')
assert_eq "$cycle" "2" "taskgroup: cycle incremented to 2"

# Hotfix: verify→build loop (only loop available)
rm -f "$(get_sandbox)/.claude/.state/phase-state"
init_phase "hotfix"
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
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

rm -f "$(get_sandbox)/.claude/.state/phase-state"
init_phase "standard"
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
rm -f "$(get_sandbox)/.claude/.state/phase-state"
init_phase "standard"
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
advance_phase "review" 2>/dev/null
advance_phase "verify" 2>/dev/null
advance_phase "commit" 2>/dev/null

# Skip op-review, go directly to close
advance_phase "close" 2>/dev/null
rc=$?
assert_ok "$rc" "standard: commit→close (skipping op-review) succeeds"

current=$(get_phase)
assert_eq "$current" "close" "standard: phase is close after skipping op-review"

# Taskgroup: same forward jump
rm -f "$(get_sandbox)/.claude/.state/phase-state"
init_phase "taskgroup"
advance_phase "contract-init" 2>/dev/null
advance_phase "plan" 2>/dev/null
advance_phase "approval" 2>/dev/null
advance_phase "build" 2>/dev/null
advance_phase "review" 2>/dev/null
advance_phase "verify" 2>/dev/null
advance_phase "commit" 2>/dev/null
advance_phase "contract-update" 2>/dev/null

# Skip op-review, go directly to close
advance_phase "close" 2>/dev/null
rc=$?
assert_ok "$rc" "taskgroup: contract-update→close (skipping op-review) succeeds"

# advisory-init: synthesize→validate (skipping op-review)
rm -f "$(get_sandbox)/.claude/.state/phase-state"
init_phase "advisory-init"
advance_phase "tier-select" 2>/dev/null
advance_phase "dispatch" 2>/dev/null
advance_phase "synthesize" 2>/dev/null

advance_phase "validate" 2>/dev/null
rc=$?
assert_ok "$rc" "advisory-init: synthesize→validate (skipping op-review) succeeds"

# audit: synthesize→close (skipping op-review)
rm -f "$(get_sandbox)/.claude/.state/phase-state"
init_phase "audit"
advance_phase "scope" 2>/dev/null
advance_phase "dispatch" 2>/dev/null
advance_phase "synthesize" 2>/dev/null

advance_phase "close" 2>/dev/null
rc=$?
assert_ok "$rc" "audit: synthesize→close (skipping op-review) succeeds"

# taskdef-brief: synthesize→output (skipping op-review)
rm -f "$(get_sandbox)/.claude/.state/phase-state"
init_phase "taskdef-brief"
advance_phase "dispatch" 2>/dev/null
advance_phase "synthesize" 2>/dev/null

advance_phase "output" 2>/dev/null
rc=$?
assert_ok "$rc" "taskdef-brief: synthesize→output (skipping op-review) succeeds"

# ============================================================
# L2.8 — Error paths
# ============================================================
tap_section "L2.8: error paths"

# Empty phase-state (no file)
rm -f "$(get_sandbox)/.claude/.state/phase-state"

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
rm -f "$(get_sandbox)/.claude/.state/phase-state"
init_phase "experiment"
advance_phase "plan" 2>/dev/null && rc=0 || rc=$?
assert_fail "$rc" "advance_phase rejects invalid phase 'plan' for experiment"

advance_phase "review" 2>/dev/null && rc=0 || rc=$?
assert_fail "$rc" "advance_phase rejects invalid phase 'review' for experiment"

# Missing session-id file
rm -f "$(get_sandbox)/.claude/.state/phase-state"
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

rm -f "$(get_sandbox)/.claude/.state/phase-state"
init_phase "standard"

state_file="$(get_sandbox)/.claude/.state/phase-state"

# After init, phases_completed should be empty
completed=$(grep '^phases_completed:' "$state_file" | sed 's/^phases_completed: *//')
assert_eq "$completed" "" "phases_completed empty after init"

# Advance through several phases
advance_phase "plan" 2>/dev/null
completed=$(grep '^phases_completed:' "$state_file" | sed 's/^phases_completed: *//')
assert_eq "$completed" "init" "phases_completed = 'init' after advancing to plan"

advance_phase "approval" 2>/dev/null
completed=$(grep '^phases_completed:' "$state_file" | sed 's/^phases_completed: *//')
assert_eq "$completed" "init,plan" "phases_completed = 'init,plan' after advancing to approval"

advance_phase "build" 2>/dev/null
completed=$(grep '^phases_completed:' "$state_file" | sed 's/^phases_completed: *//')
assert_eq "$completed" "init,plan,approval" "phases_completed accumulates through build"

# ============================================================
# L2.10 — Tag updates on advance
# ============================================================
tap_section "L2.10: tag updates correctly on advance"

rm -f "$(get_sandbox)/.claude/.state/phase-state"
init_phase "standard"

tag=$(get_tag)
assert_eq "$tag" "agent" "tag = agent at init"

advance_phase "plan" 2>/dev/null
tag=$(get_tag)
assert_eq "$tag" "agent" "tag = agent at plan"

advance_phase "approval" 2>/dev/null
tag=$(get_tag)
assert_eq "$tag" "operator" "tag = operator at approval"

advance_phase "build" 2>/dev/null
tag=$(get_tag)
assert_eq "$tag" "agent" "tag = agent at build"

advance_phase "review" 2>/dev/null
advance_phase "verify" 2>/dev/null
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

rm -f "$(get_sandbox)/.claude/.state/phase-state"
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
# Summary
# ============================================================
finish_tests