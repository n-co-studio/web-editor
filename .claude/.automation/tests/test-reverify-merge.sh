#!/usr/bin/env bash
# Re-verify-before-merge tests — verifies lib/reverify-merge.sh against a git
# fixture, with a stub `claude` standing in for the re-verification session.
# Bash 3.2 compatible.
#
# Cases (one per line of the brief's verification checklist):
#   RV.1: overlap, clean rebase, session passes -> merge as today, reverified=true
#   RV.2: overlap, clean rebase, session fails  -> no merge, escalation names the
#         failing checks, the overlapping files and the main commit
#   RV.3: overlap, rebase conflicts             -> conflict path, files listed,
#         branch ref restored
#   RV.4: no overlap                            -> no rebase, no session at all
#   RV.5: task group                            -> rebase in the group worktree,
#         which is left in place for the remaining briefs
#   RV.6: session exceeds the time cap          -> failure, and the escalation
#         says it timed out
#   RV.7: the gate is called inside the merge lock (structural, on runner.sh)
#   RV.8: reverified / overlap_files round-trip through the queue entry
#
# Why a stub `claude`: the real re-verification session is a `claude -p` run, so
# the only way to drive its PASS / FAIL / timeout branches deterministically —
# and the only way to assert that the no-overlap path starts NO session — is to
# put a scripted executable of that name first on PATH. The stub appends to a
# marker file on every invocation, which is what RV.4 reads.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"
RUNNER_SH="$SCRIPT_DIR/../runner.sh"

# --- TAP counters ---
# No case body runs in a subshell: _reverify_before_merge reports through
# globals (_RESULT_REVERIFIED and friends), and a subshell would discard them.
_TAP_TEST_NUM=0
_TAP_PASS=0
_TAP_FAIL=0

_tap_pass() {
  _TAP_TEST_NUM=$((_TAP_TEST_NUM + 1))
  _TAP_PASS=$((_TAP_PASS + 1))
  printf "ok %d - %s\n" "$_TAP_TEST_NUM" "$1"
}

_tap_fail() {
  _TAP_TEST_NUM=$((_TAP_TEST_NUM + 1))
  _TAP_FAIL=$((_TAP_FAIL + 1))
  printf "not ok %d - %s\n" "$_TAP_TEST_NUM" "$1"
  if [ -n "${2:-}" ]; then
    printf "  # %s\n" "$2"
  fi
}

assert_eq() {
  if [ "$1" = "$2" ]; then
    _tap_pass "$3"
  else
    _tap_fail "$3" "expected '$2', got '$1'"
  fi
}

assert_contains() {
  case "$1" in
    *"$2"*) _tap_pass "$3" ;;
    *)      _tap_fail "$3" "'$2' not found in: $1" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) _tap_fail "$3" "'$2' unexpectedly present in: $1" ;;
    *)      _tap_pass "$3" ;;
  esac
}

# --- Fixture -------------------------------------------------------------
_FIX=""
_GWT=""
_MARKER=""

_fixture_destroy() {
  # Capture first, re-assert last. On bash 3.2 (the floor here) the status of
  # the last command run by an EXIT trap becomes the shell's exit status, so
  # the guarded `rm -rf ... || true` below would rewrite every failure to 0 —
  # including a `set -e` abort before a single TAP line is printed. That is
  # invisible to run-automation-tests.sh, which gates purely on exit code.
  local _rc=$?
  if [ -n "$_FIX" ] && [ -d "$_FIX" ]; then
    # The group worktree lives outside the repo dir and holds a ref in
    # .git/worktrees; prune it first so nothing is left registered.
    git -C "$_FIX" worktree remove --force "$_GWT" > /dev/null 2>&1 || true
    rm -rf "$_FIX" 2>/dev/null || true
  fi
  if [ -n "$_GWT" ] && [ -d "$_GWT" ]; then
    rm -rf "$_GWT" 2>/dev/null || true
  fi
  exit "$_rc"
}
trap _fixture_destroy EXIT

