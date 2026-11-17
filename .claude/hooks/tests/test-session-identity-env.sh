#!/usr/bin/env bash
# Session identity from Claude Code's environment (Decision t-0065).
#
# Every case is a way one session's id has reached another through files in
# the checkout (R47, R48, child GT-8), replayed with the id Claude Code actually
# provides: CLAUDE_CODE_SESSION_ID and CLAUDE_PID, set for hooks and for the
# agent's own shell. Cases marked "guard" also pass on the pre-t-0065 code; they
# pin behaviour that must not regress, not the fix.
#
# test-helpers.sh clears the operator's own CLAUDE_CODE_SESSION_ID/CLAUDE_PID;
# each case below sets them explicitly.
#
# Bash 3.2 compatible. Requires: jq (hook runs parse stdin).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/test-helpers.sh"
# shellcheck disable=SC1091
source "$HOOKS_DIR/_cleanup-helper.sh"

# Count identity files in the sandbox checkout: the flat file and every sidecar.
_identity_files() {
  local n=0 f
  for f in "$1/.claude/.session-id" "$1"/.claude/.session-id.*; do
    [ -f "$f" ] && n=$((n + 1))
  done
  echo "$n"
}

_clear_identity_env() {
  unset CLAUDE_CODE_SESSION_ID CLAUDE_PID _REPO_OS_STDIN_SID _REPO_OS_DURABLE_PID REPO_OS_SESSION_ID 2>/dev/null || true
  _CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
}

_phase_state() { # dir sid phase
  mkdir -p "$1"
  printf 'session_type: standard\nsession_id: %s\nsession_log_id: %s\nmode: auto\ncurrent_phase: %s\ncycle: 1\nphases_completed: init,drift-check\nsolo: false\ntag: agent\ntimestamp: %s\n' \
    "$2" "$2" "$3" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$1/phase-state"
}

# ============================================================
tap_section "E1: the harness clears the operator's own session (no suite sees it)"
# ============================================================
assert_eq "${CLAUDE_CODE_SESSION_ID:-<unset>}" "<unset>" "CLAUDE_CODE_SESSION_ID is cleared by test-helpers.sh"
assert_eq "${CLAUDE_PID:-<unset>}" "<unset>" "CLAUDE_PID is cleared by test-helpers.sh"

# ============================================================
tap_section "E2: resolution order — env beats stdin, the flat file and a legacy sidecar"
# ============================================================
setup_sandbox
SB="$(get_sandbox)"
sleep 60 & PID_E2=$!
echo "stale-flat-other-window" > "$SB/.claude/.session-id"
echo "stale-sidecar-other-window" > "$SB/.claude/.session-id.$PID_E2"
_clear_identity_env
export CLAUDE_CODE_SESSION_ID="env-sess-e2"
export CLAUDE_PID="$PID_E2"
export _REPO_OS_DURABLE_PID="$PID_E2"
export _REPO_OS_STDIN_SID="stdin-different-e2"
assert_eq "$(get_session_id "$SB")" "env-sess-e2" "env id wins over a different stdin id, a stale flat file and a stale legacy sidecar"
unset _REPO_OS_STDIN_SID
_CACHED_SESSION_ID=""
assert_eq "$(get_session_id "$SB")" "env-sess-e2" "agent shell (env, no stdin) resolves the env id, not the flat file (R48 a)"
assert_eq "$(cat "$SB/.claude/.session-id")" "stale-flat-other-window" "the flat file is not rewritten"
assert_eq "$(cat "$SB/.claude/.session-id.$PID_E2")" "stale-sidecar-other-window" "the legacy sidecar is not rewritten"
export REPO_OS_SESSION_ID="daemon-brief-e2"
_CACHED_SESSION_ID=""
assert_eq "$(get_session_id "$SB")" "daemon-brief-e2" "guard: REPO_OS_SESSION_ID still beats CLAUDE_CODE_SESSION_ID (daemon started from a Claude Code shell)"
kill "$PID_E2" 2>/dev/null || true; wait "$PID_E2" 2>/dev/null || true
_clear_identity_env
teardown_sandbox

