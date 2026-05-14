#!/usr/bin/env bash
# Layer 1d — phase-state.gates cache tests (Decision 0042).
# Unit tests for compute_phase_gates and read_phase_gates in _phase-helper.sh.
#
# Bash 3.2 compatible. No external dependencies.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/test-helpers.sh"

setup_sandbox

SB="$(get_sandbox)"
SID="$(get_test_session_id)"

# Tests call helpers directly (not via hooks). get_branch() reads from CWD's
# git, which is the real repo — set _CACHED_BRANCH so functions see the
# expected value.
TEST_BRANCH="feature/test-gates"
_CACHED_BRANCH="$TEST_BRANCH"

# Init phase so phase-state exists (compute_phase_gates depends on get_phase
# being non-empty for GATES_CURRENT_PHASE).
init_phase "standard"
STATE_DIR="$(get_session_state_dir)"
GATES_FILE="$STATE_DIR/phase-state.gates"

tap_section "L1d.1: compute_phase_gates writes the cache file"

assert_file_exists "$GATES_FILE" "init_phase calls compute_phase_gates and writes phase-state.gates"

tap_section "L1d.2: cache file contains all expected fields"

assert_file_contains "$GATES_FILE" "^GATES_SESSION_ID=" "cache contains GATES_SESSION_ID"
assert_file_contains "$GATES_FILE" "^GATES_COMPUTED_AT=" "cache contains GATES_COMPUTED_AT"
assert_file_contains "$GATES_FILE" "^GATES_CURRENT_PHASE=" "cache contains GATES_CURRENT_PHASE"
assert_file_contains "$GATES_FILE" "^GATES_SESSION_TYPE=" "cache contains GATES_SESSION_TYPE"
assert_file_contains "$GATES_FILE" "^GATES_CURRENT_BRANCH=" "cache contains GATES_CURRENT_BRANCH"
assert_file_contains "$GATES_FILE" "^GATES_CLOSED_BRANCHES_MTIME=" "cache contains GATES_CLOSED_BRANCHES_MTIME"
assert_file_contains "$GATES_FILE" "^GATES_SESSION_OVERLAP=" "cache contains GATES_SESSION_OVERLAP"
assert_file_contains "$GATES_FILE" "^GATES_BRANCH_ISOLATION=" "cache contains GATES_BRANCH_ISOLATION"

tap_section "L1d.3: read_phase_gates returns 0 on a fresh cache"

rc=0
read_phase_gates 2>/dev/null || rc=$?
assert_ok "$rc" "read_phase_gates returns 0 on fresh cache"
assert_eq "$GATES_SESSION_ID" "$SID" "GATES_SESSION_ID exposed to caller"
assert_eq "$GATES_CURRENT_BRANCH" "$TEST_BRANCH" "GATES_CURRENT_BRANCH exposed to caller"
assert_eq "$GATES_SESSION_OVERLAP" "ok" "GATES_SESSION_OVERLAP=ok with no overlap"
assert_eq "$GATES_BRANCH_ISOLATION" "ok" "GATES_BRANCH_ISOLATION=ok when not in closed-branches"

tap_section "L1d.4: read_phase_gates returns 1 on session_id mismatch"

# Override session id without rewriting the cache file.
REPO_OS_SESSION_ID="other-sid-not-cached"
rc=0
read_phase_gates 2>/dev/null || rc=$?
unset REPO_OS_SESSION_ID
if [ "$rc" -ne 0 ]; then
  _tap_pass "read_phase_gates returns non-zero on session_id mismatch"
else
  _tap_fail "read_phase_gates returns non-zero on session_id mismatch" "got rc=0"
fi

tap_section "L1d.5: read_phase_gates returns 1 on branch mismatch (mid-phase checkout)"

# Override get_branch to simulate a checkout to a different branch.
get_branch() { echo "different-branch"; }
rc=0
read_phase_gates 2>/dev/null || rc=$?
if [ "$rc" -ne 0 ]; then
  _tap_pass "read_phase_gates returns non-zero on branch mismatch"
else
  _tap_fail "read_phase_gates returns non-zero on branch mismatch" "got rc=0"
fi
# Restore (re-source the helper to recover the original)
unset -f get_branch
real_hooks_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$real_hooks_dir/_analytics-helper.sh"
_CACHED_BRANCH="$TEST_BRANCH"