# Branch $1 off main, rewrite line $3 of file $2 to $4, commit, return to main.
_fx_branch() {
  git -C "$_FIX" checkout -q -b "$1" main
  sed -i.bak "${3}s/.*/$4/" "$_FIX/$2"
  rm -f "$_FIX/$2.bak"
  git -C "$_FIX" commit -q -am "$1"
  git -C "$_FIX" checkout -q main
}

_fixture_create() {
  # Deliberately NOT named `repo-os-reverify-*`: that is the prefix the gate's
  # own scratch worktrees use, and several cases assert no such worktree is
  # left registered by grepping `git worktree list` for it. A fixture sharing
  # the prefix would match itself and the assertion would never be able to
  # fail.
  _FIX=$(mktemp -d "${TMPDIR:-/tmp}/repo-os-rvfixture-XXXXXX")
  git -C "$_FIX" init -q
  git -C "$_FIX" config user.email "test@example.com"
  git -C "$_FIX" config user.name "Reverify Test"
  git -C "$_FIX" config commit.gpgsign false

  # 20 lines so a change at line 1 and a change at line 18 are far enough
  # apart that the rebase is textually clean — the point of RV.1/RV.2/RV.5/RV.6
  # is the re-verification verdict, not git's conflict detection.
  printf 'L1\nL2\nL3\nL4\nL5\nL6\nL7\nL8\nL9\nL10\nL11\nL12\nL13\nL14\nL15\nL16\nL17\nL18\nL19\nL20\n' \
    > "$_FIX/shared.txt"
  printf 'C1\nC2\nC3\nC4\nC5\n' > "$_FIX/clash.txt"
  printf 'S1\nS2\nS3\nS4\nS5\n' > "$_FIX/solo.txt"
  git -C "$_FIX" add -A
  git -C "$_FIX" commit -q -m "base"
  # `git init -b main` is git 2.28+; renaming afterwards stays within the
  # git 2.5 tooling floor (AI.md).
  git -C "$_FIX" branch -M main

  _fx_branch feature/pass     shared.txt 20 L20-pass
  _fx_branch feature/fail     shared.txt 19 L19-fail
  _fx_branch feature/group    shared.txt 18 L18-group
  _fx_branch feature/timeout  shared.txt 17 L17-timeout
  _fx_branch feature/conflict clash.txt   1  C1-conflict
  _fx_branch feature/noverlap solo.txt    1  S1-noverlap

  # Main moves under all of them except feature/noverlap.
  sed -i.bak '1s/.*/L1-main/' "$_FIX/shared.txt"
  sed -i.bak '1s/.*/C1-main/' "$_FIX/clash.txt"
  rm -f "$_FIX/shared.txt.bak" "$_FIX/clash.txt.bak"
  git -C "$_FIX" commit -q -am "main moves shared.txt and clash.txt"

  # The task group's worktree (Decision 0054): created once, outlives the
  # brief, and must still be here when the gate is done with it.
  _GWT="${_FIX}-group-wt"
  git -C "$_FIX" worktree add -q "$_GWT" feature/group > /dev/null 2>&1

  # --- Stub claude ---
  mkdir -p "$_FIX/bin"
  _MARKER="$_FIX/claude-invocations"
  cat > "$_FIX/bin/claude" <<'STUB'
#!/usr/bin/env bash
# Stub `claude` for test-reverify-merge.sh. Mode comes from RV_STUB_MODE.
[ -z "${RV_STUB_MARKER:-}" ] || printf 'invoked\n' >> "$RV_STUB_MARKER"
cat > /dev/null 2>&1 || true
case "${RV_STUB_MODE:-pass}" in
  pass)
    printf 'all suites green\n'
    printf 'REVERIFY-RESULT: PASS\n'
    ;;
  fail)
    printf 'REVERIFY-FAILED-CHECKS: run-automation-tests.sh, qa-verifier\n'
    printf 'REVERIFY-RESULT: FAIL\n'
    ;;
  hang)
    # Short sleeps, not one long one: bash only acts on SIGTERM between
    # foreground commands, so `sleep 600` would ignore the watchdog for ten
    # minutes and the timeout case would never finish.
    _i=0
    while [ "$_i" -lt 600 ]; do sleep 1; _i=$((_i + 1)); done
    printf 'REVERIFY-RESULT: PASS\n'
    ;;
  silent)
    printf 'no verdict here\n'
    ;;
