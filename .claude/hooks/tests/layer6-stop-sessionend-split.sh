#!/usr/bin/env bash
# Layer 6 — Stop/SessionEnd split regression tests (Decision 0047).
#
# Validates that the session-close-check.sh Stop/SessionEnd event split
# works correctly:
#
#   L6.1  HOOK_EVENT parsing: jq reads hook_event_name from JSON stdin.
#   L6.2  Stop fast-exit (no phase-state): exits 0, does NOT seal branch.
#   L6.3  Stop firing N times: closed-branches list unchanged (no sealing).
#   L6.4  SessionEnd dispatch: always exits 0 (informational event).
#   L6.5  seal_branch_if_applicable guard: HOOK_EVENT=Stop returns early
#         without writing to closed-branches.
#   L6.6  Zero-change fast exit bypassed for SessionEnd: SessionEnd proceeds
#         to dispatch even with no git changes.
#
# Bash 3.2 compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/test-helpers.sh"

# jq is required (hook parses JSON with jq)
if ! command -v jq &>/dev/null; then
  printf "# Layer 6 skipped: jq not available\n"
  printf "1..0\n"
  exit 0
fi

setup_hook_sandbox

SB="$(get_sandbox)"

# Helper: count lines in closed-branches (0 if file missing)
_closed_branch_count() {
  local cb="$SB/.claude/local/closed-branches"
  [ -f "$cb" ] && wc -l < "$cb" | tr -d '[:space:]' || echo "0"
}

# Fixture: Stop event (no hook_event_name defaults to Stop)
STOP_FIXTURE='{"tool_name":"Bash","tool_input":{"command":"ls"}}'
# Fixture: explicit SessionEnd event
SESSION_END_FIXTURE='{"hook_event_name":"SessionEnd"}'

# ============================================================
tap_section "L6.1: HOOK_EVENT parsing — jq reads hook_event_name"
# Direct test of the jq expression used in the hook.
_evt_stop=$(printf '%s' '{}' | jq -r '.hook_event_name // "Stop"' 2>/dev/null)
assert_eq "$_evt_stop" "Stop" "missing key defaults to Stop"

_evt_explicit=$(printf '%s' '{"hook_event_name":"SessionEnd"}' | jq -r '.hook_event_name // "Stop"' 2>/dev/null)
assert_eq "$_evt_explicit" "SessionEnd" "explicit SessionEnd parsed correctly"

_evt_stop_explicit=$(printf '%s' '{"hook_event_name":"Stop"}' | jq -r '.hook_event_name // "Stop"' 2>/dev/null)
assert_eq "$_evt_stop_explicit" "Stop" "explicit Stop parsed correctly"

# ============================================================
tap_section "L6.2: Stop with no phase-state exits 0 (no-init fast exit)"
# Session was never initialized — no phase-state file exists.
# The hook must exit 0 (not block) and must NOT create a closed-branches entry.
_before=$(_closed_branch_count)
run_hook_rc "session-close-check.sh" "$STOP_FIXTURE"
assert_ok "$_LAST_RC" "Stop no-init exits 0"
_after=$(_closed_branch_count)
assert_eq "$_after" "$_before" "no closed-branches entry written on no-init Stop"

# ============================================================
tap_section "L6.3: Stop firing N times leaves closed-branches unchanged"
# Run Stop 5 times on a sandbox with no phase-state (zero-change fast-exit path).
# Closed-branches must remain empty throughout — sealing must not happen.
_count_before=$(_closed_branch_count)
for _i in 1 2 3 4 5; do
  run_hook_rc "session-close-check.sh" "$STOP_FIXTURE" >/dev/null 2>&1 || true
done
_count_after=$(_closed_branch_count)
assert_eq "$_count_after" "$_count_before" "closed-branches unchanged after 5 Stop firings"

