#!/usr/bin/env bash
# Layer 4 — Session identity, close-gated cleanup, and handoff-bundle carve-out.
#
# Covers:
#   L4.1  Multi-turn standard Stop (pause): _REPO_OS_STDIN_SID preserves .session-id,
#          phase-state, no attempt-counter increment, no state-dir eviction.
#   L4.2  Multi-turn taskdef Stop (pause): same guarantees for taskdef session type.
#   L4.3  Cross-session no-bleed: different _REPO_OS_STDIN_SID does not adopt
#          prior .session-id value.
#   L4.4  Editor-live pause + close parity: pause withholds close; closing Stop
#          (review in phases_completed) performs cleanup/seal path.
#   L4.5  Registry liveness: register_session records a live PID; sweep with
#          exclude_sid does not remove the current session; is_session_active and
#          check_session_overlap give correct verdicts.
#   L4.6  Bug #3 carve-out: template mode allows handoff-bundle paths; blocks
#          non-bundle .claude/local/ paths; path-exactness maintained.
#
# Bash 3.2 compatible. Requires: jq (for hook integration tests in L4.6).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/test-helpers.sh"

# _cleanup-helper.sh is sourced after test-helpers.sh so _analytics-helper.sh
# and _phase-helper.sh are already available (cleanup-helper depends on them).
# It is NOT sourced by setup_sandbox, so we load it explicitly here.
# shellcheck disable=SC1091
source "$HOOKS_DIR/_cleanup-helper.sh"

# ============================================================
# L4.1 — Multi-turn interactive STANDARD Stop: pause preserves identity
# ============================================================

tap_section "L4.1: Standard session pause Stop — identity and state preserved"

setup_sandbox
SB="$(get_sandbox)"

# Initialize a standard session in build phase (not closing)
reset_phase "standard"
SID_BEFORE=$(cat "$SB/.claude/.session-id" 2>/dev/null)
STATE_DIR_BEFORE=$(get_session_state_dir)

# Verify phase-state is in a non-closing phase
assert_file_exists "$STATE_DIR_BEFORE/phase-state" "phase-state exists before pause Stop"

# Simulate what is_session_closing returns for build phase (not closing)
_IC_CLOSING=false
if is_session_closing 2>/dev/null; then
  _IC_CLOSING=true
fi
assert_eq "$_IC_CLOSING" "false" "is_session_closing returns false in build phase"

# Confirm .session-id is preserved (not deleted) on a pause path
assert_file_exists "$SB/.claude/.session-id" ".session-id exists before pause"

SID_AFTER=$(cat "$SB/.claude/.session-id" 2>/dev/null)
assert_eq "$SID_AFTER" "$SID_BEFORE" "session-id unchanged after pause detection"

# Confirm phase-state still exists (not cleaned on pause)
assert_file_exists "$STATE_DIR_BEFORE/phase-state" "phase-state survives pause detection"

# cleanup_session_files with is_closing=false must NOT delete .session-id
# (_cleanup-helper.sh sourced at top of test file)
echo "$SID_BEFORE" > "$SB/.claude/.session-id"
cleanup_session_files "$SB" "standard" "$SID_BEFORE" "false" 2>/dev/null || true
assert_file_exists "$SB/.claude/.session-id" "cleanup_session_files(is_closing=false) preserves .session-id"

teardown_sandbox

# ============================================================
# L4.2 — Multi-turn TASKDEF Stop (pause): same guarantees
# ============================================================

tap_section "L4.2: Taskdef-brief session pause Stop — identity and state preserved"

setup_sandbox
SB="$(get_sandbox)"

reset_phase "taskdef-brief"
SID_TASKDEF=$(cat "$SB/.claude/.session-id" 2>/dev/null)
STATE_DIR_TASKDEF=$(get_session_state_dir)

assert_file_exists "$STATE_DIR_TASKDEF/phase-state" "taskdef phase-state exists"

# taskdef-brief starts in init — not a closing phase
_TD_CLOSING=false
if is_session_closing 2>/dev/null; then
  _TD_CLOSING=true
fi
assert_eq "$_TD_CLOSING" "false" "is_session_closing false for taskdef in init phase"

# cleanup with is_closing=false preserves identity
echo "$SID_TASKDEF" > "$SB/.claude/.session-id"
cleanup_session_files "$SB" "taskdef-brief" "$SID_TASKDEF" "false" 2>/dev/null || true
assert_file_exists "$SB/.claude/.session-id" "cleanup_session_files(is_closing=false) preserves taskdef .session-id"

teardown_sandbox

# ============================================================
# L4.3 — A hook's own id beats a flat file left by someone else (Decision t-0065)
# ============================================================
# Rewritten for t-0065. This case used to pin "first-writer-wins": the flat
# .session-id beat the hook's stdin id, on the premise that the harness rotates
# the id across a context-window turnover. Nothing on record shows that
# rotation, and a flat file beating the hook's own id is how one session's id
# reached another (R47, R48, GT-8). Now the hook's id wins and no file is
# written; the flat file is consulted only with no Claude Code id at all.

tap_section "L4.3: the hook's stdin id beats a flat file, and nothing is written"

setup_sandbox
SB="$(get_sandbox)"

# Case A: a flat file from another session exists — the hook's id wins, file untouched.
PRIOR_SID="prior-session-20260608-111111"
echo "$PRIOR_SID" > "$SB/.claude/.session-id"
_CACHED_SESSION_ID=""
export _REPO_OS_STDIN_SID="this-hook-session-20260608-222222"
RESOLVED_SID=$(get_session_id "$SB" 2>/dev/null)
assert_eq "$RESOLVED_SID" "$_REPO_OS_STDIN_SID" "get_session_id returns the hook's own stdin id, not a flat file's"
FILE_SID=$(cat "$SB/.claude/.session-id" 2>/dev/null || true)
assert_eq "$FILE_SID" "$PRIOR_SID" ".session-id file is NOT overwritten when a different stdin sid arrives"

# Case B: no files — the stdin id is used and nothing is seeded.
rm -f "$SB/.claude/.session-id" "$SB"/.claude/.session-id.*
_CACHED_SESSION_ID=""
export _REPO_OS_STDIN_SID="bootstrap-session-20260608-333333"
BOOT_SID=$(get_session_id "$SB" 2>/dev/null)
assert_eq "$BOOT_SID" "bootstrap-session-20260608-333333" "get_session_id uses the stdin sid when no file exists"
assert_file_not_exists "$SB/.claude/.session-id" "the stdin sid is not written through to .session-id"

