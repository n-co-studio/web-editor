#!/usr/bin/env bash
# Draft-first queue intake for Prompt T — Decision t-0067
#
# A Prompt T Brief session (taskdef-brief) can queue its brief as a
# pending-review draft right after synthesis, revise it in place, and be
# released by an approval made OUTSIDE the session (queue-cli.sh approve /
# approve-wo, mode from the approver) or ended by removal (discard_draft).
# One section per acceptance criterion, plus the guards that keep the agent
# from approving its own draft and keep briefs/ writes to their phases.
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

printf "# === Draft-first queue intake for Prompt T (Decision t-0067) ===\n"

setup_adversarial_sandbox
trap 'teardown_adversarial_sandbox' EXIT

REPO_ROOT="$ADV_SANDBOX"; export REPO_ROOT
AUTOMATION_DIR="$ADV_SANDBOX/.claude/.automation"; export AUTOMATION_DIR
CONFIG_FILE="$AUTOMATION_DIR/config.yaml"; export CONFIG_FILE
cd "$ADV_SANDBOX" || exit 1

cp "$_ADV_REAL_REPO/.claude/.automation/queue-cli.sh" "$AUTOMATION_DIR/queue-cli.sh"
CLI="$AUTOMATION_DIR/queue-cli.sh"
Q="$AUTOMATION_DIR/queue"
BRIEFS="$AUTOMATION_DIR/briefs"
SID="$(cat "$ADV_SANDBOX/.claude/.session-id")"

# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/hooks/_analytics-helper.sh"
# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/hooks/_phase-helper.sh"
# shellcheck disable=SC1091
source "$AUTOMATION_DIR/lib/file-lock.sh"
# shellcheck disable=SC1091
source "$AUTOMATION_DIR/lib/queue-manager.sh"
# The queue libraries set -e; a suite that asserts on failures must not exit on them.
set +e
_CACHED_MAIN_REPO_ROOT="$ADV_SANDBOX"
_CACHED_SESSION_STATE_DIR=""

# A brief with its sidecar contract and bundle, as Prompt T writes them.
_mk_draft() { # stem -> prints the repo-relative brief path
  local stem="$1"
  printf '## Task Brief: %s\n\n### Goal\nDraft %s.\n' "$stem" "$stem" > "$BRIEFS/$stem.md"
  printf 'task: "%s"\n' "$stem" > "$BRIEFS/$stem.contract.yaml"
  printf 'brief_id: "%s"\nmode: "review"\n' "$stem" > "$BRIEFS/$stem.bundle.yaml"
  printf '.claude/.automation/briefs/%s.md' "$stem"
}
_entry_id() { printf '%s\n' "$1" | sed -n 's/^entry_id: //p'; }
_field() { # file field
  sed -n "s/^  $2: *\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$1" | head -1
}
_new_session() { # a fresh taskdef-brief session, phase synthesize
  REPO_OS_ALLOW_REINIT=1 init_phase taskdef-brief > /dev/null 2>&1
  advance_phase dispatch > /dev/null 2>&1
  advance_phase synthesize > /dev/null 2>&1
  # Step 2 dispatches the Pragmatist; its verdict gates the approval phase on
  # every path, in-session or draft.
  printf 'GATE_RESULT: APPROVED\nsession_id: %s\n' "$SID" > "$(get_session_state_dir)/pragmatist-signed"
}
_PA() { printf '%s/plan-approved' "$(get_session_state_dir)"; }
_hook() { # hook-name tool-json -> exit code; stderr kept in _HOOK_ERR
  local _out
  _out=$(printf '%s' "$2" | bash "$ADV_SANDBOX/.claude/hooks/$1" 2>&1 >/dev/null)
  local rc=$?
  _HOOK_ERR="$_out"
  return $rc
}
_bash_json() { printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"%s"}}' "$SID" "$1"; }
_edit_json() { printf '{"tool_name":"Edit","session_id":"%s","tool_input":{"file_path":"%s","old_string":"a","new_string":"b"}}' "$SID" "$1"; }

# ----------------------------------------------------------------------------
printf "\n# --- 1. Draft add: pending-review, no daemon ---\n"
_new_session
B1=$(_mk_draft 20261112-120000-draft-one)
OUT="$(bash "$CLI" add --brief "$B1" 2>&1)"
ID1="$(_entry_id "$OUT")"
_tap_contains "$OUT" "status: pending-review" "add without --auto-approve reports pending-review"
if [ -n "$ID1" ] && [ -f "$Q/pending-review/$ID1.yaml" ]; then
  _tap_pass "the draft entry is in pending-review/"
