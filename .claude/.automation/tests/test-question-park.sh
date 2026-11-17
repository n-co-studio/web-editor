#!/usr/bin/env bash
# Question park — Decision t-0068 (amends t-0064)
#
# An unanswered headless question no longer expires. Under the default
# question_on_timeout: pause the hook parks the question and ends the run like
# a graceful stop; `queue-cli.sh answer` resumes the same Claude session with
# the answer as its first message. Under agent-decides the agent is told to
# choose and continue, and an advisory escalation records the question.
#
# Runs the real hook, the real question-channel library, functions extracted
# from the real runner.sh and the real queue-cli.sh against a sandbox — never
# the real queue, escalations or questions directory. The runner's post-exit
# block is inline in _run_single_entry and cannot be extracted, so the stop-mode
# mapping is checked structurally as well as through the pieces it calls.
# Bash 3.2 compatible.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/sandbox-setup.sh"
set +e

_TAP_NUM=0; _TAP_PASS=0; _TAP_FAIL=0
_tap_pass() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_PASS=$((_TAP_PASS+1)); printf "ok %d - %s\n" "$_TAP_NUM" "$1"; }
_tap_fail() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_FAIL=$((_TAP_FAIL+1)); printf "not ok %d - %s\n" "$_TAP_NUM" "$1"; [ -n "${2:-}" ] && printf "  # %s\n" "$2"; }
_tap_eq() { if [ "$1" = "$2" ]; then _tap_pass "$3"; else _tap_fail "$3" "expected '$2', got '$1'"; fi; }
_tap_contains() { case "$1" in *"$2"*) _tap_pass "$3" ;; *) _tap_fail "$3" "output did not contain '$2'" ;; esac; }
_tap_lacks() { case "$1" in *"$2"*) _tap_fail "$3" "output contained '$2'" ;; *) _tap_pass "$3" ;; esac; }
_tap_true() { if eval "$1"; then _tap_pass "$2"; else _tap_fail "$2" "condition false: $1"; fi; }

printf "# === Question park (Decision t-0068) ===\n"

setup_adversarial_sandbox >/dev/null 2>&1
set +e
trap 'teardown_adversarial_sandbox >/dev/null 2>&1' EXIT
SB="$ADV_SANDBOX"
ADIR="$SB/.claude/.automation"
QDIR="$ADIR/questions"
HOOK="$SB/.claude/hooks/ask-user-deny.sh"
CLI="$ADIR/queue-cli.sh"
# The sandbox does not carry queue-cli.sh; run the real one against it.
cp "$_ADV_REAL_REPO/.claude/.automation/queue-cli.sh" "$CLI"
WORK="$SB/.qp-test"
mkdir -p "$WORK"
REPO_ROOT="$SB"; export REPO_ROOT
AUTOMATION_DIR="$ADIR"; export AUTOMATION_DIR
export CONFIG_FILE="$ADIR/config.yaml"
cd "$SB" || exit 1
# Pin the main repo root to the sandbox (see test-operator-control.sh): the
# control directory resolves through get_main_repo_root().
# shellcheck disable=SC1091
source "$SB/.claude/hooks/_analytics-helper.sh"
_CACHED_MAIN_REPO_ROOT="$SB"
_tap_eq "$(get_main_repo_root)" "$SB" "fixture: main repo root is pinned to the sandbox"

# shellcheck disable=SC1091
source "$ADIR/lib/question-channel.sh"
for _fn in qc_on_timeout qc_parked_for_entry qc_write_answer qc_text_answer qc_close_reason qc_question_summary; do
  if type "$_fn" >/dev/null 2>&1; then _tap_pass "library defines $_fn"; else _tap_fail "library defines $_fn" "not found"; fi
done

_config() {  # $1 question_timeout_seconds, $2 question_on_timeout (optional)
  {
    printf 'runner:\n  question_timeout_seconds: %s\n  question_hook_timeout_seconds: 600\n' "$1"
    [ -n "${2:-}" ] && printf '  question_on_timeout: %s\n' "$2"
    true
  } > "$ADIR/config.yaml"
}
_reset_questions() { rm -rf "$QDIR" "$ADIR/escalations"; mkdir -p "$ADIR/escalations"; }

PAYLOAD="$WORK/payload.json"
printf '%s' '{"session_id":"cc-1","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which store should the cache use?","header":"Cache","multiSelect":false,"options":[{"label":"Redis","description":"Shared"},{"label":"In-process","description":"Fastest"}]}]}}' > "$PAYLOAD"

# Run the hook synchronously: $1 tag, $2 entry, [$3 extra env assignment].
_run_hook() {
  local tag="$1" entry="$2"
  ( cd "$SB" && env CLAUDE_HEADLESS=1 REPO_OS_SESSION_ID="sess-$entry" REPO_OS_AUTOMATION_ENTRY="$entry" ${3:+"$3"} \
      bash "$HOOK" < "$PAYLOAD" > "$WORK/$tag.out" 2> "$WORK/$tag.err"; echo $? > "$WORK/$tag.rc" )
  cat "$WORK/$tag.rc"
}

