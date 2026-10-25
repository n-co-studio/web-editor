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
# L4.9 — Foreign-state guard: an interactive Stop must not enforce a
#         CONCURRENT session's close (identity-churn safety)
# ============================================================
# When two sessions share the repo-global .claude/.session-id (a concurrent
# headless/daemon build, or a second interactive window on the same checkout),
# an interactive Stop can resolve via that shared file to the OTHER session's
# phase-state. session-close-check.sh must NOT run close enforcement (session-log
# demand / uncommitted block) against a foreign session owned by a DIFFERENT,
# independently-live process. Discriminator vs. a legitimate context-window
# turnover: register_session() records the durable claude PID ($PPID), so a
# turned-over session's resolved state has registry pid == our $PPID (skip NOT
# taken); only a different live pid trips the guard. A dead/orphaned foreign
# owner is intentionally not caught (falls through to normal enforcement).

tap_section "L4.9: Foreign-state guard — live-foreign close skipped, orphan still enforced"

# --- L4.9a — Foreign state owned by a different LIVE process => guard skips ---
setup_hook_sandbox
SB="$(get_sandbox)"

FSID="foreign-session-20260617-000001"
echo "$FSID" > "$SB/.claude/.session-id"
# Craft the foreign session's per-session phase-state in a CLOSING standard state
# (review completed, no session log) — WITHOUT the guard this blocks on the
# session-log check.
FS_DIR="$SB/.claude/.state/wt-sessions/$FSID"
mkdir -p "$FS_DIR"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf 'session_type: standard\nsession_id: %s\nsession_log_id: %s\nmode: review\ncurrent_phase: review\ncycle: 1\nphases_completed: init,build,review\nsolo: false\ntag: agent\ntimestamp: %s\n' \
  "$FSID" "$FSID" "$ts" > "$FS_DIR/phase-state"
# Non-zero baseline so the zero-change fast path does not pre-empt the guard.
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
# Foreign owner: a real, live process whose PID is not the hook's PPID.
sleep 60 &
FS_LIVE_PID=$!
create_fake_session "$FSID" "standard" "feature/test" "$FS_LIVE_PID"

# Confirm the sandbox resolves the per-session dir for this sid (so the hook reads
# the crafted phase-state, not the flat backward-compat path) — otherwise the
# guard's outer condition would be false and the test could pass vacuously.
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
assert_eq "$(get_session_state_dir)" "$FS_DIR" "per-session dir resolves for the foreign sid (guard reads crafted phase-state)"

# Live stdin sid differs from the resolved (foreign) state's session_id.
run_hook_rc "session-close-check.sh" "$(fixture_stop "live-stdin-uuid-aaaa")" >/dev/null 2>&1 || true
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

# --- L4.9b — Orphaned foreign state (owner DEAD) => guard does NOT skip ---
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
# Dead owner PID — guard must fall through to normal close enforcement.
create_fake_session "$OSID" "standard" "feature/test" "99999999"

# Same resolution guard as L4.9a — rule out a vacuous pass on the flat path.
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
assert_eq "$(get_session_state_dir)" "$OS_DIR" "per-session dir resolves for the orphan sid (guard reads crafted phase-state)"

run_hook_rc "session-close-check.sh" "$(fixture_stop "live-stdin-uuid-bbbb")" >/dev/null 2>&1 || true
case "$_LAST_OUTPUT" in
  *"Session log not updated"*)
    _tap_pass "dead-owner orphan is NOT skipped (close enforcement still fires)" ;;
  *)
    _tap_fail "dead-owner orphan is NOT skipped (close enforcement still fires)" "expected session-log block, got: $_LAST_OUTPUT" ;;
esac
teardown_sandbox

# --- L4.9c — Turnover discriminator (unit): registry pid == our PID -> not foreign ---
# run_hook_rc runs the hook inside $( ( ... | bash hook ) ), so the hook's $PPID
# is an ephemeral subshell that the test cannot predict — the PPID discriminator
# therefore can't be exercised through the full hook. Verify it as a unit
# mirroring the guard's exact boolean, with $$ standing in for the hook's $PPID.
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

# ============================================================
# L4.10 — Concurrent processes resolve to DISTINCT ids and state dirs
# ============================================================
# Two claude processes in one checkout must NOT alias. Each has a distinct
# durable pid (injected via _REPO_OS_DURABLE_PID — the hook harness gives real
# hooks an ephemeral $PPID, so the per-process path is unit-tested by injection).
# Process A bootstraps (writes its sidecar + the shared flat .session-id); a
# concurrent process B, seeing A's flat id claimed by A's LIVE sidecar, mints its
# own distinct id instead of adopting. Asserts get_session_state_dir() differs —
# the core property the brief requires.

