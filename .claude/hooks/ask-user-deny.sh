#!/usr/bin/env bash
# Ask-user question channel — AskUserQuestion in headless automation mode.
# Wired to PreToolUse on AskUserQuestion via .claude/settings.json.
# Decision t-0064 (supersedes the discard-and-deny behaviour of Decision 0017),
# amended by Decision t-0068: an unanswered question no longer expires.
#
# Interactive (CLAUDE_HEADLESS unset or not 1): exit 0 before reading anything.
# Headless: record the question under .claude/.automation/questions/, wait for
# an answer file, and deny with exit 2 so the answer reaches the agent through
# stderr in the SAME session and worktree. When the live wait ends unanswered,
# runner.question_on_timeout decides:
#   pause (default)  close the question as `parked` and end the run like an
#                    operator graceful stop ({"continue": false}, exit 0). The
#                    runner moves the entry to stopped/ (stopped_mode question),
#                    and `queue-cli.sh answer` resumes the same Claude session
#                    with the answer as its first message. No escalation.
#   agent-decides    close it as `agent-decided`, write an ADVISORY escalation
#                    and tell the agent to choose, state its assumption and
#                    continue (exit 2). The operator opted into this.
# The hook never tells the agent to guess under pause (only the operator can:
# agent-decides, or resume-entry --force).
#
# The live wait is bounded here: a waiting task-group brief holds the group
# worktree (Decision t-0054). It stays 30s under the hook timeout in
# settings.json, because a timed-out PreToolUse hook fails OPEN unless
# onFailure blocks (t-0064 § 2), and 60s under the session TTL deadline the
# runner exports, so the wait parks before the TTL watchdog kills the session
# (t-0068 § 5).

set -euo pipefail

# Fast-exit for interactive sessions (no headless env var)
if [ "${CLAUDE_HEADLESS:-0}" != "1" ]; then
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
_QC_POLL_SECONDS=5

# Drain stdin (hook protocol) into a private file — it is the question.
_qc_payload=$(mktemp "${TMPDIR:-/tmp}/ask-user-payload.XXXXXX" 2>/dev/null) || _qc_payload=""
if [ -n "$_qc_payload" ]; then
  cat > "$_qc_payload" 2>/dev/null || true
else
  cat > /dev/null 2>&1 || true
fi
trap '[ -n "$_qc_payload" ] && rm -f "$_qc_payload" 2>/dev/null || true' EXIT

# shellcheck source=_analytics-helper.sh
source "$SCRIPT_DIR/_analytics-helper.sh" 2>/dev/null || true

_qc_main_root=""
if command -v get_main_repo_root >/dev/null 2>&1; then
  _qc_main_root="$(get_main_repo_root 2>/dev/null)" || _qc_main_root=""
fi
[ -n "$_qc_main_root" ] || _qc_main_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
_qc_adir="$_qc_main_root/.claude/.automation"
_qc_entry="${REPO_OS_AUTOMATION_ENTRY:-}"
_qc_sid="${REPO_OS_SESSION_ID:-}"
_qc_id=""

# --- Escalation ---
# blocking: the question could not be recorded at all (the session stops).
# advisory: agent-decides answered for the operator (the session continues).
# Arguments: $1 message (no double quotes), $2 severity (default blocking)
_qc_escalate() {
  local msg="$1" dir ts f
  dir=""
  if command -v get_escalations_dir >/dev/null 2>&1; then
    dir="$(get_escalations_dir 2>/dev/null)" || dir=""
  fi
  [ -n "$dir" ] || dir="$_qc_adir/escalations"
  mkdir -p "$dir" 2>/dev/null || return 0
  local severity="${2:-blocking}"
  ts="$(date -u +%Y%m%d-%H%M%S)"
  f="$dir/esc-question-${_qc_id:-unrecorded}-${ts}.yaml"
  {
    printf 'escalation:\n'
    printf '  id: "esc-question-%s-%s"\n' "${_qc_id:-unrecorded}" "$ts"
    printf '  queue_entry_id: "%s"\n' "$_qc_entry"
    printf '  type: "ambiguity"\n'
    printf '  severity: "%s"\n' "$severity"
    printf '  phase_at_exit: ""\n'
    printf '  tag_at_exit: ""\n'
    printf '  message: "%s"\n' "$msg"
    printf '  context: "question_id: %s, session_id: %s, questions_dir: %s"\n' "${_qc_id:-none}" "$_qc_sid" "$(qc_dir "$_qc_adir" 2>/dev/null || true)"
    printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  resolved: false\n'
    printf '  resolution: ""\n'
  } > "$f" 2>/dev/null || true
  return 0
}

