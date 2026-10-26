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
  "init drift-check plan approval build review verify user-review commit op-review close" \
  "standard phase sequence"

assert_eq "$(get_phases_for_type taskgroup)" \
  "init contract-init drift-check plan approval build review verify user-review commit contract-update op-review close" \
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

# Standard: 11 phases — init=1, drift-check=2, plan=3, ..., close=11 (Decision 0038)
assert_eq "$(get_phase_index standard init)" "1" "standard init = index 1"
assert_eq "$(get_phase_index standard drift-check)" "2" "standard drift-check = index 2"
assert_eq "$(get_phase_index standard plan)" "3" "standard plan = index 3"
assert_eq "$(get_phase_index standard approval)" "4" "standard approval = index 4"
assert_eq "$(get_phase_index standard build)" "5" "standard build = index 5"
assert_eq "$(get_phase_index standard review)" "6" "standard review = index 6"
assert_eq "$(get_phase_index standard verify)" "7" "standard verify = index 7"
assert_eq "$(get_phase_index standard user-review)" "8" "standard user-review = index 8"
assert_eq "$(get_phase_index standard commit)" "9" "standard commit = index 9"
assert_eq "$(get_phase_index standard op-review)" "10" "standard op-review = index 10"
assert_eq "$(get_phase_index standard close)" "11" "standard close = index 11"

# Taskgroup: 13 phases — drift-check inserted after contract-init (Decision 0038)
assert_eq "$(get_phase_index taskgroup contract-init)" "2" "taskgroup contract-init = index 2"
assert_eq "$(get_phase_index taskgroup drift-check)" "3" "taskgroup drift-check = index 3"
assert_eq "$(get_phase_index taskgroup contract-update)" "11" "taskgroup contract-update = index 11"
assert_eq "$(get_phase_index taskgroup close)" "13" "taskgroup close = index 13"

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
# L1.8 — get_write_phases_for_type returns correct phases
# ============================================================
tap_section "L1.8: get_write_phases_for_type — per-type write-allowed phase lists"

# Standard: build, review, verify, commit
assert_eq "$(get_write_phases_for_type standard)" \
  "build review verify commit" \
  "standard write phases"

# Taskgroup: build, review, verify, commit, contract-update
assert_eq "$(get_write_phases_for_type taskgroup)" \
  "build review verify commit contract-update" \
  "taskgroup write phases"

# Taskgroup-merge: cohesion, verify, commit
assert_eq "$(get_write_phases_for_type taskgroup-merge)" \
  "cohesion verify commit" \
  "taskgroup-merge write phases"

# Hotfix: build, verify, commit
assert_eq "$(get_write_phases_for_type hotfix)" \
  "build verify commit" \
  "hotfix write phases"

# Finish-loop: fix, commit (assess and reassess intentionally excluded)
assert_eq "$(get_write_phases_for_type finish-loop)" \
  "fix commit" \
  "finish-loop write phases (assess/reassess excluded)"

# Experiment: build, commit
assert_eq "$(get_write_phases_for_type experiment)" \
  "build commit" \
  "experiment write phases"

# Spec sessions: write, governance
assert_eq "$(get_write_phases_for_type spec-fresh)" \
  "write governance" \
  "spec-fresh write phases"
assert_eq "$(get_write_phases_for_type spec-update)" \
  "write governance" \
  "spec-update write phases"

# Prototype and editor-live: all phases exempt
assert_eq "$(get_write_phases_for_type prototype-napkin)" "all" "prototype-napkin returns all"
assert_eq "$(get_write_phases_for_type prototype-spike)" "all" "prototype-spike returns all"
assert_eq "$(get_write_phases_for_type prototype-poc)" "all" "prototype-poc returns all"
assert_eq "$(get_write_phases_for_type editor-live)" "all" "editor-live returns all"

# Advisory: governance only
assert_eq "$(get_write_phases_for_type advisory-init)" \
  "governance" \
  "advisory-init write phases"
assert_eq "$(get_write_phases_for_type advisory-reinit)" \
  "governance" \
  "advisory-reinit write phases"

# No-write session types return empty
assert_eq "$(get_write_phases_for_type taskdef-query)" "" "taskdef-query write phases = empty"
assert_eq "$(get_write_phases_for_type taskdef-brief)" "" "taskdef-brief write phases = empty"
assert_eq "$(get_write_phases_for_type queue-triage)" "" "queue-triage write phases = empty"
assert_eq "$(get_write_phases_for_type audit)" "" "audit write phases = empty"
assert_eq "$(get_write_phases_for_type ephemeral)" "" "ephemeral write phases = empty"

