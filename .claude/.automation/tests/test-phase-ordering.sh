#!/usr/bin/env bash
# Adversarial test suite: Phase ordering attacks.
# Tests whether the phase model can be bypassed via forward-jumps,
# direct state file edits, and session type manipulation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/sandbox-setup.sh"

# --- TAP infrastructure ---
# Every case below runs in its own ( ) subshell, so counter VARIABLES cannot
# survive it: each case incremented a fresh copy and the parent's totals stayed
# at zero. The suite therefore always reported "Tests: 0 Pass: 0 Fail: 0" and
# numbered every case "ok 1", whatever actually happened. Tally through a file
# instead, which the subshells share.
_TAP_LOG="$(mktemp "${TMPDIR:-/tmp}/repo-os-tap-XXXXXX")"
trap 'rm -f "$_TAP_LOG"' EXIT
# Remove the tally on any exit, including an abort before finish() runs.
# Unguarded on purpose. An earlier attempt guarded this on BASHPID and broke
# every suite; the cause was NOT subshell trap inheritance (bash does not
# inherit an EXIT trap into a ( ) subshell) but that BASHPID is a bash 4.0+
# variable and these suites run under bash 3.2, so `set -u` made it a fatal
# unbound-variable error before the first case. No guard is needed: the trap
# does not fire in the case subshells, which set their own EXIT trap anyway.
_tap_n() { wc -l < "$_TAP_LOG" | tr -d '[:space:]'; }
_tap_pass() { printf 'P\t%s\n' "$1" >> "$_TAP_LOG"; printf "ok %s - %s\n" "$(_tap_n)" "$1"; return 0; }
_tap_fail() {
  printf 'F\t%s\t%s\n' "$1" "${2:-}" >> "$_TAP_LOG"
  printf "not ok %s - %s\n" "$(_tap_n)" "$1"
  [ -n "${2:-}" ] && printf "  # %s\n" "$2"
  return 0
}
assert_ok() { if [ "$1" -eq 0 ]; then _tap_pass "$2"; else _tap_fail "$2" "expected exit 0, got $1"; fi; }
assert_fail() { if [ "$1" -ne 0 ]; then _tap_pass "$2"; else _tap_fail "$2" "expected non-zero exit, got 0"; fi; }
assert_eq() { if [ "$1" = "$2" ]; then _tap_pass "$3"; else _tap_fail "$3" "expected '$2', got '$1'"; fi; }
finish() {
  local total pass fail
  total=$(_tap_n)
  pass=$(grep -c '^P' "$_TAP_LOG" 2>/dev/null) || pass=0
  fail=$(grep -c '^F' "$_TAP_LOG" 2>/dev/null) || fail=0
  printf "\n1..%s\n# Tests: %s  Pass: %s  Fail: %s\n" "$total" "$total" "$pass" "$fail"
  if [ "$fail" -gt 0 ]; then
    printf "# Failures:\n"
    grep '^F' "$_TAP_LOG" | cut -f2 | sed 's/^/  FAIL: /'
  fi
  rm -f "$_TAP_LOG"
  return "$fail"
}

printf "# === Phase Ordering Attacks ===\n"

# --- Test 1: Forward-jump plan→commit (skipping build, review, verify) ---
(
  setup_adversarial_sandbox
  trap 'teardown_adversarial_sandbox' EXIT
  _setup_at "plan" || exit 0
  # Attempt to jump directly to commit, skipping build/review/verify
  rc=0; advance_phase "commit" 2>/dev/null || rc=$?
  # advance_phase allows any forward jump (new_idx > current_idx)
  # This is a FINDING: phase helper permits arbitrary forward jumps
  if [ "$rc" -eq 0 ]; then
    _tap_fail "[CRITICAL] Forward-jump plan→commit should be blocked" "advance_phase allows arbitrary forward skip"
  else
    _tap_pass "[CRITICAL] Forward-jump plan→commit blocked"
  fi
)