# ---------------------------------------------------------------------------
printf "\n# --- config: question_on_timeout ---\n"
_config 30;                    _tap_eq "$(qc_on_timeout "$ADIR")" "pause" "absent -> pause"
_config 30 agent-decides;      _tap_eq "$(qc_on_timeout "$ADIR")" "agent-decides" "agent-decides read"
_config 30 '"agent-decides"';  _tap_eq "$(qc_on_timeout "$ADIR")" "agent-decides" "quoted value read"
_config 30 bogus;              _tap_eq "$(qc_on_timeout "$ADIR")" "pause" "invalid -> pause"
_config 30 pause
printf 'runner:\n  question_on_timeout: agent-decides\n' > "$ADIR/config.local.yaml"
_tap_eq "$(qc_on_timeout "$ADIR")" "agent-decides" "config.local.yaml overrides config.yaml"
rm -f "$ADIR/config.local.yaml"
rm -f "$ADIR/config.yaml"
_tap_eq "$(qc_on_timeout "$ADIR")" "pause" "no config -> pause"
printf 'runner:\n  question_hook_timeout_seconds: 14430\n' > "$ADIR/config.yaml"
_tap_eq "$(qc_effective_timeout "$ADIR")" "1800" "question_timeout_seconds default is 1800"
_config 14400; _tap_eq "$(qc_effective_timeout "$ADIR")" "570" "the cap against question_hook_timeout_seconds is kept"
cp "$_ADV_REAL_REPO/.claude/.automation/config.yaml" "$ADIR/config.yaml"
_tap_eq "$(qc_config_int "$ADIR" question_timeout_seconds 0)" "1800" "shipped config: question_timeout_seconds 1800"
_tap_eq "$(qc_on_timeout "$ADIR")" "pause" "shipped config: question_on_timeout pause"
_tap_true "grep -q '^  question_on_timeout: pause\$' '$ADIR/config.yaml'" "shipped config writes question_on_timeout explicitly"
_ttl=$(sed -n 's/^  session_max_ttl_seconds: *//p' "$ADIR/config.yaml" | head -1)
_tap_true "[ 1800 -lt ${_ttl:-0} ]" "shipped config: question_timeout_seconds < session_max_ttl_seconds ($_ttl)"

# ---------------------------------------------------------------------------
printf "\n# --- pause: timeout 0 parks immediately ---\n"
_reset_questions; _config 0
_s=$(date +%s)
_rc=$(_run_hook park0 entry-p0)
_el=$(( $(date +%s) - _s ))
OUT="$(cat "$WORK/park0.out")"
_tap_eq "$_rc" "0" "park: exit 0 (a stop, not a denial the agent continues past)"
_tap_true "[ $_el -le 3 ]" "park: timeout 0 does not wait (${_el}s)"
_tap_contains "$OUT" '"continue": false' "park: continue:false ends the run at the tool boundary"
_tap_contains "$OUT" '"permissionDecision": "deny"' "park: the AskUserQuestion call itself is still denied"
_tap_contains "$OUT" 'Do not continue and do not guess an answer: end the session now' "park: the deny reason tells the agent to stop if the run were not ended"
_tap_contains "$OUT" 'queue-cli.sh answer entry-p0 --question q-000001' "park: stopReason tells the operator how to answer"
if command -v jq >/dev/null 2>&1; then
  _tap_true "jq -e '.continue == false' '$WORK/park0.out' >/dev/null 2>&1" "park: stdout is valid JSON"
fi
_tap_eq "$(qc_close_reason "$ADIR" q-000001)" "parked" "park: question closed as parked"
_tap_eq "$(ls "$ADIR/escalations" | wc -l | tr -d ' ')" "0" "park: no escalation"
_tap_eq "$(qc_parked_for_entry "$ADIR" entry-p0)" "q-000001" "park: qc_parked_for_entry finds it"
_tap_eq "$(qc_parked_for_entry "$ADIR" entry-other)" "" "park: another entry's park is not this one's"
_tap_eq "$(qc_parked_for_entry "$ADIR" entry-p0 $(( $(date +%s) + 100 )))" "" "park: a park created before the launch bound is not this launch's"

printf "\n# --- pause: a live wait that times out parks ---\n"
_reset_questions; _config 2
_rc=$(_run_hook park2 entry-p2)
_tap_eq "$_rc" "0" "park after a 2s wait: exit 0"
_tap_eq "$(qc_close_reason "$ADIR" q-000001)" "parked" "park after a 2s wait: closed as parked"

printf "\n# --- the session TTL deadline ends the live wait early ---\n"
_reset_questions; _config 600
_s=$(date +%s)
_rc=$(_run_hook ttl entry-ttl "REPO_OS_SESSION_DEADLINE_EPOCH=$(( _s + 62 ))")
_el=$(( $(date +%s) - _s ))
_tap_eq "$_rc" "0" "TTL clamp: parks (exit 0)"
_tap_true "[ $_el -le 8 ]" "TTL clamp: parked 60s before the session deadline, not after 600s (${_el}s)"
_tap_eq "$(qc_close_reason "$ADIR" q-000001)" "parked" "TTL clamp: closed as parked, not abandoned"
# A deadline already inside the margin parks at once rather than waiting.
_reset_questions
_s=$(date +%s)
_rc=$(_run_hook ttlpast entry-ttl "REPO_OS_SESSION_DEADLINE_EPOCH=$(( _s + 5 ))")
_tap_true "[ $(( $(date +%s) - _s )) -le 3 ] && [ '$_rc' = 0 ]" "TTL clamp: a deadline inside the 60s margin parks immediately"