# Unknown type returns empty
assert_eq "$(get_write_phases_for_type unknown-type)" "" "unknown-type write phases = empty"

# ============================================================
# L1.R41 — the harness refuses to run against a root outside its sandbox
# ============================================================
# Known-issue R41. A layer whose helpers resolve _REPO_OS_ROOT anywhere but
# its own sandbox operates on that root's REAL session state — reset_phase
# deletes and re-initialises it. The resolution can fail silently (the seam
# rejects a non-/tmp root with only a stderr WARNING), so the harness has to
# check where it actually landed rather than trust that it was told.
#
# Decoys are scratch dirs under /tmp, never the real repo: a probe for
# "touches the wrong root" must not itself be able to touch the real one. Each
# runs in a child bash because the expected outcome is that the harness exits.
#
# Each of the guard's three checks is probed ALONE, with the other two
# satisfied, and asserted by its own message. A probe that trips several checks
# at once stays green when any one of them is deleted — which is what the first
# version of these probes did for the root check.
tap_section "L1.R41: harness refuses a root outside its sandbox"

# Runs a child harness and leaves its exit code / output in _R41_RC/_R41_OUT.
# $1 is the body run after setup_sandbox; $2 is passed through as "$2".
_r41_child() {
  _R41_RC=0
  _R41_OUT=$(bash -c '
    set -euo pipefail
    source "$1/test-helpers.sh"
    setup_sandbox
    eval "$3"
    reset_phase standard
    echo "REACHED-AFTER-RESET"
  ' _ "$SCRIPT_DIR" "${2:-}" "$1" 2>&1) || _R41_RC=$?
}

# A decoy with a writable .claude/.state, so a leak would actually land and the
# "nothing written" assertion can fail. Without it, writes under the decoy fail
# for want of a directory and that assertion passes whatever the guard does.
_r41_decoy() {
  _R41_DECOY=$(mktemp -d /tmp/r41-decoy.XXXXXX) || { echo "Bail out! mktemp failed"; exit 2; }
  mkdir -p "$_R41_DECOY/.claude/.state"
}

# (1) Root check alone: _REPO_OS_ROOT is foreign, but the state-dir cache and
# the main-root cache both point INTO the sandbox, so only the root check can
# fire.
_r41_decoy
_r41_child '_REPO_OS_ROOT="$2"
  _CACHED_SESSION_STATE_DIR="$_SANDBOX_DIR/.claude/.state/wt-sessions/probe"
  _CACHED_MAIN_REPO_ROOT="$_SANDBOX_DIR"' "$_R41_DECOY"
assert_neq "$_R41_RC" "0" "L1.R41 a foreign _REPO_OS_ROOT exits non-zero"
assert_contains "$_R41_OUT" "Bail out! reset_phase: _REPO_OS_ROOT is" \
  "L1.R41 ...refused by the root check itself"
case "$_R41_OUT" in
  *REACHED-AFTER-RESET*) _tap_fail "L1.R41 the suite does not continue past the refusal" "it did" ;;
  *) _tap_pass "L1.R41 the suite does not continue past the refusal" ;;
esac
assert_eq "$(find "$_R41_DECOY" -type f | wc -l | tr -d ' ')" "0" \
  "L1.R41 nothing was written under the foreign root"
rm -rf "$_R41_DECOY"

# (2) State-dir check alone: root right, main root right, but a stale or
# hand-set _CACHED_SESSION_STATE_DIR — which get_session_state_dir returns
# without consulting the root at all.
_r41_decoy
_r41_child '_CACHED_SESSION_STATE_DIR="$2/.claude/.state/wt-sessions/stale"' "$_R41_DECOY"
assert_neq "$_R41_RC" "0" "L1.R41 a state dir cached outside the sandbox exits non-zero"
assert_contains "$_R41_OUT" "Bail out! reset_phase: session state dir is" \
  "L1.R41 ...refused by the state-dir check itself"
rm -rf "$_R41_DECOY"