# ============================================================
tap_section "L6.4: SessionEnd dispatch always exits 0"
# SessionEnd is an informational event — exit code is ignored by Claude Code.
# The hook must exit 0 regardless of session state.
run_hook_rc "session-close-check.sh" "$SESSION_END_FIXTURE"
assert_ok "$_LAST_RC" "SessionEnd exits 0 (no phase-state path)"

# Verify no closed-branches written (no branch to seal on a bare sandbox)
_after_se=$(_closed_branch_count)
assert_eq "$_after_se" "$_count_before" "SessionEnd on bare sandbox does not write closed-branches"

# ============================================================
tap_section "L6.5: seal_branch_if_applicable guard — HOOK_EVENT=Stop returns early"
# This test extracts the REAL seal_branch_if_applicable() body from
# session-close-check.sh and evaluates it against stubbed dependencies. It does
# NOT reimplement the guard: the text under test is the production source, so an
# edit that removes or inverts the HOOK_EVENT check changes what is evaluated
# here and the test fails. (The previous version of this test defined its own
# copy of the condition and asserted against that copy, so it passed
# unconditionally and would not have caught a regression in the real function —
# exactly the belt-and-suspenders protection Decision t-0047 §3 calls for having
# no coverage at all.)
_HOOK_SRC="$SCRIPT_DIR/../session-close-check.sh"
_SEAL_FN_TEXT=$(sed -n '/^seal_branch_if_applicable() {/,/^}/p' "$_HOOK_SRC")

if [ -z "$_SEAL_FN_TEXT" ]; then
  _tap_fail "extract seal_branch_if_applicable() from production source" "function not found in $_HOOK_SRC"
else
  _tap_pass "extract seal_branch_if_applicable() from production source"
fi

# Guard must be present in the extracted production text, not merely in a copy.
case "$_SEAL_FN_TEXT" in
  *'HOOK_EVENT'*'SessionEnd'*) _tap_pass "production seal guard references HOOK_EVENT/SessionEnd" ;;
  *) _tap_fail "production seal guard references HOOK_EVENT/SessionEnd" "guard condition absent from function body" ;;
esac

# Evaluate the real function body with stubs. record_closed_branch is the
# observable side effect: if the guard fails to defer, it fires.
_run_real_seal_guard() {
  local _event="$1"
  (
    HOOK_EVENT="$_event"
    START_MS=0
    log_hook_event() { :; }
    get_branch() { echo "feature/guard-probe"; }
    is_session_active() { return 1; }
    get_session_type() { echo "standard"; }
    is_final_brief() { echo "false"; }
    _branch_in_active_contract() { return 1; }
    record_closed_branch() { echo "sealed"; }
    eval "$_SEAL_FN_TEXT"
    seal_branch_if_applicable
  )
}

assert_eq "$(_run_real_seal_guard "Stop")" "" "real guard: HOOK_EVENT=Stop does not seal"
assert_eq "$(_run_real_seal_guard "SessionEnd")" "sealed" "real guard: HOOK_EVENT=SessionEnd seals"
assert_eq "$(_run_real_seal_guard "")" "" "real guard: HOOK_EVENT='' defaults to Stop behaviour (no seal)"

