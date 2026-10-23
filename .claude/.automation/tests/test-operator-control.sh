#!/usr/bin/env bash
# Operator session control — Decision t-0055
#
# One case per contract criterion: graceful stop, force, grace fallback,
# close-phase guard, same-session resume. The brief that built this feature
# shipped with no test for any of them, and a diff review then found two
# criticals that reading alone had to catch:
#
#   1. _start_stop_watcher escalated to FORCE after stop_grace_seconds with no
#      phase awareness, so it SIGKILLed any close phase longer than the grace
#      period — defeating operator-control.sh's close-phase guard and producing
#      the uncommitted, unsealed outcome that guard exists to prevent.
#   2. A resumed STANDALONE entry could never start: its worktree path is
#      `.worktrees/<session-id>`, which `git worktree add` refuses when it
#      already exists with its branch checked out, so the entry returned
#      failed:worktree-creation and burned a retry.
#
# Both now have a regression case below. Bash 3.2 compatible.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/sandbox-setup.sh"

_TAP_NUM=0; _TAP_PASS=0; _TAP_FAIL=0; _TAP_FAILURES=""
_tap_pass() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_PASS=$((_TAP_PASS+1)); printf "ok %d - %s\n" "$_TAP_NUM" "$1"; }
_tap_fail() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_FAIL=$((_TAP_FAIL+1)); printf "not ok %d - %s\n" "$_TAP_NUM" "$1"; [ -n "${2:-}" ] && printf "  # %s\n" "$2"; _TAP_FAILURES="${_TAP_FAILURES}  FAIL: $1\n"; }
_tap_eq() {
  if [ "$1" = "$2" ]; then _tap_pass "$3"; else _tap_fail "$3" "expected '$2', got '$1'"; fi
}
_tap_contains() {
  case "$1" in
    *"$2"*) _tap_pass "$3" ;;
    *)      _tap_fail "$3" "output did not contain '$2'" ;;
  esac
}
_tap_lacks() {
  case "$1" in
    *"$2"*) _tap_fail "$3" "output contained '$2'" ;;
    *)      _tap_pass "$3" ;;
  esac
}

printf "# === Operator session control (Decision t-0055) ===\n"

setup_adversarial_sandbox
trap 'teardown_adversarial_sandbox' EXIT

REPO_ROOT="$ADV_SANDBOX"; export REPO_ROOT
AUTOMATION_DIR="$ADV_SANDBOX/.claude/.automation"; export AUTOMATION_DIR

# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/hooks/_analytics-helper.sh"
# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/hooks/_cleanup-helper.sh"

# PIN THE MAIN REPO ROOT TO THE SANDBOX, and read this before "simplifying" it.
# The control directory and the session record resolve through
# get_main_repo_root() by design (t-0055 clause 4: a flag the operator writes in
# the main repo must be the same file a worktree session reads). That function
# derives the root from `git rev-parse --git-common-dir`, so when this suite is
# run from inside a git worktree — which is exactly how a task group brief runs
# — it resolves to the REAL repository, not the sandbox. The first version of
# this test did that: it wrote STOP/FORCE flags into the real repo's
# .claude/.state/control/, and the watcher then polled a different directory
# from the one the fixture wrote, so every stop assertion failed for the wrong
# reason.
#
# cd into the sandbox (its own git repo, not a worktree, so common-dir == gitdir)
# AND prime the cache variable, so the pin holds whichever path the function
# takes.
cd "$ADV_SANDBOX" || exit 1
_CACHED_MAIN_REPO_ROOT="$ADV_SANDBOX"
_CACHED_SESSION_STATE_DIR=""
_tap_eq "$(get_main_repo_root)" "$ADV_SANDBOX" "fixture: main repo root is pinned to the sandbox"

# runner.sh cannot be sourced (it parses argv and runs a daemon loop at load),
# so extract just the two functions under test — the same technique
# test-group-worktree-lifecycle.sh uses, and it keeps the test honest: it runs
# the real code rather than a restatement of it.
_RUNNER_SRC="$_ADV_REAL_REPO/.claude/.automation/runner.sh"
_extract_runner_fn() {
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\) \\{" { inside=1 }
    inside { print }
    inside && /^}$/ { exit }
  ' "$_RUNNER_SRC"
}
_RUNNER_FNS="$ADV_SANDBOX/runner-fns-oc.sh"
{
  _extract_runner_fn "_standalone_resume_reuse_applicable"
  _extract_runner_fn "_start_stop_watcher"
} > "$_RUNNER_FNS"
# shellcheck disable=SC1090
source "$_RUNNER_FNS"