# Case C: no Claude Code id at all (a manual shell, a fixture) — the flat file.
unset _REPO_OS_STDIN_SID
echo "$PRIOR_SID" > "$SB/.claude/.session-id"
_CACHED_SESSION_ID=""
assert_eq "$(get_session_id "$SB" 2>/dev/null)" "$PRIOR_SID" "with no Claude Code id the flat file is read"

# Unset for next tests
unset _REPO_OS_STDIN_SID
_CACHED_SESSION_ID=""

teardown_sandbox

# ============================================================
# L4.4 — Editor-live pause + close parity via is_session_closing
# ============================================================

tap_section "L4.4: Editor-live pause (non-closing) and close (review completed) parity"

setup_sandbox
SB="$(get_sandbox)"

# Editor-live session in build phase (non-closing)
_CACHED_SESSION_STATE_DIR=""
reset_phase "editor-live"
STATE_DIR_EL=$(get_session_state_dir)

_EL_CLOSING=false
if is_session_closing 2>/dev/null; then
  _EL_CLOSING=true
fi
assert_eq "$_EL_CLOSING" "false" "editor-live in build phase: is_session_closing=false (pause)"

# Simulate closing state: directly write phase-state with review in phases_completed.
# (advance_phase requires going through the full sequence; for this test we only need
# to verify that is_session_closing reads phases_completed correctly.)
EL_SID=$(_read_phase_field "session_id" "$STATE_DIR_EL/phase-state" 2>/dev/null || true)
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf 'session_type: editor-live\nsession_id: %s\nmode: review\ncurrent_phase: review\ncycle: 1\nphases_completed: init,build,commit\nsolo: false\ntag: agent\ntimestamp: %s\n' \
  "$EL_SID" "$ts" > "$STATE_DIR_EL/phase-state"
# Invalidate the phase-state cache so is_session_closing re-reads
_PS_VALIDATED=false
_CACHED_CURRENT_SID=""

_EL_CLOSING2=false
if is_session_closing 2>/dev/null; then
  _EL_CLOSING2=true
fi
assert_eq "$_EL_CLOSING2" "true" "editor-live with current_phase=review: is_session_closing=true (close)"

# Also verify phases_completed path: write review into phases_completed
printf 'session_type: editor-live\nsession_id: %s\nmode: review\ncurrent_phase: verify\ncycle: 1\nphases_completed: init,build,commit,review\nsolo: false\ntag: agent\ntimestamp: %s\n' \
  "$EL_SID" "$ts" > "$STATE_DIR_EL/phase-state"
_PS_VALIDATED=false
_CACHED_CURRENT_SID=""

PS_COMPLETED=$(_read_phase_field "phases_completed" "$STATE_DIR_EL/phase-state" 2>/dev/null || true)
case ",$PS_COMPLETED," in
  *",review,"*)
    _tap_pass "phases_completed contains review — is_session_closing=true path"
    ;;
  *)
    _tap_fail "phases_completed contains review — is_session_closing=true path" "got: $PS_COMPLETED"
    ;;
esac

_EL_CLOSING3=false
if is_session_closing 2>/dev/null; then
  _EL_CLOSING3=true
fi
assert_eq "$_EL_CLOSING3" "true" "editor-live with review in phases_completed: is_session_closing=true"

teardown_sandbox

# ============================================================
# L4.5 — Registry liveness: durable PID, sweep exclude_sid, overlap checks
# ============================================================

tap_section "L4.5: Registry liveness — durable PID, sweep exclude, overlap"

setup_sandbox
SB="$(get_sandbox)"
_CACHED_BRANCH="feature/test-liveness"

# Register session — should use PPID (durable) or $$ fallback
reset_phase "standard"
SID_LIVE=$(get_session_id "$SB")
register_session "standard"

SESSIONS_DIR="$SB/.claude/.state/sessions"
assert_file_exists "$SESSIONS_DIR/${SID_LIVE}.yaml" "register_session creates session file"

# The recorded PID should be a live process (PPID or $$)
RECORDED_PID=$(grep '^pid: ' "$SESSIONS_DIR/${SID_LIVE}.yaml" 2>/dev/null | sed 's/^pid: *//')
rc_pid=0
kill -0 "$RECORDED_PID" 2>/dev/null || rc_pid=$?
assert_ok "$rc_pid" "registered PID is a live process"

# sweep_stale_sessions with exclude_sid must NOT remove the current session
# even if PPID appears dead from a subprocess context
sweep_stale_sessions "$SID_LIVE" || true
assert_file_exists "$SESSIONS_DIR/${SID_LIVE}.yaml" "sweep_stale_sessions(exclude_sid) preserves current session"

# Create a stale entry with a dead PID — sweep should remove it
create_fake_session "stale-for-sweep" "standard" "feature/other" "99999999"
assert_file_exists "$SESSIONS_DIR/stale-for-sweep.yaml" "stale entry exists before sweep"
sweep_stale_sessions "$SID_LIVE" || true
assert_file_not_exists "$SESSIONS_DIR/stale-for-sweep.yaml" "sweep removes dead-PID entry (non-excluded)"

# is_session_active: no other session on same branch → returns 1 (false)
rc_active=0
is_session_active "$_CACHED_BRANCH" 2>/dev/null || rc_active=$?
assert_fail "$rc_active" "is_session_active returns false when no other session on branch"

# check_session_overlap: with only current session → returns 0 (no overlap)
_SESSION_OVERLAP_CHECKED=false
rc_overlap=0
check_session_overlap 2>/dev/null || rc_overlap=$?
assert_ok "$rc_overlap" "check_session_overlap returns 0 with no other session"

teardown_sandbox

# ============================================================
# L4.6 — Bug #3 carve-out: is_carved_out for handoff-bundle paths
# ============================================================

tap_section "L4.6: Template-mode carve-out for handoff-bundle paths"

# Source the mode-guard helper directly (it's not standalone).
# setup_sandbox sources _analytics-helper.sh (provides normalize_path used by
# make_relative in _mode-guard-helper.sh). No other top-level code in the helper.
setup_sandbox
# shellcheck disable=SC1091
source "$HOOKS_DIR/_mode-guard-helper.sh"

# Per-brief path (Decision t-0043) — must be carved out in template mode
rc_bundle1=0
is_carved_out "template" ".claude/local/handoff-bundles/my-brief.yaml" || rc_bundle1=$?
assert_ok "$rc_bundle1" "is_carved_out: .claude/local/handoff-bundles/* returns 0 in template mode"