# --- Stop: deny, and tell the agent not to continue ---
# Only for a question that could not be recorded: there is nothing to park on
# and nothing an answer could later be written to.
_qc_stop() {
  local why="$1"
  _qc_escalate "$why" || true
  printf '{"decision": "deny", "reason": "AskUserQuestion: no operator answer (headless) — stop"}\n'
  echo "STOPPED: ${why} An escalation has been written for the operator. Do not guess an answer and do not continue the task. Write a short summary of where the work stands and what decision is needed, then end the session." >&2
  exit 2
}

# shellcheck source=../.automation/lib/question-channel.sh
if ! source "$SCRIPT_DIR/../.automation/lib/question-channel.sh" 2>/dev/null; then
  _qc_stop "The question channel library is missing, so the question could not be recorded."
fi
[ -n "$_qc_payload" ] || _qc_stop "The question payload could not be captured."

_qc_phase=""
if command -v get_session_state_dir >/dev/null 2>&1; then
  _qc_sdir="$(get_session_state_dir 2>/dev/null)" || _qc_sdir=""
  if [ -n "$_qc_sdir" ] && [ -f "$_qc_sdir/phase-state" ]; then
    _qc_phase="$(sed -n 's/^current_phase: *//p' "$_qc_sdir/phase-state" 2>/dev/null | head -1)" || _qc_phase=""
  fi
fi