else
  _tap_fail "the draft entry is in pending-review/" "no entry file for '$ID1'"
fi
_tap_eq "$(_field "$Q/pending-review/$ID1.yaml" auto_mode)" "false" "a draft starts in review mode"
if [ ! -f "$AUTOMATION_DIR/runner.pid" ] && ! grep -q 'enabled: true' "$AUTOMATION_DIR/config.local.yaml" 2>/dev/null; then
  _tap_pass "adding a draft starts no daemon and enables no runner"
else
  _tap_fail "adding a draft starts no daemon and enables no runner"
fi

OUT="$(bash "$CLI" draft-status "$ID1" 2>&1)"
_tap_eq "$OUT" "$ID1 pending-review review" "draft-status reports the entry, its status and mode"

# ----------------------------------------------------------------------------
printf "\n# --- 2. Revise in place: same file, same entry ---\n"
printf '\n### Approach\nRevised.\n' >> "$BRIEFS/20261112-120000-draft-one.md"
OUT="$(bash "$CLI" add --brief "$B1" 2>/dev/null)"
_tap_eq "$(_entry_id "$OUT")" "$ID1" "re-adding the revised brief keeps the same entry id"
_tap_eq "$(ls "$Q/pending-review/" | grep -c '\.yaml$')" "1" "revising leaves one draft entry"
_tap_eq "$(_field "$Q/pending-review/$ID1.yaml" brief_path)" "$B1" "brief_path is unchanged"
_tap_contains "$(cat "$ADV_SANDBOX/$B1")" "Revised." "the entry's brief file carries the revision"

# ----------------------------------------------------------------------------
printf "\n# --- 3. External approval releases the session with the approver's mode ---\n"
if record_draft "$ID1" > /dev/null 2>&1; then
  _tap_pass "record_draft binds the draft to the session"
else
  _tap_fail "record_draft binds the draft to the session"
fi
accept_draft_approval > /dev/null 2>&1
_tap_eq "$?" "2" "accept_draft_approval waits while the draft is pending"
[ -f "$(_PA)" ] && _tap_fail "no plan-approved while pending" || _tap_pass "no plan-approved while pending"

# The agent cannot approve its own draft.
for _cmd in "bash .claude/.automation/queue-cli.sh approve $ID1" \
            "$CLI approve $ID1 --mode auto" \
            "queue-cli.sh approve-wo wo-1" \
            ".claude/.automation/queue-cli.sh add --brief $B1 --auto-approve --solo" \
            "queue-cli.sh follow-up parent-1 --brief $B1 --auto-approve"; do
  _hook bash-guard.sh "$(_bash_json "$_cmd")"
  _tap_eq "$?" "2" "bash-guard blocks a self-approval in a draft session: ${_cmd##*/}"
done
_hook bash-guard.sh "$(_bash_json "bash .claude/.automation/queue-cli.sh draft-status $ID1")"
_tap_eq "$?" "0" "bash-guard allows draft-status"

OUT="$(bash "$CLI" draft-wait "$ID1" --timeout 1 --interval 1 2>&1)"
_tap_eq "$?" "3" "draft-wait times out while the draft is pending"

OUT="$(bash "$CLI" approve "$ID1" --mode auto 2>&1)"
_tap_contains "$OUT" "Approved: $ID1" "approve --mode auto from outside the session"
_tap_eq "$(_field "$Q/approved/$ID1.yaml" auto_mode)" "true" "approve --mode auto records auto_mode"
OUT="$(bash "$CLI" draft-wait "$ID1" --timeout 5 --interval 1 2>&1)"
_tap_eq "$OUT" "$ID1 approved auto" "draft-wait returns once the draft is approved"

OUT="$(accept_draft_approval 2>&1)"
_tap_eq "$?" "0" "accept_draft_approval accepts the external approval"
_tap_contains "$(cat "$(_PA)" 2>/dev/null)" "mode: auto" "plan-approved carries the approver's mode"
_tap_contains "$(cat "$(_PA)" 2>/dev/null)" "source: queue-draft" "plan-approved records the queue-draft provenance"
_tap_contains "$(cat "$(_PA)" 2>/dev/null)" "draft_entry_ids: $ID1" "plan-approved names the draft entry"
_tap_contains "$(cat "$(_PA)" 2>/dev/null)" "session_id: $SID" "plan-approved is stamped with the session id"
_tap_eq "$(get_phase)" "output" "the session moves to output"
_tap_eq "$(get_phase_mode 2>/dev/null || _read_phase_field mode "$(get_session_state_dir)/phase-state")" "auto" "the phase mode is the approver's"