# ---------------------------------------------------------------------------
printf "\n# --- no path writes reason: expired ---\n"
_hits=$(grep -n -E 'qc_close[^#]*expired|reason: expired' \
  "$_ADV_REAL_REPO/.claude/hooks/ask-user-deny.sh" \
  "$_ADV_REAL_REPO/.claude/.automation/runner.sh" \
  "$_ADV_REAL_REPO/.claude/.automation/queue-cli.sh" 2>/dev/null || true)
_tap_eq "$_hits" "" "hook, runner and queue-cli never close a question as expired"
_tap_lacks "$(sed -n '/^qc_close() {/,/^}/p' "$_ADV_REAL_REPO/.claude/.automation/lib/question-channel.sh")" 'expired' "qc_close has no expired default"

# ---------------------------------------------------------------------------
printf "\n# --- agent-decides ---\n"
_reset_questions; _config 0 agent-decides
_rc=$(_run_hook ad entry-ad)
ERR="$(cat "$WORK/ad.err")"
_tap_eq "$_rc" "2" "agent-decides: exit 2 (the denial reason reaches the agent and it continues)"
_tap_contains "$ERR" 'NO OPERATOR ANSWER to q-000001' "agent-decides: the agent is told there is no answer"
_tap_contains "$ERR" 'ASSUMPTION' "agent-decides: the agent is told to state its assumption"
_tap_contains "$ERR" 'continue the task' "agent-decides: the agent is told to continue"
_tap_lacks "$ERR" 'STOPPED' "agent-decides: no stop instruction"
_tap_lacks "$(cat "$WORK/ad.out")" '"continue": false' "agent-decides: the session is not ended"
_tap_eq "$(qc_close_reason "$ADIR" q-000001)" "agent-decided" "agent-decides: closed as agent-decided"
ESC="$(cat "$ADIR"/escalations/*.yaml 2>/dev/null)"
_tap_eq "$(ls "$ADIR/escalations" | wc -l | tr -d ' ')" "1" "agent-decides: one escalation"
_tap_contains "$ESC" 'severity: "advisory"' "agent-decides: escalation is advisory"
_tap_contains "$ESC" 'type: "ambiguity"' "agent-decides: escalation type ambiguity"
_tap_contains "$ESC" 'queue_entry_id: "entry-ad"' "agent-decides: escalation names the entry"
_tap_contains "$ESC" 'Which store should the cache use?' "agent-decides: escalation records the question"
_tap_contains "$ESC" 'Redis | In-process' "agent-decides: escalation records the options"
_tap_contains "$ESC" 'assumption' "agent-decides: escalation says where the assumption is recorded"
# The escalation must stay parseable: one quoted scalar per line.
_tap_eq "$(grep -c '^  message: "' "$ADIR"/escalations/*.yaml)" "1" "agent-decides: message is a single quoted scalar"
# It still routes to review (the user's choice) — detect_outcome counts it.
# shellcheck disable=SC1091
source "$ADIR/lib/outcome-detector.sh" 2>/dev/null
set +e
if type detect_outcome >/dev/null 2>&1; then
  _base=$(git -C "$SB" rev-parse HEAD 2>/dev/null)
  _oc=$(detect_outcome 0 "$_base" "$SB" "entry-ad" "$WORK/ad.err" "$WORK/ad.out" 2>/dev/null)
  _tap_eq "${_oc%%:*}" "review" "agent-decides: the entry ends in review (got '$_oc')"
else
  _tap_fail "agent-decides: the entry ends in review" "outcome-detector.sh not loadable"
fi