_qc_wait="$(qc_effective_timeout "$_qc_adir")"
_qc_mode="$(qc_on_timeout "$_qc_adir")"
_qc_start="$(date +%s)"
_qc_deadline=$((_qc_start + _qc_wait))
# Session TTL (t-0068 § 5): end the live wait 60s before the runner's TTL
# watchdog would kill the session, so the question parks instead of being
# abandoned. Unset or non-numeric (TTL disabled, or not runner-launched): no clamp.
case "${REPO_OS_SESSION_DEADLINE_EPOCH:-}" in
  ''|*[!0-9]*) ;;
  *)
    # 10#: a leading zero must not be read as octal (an abort here fails open).
    _qc_ttl_end=$((10#$REPO_OS_SESSION_DEADLINE_EPOCH - 60))
    [ "$_qc_ttl_end" -lt "$_qc_start" ] && _qc_ttl_end=$_qc_start
    if [ "$_qc_ttl_end" -lt "$_qc_deadline" ]; then
      _qc_deadline=$_qc_ttl_end
      _qc_wait=$((_qc_deadline - _qc_start))
    fi
    ;;
esac

_qc_id="$(qc_next_id "$_qc_adir")" || _qc_id=""
[ -n "$_qc_id" ] || _qc_stop "A question id could not be allocated."
if ! qc_write_question "$_qc_adir" "$_qc_id" "$_qc_payload" "$_qc_sid" "$_qc_entry" "$_qc_phase" "$_qc_deadline"; then
  _qc_stop "The question record could not be written."
fi

echo "Question ${_qc_id} recorded for the operator in $(qc_dir "$_qc_adir"); waiting up to ${_qc_wait}s for ${_qc_id}.answer.yaml." >&2

# The parent is the claude process. If it is killed (FORCE-HALT, TTL) this hook
# is reparented; stop polling then, leaving the record for the runner to close.
_qc_parent="$(ps -o ppid= -p $$ 2>/dev/null | tr -d '[:space:]')" || _qc_parent=""

while :; do
  if _qc_answer="$(qc_read_answer "$_qc_adir" "$_qc_id" 2>/dev/null)"; then
    printf '{"decision": "deny", "reason": "AskUserQuestion answered by the operator via the question channel"}\n'
    qc_answer_message "$_qc_id" "$_qc_answer" >&2
    exit 2
  fi
  _qc_now="$(date +%s)"
  [ "$_qc_now" -ge "$_qc_deadline" ] && break
  if [ -n "$_qc_parent" ]; then
    _qc_cur="$(ps -o ppid= -p $$ 2>/dev/null | tr -d '[:space:]')" || _qc_cur=""
    [ "$_qc_cur" = "$_qc_parent" ] || exit 0
  fi
  _qc_left=$((_qc_deadline - _qc_now))
  [ "$_qc_left" -gt "$_QC_POLL_SECONDS" ] && _qc_left=$_QC_POLL_SECONDS
  sleep "$_qc_left"
done

if [ "$_qc_mode" = "agent-decides" ]; then
  # The hook cannot record the assumption itself — the agent forms it after
  # this returns — so the escalation records the question and says where the
  # assumption is written down (Decision t-0068 § 4).
  qc_close "$_qc_adir" "$_qc_id" agent-decided || true
  _qc_escalate "No operator answer to question ${_qc_id} within ${_qc_wait}s; question_on_timeout is agent-decides, so the agent was told to choose and continue. Question: $(qc_question_summary "$_qc_adir" "$_qc_id" 2>/dev/null | tr '"' "'"). The agent states its choice and the assumption behind it in its next reply and in its session log." advisory || true
  printf '{"decision": "deny", "reason": "AskUserQuestion: no operator answer (headless) — agent decides"}\n'
  printf 'NO OPERATOR ANSWER to %s within %ss. The operator has configured headless sessions to continue without one (question_on_timeout: agent-decides). Choose the option that fits the brief and the work so far, state your choice and the reason for it as an explicit ASSUMPTION in your next reply and in your session log (and commit message if you commit), then continue the task. An advisory escalation records the question for the operator.\n' "$_qc_id" "$_qc_wait" >&2
  exit 2
fi

# pause: park. The question stays answerable — an answer written now is
# delivered by `queue-cli.sh answer` when it resumes this Claude session.
qc_close "$_qc_adir" "$_qc_id" parked || _qc_stop "Question ${_qc_id} could not be parked."
# An answer published between the last poll and the close would otherwise be
# stranded on a parked entry. Read once more AFTER closing: `queue-cli.sh
# answer` sees the close marker and treats anything later as a park, so only
# this window is left, and here the answer is delivered and the park undone.
if _qc_answer="$(qc_read_answer "$_qc_adir" "$_qc_id" 2>/dev/null)"; then
  rm -f "$(qc_dir "$_qc_adir")/${_qc_id}.closed" 2>/dev/null || true
  printf '{"decision": "deny", "reason": "AskUserQuestion answered by the operator via the question channel"}\n'
  qc_answer_message "$_qc_id" "$_qc_answer" >&2
  exit 2
fi
_qc_reason="Parked on question ${_qc_id}: no operator answer within ${_qc_wait}s. The entry is stopped and resumes in this session when the operator answers (operator: queue-cli.sh answer ${_qc_entry:-<entry>} --question ${_qc_id} --text TEXT)."
# What the agent sees if the run were not ended: stop, do not decide.
_qc_deny="${_qc_reason} Do not continue and do not guess an answer: end the session now. The answer arrives as your next message when the operator gives it."
# Plain %s interpolation is safe: the ids are runner-generated (q-NNNNNN and the
# queue-id charset) and the wait is an integer, so no quote or backslash.
printf '{"continue": false, "stopReason": "%s", "hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "%s"}}\n' "$_qc_reason" "$_qc_deny"
echo "$_qc_reason" >&2
exit 0