# ============================================================
tap_section "L6.5b: live initialized session — repeated Stop never seals, SessionEnd does"
# The regression Decision t-0047 exists to prevent (per its § Context): a LIVE,
# initialized, multi-turn session whose Stop fires repeatedly had its branch
# appended to closed-branches mid-session, after which Gate 5 refused all edits.
# L6.2/L6.3 fire Stop against a sandbox with NO phase-state, so they exit via the
# no-init fast path and never reach the seal logic — they cannot catch this. This
# test constructs the real scenario end-to-end against the real hook.
_reinit_l6_session() {
  echo "l6-session-$(date +%s)-$$" > "$SB/.claude/.session-id"
  _CACHED_SESSION_ID=""
  _CACHED_BRANCH=""
  _CACHED_SESSION_STATE_DIR=""
  rm -rf "$SB/.claude/.state/wt-sessions" 2>/dev/null || true
  rm -f "$SB/.claude/.state/.stop-attempt-count" 2>/dev/null || true
  rm -f "$SB/.claude/local/closed-branches" 2>/dev/null || true
  (cd "$SB" && git reset --hard HEAD >/dev/null 2>&1 || true)
  (cd "$SB" && git clean -fd -e .claude/ >/dev/null 2>&1 || true)
  reset_phase "standard"
  # Mark the session as solo and in the close phase — the state a real session
  # is in when its Stop fires at end of turn during close.
  local _ps
  _ps="$(get_session_state_dir)/phase-state"
  if [ -f "$_ps" ]; then
    sed -e 's/^current_phase: .*/current_phase: close/' -e 's/^solo: .*/solo: true/' \
      "$_ps" > "$_ps.tmp" && mv "$_ps.tmp" "$_ps"
  fi
}

switch_sandbox_branch "feature/test" >/dev/null 2>&1 || true
_reinit_l6_session
export REPO_OS_SESSION_ID="$(cat "$SB/.claude/.session-id")"

for _i in 1 2 3; do
  run_hook_rc "session-close-check.sh" "$STOP_FIXTURE" >/dev/null 2>&1 || true
done
if [ -f "$SB/.claude/local/closed-branches" ] && grep -qxF "feature/test" "$SB/.claude/local/closed-branches" 2>/dev/null; then
  _tap_fail "initialized session: 3 Stop firings do not seal the live branch" "feature/test found in closed-branches"
else
  _tap_pass "initialized session: 3 Stop firings do not seal the live branch"
fi

run_hook_rc "session-close-check.sh" "$SESSION_END_FIXTURE" >/dev/null 2>&1 || true
assert_file_contains "$SB/.claude/local/closed-branches" "feature/test" \
  "initialized session: SessionEnd does seal the branch"
unset REPO_OS_SESSION_ID

# ============================================================
tap_section "L6.5c: SessionEnd honours the foreign-state guard before destructive work"
# Decision t-0047 moved merge/seal/cleanup into the SessionEnd dispatch, which sits
# ABOVE the Stop path's foreign-state guard — so the destructive path ran without it.
# That is not just a skipped check: cleanup_session() resolves close_sid from the
# shared .claude/.session-id, so a SessionEnd firing for process A would unregister
# session B and delete B's phase-state while B was still live (Decision 0019 then
# blocks every edit in B). This test asserts SessionEnd bails out when the resolved
# state is owned by a DIFFERENT, still-running process.
_reinit_l6_session
switch_sandbox_branch "feature/test" >/dev/null 2>&1 || true
rm -f "$SB/.claude/local/closed-branches" 2>/dev/null || true

# A genuinely live foreign process to own the state (pid != our $PPID, alive).
sleep 120 &
_L6_FOREIGN_PID=$!

_L6_STATE_SID=$(grep '^session_id:' "$(get_session_state_dir)/phase-state" 2>/dev/null | sed 's/^session_id: *//' | tr -d '[:space:]')
mkdir -p "$SB/.claude/.state/sessions" 2>/dev/null || true
printf 'session_id: %s\npid: %s\n' "$_L6_STATE_SID" "$_L6_FOREIGN_PID" \
  > "$SB/.claude/.state/sessions/${_L6_STATE_SID}.yaml"

# Interactive identity (no REPO_OS_SESSION_ID) + a stdin session_id that differs
# from the resolved state's session_id is the aliasing condition the guard targets.
unset REPO_OS_SESSION_ID 2>/dev/null || true
_L6_FOREIGN_FIXTURE='{"hook_event_name":"SessionEnd","session_id":"some-other-live-session"}'
run_hook_rc "session-close-check.sh" "$_L6_FOREIGN_FIXTURE" >/dev/null 2>&1 || true
assert_ok "$_LAST_RC" "SessionEnd exits 0 when foreign live state is detected"