# ---------------------------------------------------------------------------
printf "\n# --- answers: building and writing ---\n"
_reset_questions; _config 0
_run_hook build entry-b >/dev/null
qc_text_answer q-000001 tester 'Use "Redis"
on two lines\back' > "$WORK/text-answer.yaml"
_tap_true "_qc_read_answer_file '$WORK/text-answer.yaml' q-000001 >/dev/null" "qc_text_answer builds a valid answer"
_tap_contains "$(_qc_read_answer_file "$WORK/text-answer.yaml" q-000001)" 'Use \"Redis\" on two lines\\back' "qc_text_answer escapes quotes and backslashes and flattens newlines"
printf 'format_version: 1\nquestion_id: "q-000001"\n' > "$WORK/bad-answer.yaml"
_rc=0; qc_write_answer "$ADIR" q-000001 "$WORK/bad-answer.yaml" || _rc=$?
_tap_eq "$_rc" "2" "qc_write_answer refuses an invalid answer (2)"
_tap_true "[ ! -f '$QDIR/q-000001.answer.yaml' ]" "an invalid answer is never published"
_tap_eq "$(ls -A "$QDIR" | grep -c 'answer\.')" "0" "no temporary file left behind"
_tap_true "qc_write_answer '$ADIR' q-000001 '$WORK/text-answer.yaml'" "qc_write_answer publishes a valid answer"
_rc=0; qc_write_answer "$ADIR" q-000001 "$WORK/text-answer.yaml" || _rc=$?
_tap_eq "$_rc" "3" "qc_write_answer does not replace an existing answer (3)"
_rc=0; qc_write_answer "$ADIR" q-000099 "$WORK/text-answer.yaml" || _rc=$?
_tap_eq "$_rc" "1" "qc_write_answer refuses a question with no record (1)"
# A planted symlink at an answer path is "an answer file exists", never written through.
_run_hook sym entry-sym >/dev/null
ln -s "$WORK/symlink-target" "$QDIR/q-000002.answer.yaml"
_rc=0; qc_write_answer "$ADIR" q-000002 "$WORK/text-answer.yaml" || _rc=$?
_tap_true "[ '$_rc' != 0 ] && [ ! -e '$WORK/symlink-target' ]" "qc_write_answer never writes through a symlink at the answer path"
rm -f "$QDIR/q-000002.answer.yaml"

# ---------------------------------------------------------------------------
printf "\n# --- runner: resume message and stop-mode mapping ---\n"
_RUNNER_SRC="$_ADV_REAL_REPO/.claude/.automation/runner.sh"
_extract_runner_fn() {
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\) \\{" { inside=1 }
    inside { print }
    inside && /^}$/ { exit }
  ' "$_RUNNER_SRC"
}
{
  _extract_runner_fn "_resume_message"
  _extract_runner_fn "_record_question_pause_at_exit"
} > "$WORK/runner-fns.sh"
# shellcheck disable=SC1091
source "$ADIR/lib/queue-manager.sh" 2>/dev/null
# shellcheck disable=SC1091
source "$ADIR/lib/file-lock.sh" 2>/dev/null
# shellcheck disable=SC1091
source "$WORK/runner-fns.sh"
set +e
for _fn in _resume_message _record_question_pause_at_exit; do
  if type "$_fn" >/dev/null 2>&1; then _tap_pass "extracted $_fn from runner.sh"; else _tap_fail "extracted $_fn from runner.sh" "not found"; fi
done

# The parked question from the section above (entry-b, q-000001) is answered.
_cd=$(ensure_control_dir entry-b)
printf 'claude_session_id: "cc-b"\nstopped_mode: "question"\nquestion_id: "q-000001"\n' > "$_cd/resume.yaml"
MSG="$(_resume_message entry-b question)"
_tap_contains "$MSG" 'OPERATOR ANSWER to q-000001 (AskUserQuestion is answered through the question channel in headless mode; the tool itself does not run):' "resume: first message uses the hook's answer wording"
_tap_contains "$MSG" 'Use \"Redis\"' "resume: first message carries the answer"
_tap_contains "$MSG" 'Continue the task using this answer.' "resume: the agent is told to continue with it"
_tap_contains "$MSG" 're-advance the phases' "resume: the phase-reset sentence is kept"
_tap_lacks "$MSG" 'force-stopped' "resume: no force note for a park"
# Same wording as the hook: both go through qc_answer_message, and nothing
# else spells the message out.
_tap_eq "${MSG%% Session state was reset*}" "$(qc_answer_message q-000001 "$(qc_read_answer "$ADIR" q-000001)")" "resume: the message is qc_answer_message's, verbatim"
_tap_eq "$(grep -c 'qc_answer_message "\$_qc_id" "\$_qc_answer"' "$_ADV_REAL_REPO/.claude/hooks/ask-user-deny.sh")" "2" "hook: both answer deliveries use qc_answer_message"
_tap_eq "$(grep -c "printf 'OPERATOR ANSWER to %s" "$_ADV_REAL_REPO/.claude/hooks/ask-user-deny.sh" "$_RUNNER_SRC" | awk -F: '{s+=$2} END {print s}')" "0" "no copy of the answer wording outside the library"
# No resume.yaml question id (no Claude session id was recorded): newest park.
rm -f "$_cd/resume.yaml"
_tap_contains "$(_resume_message entry-b question)" 'OPERATOR ANSWER to q-000001' "resume: falls back to the entry's newest parked question"
# A forced stop that raced the park keeps both notes.
printf 'claude_session_id: "cc-b"\nstopped_mode: "forced"\nquestion_id: "q-000001"\n' > "$_cd/resume.yaml"
MSG="$(_resume_message entry-b forced)"
_tap_contains "$MSG" 'OPERATOR ANSWER to q-000001' "resume after FORCE raced a park: answer still delivered"
_tap_contains "$MSG" 'force-stopped' "resume after FORCE raced a park: force note kept"
# Ordinary graceful resume is unchanged.
_tap_eq "$(_resume_message entry-none graceful)" "Resumed by operator. Session state was reset to the init phase at the stop, so re-advance the phases from where your work actually stands." "resume: graceful message unchanged"