# (3a) The realistic case: the suite is run from inside a WORKTREE of the real
# repo, as agent and reverify-merge sessions run it. get_main_repo_root decides
# from the CWD's git-common-dir, so before the seam fix it named that real repo
# while _REPO_OS_ROOT and the state dir were the sandbox. It must now resolve
# to the sandbox and the suite must RUN — a refusal here would turn every layer
# red in the normal workflow. The stand-in for the real repo lives in /var/tmp
# because the seam treats anything under /tmp as a test repo.
_R41_REAL=$(mktemp -d /var/tmp/r41-realrepo.XXXXXX) || { echo "Bail out! mktemp failed"; exit 2; }
_R41_WT="$_R41_REAL-wt"
# On `main`, like the real repo: init_phase's ancestry check reads git in the
# CWD (a read, never a write), and a repo with no main ref fails it.
if git -C "$_R41_REAL" init -q 2>/dev/null \
   && git -C "$_R41_REAL" symbolic-ref HEAD refs/heads/main \
   && git -C "$_R41_REAL" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null \
   && git -C "$_R41_REAL" worktree add -q "$_R41_WT" 2>/dev/null; then
  _R41_RC=0
  _R41_OUT=$(cd "$_R41_WT" && bash -c '
    set -euo pipefail
    source "$1/test-helpers.sh"
    setup_sandbox
    reset_phase standard
    [ "$(get_main_repo_root)" = "$_SANDBOX_DIR" ] && echo "MAIN-IS-SANDBOX"
    echo "REACHED-AFTER-RESET"
  ' _ "$SCRIPT_DIR" 2>&1) || _R41_RC=$?
  assert_eq "$_R41_RC" "0" "L1.R41 a suite run from a worktree of a real repo still runs"
  assert_contains "$_R41_OUT" "MAIN-IS-SANDBOX" "L1.R41 ...with the main repo root held in the sandbox"
  assert_eq "$(find "$_R41_REAL" "$_R41_WT" -path '*/.git' -prune -o -path '*/.claude*' -print | wc -l | tr -d ' ')" "0" \
    "L1.R41 ...and nothing written into that real repo or its worktree"
else
  _tap_fail "L1.R41 worktree probe could not be built" "git init/commit/worktree add failed"
fi
rm -rf "$_R41_WT" "$_R41_REAL"

# (3b) Main-root check alone: root and state dir right, but the main root names
# a repo outside /tmp (here via the cache, which get_main_repo_root returns
# as-is) — a real repo, however it got there.
_r41_child '_CACHED_MAIN_REPO_ROOT="/var/tmp/r41-not-a-sandbox"'
assert_neq "$_R41_RC" "0" "L1.R41 a main repo root outside /tmp exits non-zero"
assert_contains "$_R41_OUT" "Bail out! reset_phase: main repo root is" \
  "L1.R41 ...refused by the main-root check itself"

# (4) test-drift-check.sh's own bail-out. It does not use this harness, so a
# regression in its seam check would otherwise go unnoticed. Run a copy,
# rooted in this sandbox, whose sandbox has been moved to /var/tmp — a real
# temp dir the seam rejects, because its rule is a string prefix of /tmp/ or
# /private/tmp/ (so a /tmp path with ../ in it would NOT do). The helpers then
# fall back to the copy's own root, which must be refused. The copy's trap
# removes its /var/tmp dir on exit.
SB="$(get_sandbox)"
_R41_COPY="$SB/r41-drift-copy"
mkdir -p "$_R41_COPY/.claude/hooks/tests/drift-check"
cp "$SCRIPT_DIR"/../*.sh "$_R41_COPY/.claude/hooks/"
cp -R "$SCRIPT_DIR/drift-check/fixtures" "$_R41_COPY/.claude/hooks/tests/drift-check/" 2>/dev/null || true
sed 's#mktemp -d /tmp/drift-check-test#mktemp -d /var/tmp/drift-check-test#' \
  "$SCRIPT_DIR/drift-check/test-drift-check.sh" > "$_R41_COPY/.claude/hooks/tests/drift-check/t.sh"
if grep -q 'mktemp -d /var/tmp/drift-check-test' "$_R41_COPY/.claude/hooks/tests/drift-check/t.sh"; then
  _R41_RC=0
  _R41_OUT=$(bash "$_R41_COPY/.claude/hooks/tests/drift-check/t.sh" 2>/dev/null) || _R41_RC=$?
  assert_eq "$_R41_RC" "2" "L1.R41 test-drift-check.sh exits 2 when its seam is rejected"
  assert_contains "$_R41_OUT" "Bail out! helpers resolved to" \
    "L1.R41 ...with its own bail-out, before any case runs"
else
  _tap_fail "L1.R41 drift-check probe could not rewrite the sandbox path" "sed pattern did not match"
fi

# Positive control: the guard must not fire on a correctly rooted sandbox —
# otherwise every layer would bail and the cases above would pass for the
# wrong reason.
_r41_child ':'
assert_eq "$_R41_RC" "0" "L1.R41 a correctly rooted sandbox passes the guard"
assert_contains "$_R41_OUT" "REACHED-AFTER-RESET" "L1.R41 ...and continues past reset_phase"

# ============================================================
# Summary
# ============================================================
finish_tests
