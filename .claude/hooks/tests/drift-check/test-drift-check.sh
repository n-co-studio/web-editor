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

# Root every helper in a sandbox BEFORE sourcing (known-issue R41). This file
# used to source the helpers bare, so _REPO_OS_ROOT was the real repo and the
# drift_check fall-through cases below appended to the LIVE session's
# overrides.log (observed 2026-10-25). /tmp, not mktemp's default: macOS
# TMPDIR is /var/folders/..., which the seam rejects and silently replaces with
# the real root. A failed mktemp must stop here — with SANDBOX empty, the lines
# below would write under /.claude.
SANDBOX="$(mktemp -d /tmp/drift-check-test.XXXXXX)" || { echo "Bail out! cannot create a sandbox under /tmp"; exit 2; }
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/.claude/.state"
git init -q "$SANDBOX" 2>/dev/null || true
echo "drift-check-test-$$" > "$SANDBOX/.claude/.session-id"
export REPO_OS_TEST_MODE=1
export _REPO_OS_TEST_ROOT="$SANDBOX"
export REPO_OS_SESSION_ID="drift-check-test-$$"

# Source helpers
# shellcheck source=../../_analytics-helper.sh
source "$REPO_ROOT/.claude/hooks/_analytics-helper.sh"
# shellcheck source=../../_phase-helper.sh
source "$REPO_ROOT/.claude/hooks/_phase-helper.sh"

# Refuse to continue if the seam did not take: every case below would then run
# against the real repository's session state.
case "$_REPO_OS_ROOT:$(get_session_state_dir)" in
  "$SANDBOX:$SANDBOX"/*) ;;
  *)
    printf 'Bail out! helpers resolved to %s (state %s), not the sandbox %s (R41)\n' \
      "$_REPO_OS_ROOT" "$(get_session_state_dir)" "$SANDBOX"
    exit 2
    ;;
esac
# The main root is CWD-based, so it gets the seam's prefix rule: outside /tmp
# it is a real repo, and handoff-bundle paths route through it.
case "$(get_main_repo_root)" in
  /tmp/*|/private/tmp/*) ;;
  *)
    printf 'Bail out! main repo root is %s, outside /tmp — a real repo (R41)\n' "$(get_main_repo_root)"
    exit 2
    ;;
esac

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
# The repo is a subdirectory of the sandbox so it passes the seam's /private/tmp
# prefix rule. The root is redirected through _REPO_OS_TEST_ROOT, never by
# assigning _REPO_OS_ROOT: re-sourcing the helper recomputes _REPO_OS_ROOT, so
# an assignment made before it is silently discarded — which is how this case
# used to write the real repo's cross-session-context on every run (R41).
TMP_REPO="$SANDBOX/fwdjump-repo"
FWD_SID="test-session-fwdjump-$$"
mkdir -p "$TMP_REPO/.claude/.state"
echo "$FWD_SID" > "$TMP_REPO/.claude/.session-id"
(
  export REPO_OS_SESSION_ID="$FWD_SID"
  export _REPO_OS_TEST_ROOT="$TMP_REPO"
  # Re-source so the helpers re-resolve _REPO_OS_ROOT.
  source "$REPO_ROOT/.claude/hooks/_analytics-helper.sh"
  source "$REPO_ROOT/.claude/hooks/_phase-helper.sh"
  get_session_state_dir() { echo "$TMP_REPO/.claude/.state"; }
  # Seed phase-state at drift-check directly (mirrors what advance_phase would do).
  printf 'session_type: standard\nsession_id: %s\nmode: review\ncurrent_phase: drift-check\ncycle: 1\nphases_completed: init\nsolo: false\ntag: agent\ntimestamp: 2099-01-01T00:00:00Z\n' "$FWD_SID" \
    > "$TMP_REPO/.claude/.state/phase-state"
  # Seed plan-approved and pragmatist-signed (mirrors what drift_check would write).
  printf 'session_id: %s\nmode: review\nlarge-scope: true\nquestion_hash: test\n' "$FWD_SID" > "$TMP_REPO/.claude/.state/plan-approved"
  printf 'GATE_RESULT: APPROVED\nsession_id: %s\n' "$FWD_SID" > "$TMP_REPO/.claude/.state/pragmatist-signed"
  _PS_VALIDATED=false
  _CACHED_CURRENT_SID=""
  if [ "$_REPO_OS_ROOT" != "$TMP_REPO" ]; then
    echo "__FAIL__: helpers resolved to $_REPO_OS_ROOT, not $TMP_REPO — refusing to advance a real session (R41)"
    exit 0
  fi
  # Forward-jump drift-check → build (skipping plan + approval)
  if advance_phase "build" 2>"$SANDBOX/adv-err"; then
    new_phase=$(grep '^current_phase:' "$TMP_REPO/.claude/.state/phase-state" | sed 's/^current_phase: *//')
    if [ "$new_phase" = "build" ]; then
      echo "__PASS__: advance_phase drift-check→build succeeds and updates phase-state"
    else
      echo "__FAIL__: advance_phase succeeded but phase didn't update — got '$new_phase'"
    fi
  else
    echo "__FAIL__: advance_phase drift-check→build was rejected — $(cat "$SANDBOX/adv-err")"
  fi
) > "$SANDBOX/fwd-jump-out" 2>&1
if grep -q '^__PASS__' "$SANDBOX/fwd-jump-out"; then
  _pass "advance_phase: drift-check → build forward-jump succeeds"
else
  _fail "advance_phase: drift-check → build forward-jump — $(cat "$SANDBOX/fwd-jump-out")"
fi
rm -rf "$TMP_REPO" "$SANDBOX/fwd-jump-out" "$SANDBOX/adv-err"

# -- success-path drift_check test (return 0 with state file writes) --

# Use an isolated temp state dir to avoid clobbering the real session.
TMP_STATE_DIR="$SANDBOX/success-path/state"
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