tap_section "L1d.6: read_phase_gates returns 1 on closed-branches mtime change"

# Recompute baseline cache (overwrite with current mtime, which is empty since
# no closed-branches file exists in the sandbox yet).
compute_phase_gates
rc=0
read_phase_gates 2>/dev/null || rc=$?
assert_ok "$rc" "baseline cache valid before mtime change"

# Materialise the closed-branches file — its mtime is now non-empty, but the
# cache was computed when it was absent (mtime field is empty). The mismatch
# must invalidate the cache.
mkdir -p "$SB/.claude/local"
echo "feature/sealed" > "$SB/.claude/local/closed-branches"
rc=0
read_phase_gates 2>/dev/null || rc=$?
if [ "$rc" -ne 0 ]; then
  _tap_pass "read_phase_gates returns non-zero after closed-branches changes"
else
  _tap_fail "read_phase_gates returns non-zero after closed-branches changes" "got rc=0"
fi

tap_section "L1d.7: closed-branches match makes branch_isolation=blocked on next compute"

# Add the test branch to the sealed list and recompute.
echo "$TEST_BRANCH" >> "$SB/.claude/local/closed-branches"
compute_phase_gates
rc=0
read_phase_gates 2>/dev/null || rc=$?
assert_ok "$rc" "cache valid after recompute"
assert_eq "$GATES_BRANCH_ISOLATION" "blocked" "branch_isolation=blocked when branch is in closed-branches"

tap_section "L1d.8: read_phase_gates returns 1 when cache file is absent"

rm -f "$GATES_FILE"
rc=0
read_phase_gates 2>/dev/null || rc=$?
if [ "$rc" -ne 0 ]; then
  _tap_pass "read_phase_gates returns non-zero when cache absent"
else
  _tap_fail "read_phase_gates returns non-zero when cache absent" "got rc=0"
fi

tap_section "L1d.9: _delete_if_owned recognises GATES_SESSION_ID format"

# Build a fake gates file owned by another session and verify the helper
# refuses to delete it. Production callers run without set -e/pipefail; the
# test harness uses set -euo pipefail, so wrap calls with `|| true` to ignore
# the grep-no-match exit status that pipefail would otherwise propagate.
real_hooks_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$real_hooks_dir/_cleanup-helper.sh"
fake_gates="$STATE_DIR/phase-state.gates.fake-owner-test"
{
  printf "GATES_SESSION_ID='owned-by-someone-else'\n"
  printf "GATES_CURRENT_PHASE='build'\n"
} > "$fake_gates"
_delete_if_owned "$fake_gates" "$SID" || true
if [ -f "$fake_gates" ]; then
  _tap_pass "_delete_if_owned skips file owned by another session (GATES format)"
  rm -f "$fake_gates"
else
  _tap_fail "_delete_if_owned skips file owned by another session (GATES format)" "file was deleted"
fi

# Same file owned by the current session should be deleted.
{
  printf "GATES_SESSION_ID='%s'\n" "$SID"
  printf "GATES_CURRENT_PHASE='build'\n"
} > "$fake_gates"
_delete_if_owned "$fake_gates" "$SID" || true
if [ ! -f "$fake_gates" ]; then
  _tap_pass "_delete_if_owned deletes file owned by current session (GATES format)"
else
  _tap_fail "_delete_if_owned deletes file owned by current session (GATES format)" "file remained"
  rm -f "$fake_gates"
fi

tap_section "L1d.10: advance_phase recomputes cache (timestamp advances)"

# Recreate baseline cache.
compute_phase_gates
read_phase_gates 2>/dev/null
ts_before="$GATES_COMPUTED_AT"

# Sleep 1s to force a different timestamp, then advance.
sleep 1
advance_phase "drift-check" 2>/dev/null
read_phase_gates 2>/dev/null
ts_after="$GATES_COMPUTED_AT"

if [ "$ts_before" != "$ts_after" ]; then
  _tap_pass "advance_phase recomputes cache (timestamp changed)"
else
  _tap_fail "advance_phase recomputes cache" "timestamp unchanged: $ts_before"
fi
assert_eq "$GATES_CURRENT_PHASE" "drift-check" "GATES_CURRENT_PHASE reflects post-advance phase"

# ============================================================
# Summary
# ============================================================
finish_tests