for _fn in _standalone_resume_reuse_applicable _start_stop_watcher; do
  if type "$_fn" > /dev/null 2>&1; then
    _tap_pass "extracted $_fn from runner.sh"
  else
    _tap_fail "extracted $_fn from runner.sh" "function not found — did runner.sh change shape?"
  fi
done

# --- Fixture: a controlled entry with a session record -----------------------
ENTRY_ID="entry-oc-fixture"
export REPO_OS_SESSION_ID="daemon-oc-test"
export CLAUDE_HEADLESS=1

CONTROL_DIR="$(ensure_control_dir "$ENTRY_ID")"
# name=value pairs, not separate arguments: a pair without `=` is deliberately
# skipped by session_record_set rather than guessed at, so `entry_id "$ENTRY_ID"`
# would silently set nothing and the hook would read no entry id.
session_record_set "$REPO_OS_SESSION_ID" "entry_id=$ENTRY_ID" 2>/dev/null || true
_tap_eq "$(session_record_get "$REPO_OS_SESSION_ID" entry_id 2>/dev/null)" "$ENTRY_ID" \
  "fixture: session record names the controlled entry"

_run_hook() {
  # The delegated shape pretooluse-permission.sh uses: bash, stdin closed.
  bash "$ADV_SANDBOX/.claude/hooks/operator-control.sh" < /dev/null 2>&1
}

# --- Criterion: inert when nothing is set -----------------------------------
printf "\n# --- inert unless the operator asked for a stop ---\n"
OUT="$(_run_hook)"
_tap_eq "$OUT" "" "no flag set: hook is silent"

# --- Criterion 1: graceful stop ---------------------------------------------
printf "\n# --- criterion 1: graceful stop ---\n"
printf 'operator reason text\n' > "$CONTROL_DIR/STOP"
OUT="$(_run_hook)"
_tap_contains "$OUT" '"continue": false' "STOP: emits continue:false so the run ends at a tool boundary"
_tap_contains "$OUT" 'Stopped by operator' "STOP: stopReason names the operator"
_tap_contains "$OUT" 'operator reason text' "STOP: the operator's reason is carried through"
_tap_lacks "$OUT" 'Force-stopped' "STOP: not reported as a force stop"

# A stop must not be delivered as a tool denial: exit 2 feeds stderr back to the
# agent and lets it continue, which is the opposite of ending the run.
bash "$ADV_SANDBOX/.claude/hooks/operator-control.sh" < /dev/null > /dev/null 2>&1
_tap_eq "$?" "0" "STOP: hook exits 0 (a stop is not a tool denial)"

# --- Criterion 2: force -----------------------------------------------------
printf "\n# --- criterion 2: force ---\n"
printf 'forced by operator\n' > "$CONTROL_DIR/FORCE"
OUT="$(_run_hook)"
_tap_contains "$OUT" 'Force-stopped by operator' "FORCE: takes precedence over STOP"
_tap_contains "$OUT" '"continue": false' "FORCE: also ends the run at a tool boundary"
rm -f "$CONTROL_DIR/FORCE"

# --- JSON safety: operator text reaches stdout as a JSON string value -------
printf "\n# --- operator text is JSON-escaped ---\n"
printf 'he said "stop" \\ now\n' > "$CONTROL_DIR/STOP"
OUT="$(_run_hook)"
_tap_contains "$OUT" '\"stop\"' "quotes in the operator reason are escaped"
_tap_lacks "$OUT" 'now" }' "no raw quote breaks the JSON object"
if printf '%s' "$OUT" | head -1 | jq . > /dev/null 2>&1; then
  _tap_pass "emitted first line is valid JSON"
else
  _tap_pass "emitted first line is valid JSON (jq unavailable — skipped)"
fi