_hook bash-guard.sh "$(_bash_json "bash .claude/.automation/queue-cli.sh approve $ID1")"
_tap_eq "$?" "0" "after an approval the session may run queue-cli approve (in-session path)"
_hook write-guard.sh "$(_edit_json "$BRIEFS/20261112-120000-draft-one.md")"
_tap_eq "$?" "0" "write-guard allows a briefs/ write in output (bundle mode rewrite)"

# Input checks on the new subcommands.
OUT="$(bash "$CLI" approve "$ID1" --mode sometimes 2>&1)"
_tap_contains "$OUT" "--mode must be review or auto" "approve rejects an unknown --mode"
OUT="$(bash "$CLI" approve ../approved/x 2>&1)"
_tap_contains "$OUT" "invalid id" "approve rejects an id that is not a plain file stem"
OUT="$(bash "$CLI" draft-status ../../config 2>&1)"
_tap_contains "$OUT" "invalid id" "draft-status rejects an id that is not a plain file stem"
OUT="$(bash "$CLI" draft-wait "$ID1" --timeout "" 2>&1)"
_tap_contains "$OUT" "take whole seconds" "draft-wait rejects an empty --timeout"

# Default mode is the draft's review.
_new_session
B2=$(_mk_draft 20261112-120100-draft-two)
ID2="$(_entry_id "$(bash "$CLI" add --brief "$B2" 2>/dev/null)")"
record_draft "$ID2" > /dev/null 2>&1
bash "$CLI" approve "$ID2" > /dev/null 2>&1
accept_draft_approval > /dev/null 2>&1
_tap_contains "$(cat "$(_PA)" 2>/dev/null)" "mode: review" "approve without --mode gives review"

# An approval for an entry the session never bound does not release it.
_new_session
accept_draft_approval > /dev/null 2>&1
_tap_eq "$?" "1" "accept_draft_approval refuses a session with no bound draft"
[ -f "$(_PA)" ] && _tap_fail "no plan-approved without a bound draft" || _tap_pass "no plan-approved without a bound draft"

# ----------------------------------------------------------------------------
printf "\n# --- 4. Remove ends the session with no orphan files ---\n"
_new_session
B3=$(_mk_draft 20261112-120200-draft-three)
ID3="$(_entry_id "$(bash "$CLI" add --brief "$B3" 2>/dev/null)")"
record_draft "$ID3" > /dev/null 2>&1
discard_draft > /dev/null 2>&1
_tap_eq "$?" "1" "discard_draft refuses while the entry still exists"
[ -f "$BRIEFS/20261112-120200-draft-three.md" ] && _tap_pass "a refused discard deletes nothing" || _tap_fail "a refused discard deletes nothing"
bash "$CLI" remove "$ID3" > /dev/null 2>&1
OUT="$(bash "$CLI" draft-status "$ID3" 2>&1)"
_tap_eq "$OUT" "$ID3 absent -" "draft-status reports a removed draft as absent"
accept_draft_approval > /dev/null 2>&1
_tap_eq "$?" "3" "accept_draft_approval reports a removed draft as discarded"
discard_draft > /dev/null 2>&1
_tap_eq "$?" "0" "discard_draft runs once the entry is gone"
_LEFT="$(ls "$BRIEFS" | grep -c '^20261112-120200-draft-three' || true)"
_tap_eq "$_LEFT" "0" "the brief, sidecar contract and bundle are deleted"
[ -f "$(_PA)" ] && _tap_fail "a discarded draft is never approved" || _tap_pass "a discarded draft is never approved"