# Legacy deprecated fallback path — must also be carved out
rc_bundle2=0
is_carved_out "template" ".claude/local/handoff-bundle.yaml" || rc_bundle2=$?
assert_ok "$rc_bundle2" "is_carved_out: .claude/local/handoff-bundle.yaml returns 0 in template mode"

# Path-exactness: a sibling non-bundle path must still return 1 (block)
rc_other=0
is_carved_out "template" ".claude/local/secret.yaml" || rc_other=$?
assert_fail "$rc_other" "is_carved_out: .claude/local/secret.yaml returns 1 (blocked) in template mode"

# Carve-out is template-mode only — child mode must NOT allow these paths
rc_child=0
is_carved_out "child" ".claude/local/handoff-bundle.yaml" || rc_child=$?
assert_fail "$rc_child" "is_carved_out: handoff-bundle.yaml NOT carved out in child mode"

rc_child2=0
is_carved_out "child" ".claude/local/handoff-bundles/x.yaml" || rc_child2=$?
assert_fail "$rc_child2" "is_carved_out: handoff-bundles/* NOT carved out in child mode"

teardown_sandbox

# ============================================================
# L4.7 — Split-identity multi-turn editor-live: drift falsifier (Decision 0023)
# ============================================================
# Integration test for the editor-live identity-drift fix. Simulates an
# editor-live session initialized under a timestamp-PID id, then fires Stop
# hooks across two "turns" with a DIFFERENT harness UUID each time (modelling a
# context-window turnover that rotates session_id). Asserts the session keeps a
# stable identity, does NOT prematurely seal its branch on a pause, and resolves
# its committed session log at close despite the rotated stdin SID.
#
# This is the falsifier the brief calls for: it must FAIL before the fix (the
# write-through churns .session-id → orphaned state dir → premature seal / lost
# log) and PASS after.

tap_section "L4.7: Split-identity multi-turn editor-live — no drift, no premature seal"

# setup_hook_sandbox (not plain setup_sandbox): provides _HOOKS_DIR + fixtures
# (run_hook_rc / fixture_stop) and a real git history so the Stop hook can run
# end-to-end and the rotated stdin UUID is genuinely injected per turn.
setup_hook_sandbox
SB="$(get_sandbox)"

# --- Turn 1: init editor-live under a timestamp-PID id (id-A), reach build ---
switch_sandbox_branch "live-editor-1"
_CACHED_SESSION_ID=""
_CACHED_SESSION_STATE_DIR=""
_CACHED_BRANCH="live-editor-1"
reset_phase "editor-live"
SID_A=$(cat "$SB/.claude/.session-id" 2>/dev/null)
STATE_DIR_A=$(get_session_state_dir)
advance_phase "build" >/dev/null 2>&1

# session_log_id persisted at init and survives the init→build advance.
LOG_ID_AT_BUILD=$(_read_phase_field "session_log_id" "$STATE_DIR_A/phase-state" 2>/dev/null || true)
assert_eq "$LOG_ID_AT_BUILD" "$SID_A" "session_log_id persisted in phase-state and survives advance_phase"

# --- Turn 2: PAUSE Stop with a DIFFERENT harness UUID ---
UUID_B="11111111-2222-3333-4444-555555555555"
run_hook_rc "session-close-check.sh" "$(fixture_stop "$UUID_B")" >/dev/null 2>&1 || true

# (a) .session-id content unchanged — first-writer-wins ignores the rotated UUID.
SID_AFTER_PAUSE=$(cat "$SB/.claude/.session-id" 2>/dev/null)
assert_eq "$SID_AFTER_PAUSE" "$SID_A" "pause Stop with a different UUID leaves .session-id unchanged"

# (b) get_session_state_dir() stable across the hook fire.
_CACHED_SESSION_ID=""
_CACHED_SESSION_STATE_DIR=""
STATE_DIR_AFTER_PAUSE=$(get_session_state_dir)
assert_eq "$STATE_DIR_AFTER_PAUSE" "$STATE_DIR_A" "get_session_state_dir() stable after a pause Stop with a rotated UUID"

# (c) branch is NOT sealed on a pause (not appended to closed-branches).
CLOSED_BRANCHES="$SB/.claude/local/closed-branches"
_SEALED=false
if [ -f "$CLOSED_BRANCHES" ] && grep -q '^live-editor-1$' "$CLOSED_BRANCHES" 2>/dev/null; then
  _SEALED=true
fi
assert_eq "$_SEALED" "false" "pause Stop does NOT seal the editor-live branch"

# --- Turn 3: CLOSE Stop with yet another UUID — committed log must be found ---
# Write the session log under the init-time id (id-A) and move phase-state into a
# closing phase. The committed log lives at session-<id-A>.md; the Stop fires
# with a third rotated UUID, so the log can only be found via session_log_id /
# the stable .session-id — never via the rotated stdin value.
mkdir -p "$SB/.claude/local/sessions"
printf '# Session Log\n\nSession: %s\nDate: 2026-06-15\n\n[editor-live close — verifying log resolution across identity rotation.]\n' \
  "$SID_A" > "$SB/.claude/local/sessions/session-${SID_A}.md"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf 'session_type: editor-live\nsession_id: %s\nsession_log_id: %s\nmode: review\ncurrent_phase: review\ncycle: 1\nphases_completed: init,build,commit\nsolo: false\ntag: agent\ntimestamp: %s\n' \
  "$SID_A" "$SID_A" "$ts" > "$STATE_DIR_A/phase-state"
# Invalid baseline → non-zero session (avoids the zero-change fast path).
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"

UUID_C="99999999-8888-7777-6666-555555555555"
CLOSE_OUT=$(run_hook_rc "session-close-check.sh" "$(fixture_stop "$UUID_C")" 2>&1 || true)

# (d) the committed session log is found — no "Session log not updated" block.
case "$CLOSE_OUT" in
  *"Session log not updated"*)
    _tap_fail "close Stop finds the committed log via session_log_id (not the rotated UUID)" "got block: $CLOSE_OUT"
    ;;
  *)
    _tap_pass "close Stop finds the committed log via session_log_id (not the rotated UUID)"
    ;;
esac

# Step-2 isolation: when the live id has drifted, session-close-check resolves
# the log id from phase-state's session_log_id, independent of the live id.
printf 'session_type: editor-live\nsession_id: LIVE-DRIFTED-ID\nsession_log_id: %s\nmode: review\ncurrent_phase: review\ncycle: 1\nphases_completed: init,build,commit\nsolo: false\ntag: agent\ntimestamp: %s\n' \
  "$SID_A" "$ts" > "$STATE_DIR_A/phase-state"