esac
exit 0
STUB
  chmod +x "$_FIX/bin/claude"

  # --- Config the gate reads ---
  mkdir -p "$_FIX/.claude/.automation"
  cat > "$_FIX/.claude/.automation/config.yaml" <<'CFG'
runner:
  session_max_turns: 10
  reverify_timeout_seconds: 900
CFG
  cat > "$_FIX/.claude/.automation/config-fast.yaml" <<'CFG'
runner:
  session_max_turns: 10
  reverify_timeout_seconds: 2
CFG
}

_fixture_create

# --- Environment the libs expect ----------------------------------------
# queue-manager.sh documents runner.sh as the setter of these three.
REPO_ROOT="$_FIX"
AUTOMATION_DIR="$_FIX/.claude/.automation"
CONFIG_FILE="$AUTOMATION_DIR/config.yaml"
CONFIG_LOCAL_FILE=""
export REPO_ROOT AUTOMATION_DIR CONFIG_FILE CONFIG_LOCAL_FILE

PATH="$_FIX/bin:$PATH"
export PATH
RV_STUB_MARKER="$_MARKER"
export RV_STUB_MARKER

# Sourcing order is mandated by lib/reverify-merge.sh's header.
# shellcheck disable=SC1091
source "$LIB_DIR/overlap-report.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/file-lock.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/queue-manager.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/permission-profiles.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/reverify-merge.sh"

_ESC_DIR="$_FIX/.claude/.automation/escalations"

# Read back the escalation the last call wrote.
_last_escalation() {
  [ -n "${_REVERIFY_ESCALATION_ID:-}" ] || { printf ''; return 0; }
  cat "$_ESC_DIR/${_REVERIFY_ESCALATION_ID}.yaml" 2>/dev/null || printf ''
}

_MAIN_COMMIT=$(git -C "$_FIX" rev-parse --short main)

# ========================================================================
printf "# --- RV.0: the files this brief touched still parse ---\n"
# ========================================================================
# runner.sh has top-level execution, so no suite can source it and a syntax
# error in it would otherwise surface only when the daemon next runs. The libs
# are covered by the `source` lines above; this covers the one file that is
# not.
if bash -n "$RUNNER_SH" 2> /dev/null; then
  _tap_pass "RV.0 runner.sh parses"
else
  _tap_fail "RV.0 runner.sh parses" "$(bash -n "$RUNNER_SH" 2>&1 || true)"
fi

# ========================================================================
printf "# --- RV.1: overlap, clean rebase, session passes ---\n"
# ========================================================================
RV_STUB_MODE=pass; export RV_STUB_MODE
: > "$_MARKER"
_rc=0
_reverify_before_merge "$_FIX" "feature/pass" "entry-rv1" || _rc=$?

assert_eq "$_rc" "0" "RV.1 returns 0 — caller merges as today"
assert_eq "$_RESULT_REVERIFIED" "true" "RV.1 records reverified=true"
assert_contains "$_RESULT_OVERLAP_FILES" "shared.txt" "RV.1 reports shared.txt as overlapping"
if git -C "$_FIX" merge-base --is-ancestor main feature/pass 2>/dev/null; then
  _tap_pass "RV.1 branch was rebased onto main"
else
  _tap_fail "RV.1 branch was rebased onto main" "main is not an ancestor of feature/pass"
fi
assert_contains "$(cat "$_MARKER" 2>/dev/null || printf '')" "invoked" \
  "RV.1 a re-verification session ran"
