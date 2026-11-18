#!/usr/bin/env bash
# Headless question pause — Decision t-0064
#
# One section per Verification item in the brief
# (20261028-001327-headless-question-pause). Runs the real hook, the real
# question-channel library and functions extracted from the real runner.sh
# against a /tmp sandbox — never the real queue, escalations or questions
# directory. Bash 3.2 compatible. Takes about a minute: the FORCE-HALT case
# waits on the runner watcher's real 5s poll.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_REPO="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck disable=SC1091
source "$REAL_REPO/.claude/.automation/tests/sandbox-setup.sh"
# sandbox-setup.sh may enable errexit; every case here checks its own status.
set +e

_TAP_NUM=0; _TAP_PASS=0; _TAP_FAIL=0
_tap_pass() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_PASS=$((_TAP_PASS+1)); printf "ok %d - %s\n" "$_TAP_NUM" "$1"; }
_tap_fail() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_FAIL=$((_TAP_FAIL+1)); printf "not ok %d - %s\n" "$_TAP_NUM" "$1"; [ -n "${2:-}" ] && printf "  # %s\n" "$2"; }
_tap_eq() { if [ "$1" = "$2" ]; then _tap_pass "$3"; else _tap_fail "$3" "expected '$2', got '$1'"; fi; }
_tap_contains() { case "$1" in *"$2"*) _tap_pass "$3" ;; *) _tap_fail "$3" "output did not contain '$2'" ;; esac; }
_tap_lacks() { case "$1" in *"$2"*) _tap_fail "$3" "output contained '$2'" ;; *) _tap_pass "$3" ;; esac; }
_tap_true() { if eval "$1"; then _tap_pass "$2"; else _tap_fail "$2" "condition false: $1"; fi; }

printf "# === Headless question pause (Decision t-0064) ===\n"

setup_adversarial_sandbox >/dev/null 2>&1
set +e
trap 'teardown_adversarial_sandbox >/dev/null 2>&1' EXIT
SB="$ADV_SANDBOX"
ADIR="$SB/.claude/.automation"
QDIR="$ADIR/questions"
HOOK="$SB/.claude/hooks/ask-user-deny.sh"
WORK="$SB/.qc-test"
mkdir -p "$WORK"
# work-preserver.sh writes patches under $AUTOMATION_DIR/reports; the extracted
# runner functions read it too. Pin it to the sandbox before anything runs.
AUTOMATION_DIR="$ADIR"; export AUTOMATION_DIR
cd "$SB" || exit 1

if [ -f "$HOOK" ] && [ -f "$ADIR/lib/question-channel.sh" ]; then
  _tap_pass "fixture: sandbox has the hook and lib/question-channel.sh"
else
  _tap_fail "fixture: sandbox has the hook and lib/question-channel.sh" "missing — later cases cannot be meaningful"
fi
# shellcheck disable=SC1091
source "$ADIR/lib/question-channel.sh"
# Negative assertions below (`! qc_is_open`, `! qc_read_answer`) would pass
# vacuously if the library failed to load — `!` of "command not found" is
# true. _lib guards each of them.
if type qc_is_open >/dev/null 2>&1 && type qc_read_answer >/dev/null 2>&1; then
  _tap_pass "fixture: question-channel library loaded"
else
  _tap_fail "fixture: question-channel library loaded" "negative assertions below will FAIL rather than pass vacuously"
fi
_lib() { type qc_is_open >/dev/null 2>&1 && type qc_read_answer >/dev/null 2>&1; }

_set_timeout() {
  printf 'runner:\n  question_timeout_seconds: %s\n  question_hook_timeout_seconds: %s\n' "$1" "${2:-600}" > "$ADIR/config.yaml"
}
_reset_questions() { rm -rf "$QDIR" "$ADIR/escalations"; mkdir -p "$ADIR/escalations"; }

# Payload: two questions, quotes, unicode, multiSelect true and false.
PAYLOAD="$WORK/payload.json"
printf '%s' '{"session_id":"cc-1","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which store should the cache use?","header":"Cache","multiSelect":false,"options":[{"label":"Redis","description":"Shared, survives restarts"},{"label":"In-process","description":"Fastest; lost on restart"},{"label":"Say \"none\"","description":"Café — no cache"}]},{"question":"Which platforms?","header":"Platforms","multiSelect":true,"options":[{"label":"macOS","description":"bash 3.2"},{"label":"Linux","description":"bash 5"}]}]}}' > "$PAYLOAD"