# ============================================================
tap_section "E3: nothing inside Claude Code writes an identity file"
# ============================================================
setup_sandbox
SB="$(get_sandbox)"
rm -f "$SB/.claude/.session-id" "$SB"/.claude/.session-id.* 2>/dev/null || true
sleep 60 & PID_E3=$!
_clear_identity_env
export CLAUDE_CODE_SESSION_ID="env-sess-e3"
export CLAUDE_PID="$PID_E3"
export _REPO_OS_DURABLE_PID="$PID_E3"
export _REPO_OS_STDIN_SID="env-sess-e3"
get_session_id "$SB" >/dev/null
_sd=$(get_session_state_dir)
log_hook_event "test-hook" "Stop" "" "allow" "0" "telemetry_probe" || true
log_kpi_event "kpi" "metric" "probe" "" || true
assert_eq "$(_identity_files "$SB")" "0" "resolution, state-dir lookup and telemetry create no .session-id or sidecar (GT-8, R48 d)"
assert_eq "$_sd" "$SB/.claude/.state/wt-sessions/env-sess-e3" "the state dir is keyed on the env id"
# Old Claude Code: stdin only, no env.
_clear_identity_env
export _REPO_OS_DURABLE_PID="$PID_E3"
export _REPO_OS_STDIN_SID="stdin-only-e3"
assert_eq "$(get_session_id "$SB")" "stdin-only-e3" "without the env var a hook uses its stdin id"
assert_eq "$(_identity_files "$SB")" "0" "the stdin path writes no identity file either"
kill "$PID_E3" 2>/dev/null || true; wait "$PID_E3" 2>/dev/null || true
_clear_identity_env
teardown_sandbox