RESOLVED_LOG_ID=$(_read_phase_field "session_log_id" "$STATE_DIR_A/phase-state" 2>/dev/null || true)
assert_eq "$RESOLVED_LOG_ID" "$SID_A" "log id resolves from session_log_id, decoupled from a drifted live session_id"

teardown_sandbox

# ============================================================
# L4.8 — Daemon-safe branching guard: repo-scoped pgrep fallback (Decision 0036)
# ============================================================
# bash-guard.sh blocks branch switches on the main working tree when THIS repo's
# automation daemon is active. The pgrep fallback (for an absent/stale pid file)
# must be repo-scoped: a daemon belonging to ANOTHER repo must not block here.
# (Lives in Layer 4 rather than Layer 3 because Layer 3 early-exits on the
# pre-existing reset_phase per-session-dir teardown bug.)

tap_section "L4.8: Daemon branch-guard — live pid blocks; absent pid + no this-repo daemon allows"

setup_hook_sandbox
SB="$(get_sandbox)"
mkdir -p "$SB/.claude/.automation"
switch_sandbox_branch "feature/daemon-test"

# Case 1: a LIVE runner.pid for this repo -> branch switch blocked (primary check)
echo "$$" > "$SB/.claude/.automation/runner.pid"
run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "git checkout -b some-new-branch")" >/dev/null 2>&1
case "$_LAST_OUTPUT" in
  *"Daemon is running"*) _tap_pass "live runner.pid blocks a branch switch (daemon guard fires)" ;;
  *)                     _tap_fail "live runner.pid blocks a branch switch (daemon guard fires)" "got: $_LAST_OUTPUT" ;;
esac

# Case 2: no runner.pid and no THIS-repo daemon -> branch switch NOT blocked by
# the daemon guard. With the unscoped pgrep this was flaky (any machine-wide
# `runner.sh --daemon` matched); the repo-scoped pattern makes it reliable.
rm -f "$SB/.claude/.automation/runner.pid"
run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "git checkout -b another-branch")" >/dev/null 2>&1
case "$_LAST_OUTPUT" in
  *"Daemon is running"*) _tap_fail "absent pid + no this-repo daemon does NOT trip the daemon guard" "got: $_LAST_OUTPUT" ;;
  *)                     _tap_pass "absent pid + no this-repo daemon does NOT trip the daemon guard" ;;
esac

# Case 3 (scoping falsifier): a daemon belonging to ANOTHER repo must NOT block
# here. Spawn a process whose argv impersonates a different repo's daemon path.
# The repo-scoped pgrep must ignore it; the OLD unscoped `runner.sh --daemon`
# pattern WOULD match it and wrongly block (the exact prior-session bug).
if command -v pgrep >/dev/null 2>&1; then
  _FAKE_ARGV="/tmp/foreign-repo-$$/.claude/.automation/runner.sh --daemon"
  bash -c "exec -a '$_FAKE_ARGV' sleep 30" &
  _FAKE_DAEMON_PID=$!
  # Poll (bounded ~2s) until the impersonated argv is actually visible to pgrep,
  # so the guard check below isn't vacuous on a slow host (a fixed sleep can fire
  # before exec replaces argv).
  _spin=0
  while [ "$_spin" -lt 20 ]; do
    pgrep -f "$_FAKE_ARGV" >/dev/null 2>&1 && break
    ( sleep 0.1 ) 2>/dev/null || true
    _spin=$((_spin + 1))
  done
  run_hook_rc "bash-guard.sh" "$(fixture_pretooluse_bash "git checkout -b scoping-test")" >/dev/null 2>&1
  case "$_LAST_OUTPUT" in
    *"Daemon is running"*) _tap_fail "another repo's daemon does NOT block here (repo-scoped pgrep)" "got: $_LAST_OUTPUT" ;;
    *)                     _tap_pass "another repo's daemon does NOT block here (repo-scoped pgrep)" ;;
  esac
  kill "$_FAKE_DAEMON_PID" 2>/dev/null || true
  wait "$_FAKE_DAEMON_PID" 2>/dev/null || true
else
  # Keep the test count stable and make the omission visible (no TAP SKIP prim).
  _tap_pass "another repo's daemon does NOT block here (repo-scoped pgrep) [skipped — pgrep unavailable]"
fi

teardown_sandbox

# ============================================================
# L4.9 — Foreign-state guard: an interactive Stop must not enforce a
#         CONCURRENT session's close (identity-churn safety)
# ============================================================
# session-close-check.sh must NOT run close enforcement (session-log demand /
# uncommitted block) against a session owned by a DIFFERENT, independently-live
# process. Before Decision t-0065 the trigger was a shared flat .session-id
# resolving to another window's state. Since t-0065 state resolves from the same
# id the hook's stdin carries, so the guard fires only when CLAUDE_CODE_SESSION_ID
# and the stdin id disagree — the case L4.9a now builds. L4.9a's control (dead
# owner) shows the skip comes from the guard and not from an empty state dir.

tap_section "L4.9: Foreign-state guard — live-foreign close skipped, orphan still enforced"

# --- L4.9a — Foreign state owned by a different LIVE process => guard skips ---
_l49a_run() { # owner_pid -> sets _LAST_OUTPUT
  setup_hook_sandbox
  SB="$(get_sandbox)"
  FSID="foreign-session-20260617-000001"
  rm -f "$SB/.claude/.session-id" "$SB"/.claude/.session-id.* 2>/dev/null || true
  # The foreign session's per-session phase-state in a CLOSING standard state
  # (review completed, no session log) — WITHOUT the guard this blocks on the
  # session-log check.
  FS_DIR="$SB/.claude/.state/wt-sessions/$FSID"
  mkdir -p "$FS_DIR"
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf 'session_type: standard\nsession_id: %s\nsession_log_id: %s\nmode: review\ncurrent_phase: review\ncycle: 1\nphases_completed: init,build,review\nsolo: false\ntag: agent\ntimestamp: %s\n' \
    "$FSID" "$FSID" "$ts" > "$FS_DIR/phase-state"
  # Non-zero baseline so the zero-change fast path does not pre-empt the guard.
  echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
  create_fake_session "$FSID" "standard" "feature/test" "$1"
  # State resolves to FSID through the env; the hook's stdin carries another id.
  export CLAUDE_CODE_SESSION_ID="$FSID"
  _CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
  assert_eq "$(get_session_state_dir)" "$FS_DIR" "per-session dir resolves for the foreign sid (guard reads crafted phase-state)"
  run_hook_rc "session-close-check.sh" "$(fixture_stop "live-stdin-uuid-aaaa")" >/dev/null 2>&1 || true
  unset CLAUDE_CODE_SESSION_ID
  _CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
}