# Run the hook in the background: $1 tag, $2 session id, $3 entry id, $4 payload.
# Writes $WORK/<tag>.out / .err / .rc and sets BG_PID.
_run_bg() {
  local tag="$1" sid="$2" entry="$3" payload="${4:-$PAYLOAD}"
  rm -f "$WORK/$tag.out" "$WORK/$tag.err" "$WORK/$tag.rc"
  ( cd "$SB" && CLAUDE_HEADLESS=1 REPO_OS_SESSION_ID="$sid" REPO_OS_AUTOMATION_ENTRY="$entry" \
      bash "$HOOK" < "$payload" > "$WORK/$tag.out" 2> "$WORK/$tag.err"; echo $? > "$WORK/$tag.rc" ) &
  BG_PID=$!
}
_wait_rc() {  # $1 tag, $2 max seconds
  local i=0
  while [ ! -s "$WORK/$1.rc" ] && [ "$i" -lt $(( ${2:-20} * 10 )) ]; do sleep 0.1; i=$((i+1)); done
  cat "$WORK/$1.rc" 2>/dev/null || echo "none"
}
_wait_file() {  # $1 path, $2 max seconds
  local i=0
  while [ ! -f "$1" ] && [ "$i" -lt $(( ${2:-10} * 10 )) ]; do sleep 0.1; i=$((i+1)); done
  [ -f "$1" ]
}
# Write an answer the way the contract requires: temporary name, then mv.
_answer() {  # $1 id, $2 body
  printf '%s' "$2" > "$QDIR/.$1.answer.tmp" && mv "$QDIR/.$1.answer.tmp" "$QDIR/$1.answer.yaml"
}
_good_answer() {  # $1 id
  printf 'format_version: 1\nquestion_id: "%s"\noperator: "test-operator"\nanswered_at: "2026-10-28T00:00:00Z"\nanswers:\n  - question_index: 0\n    selected:\n      - "In-process"\n    free_text: "Keep it simple for now"\n  - question_index: 1\n    selected:\n      - "macOS"\n      - "Linux"\n    free_text: ""\n' "$1"
}

# ---------------------------------------------------------------------------
printf "\n# --- interactive sessions are untouched ---\n"
_reset_questions; _set_timeout 30
for _hv in unset 0 true; do
  _s=$(date +%s)
  if [ "$_hv" = unset ]; then
    _out=$( (cd "$SB" && unset CLAUDE_HEADLESS && bash "$HOOK" < "$PAYLOAD") 2>&1 ); _rc=$?
  else
    _out=$( (cd "$SB" && CLAUDE_HEADLESS="$_hv" bash "$HOOK" < "$PAYLOAD") 2>&1 ); _rc=$?
  fi
  _el=$(( $(date +%s) - _s ))
  _tap_eq "$_rc" "0" "interactive (CLAUDE_HEADLESS=$_hv): exit 0"
  _tap_eq "$_out" "" "interactive (CLAUDE_HEADLESS=$_hv): no output"
  _tap_true "[ $_el -le 1 ]" "interactive (CLAUDE_HEADLESS=$_hv): no wait (${_el}s)"
done
_tap_true "[ ! -e '$QDIR' ]" "interactive: no questions directory, no record written"

# ---------------------------------------------------------------------------
printf "\n# --- the record reproduces the payload ---\n"
_reset_questions; _set_timeout 20
_run_bg rec "sess-rec" "entry-rec"
_wait_file "$QDIR/q-000001.yaml" 10
_tap_true "[ -f '$QDIR/q-000001.yaml' ]" "headless: question record q-000001.yaml written"
if cmp -s "$PAYLOAD" "$QDIR/q-000001.payload.json"; then
  _tap_pass "payload copy is byte-for-byte the tool payload"
else
  _tap_fail "payload copy is byte-for-byte the tool payload" "cmp differs"
fi
REC="$(cat "$QDIR/q-000001.yaml" 2>/dev/null)"
_tap_contains "$REC" 'format_version: 1' "record: format_version 1"
_tap_contains "$REC" 'session_id: "sess-rec"' "record: session id"
_tap_contains "$REC" 'entry_id: "entry-rec"' "record: entry id"
_tap_contains "$REC" 'parsed: true' "record: parsed from the payload"
# Every field, compared against jq's own reading of the payload, in order.
if command -v jq >/dev/null 2>&1; then
  _expected=$(jq -r '.tool_input.questions[] | (.question|tojson), (.header|tojson), (.multiSelect|tojson), (.options[] | (.label|tojson), (.description|tojson))' "$PAYLOAD")
  _actual=$(sed -n 's/^    question: //p; s/^    header: //p; s/^    multi_select: //p; s/^      - label: //p; s/^        description: //p' "$QDIR/q-000001.yaml")
  _tap_eq "$_actual" "$_expected" "record: question, header, multiSelect and every option label+description, in payload order"
else
  _tap_fail "record: field-by-field comparison" "jq not installed"