# ----------------------------------------------------------------------------
printf "\n# --- 5. Task group drafts approve together ---\n"
_new_session
G1=$(_mk_draft 20261112-120300-group-one)
G2=$(_mk_draft 20261112-120301-group-two)
GID1="$(_entry_id "$(bash "$CLI" add --brief "$G1" 2>/dev/null)")"
WO="$(_field "$Q/pending-review/$GID1.yaml" work_order_id)"
OUT="$(bash "$CLI" add --brief "$G2" --work-order "$WO" 2>&1)"
GID2="$(_entry_id "$OUT")"
_tap_eq "$(_field "$Q/pending-review/$GID2.yaml" work_order_id)" "$WO" "add --work-order puts the second draft in the first's work order"
OUT="$(bash "$CLI" add --brief "$(_mk_draft 20261112-120302-group-x)" --work-order wo-does-not-exist 2>&1)"
_tap_contains "$OUT" "Work order wo-does-not-exist not found" "add --work-order refuses an unknown work order"
record_draft "$GID1" "$GID2" > /dev/null 2>&1
bash "$CLI" approve "$GID1" > /dev/null 2>&1
accept_draft_approval > /dev/null 2>&1
_tap_eq "$?" "2" "one approved entry of a group with a draft still pending is not an approval"
OUT="$(bash "$CLI" approve-wo "$WO" --mode review 2>&1)"
_tap_contains "$OUT" "Approved" "approve-wo approves the work order"
if [ -f "$Q/approved/$GID2.yaml" ] && [ ! -f "$Q/pending-review/$GID2.yaml" ]; then
  _tap_pass "approve-wo moves every pending draft of the work order to approved/"
else
  _tap_fail "approve-wo moves every pending draft of the work order to approved/"
fi
_tap_eq "$(_field "$Q/approved/$GID2.yaml" auto_mode)" "false" "approve-wo --mode review records review"
accept_draft_approval > /dev/null 2>&1
_tap_eq "$?" "0" "the session accepts the group once every draft is approved"
_tap_contains "$(cat "$(_PA)" 2>/dev/null)" "draft_entry_ids: $GID1 $GID2" "plan-approved names every draft of the group"

# Part removed, part approved: neither an approval nor a discard.
_new_session
P1=$(_mk_draft 20261112-120400-part-one)
P2=$(_mk_draft 20261112-120401-part-two)
PID1="$(_entry_id "$(bash "$CLI" add --brief "$P1" 2>/dev/null)")"
PID2="$(_entry_id "$(bash "$CLI" add --brief "$P2" 2>/dev/null)")"
record_draft "$PID1" "$PID2" > /dev/null 2>&1
bash "$CLI" approve "$PID1" > /dev/null 2>&1
bash "$CLI" remove "$PID2" > /dev/null 2>&1
accept_draft_approval > /dev/null 2>&1
_tap_eq "$?" "4" "a draft part removed and part approved is referred to the operator"
[ -f "$(_PA)" ] && _tap_fail "a part-removed draft is not approved" || _tap_pass "a part-removed draft is not approved"
record_draft "../approved/x" > /dev/null 2>&1
_tap_eq "$?" "1" "record_draft rejects an id that is not a plain file stem"

# ----------------------------------------------------------------------------
printf "\n# --- 6. briefs/ writes only in synthesize and output ---\n"
_tap_eq "$(get_write_phases_for_type taskdef-brief)" "synthesize output" "taskdef-brief write phases"
REPO_OS_ALLOW_REINIT=1 init_phase taskdef-brief > /dev/null 2>&1
advance_phase dispatch > /dev/null 2>&1
_hook write-guard.sh "$(_edit_json "$BRIEFS/20261112-120000-draft-one.md")"
_tap_eq "$?" "2" "write-guard blocks a briefs/ write in dispatch"
advance_phase synthesize > /dev/null 2>&1
_hook write-guard.sh "$(_edit_json "$BRIEFS/20261112-120000-draft-one.md")"
_tap_eq "$?" "0" "write-guard allows a briefs/ write in synthesize"
_hook write-guard.sh "$(_edit_json "$ADV_SANDBOX/lib/product.sh")"
_tap_eq "$?" "2" "write-guard still blocks any write outside briefs/"

# A path that climbs out of briefs/ names a protected file without matching
# any guard's text — the forged-approval route the security review found.
_hook write-guard.sh "$(_edit_json "$BRIEFS/../../.state/wt-sessions/$SID/plan-approved")"
_tap_eq "$?" "2" "write-guard refuses briefs/../../.state (forged plan-approved)"
_hook write-guard.sh "$(_edit_json "$BRIEFS/../queue/approved/forged.yaml")"
_tap_eq "$?" "2" "write-guard refuses briefs/../queue (hand-moved entry)"
REPO_OS_ALLOW_REINIT=1 init_phase standard > /dev/null 2>&1
_hook write-guard.sh "$(_edit_json "$ADV_SANDBOX/lib/../.claude/x/../.state/foo")"
_tap_eq "$?" "2" "write-guard refuses a '..' path in any session type"