# Foreign owner: a real, live process whose PID is not the hook's PPID.
sleep 60 &
FS_LIVE_PID=$!
_l49a_run "$FS_LIVE_PID"
case "$_LAST_OUTPUT" in
  *"Session log not updated"*)
    _tap_fail "live-foreign close is skipped (no session-log block)" "got block: $_LAST_OUTPUT" ;;
  *'"decision"'*)
    _tap_fail "live-foreign close is skipped (no block emitted)" "got block JSON: $_LAST_OUTPUT" ;;
  *)
    _tap_pass "live-foreign close is skipped (foreign_state_skip — no block)" ;;
esac
kill "$FS_LIVE_PID" 2>/dev/null || true
wait "$FS_LIVE_PID" 2>/dev/null || true
teardown_sandbox

# Control: the same state with a DEAD owner is enforced, so the skip above is
# the guard's doing.
_l49a_run "99999999"
case "$_LAST_OUTPUT" in
  *"Session log not updated"*) _tap_pass "control: a dead owner's identical state is enforced (the skip is the guard's)" ;;
  *) _tap_fail "control: a dead owner's identical state is enforced (the skip is the guard's)" "got: $_LAST_OUTPUT" ;;
esac
teardown_sandbox

# --- L4.9b — An orphan in the flat file is not this hook's session (t-0065) ---
# Rewritten for t-0065. This case used to show that a Stop whose stdin id
# differed from the flat file's resolved the orphan's state and enforced ITS
# close requirements. A hook now resolves its own id, so the orphan's state is
# neither enforced against this session nor touched; the sweep reaps it once
# its owner is dead.
setup_hook_sandbox
SB="$(get_sandbox)"

OSID="orphan-session-20260617-000002"
echo "$OSID" > "$SB/.claude/.session-id"
OS_DIR="$SB/.claude/.state/wt-sessions/$OSID"
mkdir -p "$OS_DIR"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf 'session_type: standard\nsession_id: %s\nsession_log_id: %s\nmode: review\ncurrent_phase: review\ncycle: 1\nphases_completed: init,build,review\nsolo: false\ntag: agent\ntimestamp: %s\n' \
  "$OSID" "$OSID" "$ts" > "$OS_DIR/phase-state"
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
create_fake_session "$OSID" "standard" "feature/test" "99999999"

run_hook_rc "session-close-check.sh" "$(fixture_stop "live-stdin-uuid-bbbb")" >/dev/null 2>&1 || true
case "$_LAST_OUTPUT" in
  *"Session log not updated"*)
    _tap_fail "an orphan's close requirements are not enforced against another session" "got: $_LAST_OUTPUT" ;;
  *)
    _tap_pass "an orphan's close requirements are not enforced against another session" ;;
esac
assert_file_exists "$OS_DIR/phase-state" "the orphan's phase-state is left for the sweep, not touched by another session's Stop"
teardown_sandbox

# --- L4.9c — Turnover discriminator (unit): registry pid == our PID -> not foreign ---
# A unit mirror of the guard's exact boolean, with $$ standing in for the hook's
# durable pid. L4.9d below drives the same discriminator through the full hook,
# which became possible once the guard compared _resolve_durable_pid (an
# exportable CLAUDE_PID) instead of the hook's unpredictable $PPID.
tap_section "L4.9c: Turnover discriminator — resolved-state pid == own PID does not trip the guard"

STATE_SID="self-session-id"
STDIN_SID="rotated-harness-uuid"   # differs from STATE_SID, as in a turnover

# OWN_PID stands in for the hook's $PPID — the durable claude process that also
# registered the session. It is a genuinely LIVE process: assert that explicitly,
# so the turnover suppression below is proven to come from the pid-EQUALITY clause
# and not from a dead owner. (The two cases differ ONLY in pid==own vs pid!=own;
# both owners are alive — that is what isolates the discriminator.)
OWN_PID=$$
_own_rc=0; kill -0 "$OWN_PID" 2>/dev/null || _own_rc=$?
assert_ok "$_own_rc" "stand-in own PID is live (turnover must suppress the guard DESPITE liveness)"

# Turnover: the resolved-state registry pid IS our live process. The pid-equality
# clause `[ reg_pid != own_pid ]` is the only thing suppressing the guard here;
# drop it and the live owner would (wrongly) trip the guard — so this asserts the
# discriminator, not a tautology.
REG_PID="$OWN_PID"
fire=true
[ "$STATE_SID" != "$STDIN_SID" ] || fire=false
{ [ -n "$REG_PID" ] && [ "$REG_PID" != "$OWN_PID" ] && kill -0 "$REG_PID" 2>/dev/null; } || fire=false
assert_eq "$fire" "false" "turnover: registry pid == own LIVE PID -> guard does NOT fire"

# Foreign control: a DIFFERENT, independently-live process -> guard fires. Same
# liveness as the turnover case; only the pid differs from OWN_PID.
sleep 60 &
REG_PID=$!
fire=true
[ "$STATE_SID" != "$STDIN_SID" ] || fire=false
{ [ -n "$REG_PID" ] && [ "$REG_PID" != "$OWN_PID" ] && kill -0 "$REG_PID" 2>/dev/null; } || fire=false
assert_eq "$fire" "true" "foreign: a different LIVE PID -> guard fires"
kill "$REG_PID" 2>/dev/null || true
wait "$REG_PID" 2>/dev/null || true

# --- L4.9d — Through the hook: own durable pid after an id change is enforced ---
# register_session records _resolve_durable_pid (CLAUDE_PID, Decision t-0065),
# so the guard must compare against that, not the hook's $PPID. Exporting
# CLAUDE_PID makes the hook's own pid predictable, which L4.9c could not do.
# Same state as L4.9a — ids differ, owner live — but the owner is this session's
# own claude process, as after a /clear, so its close is enforced.
tap_section "L4.9d: own durable pid with a changed id — close enforced through the hook"

sleep 60 &
OWN_CLAUDE_PID=$!
export CLAUDE_PID="$OWN_CLAUDE_PID"
_l49a_run "$OWN_CLAUDE_PID"
unset CLAUDE_PID
case "$_LAST_OUTPUT" in
  *"Session log not updated"*) _tap_pass "a state owned by this session's own claude pid is enforced, not skipped as foreign" ;;
  *) _tap_fail "a state owned by this session's own claude pid is enforced, not skipped as foreign" "got: $_LAST_OUTPUT" ;;