# ============================================================
tap_section "E4: GT-8 — a SessionEnd leaves nothing a later session can inherit"
# ============================================================
setup_hook_sandbox
SB="$(get_sandbox)"
rm -f "$SB/.claude/.session-id" "$SB"/.claude/.session-id.* "$SB"/.claude/.state/sessions/*.yaml 2>/dev/null || true
sleep 60 & PID_A4=$!
_clear_identity_env
A4_DIR="$SB/.claude/.state/wt-sessions/ended-sess-a"
_phase_state "$A4_DIR" "ended-sess-a" "build"
echo "0000000000000000000000000000000000000000" > "$SB/.claude/.session-baseline-sha"
(
  export CLAUDE_CODE_SESSION_ID="ended-sess-a" CLAUDE_PID="$PID_A4" _REPO_OS_DURABLE_PID="$PID_A4"
  run_hook_rc "session-close-check.sh" '{"hook_event_name":"SessionEnd","session_id":"ended-sess-a","reason":"prompt_input_exit"}' >/dev/null 2>&1 || true
)
assert_eq "$(_identity_files "$SB")" "0" "A's SessionEnd leaves no .session-id or sidecar behind"
kill "$PID_A4" 2>/dev/null || true; wait "$PID_A4" 2>/dev/null || true
sleep 60 & PID_B4=$!
export CLAUDE_CODE_SESSION_ID="next-sess-b" CLAUDE_PID="$PID_B4" _REPO_OS_DURABLE_PID="$PID_B4" _REPO_OS_STDIN_SID="next-sess-b"
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
assert_eq "$(get_session_id "$SB")" "next-sess-b" "the next conversation resolves its own id, not the ended one"
kill "$PID_B4" 2>/dev/null || true; wait "$PID_B4" 2>/dev/null || true
_clear_identity_env
teardown_sandbox

# ============================================================
tap_section "E5: two windows in one checkout"
# ============================================================
setup_hook_sandbox
SB="$(get_sandbox)"
rm -f "$SB/.claude/.session-id" "$SB"/.claude/.session-id.* "$SB"/.claude/.state/sessions/*.yaml 2>/dev/null || true
sleep 60 & PID_WA=$!
sleep 60 & PID_WB=$!
_clear_identity_env
export CLAUDE_CODE_SESSION_ID="win-a" CLAUDE_PID="$PID_WA" _REPO_OS_DURABLE_PID="$PID_WA" _REPO_OS_STDIN_SID="win-a"
SID_WA=$(get_session_id "$SB"); SD_WA=$(get_session_state_dir)
export CLAUDE_CODE_SESSION_ID="win-b" CLAUDE_PID="$PID_WB" _REPO_OS_DURABLE_PID="$PID_WB" _REPO_OS_STDIN_SID="win-b"
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
SID_WB=$(get_session_id "$SB"); SD_WB=$(get_session_state_dir)
assert_eq "$SID_WA/$SID_WB" "win-a/win-b" "each window resolves its own id"
assert_neq "$SD_WA" "$SD_WB" "each window has its own state dir"
_phase_state "$SD_WA" "win-a" "build"
(
  export CLAUDE_CODE_SESSION_ID="win-b" CLAUDE_PID="$PID_WB" _REPO_OS_DURABLE_PID="$PID_WB"
  run_hook_rc "session-close-check.sh" '{"hook_event_name":"SessionEnd","session_id":"win-b","reason":"prompt_input_exit"}' >/dev/null 2>&1 || true
)
assert_file_exists "$SD_WA/phase-state" "B's SessionEnd leaves A's phase-state alone"
export CLAUDE_CODE_SESSION_ID="win-a" CLAUDE_PID="$PID_WA" _REPO_OS_DURABLE_PID="$PID_WA" _REPO_OS_STDIN_SID="win-a"
_CACHED_SESSION_ID=""
assert_eq "$(get_session_id "$SB")" "win-a" "A still resolves A after B's SessionEnd"
assert_eq "$(_identity_files "$SB")" "0" "neither window wrote an identity file"
kill "$PID_WA" "$PID_WB" 2>/dev/null || true; wait "$PID_WA" 2>/dev/null || true; wait "$PID_WB" 2>/dev/null || true
_clear_identity_env
teardown_sandbox

# ============================================================
tap_section "E6: write-guard and state-writer resolve the env id, not the flat file"
# ============================================================
setup_hook_sandbox
SB="$(get_sandbox)"
rm -f "$SB"/.claude/.session-id.* "$SB"/.claude/.state/sessions/*.yaml 2>/dev/null || true
echo "other-window-no-state" > "$SB/.claude/.session-id"
sleep 60 & PID_E6=$!
_clear_identity_env
E6_DIR="$SB/.claude/.state/wt-sessions/env-sess-e6"
_phase_state "$E6_DIR" "env-sess-e6" "plan"
(
  export CLAUDE_CODE_SESSION_ID="env-sess-e6" CLAUDE_PID="$PID_E6" _REPO_OS_DURABLE_PID="$PID_E6"
  # A template-mode carve-out path, so the mode guard lets it through to the
  # phase check (src/ is a product path here and would stop earlier).
  run_hook_rc "write-guard.sh" "$(fixture_pretooluse_edit "$SB/.claude/hooks/probe.sh")" > "$SB/wg.out" 2>&1 || true
)
if grep -q "No phase-state" "$SB/wg.out" 2>/dev/null; then
  _tap_fail "write-guard finds this session's phase-state through the env id (R48 b)" "$(head -c 200 "$SB/wg.out")"
else
  _tap_pass "write-guard finds this session's phase-state through the env id (R48 b)"
fi
(
  export CLAUDE_CODE_SESSION_ID="env-sess-e6" CLAUDE_PID="$PID_E6" _REPO_OS_DURABLE_PID="$PID_E6"
  run_hook_rc "state-writer.sh" "$(fixture_subagentstop pragmatist "Plan review.
GATE_RESULT: APPROVED")" >/dev/null 2>&1 || true
)
assert_file_exists "$E6_DIR/pragmatist-signed" "state-writer writes the verdict into the env id's dir"
assert_eq "$(grep '^session_id:' "$E6_DIR/pragmatist-signed" 2>/dev/null | sed 's/^session_id: *//')" "env-sess-e6" \
  "state-writer stamps the same id as the dir it writes to (the mislabelled pragmatist-signed)"
assert_eq "$(cat "$SB/.claude/.session-id")" "other-window-no-state" "neither hook rewrote the flat file"
kill "$PID_E6" 2>/dev/null || true; wait "$PID_E6" 2>/dev/null || true
_clear_identity_env
teardown_sandbox