# Structural: the inline post-exit block (not extractable).
_blk=$(awk '/^_run_single_entry\(\) \{/{f=1} f{print} f && /^}$/{exit}' "$_RUNNER_SRC")
_tap_contains "$_blk" '_parked_question=$(qc_parked_for_entry "$AUTOMATION_DIR" "$brief_id" "$_session_launch_epoch"' "runner: park detection is bounded by this launch"
_order=$(printf '%s\n' "$_blk" | grep -n -E '_stopped_mode="(forced|question|graceful)"' | sed 's/:.*_stopped_mode="/ /; s/"$//' | awk '{print $2}' | tr '\n' ' ')
_tap_eq "$_order" "forced question graceful " "runner: precedence FORCE > question > STOP"
_tap_contains "$_blk" 'export REPO_OS_SESSION_DEADLINE_EPOCH=$((_session_launch_epoch + _session_max_ttl))' "runner: exports the session TTL deadline to the hook"
_tap_contains "$_blk" 'is not below runner.session_max_ttl_seconds' "runner: warns when question_timeout_seconds >= session_max_ttl_seconds"
_tap_contains "$_blk" '[ "$_RESULT_OUTCOME" != "stopped:question" ]' "runner: no patch snapshot for a parked group brief"
_tap_true "grep -q 'PROMPT=\$(_resume_message \"\$ENTRY_ID\" \"\$ENTRY_STOPPED_MODE\")' '$_RUNNER_SRC'" "runner: the daemon loop builds the resume prompt with _resume_message"
# Breaker: the stopped arm never increments it; a park lands there. The arm is
# the `stopped)` case arm that logs "entry-stopped", up to the next arm at the
# same indent — found by content, not position, and checked whole before the
# negative assertion so a truncated extract cannot pass it vacuously.
_arm=$(awk '
  /^    stopped\)$/ { buf = $0 "\n"; inside = 1; next }
  inside && /^    [a-z|*]+\)$/ { if (buf ~ /entry-stopped/) { printf "%s", buf; exit } inside = 0 }
  inside { buf = buf $0 "\n" }
' "$_RUNNER_SRC")
_tap_contains "$_arm" 'review_log_append "entry-stopped"' "breaker: fixture found the whole stopped arm"
_tap_contains "$_arm" '_CONSECUTIVE_SESSION_COUNT' "breaker: fixture extract runs past the log calls"
_tap_contains "$_arm" 'parked on an unanswered question' "breaker: a park is logged in the stopped arm"
_tap_lacks "$_arm" '_circuit_breaker_increment' "breaker: the stopped arm does not increment the circuit breaker"
# A parked question is closed, so the exit hook neither flags nor re-closes it.
_ENTRY_PAUSED_AT_EXIT=false
_record_question_pause_at_exit entry-b 2>/dev/null
_tap_eq "$_ENTRY_PAUSED_AT_EXIT" "false" "exit: a parked question is not an abandoned wait"
_tap_eq "$(qc_close_reason "$ADIR" q-000001)" "parked" "exit: the park marker is not overwritten with abandoned"

# ---------------------------------------------------------------------------
printf "\n# --- queue-cli: park -> answer -> resume ---\n"
_ensure_queue_dirs
QQ="$ADIR/queue"
_mk_entry() {  # $1 id, $2 status dir, $3 created_at, [$4 session_type, $5 work order, $6 brief path, $7 stopped_mode]
  _load_queue_entry "$SB/.no-such-entry.yaml" 2>/dev/null
  _QE_ID="$1"; _QE_STATUS="$2"; _QE_PRIORITY="0"
  _QE_SESSION_TYPE="${4:-standard}"; _QE_BRANCH="feature/$1"; _QE_BRIEF_PATH="${6:-}"
  _QE_WORK_ORDER_ID="${5:-}"
  _QE_AUTO_MODE="false"; _QE_SOLO_MODE="true"; _QE_PUSH_ON_COMPLETE="false"
  _QE_RETRY_COUNT="0"; _QE_MAX_RETRIES="3"
  _QE_STOPPED_MODE="${7:-}"
  _QE_CREATED_AT="$3"; _QE_UPDATED_AT="$3"
  _write_queue_entry "$QQ/$2/$1.yaml"
}
_reset_questions; _config 0
# Parked "days ago": the record is old and its live deadline long past.
_run_hook pk entry-pk >/dev/null
_old=$(( $(date +%s) - 3 * 86400 ))
sed -i.bak "s/^created_epoch: .*/created_epoch: $_old/; s/^deadline_epoch: .*/deadline_epoch: $_old/" "$QDIR/q-000001.yaml" && rm -f "$QDIR/q-000001.yaml.bak"
_mk_entry entry-pk stopped "2026-11-10T10:00:00Z" standard "" "" question
_cd=$(ensure_control_dir entry-pk)
printf 'claude_session_id: "cc-pk"\nworktree: "%s/.worktrees/pk"\nrepo_os_session_id: "daemon-pk"\nstopped_mode: "question"\nquestion_id: "q-000001"\n' "$SB" > "$_cd/resume.yaml"