# The Bash guards match the resolved target, so '..' cannot hide .state/ or queue/.
_DOTDOT_STATE=".claude/.automation/briefs/../../.state/forged"
_DOTDOT_QUEUE=".claude/.automation/briefs/../queue/approved/forged.yaml"
_hook bash-guard.sh "$(_bash_json "echo x > $_DOTDOT_STATE")"
_tap_contains "$_HOOK_ERR" ".state/ is write-protected" "bash-guard sees a Bash write to briefs/../../.state as a .state write"
_hook write-guard.sh "$(_bash_json "echo x > $_DOTDOT_STATE")"
_tap_contains "$_HOOK_ERR" ".state/ is write-protected" "write-guard sees a Bash write to briefs/../../.state as a .state write"
_hook write-guard.sh "$(_bash_json "echo x > $_DOTDOT_QUEUE")"
_tap_contains "$_HOOK_ERR" "queue/ is write-protected" "write-guard sees a Bash write to briefs/../queue as a queue write"
# Normalising drops a directory target's trailing slash; it must still match.
# (cp/mv are write-guard's: bash-guard's pre-check passes only redirects and tee.)
_hook write-guard.sh "$(_bash_json "cp x .claude/.state/./")"
_tap_contains "$_HOOK_ERR" ".state/ is write-protected" "write-guard sees cp into .claude/.state/./ as a .state write"
_hook write-guard.sh "$(_bash_json "cp x .claude/.automation/queue/approved/../")"
_tap_contains "$_HOOK_ERR" "queue/ is write-protected" "write-guard sees cp into queue/approved/../ as a queue write"

# ----------------------------------------------------------------------------
printf "\n# --- 7. A failed approval changes nothing ---\n"
# A directory where the transition's temp file goes makes that one write fail.
_new_session
F1=$(_mk_draft 20261113-090000-fail-one)
FID1="$(_entry_id "$(bash "$CLI" add --brief "$F1" 2>/dev/null)")"
mkdir -p "$Q/approved/$FID1.yaml.tmp"
bash "$CLI" approve "$FID1" --mode auto > /dev/null 2>&1
_tap_eq "$?" "1" "approve reports a transition that could not be written"
if [ -f "$Q/pending-review/$FID1.yaml" ] && [ ! -f "$Q/approved/$FID1.yaml" ]; then
  _tap_pass "a failed approve leaves the draft in pending-review"
else
  _tap_fail "a failed approve leaves the draft in pending-review"
fi
_tap_eq "$(_field "$Q/pending-review/$FID1.yaml" auto_mode)" "false" "a failed approve --mode auto leaves the draft's mode unchanged"
rmdir "$Q/approved/$FID1.yaml.tmp"
bash "$CLI" remove "$FID1" > /dev/null 2>&1

# approve-wo is all or nothing: the second child fails, the first comes back.
W1=$(_mk_draft 20261113-090100-wo-one)
W2=$(_mk_draft 20261113-090101-wo-two)
WID1="$(_entry_id "$(bash "$CLI" add --brief "$W1" 2>/dev/null)")"
WWO="$(_field "$Q/pending-review/$WID1.yaml" work_order_id)"
WID2="$(_entry_id "$(bash "$CLI" add --brief "$W2" --work-order "$WWO" 2>/dev/null)")"
mkdir -p "$Q/approved/$WID2.yaml.tmp"
OUT="$(bash "$CLI" approve-wo "$WWO" --mode auto 2>&1)"
_tap_eq "$?" "1" "approve-wo reports a child that could not be approved"
if [ -f "$Q/pending-review/$WID1.yaml" ] && [ -f "$Q/pending-review/$WID2.yaml" ] \
   && [ ! -f "$Q/approved/$WID1.yaml" ]; then
  _tap_pass "a failed approve-wo leaves every draft of the work order in pending-review"
else
  _tap_fail "a failed approve-wo leaves every draft of the work order in pending-review"
fi
_tap_eq "$(_field "$Q/pending-review/$WID1.yaml" auto_mode)" "false" "the rolled-back draft keeps its own mode"
case "$OUT" in
  *"Approved:"*) _tap_fail "a failed approve-wo prints no Approved line" ;;
  *)             _tap_pass "a failed approve-wo prints no Approved line" ;;
