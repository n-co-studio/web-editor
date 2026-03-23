#!/usr/bin/env bash
# Layer 1 — Pure function unit tests for _phase-helper.sh.
# Exercises get_phases_for_type, get_tag_for_phase, has_plan_gate,
# get_post_approval_phase, get_loops_for_type, get_phase_index,
# upgrade_session_type across all 17 session types.
#
# Bash 3.2 compatible. No external dependencies.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/test-helpers.sh"

setup_sandbox

# ============================================================
# L1.1 — get_phases_for_type returns non-empty for all 17 types
# ============================================================
tap_section "L1.1: get_phases_for_type — all 17 types return non-empty"

for stype in $SESSION_TYPES; do
  phases=$(get_phases_for_type "$stype")
  assert_neq "$phases" "" "get_phases_for_type '$stype' returns non-empty"
done

# Unknown type returns empty
unknown_phases=$(get_phases_for_type "nonexistent-type")
assert_eq "$unknown_phases" "" "get_phases_for_type 'nonexistent-type' returns empty"

# ============================================================
# L1.2 — get_phases_for_type returns expected sequences
# ============================================================
tap_section "L1.2: get_phases_for_type — expected sequences"

assert_eq "$(get_phases_for_type standard)" \
  "init plan approval build review verify user-review commit op-review close" \
  "standard phase sequence"

assert_eq "$(get_phases_for_type taskgroup)" \
  "init contract-init plan approval build review verify user-review commit contract-update op-review close" \
  "taskgroup phase sequence"

assert_eq "$(get_phases_for_type taskgroup-merge)" \
  "init contract-init cohesion verify commit op-review close" \
  "taskgroup-merge phase sequence"

assert_eq "$(get_phases_for_type hotfix)" \
  "init plan approval build verify commit close" \
  "hotfix phase sequence"

assert_eq "$(get_phases_for_type experiment)" \
  "init build commit close" \
  "experiment phase sequence"

assert_eq "$(get_phases_for_type spec-fresh)" \
  "init interview write approval governance close" \
  "spec-fresh phase sequence"

assert_eq "$(get_phases_for_type spec-update)" \
  "init interview write approval governance close" \
  "spec-update phase sequence"

assert_eq "$(get_phases_for_type prototype-napkin)" \
  "init build close" \
  "prototype-napkin phase sequence"

assert_eq "$(get_phases_for_type prototype-spike)" \
  "init build evaluate close" \
  "prototype-spike phase sequence"

assert_eq "$(get_phases_for_type prototype-poc)" \
  "init build evaluate document close" \
  "prototype-poc phase sequence"

assert_eq "$(get_phases_for_type advisory-init)" \
  "init tier-select dispatch synthesize op-review validate governance close" \
  "advisory-init phase sequence"

assert_eq "$(get_phases_for_type advisory-reinit)" \
  "init validate governance close" \
  "advisory-reinit phase sequence"

assert_eq "$(get_phases_for_type audit)" \
  "init scope dispatch synthesize op-review close" \
  "audit phase sequence"

assert_eq "$(get_phases_for_type taskdef-query)" \
  "init conversation close" \
  "taskdef-query phase sequence"

assert_eq "$(get_phases_for_type taskdef-brief)" \
  "init dispatch synthesize approval output close" \
  "taskdef-brief phase sequence"

assert_eq "$(get_phases_for_type editor-live)" \
  "init build commit review verify op-review close" \
  "editor-live phase sequence"

assert_eq "$(get_phases_for_type ephemeral)" \
  "init conversation close" \
  "ephemeral phase sequence"

# ============================================================
# L1.3 — get_tag_for_phase returns valid tag for every phase
# ============================================================
tap_section "L1.3: get_tag_for_phase — valid tags for all phases in all types"

for stype in $SESSION_TYPES; do
  phases=$(get_phases_for_type "$stype")
  for phase in $phases; do
    tag=$(get_tag_for_phase "$stype" "$phase")
    case "$tag" in
      agent|operator|both)
        _tap_pass "get_tag_for_phase '$stype' '$phase' = '$tag'"
        ;;
      *)
        _tap_fail "get_tag_for_phase '$stype' '$phase'" "invalid tag '$tag' (expected agent/operator/both)"
        ;;
    esac
  done
done

# ============================================================
# L1.4 — Spot-check specific tags from Decision 0014
# ============================================================
tap_section "L1.4: get_tag_for_phase — spot checks"

# Universal: init and close are always agent
for stype in $SESSION_TYPES; do
  assert_eq "$(get_tag_for_phase "$stype" init)" "agent" "$stype init tag = agent"
  assert_eq "$(get_tag_for_phase "$stype" close)" "agent" "$stype close tag = agent"
done