# --- Test 1b: the non-adjacency rule alone, with no substance gate involved ---
# The other forward-jump cases are all ALSO blocked by a substance gate (a
# missing pragmatist-signed, cohesion-reviewed or qa-verified), so disabling
# the ordering check leaves them green and they do not pin that layer.
# init -> plan is the exception: `plan` requires no verdict file, so the only
# thing that can refuse this jump is the non-skippable intermediate
# `drift-check` (Decision 0038). If this case passes while the others also
# pass, the ordering rule is genuinely live.
(
  setup_adversarial_sandbox
  trap 'teardown_adversarial_sandbox' EXIT
  init_phase "standard"
  rc=0; advance_phase "plan" 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    _tap_pass "[HIGH] Non-adjacency rule alone refuses init->plan over drift-check"
  else
    _tap_fail "[HIGH] init->plan skipped the non-skippable drift-check phase" \
      "no substance gate guards this jump, so the ordering rule is not enforcing"
  fi
)

# --- Test 2: Forward-jump review→commit (skipping verify) ---
(
  setup_adversarial_sandbox
  trap 'teardown_adversarial_sandbox' EXIT
  _setup_at "review" || exit 0
  rc=0; advance_phase "commit" 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then
    _tap_fail "[HIGH] Forward-jump review→commit should be blocked" "skips verify phase entirely"
  else
    _tap_pass "[HIGH] Forward-jump review→commit blocked"
  fi
)

# --- Test 3: Backward jump build→plan ---
(
  setup_adversarial_sandbox
  trap 'teardown_adversarial_sandbox' EXIT
  _setup_at "build" || exit 0
  rc=0; advance_phase "plan" 2>/dev/null || rc=$?
  assert_fail "$rc" "[LOW] Backward jump build→plan blocked"
)

# --- Test 4: Direct phase-state edit with correct session_id (residual risk) ---
# With the correct session_id, a direct file write bypasses phase validation.
# Primary defense: bash-guard.sh state-guard blocks agent writes to .state/.
# Full fix would require HMAC on phase-state content (future hardening).
# This test documents the residual risk and verifies state-guard is the defense.
(
  setup_adversarial_sandbox
  trap 'teardown_adversarial_sandbox' EXIT
  init_phase "standard"
  sid=$(cat "$ADV_SANDBOX/.claude/.session-id")
  # Forge phase-state directly (simulating shell I/O bypass of state-guard)
  printf 'session_type: standard\nsession_id: %s\nmode: auto\ncurrent_phase: commit\ncycle: 1\nphases_completed: init,plan,approval,build,review,verify\nsolo: false\ntag: agent\ntimestamp: 2026-03-20T00:00:00Z\n' "$sid" \
    > "$(get_session_state_dir)/phase-state"
  _PS_VALIDATED=false; _CACHED_CURRENT_SID=""
  phase=$(get_phase)
  # With correct session_id, phase-state is accepted (known residual — needs HMAC).
  # Defense: state-guard blocks agent tool writes to .state/ dir.
  # This is a PASS because the defense-in-depth layer (state-guard) is the primary control.
  # Documented residual risk: with the correct session_id there is no content
  # integrity check, so a direct write to the per-session phase-state IS
  # honoured. state-guard blocking agent writes to the state dir is the primary
  # control. Asserted rather than accepted-either-way: this case previously
  # called _tap_pass in both branches and so could never fail. If HMAC or any
  # content check lands, this goes red on purpose — update the comment then.
  assert_eq "$phase" "commit" \
    "[CRITICAL] Direct phase-state edit with correct session_id is honoured (residual; state-guard is the primary defense)"
)

# --- Test 5: Session ID mismatch detection ---
(
  setup_adversarial_sandbox
  trap 'teardown_adversarial_sandbox' EXIT
  init_phase "standard"
  # Write a different session ID into phase-state
  _adv_ps="$(get_session_state_dir)/phase-state"
  sed -i '' 's/^session_id: .*/session_id: FORGED-SID/' "$_adv_ps" 2>/dev/null || \
    sed -i 's/^session_id: .*/session_id: FORGED-SID/' "$_adv_ps"
  _PS_VALIDATED=false; _CACHED_CURRENT_SID=""
  phase=$(get_phase)
  assert_eq "$phase" "" "[MEDIUM] Session ID mismatch returns empty phase"
)

# --- Test 6: Invalid session type ---
(
  setup_adversarial_sandbox
  trap 'teardown_adversarial_sandbox' EXIT
  rc=0; init_phase "evil-type" 2>/dev/null || rc=$?
  assert_fail "$rc" "[LOW] Invalid session type rejected"
)

