#!/usr/bin/env bash
# Layer 1b — Session registry function tests.
# Unit tests for register_session, unregister_session, check_session_overlap,
# and _iso_to_epoch in _analytics-helper.sh.
#
# Bash 3.2 compatible. No external dependencies.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/test-helpers.sh"

setup_sandbox

SB="$(get_sandbox)"
SID="$(get_test_session_id)"
SESSIONS_DIR="$SB/.claude/.state/sessions"

# Tests call registry functions directly (not via hooks). get_branch() uses
# CWD's git, which is the real repo — not the sandbox. Set _CACHED_BRANCH
# to the desired test branch so functions see the right value.
TEST_BRANCH="feature/test-reg"
_CACHED_BRANCH="$TEST_BRANCH"

tap_section "L1b.1: register_session creates session YAML file"

register_session "standard"
assert_file_exists "$SESSIONS_DIR/${SID}.yaml" "register_session creates session file"
assert_file_contains "$SESSIONS_DIR/${SID}.yaml" "session_id: $SID" "session file contains session_id"
assert_file_contains "$SESSIONS_DIR/${SID}.yaml" "session_type: standard" "session file contains session_type"
assert_file_contains "$SESSIONS_DIR/${SID}.yaml" "branch: $TEST_BRANCH" "session file contains branch"
assert_file_contains "$SESSIONS_DIR/${SID}.yaml" "^pid: " "session file contains pid"
assert_file_contains "$SESSIONS_DIR/${SID}.yaml" "^started_at: " "session file contains started_at"

tap_section "L1b.2: register_session warns on same-branch overlap"

# Create a fake overlapping session on the same branch
create_fake_session "other-session-1" "standard" "$TEST_BRANCH" "$$"

# Re-register to trigger overlap advisory (capture stderr)
OUTPUT=$(register_session "standard" 2>&1)
assert_contains "$OUTPUT" "Warning" "register_session emits warning on same-branch overlap"
assert_contains "$OUTPUT" "other-session-1" "warning mentions overlapping session ID"

# Clean up fake session
rm -f "$SESSIONS_DIR/other-session-1.yaml"

tap_section "L1b.3: unregister_session removes current session file"

# Register, verify exists, unregister, verify gone
register_session "standard"
assert_file_exists "$SESSIONS_DIR/${SID}.yaml" "session file exists before unregister"
unregister_session
assert_file_not_exists "$SESSIONS_DIR/${SID}.yaml" "unregister_session removes session file"

tap_section "L1b.4: unregister_session cleans stale entries (dead PID)"

# Re-register current session (so unregister_session can find current SID)
register_session "standard"

# Create a fake session with PID 99999999 (guaranteed dead)
create_fake_session "stale-dead-pid" "standard" "feature/other" "99999999"
assert_file_exists "$SESSIONS_DIR/stale-dead-pid.yaml" "stale file exists before cleanup"
unregister_session
assert_file_not_exists "$SESSIONS_DIR/stale-dead-pid.yaml" "unregister_session removes stale dead-PID entry"

tap_section "L1b.5: check_session_overlap returns 0 when no overlap"

# Register only this session
_CACHED_SESSION_ID=""
echo "$SID" > "$SB/.claude/.session-id"
register_session "standard"

# Set session type in phase-state for check_session_overlap
reset_phase "standard"

# Reset overlap cache between test scenarios (audit C7 added process-scoped cache)
_SESSION_OVERLAP_CHECKED=false
rc=0
check_session_overlap 2>/dev/null || rc=$?
assert_ok "$rc" "check_session_overlap returns 0 with no overlap"

tap_section "L1b.6: check_session_overlap returns 2 on non-taskgroup overlap"

# Create a fake session on the same branch with a live PID
create_fake_session "overlap-std" "standard" "$TEST_BRANCH" "$$"

