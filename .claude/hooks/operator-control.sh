#!/usr/bin/env bash
# Operator control — ends one entry's session when the operator stops it.
# Decision t-0055 clause 6 (graceful stop).
#
# Invoked two ways, and designed to behave identically under both:
#   - delegated from pretooluse-permission.sh (Bash and Agent tool calls), which
#     relays this script's stdout verbatim. This is the path that works today.
#   - registered directly as a PreToolUse hook with matcher "*", which extends
#     coverage to every tool. `.claude/settings.json` is an immune path
#     (_mode-guard-helper.sh is_immune) that no session may edit — the hook chain
#     would otherwise be dismantlable from inside a session — so that
#     registration is an operator action, not something this brief could apply.
#
# Reads the per-entry control directory for THIS session's entry. If the
# operator has set STOP (or FORCE), returns
# {"continue": false, "stopReason": "..."} so the run ends at a tool boundary —
# no partial edit, no half-written file. The session is NOT deleted: it stays
# resumable by its claude_session_id (`queue-cli.sh resume-entry`).
#
# Inert unless all three hold, so the common path costs one env read:
#   1. CLAUDE_HEADLESS=1 — only runner-launched entries have a control directory
#   2. this session's record names an entry_id
#   3. that entry's control directory holds STOP or FORCE
#
# Always exits 0. A stop is not a tool denial (exit 2, which feeds stderr back
# to the agent and lets it continue) — it ends the run. Every fallible step
# fails open: operator control that cannot read its own state must not wedge a
# session that the operator has not asked to stop.

set -uo pipefail

# Fast-exit for interactive sessions — operator control addresses queue entries.
[ "${CLAUDE_HEADLESS:-0}" = "1" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" || exit 0
# shellcheck source=_analytics-helper.sh
source "$SCRIPT_DIR/_analytics-helper.sh" 2>/dev/null || exit 0
_OC_START_MS="$(now_ms 2>/dev/null)" || _OC_START_MS=""

_oc_sid="$(get_session_id "$_REPO_OS_ROOT" 2>/dev/null)" || exit 0
[ -n "$_oc_sid" ] || exit 0

# Session record → entry id. An absent record or field is "not controlled",
# not an error (t-0055 clause 2).
_oc_entry="$(session_record_get "$_oc_sid" entry_id 2>/dev/null)" || exit 0
[ -n "$_oc_entry" ] || exit 0

# get_control_dir resolves through get_main_repo_root() so a flag written by the
# operator in the main repo is the same file this worktree session reads
# (t-0055 clause 4).
_oc_dir="$(get_control_dir "$_oc_entry" 2>/dev/null)" || exit 0
[ -n "$_oc_dir" ] || exit 0

if [ -f "$_oc_dir/FORCE" ]; then
  _oc_flag="FORCE"
elif [ -f "$_oc_dir/STOP" ]; then
  _oc_flag="STOP"
else
  exit 0
fi

# Close-phase guard. The close phase writes the session log, commits and seals
# the branch. Stopping inside it would leave the entry's work uncommitted and
# its branch unsealed — strictly worse than the handful of tool calls close
# costs. Nothing is lost by waiting: the flag stays set and the runner honours
# it once the child exits, so the entry still lands in stopped/ and
# control_state stays `stopping` ("stopping after close") until then.
_oc_phase=""
_oc_state_dir="$(get_session_state_dir 2>/dev/null)" || _oc_state_dir=""
if [ -n "$_oc_state_dir" ] && [ -f "$_oc_state_dir/phase-state" ]; then
  while IFS= read -r _oc_line || [ -n "$_oc_line" ]; do
    case "$_oc_line" in
      "current_phase: "*) _oc_phase="${_oc_line#current_phase: }"; break ;;
    esac
  done < "$_oc_state_dir/phase-state"
fi
if [ "$_oc_phase" = "close" ]; then
  echo "Operator stop pending: $_oc_flag is set for entry $_oc_entry, but this session is in the close phase — finishing close first." >&2
  exit 0
fi

# Flag content is advisory (a reason string); its existence is the signal.
_oc_reason=""
if [ -s "$_oc_dir/$_oc_flag" ]; then
  _oc_reason="$(cat "$_oc_dir/$_oc_flag" 2>/dev/null)" || _oc_reason=""
fi

if [ "$_oc_flag" = "FORCE" ]; then
  _oc_stop_reason="Force-stopped by operator"
else
  _oc_stop_reason="Stopped by operator"
fi
if [ -n "$_oc_reason" ]; then
  _oc_stop_reason="$_oc_stop_reason: $_oc_reason"
fi

# JSON-escape the composed reason: operator text reaches stdout as a JSON
# string value, so backslash, quote and control characters must be escaped.
_oc_stop_reason="${_oc_stop_reason//\\/\\\\}"
_oc_stop_reason="${_oc_stop_reason//\"/\\\"}"
_oc_stop_reason="${_oc_stop_reason//$'\n'/ }"
_oc_stop_reason="${_oc_stop_reason//$'\r'/ }"
_oc_stop_reason="${_oc_stop_reason//$'\t'/ }"

# Drain the PreToolUse payload before answering (hook protocol), as
# ask-user-deny.sh does. The delegated path passes </dev/null, so this is a
# no-op there.
cat > /dev/null 2>&1 || true

log_hook_event "operator-control" "PreToolUse" "" "block" "$_OC_START_MS" "operator_stop_$_oc_flag" "" "$_oc_entry" 2>/dev/null || true
printf '{"continue": false, "stopReason": "%s"}\n' "$_oc_stop_reason"
echo "Operator stop honoured for entry $_oc_entry ($_oc_flag). The entry moves to queue/stopped/; its worktree and Claude session are kept. Resume with: .claude/.automation/queue-cli.sh resume-entry $_oc_entry" >&2
exit 0
