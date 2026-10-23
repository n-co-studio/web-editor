#!/usr/bin/env bash
# Operator notes — Decision t-0055 clause 13
#
# A note is the one control that adds context instead of taking it away, and it
# has three delivery routes that must agree on one history:
#
#   running  → .claude/hooks/operator-notes.sh (PostToolUse additionalContext)
#   queued   → runner.sh _drain_operator_notes, appended to the prompt
#   stopped  → the same function, appended to the resume message
#
# Each route MOVES what it delivered to notes/delivered/ and stamps a .at
# sidecar, so `notes-entry` reports the same thing whichever route ran.
#
# The hook is invoked DIRECTLY here, with a crafted payload, rather than through
# the hook chain: `.claude/settings.json` is an immune path and `chmod` is off
# the headless allowlist, so this brief could neither register the hook nor mark
# it executable. Registration is escalated to the operator. Running the hook
# directly is therefore the only honest way to exercise it — and it is the same
# technique the layer suites use.
#
# Bash 3.2 compatible.

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

printf "# === Operator notes (Decision t-0055 clause 13) ===\n"

# --- Syntax: the two scripts this suite cannot `bash -n` from an agent -------
# queue-cli.sh and runner.sh are too long to review by eye and are not covered
# by any other suite's parse check. Doing it here means a syntax error in either
# fails a test rather than a production daemon tick.
printf "\n# --- syntax ---\n"
_REAL="$(cd "$SCRIPT_DIR/../../.." && pwd)"
for _f in \
  ".claude/.automation/queue-cli.sh" \
  ".claude/.automation/runner.sh" \
  ".claude/hooks/operator-notes.sh" \
  ".claude/hooks/_analytics-helper.sh"
do
  if bash -n "$_REAL/$_f" 2>/dev/null; then
    _tap_pass "bash -n $_f"
  else
    _tap_fail "bash -n $_f" "$(bash -n "$_REAL/$_f" 2>&1 | head -2)"
  fi
done

setup_adversarial_sandbox
trap 'teardown_adversarial_sandbox' EXIT

REPO_ROOT="$ADV_SANDBOX"; export REPO_ROOT
AUTOMATION_DIR="$ADV_SANDBOX/.claude/.automation"; export AUTOMATION_DIR

# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/hooks/_analytics-helper.sh"
# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/.automation/lib/queue-manager.sh"
# queue-manager.sh sets -e; a TAP suite must survive a failing assertion.
set +e

# Pin the main repo root to the sandbox. get_control_dir resolves through
# get_main_repo_root() by design (t-0055 clause 4), which inside a git worktree
# — exactly how a task group brief runs — would otherwise resolve to the REAL
# repository and write notes into it. cd AND prime the cache, so the pin holds
# whichever path the function takes.
cd "$ADV_SANDBOX" || exit 1
_CACHED_MAIN_REPO_ROOT="$ADV_SANDBOX"
_CACHED_SESSION_STATE_DIR=""
_tap_eq "$(get_main_repo_root)" "$ADV_SANDBOX" "fixture: main repo root is pinned to the sandbox"

CLI="$ADV_SANDBOX/.claude/.automation/queue-cli.sh"
cp "$_ADV_REAL_REPO/.claude/.automation/queue-cli.sh" "$CLI"
Q="$ADV_SANDBOX/.claude/.automation/queue"
mkdir -p "$Q/stopped"

# --- Fixtures ----------------------------------------------------------------
# $1 id · $2 status (also the directory)
_mk_entry() {
  _load_queue_entry "$ADV_SANDBOX/.no-such-entry.yaml" 2>/dev/null
  _QE_ID="$1"; _QE_STATUS="$2"; _QE_PRIORITY="0"
  _QE_SESSION_TYPE="taskgroup"; _QE_BRANCH="feature/notes-$1"
  _QE_BRIEF_PATH=".claude/.automation/briefs/$1.md"
  _QE_AUTO_MODE="true"; _QE_SOLO_MODE="false"; _QE_PUSH_ON_COMPLETE="false"
  _QE_RETRY_COUNT="0"; _QE_MAX_RETRIES="3"
  _QE_CREATED_AT="2026-10-22T10:00:00Z"; _QE_UPDATED_AT="2026-10-22T10:00:00Z"
  mkdir -p "$Q/$2"
  _write_queue_entry "$Q/$2/$1.yaml"
}