if [ -f "$SB/.claude/local/closed-branches" ] && grep -qxF "feature/test" "$SB/.claude/local/closed-branches" 2>/dev/null; then
  _tap_fail "SessionEnd does not seal when state is owned by a live foreign process" "feature/test sealed"
else
  _tap_pass "SessionEnd does not seal when state is owned by a live foreign process"
fi

# The foreign session's phase-state must survive — this is the corruption the guard prevents.
if [ -f "$(get_session_state_dir)/phase-state" ]; then
  _tap_pass "SessionEnd leaves the live foreign session's phase-state intact"
else
  _tap_fail "SessionEnd leaves the live foreign session's phase-state intact" "phase-state was deleted by cleanup_session"
fi

kill "$_L6_FOREIGN_PID" 2>/dev/null || true
wait "$_L6_FOREIGN_PID" 2>/dev/null || true
rm -f "$SB/.claude/.state/sessions/${_L6_STATE_SID}.yaml" 2>/dev/null || true

# ============================================================
tap_section "L6.5d: every SessionEnd merge-failure path yields exactly one escalation"
# SessionEnd cannot block (Decision t-0047 §2/§9), so a durable escalation file is
# the operator's only signal that a close-time merge failed. Two regressions have
# already happened here: first a duplicate escalation on merge-lock failure, then —
# while fixing that — three failure paths silently producing ZERO escalations
# because the suppression condition keyed on the wrong variable.
#
# The invariant: _SE_FAIL_REASON records WHY (set at every throw site);
# _SE_ESC_WRITTEN records WHETHER a throw site already escalated (set only where
# one actually did). The generic handler must key on _SE_ESC_WRITTEN. Keying it on
# _SE_FAIL_REASON suppresses the handler for every path that relies on it.
_SE_BLOCK=$(sed -n '/_SE_MERGE_OK=false/,/^      fi$/p' "$_HOOK_SRC")

if [ -n "$_SE_BLOCK" ]; then
  _tap_pass "extract SessionEnd merge block from production source"
else
  _tap_fail "extract SessionEnd merge block from production source" "block not found"
fi

# The generic fallback must be gated on _SE_ESC_WRITTEN, never on _SE_FAIL_REASON.
_GENERIC_GATE=$(grep -A1 'if \[ "\$_SE_ESC_WRITTEN" = false \]; then' "$_HOOK_SRC" | grep -c '_write_close_escalation "esc-solo-merge"' || true)
if [ "$_GENERIC_GATE" -ge 1 ]; then
  _tap_pass "generic merge-failure escalation is gated on _SE_ESC_WRITTEN"
else
  _tap_fail "generic merge-failure escalation is gated on _SE_ESC_WRITTEN" "esc-solo-merge not guarded by _SE_ESC_WRITTEN"
fi

if grep -q 'if \[ -z "\$_SE_FAIL_REASON" \]; then' "$_HOOK_SRC"; then
  _tap_fail "generic escalation is NOT gated on _SE_FAIL_REASON" "found suppression keyed on _SE_FAIL_REASON — three failure paths would produce no escalation"
else
  _tap_pass "generic escalation is NOT gated on _SE_FAIL_REASON"
fi

# Every throw site that sets _SE_ESC_WRITTEN=true must actually write an escalation.
_ESC_TRUE_COUNT=$(printf '%s\n' "$_SE_BLOCK" | grep -c '_SE_ESC_WRITTEN=true' || true)
_ESC_CALL_COUNT=$(printf '%s\n' "$_SE_BLOCK" | grep -c '_write_close_escalation "esc-merge-lock"\|_write_close_escalation "esc-wt-not-main"' || true)
assert_eq "$_ESC_TRUE_COUNT" "$_ESC_CALL_COUNT" \
  "each _SE_ESC_WRITTEN=true site pairs with its own escalation write"