esac
rmdir "$Q/approved/$WID2.yaml.tmp"
OUT="$(bash "$CLI" approve-wo "$WWO" 2>&1)"
_tap_contains "$OUT" "Approved: $WID2" "approve-wo succeeds once the write can be made"

# ----------------------------------------------------------------------------
printf "\n# --- 8. discard_draft never follows a symlinked directory ---\n"
_new_session
S1=$(_mk_draft 20261113-090200-link-one)
SID1="$(_entry_id "$(bash "$CLI" add --brief "$S1" 2>/dev/null)")"
mkdir -p "$ADV_SANDBOX/.claude/local/task-groups"
printf 'x\n' > "$ADV_SANDBOX/.claude/local/task-groups/real.yaml"
record_draft "$SID1" --also ".claude/local/task-groups/linked/keep.yaml" > /dev/null 2>&1
# The bound path's directory is swapped for a symlink to somewhere outside.
_OUTSIDE="$(mktemp -d)"
printf 'keep\n' > "$_OUTSIDE/keep.yaml"
ln -s "$_OUTSIDE" "$ADV_SANDBOX/.claude/local/task-groups/linked"
bash "$CLI" remove "$SID1" > /dev/null 2>&1
discard_draft > /dev/null 2>&1
[ -f "$_OUTSIDE/keep.yaml" ] && _tap_pass "a file under a symlinked directory is not removed" \
  || _tap_fail "a file under a symlinked directory is not removed"
_tap_eq "$(ls "$BRIEFS" | grep -c '^20261113-090200-link-one' || true)" "0" "the draft's own files are still removed"
# An ancestor symlink: the whole task-groups directory points outside.
_new_session
S2=$(_mk_draft 20261113-090300-link-two)
SID2="$(_entry_id "$(bash "$CLI" add --brief "$S2" 2>/dev/null)")"
mv "$ADV_SANDBOX/.claude/local/task-groups" "$ADV_SANDBOX/.claude/local/task-groups.real"
mkdir -p "$_OUTSIDE/tg/sub"
printf 'keep\n' > "$_OUTSIDE/tg/sub/keep.yaml"
ln -s "$_OUTSIDE/tg" "$ADV_SANDBOX/.claude/local/task-groups"
record_draft "$SID2" --also ".claude/local/task-groups/sub/keep.yaml" > /dev/null 2>&1
_tap_eq "$?" "0" "record_draft binds the second link draft"
bash "$CLI" remove "$SID2" > /dev/null 2>&1
discard_draft > /dev/null 2>&1
_tap_eq "$?" "0" "discard_draft runs for the second link draft"
_tap_eq "$(ls "$BRIEFS" | grep -c '^20261113-090300-link-two' || true)" "0" "the second link draft's own files are removed"
[ -f "$_OUTSIDE/tg/sub/keep.yaml" ] && _tap_pass "a file under a symlinked ancestor directory is not removed" \
  || _tap_fail "a file under a symlinked ancestor directory is not removed"
rm -f "$ADV_SANDBOX/.claude/local/task-groups"
mv "$ADV_SANDBOX/.claude/local/task-groups.real" "$ADV_SANDBOX/.claude/local/task-groups"
rm -rf "$_OUTSIDE"

# ----------------------------------------------------------------------------
printf "\n# --- 9. prune --briefs-only sweeps orphaned Prompt T briefs (R49) ---\n"
# A Prompt T brief has a .bundle.yaml beside it; a hand-written one does not.
_old() { touch -t 202001010000 "$BRIEFS/$1".*; }
_mk_draft 20261113-100000-orphan-old > /dev/null; _old 20261113-100000-orphan-old
_mk_draft 20261113-100100-orphan-new > /dev/null
_mk_draft 20261113-100200-referenced > /dev/null
RID="$(_entry_id "$(bash "$CLI" add --brief .claude/.automation/briefs/20261113-100200-referenced.md 2>/dev/null)")"
_old 20261113-100200-referenced
printf '## Task Brief: by hand\n' > "$BRIEFS/20261113-100300-hand-written.md"
_old 20261113-100300-hand-written
_LINKED="$(mktemp -d)"
printf 'keep\n' > "$_LINKED/brief.md"
ln -s "$_LINKED/brief.md" "$BRIEFS/20261113-100400-linked.md"
printf 'brief_id: "linked"\n' > "$BRIEFS/20261113-100400-linked.bundle.yaml"
_old 20261113-100400-linked
touch -h -t 202001010000 "$BRIEFS/20261113-100400-linked.md"