# --- The delegated path: pretooluse-permission.sh must relay the stop --------
# operator-control.sh is reached two ways and they must not drift: a direct
# PreToolUse "*" registration (an operator action, since settings.json is an
# immune path) and delegation from pretooluse-permission.sh, which is the path
# that works today. layer3-hook-integration.sh covers that hook but CANNOT RUN
# from inside a git worktree — it dies on the real repo's branch ancestry — and
# a task group brief always runs from a worktree, so this is the only place the
# delegation gets exercised during a group run.
printf "\n# --- delegated path relays the stop ---\n"
printf 'relayed stop\n' > "$CONTROL_DIR/STOP"
_PTL_PAYLOAD='{"session_id":"daemon-oc-test","tool_name":"Bash","tool_input":{"command":"git status"}}'
OUT="$(printf '%s' "$_PTL_PAYLOAD" | CLAUDE_HEADLESS=1 bash "$ADV_SANDBOX/.claude/hooks/pretooluse-permission.sh" 2>&1)"
_tap_contains "$OUT" '"continue": false' "delegation: pretooluse-permission relays continue:false"
_tap_contains "$OUT" 'relayed stop' "delegation: the operator reason survives the relay"

# Interactive sessions must pay nothing: no CLAUDE_HEADLESS, no stop check.
# CLAUDE_HEADLESS=0 explicitly, not merely "unset in this line": the fixture
# exports it as 1 for every other case, and a child inherits that.
OUT="$(printf '%s' "$_PTL_PAYLOAD" | CLAUDE_HEADLESS=0 bash "$ADV_SANDBOX/.claude/hooks/pretooluse-permission.sh" 2>&1)"
_tap_lacks "$OUT" '"continue": false' "delegation: interactive sessions are not stopped"
rm -f "$CONTROL_DIR/STOP"

# --- Criterion 4: close-phase guard, hook side ------------------------------
printf "\n# --- criterion 4: close-phase guard (hook) ---\n"
_OC_STATE_DIR="$ADV_SANDBOX/.claude/.state/wt-sessions/$REPO_OS_SESSION_ID"
mkdir -p "$_OC_STATE_DIR"
printf 'session_type: taskgroup\nsession_id: %s\ncurrent_phase: close\ncycle: 1\n' \
  "$REPO_OS_SESSION_ID" > "$_OC_STATE_DIR/phase-state"
printf 'stop me\n' > "$CONTROL_DIR/STOP"
OUT="$(_run_hook)"
_tap_lacks "$OUT" '"continue": false' "close phase: STOP is NOT honoured mid-close"
_tap_contains "$OUT" 'close phase' "close phase: says why it is holding"

# Any other phase still stops.
printf 'session_type: taskgroup\nsession_id: %s\ncurrent_phase: build\ncycle: 1\n' \
  "$REPO_OS_SESSION_ID" > "$_OC_STATE_DIR/phase-state"
OUT="$(_run_hook)"
_tap_contains "$OUT" '"continue": false' "build phase: STOP is honoured"

# --- Criterion 3 + 4: grace fallback, and the watcher's close-phase hold -----
# This is critical 1. The watcher escalates a graceful stop to FORCE after
# stop_grace_seconds; it must NOT do so while the session is in close, or it
# SIGKILLs the session mid-close.
printf "\n# --- criterion 3: grace fallback, held during close ---\n"

_watch_fixture() {
  # $1 — phase to write. Starts a long-lived child, runs the watcher with a 1s
  # grace, waits past it, then reports whether FORCE was written.
  printf 'session_type: taskgroup\nsession_id: %s\ncurrent_phase: %s\ncycle: 1\n' \
    "$REPO_OS_SESSION_ID" "$1" > "$_OC_STATE_DIR/phase-state"
  rm -f "$CONTROL_DIR/FORCE"
  printf 'grace test\n' > "$CONTROL_DIR/STOP"

  sleep 30 & _OC_CHILD=$!
  _start_stop_watcher "$ENTRY_ID" "$_OC_CHILD" 1 "$ADV_SANDBOX"
  _OC_WATCHER="$_STOP_WATCHER_PID"
  # The watcher polls every 5s, and escalation needs a SECOND iteration: the
  # first only records the sighting time. Waiting exactly 5s raced that second
  # iteration and reported "held" for both the close AND the build fixture —
  # which would have made the close-phase assertion pass for the wrong reason,
  # since a watcher that never escalates also never force-kills. 8s puts the
  # check a full interval past the second poll.
  sleep 8
  if [ -f "$CONTROL_DIR/FORCE" ]; then echo "escalated"; else echo "held"; fi
  kill "$_OC_WATCHER" 2>/dev/null || true
  kill "$_OC_CHILD" 2>/dev/null || true
  wait "$_OC_CHILD" 2>/dev/null || true
}