# Reset overlap cache between test scenarios (audit C7)
_SESSION_OVERLAP_CHECKED=false
rc=0
OUTPUT=$(check_session_overlap 2>&1) || rc=$?
assert_fail "$rc" "check_session_overlap returns non-zero on non-taskgroup overlap"
assert_contains "$OUTPUT" "BLOCKED" "overlap check emits BLOCKED message"
assert_contains "$OUTPUT" "overlap-std" "overlap message mentions other session ID"

rm -f "$SESSIONS_DIR/overlap-std.yaml"

tap_section "L1b.7: check_session_overlap returns 0 (advisory) for taskgroup overlap"

# Both sessions must be taskgroup type
rm -f "$SESSIONS_DIR/${SID}.yaml"
reset_phase "taskgroup"
register_session "taskgroup"

create_fake_session "overlap-tg" "taskgroup" "$TEST_BRANCH" "$$"

# Reset overlap cache between test scenarios (audit C7)
_SESSION_OVERLAP_CHECKED=false
rc=0
OUTPUT=$(check_session_overlap 2>&1) || rc=$?
assert_ok "$rc" "check_session_overlap returns 0 for taskgroup overlap"
assert_contains "$OUTPUT" "Advisory" "taskgroup overlap emits Advisory message"

rm -f "$SESSIONS_DIR/overlap-tg.yaml"

tap_section "L1b.8: check_session_overlap skips taskdef-query/taskdef-brief"

# Create an overlapping standard session
create_fake_session "overlap-promptt" "standard" "$TEST_BRANCH" "$$"

# Set current session type to taskdef-query
rm -f "$SESSIONS_DIR/${SID}.yaml"
reset_phase "taskdef-query"
register_session "taskdef-query"

# Reset overlap cache between test scenarios (audit C7)
_SESSION_OVERLAP_CHECKED=false
rc=0
check_session_overlap 2>/dev/null || rc=$?
assert_ok "$rc" "check_session_overlap skips taskdef-query sessions"

# Also test taskdef-brief
rm -f "$SESSIONS_DIR/${SID}.yaml"
_CACHED_SESSION_ID=""
echo "$SID" > "$SB/.claude/.session-id"
reset_phase "taskdef-brief"
register_session "taskdef-brief"

# Reset overlap cache between test scenarios (audit C7)
_SESSION_OVERLAP_CHECKED=false
rc=0
check_session_overlap 2>/dev/null || rc=$?
assert_ok "$rc" "check_session_overlap skips taskdef-brief sessions"

rm -f "$SESSIONS_DIR/overlap-promptt.yaml"

tap_section "L1b.9: REPO_OS_SKIP_OVERLAP_CHECK=1 bypasses check"

# Create a blocking overlap scenario
rm -f "$SESSIONS_DIR/${SID}.yaml"
reset_phase "standard"
register_session "standard"
create_fake_session "overlap-skip" "standard" "$TEST_BRANCH" "$$"

# Reset overlap cache between test scenarios (audit C7)
_SESSION_OVERLAP_CHECKED=false
rc=0
REPO_OS_SKIP_OVERLAP_CHECK=1 check_session_overlap 2>/dev/null || rc=$?
assert_ok "$rc" "REPO_OS_SKIP_OVERLAP_CHECK=1 bypasses overlap check"

rm -f "$SESSIONS_DIR/overlap-skip.yaml"

tap_section "L1b.10: check_session_overlap cleans dead-PID overlap opportunistically"

# Create fake overlap with dead PID on same branch
create_fake_session "overlap-dead" "standard" "$TEST_BRANCH" "99999999"
assert_file_exists "$SESSIONS_DIR/overlap-dead.yaml" "dead-PID overlap file exists before check"

# Reset overlap cache between test scenarios (audit C7)
_SESSION_OVERLAP_CHECKED=false
rc=0
check_session_overlap 2>/dev/null || rc=$?
assert_ok "$rc" "check_session_overlap returns 0 after cleaning dead-PID overlap"
assert_file_not_exists "$SESSIONS_DIR/overlap-dead.yaml" "check_session_overlap removes dead-PID overlap file"

# ============================================================
# Summary
# ============================================================
finish_tests