_mk_entry note-run   running
_mk_entry note-queue approved
_mk_entry note-stop  stopped
_mk_entry note-done  completed

ENTRY_ID="note-run"
export REPO_OS_SESSION_ID="daemon-notes-test"
export CLAUDE_HEADLESS=1
CONTROL_DIR="$(ensure_control_dir "$ENTRY_ID")"
session_record_set "$REPO_OS_SESSION_ID" "entry_id=$ENTRY_ID" 2>/dev/null || true
_tap_eq "$(session_record_get "$REPO_OS_SESSION_ID" entry_id 2>/dev/null)" "$ENTRY_ID" \
  "fixture: session record names the noted entry"

_run_hook() {
  bash "$ADV_SANDBOX/.claude/hooks/operator-notes.sh" < /dev/null 2>&1
}
_pending_count() {
  ls "$(get_control_dir "$1")/notes"/*.md 2>/dev/null | wc -l | tr -d ' '
}
_delivered_count() {
  ls "$(get_control_dir "$1")/notes/delivered"/*.md 2>/dev/null | wc -l | tr -d ' '
}

# --- Inert when the operator has said nothing --------------------------------
printf "\n# --- inert unless there is a note ---\n"
OUT="$(_run_hook)"
_tap_eq "$OUT" "" "no notes: hook is silent"
bash "$ADV_SANDBOX/.claude/hooks/operator-notes.sh" < /dev/null > /dev/null 2>&1
_tap_eq "$?" "0" "no notes: hook exits 0"

OUT="$(CLAUDE_HEADLESS=0 bash "$ADV_SANDBOX/.claude/hooks/operator-notes.sh" < /dev/null 2>&1)"
_tap_eq "$OUT" "" "interactive sessions pay nothing"

# --- note-entry writes a pending note ----------------------------------------
printf "\n# --- note-entry ---\n"
OUT="$(bash "$CLI" note-entry note-run --text "prefer the existing helper" 2>&1)"
_tap_contains "$OUT" "Note queued for note-run" "note-entry reports the queued note"
_tap_contains "$OUT" "next tool step" "note-entry names the delivery route for a running entry"
_tap_eq "$(_pending_count note-run)" "1" "note-entry wrote exactly one pending note"

OUT="$(bash "$CLI" --json notes-entry note-run 2>&1)"
_tap_contains "$OUT" '"pending":1' "notes-entry --json counts the pending note"
_tap_contains "$OUT" '"delivered":0' "notes-entry --json reports nothing delivered yet"
_tap_contains "$OUT" '"state":"pending"' "notes-entry --json states the note is pending"
_tap_contains "$OUT" '"sent_at":"20' "notes-entry --json carries an ISO sent_at"
_tap_contains "$OUT" '"delivered_at":""' "notes-entry --json leaves delivered_at empty while pending"

# The short alias the UI map uses must reach the same subcommand.
OUT="$(bash "$CLI" --json notes note-run 2>&1)"
_tap_contains "$OUT" '"pending":1' "the 'notes' alias reaches notes-entry"

# --- Route 1: a running session gets it at its next tool step ----------------
printf "\n# --- route 1: running session (the hook) ---\n"
OUT="$(_run_hook)"
_tap_contains "$OUT" '"hookEventName": "PostToolUse"' "hook answers on the PostToolUse contract"
_tap_contains "$OUT" 'additionalContext' "hook returns the note as additionalContext"
_tap_contains "$OUT" 'Operator note (' "the note is labelled as an operator note"
_tap_contains "$OUT" 'prefer the existing helper' "the operator's text reaches the agent"
_tap_contains "$OUT" 'Governance gates still apply' "the note cannot be read as a gate waiver"
_tap_contains "$OUT" 'escalate rather than guess' "a conflicting note is told to escalate"

_tap_eq "$(_pending_count note-run)" "0" "the delivered note is no longer pending"
_tap_eq "$(_delivered_count note-run)" "1" "the delivered note was MOVED to notes/delivered/, not deleted"

OUT="$(bash "$CLI" --json notes-entry note-run 2>&1)"
_tap_contains "$OUT" '"state":"delivered"' "notes-entry --json flips the note to delivered"
_tap_contains "$OUT" '"delivered":1' "notes-entry --json counts the delivered note"
_tap_lacks "$OUT" '"delivered_at":""' "notes-entry --json stamps delivered_at from the .at sidecar"

# Delivery is at-most-once: a second tool call must not re-read the same note.
OUT="$(_run_hook)"
_tap_eq "$OUT" "" "a delivered note is not delivered twice"

# --- The per-call cap --------------------------------------------------------
# This hook fires on EVERY tool use. Without a cap an operator who queued ten
# notes would bury every tool result the agent asked for.
printf "\n# --- at most three notes per tool call ---\n"
_i=1
while [ "$_i" -le 5 ]; do
  bash "$CLI" note-entry note-run --text "burst note $_i" > /dev/null 2>&1
  _i=$((_i + 1))
done
_tap_eq "$(_pending_count note-run)" "5" "fixture: five notes are pending"
OUT="$(_run_hook)"
_tap_eq "$(_pending_count note-run)" "2" "one tool call delivers three and leaves the rest pending"
_tap_contains "$OUT" "burst note 1" "the oldest note goes first"
_tap_lacks "$OUT" "burst note 4" "the fourth waits for the next tool call"
OUT="$(_run_hook)"
_tap_contains "$OUT" "burst note 4" "the next tool call picks up where the last stopped"
_tap_eq "$(_pending_count note-run)" "0" "the backlog drains"

# --- JSON safety -------------------------------------------------------------
# Operator text reaches stdout as a JSON string value. A raw quote would break
# the object and the hook's output would be discarded — silently losing notes.
printf "\n# --- operator text is JSON-escaped ---\n"
bash "$CLI" note-entry note-run --text 'he said "ship it" \ today' > /dev/null 2>&1
OUT="$(_run_hook)"
_tap_contains "$OUT" '\"ship it\"' "quotes in the note are escaped"
# One literal backslash in the note becomes two on the wire.
_tap_contains "$OUT" '\\ today' "a backslash in the note is escaped"
if printf '%s' "$OUT" | head -1 | jq . > /dev/null 2>&1; then
  _tap_pass "emitted line is valid JSON"
elif command -v jq > /dev/null 2>&1; then
  _tap_fail "emitted line is valid JSON" "jq rejected: $(printf '%s' "$OUT" | head -1 | cut -c1-120)"
else
  _tap_pass "emitted line is valid JSON (jq unavailable — skipped)"
fi

# A multi-line note must survive as one JSON string.
printf 'line one\nline two\n' > "$ADV_SANDBOX/note.txt"
bash "$CLI" note-entry note-run --file "$ADV_SANDBOX/note.txt" > /dev/null 2>&1
OUT="$(_run_hook)"
_tap_contains "$OUT" 'line one\nline two' "--file: a multi-line note is escaped, not flattened"
# $(...) already ate the trailing newline, so put exactly one back: a correctly
# escaped two-line note is then one line, and a flattened one would be two.
_tap_eq "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "1" "--file: the hook still emits a single line"

# A CRLF file — an operator pasting from a Windows editor — must escape the CR
# rather than drop it, matching _json_escape() in lib/review-log.sh.
printf 'crlf one\r\ncrlf two\r\n' > "$ADV_SANDBOX/crlf.txt"
bash "$CLI" note-entry note-run --file "$ADV_SANDBOX/crlf.txt" > /dev/null 2>&1
OUT="$(_run_hook)"
_tap_contains "$OUT" 'crlf one\r\ncrlf two' "--file: a CR is escaped, not silently dropped"

# --- Rejections --------------------------------------------------------------
printf "\n# --- what note-entry refuses ---\n"
OUT="$(bash "$CLI" note-entry note-done --text "too late" 2>&1)"
_RC=$?
_tap_eq "$_RC" "1" "a completed entry is refused"
_tap_contains "$OUT" "it is closed" "the refusal says why"
_tap_eq "$(_pending_count note-done)" "0" "the refused note was not written"

_BIG="$(printf 'x%.0s' $(seq 1 2001))"
OUT="$(bash "$CLI" note-entry note-queue --text "$_BIG" 2>&1)"
_RC=$?
_tap_eq "$_RC" "1" "a note over 2000 characters is refused"
_tap_contains "$OUT" "the limit is 2000" "the length refusal names the limit"
_tap_eq "$(_pending_count note-queue)" "0" "the oversized note was not written"

OUT="$(bash "$CLI" note-entry note-queue --text "" 2>&1)"
_tap_eq "$?" "1" "an empty note is refused"
OUT="$(bash "$CLI" note-entry note-queue 2>&1)"
_tap_eq "$?" "1" "note-entry with neither --text nor --file is refused"
_tap_contains "$OUT" "--text" "the usage error names the flags"
OUT="$(bash "$CLI" note-entry note-queue --file "$ADV_SANDBOX/no-such-file.txt" 2>&1)"
_tap_eq "$?" "1" "--file with a missing path is refused"
OUT="$(bash "$CLI" note-entry no-such-entry --text "hello" 2>&1)"
_tap_eq "$?" "1" "an unknown id is refused"

# Exactly 2000 characters is allowed — the boundary must not be off by one.
_EDGE="$(printf 'y%.0s' $(seq 1 2000))"
bash "$CLI" note-entry note-queue --text "$_EDGE" > /dev/null 2>&1
_tap_eq "$(_pending_count note-queue)" "1" "exactly 2000 characters is accepted"

# --- Routes 2 and 3: the runner-side drain -----------------------------------
# runner.sh cannot be sourced (it parses argv and runs a daemon loop at load),
# so extract the function under test — the same technique
# test-operator-control.sh uses. It keeps the test honest: it runs the real
# code rather than a restatement of it.
printf "\n# --- routes 2 and 3: the runner drain ---\n"
_RUNNER_SRC="$_ADV_REAL_REPO/.claude/.automation/runner.sh"
_RUNNER_FNS="$ADV_SANDBOX/runner-fns-notes.sh"
awk '
  $0 ~ "^_drain_operator_notes\\(\\) \\{" { inside=1 }
  inside { print }
  inside && /^}$/ { exit }
' "$_RUNNER_SRC" > "$_RUNNER_FNS"
# shellcheck disable=SC1090
source "$_RUNNER_FNS"
if type _drain_operator_notes > /dev/null 2>&1; then
  _tap_pass "extracted _drain_operator_notes from runner.sh"
else
  _tap_fail "extracted _drain_operator_notes from runner.sh" "function not found — did runner.sh change shape?"
fi

# Route 2: a queued entry. The note was already written above (the 2000-char
# edge case), so this also proves the edge-case note was really stored.
OUT="$(_drain_operator_notes note-queue)"
_tap_contains "$OUT" "## Operator notes" "queued entry: the prompt gains an Operator notes section"
_tap_contains "$OUT" "yyyy" "queued entry: the note text is in the section"
_tap_contains "$OUT" "Governance gates still apply" "queued entry: the section cannot be read as a gate waiver"
_tap_eq "$(_pending_count note-queue)" "0" "queued entry: the note is no longer pending"
_tap_eq "$(_delivered_count note-queue)" "1" "queued entry: the note was moved to notes/delivered/"
OUT="$(bash "$CLI" --json notes-entry note-queue 2>&1)"
_tap_contains "$OUT" '"state":"delivered"' "queued entry: notes-entry sees the same history as the hook route"
_tap_lacks "$OUT" '"delivered_at":""' "queued entry: delivered_at is stamped by the runner route too"

# Route 3: a stopped entry. Same function, same guarantees — what differs is
# only where the caller appends the section.
bash "$CLI" note-entry note-stop --text "rebase before you resume" > /dev/null 2>&1
_tap_contains "$(bash "$CLI" note-entry note-stop --text "and re-run the suite" 2>&1)" \
  "resume message" "stopped entry: note-entry names the resume route"
# Five, not two: the hook's cap is three, so a two-note backlog would drain
# identically whether this route were capped or not and would prove nothing.
_i=3
while [ "$_i" -le 5 ]; do
  bash "$CLI" note-entry note-stop --text "backlog note $_i" > /dev/null 2>&1
  _i=$((_i + 1))
done
_tap_eq "$(_pending_count note-stop)" "5" "fixture: five notes wait on the stopped entry"
OUT="$(_drain_operator_notes note-stop)"
_tap_contains "$OUT" "rebase before you resume" "stopped entry: the resume message carries the note"
_tap_contains "$OUT" "and re-run the suite" "stopped entry: every pending note rides along"
_tap_contains "$OUT" "backlog note 5" "stopped entry: the drain is uncapped past the hook's three"
_tap_eq "$(_pending_count note-stop)" "0" "stopped entry: the notes are marked delivered"

# Nothing pending must produce nothing, so the caller can append unconditionally.
_tap_eq "$(_drain_operator_notes note-stop)" "" "no pending notes: the drain prints nothing"
_tap_eq "$(_drain_operator_notes entry-that-never-existed)" "" "no control directory: the drain is silent"

# --- The wiring, not just the function ---------------------------------------
# The function is useless if the main loop never calls it, and the main loop
# cannot be run here. Assert the call site exists and sits AFTER the
# resume/assemble branch, so it covers both routes rather than only one.
printf "\n# --- the call site ---\n"
_WIRE="$(awk '/^  if \[ "\$ENTRY_RESUME" = true \]; then$/,/_drain_operator_notes/' "$_RUNNER_SRC")"
_tap_contains "$_WIRE" 'PROMPT=$(assemble_prompt' "wiring: the drain follows the queued-prompt branch"
_tap_contains "$_WIRE" 'Resumed by operator.' "wiring: the drain follows the resume-message branch"
_tap_contains "$_WIRE" '_drain_operator_notes "$ENTRY_ID"' "wiring: the main loop drains the entry's notes"

# --- A work order id stands in for 'the next brief' --------------------------
# With no brief of a group running, the operator should not have to look up an
# id for work the group has not reached yet.
printf "\n# --- a work order resolves to its next brief ---\n"
_mk_entry wo-brief-1 completed
_mk_entry wo-brief-2 approved
mkdir -p "$Q/work-orders"
# Byte-for-byte what _save_work_order writes: unquoted scalars, and entry_ids as
# a two-space "  - id" list. _load_work_order matches those prefixes literally
# and strips no quotes, so a prettier fixture would silently parse to nothing.
{
  printf 'work_order:\n'
  printf '  id: wo-notes\n'
  printf '  type: task-group\n'
  printf '  label: notes fixture\n'
  printf '  entry_ids:\n'
  printf '  - wo-brief-1\n'
  printf '  - wo-brief-2\n'
  printf '  status: open\n'
  printf '  created_at: 2026-10-22T10:00:00Z\n'
  printf '  updated_at: 2026-10-22T10:00:00Z\n'
} > "$Q/work-orders/wo-notes.yaml"

OUT="$(bash "$CLI" note-entry wo-notes --text "applies to whatever runs next" 2>&1)"
_tap_contains "$OUT" "wo-notes → next entry wo-brief-2" "a work order id resolves past the finished brief"
_tap_eq "$(_pending_count wo-brief-2)" "1" "the note lands on the next brief"
_tap_eq "$(_pending_count wo-brief-1)" "0" "the completed brief gets nothing"

# --- Summary ---
printf "\n1..%d\n" "$_TAP_NUM"
printf "# Tests: %d  Pass: %d  Fail: %d\n" "$_TAP_NUM" "$_TAP_PASS" "$_TAP_FAIL"
if [ "$_TAP_FAIL" -gt 0 ]; then
  printf "\n# Failures:\n%b" "$_TAP_FAILURES"
  exit 1
fi
exit 0