# ============================================================
tap_section "E7: liveness comes from the registry's claude pid"
# ============================================================
setup_sandbox
SB="$(get_sandbox)"
rm -f "$SB/.claude/.session-id" "$SB"/.claude/.session-id.* 2>/dev/null || true
mkdir -p "$SB/.claude/.state/sessions"
sleep 60 & PID_E7=$!
_clear_identity_env
export CLAUDE_PID="$PID_E7"
assert_eq "$(_resolve_durable_pid)" "$PID_E7" "_resolve_durable_pid prefers CLAUDE_PID (the claude process, not a tool shell)"
# A daemon started from a Claude Code shell inherits the operator's CLAUDE_PID;
# a headless brief must not be registered under it.
export REPO_OS_SESSION_ID="brief-under-daemon"
assert_neq "$(_resolve_durable_pid)" "$PID_E7" "inside a headless brief an inherited CLAUDE_PID is not the brief's pid"
_clear_identity_env
# A live session with no sidecar: its registry pid is the decisive signal.
LIVE_DIR="$SB/.claude/.state/wt-sessions/live-no-sidecar"
_phase_state "$LIVE_DIR" "live-no-sidecar" "build"
printf 'session_id: live-no-sidecar\nsession_type: standard\nbranch: feature/x\npid: %s\nstarted_at: %s\n' \
  "$PID_E7" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SB/.claude/.state/sessions/live-no-sidecar.yaml"
# A dead session with no sidecar is still reaped.
dead_pid=99999; while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid - 1)); done
DEAD_DIR="$SB/.claude/.state/wt-sessions/dead-sess"
_phase_state "$DEAD_DIR" "dead-sess" "build"
printf 'session_id: dead-sess\nsession_type: standard\nbranch: feature/y\npid: %s\nstarted_at: %s\n' \
  "$dead_pid" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SB/.claude/.state/sessions/dead-sess.yaml"
sweep_stale_sessions "" 2>/dev/null || true
assert_file_not_exists "$SB/.claude/.state/sessions/dead-sess.yaml" "guard: a session whose claude pid is dead loses its registry entry"
if [ -d "$DEAD_DIR" ]; then _tap_fail "guard: and its state dir is reaped"; else _tap_pass "guard: and its state dir is reaped"; fi
assert_file_exists "$LIVE_DIR/phase-state" "guard: a live registry pid keeps its state through the same sweep, with no sidecar"
# peek_session_id: "no session" stays empty and writes nothing (pre-commit-gates'
# skip-validation path depends on it).
_clear_identity_env
rm -f "$SB/.claude/.session-id" 2>/dev/null || true
assert_eq "$(peek_session_id "$SB")" "" "peek_session_id is empty when there is no session"
assert_eq "$(_identity_files "$SB")" "0" "peek_session_id mints and writes nothing"
export CLAUDE_CODE_SESSION_ID="peek-env"
assert_eq "$(peek_session_id "$SB")" "peek-env" "peek_session_id follows the same order as get_session_id"
kill "$PID_E7" 2>/dev/null || true; wait "$PID_E7" 2>/dev/null || true
_clear_identity_env
teardown_sandbox