assert_not_contains "$(git -C "$_FIX" worktree list 2>/dev/null)" "repo-os-reverify-" \
  "RV.1 the scratch worktree is unregistered afterwards"

# ========================================================================
printf "# --- RV.2: overlap, clean rebase, session fails ---\n"
# ========================================================================
RV_STUB_MODE=fail; export RV_STUB_MODE
: > "$_MARKER"
_rc=0
_reverify_before_merge "$_FIX" "feature/fail" "entry-rv2" || _rc=$?

assert_eq "$_rc" "2" "RV.2 returns 2 — caller must NOT merge"
assert_eq "$_RESULT_REVERIFIED" "false" "RV.2 records reverified=false"
assert_contains "$_REVERIFY_FAIL_REASON" "run-automation-tests.sh" \
  "RV.2 the failure reason carries the session's failing-checks line"
_esc=$(_last_escalation)
assert_contains "$_esc" 'type: "gate-failure"' "RV.2 escalation is a gate-failure"
assert_contains "$_esc" 'severity: "blocking"' "RV.2 escalation is blocking"
assert_contains "$_esc" "shared.txt" "RV.2 escalation names the overlapping file"
assert_contains "$_esc" "$_MAIN_COMMIT" "RV.2 escalation names the main commit that changed it"
assert_contains "$_esc" "qa-verifier" "RV.2 escalation names the failing checks"
assert_contains "${_REVERIFY_ESCALATION_ID:-}" "esc-reverify-" "RV.2 escalation id is esc-reverify-*"

# ========================================================================
printf "# --- RV.3: overlap, rebase conflicts ---\n"
# ========================================================================
RV_STUB_MODE=pass; export RV_STUB_MODE
: > "$_MARKER"
_pre_sha=$(git -C "$_FIX" rev-parse feature/conflict)
_rc=0
_reverify_before_merge "$_FIX" "feature/conflict" "entry-rv3" || _rc=$?

assert_eq "$_rc" "1" "RV.3 returns 1 — caller takes the existing conflict path"
assert_contains "$_REVERIFY_CONFLICT_FILES" "clash.txt" "RV.3 lists the conflicting file"
assert_eq "$(git -C "$_FIX" rev-parse feature/conflict)" "$_pre_sha" \
  "RV.3 the aborted rebase left the branch ref where it was"
assert_eq "$(cat "$_MARKER" 2>/dev/null || printf '')" "" \
  "RV.3 no re-verification session ran — the rebase never completed"
assert_not_contains "$(git -C "$_FIX" worktree list 2>/dev/null)" "repo-os-reverify-" \
  "RV.3 the scratch worktree is unregistered after the abort"

# ========================================================================
printf "# --- RV.4: no overlap — path identical to today ---\n"
# ========================================================================
RV_STUB_MODE=pass; export RV_STUB_MODE
: > "$_MARKER"
_pre_sha=$(git -C "$_FIX" rev-parse feature/noverlap)
_rc=0
_reverify_before_merge "$_FIX" "feature/noverlap" "entry-rv4" || _rc=$?

assert_eq "$_rc" "0" "RV.4 returns 0 — merge as today"
assert_eq "$_RESULT_REVERIFIED" "" \
  "RV.4 reverified stays empty — 'did not run', not 'passed'"
assert_eq "$_RESULT_OVERLAP_FILES" "" "RV.4 no overlapping files recorded"
assert_eq "$(git -C "$_FIX" rev-parse feature/noverlap)" "$_pre_sha" \
  "RV.4 no rebase — the branch ref is untouched"
assert_eq "$(cat "$_MARKER" 2>/dev/null || printf '')" "" \
  "RV.4 no re-verification session was started"
assert_eq "${_REVERIFY_ESCALATION_ID:-}" "" "RV.4 no escalation written"