tap_section "L4.10: Concurrent processes — distinct ids and state dirs (per-process identity)"

setup_sandbox
SB="$(get_sandbox)"
rm -f "$SB/.claude/.session-id" "$SB"/.claude/.session-id.* 2>/dev/null || true

# Process A: a live durable pid bootstraps a fresh identity.
sleep 60 & PID_A=$!
export _REPO_OS_DURABLE_PID="$PID_A"
export _REPO_OS_STDIN_SID="winA-uuid-aaaa"
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
SID_A=$(get_session_id "$SB")
SD_A=$(get_session_state_dir)
assert_eq "$SID_A" "winA-uuid-aaaa" "process A bootstraps its id from the harness stdin sid"
assert_file_exists "$SB/.claude/.session-id.$PID_A" "process A writes its per-process identity sidecar"

# Process B: different live durable pid + stdin sid, SAME checkout (shares flat).
sleep 60 & PID_B=$!
export _REPO_OS_DURABLE_PID="$PID_B"
export _REPO_OS_STDIN_SID="winB-uuid-bbbb"
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
SID_B=$(get_session_id "$SB")
SD_B=$(get_session_state_dir)
assert_neq "$SID_B" "$SID_A" "concurrent process B resolves a DIFFERENT id (no aliasing onto A)"
assert_neq "$SD_B" "$SD_A" "concurrent process B resolves a DIFFERENT per-session state dir"
assert_eq "$SID_B" "winB-uuid-bbbb" "process B mints its id from its own stdin sid"

kill "$PID_A" "$PID_B" 2>/dev/null || true
wait "$PID_A" 2>/dev/null || true; wait "$PID_B" 2>/dev/null || true
unset _REPO_OS_DURABLE_PID _REPO_OS_STDIN_SID
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
teardown_sandbox

# ============================================================
# L4.11 — Single process across context-window turnover — STABLE identity
# ============================================================
# The same durable process across a turnover (harness rotates the stdin SID)
# must keep one id and one state dir. The per-process sidecar fast-path makes the
# first-seeded id win regardless of the rotated stdin value. This is the
# turnover-stability half of the requirement (companion to the integration tests
# L4.3/L4.7, which exercise the flat-file path with an unknowable hook $PPID).

tap_section "L4.11: Single process across turnover — stable id and state dir (sidecar fast-path)"

setup_sandbox
SB="$(get_sandbox)"
rm -f "$SB/.claude/.session-id" "$SB"/.claude/.session-id.* 2>/dev/null || true

sleep 60 & PID_T=$!
export _REPO_OS_DURABLE_PID="$PID_T"
export _REPO_OS_STDIN_SID="turn1-uuid"
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
SID_T1=$(get_session_id "$SB"); SD_T1=$(get_session_state_dir)

# Context-window turnover: same durable process, rotated harness stdin SID.
export _REPO_OS_STDIN_SID="turn2-uuid-rotated"
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
SID_T2=$(get_session_id "$SB"); SD_T2=$(get_session_state_dir)

assert_eq "$SID_T2" "$SID_T1" "rotated stdin SID does not churn identity (sidecar fast-path wins)"
assert_eq "$SD_T2" "$SD_T1" "per-session state dir stable across turnover"
assert_eq "$SID_T2" "turn1-uuid" "identity remains the first-seeded id, not the rotated value"

kill "$PID_T" 2>/dev/null || true; wait "$PID_T" 2>/dev/null || true
unset _REPO_OS_DURABLE_PID _REPO_OS_STDIN_SID
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
teardown_sandbox

# ============================================================
# L4.12 — Flat-file resolution: adopt when unowned, mint when a LIVE peer owns it
# ============================================================

tap_section "L4.12: Flat resolution — adopt-when-unowned, mint-on-live-peer, recover-on-dead-peer"

setup_sandbox
SB="$(get_sandbox)"

# Adopt: flat exists, NO sidecars -> adopt the durable flat id (turnover / in-flight
# pre-sidecar session / legacy file). Adoption is cache-only — no sidecar written,
# so the flat-file path that the integration tests depend on is never disturbed.
rm -f "$SB"/.claude/.session-id.* 2>/dev/null || true
echo "durable-flat-id" > "$SB/.claude/.session-id"
sleep 60 & PID_AD=$!
export _REPO_OS_DURABLE_PID="$PID_AD"
export _REPO_OS_STDIN_SID="fresh-stdin-uuid"
_CACHED_SESSION_ID=""
SID_AD=$(get_session_id "$SB")
assert_eq "$SID_AD" "durable-flat-id" "adopts the durable flat id when no live peer claims it"
assert_file_not_exists "$SB/.claude/.session-id.$PID_AD" "adoption is cache-only — writes no sidecar"
kill "$PID_AD" 2>/dev/null || true; wait "$PID_AD" 2>/dev/null || true