# --- Test 7: Double init overwrite ---
(
  setup_adversarial_sandbox
  trap 'teardown_adversarial_sandbox' EXIT
  _setup_at "build" || exit 0
  # Second init on a session already in progress. The double-init guard now
  # refuses this outright, so the attack is tested on two axes: the call must
  # be rejected, AND progress must survive it. Previously this case let the
  # re-init run unguarded under `set -e`, which aborted the suite before the
  # assertion — tests 7 through 12 never ran at all.
  rc=0; init_phase "standard" >/dev/null 2>&1 || rc=$?
  _PS_VALIDATED=false; _CACHED_CURRENT_SID=""
  phase=$(get_phase)
  assert_fail "$rc" "[MEDIUM] Double init refused by the double-init guard"
  assert_eq "$phase" "build" "[MEDIUM] Double init does not reset phase progress"
)

# --- Test 8: Phase-state deletion then commit gate ---
(
  setup_adversarial_sandbox
  trap 'teardown_adversarial_sandbox' EXIT
  _setup_at "plan" || exit 0
  # Delete phase-state
  rm -f "$(get_session_state_dir)/phase-state"
  # Stage a file for commit
  mkdir -p "$ADV_SANDBOX/src"
  echo "test" > "$ADV_SANDBOX/src/test.ts"
  (cd "$ADV_SANDBOX" && git add src/test.ts)
  # Run pre-commit-gates
  fixture='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"test\""}}'
  run_adv_hook "pre-commit-gates.sh" "$fixture"
  if [ "$ADV_LAST_RC" -ne 0 ]; then
    _tap_pass "[HIGH] Commit blocked when phase-state deleted (defense-in-depth: state files)"
  else
    _tap_fail "[HIGH] Commit allowed with no phase-state" "missing defense-in-depth"
  fi
)

# --- Test 9: Forward-jump skipping approval (plan→build without plan-approved) ---
(
  setup_adversarial_sandbox
  trap 'teardown_adversarial_sandbox' EXIT
  _setup_at "plan" || exit 0
  # Skip approval phase, jump straight to build
  rc=0; advance_phase "build" 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then
    # Phase helper allowed it — but does pre-commit catch missing plan-approved?
    _tap_fail "[CRITICAL] Forward-jump plan→build allowed (skips approval)" "phase helper permits; defense-in-depth needed"
  else
    _tap_pass "[CRITICAL] Forward-jump plan→build blocked"
  fi
)

# --- Test 10: Non-allowed loop (build→build) ---
(
  setup_adversarial_sandbox
  trap 'teardown_adversarial_sandbox' EXIT
  _setup_at "build" || exit 0
  rc=0; advance_phase "build" 2>/dev/null || rc=$?
  assert_fail "$rc" "[LOW] Non-allowed loop build→build blocked"
)

# --- Test 11: upgrade_session_type from non-ephemeral ---
(
  setup_adversarial_sandbox
  trap 'teardown_adversarial_sandbox' EXIT
  init_phase "standard"
  rc=0; upgrade_session_type 2>/dev/null || rc=$?
  assert_fail "$rc" "[LOW] Upgrade from non-ephemeral rejected"
)

# --- Test 12: Forged phases_completed bypasses checks ---
(
  setup_adversarial_sandbox
  trap 'teardown_adversarial_sandbox' EXIT
  init_phase "standard"
  sid=$(cat "$ADV_SANDBOX/.claude/.session-id")
  # Forge phase-state with all phases "completed" but current_phase at build
  printf 'session_type: standard\nsession_id: %s\nmode: auto\ncurrent_phase: build\ncycle: 1\nphases_completed: init,plan,approval,build,review,verify,user-review,commit\nsolo: false\ntag: agent\ntimestamp: 2026-03-20T00:00:00Z\n' "$sid" \
    > "$(get_session_state_dir)/phase-state"
  _PS_VALIDATED=false; _CACHED_CURRENT_SID=""
  # phases_completed claims everything done, but current_phase says build
  # Does assert_phase("commit") pass? (It checks current_phase index, not phases_completed)
  rc=0; assert_phase "commit" || rc=$?
  if [ "$rc" -eq 0 ]; then
    _tap_fail "[CRITICAL] Forged phases_completed bypasses assert_phase" "phases_completed not validated against current_phase"
  else
    _tap_pass "[CRITICAL] Forged phases_completed does not bypass assert_phase"
  fi
)

finish || true