OUT="$(bash "$CLI" --json show entry-pk 2>&1)"
_tap_contains "$OUT" '"question":{"id":"q-000001","waiting":"parked","parked":true,"answered":false' "show --json: exposes the parked question"
_tap_contains "$OUT" 'Which store should the cache use?' "show --json: includes the question text"
_tap_contains "$OUT" '"stopped_mode":"question"' "show --json: stopped_mode question"
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$OUT" > "$WORK/show-pk.json"
  _tap_true "jq -e '.question.parked == true' '$WORK/show-pk.json' >/dev/null 2>&1" "show --json: output is valid JSON"
fi

OUT="$(bash "$CLI" resume-entry entry-pk 2>&1)"; _rc=$?
_tap_eq "$_rc" "1" "resume-entry: refuses a parked entry with no answer"
_tap_contains "$OUT" 'queue-cli.sh answer entry-pk --question q-000001' "resume-entry: points to answer"
_tap_true "[ -f '$QQ/stopped/entry-pk.yaml' ]" "resume-entry refusal: entry stays stopped"

OUT="$(bash "$CLI" answer entry-pk --question q-000002 --text x 2>&1)"; _rc=$?
_tap_eq "$_rc" "1" "answer: unknown question refused"
OUT="$(bash "$CLI" answer entry-other --question q-000001 --text x 2>&1)"; _rc=$?
_tap_eq "$_rc" "1" "answer: another entry's question refused"
OUT="$(bash "$CLI" answer entry-pk --question q-000001 --text a --text b 2>&1)"; _rc=$?
_tap_eq "$_rc" "1" "answer: wrong number of --text values refused"
_tap_contains "$OUT" 'one --text per question' "answer: says why"
_tap_true "[ ! -f '$QDIR/q-000001.answer.yaml' ]" "answer refusals write nothing"

OUT="$(bash "$CLI" --json answer entry-pk --question q-000001 --text 'Use Redis' 2>&1)"; _rc=$?
_tap_eq "$_rc" "0" "answer: parked entry answered (parked for days)"
_tap_contains "$OUT" '"action":"answered-resumed"' "answer: reports the resume"
_tap_contains "$OUT" '"claude_session_id":"cc-pk"' "answer: continues the recorded Claude session"
_tap_true "_qc_read_answer_file '$QDIR/q-000001.answer.yaml' q-000001 >/dev/null" "answer: q-000001.answer.yaml is a valid format_version 1 answer"
_tap_true "grep -q '^format_version: 1\$' '$QDIR/q-000001.answer.yaml'" "answer: format_version 1"
_tap_true "[ -f '$QQ/approved/entry-pk.yaml' ] && [ ! -f '$QQ/stopped/entry-pk.yaml' ]" "answer: entry re-queued in approved/"
_load_queue_entry "$QQ/approved/entry-pk.yaml"
_tap_eq "$_QE_RESUME" "true" "answer: resume: true, like resume-entry"
_tap_eq "$_QE_STOPPED_MODE" "question" "answer: stopped_mode kept for the resume message"
MSG="$(_resume_message entry-pk "$_QE_STOPPED_MODE")"
_tap_contains "$MSG" 'OPERATOR ANSWER to q-000001' "resume after days: the runner's first message is the answer"
_tap_contains "$MSG" '"Use Redis"' "resume after days: carrying the operator's text"
OUT="$(bash "$CLI" answer entry-pk --question q-000001 --text again 2>&1)"; _rc=$?
_tap_eq "$_rc" "1" "answer: a second answer is refused"
_tap_contains "$OUT" 'answered_at' "answer refusal: names who the existing answer claims to be from"
# An invalid file at the answer path is reported as such, not as bad input.
_reset_questions; _config 0
_run_hook inv entry-inv >/dev/null
_mk_entry entry-inv stopped "2026-11-10T10:30:00Z" standard "" "" question
printf 'garbage\n' > "$QDIR/q-000001.answer.yaml"
OUT="$(bash "$CLI" answer entry-inv --question q-000001 --text x 2>&1)"; _rc=$?
_tap_eq "$_rc" "1" "answer: an invalid existing answer file blocks a new answer"
_tap_contains "$OUT" 'exists but is not a valid answer' "answer: and says so, instead of blaming the operator's input"

printf "\n# --- queue-cli: answer during the live wait ---\n"
_reset_questions; _config 30
( cd "$SB" && CLAUDE_HEADLESS=1 REPO_OS_SESSION_ID=sess-live REPO_OS_AUTOMATION_ENTRY=entry-live \
    bash "$HOOK" < "$PAYLOAD" > "$WORK/live.out" 2> "$WORK/live.err"; echo $? > "$WORK/live.rc" ) &