# Mint: a DIFFERENT, live process already claims the flat id via its sidecar.
sleep 60 & PID_OWNER=$!
echo "shared-id" > "$SB/.claude/.session-id"
echo "shared-id" > "$SB/.claude/.session-id.$PID_OWNER"
sleep 60 & PID_ME=$!
export _REPO_OS_DURABLE_PID="$PID_ME"
export _REPO_OS_STDIN_SID="my-distinct-uuid"
_CACHED_SESSION_ID=""
SID_ME=$(get_session_id "$SB")
assert_neq "$SID_ME" "shared-id" "mints a distinct id when a live peer already claims the flat id"
assert_eq "$SID_ME" "my-distinct-uuid" "minted id comes from this process's own stdin sid"
assert_file_exists "$SB/.claude/.session-id.$PID_ME" "mint writes this process's sidecar"
kill "$PID_OWNER" "$PID_ME" 2>/dev/null || true
wait "$PID_OWNER" 2>/dev/null || true; wait "$PID_ME" 2>/dev/null || true

# Recover: a sidecar owned by a DEAD pid must NOT force a mint — the orphan flat
# id is adopted (the dead owner is gone; this is recovery, not a concurrent peer).
echo "orphan-id" > "$SB/.claude/.session-id"
echo "orphan-id" > "$SB/.claude/.session-id.99999999"
sleep 60 & PID_REC=$!
export _REPO_OS_DURABLE_PID="$PID_REC"
export _REPO_OS_STDIN_SID="recover-stdin"
_CACHED_SESSION_ID=""
SID_REC=$(get_session_id "$SB")
assert_eq "$SID_REC" "orphan-id" "a dead peer's sidecar does not force a mint — orphan flat id is adopted"
kill "$PID_REC" 2>/dev/null || true; wait "$PID_REC" 2>/dev/null || true

unset _REPO_OS_DURABLE_PID _REPO_OS_STDIN_SID
_CACHED_SESSION_ID=""
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
# L4.14 — unregister_session removes the closing session's sidecar
# ============================================================
# Close must delete this window's sidecar (whose pid is still alive, so the
# dead-pid sweep will not reap it) so the SAME window's next session bootstraps a
# fresh id rather than fast-pathing onto the closed identity.

tap_section "L4.14: unregister_session removes the closing session's sidecar (no same-window id bleed)"

setup_sandbox
SB="$(get_sandbox)"
rm -f "$SB/.claude/.session-id" "$SB"/.claude/.session-id.* 2>/dev/null || true

sleep 60 & PID_U=$!
export _REPO_OS_DURABLE_PID="$PID_U"
export _REPO_OS_STDIN_SID="session-one-uuid"
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
SID_U=$(get_session_id "$SB")
assert_file_exists "$SB/.claude/.session-id.$PID_U" "session sidecar present before close"

unregister_session
assert_file_not_exists "$SB/.claude/.session-id.$PID_U" "unregister_session removes the closing session's sidecar by content-match"

# Same window (same durable pid), next session: with the sidecar (and flat) gone,
# a fresh stdin sid must bootstrap a NEW id — no bleed from the closed session.
rm -f "$SB/.claude/.session-id" 2>/dev/null || true
export _REPO_OS_STDIN_SID="session-two-uuid"
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
SID_U2=$(get_session_id "$SB")
assert_neq "$SID_U2" "$SID_U" "next session in the same window bootstraps a fresh id (no cross-session bleed)"

kill "$PID_U" 2>/dev/null || true; wait "$PID_U" 2>/dev/null || true
unset _REPO_OS_DURABLE_PID _REPO_OS_STDIN_SID
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

export REPO_OS_SESSION_ID="daemon-brief-1"
get_session_id "$SB" > /dev/null
get_session_state_dir > /dev/null
SID_B1="$_CACHED_SESSION_ID"; SD_B1="$_CACHED_SESSION_STATE_DIR"
assert_eq "$SID_B1" "daemon-brief-1" "brief 1 resolves to its own injected id"

export REPO_OS_SESSION_ID="daemon-brief-2"
get_session_id "$SB" > /dev/null
SID_B2="$_CACHED_SESSION_ID"
assert_eq "$SID_B2" "daemon-brief-2" "brief 2 follows the NEW env id despite a populated cache"

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
assert_eq "$_CACHED_SESSION_ID" "daemon-brief-2" "repeat call with an unchanged env id is stable"

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
# Summary
# ============================================================
finish_tests