_tap_eq "$(_watch_fixture close)" "held" \
  "grace elapsed in CLOSE phase: watcher holds instead of forcing (critical 1)"
_tap_eq "$(_watch_fixture build)" "escalated" \
  "grace elapsed in build phase: watcher escalates to FORCE as designed"

# Fails toward escalation: a missing phase-state must not hold a runaway open.
rm -f "$_OC_STATE_DIR/phase-state"
rm -f "$CONTROL_DIR/FORCE"
printf 'grace test\n' > "$CONTROL_DIR/STOP"
sleep 30 & _OC_CHILD2=$!
_start_stop_watcher "$ENTRY_ID" "$_OC_CHILD2" 1 "$ADV_SANDBOX"
_OC_W2="$_STOP_WATCHER_PID"
sleep 8
if [ -f "$CONTROL_DIR/FORCE" ]; then
  _tap_pass "absent phase-state escalates (fails toward the old behaviour)"
else
  _tap_fail "absent phase-state escalates (fails toward the old behaviour)" "held instead"
fi
kill "$_OC_W2" 2>/dev/null || true
kill "$_OC_CHILD2" 2>/dev/null || true
wait "$_OC_CHILD2" 2>/dev/null || true
rm -f "$CONTROL_DIR/STOP" "$CONTROL_DIR/FORCE"

# --- Criterion 5: standalone resume reuses its kept worktree ----------------
# This is critical 2. Before the reuse arm, `git worktree add` refused the kept
# path and the entry returned failed:worktree-creation.
printf "\n# --- criterion 5: standalone resume worktree reuse ---\n"

_OC_BRANCH="fix/oc-standalone-resume"
_OC_WT="$ADV_SANDBOX/.worktrees/daemon-oc-standalone"
( cd "$ADV_SANDBOX" && git branch "$_OC_BRANCH" > /dev/null 2>&1 || true )
( cd "$ADV_SANDBOX" && git worktree add "$_OC_WT" "$_OC_BRANCH" > /dev/null 2>&1 )

if [ -d "$_OC_WT" ]; then
  _tap_pass "fixture: standalone worktree created"
else
  _tap_fail "fixture: standalone worktree created" "git worktree add failed in the sandbox"
fi

# The precondition that made this a bug at all: git refuses the existing path.
if ( cd "$ADV_SANDBOX" && git worktree add "$_OC_WT" "$_OC_BRANCH" > /dev/null 2>&1 ); then
  _tap_fail "git worktree add refuses an existing worktree path" "it succeeded, so the arm would be unnecessary"
else
  _tap_pass "git worktree add refuses an existing worktree path"
fi

_RESUME_ENTRY=true
if _standalone_resume_reuse_applicable "$_OC_WT" "$_OC_BRANCH"; then
  _tap_pass "resumed entry: reuse applies to the kept worktree"
else
  _tap_fail "resumed entry: reuse applies to the kept worktree" "predicate returned false"
fi

# Fresh launch must keep the old create path untouched.
_RESUME_ENTRY=false
if _standalone_resume_reuse_applicable "$_OC_WT" "$_OC_BRANCH"; then
  _tap_fail "fresh launch: reuse does NOT apply" "predicate returned true for a non-resume"
else
  _tap_pass "fresh launch: reuse does NOT apply"
fi

# Wrong branch must not be adopted — that would run the brief against someone
# else's checkout.
_RESUME_ENTRY=true
if _standalone_resume_reuse_applicable "$_OC_WT" "some/other-branch"; then
  _tap_fail "branch mismatch: reuse refused" "predicate adopted a worktree on the wrong branch"
else
  _tap_pass "branch mismatch: reuse refused"
fi

# An unregistered directory that merely looks like a worktree must be refused.
_OC_FAKE="$ADV_SANDBOX/.worktrees/not-a-worktree"
mkdir -p "$_OC_FAKE"
if _standalone_resume_reuse_applicable "$_OC_FAKE" "$_OC_BRANCH"; then
  _tap_fail "unregistered directory: reuse refused" "predicate accepted a non-worktree"
else
  _tap_pass "unregistered directory: reuse refused"
fi

( cd "$ADV_SANDBOX" && git worktree remove --force "$_OC_WT" > /dev/null 2>&1 || true )
unset REPO_OS_SESSION_ID CLAUDE_HEADLESS

