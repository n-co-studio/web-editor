#!/usr/bin/env bash
# Tests for drift_check + bundle_valid + bundle_expired (Decision 0038).
# Runnable standalone: bash .claude/hooks/tests/drift-check/test-drift-check.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
_fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

# Source helpers
# shellcheck source=../../_analytics-helper.sh
source "$REPO_ROOT/.claude/hooks/_analytics-helper.sh"
# shellcheck source=../../_phase-helper.sh
source "$REPO_ROOT/.claude/hooks/_phase-helper.sh"

# -- bundle_valid tests --

# Missing bundle
bundle_valid "$FIXTURE_DIR/nonexistent.yaml" && _fail "bundle_valid should return non-zero for missing file" || _pass "bundle_valid: missing file returns non-zero"

# Valid structural bundle
bundle_valid "$FIXTURE_DIR/valid-bundle.yaml" && _pass "bundle_valid: structurally valid bundle returns 0" || _fail "bundle_valid: should return 0 for valid bundle"

# -- bundle_expired tests --

# Fresh bundle (year 2099): expect return 1 (fresh)
_bx_status=0
bundle_expired "$FIXTURE_DIR/valid-bundle.yaml" || _bx_status=$?
if [ "$_bx_status" = "1" ]; then
  _pass "bundle_expired: fresh bundle returns 1"
else
  _fail "bundle_expired: fresh bundle should return 1, got $_bx_status"
fi

# Expired bundle (year 2000): expect return 2 (hard-expired)
_bx_status=0
bundle_expired "$FIXTURE_DIR/expired-bundle.yaml" || _bx_status=$?
if [ "$_bx_status" = "2" ]; then
  _pass "bundle_expired: hard-expired bundle returns 2"
else
  _fail "bundle_expired: hard-expired bundle should return 2, got $_bx_status"
fi

# Missing bundle: expect return 2 (cannot evaluate)
_bx_status=0
bundle_expired "$FIXTURE_DIR/nonexistent.yaml" || _bx_status=$?
if [ "$_bx_status" = "2" ]; then
  _pass "bundle_expired: missing bundle returns 2"
else
  _fail "bundle_expired: missing bundle should return 2, got $_bx_status"
fi

# -- drift_check tests --

# Missing bundle → exit 1 (fall through to legacy)
_dc_status=0
drift_check "$FIXTURE_DIR/nonexistent.yaml" >/dev/null 2>&1 || _dc_status=$?
if [ "$_dc_status" = "1" ]; then
  _pass "drift_check: missing bundle returns 1 (fall-through)"
else
  _fail "drift_check: missing bundle should return 1, got $_dc_status"
fi

# Hard-expired bundle → exit 2
_dc_status=0
drift_check "$FIXTURE_DIR/expired-bundle.yaml" >/dev/null 2>&1 || _dc_status=$?
if [ "$_dc_status" = "2" ]; then
  _pass "drift_check: hard-expired bundle returns 2"
else
  _fail "drift_check: hard-expired bundle should return 2, got $_dc_status"
fi

# -- deterministic_alignment_check tests --

# Missing contract → missing-design (return 2)
_da_status=0
result=$(deterministic_alignment_check "any plan" "$FIXTURE_DIR/nonexistent.yaml")
_da_status=$?
if [ "$_da_status" = "2" ] && [ "$result" = "missing-design" ]; then
  _pass "deterministic_alignment_check: missing contract returns missing-design"
else
  _fail "deterministic_alignment_check: missing contract — got status=$_da_status output=$result"
fi