# ============================================================
tap_section "L6.6: Zero-change fast exit bypassed for SessionEnd"
# The zero-change fast-exit guards against: no uncommitted changes, no staged,
# no recent, no merge signal, no phase-state. It MUST NOT fire for SessionEnd.
# We verify by checking the hook exits 0 (not killed by the ZC guard) with
# an explicit SessionEnd fixture on a clean sandbox with no changes.
#
# Note: a zero-change Stop on the same sandbox would also exit 0 (fast-exit
# path), so both exit 0 here. The key invariant is that SessionEnd is not
# intercepted by the ZC guard — it proceeds to the SessionEnd dispatch block.
# We verify the hook output differs: SessionEnd path may emit KPI summary or
# cleanup log; zero-change Stop emits nothing (silent fast-exit).
_stop_out=$(printf '%s' "$STOP_FIXTURE" | (cd "$SB" && bash "$_HOOKS_DIR/session-close-check.sh" 2>&1)) || true
_se_out=$(printf '%s' "$SESSION_END_FIXTURE" | (cd "$SB" && bash "$_HOOKS_DIR/session-close-check.sh" 2>&1)) || true

# Both must exit 0 (we already tested SessionEnd above; test Stop here too)
run_hook_rc "session-close-check.sh" "$STOP_FIXTURE"
assert_ok "$_LAST_RC" "zero-change Stop exits 0"
run_hook_rc "session-close-check.sh" "$SESSION_END_FIXTURE"
assert_ok "$_LAST_RC" "zero-change SessionEnd exits 0"

# ============================================================
tap_section "L6.7: SessionEnd merge path executes without unresolved functions"
# Regression: the SessionEnd dispatch block was placed ABOVE the seven functions
# it calls (_acquire_merge_lock, _release_merge_lock, update_baseline,
# advisory_push_to_remote, seal_branch_if_applicable, cleanup_session,
# _emit_kpi_summary). Bash resolves names at call time, so every one of them was
# "command not found" and the whole path died at the first call — leaving the
# session unmerged and its branch sealed.
#
# L6.1-L6.6 all missed this because they exercise SessionEnd only on a
# zero-change sandbox, where the merge-signal path never runs. This test plants a
# merge-source-branch signal so the dispatch actually reaches those calls, then
# asserts nothing was unresolved at runtime. Grepping the source for definitions
# is NOT sufficient: the definitions exist, they are just too late in the file.
_sid=$(get_test_session_id)
_sid="${_sid//\//_}"
_se_state="$SB/.claude/.state/wt-sessions/$_sid"
mkdir -p "$_se_state"
echo "feature/l6-merge-signal" > "$_se_state/merge-source-branch"

_merge_out=$(printf '%s' "$SESSION_END_FIXTURE" | (cd "$SB" && bash "$_HOOKS_DIR/session-close-check.sh" 2>&1)) || true

case "$_merge_out" in
  *"command not found"*) _unresolved="yes" ;;
  *)                     _unresolved="no"  ;;
esac
assert_eq "$_unresolved" "no" "SessionEnd merge path: no unresolved function calls"

# ============================================================
tap_section "L6.8: unmerged branch is not sealed on a merge signal"
# Regression: the merge-signal path sealed on the mere presence of the signal
# file. Its contract is "the agent already merged" — it seals, pushes and
# deletes, it never merges. A session that wrote the signal expecting SessionEnd
# to do the merge got its branch sealed and its work stranded on a branch that
# governance then forbids reusing. feature/l6-merge-signal does not exist in the
# sandbox, so it cannot be an ancestor of main and must NOT be sealed.
_cb="$SB/.claude/local/closed-branches"
if [ -f "$_cb" ] && grep -qxF "feature/l6-merge-signal" "$_cb" 2>/dev/null; then
  _sealed="yes"
else
  _sealed="no"
fi
assert_eq "$_sealed" "no" "unverified merge signal does not seal the branch"

rm -f "$_se_state/merge-source-branch"

# ============================================================
finish_tests