# ========================================================================
printf "# --- RV.5: task group — rebase in the group worktree ---\n"
# ========================================================================
RV_STUB_MODE=pass; export RV_STUB_MODE
: > "$_MARKER"
_gwt_pre=$(git -C "$_GWT" rev-parse HEAD)
_CURRENT_WORKTREE_IS_GROUP=true
_CURRENT_WORKTREE_DIR="$_GWT"
_rc=0
_reverify_before_merge "$_FIX" "feature/group" "entry-rv5" || _rc=$?
_CURRENT_WORKTREE_IS_GROUP=false
_CURRENT_WORKTREE_DIR=""

assert_eq "$_rc" "0" "RV.5 returns 0 — re-verified clean"
assert_eq "$_RESULT_REVERIFIED" "true" "RV.5 records reverified=true"
if [ -d "$_GWT" ] && git -C "$_GWT" rev-parse HEAD > /dev/null 2>&1; then
  _tap_pass "RV.5 the group worktree is left in place for the remaining briefs"
else
  _tap_fail "RV.5 the group worktree is left in place for the remaining briefs" \
    "$_GWT is gone or no longer a worktree"
fi
assert_not_contains "$(git -C "$_GWT" rev-parse HEAD)" "$_gwt_pre" \
  "RV.5 the rebase happened in the group worktree, not a scratch one"
if git -C "$_FIX" merge-base --is-ancestor main feature/group 2>/dev/null; then
  _tap_pass "RV.5 the group branch is rebased onto main"
else
  _tap_fail "RV.5 the group branch is rebased onto main" "main is not an ancestor"
fi
assert_not_contains "$(git -C "$_FIX" worktree list 2>/dev/null)" "repo-os-reverify-" \
  "RV.5 no scratch worktree was created for a group branch"

# ========================================================================
printf "# --- RV.6: the session exceeds the time cap ---\n"
# ========================================================================
# A 2-second cap against a stub that would otherwise run for ten minutes.
CONFIG_FILE="$AUTOMATION_DIR/config-fast.yaml"
export CONFIG_FILE
assert_eq "$(_reverify_timeout)" "2" "RV.6 the cap is read from runner.reverify_timeout_seconds"

RV_STUB_MODE=hang; export RV_STUB_MODE
: > "$_MARKER"
_rc=0
_reverify_before_merge "$_FIX" "feature/timeout" "entry-rv6" || _rc=$?

assert_eq "$_rc" "2" "RV.6 a timeout is a failure, not a pass"
assert_eq "$_RESULT_REVERIFIED" "false" "RV.6 records reverified=false"
assert_contains "$_REVERIFY_FAIL_REASON" "timed out" "RV.6 the reason says it timed out"
assert_contains "$(_last_escalation)" "timed out" "RV.6 the escalation says it timed out"

CONFIG_FILE="$AUTOMATION_DIR/config.yaml"
export CONFIG_FILE

# A session that answers nothing is a failure too — the sentinel contract is
# fail-closed, and this is the cheapest way to assert it stays that way.
RV_STUB_MODE=silent; export RV_STUB_MODE
_rc=0
_run_reverify_session "$_FIX" "feature/pass" "shared.txt" || _rc=$?
assert_eq "$_rc" "1" "RV.6 a session with no verdict fails"
assert_contains "$_REVERIFY_FAIL_REASON" "no verdict" "RV.6 the reason says there was no verdict"

# ========================================================================
printf "# --- RV.7: the gate runs inside the merge lock ---\n"
# ========================================================================
# Structural, on runner.sh: the gate is worthless outside the lock, because
# another close could land on main between the verdict and the merge. There is
# no way to observe that from a unit test of the lib, so the call site's
# position between acquire and release is asserted directly.
_acq_ln=$(grep -n '_acquire_runner_merge_lock "\$_merge_lock"' "$RUNNER_SH" | head -1 | cut -d: -f1)
_gate_ln=$(grep -n '_reverify_before_merge "\$_main_repo"' "$RUNNER_SH" | head -1 | cut -d: -f1)
_rel_ln=$(grep -n '^ *_release_runner_merge_lock$' "$RUNNER_SH" | tail -1 | cut -d: -f1)

