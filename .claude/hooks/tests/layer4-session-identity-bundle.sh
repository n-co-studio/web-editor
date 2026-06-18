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
# L4.3 — First-writer-wins on .session-id (fix for editor-live identity drift)
# ============================================================
# Inverts the write-through behaviour 9b6ec01 introduced: the on-disk
# .session-id is the durable identity once written and must win over a rotated
# harness stdin SID (otherwise a context-window UUID rotation churns the
# per-session state dir / log filename mid-session). Cross-session bleed is now
# prevented by close-gated deletion of .session-id, not by overwriting it.

tap_section "L4.3: First-writer-wins — durable .session-id beats a rotated stdin SID"

setup_sandbox
SB="$(get_sandbox)"

# Case A: a durable .session-id exists — file wins, stdin SID does NOT overwrite.
PRIOR_SID="prior-session-20260608-111111"
echo "$PRIOR_SID" > "$SB/.claude/.session-id"
_CACHED_SESSION_ID=""
export _REPO_OS_STDIN_SID="rotated-harness-session-20260608-222222"
RESOLVED_SID=$(get_session_id "$SB" 2>/dev/null)
assert_eq "$RESOLVED_SID" "$PRIOR_SID" "get_session_id returns durable file id, not the rotated stdin sid"
assert_neq "$RESOLVED_SID" "$_REPO_OS_STDIN_SID" "rotated stdin sid does not override the durable identity"
FILE_SID=$(cat "$SB/.claude/.session-id" 2>/dev/null)
assert_eq "$FILE_SID" "$PRIOR_SID" ".session-id file is NOT overwritten when a different stdin sid arrives"

# Advisory gate: the mismatch warning is debug-gated (REPO_OS_DEBUG). The
# mismatch is benign (file wins), so it must be SILENT by default to avoid a
# per-turn stderr nag, and surface only under REPO_OS_DEBUG=1. (.session-id is
# still PRIOR_SID and _REPO_OS_STDIN_SID still differs from Case A.)
_CACHED_SESSION_ID=""
STDERR_DEFAULT=$(get_session_id "$SB" 2>&1 >/dev/null)
case "$STDERR_DEFAULT" in
  *"session-id mismatch"*) _tap_fail "mismatch advisory silent by default (no REPO_OS_DEBUG)" "got: $STDERR_DEFAULT" ;;
  *)                       _tap_pass "mismatch advisory silent by default (no REPO_OS_DEBUG)" ;;
esac
_CACHED_SESSION_ID=""
export REPO_OS_DEBUG=1
STDERR_DEBUG=$(get_session_id "$SB" 2>&1 >/dev/null)
unset REPO_OS_DEBUG
case "$STDERR_DEBUG" in
  *"session-id mismatch"*) _tap_pass "mismatch advisory surfaces under REPO_OS_DEBUG=1" ;;
  *)                       _tap_fail "mismatch advisory surfaces under REPO_OS_DEBUG=1" "got: $STDERR_DEBUG" ;;
esac

# Case B: no durable file yet — the hook is the first initializer, so the stdin
# SID seeds the file (bootstrap path; e.g. first turn after a clean prior close).
rm -f "$SB/.claude/.session-id"
_CACHED_SESSION_ID=""
export _REPO_OS_STDIN_SID="bootstrap-session-20260608-333333"
BOOT_SID=$(get_session_id "$SB" 2>/dev/null)
assert_eq "$BOOT_SID" "bootstrap-session-20260608-333333" "get_session_id seeds id from stdin sid when .session-id is absent"
BOOT_FILE=$(cat "$SB/.claude/.session-id" 2>/dev/null)
assert_eq "$BOOT_FILE" "bootstrap-session-20260608-333333" "stdin sid written through to .session-id only when absent"

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
# Summary
# ============================================================
finish_tests