fi
_tap_contains "$REC" 'label: "Say \"none\""' "record: quotes survive encoding"
_tap_contains "$REC" 'multi_select: true' "record: multiSelect true carried"
_tap_contains "$REC" 'multi_select: false' "record: multiSelect false carried"

printf "\n# --- an answer comes back in the same session ---\n"
_answer q-000001 "$(_good_answer q-000001)"
_rc=$(_wait_rc rec 15)
_tap_eq "$_rc" "2" "answered: hook denies with exit 2 (stderr returns to the same agent)"
ERR="$(cat "$WORK/rec.err" 2>/dev/null)"
_tap_contains "$ERR" '"In-process"' "answered: selected label carried verbatim"
_tap_contains "$ERR" '"macOS", "Linux"' "answered: multi-select labels carried verbatim, in order"
_tap_contains "$ERR" '"Keep it simple for now"' "answered: free text carried verbatim"
_tap_contains "$ERR" 'Continue the task using this answer' "answered: agent is told to continue"
_tap_contains "$(cat "$WORK/rec.out" 2>/dev/null)" '"decision": "deny"' "answered: deny decision on stdout"
_tap_lacks "$ERR" 'STOPPED' "answered: no stop instruction"
_tap_true "[ ! -f '$QDIR/q-000001.closed' ]" "answered: no expiry marker"
_tap_eq "$(ls "$ADIR/escalations" | wc -l | tr -d ' ')" "0" "answered: no escalation written"
_tap_true "_lib && ! qc_is_open '$ADIR' q-000001" "answered: question no longer open"
# Same session and worktree: the hook returns to its caller; nothing is relaunched.
_tap_eq "$(sed -n 's/^session_id: //p' "$QDIR/q-000001.yaml")" '"sess-rec"' "answered: record bound to the asking session id"

# ---------------------------------------------------------------------------
printf "\n# --- timeout parks the question (Decision t-0068) ---\n"
# t-0064 stopped the session and escalated here; since t-0068 the default
# (question_on_timeout: pause) parks instead. test-question-park.sh covers the
# runner, queue-cli and agent-decides sides.
_reset_questions; _set_timeout 2
_s=$(date +%s)
_run_bg to "sess-to" "entry-to"
_rc=$(_wait_rc to 20)
_el=$(( $(date +%s) - _s ))
_tap_eq "$_rc" "0" "timeout: hook ends the run (exit 0 with continue:false), not a denial"
_tap_true "[ $_el -ge 2 ] && [ $_el -le 10 ]" "timeout: waited the configured window (${_el}s)"
_tap_contains "$(cat "$WORK/to.out" 2>/dev/null)" '"continue": false' "timeout: continue:false"
_tap_lacks "$(cat "$WORK/to.err" 2>/dev/null)" 'STOPPED' "timeout: no stop-and-summarise instruction"
_tap_contains "$(cat "$QDIR/q-000001.closed" 2>/dev/null)" 'reason: parked' "timeout: question closed as parked"
_tap_lacks "$(cat "$QDIR/q-000001.closed" 2>/dev/null)" 'expired' "timeout: never closed as expired"
_tap_eq "$(ls "$ADIR/escalations" | wc -l | tr -d ' ')" "0" "timeout: no escalation"
# A late answer is VALID now: the parked question stays answerable.
_answer q-000001 "$(_good_answer q-000001)"
_tap_true "_lib && qc_read_answer '$ADIR' q-000001 >/dev/null 2>&1" "timeout: a late answer is read as an answer"
_tap_true "_lib && ! qc_is_open '$ADIR' q-000001" "timeout: a parked question is not in its live wait"

# ---------------------------------------------------------------------------
printf "\n# --- an unrecordable question stops instead of guessing ---\n"
_reset_questions; _set_timeout 30
mkdir -p "$QDIR"; chmod 555 "$QDIR"
_s=$(date +%s)
_out=$( (cd "$SB" && CLAUDE_HEADLESS=1 REPO_OS_SESSION_ID=s-ro REPO_OS_AUTOMATION_ENTRY=entry-ro bash "$HOOK" < "$PAYLOAD") 2>&1 ); _rc=$?
_el=$(( $(date +%s) - _s ))
chmod 755 "$QDIR"
_tap_eq "$_rc" "2" "unwritable questions dir: exit 2, not allowed through"
_tap_true "[ $_el -le 3 ]" "unwritable questions dir: fails fast, does not spin toward the hook timeout (${_el}s)"
_tap_contains "$_out" 'STOPPED' "unwritable questions dir: stop instruction"
_tap_contains "$(cat "$ADIR"/escalations/*.yaml 2>/dev/null)" 'queue_entry_id: "entry-ro"' "unwritable questions dir: escalation still written"