esac
kill "$OWN_CLAUDE_PID" 2>/dev/null || true
wait "$OWN_CLAUDE_PID" 2>/dev/null || true
teardown_sandbox

# ============================================================
# L4.10 — Concurrent processes resolve to DISTINCT ids and state dirs
# ============================================================
# Rewritten for t-0065: each window has its own Claude Code id, and resolving
# it writes no identity file (this case used to assert a sidecar was written).

tap_section "L4.10: Concurrent processes — distinct ids and state dirs, no identity files"

setup_sandbox
SB="$(get_sandbox)"
rm -f "$SB/.claude/.session-id" "$SB"/.claude/.session-id.* 2>/dev/null || true

export _REPO_OS_STDIN_SID="winA-uuid-aaaa"
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
SID_A=$(get_session_id "$SB")
SD_A=$(get_session_state_dir)
export _REPO_OS_STDIN_SID="winB-uuid-bbbb"
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
SID_B=$(get_session_id "$SB")
SD_B=$(get_session_state_dir)
assert_eq "$SID_A" "winA-uuid-aaaa" "process A resolves its own id"
assert_eq "$SID_B" "winB-uuid-bbbb" "process B resolves its own id"
assert_neq "$SD_B" "$SD_A" "concurrent process B resolves a DIFFERENT per-session state dir"
assert_file_not_exists "$SB/.claude/.session-id" "neither process wrote the flat identity file"

unset _REPO_OS_STDIN_SID
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
teardown_sandbox

# ============================================================
# L4.11 — One conversation across turns keeps one id and state dir
# ============================================================
# Rewritten for t-0065. This case used to simulate the harness ROTATING the id
# mid-conversation and pin a sidecar that ignored the rotation. Measured
# 2026-11-03: a conversation keeps one id across compactions, and Claude Code
# documents that it changes only on /clear and fork. So stability is the id's
# own; /clear starting a new session is correct, not churn.

tap_section "L4.11: one conversation keeps its id across turns; /clear starts a new session"

setup_sandbox
SB="$(get_sandbox)"
rm -f "$SB/.claude/.session-id" "$SB"/.claude/.session-id.* 2>/dev/null || true

export CLAUDE_CODE_SESSION_ID="conversation-uuid"
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
SID_T1=$(get_session_id "$SB"); SD_T1=$(get_session_state_dir)
# Next turn, after a compaction: same conversation id, fresh hook process.
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
SID_T2=$(get_session_id "$SB"); SD_T2=$(get_session_state_dir)
assert_eq "$SID_T2" "$SID_T1" "the id is stable across turns of one conversation"
assert_eq "$SD_T2" "$SD_T1" "per-session state dir stable across turns"
export CLAUDE_CODE_SESSION_ID="after-clear-uuid"
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
assert_eq "$(get_session_id "$SB")" "after-clear-uuid" "/clear (a new Claude Code id) is a new session"

unset CLAUDE_CODE_SESSION_ID
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
teardown_sandbox

# ============================================================
# L4.12 — A flat id is never adopted while a Claude Code id exists
# ============================================================
# Rewritten for t-0065. This case pinned adopt-when-unowned, mint-on-live-peer
# and recover-on-dead-peer — the rules by which one session's id reached
# another (R47, R48 d, GT-8). None of them exists now.

tap_section "L4.12: a flat id is never adopted, whatever its owner's state"

setup_sandbox
SB="$(get_sandbox)"
rm -f "$SB"/.claude/.session-id.* 2>/dev/null || true
echo "durable-flat-id" > "$SB/.claude/.session-id"
sleep 60 & PEER_PID=$!
echo "durable-flat-id" > "$SB/.claude/.session-id.$PEER_PID"

export _REPO_OS_STDIN_SID="fresh-stdin-uuid"
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
assert_eq "$(get_session_id "$SB")" "fresh-stdin-uuid" "a flat id claimed by a live peer is not adopted"
kill "$PEER_PID" 2>/dev/null || true; wait "$PEER_PID" 2>/dev/null || true
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
assert_eq "$(get_session_id "$SB")" "fresh-stdin-uuid" "a flat id whose owner is dead is not adopted either"
assert_eq "$(cat "$SB/.claude/.session-id")" "durable-flat-id" "the flat file is left as found"
_n=0; for _f in "$SB"/.claude/.session-id.*; do [ -f "$_f" ] && _n=$((_n + 1)); done
assert_eq "$_n" "1" "no sidecar was written (only the peer's legacy one remains)"

unset _REPO_OS_STDIN_SID
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
teardown_sandbox

# ============================================================
# L4.13 — sweep_stale_sessions reaps dead-pid identity sidecars
# ============================================================

tap_section "L4.13: sweep_stale_sessions reaps dead-pid identity sidecars, preserves live ones"

setup_sandbox
SB="$(get_sandbox)"
rm -f "$SB"/.claude/.session-id.* 2>/dev/null || true

echo "dead-sid" > "$SB/.claude/.session-id.99999999"
sleep 60 & PID_LIVE=$!
echo "live-sid" > "$SB/.claude/.session-id.$PID_LIVE"

sweep_stale_sessions || true

assert_file_not_exists "$SB/.claude/.session-id.99999999" "sweep removes a dead-pid identity sidecar (no unbounded accumulation)"
assert_file_exists "$SB/.claude/.session-id.$PID_LIVE" "sweep preserves a live-pid identity sidecar"

kill "$PID_LIVE" 2>/dev/null || true; wait "$PID_LIVE" 2>/dev/null || true
teardown_sandbox

# ============================================================
# L4.14 — unregister_session removes the registry record and nothing else
# ============================================================
# Rewritten for t-0065: no sidecar holds identity, so there is none to delete
# by content (that deletion is gone). The next session in the same window has
# its own Claude Code id.

tap_section "L4.14: unregister_session removes the registry record; the next session has its own id"