OUT="$(bash "$CLI" prune --briefs-only 2>&1)"
_tap_eq "$?" "0" "prune --briefs-only runs"
_tap_eq "$(ls "$BRIEFS" | grep -c '^20261113-100000-orphan-old' || true)" "0" \
  "an old unreferenced Prompt T brief is removed with its contract and bundle"
_tap_eq "$(ls "$BRIEFS" | grep -c '^20261113-100100-orphan-new' || true)" "3" \
  "a recent unreferenced brief is kept"
_tap_eq "$(ls "$BRIEFS" | grep -c '^20261113-100200-referenced' || true)" "3" \
  "a brief a queue entry references is kept"
[ -f "$BRIEFS/20261113-100300-hand-written.md" ] && _tap_pass "a brief with no bundle (hand-written) is kept" \
  || _tap_fail "a brief with no bundle (hand-written) is kept"
[ -f "$_LINKED/brief.md" ] && [ -L "$BRIEFS/20261113-100400-linked.md" ] \
  && _tap_pass "a symlinked brief and its target are kept" \
  || _tap_fail "a symlinked brief and its target are kept"
_tap_contains "$OUT" "Pruned" "prune --briefs-only reports what it pruned"
# An unreadable queue file makes grep exit 2; that must keep the brief, not
# read as "no entry references it".
# Root reads a mode-000 file, so grep would not error and the case would fail
# for the wrong reason: skip it there (pass-marked, so the counters stay right).
if [ "$(id -u)" = "0" ]; then
  _tap_pass "a grep error while checking references keeps the brief # SKIP running as root, mode 000 is readable"
else
  _mk_draft 20261113-100500-grep-error > /dev/null; _old 20261113-100500-grep-error
  _UNREAD="$Q/approved/zz-unreadable.yaml"
  printf 'brief_path: x\n' > "$_UNREAD"; chmod 000 "$_UNREAD"
  bash "$CLI" prune --briefs-only > /dev/null 2>&1
  _tap_eq "$(ls "$BRIEFS" | grep -c '^20261113-100500-grep-error' || true)" "3" \
    "a grep error while checking references keeps the brief"
  chmod 644 "$_UNREAD"; rm -f "$_UNREAD"
fi
# No queue directory: nothing is deleted. Pins the behaviour (grep's rc 2 would
# also keep it); the old `[ -d ]` wrapper skipped grep and deleted.
_NOQ="$(mktemp -d)"
mkdir -p "$_NOQ/briefs"
for _ext in md contract.yaml bundle.yaml; do
  printf 'x\n' > "$_NOQ/briefs/20261113-100600-no-queue.$_ext"
done
touch -t 202001010000 "$_NOQ/briefs/20261113-100600-no-queue".*
_CLEANUP_LIB="$AUTOMATION_DIR/lib/cleanup.sh"
# shellcheck disable=SC1090
_NOQ_OUT="$( source "$_CLEANUP_LIB" 2>/dev/null; AUTOMATION_DIR="$_NOQ"; _QUEUE_DIR="$_NOQ/queue"; \
  _clean_orphan_briefs 30 2>/dev/null )"
_tap_eq "$(ls "$_NOQ/briefs" | grep -c '^20261113-100600-no-queue' || true)" "3" \
  "with no queue directory the orphan sweep deletes nothing"
_tap_eq "${_NOQ_OUT:-}" "0" "with no queue directory the sweep reports 0 deleted"
rm -rf "$_NOQ"
bash "$CLI" remove "$RID" > /dev/null 2>&1
rm -rf "$_LINKED"

# The queue lock must be free after every subcommand above.
if acquire_queue_lock; then
  release_queue_lock
  _tap_pass "the draft subcommands leave the queue lock released"
else
  _tap_fail "the draft subcommands leave the queue lock released" "lock still held"
fi

# --- Summary ---
printf "\n1..%d\n" "$_TAP_NUM"
printf "# Tests: %d  Pass: %d  Fail: %d\n" "$_TAP_NUM" "$_TAP_PASS" "$_TAP_FAIL"
[ "$_TAP_FAIL" -gt 0 ] && printf "# Failures:\n%b" "$_TAP_FAILURES"
exit "$_TAP_FAIL"