if [ -n "$_acq_ln" ] && [ -n "$_gate_ln" ] && [ -n "$_rel_ln" ] \
   && [ "$_acq_ln" -lt "$_gate_ln" ] && [ "$_gate_ln" -lt "$_rel_ln" ]; then
  _tap_pass "RV.7 _reverify_before_merge sits between acquire and release"
else
  _tap_fail "RV.7 _reverify_before_merge sits between acquire and release" \
    "acquire=$_acq_ln gate=$_gate_ln release=$_rel_ln"
fi
assert_contains "$(cat "$RUNNER_SH")" "_warn_if_merge_lock_held_long" \
  "RV.7 a long lock hold is warned about"

# The legacy non-worktree path must get the same gate, or the two merge paths
# can disagree about whether a branch is safe to land.
assert_contains "$(cat "$RUNNER_SH")" '_reverify_before_merge "$REPO_ROOT"' \
  "RV.7 the legacy checkout-main path is gated too"

# Regression: the two result globals are per-entry state. The daemon-loop
# write-back fires whenever either is non-empty, so a value surviving from a
# previous cycle would be stamped onto an entry whose merge never reached the
# gate. Slice the reset block rather than the whole file — a match anywhere
# else in runner.sh would make this assertion unfalsifiable.
_reset_block=$(awk '/^  # Reset globals$/ { f = 1 }
                    f { print }
                    f && /^  _CURRENT_GROUP_NAME=""$/ { exit }' "$RUNNER_SH")
assert_contains "$_reset_block" '_RESULT_REVERIFIED=""' \
  "RV.7 _RESULT_REVERIFIED is reset per entry"
assert_contains "$_reset_block" '_RESULT_OVERLAP_FILES=""' \
  "RV.7 _RESULT_OVERLAP_FILES is reset per entry"

# ========================================================================
printf "# --- RV.8: the result round-trips on the queue entry ---\n"
# ========================================================================
assert_eq "$(queue_yaml_flow_seq "")" "[]" "RV.8 an empty list renders as []"
assert_eq "$(queue_yaml_flow_seq "$(printf 'a.txt\nb.txt')")" \
  '["a.txt","b.txt"]' "RV.8 a two-file list renders as a flow sequence"

_entry="$_FIX/entry.yaml"
cat > "$_entry" <<'ENTRY'
entry:
  id: "entry-rv8"
  status: "running"
  session_type: "taskgroup"
  branch: "feature/pass"
ENTRY
_load_queue_entry "$_entry"
_QE_REVERIFIED="true"
_QE_OVERLAP_FILES=$(queue_yaml_flow_seq "$(printf 'shared.txt\ndocs/x.md')")
_write_queue_entry "$_entry"
_load_queue_entry "$_entry"
assert_eq "$_QE_REVERIFIED" "true" "RV.8 reverified survives a load/write round-trip"
assert_eq "$_QE_OVERLAP_FILES" '["shared.txt","docs/x.md"]' \
  "RV.8 overlap_files survives a load/write round-trip"

# A gate that did not run must read as "did not run", not as a pass.
_load_queue_entry "$_entry"
_QE_REVERIFIED=""
_QE_OVERLAP_FILES=$(queue_yaml_flow_seq "")
_write_queue_entry "$_entry"
_load_queue_entry "$_entry"
assert_eq "$_QE_REVERIFIED" "" "RV.8 an unrun gate round-trips as empty"
assert_eq "$_QE_OVERLAP_FILES" "[]" "RV.8 an empty overlap list round-trips as []"

# ========================================================================
printf "\n1..%d\n" "$_TAP_TEST_NUM"
printf "# passed %d, failed %d\n" "$_TAP_PASS" "$_TAP_FAIL"

[ "$_TAP_FAIL" -eq 0 ] || exit 1
exit 0