# Operator phases
assert_eq "$(get_tag_for_phase standard approval)" "operator" "standard approval = operator"
assert_eq "$(get_tag_for_phase standard op-review)" "operator" "standard op-review = operator"
assert_eq "$(get_tag_for_phase taskgroup approval)" "operator" "taskgroup approval = operator"
assert_eq "$(get_tag_for_phase taskgroup op-review)" "operator" "taskgroup op-review = operator"
assert_eq "$(get_tag_for_phase hotfix approval)" "operator" "hotfix approval = operator"
assert_eq "$(get_tag_for_phase advisory-init op-review)" "operator" "advisory-init op-review = operator"
assert_eq "$(get_tag_for_phase audit op-review)" "operator" "audit op-review = operator"
assert_eq "$(get_tag_for_phase taskdef-brief approval)" "operator" "taskdef-brief approval = operator"
assert_eq "$(get_tag_for_phase taskgroup-merge op-review)" "operator" "taskgroup-merge op-review = operator"
assert_eq "$(get_tag_for_phase taskgroup-merge cohesion)" "agent" "taskgroup-merge cohesion = agent"
assert_eq "$(get_tag_for_phase editor-live op-review)" "operator" "editor-live op-review = operator"
assert_eq "$(get_tag_for_phase editor-live build)" "agent" "editor-live build = agent"
assert_eq "$(get_tag_for_phase editor-live commit)" "agent" "editor-live commit = agent"

# Both phases
assert_eq "$(get_tag_for_phase spec-fresh interview)" "both" "spec-fresh interview = both"
assert_eq "$(get_tag_for_phase spec-update interview)" "both" "spec-update interview = both"
assert_eq "$(get_tag_for_phase prototype-spike evaluate)" "both" "prototype-spike evaluate = both"
assert_eq "$(get_tag_for_phase prototype-poc evaluate)" "both" "prototype-poc evaluate = both"
assert_eq "$(get_tag_for_phase advisory-init tier-select)" "both" "advisory-init tier-select = both"
assert_eq "$(get_tag_for_phase audit scope)" "both" "audit scope = both"
assert_eq "$(get_tag_for_phase taskdef-query conversation)" "both" "taskdef-query conversation = both"
assert_eq "$(get_tag_for_phase ephemeral conversation)" "both" "ephemeral conversation = both"

# ============================================================
# L1.5 — has_plan_gate
# ============================================================
tap_section "L1.5: has_plan_gate — correct boolean per type"

# Types WITH plan gate (have approval phase)
for stype in standard taskgroup hotfix spec-fresh spec-update taskdef-brief; do
  has_plan_gate "$stype"
  rc=$?
  assert_ok "$rc" "has_plan_gate '$stype' = true (has approval)"
done

# Types WITHOUT plan gate (no approval phase)
for stype in taskgroup-merge experiment editor-live prototype-napkin prototype-spike prototype-poc advisory-init advisory-reinit audit taskdef-query ephemeral; do
  has_plan_gate "$stype" && rc=0 || rc=$?
  assert_fail "$rc" "has_plan_gate '$stype' = false (no approval)"
done

# ============================================================
# L1.6 — get_post_approval_phase
# ============================================================
tap_section "L1.6: get_post_approval_phase — correct next phase"

assert_eq "$(get_post_approval_phase standard)" "build" "standard post-approval = build"
assert_eq "$(get_post_approval_phase taskgroup)" "build" "taskgroup post-approval = build"
assert_eq "$(get_post_approval_phase hotfix)" "build" "hotfix post-approval = build"
assert_eq "$(get_post_approval_phase spec-fresh)" "governance" "spec-fresh post-approval = governance"
assert_eq "$(get_post_approval_phase spec-update)" "governance" "spec-update post-approval = governance"
assert_eq "$(get_post_approval_phase taskdef-brief)" "output" "taskdef-brief post-approval = output"

# Types without approval return empty
for stype in taskgroup-merge experiment editor-live prototype-napkin prototype-spike prototype-poc advisory-init advisory-reinit audit taskdef-query ephemeral; do
  result=$(get_post_approval_phase "$stype")
  assert_eq "$result" "" "get_post_approval_phase '$stype' = empty (no approval)"
done

# ============================================================
# L1.7 — get_loops_for_type
# ============================================================
tap_section "L1.7: get_loops_for_type — correct loop sets"

assert_eq "$(get_loops_for_type standard)" "review:build verify:build" "standard loops"
assert_eq "$(get_loops_for_type taskgroup)" "review:build verify:build" "taskgroup loops"
assert_eq "$(get_loops_for_type hotfix)" "verify:build" "hotfix loops"
assert_eq "$(get_loops_for_type taskgroup-merge)" "cohesion:cohesion" "taskgroup-merge loops"
assert_eq "$(get_loops_for_type editor-live)" "commit:build verify:build" "editor-live loops"

# All other types have no loops
for stype in experiment spec-fresh spec-update prototype-napkin prototype-spike prototype-poc advisory-init advisory-reinit audit taskdef-query taskdef-brief ephemeral; do
  result=$(get_loops_for_type "$stype")
  assert_eq "$result" "" "get_loops_for_type '$stype' = empty (no loops)"
done

# ============================================================
# L1.8 — get_phase_index
# ============================================================
tap_section "L1.8: get_phase_index — correct ordinals"