_i=0; while [ ! -f "$QDIR/q-000001.yaml" ] && [ "$_i" -lt 100 ]; do sleep 0.1; _i=$((_i+1)); done
_mk_entry entry-live running "2026-11-10T11:00:00Z"
OUT="$(bash "$CLI" --json show entry-live 2>&1)"
_tap_contains "$OUT" '"question":{"id":"q-000001","waiting":"open","parked":false' "show --json: exposes the open question during the live wait"
OUT="$(bash "$CLI" --json answer entry-live --question q-000001 --text 'In-process' 2>&1)"; _rc=$?
_tap_eq "$_rc" "0" "answer: live wait answered"
_tap_contains "$OUT" '"action":"answered"' "answer: live answer does not re-queue"
_i=0; while [ ! -s "$WORK/live.rc" ] && [ "$_i" -lt 150 ]; do sleep 0.1; _i=$((_i+1)); done
_tap_eq "$(cat "$WORK/live.rc" 2>/dev/null)" "2" "live: the waiting hook picked the answer up"
_tap_contains "$(cat "$WORK/live.err")" '"In-process"' "live: the agent received the operator's text"
_tap_true "[ -f '$QQ/running/entry-live.yaml' ]" "live: entry still running"

printf "\n# --- queue-cli: --file and --force ---\n"
_reset_questions; _config 0
_run_hook pf entry-pf >/dev/null
_mk_entry entry-pf stopped "2026-11-10T12:00:00Z" standard "" "" question
printf 'format_version: 1\nquestion_id: "q-000001"\nanswers:\n  - question_index: 0\n    selected:\n      - "Redis"\n    free_text: ""\n' > "$WORK/file-answer.yaml"
OUT="$(bash "$CLI" answer entry-pf --question q-000001 --file "$WORK/file-answer.yaml" 2>&1)"; _rc=$?
_tap_eq "$_rc" "0" "answer --file: accepted"
_tap_true "cmp -s '$WORK/file-answer.yaml' '$QDIR/q-000001.answer.yaml'" "answer --file: published byte for byte"
_run_hook pf2 entry-pf2 >/dev/null
_mk_entry entry-pf2 stopped "2026-11-10T12:30:00Z" standard "" "" question
OUT="$(bash "$CLI" --json resume-entry entry-pf2 --force 2>&1)"; _rc=$?
_tap_eq "$_rc" "0" "resume-entry --force: resumes a parked entry without an answer"
_tap_contains "$(_resume_message entry-pf2 question)" 'without an answer to question q-000002' "resume-entry --force: the agent is told no answer was given"
_tap_contains "$(_resume_message entry-pf2 question)" 'ASSUMPTION' "resume-entry --force: and to state its assumption"