setup_sandbox
SB="$(get_sandbox)"
rm -f "$SB/.claude/.session-id" "$SB"/.claude/.session-id.* "$SB"/.claude/.state/sessions/*.yaml 2>/dev/null || true

export CLAUDE_CODE_SESSION_ID="closing-sess-uuid"
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
create_fake_session "closing-sess-uuid" "standard" "feature/test" "$$"
assert_file_exists "$SB/.claude/.state/sessions/closing-sess-uuid.yaml" "session registry record present before close"
unregister_session 2>/dev/null || true
assert_file_not_exists "$SB/.claude/.state/sessions/closing-sess-uuid.yaml" "unregister_session removes the registry record"
assert_file_not_exists "$SB/.claude/.session-id" "and writes no identity file"

export CLAUDE_CODE_SESSION_ID="next-sess-uuid"
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
assert_eq "$(get_session_id "$SB")" "next-sess-uuid" "the next session in the window resolves its own id"

unset CLAUDE_CODE_SESSION_ID
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
teardown_sandbox

# ============================================================
# L4.15 — Env-var precedence: a long-lived process must follow REPO_OS_SESSION_ID
# ============================================================

tap_section "L4.15: REPO_OS_SESSION_ID overrides a populated cache (daemon per-brief identity)"

setup_sandbox
SB="$(get_sandbox)"
rm -f "$SB/.claude/.session-id" "$SB"/.claude/.session-id.* 2>/dev/null || true

# The automation daemon is ONE process that sources this library once and
# re-exports REPO_OS_SESSION_ID per brief. get_session_id consulted its cache
# first, so brief 1 of a run became the identity for every brief after it:
# state_manager_setup wrote plan-approved under the stale key, the runner's
# worktree mirror found nothing at the new key, and the brief deadlocked in the
# plan phase — writes gated, no advance possible without plan-approved, and no
# AskUserQuestion available in headless mode. Diagnosed 2026-10-12; hit again
# 2026-10-13, where it killed brief 3 of a 6-brief group after ~45 minutes.
#
# CALL SHAPE IS THE TEST. `get_session_id ... > /dev/null` — a direct call with
# a redirect, NOT `$(get_session_id ...)` — because that is what
# state-manager.sh:39 does, and it is the only shape that reproduces the bug: a
# command substitution runs in a subshell, so the cache it populates dies with
# it and every call starts cold. Written with `$(...)` first, this whole section
# passed against the unfixed helper. The caches are deliberately NOT reset
# between the two briefs below; they carry over, exactly as in the daemon loop.
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""

# The ids carry $$ so that even a rooting failure cannot land this case on a
# real session's state directory (known-issue R41).
export REPO_OS_SESSION_ID="daemon-brief-1-$$"
get_session_id "$SB" > /dev/null
get_session_state_dir > /dev/null
SID_B1="$_CACHED_SESSION_ID"; SD_B1="$_CACHED_SESSION_STATE_DIR"
assert_eq "$SID_B1" "daemon-brief-1-$$" "brief 1 resolves to its own injected id"

export REPO_OS_SESSION_ID="daemon-brief-2-$$"
get_session_id "$SB" > /dev/null
SID_B2="$_CACHED_SESSION_ID"
assert_eq "$SID_B2" "daemon-brief-2-$$" "brief 2 follows the NEW env id despite a populated cache"

# The state dir is derived from the id, so a stale dir cache is the same defect
# wearing a different hat — and it is the one that actually mis-routed
# plan-approved into the previous brief's directory.
get_session_state_dir > /dev/null
SD_B2="$_CACHED_SESSION_STATE_DIR"
assert_neq "$SD_B2" "$SD_B1" "state dir follows the new identity"
case "$SD_B2" in
  *daemon-brief-2*) _tap_pass "state dir is keyed on the current brief id" ;;
  *) _tap_fail "state dir is keyed on the current brief id" "got $SD_B2" ;;
esac

# Idempotence: re-asserting the SAME id must not thrash the cache.
get_session_id "$SB" > /dev/null
assert_eq "$_CACHED_SESSION_ID" "daemon-brief-2-$$" "repeat call with an unchanged env id is stable"

unset REPO_OS_SESSION_ID
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
teardown_sandbox

tap_section "L4.15b: the cache still serves when REPO_OS_SESSION_ID is absent"

setup_sandbox
SB="$(get_sandbox)"
rm -f "$SB/.claude/.session-id" "$SB"/.claude/.session-id.* 2>/dev/null || true
unset REPO_OS_SESSION_ID
# Interactive sessions never set the env var, and must keep the cache-first
# path — this is what L4.11's turnover stability rests on.
_CACHED_SESSION_ID="cached-interactive-id"; _CACHED_SESSION_STATE_DIR=""
SID_C=$(get_session_id "$SB")
assert_eq "$SID_C" "cached-interactive-id" "no env var: the cache is still authoritative"
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
teardown_sandbox

# ============================================================
# L4.16 — A second process's SessionEnd cannot close a live session (R47)
# ============================================================
# Rewritten for t-0065. R47: a window that adopted the flat id without
# claiming it was invisible to liveness checks, and a reopened old
# conversation (B) in the same checkout resolved A's id too; its SessionEnd
# sealed A's branch. Now A and B have their own Claude Code ids, so B's
# SessionEnd is about B only.

tap_section "L4.16: a second process's SessionEnd cannot close another live session (R47)"

setup_hook_sandbox
SB="$(get_sandbox)"
rm -f "$SB/.claude/.session-id" "$SB"/.claude/.session-id.* "$SB"/.claude/.state/sessions/*.yaml 2>/dev/null || true

A_SID="live-session-a-20261026"
A_DIR="$SB/.claude/.state/wt-sessions/$A_SID"
mkdir -p "$A_DIR"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf 'session_type: standard\nsession_id: %s\nsession_log_id: %s\nmode: review\ncurrent_phase: build\ncycle: 1\nphases_completed: init,drift-check,plan,approval\nsolo: false\ntag: agent\ntimestamp: %s\n' \
  "$A_SID" "$A_SID" "$ts" > "$A_DIR/phase-state"
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
(cd "$SB" && git checkout -q -b fix/r47-live-branch 2>/dev/null) || true
R47_BRANCH=$(cd "$SB" && git rev-parse --abbrev-ref HEAD)

sleep 60 & PID_A=$!
create_fake_session "$A_SID" "standard" "$R47_BRANCH" "$PID_A"

# B, a different process with its own Claude Code id, ends its session.
(
  export CLAUDE_CODE_SESSION_ID="b-harness-uuid"
  run_hook_rc "session-close-check.sh" '{"hook_event_name":"SessionEnd","session_id":"b-harness-uuid"}' >/dev/null 2>&1 || true
)

assert_file_exists "$A_DIR/phase-state" "B's SessionEnd leaves A's phase-state in place"
assert_file_exists "$SB/.claude/.state/sessions/$A_SID.yaml" "B's SessionEnd leaves A's registry record in place"
if grep -qxF "$R47_BRANCH" "$SB/.claude/local/closed-branches" 2>/dev/null; then
  _tap_fail "B's SessionEnd does not seal A's branch" "$R47_BRANCH was recorded in closed-branches"
else
  _tap_pass "B's SessionEnd does not seal A's branch"
fi

export CLAUDE_CODE_SESSION_ID="$A_SID"
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
assert_eq "$(get_session_id "$SB")" "$A_SID" "A still resolves its own id after B's SessionEnd"

kill "$PID_A" 2>/dev/null || true; wait "$PID_A" 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
teardown_sandbox

# ============================================================
# L4.17 — A session id cannot steer the registry record out of its directory
# ============================================================
# register_session, release_branch_claim and unregister_session build the record
# path from the session id. An id carrying / or .. must land, be found and be
# removed inside .claude/.state/sessions, like the state dir and control record.

tap_section "L4.17: registry record paths sanitise the session id"

_l417_records() { # -> the registry records, one per line
  local f
  for f in "$SB"/.claude/.state/sessions/*.yaml; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
  return 0
}

setup_sandbox
SB="$(get_sandbox)"
rm -f "$SB/.claude/.session-id" "$SB"/.claude/.state/sessions/*.yaml 2>/dev/null || true
mkdir -p "$SB/.claude/.state/sessions"

export CLAUDE_CODE_SESSION_ID="../../escape-sid"
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
register_session standard 2>/dev/null || true
assert_file_not_exists "$SB/.claude/escape-sid.yaml" "register_session does not write outside the registry dir"
_l417_rec=$(_l417_records)
assert_eq "$(printf '%s' "$_l417_rec" | grep -c .)" "1" "register_session writes one record inside the registry dir"

# Its readers compare record names against the same sanitised id, so the
# session does not see its own record as another session on its branch.
_l417_rc=0
is_session_active "$(get_branch)" 2>/dev/null || _l417_rc=$?
assert_fail "$_l417_rc" "is_session_active does not count the session's own record"
_SESSION_OVERLAP_CHECKED=false
_l417_rc=0
check_session_overlap 2>/dev/null || _l417_rc=$?
assert_ok "$_l417_rc" "check_session_overlap does not block on the session's own record"

release_branch_claim 2>/dev/null || true
assert_eq "$(grep -c '^branch_claim: released$' "$_l417_rec" 2>/dev/null || true)" "1" \
  "release_branch_claim marks that same record"

unregister_session 2>/dev/null || true
assert_eq "$(_l417_records | grep -c . || true)" "0" "unregister_session removes that same record"

unset CLAUDE_CODE_SESSION_ID
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
teardown_sandbox

# ============================================================
# L4.18 — The id encoding is one-to-one, and every copy of it agrees
# ============================================================
# _safe_sid percent-encodes % / and ., so no two ids share a registry record or
# state dir, and real ids (UUIDs, daemon-<date>-<n>) are unchanged. The close
# hook's fast path runs before the helpers are sourced and carries its own copy
# (_zc_safe_sid); it must produce the same names. Names read back from the
# registry or wt-sessions are encoded, so the sweep's liveness test must compare
# encoded ids or it deletes a live session's state.

tap_section "L4.18: one-to-one id encoding — no collisions, copies agree, sweep keeps a live encoded id"

assert_eq "$(_safe_sid "6f1e2d3c-aaaa-bbbb-cccc-0123456789ab")" "6f1e2d3c-aaaa-bbbb-cccc-0123456789ab" "a UUID maps to itself"
assert_eq "$(_safe_sid "daemon-20261112-101500-1234")" "daemon-20261112-101500-1234" "a daemon id maps to itself"
_l418_ab="$(_safe_sid "a/b")"
assert_eq "$([ "$_l418_ab" != "$(_safe_sid "a_b")" ] && echo distinct)" "distinct" "a/b and a_b get different names"
assert_eq "$([ "$(_safe_sid "%2F")" != "$(_safe_sid "/")" ] && echo distinct)" "distinct" "a literal %2F and / get different names"
assert_eq "$([ "$(_safe_sid "..")" != "$(_safe_sid "__")" ] && echo distinct)" "distinct" ".. and __ get different names"
case "$(_safe_sid "../x/..")" in
  */*|*.*) _tap_fail "an encoded name holds no / or ." "got: $(_safe_sid "../x/..")" ;;
  *) _tap_pass "an encoded name holds no / or ." ;;