# ---------------------------------------------------------------------------
printf "\n# --- no path tells the agent to guess ---\n"
_hits=$(grep -n -i -E 'best judg|own judg|use your judg|make (a|an|your) (best )?(guess|assumption)|assume the|proceed anyway|guess (the|an) answer' \
  "$REAL_REPO/.claude/hooks/ask-user-deny.sh" \
  "$REAL_REPO/.claude/.automation/lib/question-channel.sh" \
  "$REAL_REPO/.claude/.automation/lib/prompt-assembler.sh" \
  "$REAL_REPO/.claude/.automation/templates/"*.md 2>/dev/null | grep -v -i 'do not guess' || true)
_tap_eq "$_hits" "" "no instruction to guess in the hook, channel, prompt assembler or session templates"
_tap_lacks "$(cat "$WORK"/*.err 2>/dev/null)" 'best judgment' "no run in this suite emitted 'best judgment'"
_hits=$(grep -n -i 'AskUserQuestion' "$REAL_REPO/.claude/.automation/lib/prompt-assembler.sh" \
  "$REAL_REPO/.claude/.automation/templates/"*.md "$REAL_REPO/AI.md" "$REAL_REPO/.claude/.automation/runner.sh" 2>/dev/null \
  | grep -i -E 'do not use|mechanically blocked|blocks .?AskUserQuestion' || true)
_tap_eq "$_hits" "" "headless prompt, session templates, runner and AI.md no longer say AskUserQuestion is blocked or forbidden"
# A template's ask line must match the tool list its own profile gets: audit and
# judge keep AskUserQuestion disallowed, every other profile allows it.
_bad=""
for _t in "$REAL_REPO/.claude/.automation/templates/"*.md; do
  _p=$(grep -o -E 'Permission profile: [a-z]+' "$_t" 2>/dev/null | head -1 | sed 's/.*: //')
  grep -q 'AskUserQuestion' "$_t" 2>/dev/null || continue
  case "$_p" in
    audit|judge) grep -q 'waits for the operator' "$_t" && _bad="$_bad $(basename "$_t")" ;;
    *) grep -q 'not available' "$_t" && _bad="$_bad $(basename "$_t")" ;;
  esac
done
_tap_eq "$_bad" "" "each session template's AskUserQuestion line matches its permission profile"
_tap_true "grep -q 'audit|judge)' '$REAL_REPO/.claude/.automation/lib/prompt-assembler.sh'" "prompt: audit/judge profiles get a line that matches their disallowed tool"

# ---------------------------------------------------------------------------
printf "\n# --- malformed or absent answers are no answer ---\n"
_reset_questions; _set_timeout 3
_run_bg mal "sess-mal" "entry-mal"
_wait_file "$QDIR/q-000001.yaml" 10
for _bad in garbage wrong-id wrong-version no-answers empty-selection binary; do
  case "$_bad" in
    garbage) _body=$'{{{ not yaml\n  - :\n' ;;
    wrong-id) _body="$(_good_answer q-000099)" ;;
    wrong-version) _body="$(_good_answer q-000001 | sed 's/^format_version: 1/format_version: 2/')" ;;
    no-answers) _body=$'format_version: 1\nquestion_id: "q-000001"\n' ;;
    empty-selection) _body=$'format_version: 1\nquestion_id: "q-000001"\nanswers:\n  - question_index: 0\n    selected: []\n    free_text: ""\n' ;;
    binary) _body="$(printf 'format_version: 1\nquestion_id: \001\377\n')" ;;
  esac
  _answer q-000001 "$_body"
  if ! _lib; then
    _tap_fail "malformed answer ($_bad) is not an answer" "library not loaded"
  elif qc_read_answer "$ADIR" q-000001 >/dev/null 2>&1; then
    _tap_fail "malformed answer ($_bad) is not an answer"
  else
    _tap_pass "malformed answer ($_bad) is not an answer"
  fi
  sleep 0.3
done
_rc=$(_wait_rc mal 20)
_tap_eq "$_rc" "0" "malformed answers: hook did not abort; it timed out normally and parked (exit 0)"
_tap_contains "$(cat "$QDIR/q-000001.closed" 2>/dev/null)" 'reason: parked' "malformed answers: treated as no answer, parked on timeout"
rm -f "$QDIR/q-000001.answer.yaml"
_tap_true "_lib && ! qc_read_answer '$ADIR' q-000001 >/dev/null 2>&1" "absent answer file is no answer"
# The good-answer shape must be accepted, or every 'not an answer' above is vacuous.
_answer q-000001 "$(_good_answer q-000001)"
_tap_true "_lib && qc_read_answer '$ADIR' q-000001 >/dev/null 2>&1" "control: a well-formed answer IS read as an answer"