# ---------------------------------------------------------------------------
printf "\n# --- task group: a parked brief holds later briefs ---\n"
# shellcheck disable=SC1091
source "$ADIR/lib/work-order-manager.sh" 2>/dev/null
set +e
mkdir -p "$SB/.claude/.automation/briefs"
# Entries the sections above re-queued would otherwise be dequeued first.
rm -f "$QQ"/approved/*.yaml "$QQ"/running/*.yaml "$QQ"/stopped/*.yaml
for _n in 1 2; do
  printf '# brief %s\n\n### Task Group\n\n**Brief:** %s of 2 — fixture\n\n### Task Contract\n\n```yaml\ngoal: "fixture"\nscope_files:\n  - "lib/g.sh"\n```\n' "$_n" "$_n" > "$SB/.claude/.automation/briefs/grp-brief-${_n}.md"
done
_mk_entry grp-1 stopped  "2026-11-11T10:00:00Z" taskgroup wo-grp ".claude/.automation/briefs/grp-brief-1.md" question
_mk_entry grp-2 approved "2026-11-11T10:05:00Z" taskgroup wo-grp ".claude/.automation/briefs/grp-brief-2.md"
_dq=$(queue_dequeue 2>/dev/null)
_tap_eq "${_dq:-none}" "none" "group: brief 2 does not start while brief 1 is parked"
_load_queue_entry "$QQ/approved/grp-2.yaml"
_tap_eq "${_QE_HELD_BY:-}" "grp-1" "group: brief 2 is held by the parked brief"
# Answered and resumed: brief 1 is back in approved/, so sequencing still holds
# brief 2 until brief 1 finishes.
queue_resume grp-1 >/dev/null 2>&1
queue_release_holds grp-1 >/dev/null 2>&1
_dq=$(queue_dequeue 2>/dev/null)
_tap_eq "$(basename "${_dq:-none}" .yaml)" "grp-1" "group: after the answer the parked brief runs first"
_dq=$(queue_dequeue 2>/dev/null)
_tap_eq "${_dq:-none}" "none" "group: brief 2 still waits while brief 1 is running"

# ---------------------------------------------------------------------------
printf "\n# --- races around the park (critic findings) ---\n"
# An answer published while the entry is between the hook's park and the
# runner's stop is accepted, and the operator is told to resume once stopped.
_reset_questions; _config 0
_run_hook rc1 entry-race >/dev/null
_mk_entry entry-race running "2026-11-12T09:00:00Z"
OUT="$(bash "$CLI" --json answer entry-race --question q-000001 --text 'late' 2>&1)"; _rc=$?
_tap_eq "$_rc" "0" "parking: an answer during the park transition is accepted"
_tap_contains "$OUT" '"action":"answered-parking"' "parking: reported as parking, not as a live delivery"
_tap_true "[ -f '$QQ/running/entry-race.yaml' ]" "parking: nothing is resumed before the runner has stopped the entry"
mv "$QQ/running/entry-race.yaml" "$QQ/stopped/entry-race.yaml"
sed -i.bak 's/^  status: .*/  status: "stopped"/; s/^  stopped_mode: .*/  stopped_mode: "question"/' "$QQ/stopped/entry-race.yaml" && rm -f "$QQ/stopped/entry-race.yaml.bak"
OUT="$(bash "$CLI" resume-entry entry-race 2>&1)"; _rc=$?
_tap_eq "$_rc" "0" "parking: once stopped, resume-entry accepts it (the answer exists)"
# The hook re-reads after closing, so an answer that beat the close is delivered.
_hook_src="$_ADV_REAL_REPO/.claude/hooks/ask-user-deny.sh"
_after_close=$(awk '/qc_close "\$_qc_adir" "\$_qc_id" parked/{f=1} f' "$_hook_src")
_tap_contains "$_after_close" 'qc_read_answer "$_qc_adir" "$_qc_id"' "hook: re-reads the answer after closing as parked"
_tap_contains "$_after_close" '.closed" 2>/dev/null' "hook: an answer found then undoes the park"
# Two concurrent writers: exactly one publishes.
_reset_questions; _config 0
_run_hook cw entry-cw >/dev/null
qc_text_answer q-000001 a 'first' > "$WORK/cw1.yaml"
qc_text_answer q-000001 b 'second' > "$WORK/cw2.yaml"
( qc_write_answer "$ADIR" q-000001 "$WORK/cw1.yaml"; echo $? > "$WORK/cw1.rc" ) &
( qc_write_answer "$ADIR" q-000001 "$WORK/cw2.yaml"; echo $? > "$WORK/cw2.rc" ) &
wait
_tap_eq "$(cat "$WORK/cw1.rc" "$WORK/cw2.rc" | sort | tr '\n' ' ')" "0 3 " "concurrent qc_write_answer: exactly one publishes, the other is told an answer exists"
# A leading-zero deadline is not read as octal (an abort would fail open).
_reset_questions; _config 0
_rc=$(_run_hook oct entry-oct "REPO_OS_SESSION_DEADLINE_EPOCH=0$(( $(date +%s) + 3600 ))")
_tap_eq "$_rc" "0" "hook: a leading-zero session deadline does not abort the hook"
# A stop with no Claude session id drops the stale handle of an earlier stop.
_tap_true "grep -A4 'has no Claude session id — resume will start a fresh session' '$_RUNNER_SRC' | grep -q 'rm -f \"\$_control_dir/resume.yaml\"'" "runner: a stale resume.yaml is removed when this stop has no session id"

# ---------------------------------------------------------------------------
printf "\n# --- FORCE-HALT during the live wait still closes as abandoned ---\n"
_reset_questions; _config 120
( cd "$SB" && CLAUDE_HEADLESS=1 REPO_OS_SESSION_ID=sess-fh REPO_OS_AUTOMATION_ENTRY=entry-fh \
    exec bash -c 'bash "$1" < "$2" > /dev/null 2>&1 & echo $! > "$3"; wait' _ "$HOOK" "$PAYLOAD" "$WORK/fh-hook.pid" ) &
_child=$!
_i=0; while [ ! -f "$QDIR/q-000001.yaml" ] && [ "$_i" -lt 100 ]; do sleep 0.1; _i=$((_i+1)); done
_hookpid=$(cat "$WORK/fh-hook.pid" 2>/dev/null)
kill -TERM "$_child" 2>/dev/null
_i=0; while [ -n "$_hookpid" ] && kill -0 "$_hookpid" 2>/dev/null && [ "$_i" -lt 150 ]; do sleep 0.1; _i=$((_i+1)); done
_tap_true "[ -n '$_hookpid' ] && ! kill -0 $_hookpid 2>/dev/null" "FORCE-HALT: the orphaned hook stopped polling"
_tap_true "[ ! -f '$QDIR/q-000001.closed' ]" "FORCE-HALT: the hook did not park on its way out"
_ENTRY_PAUSED_AT_EXIT=false
_record_question_pause_at_exit entry-fh 2>/dev/null
_tap_eq "$_ENTRY_PAUSED_AT_EXIT" "true" "FORCE-HALT: the runner flags the wait (breaker exempt)"
_tap_eq "$(qc_close_reason "$ADIR" q-000001)" "abandoned" "FORCE-HALT: the question closes as abandoned"
_tap_eq "$(qc_parked_for_entry "$ADIR" entry-fh)" "" "FORCE-HALT: not a park, so the entry is not stopped on a question"

printf "\n1..%d\n" "$_TAP_NUM"
printf "# pass %d fail %d\n" "$_TAP_PASS" "$_TAP_FAIL"
[ "$_TAP_FAIL" -eq 0 ]