esac

# The close hook's copy, extracted as written.
eval "$(sed -n '/^_zc_safe_sid() {/,/^}/p' "$HOOKS_DIR/session-close-check.sh")"
if type _zc_safe_sid >/dev/null 2>&1; then
  _l418_diff=""
  for _l418_id in "a/b" "a_b" ".." "%2F" "a.b" "../../x" "%" "6f1e2d3c-aaaa"; do
    [ "$(_zc_safe_sid "$_l418_id")" = "$(_safe_sid "$_l418_id")" ] || _l418_diff="$_l418_diff $_l418_id"
  done
  assert_eq "$_l418_diff" "" "the close hook's fast-path encoding matches _safe_sid"
else
  _tap_fail "the close hook's fast-path encoding matches _safe_sid" "_zc_safe_sid not found in session-close-check.sh"
fi

# Two sessions whose ids collided under the old mapping keep separate records.
setup_sandbox
SB="$(get_sandbox)"
rm -f "$SB/.claude/.session-id" "$SB"/.claude/.state/sessions/*.yaml 2>/dev/null || true
mkdir -p "$SB/.claude/.state/sessions"
for _l418_id in "a/b" "a_b"; do
  export CLAUDE_CODE_SESSION_ID="$_l418_id"
  _CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
  register_session standard 2>/dev/null || true
done
_l418_n=0
for _l418_f in "$SB"/.claude/.state/sessions/*.yaml; do
  [ -f "$_l418_f" ] && _l418_n=$((_l418_n + 1))
done
assert_eq "$_l418_n" "2" "a/b and a_b register two separate records"

# A live session with such an id keeps its state dir through the sweep, even
# with no registry record (the orphaned-state-dir loop's liveness test).
rm -f "$SB"/.claude/.state/sessions/*.yaml 2>/dev/null || true
export CLAUDE_CODE_SESSION_ID="x/y"
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
_l418_dir="$SB/.claude/.state/wt-sessions/$(_safe_sid "x/y")"
mkdir -p "$_l418_dir"
echo "session_id: x/y" > "$_l418_dir/phase-state"
sweep_stale_sessions 2>/dev/null || true
assert_file_exists "$_l418_dir/phase-state" "a live session whose id needs encoding keeps its state through the sweep"

unset CLAUDE_CODE_SESSION_ID
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
teardown_sandbox

# ============================================================
# Summary
# ============================================================
finish_tests