# -- advance_phase forward-jump: drift-check → build (Decision 0038) --
# Verifies the skippable-set extension lets the bundle path advance correctly.
TMP_REPO="$(mktemp -d)"
mkdir -p "$TMP_REPO/.claude/.state"
echo "test-session-fwdjump" > "$TMP_REPO/.claude/.session-id"
(
  export REPO_OS_SESSION_ID="test-session-fwdjump"
  export _REPO_OS_ROOT="$TMP_REPO"
  # Re-source so the helpers re-resolve _REPO_OS_ROOT.
  source "$REPO_ROOT/.claude/hooks/_analytics-helper.sh"
  source "$REPO_ROOT/.claude/hooks/_phase-helper.sh"
  get_session_state_dir() { echo "$TMP_REPO/.claude/.state"; }
  # Seed phase-state at drift-check directly (mirrors what advance_phase would do).
  printf 'session_type: standard\nsession_id: test-session-fwdjump\nmode: review\ncurrent_phase: drift-check\ncycle: 1\nphases_completed: init\nsolo: false\ntag: agent\ntimestamp: 2099-01-01T00:00:00Z\n' \
    > "$TMP_REPO/.claude/.state/phase-state"
  # Seed plan-approved and pragmatist-signed (mirrors what drift_check would write).
  printf 'session_id: test-session-fwdjump\nmode: review\nlarge-scope: true\nquestion_hash: test\n' > "$TMP_REPO/.claude/.state/plan-approved"
  printf 'GATE_RESULT: APPROVED\nsession_id: test-session-fwdjump\n' > "$TMP_REPO/.claude/.state/pragmatist-signed"
  _PS_VALIDATED=false
  _CACHED_CURRENT_SID=""
  # Forward-jump drift-check → build (skipping plan + approval)
  if advance_phase "build" 2>/tmp/adv-err; then
    new_phase=$(grep '^current_phase:' "$TMP_REPO/.claude/.state/phase-state" | sed 's/^current_phase: *//')
    if [ "$new_phase" = "build" ]; then
      echo "__PASS__: advance_phase drift-check→build succeeds and updates phase-state"
    else
      echo "__FAIL__: advance_phase succeeded but phase didn't update — got '$new_phase'"
    fi
  else
    echo "__FAIL__: advance_phase drift-check→build was rejected — $(cat /tmp/adv-err)"
  fi
) > /tmp/fwd-jump-out 2>&1
if grep -q '^__PASS__' /tmp/fwd-jump-out; then
  _pass "advance_phase: drift-check → build forward-jump succeeds"
else
  _fail "advance_phase: drift-check → build forward-jump — $(cat /tmp/fwd-jump-out)"
fi
rm -rf "$TMP_REPO" /tmp/fwd-jump-out /tmp/adv-err

# -- success-path drift_check test (return 0 with state file writes) --

# Use an isolated temp state dir to avoid clobbering the real session.
TMP_STATE_DIR="$(mktemp -d)/state"
mkdir -p "$TMP_STATE_DIR"
_orig_state_dir_fn=$(declare -f get_session_state_dir)
get_session_state_dir() { echo "$TMP_STATE_DIR"; }
# Fresh valid bundle (snapshot is empty so predicate 3 vacuously passes;
# scope_files lists a non-existent path, so predicate 4 finds no commits).
drift_check "$FIXTURE_DIR/valid-bundle.yaml" >/dev/null 2>&1
_dc_status=$?
if [ "$_dc_status" = "0" ] && [ -f "$TMP_STATE_DIR/plan-approved" ] && [ -f "$TMP_STATE_DIR/pragmatist-signed" ]; then
  _pass "drift_check: success path returns 0 and writes plan-approved + pragmatist-signed"
else
  _fail "drift_check: success path — status=$_dc_status, plan-approved=$([ -f "$TMP_STATE_DIR/plan-approved" ] && echo yes || echo no), pragmatist-signed=$([ -f "$TMP_STATE_DIR/pragmatist-signed" ] && echo yes || echo no)"
fi
# Restore the helper
eval "$_orig_state_dir_fn"
rm -rf "$(dirname "$TMP_STATE_DIR")"

# Summary
printf '\n--- Results: %d pass, %d fail ---\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
