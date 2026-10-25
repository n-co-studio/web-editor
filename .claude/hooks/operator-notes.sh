#!/usr/bin/env bash
# Operator notes — delivers the operator's notes to a running entry's agent.
# Decision t-0055 clause 13 (note delivery).
#
# Registered as a PostToolUse hook with matcher "*", so a note written while a
# session is running reaches the agent at its next tool step. Returns the note
# text as `additionalContext`, which the agent reads as part of the tool result.
#
# NOT YET REGISTERED. `.claude/settings.json` is an immune path
# (_mode-guard-helper.sh is_immune) that no session may edit — the hook chain
# would otherwise be dismantlable from inside a session — and `chmod` is not on
# the headless Bash allowlist, so this file also ships mode 644. Until an
# operator adds the settings.json entry AND marks this file executable, the
# running-session delivery route is inert; the queued-prompt and resume-message
# routes in runner.sh work regardless. Same constraint as operator-control.sh.
#
# Inert unless all of these hold, so the common path costs one env read:
#   1. CLAUDE_HEADLESS=1 — only runner-launched entries have a control directory
#   2. this session's record names an entry_id
#   3. that entry's control directory holds at least one pending note
#
# Always exits 0. A note is context, never an denial: every fallible step fails
# open, because note delivery that cannot read its own state must not disturb a
# session the operator only wanted to talk to.
#
# Delivery is at-most-once and destructive-by-move: a note is moved to
# notes/delivered/ immediately, so a crash between the move and the agent
# reading the result loses that note rather than repeating it forever. The
# directory is the audit trail (t-0055 clause 13: delivered notes are moved,
# not deleted).

set -uo pipefail

# Fast-exit for interactive sessions — operator notes address queue entries.
[ "${CLAUDE_HEADLESS:-0}" = "1" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" || exit 0
# shellcheck source=_analytics-helper.sh
source "$SCRIPT_DIR/_analytics-helper.sh" 2>/dev/null || exit 0
_ON_START_MS="$(now_ms 2>/dev/null)" || _ON_START_MS=""

_on_sid="$(get_session_id "$_REPO_OS_ROOT" 2>/dev/null)" || exit 0
[ -n "$_on_sid" ] || exit 0

# Session record → entry id. An absent record or field is "not controlled",
# not an error (t-0055 clause 2).
_on_entry="$(session_record_get "$_on_sid" entry_id 2>/dev/null)" || exit 0
[ -n "$_on_entry" ] || exit 0

# get_control_dir resolves through get_main_repo_root() so a note written by the
# operator in the main repo is the same file this worktree session reads
# (t-0055 clause 4).
_on_dir="$(get_control_dir "$_on_entry" 2>/dev/null)" || exit 0
[ -n "$_on_dir" ] || exit 0
[ -d "$_on_dir/notes" ] || exit 0

# Pending notes are the *.md files at the top of notes/; delivered ones live in
# notes/delivered/. Filenames are <epoch>-<n>.md, so glob order is send order.
# At most three per call: this hook fires on every tool use, and an unbounded
# additionalContext would bury the tool result the agent actually asked for.
# The rest stay pending and arrive at the following tool steps.
_ON_MAX=3
_on_count=0
_on_body=""
for _on_file in "$_on_dir"/notes/*.md; do
  [ -f "$_on_file" ] || continue
  [ "$_on_count" -lt "$_ON_MAX" ] || break

  _on_text="$(cat "$_on_file" 2>/dev/null)" || continue
  [ -n "$_on_text" ] || continue

  # sent_at comes from the <epoch> filename prefix — the note body is plain
  # text by contract, so it carries no metadata of its own.
  _on_base="${_on_file##*/}"
  _on_epoch="${_on_base%%-*}"
  _on_sent="$(epoch_to_iso "$_on_epoch" 2>/dev/null)" || _on_sent=""
  [ -n "$_on_sent" ] || _on_sent="$_on_base"

  # Move first, emit second. The reverse order can deliver the same note on
  # every tool call if the move fails, which is a far worse failure than
  # losing one note: the agent would never make progress.
  mkdir -p "$_on_dir/notes/delivered" 2>/dev/null || continue
  mv "$_on_file" "$_on_dir/notes/delivered/$_on_base" 2>/dev/null || continue
  _on_now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || _on_now=""
  printf '%s\n' "$_on_now" > "$_on_dir/notes/delivered/$_on_base.at" 2>/dev/null || true

  _on_body="${_on_body}Operator note (${_on_sent}): ${_on_text}
"
  _on_count=$((_on_count + 1))
done

[ "$_on_count" -gt 0 ] || exit 0

_on_context="${_on_body}Treat this as operator direction for the current brief. Follow it within the brief's scope; if it conflicts with the brief or a gate, escalate rather than guess. Governance gates still apply. Record the note and what you did about it in the session log."

# JSON-escape: operator text reaches stdout as a JSON string value, so
# backslash, quote and control characters must be escaped. Newlines are
# preserved as \n rather than flattened — a multi-line note is readable.
_on_context="${_on_context//\\/\\\\}"
_on_context="${_on_context//\"/\\\"}"
_on_context="${_on_context//$'\t'/\\t}"
_on_context="${_on_context//$'\r'/\\r}"
_on_context="${_on_context//$'\n'/\\n}"

# Drain the PostToolUse payload before answering (hook protocol), as
# operator-control.sh does.
cat > /dev/null 2>&1 || true

log_hook_event "operator-notes" "PostToolUse" "" "allow" "$_ON_START_MS" "operator_notes_delivered" "count:$_on_count" "$_on_entry" 2>/dev/null || true
printf '{"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "%s"}}\n' "$_on_context"
exit 0