# ============================================================
tap_section "E8: the Stop safety valve releases the branch claim, not the session"
# ============================================================
setup_hook_sandbox
SB="$(get_sandbox)"
rm -f "$SB/.claude/.session-id" "$SB"/.claude/.session-id.* "$SB"/.claude/.state/sessions/*.yaml 2>/dev/null || true
mkdir -p "$SB/.claude/.state/sessions"
E8_BRANCH=$(cd "$SB" && git rev-parse --abbrev-ref HEAD)
sleep 60 & PID_VA=$!
sleep 60 & PID_VB=$!
_clear_identity_env
VA_DIR="$SB/.claude/.state/wt-sessions/valve-a"
_phase_state "$VA_DIR" "valve-a" "build"
printf 'session_id: valve-a\nsession_type: standard\nbranch: %s\npid: %s\nstarted_at: %s\n' \
  "$E8_BRANCH" "$PID_VA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SB/.claude/.state/sessions/valve-a.yaml"
export CLAUDE_CODE_SESSION_ID="valve-a" CLAUDE_PID="$PID_VA" _REPO_OS_DURABLE_PID="$PID_VA"
if type release_branch_claim >/dev/null 2>&1; then
  release_branch_claim 2>/dev/null || true
  _tap_pass "release_branch_claim exists"
else
  _tap_fail "release_branch_claim exists" "the valve has no claim-only release"
fi
assert_file_exists "$SB/.claude/.state/sessions/valve-a.yaml" "the released session keeps its registry record (its liveness signal)"
assert_file_contains "$SB/.claude/.state/sessions/valve-a.yaml" "branch_claim: released" "the record is marked released"
assert_file_contains "$SB/.claude/.state/sessions/valve-a.yaml" "branch: $E8_BRANCH" "the real branch stays on the record (group sweep and overlap report read it)"
# Session B on the same branch is not blocked by A's released claim.
export CLAUDE_CODE_SESSION_ID="valve-b" CLAUDE_PID="$PID_VB" _REPO_OS_DURABLE_PID="$PID_VB"
_CACHED_SESSION_ID=""; _CACHED_SESSION_STATE_DIR=""
_SESSION_OVERLAP_CHECKED=false
_phase_state "$SB/.claude/.state/wt-sessions/valve-b" "valve-b" "build"
# get_branch reads the CWD's branch, so run the overlap checks from the sandbox.
_rc=0; (cd "$SB" && check_session_overlap) 2>/dev/null || _rc=$?
assert_eq "$_rc" "0" "check_session_overlap ignores a released claim"
if is_session_active "$E8_BRANCH"; then
  _tap_fail "is_session_active ignores a released claim"
else
  _tap_pass "is_session_active ignores a released claim"
fi
_reg_err=$(cd "$SB" && register_session standard 2>&1 >/dev/null || true)
case "$_reg_err" in
  *valve-a*) _tap_fail "register_session's overlap advisory ignores a released claim" "$_reg_err" ;;
  *) _tap_pass "register_session's overlap advisory ignores a released claim" ;;
esac
sweep_stale_sessions "valve-b" 2>/dev/null || true
assert_file_exists "$VA_DIR/phase-state" "the released, still-live session keeps its state through a sweep"
export CLAUDE_CODE_SESSION_ID="valve-a" CLAUDE_PID="$PID_VA" _REPO_OS_DURABLE_PID="$PID_VA"
_CACHED_SESSION_ID=""
assert_eq "$(get_session_id "$SB")" "valve-a" "the released session still resolves its own id (R48 d)"
kill "$PID_VA" "$PID_VB" 2>/dev/null || true; wait "$PID_VA" 2>/dev/null || true; wait "$PID_VB" 2>/dev/null || true
_clear_identity_env
teardown_sandbox

# ============================================================
tap_section "E9: no reader bypasses get_session_id with the flat file"
# ============================================================
# Static: these readers run inside hooks where the behavioural cases above
# cannot reach every branch (pre-commit-gates' validation needs a full commit
# fixture). A flat-file read here is how the stamp/dir split happened.
# Comments are stripped first, so a mention in prose cannot satisfy a check.
_code() { grep -v '^[[:space:]]*#' "$@" 2>/dev/null || true; }
_hits=$(_code "$HOOKS_DIR/state-writer.sh" "$HOOKS_DIR/pre-commit-gates.sh" | grep -n '\.claude/\.session-id' || true)
assert_eq "$_hits" "" "state-writer and pre-commit-gates read no flat .session-id directly"
_valve=$(_code "$HOOKS_DIR/session-close-check.sh" | awk '/STOP_ATTEMPT" -ge 3/{f=1} f&&/^fi$/{exit} f')
if printf '%s\n' "$_valve" | grep -q '^[[:space:]]*release_branch_claim[[:space:]]'; then
  _tap_pass "the Stop safety valve calls release_branch_claim"
else
  _tap_fail "the Stop safety valve calls release_branch_claim"
fi
if printf '%s\n' "$_valve" | grep -q 'unregister_session'; then
  _tap_fail "the Stop safety valve no longer unregisters the session"
else
  _tap_pass "the Stop safety valve no longer unregisters the session"
fi
_fast=$(_code "$HOOKS_DIR/session-close-check.sh" | grep '_ZC_' || true)
case "$_fast" in
  *CLAUDE_CODE_SESSION_ID*) _tap_pass "the close-check fast path resolves CLAUDE_CODE_SESSION_ID first" ;;
  *) _tap_fail "the close-check fast path resolves CLAUDE_CODE_SESSION_ID first" ;;
esac
case "$_fast" in
  *'.session-id.$'*) _tap_fail "the close-check fast path no longer reads a sidecar" ;;
  *) _tap_pass "the close-check fast path no longer reads a sidecar" ;;
esac

finish_tests