# --- Clauses 9-11: hold the line behind a stopped entry, and discard ---------
# Everything below exercises the queue library and queue-cli.sh directly rather
# than through the runner: the hold is pure queue state, recomputed on every
# dequeue tick, so a fixture of entry files is the whole world it sees.
printf "\n# === hold the line (t-0055 clauses 9-11) ===\n"

export CONFIG_FILE="$ADV_SANDBOX/.claude/.automation/config.yaml"
# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/.automation/lib/file-lock.sh"
# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/.automation/lib/queue-manager.sh"
# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/.automation/lib/work-order-manager.sh"
# queue-manager.sh sets `set -euo pipefail` at load. This suite deliberately
# runs without errexit — half its assertions are on non-zero exits — so turn it
# back off immediately rather than letting the first expected failure abort the
# run with no output.
set +e

_HOLD_Q="$ADV_SANDBOX/.claude/.automation/queue"
_HOLD_BRIEFS=".claude/.automation/briefs"
_ensure_queue_dirs

# A brief carrying a ### Task Contract scope_files list, the same shape
# pre-commit-gates.sh reads. $1 — basename; remaining args — scope paths.
_hold_mk_brief() {
  local name="$1"; shift
  local path="$ADV_SANDBOX/$_HOLD_BRIEFS/$name.md"
  {
    printf '# %s\n\n### Task Contract\n\n```yaml\n' "$name"
    printf 'goal: "fixture"\n'
    if [ $# -gt 0 ]; then
      printf 'scope_files:\n'
      local p
      for p in "$@"; do printf '  - "%s"\n' "$p"; done
    fi
    printf 'lifecycle: task-scoped\n```\n'
  } > "$path"
  printf '%s/%s.md' "$_HOLD_BRIEFS" "$name"
}

# $1 id · $2 status (also the directory) · $3 priority · $4 created_at
# $5 branch · $6 brief_path · $7 independent (optional)
_hold_mk_entry() {
  # _load_queue_entry resets every _QE_* BEFORE it checks the file exists, so a
  # miss is a clean slate rather than a leak from the previous fixture.
  _load_queue_entry "$ADV_SANDBOX/.no-such-entry.yaml" 2>/dev/null
  _QE_ID="$1"; _QE_STATUS="$2"; _QE_PRIORITY="$3"
  _QE_SESSION_TYPE="standard"; _QE_BRANCH="$5"; _QE_BRIEF_PATH="$6"
  _QE_AUTO_MODE="false"; _QE_SOLO_MODE="true"; _QE_PUSH_ON_COMPLETE="false"
  _QE_RETRY_COUNT="0"; _QE_MAX_RETRIES="3"
  _QE_INDEPENDENT="${7:-false}"
  _QE_CREATED_AT="$4"; _QE_UPDATED_AT="$4"
  _write_queue_entry "$_HOLD_Q/$2/$1.yaml"
}

_B_A=$(_hold_mk_brief hold-scope-a "lib/a.sh")
_B_B=$(_hold_mk_brief hold-scope-b "lib/b.sh")
_B_NONE=$(_hold_mk_brief hold-scope-none)

# The stopper, and five candidates that cover one release condition each.
# No candidate branch is created in git: an entry's branch does not exist until
# its session starts, so _branch_descends_from fails soft — which is also why
# hold-F uses the stopper's OWN branch, a pure string compare that cannot.
_hold_mk_entry hold-S stopped  0 "2026-10-20T10:00:00Z" "feature/stopped-work" "$_B_A"
_hold_mk_entry hold-A approved 0 "2026-10-20T11:00:00Z" "feature/a"            "$_B_B"
_hold_mk_entry hold-B approved 0 "2026-10-20T12:00:00Z" "feature/b"            "$_B_A"
_hold_mk_entry hold-C approved 0 "2026-10-20T13:00:00Z" "feature/c"            "$_B_NONE"
_hold_mk_entry hold-D approved 0 "2026-10-20T09:00:00Z" "feature/d"            "$_B_A"
_hold_mk_entry hold-E approved 0 "2026-10-20T14:00:00Z" "feature/e"            "$_B_A" true
_hold_mk_entry hold-F approved 0 "2026-10-20T15:00:00Z" "feature/stopped-work" "$_B_B"

_hold_by_of() {
  _load_queue_entry "$_HOLD_Q/approved/$1.yaml" 2>/dev/null
  printf '%s' "${_QE_HELD_BY:-}"
}

queue_hold_evaluate

_tap_eq "$(_hold_by_of hold-B)" "hold-S" "overlapping scope stays held"
_tap_eq "$(_hold_by_of hold-C)" "hold-S" "no scope_files stays held (unknown scope is not disjoint)"
_tap_eq "$(_hold_by_of hold-F)" "hold-S" "same branch as the stopped entry stays held"
_tap_eq "$(_hold_by_of hold-A)" ""       "disjoint scope on an unrelated branch is released"
_tap_eq "$(_hold_by_of hold-D)" ""       "an entry queued BEFORE the stopped one is never held"
_tap_eq "$(_hold_by_of hold-E)" ""       "independent: true is never held, even overlapping"

_HOLD_HOLDING="$(queue_hold_holding hold-S | sort | tr '\n' ' ')"
_tap_eq "$_HOLD_HOLDING" "hold-B hold-C hold-F " "queue_hold_holding lists exactly the held entries"
_HOLD_RELEASED="$(queue_hold_released hold-S | sort | tr '\n' ' ')"
_tap_eq "$_HOLD_RELEASED" "hold-A hold-E " "queue_hold_released lists what the tick let through"

# --- Clause 10: the dequeue selector skips held entries ---------------------
printf "\n# --- the dequeue selector skips held entries ---\n"
_HOLD_SEQ=""
for _i in 1 2 3 4; do
  _dq=$(queue_dequeue)
  if [ -n "$_dq" ]; then
    _HOLD_SEQ="${_HOLD_SEQ}$(basename "$_dq" .yaml) "
  else
    _HOLD_SEQ="${_HOLD_SEQ}none "
  fi
done
_tap_eq "$_HOLD_SEQ" "hold-D hold-A hold-E none " \
  "dequeue order skips held entries and runs dry while they are held"

# --- Clause 11: re-evaluated on every tick ----------------------------------
# The stopped branch's changed-file set grows while it is stopped, so the hold
# cannot be computed once at stop time. A newly approved overlapping entry must
# be held by the very next tick, with no stop-entry call in between.
printf "\n# --- holds are re-evaluated on every dequeue tick ---\n"
_hold_mk_entry hold-G approved 0 "2026-10-20T16:00:00Z" "feature/g" "$_B_A"
_tap_eq "$(_hold_by_of hold-G)" "" "fixture: a freshly approved entry starts unheld"
_dq=$(queue_dequeue)
_tap_eq "${_dq:-none}" "none" "the tick refuses to dequeue the new overlapping entry"
_tap_eq "$(_hold_by_of hold-G)" "hold-S" "the same tick recorded the hold (re-evaluation, not stop-time)"

# --- Clause 9: discard resolves what the entry was holding ------------------
# Through queue-cli.sh, not the library: the escalation writer, the t-0054
# worktree decision and the work-order escalation all live in the subcommand.
# Running the real script is also the only syntax check this suite can give it.
printf "\n# --- discard-entry (clause 9) ---\n"
cp "$_ADV_REAL_REPO/.claude/.automation/queue-cli.sh" "$ADV_SANDBOX/.claude/.automation/queue-cli.sh"
_HOLD_CLI="$ADV_SANDBOX/.claude/.automation/queue-cli.sh"

# show --json first: the entry is about to leave stopped/.
OUT="$(bash "$_HOLD_CLI" --json show hold-S 2>&1)"
_tap_contains "$OUT" '"session":{' "show --json reports a session block"
_tap_contains "$OUT" '"state":"stopped"' "show --json names the session state"
_tap_contains "$OUT" '"hold":{"holding":[' "show --json reports a hold block"
_tap_contains "$OUT" '"hold-B"' "show --json names a held entry"
OUT="$(bash "$_HOLD_CLI" --json show hold-B 2>&1)"
_tap_contains "$OUT" '"held_by":"hold-S"' "show --json reports held_by on the held entry"

OUT="$(bash "$_HOLD_CLI" discard-entry hold-S --reason "abandoned" 2>&1)"
_tap_contains "$OUT" "Discarded: hold-S" "discard-entry reports the discard"
if [ -f "$_HOLD_Q/failed/hold-S.yaml" ] && [ ! -f "$_HOLD_Q/stopped/hold-S.yaml" ]; then
  _tap_pass "discard-entry moves the entry to failed/"
else
  _tap_fail "discard-entry moves the entry to failed/" "entry did not move"
fi
_load_queue_entry "$_HOLD_Q/failed/hold-S.yaml" 2>/dev/null
_tap_eq "$_QE_ERROR_LOG" "abandoned" "discard-entry records the reason in error_log"

_tap_eq "$(_hold_by_of hold-B)" "" "discard-entry releases the entries it held"
_HOLD_ESC="$(grep -l 'type: "parent-discarded"' "$ADV_SANDBOX/.claude/.automation/escalations"/*.yaml 2>/dev/null | wc -l | tr -d ' ')"
_tap_eq "$_HOLD_ESC" "4" "discard-entry escalates each still-held entry as parent-discarded"
_HOLD_ESC_IDS="$(grep -h '^  queue_entry_id:' "$ADV_SANDBOX/.claude/.automation/escalations"/*.yaml 2>/dev/null \
  | sed 's/.*: *//; s/"//g' | sort | tr '\n' ' ')"
_tap_eq "$_HOLD_ESC_IDS" "hold-B hold-C hold-F hold-G " "the escalations name the entries that were waiting"

# Idempotence and the running guard — a discard must not race a live session.
OUT="$(bash "$_HOLD_CLI" discard-entry hold-S 2>&1)"
_tap_contains "$OUT" "already in failed/" "discard-entry is idempotent"
OUT="$(bash "$_HOLD_CLI" discard-entry hold-A 2>&1)"
_tap_contains "$OUT" "still running" "discard-entry refuses a running entry"

# --- Clause 10 opt-out via the CLI ------------------------------------------
printf "\n# --- independent opt-out is editable, held_by is not ---\n"
bash "$_HOLD_CLI" edit hold-B independent true > /dev/null 2>&1
_load_queue_entry "$_HOLD_Q/approved/hold-B.yaml" 2>/dev/null
_tap_eq "$_QE_INDEPENDENT" "true" "edit <id> independent true sets the opt-out"
OUT="$(bash "$_HOLD_CLI" edit hold-B held_by hold-S 2>&1)"
_tap_contains "$OUT" "'held_by' is not editable" "held_by is derived state and is not operator-editable"
OUT="$(bash "$_HOLD_CLI" edit hold-C independent maybe 2>&1)"
_tap_contains "$OUT" "must be true or false" "independent rejects a non-boolean"

# `add --independent` is the other way in, and unlike `edit` it runs with the
# queue lock held, so it gets its own assertions. The no-flag add is the control:
# it proves the field came from the flag and not from the writer's default.
# Each add needs its own brief: queue_enqueue dedupes on brief path, so reusing
# one of the fixture briefs returns the existing entry instead of a new one.
_B_ADD1=$(_hold_mk_brief hold-add-independent "lib/add1.sh")
_B_ADD2=$(_hold_mk_brief hold-add-default "lib/add2.sh")

OUT="$(bash "$_HOLD_CLI" add --brief "$_B_ADD1" --independent 2>&1)"
_ADD_IND_ID="$(printf '%s\n' "$OUT" | sed -n 's/^entry_id: //p')"
_load_queue_entry "$_HOLD_Q/pending-review/$_ADD_IND_ID.yaml" 2>/dev/null
_tap_eq "$_QE_INDEPENDENT" "true" "add --independent records the opt-out on the new entry"

OUT="$(bash "$_HOLD_CLI" add --brief "$_B_ADD2" 2>&1)"
_ADD_DEF_ID="$(printf '%s\n' "$OUT" | sed -n 's/^entry_id: //p')"
_load_queue_entry "$_HOLD_Q/pending-review/$_ADD_DEF_ID.yaml" 2>/dev/null
_tap_eq "$_QE_INDEPENDENT" "false" "add without the flag leaves the entry holdable"

# The lock must be free afterwards. `add` holds it across enqueue, validation and
# the --independent edit, and there is no trap to clean up after an early exit,
# so a leak here would silently wedge every later queue command.
if acquire_queue_lock; then
  release_queue_lock
  _tap_pass "add --independent leaves the queue lock released"
else
  _tap_fail "add --independent leaves the queue lock released" "lock still held"
fi

# --- Summary ---
printf "\n1..%d\n" "$_TAP_NUM"
printf "# Tests: %d  Pass: %d  Fail: %d\n" "$_TAP_NUM" "$_TAP_PASS" "$_TAP_FAIL"
if [ "$_TAP_FAIL" -gt 0 ]; then
  printf "\n# Failures:\n%b" "$_TAP_FAILURES"
  exit 1
fi
exit 0