# ---------------------------------------------------------------------------
printf "\n# --- concurrent questions do not collide ---\n"
_reset_questions; _set_timeout 20
printf '%s' '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Question from A","header":"A","multiSelect":false,"options":[{"label":"A1","description":"a"}]}]}}' > "$WORK/pa.json"
printf '%s' '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Question from B","header":"B","multiSelect":false,"options":[{"label":"B1","description":"b"}]}]}}' > "$WORK/pb.json"
_run_bg ca "sess-A" "entry-A" "$WORK/pa.json"; _pa=$BG_PID
_run_bg cb "sess-B" "entry-B" "$WORK/pb.json"; _pb=$BG_PID
_wait_file "$QDIR/q-000001.yaml" 10; _wait_file "$QDIR/q-000002.yaml" 10
_tap_true "[ -f '$QDIR/q-000001.yaml' ] && [ -f '$QDIR/q-000002.yaml' ]" "concurrent: two distinct question ids"
_ida=$(grep -l 'session_id: "sess-A"' "$QDIR"/q-00000?.yaml 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.yaml$//')
_idb=$(grep -l 'session_id: "sess-B"' "$QDIR"/q-00000?.yaml 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.yaml$//')
_tap_true "[ -n '$_ida' ] && [ -n '$_idb' ] && [ '$_ida' != '$_idb' ]" "concurrent: each session owns exactly one record ($_ida, $_idb)"
_tap_contains "$(cat "$QDIR/$_ida.yaml" 2>/dev/null)" 'Question from A' "concurrent: A's record holds A's question"
_tap_contains "$(cat "$QDIR/$_idb.yaml" 2>/dev/null)" 'Question from B' "concurrent: B's record holds B's question"
_answer "$_idb" "$(printf 'format_version: 1\nquestion_id: "%s"\nanswers:\n  - question_index: 0\n    selected:\n      - "B1"\n    free_text: ""\n' "$_idb")"
_tap_eq "$(_wait_rc cb 15)" "2" "concurrent: B answered"
_tap_true "[ ! -s '$WORK/ca.rc' ]" "concurrent: A still waiting — B's answer was not read by A"
_answer "$_ida" "$(printf 'format_version: 1\nquestion_id: "%s"\nanswers:\n  - question_index: 0\n    selected:\n      - "A1"\n    free_text: ""\n' "$_ida")"
_tap_eq "$(_wait_rc ca 15)" "2" "concurrent: A answered"
_tap_contains "$(cat "$WORK/ca.err")" '"A1"' "concurrent: A received A's answer"
_tap_lacks "$(cat "$WORK/ca.err")" '"B1"' "concurrent: A did not receive B's answer"
_tap_contains "$(cat "$WORK/cb.err")" '"B1"' "concurrent: B received B's answer"
_tap_eq "$(cat "$QDIR/.seq" 2>/dev/null | tr -d '[:space:]')" "2" "concurrent: sequence advanced once per question"

printf "\n# --- id allocation is unique without trusting the lock ---\n"
_reset_questions; mkdir -p "$QDIR"
# Lost counter with old files left behind: their ids must not be reused, or a
# new question would read a stale answer at once.
printf 'format_version: 1\n' > "$QDIR/q-000001.yaml"
_good_answer q-000002 > "$QDIR/q-000002.answer.yaml"
# A pre-t-0068 close marker: `expired` is no longer written, but old records keep it.
printf 'reason: expired\n' > "$QDIR/q-000003.closed"
_tap_eq "$(qc_next_id "$ADIR" 2>/dev/null)" "q-000004" "lost .seq: ids with existing record/answer/close files are skipped"
# A stale lock (holder killed) is removed once and does not stop allocation.
mkdir -p "$QDIR/.seq.lock"; touch -t 202001010000 "$QDIR/.seq.lock"
_tap_eq "$(qc_next_id "$ADIR" 2>/dev/null)" "q-000005" "stale lock: removed and allocation proceeds"
# A lock held throughout (live holder): allocation still succeeds, uniquely.
mkdir -p "$QDIR/.seq.lock"
( qc_next_id "$ADIR" > "$WORK/l1" 2>/dev/null ) & _l1=$!
( qc_next_id "$ADIR" > "$WORK/l2" 2>/dev/null ) & _l2=$!
wait "$_l1"; wait "$_l2"
rmdir "$QDIR/.seq.lock" 2>/dev/null
_tap_true "[ -n \"\$(cat '$WORK/l1')\" ] && [ -n \"\$(cat '$WORK/l2')\" ] && [ \"\$(cat '$WORK/l1')\" != \"\$(cat '$WORK/l2')\" ]" "held lock: two concurrent allocations both succeed with distinct ids ($(cat "$WORK/l1"), $(cat "$WORK/l2"))"
# Burst: 8 allocations at once, no lock contention avoided, all distinct.
: > "$WORK/burst"
for _b in 1 2 3 4 5 6 7 8; do ( qc_next_id "$ADIR" >> "$WORK/burst.$_b" 2>/dev/null ) & done; wait
# qc_next_id prints no trailing newline; split on the ids, not on lines.
cat "$WORK"/burst.? 2>/dev/null | grep -o 'q-[0-9]\{6\}' > "$WORK/burst"
_tap_eq "$(sort -u "$WORK/burst" | wc -l | tr -d ' ')" "8" "burst of 8 concurrent allocations: 8 distinct ids"

# ---------------------------------------------------------------------------
printf "\n# --- timeout cap stays under the hook timeout ---\n"
_set_timeout 14400 600;   _tap_eq "$(qc_effective_timeout "$ADIR")" "570" "cap: 4h wanted, 600s hook timeout -> 570s"
_set_timeout 14400 14430; _tap_eq "$(qc_effective_timeout "$ADIR")" "14400" "cap: 4h wanted, 14430s hook timeout -> 14400s"
_set_timeout abc 600;     _tap_eq "$(qc_effective_timeout "$ADIR")" "570" "cap: non-numeric timeout -> default, capped"
rm -f "$ADIR/config.yaml"; _tap_eq "$(qc_effective_timeout "$ADIR")" "570" "cap: no config -> defaults (1800 capped to 570)"
# The SHIPPED config must also land under the shipped hook timeout (600 unless
# settings.json sets one), or the hook would be killed and fail open.
cp "$REAL_REPO/.claude/.automation/config.yaml" "$ADIR/config.yaml"
_shipped_hook=$(qc_config_int "$ADIR" question_hook_timeout_seconds 600)
_settings_to=$(jq -r '[.hooks.PreToolUse[]? | select(.matcher=="AskUserQuestion") | .hooks[]? | select((.command // "") | test("ask-user-deny")) | .timeout // 600] | first // 600' "$REAL_REPO/.claude/settings.json" 2>/dev/null)
_tap_true "[ $(qc_effective_timeout "$ADIR") -lt ${_settings_to:-600} ]" "cap: shipped config waits less than the settings.json hook timeout (${_settings_to:-600}s)"
_tap_eq "$_shipped_hook" "${_settings_to:-600}" "cap: config question_hook_timeout_seconds mirrors settings.json"

# ---------------------------------------------------------------------------
printf "\n# --- runner: awaiting-answer health and circuit breaker ---\n"
_RUNNER_SRC="$REAL_REPO/.claude/.automation/runner.sh"
_extract_runner_fn() {
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\) \\{" { inside=1 }
    inside { print }
    inside && /^}$/ { exit }
  ' "$_RUNNER_SRC"
}
{
  _extract_runner_fn "_entry_health_status"
  _extract_runner_fn "_record_question_pause_at_exit"
  _extract_runner_fn "_start_force_halt_watcher"
} > "$WORK/runner-fns.sh"
# shellcheck disable=SC1091
source "$WORK/runner-fns.sh" 2>/dev/null
for _fn in _entry_health_status _record_question_pause_at_exit _start_force_halt_watcher; do
  if type "$_fn" >/dev/null 2>&1; then _tap_pass "extracted $_fn from runner.sh"; else _tap_fail "extracted $_fn from runner.sh" "not found"; fi
done

_reset_questions; _set_timeout 20
_tap_eq "$(_entry_health_status entry-h 2>/dev/null)" "running" "health: no question -> running"
_run_bg h "sess-h" "entry-h"
_wait_file "$QDIR/q-000001.yaml" 10
_tap_eq "$(_entry_health_status entry-h 2>/dev/null)" "awaiting-answer" "health: open question -> awaiting-answer"
_tap_eq "$(_entry_health_status entry-other 2>/dev/null)" "running" "health: another entry's question does not pause this one"
_answer q-000001 "$(_good_answer q-000001)"
_wait_rc h 15 >/dev/null
_tap_eq "$(_entry_health_status entry-h 2>/dev/null)" "running" "health: answered -> running"

# Breaker: a session ended while paused is flagged and its question closed.
_reset_questions; _set_timeout 20
_run_bg br "sess-br" "entry-br"; _brpid=$BG_PID
_wait_file "$QDIR/q-000001.yaml" 10
kill -TERM "$_brpid" 2>/dev/null; sleep 0.5
_ENTRY_PAUSED_AT_EXIT=false
_record_question_pause_at_exit entry-br 2>/dev/null
_tap_eq "$_ENTRY_PAUSED_AT_EXIT" "true" "breaker: a session ended while awaiting an answer is flagged paused-at-exit"
_tap_contains "$(cat "$QDIR/q-000001.closed" 2>/dev/null)" 'reason: abandoned' "breaker: its open question is closed as abandoned"
_tap_true "[ -f '$QDIR/q-000001.yaml' ]" "breaker: the record stays on disk"
_record_question_pause_at_exit entry-br 2>/dev/null
_tap_eq "$_ENTRY_PAUSED_AT_EXIT" "false" "breaker: no open question -> not flagged"
# The failure arm reads the flag before incrementing; the flag is reset per entry.
_arm=$(awk '/Rebase conflict — not counted against the circuit breaker/{f=1} f{print} f && /_circuit_breaker_increment/{exit}' "$_RUNNER_SRC")
_tap_contains "$_arm" '_ENTRY_PAUSED_AT_EXIT:-false}" = true' "breaker: failure arm exempts a paused-at-exit session before _circuit_breaker_increment"
_reset=$(awk '/^_run_single_entry\(\) \{/{f=1} f{print} f && /_RESULT_BASELINE=""/{exit}' "$_RUNNER_SRC")
_tap_contains "$_reset" '_ENTRY_PAUSED_AT_EXIT=false' "breaker: flag reset at the start of every entry"
_tap_true "grep -q '_record_question_pause_at_exit \"\$brief_id\"' '$_RUNNER_SRC'" "breaker: runner records pause state after the child exits"
_tap_true "grep -q '_write_health \"\$(_entry_health_status \"\$entry_id\")\"' '$_RUNNER_SRC'" "health: heartbeat writes the entry's health status"

# ---------------------------------------------------------------------------
printf "\n# --- FORCE-HALT kills a paused session and leaves the record ---\n"
_reset_questions; _set_timeout 120
rm -f "$ADIR/FORCE-HALT"
# Stand-in for the claude child: a shell whose child is the hook. `exec`, as at
# the runner's launch site: without it $! is the wrapping subshell, the watcher
# kills that, and the real parent of the hook survives.
( cd "$SB" && CLAUDE_HEADLESS=1 REPO_OS_SESSION_ID=sess-fh REPO_OS_AUTOMATION_ENTRY=entry-fh \
    exec bash -c 'bash "$1" < "$2" > /dev/null 2>&1 & echo $! > "$3"; wait' _ "$HOOK" "$PAYLOAD" "$WORK/fh-hook.pid" ) &
_child=$!
_wait_file "$QDIR/q-000001.yaml" 10
_hookpid=$(cat "$WORK/fh-hook.pid" 2>/dev/null)
_tap_eq "$(_entry_health_status entry-fh 2>/dev/null)" "awaiting-answer" "FORCE-HALT fixture: entry is paused"
_start_force_halt_watcher "$_child"
touch "$ADIR/FORCE-HALT"
_i=0; while kill -0 "$_child" 2>/dev/null && [ "$_i" -lt 200 ]; do sleep 0.1; _i=$((_i+1)); done
_tap_true "! kill -0 $_child 2>/dev/null" "FORCE-HALT: watcher terminated the paused child on its next poll"
_i=0; while [ -n "$_hookpid" ] && kill -0 "$_hookpid" 2>/dev/null && [ "$_i" -lt 150 ]; do sleep 0.1; _i=$((_i+1)); done
_tap_true "[ -n '$_hookpid' ] && ! kill -0 $_hookpid 2>/dev/null" "FORCE-HALT: the orphaned hook stopped polling"
_tap_true "[ -f '$QDIR/q-000001.yaml' ] && [ -f '$QDIR/q-000001.payload.json' ]" "FORCE-HALT: question record left on disk"
_tap_true "[ ! -f '$QDIR/q-000001.closed' ]" "FORCE-HALT: the hook did not expire the question on its way out"
_tap_eq "$(ls "$ADIR/escalations" | wc -l | tr -d ' ')" "0" "FORCE-HALT: no timeout escalation"
rm -f "$ADIR/FORCE-HALT"
[ -n "${_FORCE_HALT_WATCHER_PID:-}" ] && { kill "$_FORCE_HALT_WATCHER_PID" 2>/dev/null; wait "$_FORCE_HALT_WATCHER_PID" 2>/dev/null; }

# ---------------------------------------------------------------------------
printf "\n# --- permission profiles reach the hook ---\n"
# shellcheck disable=SC1091
source "$REAL_REPO/.claude/.automation/lib/permission-profiles.sh" 2>/dev/null
set +e
for _p in build strict default; do
  _tap_lacks "$(get_disallowed_tools "$_p")" 'AskUserQuestion' "profile $_p: AskUserQuestion not disallowed (the hook can run)"
done
for _p in audit judge; do
  _tap_contains "$(get_disallowed_tools "$_p")" 'AskUserQuestion' "profile $_p: AskUserQuestion still disallowed"
done

# ---------------------------------------------------------------------------
printf "\n# --- Questions-Guard: no agent write reaches questions/ (Decision t-0070) ---\n"
# Records come from this hook and answers from queue-cli, never a tool write:
# an answer written directly would be delivered as the operator's.
_wg() {  # tool-json -> exit code; stderr in _WG_ERR
  _WG_ERR=$(cd "$SB" && printf '%s' "$1" | bash "$SB/.claude/hooks/write-guard.sh" 2>&1 >/dev/null)
}
_wg "$(printf '{"tool_name":"Write","session_id":"wg","tool_input":{"file_path":"%s","content":"x"}}' "$QDIR/q-000009.answer.yaml")"; _rc=$?
_tap_eq "$_rc" "2" "Questions-Guard: a Write to an answer file is refused"
_tap_contains "$_WG_ERR" 'questions/ is write-protected' "Questions-Guard: says why"
_wg "$(printf '{"tool_name":"Edit","session_id":"wg","tool_input":{"file_path":"%s","old_string":"a","new_string":"b"}}' "$QDIR/q-000009.yaml")"; _rc=$?
_tap_eq "$_rc" "2" "Questions-Guard: an Edit of a question record is refused"
_wg '{"tool_name":"Bash","session_id":"wg","tool_input":{"command":"printf x > .claude/.automation/questions/q-000009.answer.yaml"}}'; _rc=$?
_tap_eq "$_rc" "2" "Questions-Guard: a Bash redirect into questions/ is refused"
# The Write path is matched after resolving, so '.' and '//' segments hide nothing.
_wg "$(printf '{"tool_name":"Write","session_id":"wg","tool_input":{"file_path":"%s","content":"x"}}' "$SB/.claude/./.automation/questions/q-000009.answer.yaml")"; _rc=$?
_tap_eq "$_rc" "2" "Questions-Guard: a Write through a './' segment is refused"
_wg "$(printf '{"tool_name":"Write","session_id":"wg","tool_input":{"file_path":"%s","content":"x"}}' "$SB/.claude/.automation//questions/q-000009.answer.yaml")"; _rc=$?
_tap_eq "$_rc" "2" "Questions-Guard: a Write through a '//' segment is refused"
_wg "$(printf '{"tool_name":"Write","session_id":"wg","tool_input":{"file_path":"%s","content":"x"}}' "$ADIR/questions-notes.md")"
_tap_lacks "$_WG_ERR" 'questions/ is write-protected' "Questions-Guard: a sibling path is not mistaken for questions/"
_WG_ERR=$(cd "$SB" && printf '{"tool_name":"Write","session_id":"wg","tool_input":{"file_path":"%s","content":"x"}}' "$QDIR/q-000009.answer.yaml" \
  | REPO_OS_RECOVER=1 bash "$SB/.claude/hooks/write-guard.sh" 2>&1 >/dev/null)
_tap_lacks "$_WG_ERR" 'questions/ is write-protected' "Questions-Guard: REPO_OS_RECOVER=1 overrides it"
# questions/ is shared through the main repo (t-0064); a worktree session's
# absolute path to it lies outside the worktree's own root. git names the main
# repo by its physical path (/private/tmp on macOS), so the target does too.
_WT="$SB-wt"
_QDIR_P=$(cd "$QDIR" && pwd -P)
rm -rf "$_WT"
if git -C "$SB" worktree add -q -b qc-wg-wt "$_WT" >/dev/null 2>&1; then
  _WG_ERR=$(cd "$_WT" && printf '{"tool_name":"Write","session_id":"wg","tool_input":{"file_path":"%s","content":"x"}}' "$_QDIR_P/q-000009.answer.yaml" \
    | _REPO_OS_TEST_ROOT="$_WT" bash "$SB/.claude/hooks/write-guard.sh" 2>&1 >/dev/null); _rc=$?
  _tap_eq "$_rc" "2" "Questions-Guard: a worktree session's write to the main repo's questions/ is refused"
  git -C "$SB" worktree remove --force "$_WT" >/dev/null 2>&1; git -C "$SB" branch -D qc-wg-wt >/dev/null 2>&1
else
  _tap_fail "Questions-Guard: fixture: worktree of the sandbox" "git worktree add failed"
fi

printf "\n1..%d\n" "$_TAP_NUM"
printf "# pass %d fail %d\n" "$_TAP_PASS" "$_TAP_FAIL"
[ "$_TAP_FAIL" -eq 0 ]