# Standard: init=1, plan=2, ..., close=10 (user-review at index 7)
assert_eq "$(get_phase_index standard init)" "1" "standard init = index 1"
assert_eq "$(get_phase_index standard plan)" "2" "standard plan = index 2"
assert_eq "$(get_phase_index standard approval)" "3" "standard approval = index 3"
assert_eq "$(get_phase_index standard build)" "4" "standard build = index 4"
assert_eq "$(get_phase_index standard review)" "5" "standard review = index 5"
assert_eq "$(get_phase_index standard verify)" "6" "standard verify = index 6"
assert_eq "$(get_phase_index standard user-review)" "7" "standard user-review = index 7"
assert_eq "$(get_phase_index standard commit)" "8" "standard commit = index 8"
assert_eq "$(get_phase_index standard op-review)" "9" "standard op-review = index 9"
assert_eq "$(get_phase_index standard close)" "10" "standard close = index 10"

# Taskgroup: 12 phases (user-review at index 8)
assert_eq "$(get_phase_index taskgroup contract-init)" "2" "taskgroup contract-init = index 2"
assert_eq "$(get_phase_index taskgroup contract-update)" "10" "taskgroup contract-update = index 10"
assert_eq "$(get_phase_index taskgroup close)" "12" "taskgroup close = index 12"

# Editor-live: 7 phases (init, build, commit, review, verify, op-review, close)
assert_eq "$(get_phase_index editor-live init)" "1" "editor-live init = index 1"
assert_eq "$(get_phase_index editor-live build)" "2" "editor-live build = index 2"
assert_eq "$(get_phase_index editor-live commit)" "3" "editor-live commit = index 3"
assert_eq "$(get_phase_index editor-live review)" "4" "editor-live review = index 4"
assert_eq "$(get_phase_index editor-live verify)" "5" "editor-live verify = index 5"
assert_eq "$(get_phase_index editor-live op-review)" "6" "editor-live op-review = index 6"
assert_eq "$(get_phase_index editor-live close)" "7" "editor-live close = index 7"

# Taskgroup-merge: 7 phases (init, contract-init, cohesion, verify, commit, op-review, close)
assert_eq "$(get_phase_index taskgroup-merge contract-init)" "2" "taskgroup-merge contract-init = index 2"
assert_eq "$(get_phase_index taskgroup-merge cohesion)" "3" "taskgroup-merge cohesion = index 3"
assert_eq "$(get_phase_index taskgroup-merge verify)" "4" "taskgroup-merge verify = index 4"
assert_eq "$(get_phase_index taskgroup-merge close)" "7" "taskgroup-merge close = index 7"

# Invalid phase returns 0
assert_eq "$(get_phase_index standard nonexistent)" "0" "invalid phase returns 0"
assert_eq "$(get_phase_index nonexistent init)" "0" "unknown type returns 0"

# Verify all phases in all types get valid (non-zero) indices
for stype in $SESSION_TYPES; do
  phases=$(get_phases_for_type "$stype")
  for phase in $phases; do
    idx=$(get_phase_index "$stype" "$phase")
    if [ "$idx" -gt 0 ]; then
      _tap_pass "get_phase_index '$stype' '$phase' = $idx (non-zero)"
    else
      _tap_fail "get_phase_index '$stype' '$phase'" "expected non-zero, got $idx"
    fi
  done
done

# ============================================================
# L1.9 — Ephemeral phase index
# ============================================================
tap_section "L1.9: Ephemeral — phase index and conversation phase"

assert_eq "$(get_phase_index ephemeral init)" "1" "ephemeral init = index 1"
assert_eq "$(get_phase_index ephemeral conversation)" "2" "ephemeral conversation = index 2"
assert_eq "$(get_phase_index ephemeral close)" "3" "ephemeral close = index 3"

# ============================================================
# L1.10 — upgrade_session_type
# ============================================================
tap_section "L1.10: upgrade_session_type — ephemeral to standard conversion"

# --- Setup ephemeral session ---
init_phase "ephemeral"
stype_before=$(get_session_type)
assert_eq "$stype_before" "ephemeral" "pre-upgrade session type is ephemeral"

phase_before=$(get_phase)
assert_eq "$phase_before" "init" "pre-upgrade phase is init"

# --- Advance to conversation (simulate Q&A session) ---
advance_phase "conversation" 2>/dev/null
phase_mid=$(get_phase)
assert_eq "$phase_mid" "conversation" "ephemeral advances to conversation"

# --- Upgrade ---
upgrade_session_type 2>/dev/null
stype_after=$(get_session_type)
assert_eq "$stype_after" "standard" "post-upgrade session type is standard"

phase_after=$(get_phase)
assert_eq "$phase_after" "plan" "post-upgrade phase is plan"

# --- Upgrade of non-ephemeral fails ---
reset_phase "standard"
upgrade_out=$(upgrade_session_type 2>&1 || true)
case "$upgrade_out" in
  *"not 'ephemeral'"*) _tap_pass "upgrade_session_type rejects non-ephemeral" ;;
  *) _tap_fail "upgrade_session_type rejects non-ephemeral" "expected error, got: $upgrade_out" ;;
esac

# ============================================================
# Summary
# ============================================================
finish_tests