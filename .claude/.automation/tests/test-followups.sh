#!/usr/bin/env bash
# Follow-ups — Decision t-0055 clause 14
#
# One case per line of the brief's verification checklist. The feature is three
# separate mechanisms reading one `follow_up_of` pointer, and each can fail
# independently, so each gets its own fixture:
#
#   1. ORDER   — queue_dequeue refuses a follow-up until its parent completes,
#                and queue_hold_evaluate holds it when the parent stops.
#   2. BRANCH  — _followup_resolve_branch continues the parent's branch while
#                that branch is still a live line of work, and cuts a new one
#                off main once it has landed.
#   3. CONTEXT — queue-cli.sh links both directions, follow-up-draft reports
#                what the parent left undone, and the runner's Parent task
#                section reaches the agent's prompt.
#
# Running the real queue-cli.sh through `bash` is also the only syntax check
# this suite can give it, which is why the CLI block drives the script rather
# than re-implementing its logic. Bash 3.2 compatible.

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

printf "# === Follow-ups (Decision t-0055 clause 14) ===\n"

setup_adversarial_sandbox
trap 'teardown_adversarial_sandbox' EXIT

REPO_ROOT="$ADV_SANDBOX"; export REPO_ROOT
AUTOMATION_DIR="$ADV_SANDBOX/.claude/.automation"; export AUTOMATION_DIR

# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/hooks/_analytics-helper.sh"
# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/hooks/_cleanup-helper.sh"

# Pin the main repo root to the sandbox — see the same block in
# test-operator-control.sh for why. Short version: get_main_repo_root() derives
# from `git rev-parse --git-common-dir`, so a suite run from inside a worktree
# resolves to the REAL repository and the fixture and the code under test then
# read two different directories.
cd "$ADV_SANDBOX" || exit 1
_CACHED_MAIN_REPO_ROOT="$ADV_SANDBOX"
_CACHED_SESSION_STATE_DIR=""
_tap_eq "$(get_main_repo_root)" "$ADV_SANDBOX" "fixture: main repo root is pinned to the sandbox"

export CONFIG_FILE="$ADV_SANDBOX/.claude/.automation/config.yaml"
# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/.automation/lib/file-lock.sh"
# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/.automation/lib/queue-manager.sh"
# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/.automation/lib/work-order-manager.sh"
# queue-manager.sh sets `set -euo pipefail` at load; half the assertions below
# are on non-zero exits, so turn errexit straight back off.
set +e

_FU_Q="$ADV_SANDBOX/.claude/.automation/queue"
_FU_BRIEFS_ABS="$ADV_SANDBOX/.claude/.automation/briefs"
_ensure_queue_dirs
mkdir -p "$_FU_BRIEFS_ABS" "$ADV_SANDBOX/.claude/.automation/escalations" \
         "$ADV_SANDBOX/.claude/.state/sessions" \
         "$ADV_SANDBOX/docs/ai/governance/criteria-verdicts"

# --- Git fixture: main, one live branch, one landed branch ------------------
# _followup_resolve_branch asks git one question — "is the parent's branch still
# a line of work main does not already have?" — so the suite needs both answers
# to exist as real refs rather than mocked.
(
  cd "$ADV_SANDBOX" || exit 1
  git branch -f main HEAD 2>/dev/null
  git checkout -q -b feature/fu-live main 2>/dev/null
  echo "work in progress" > fu-live.txt
  git add fu-live.txt
  git commit -q -m "parent's unmerged work" 2>/dev/null
  # A branch pointing AT main is indistinguishable from a merged-and-sealed one
  # as far as the question above goes, which is the point: both mean there is
  # nothing left on it to continue.
  git branch -f feature/fu-landed main 2>/dev/null
  git checkout -q feature/test 2>/dev/null
) > /dev/null 2>&1

# $1 basename; remaining args scope paths. Returns an ABSOLUTE path: the CLI
# runs in its own process and entry files are read by both, so a relative
# brief_path would resolve against whichever cwd happened to be current.
_fu_mk_brief() {
  local name="$1"; shift
  local path="$_FU_BRIEFS_ABS/$name.md"
  {
    printf '# %s\n\n' "$name"
    printf '## Goal\n\nThe %s goal sentence.\n\n' "$name"
    printf '### Task Contract\n\n```yaml\n'
    printf 'goal: "fixture"\n'
    if [ $# -gt 0 ]; then
      printf 'scope_files:\n'
      local p
      for p in "$@"; do printf '  - "%s"\n' "$p"; done
    fi
    printf 'lifecycle: task-scoped\n```\n'
  } > "$path"
  printf '%s' "$path"
}

# $1 id · $2 status (also the directory) · $3 created_at · $4 branch
# $5 brief_path · $6 follow_up_of (optional) · $7 work_order_id (optional)
_fu_mk_entry() {
  _load_queue_entry "$ADV_SANDBOX/.no-such-entry.yaml" 2>/dev/null
  _QE_ID="$1"; _QE_STATUS="$2"; _QE_PRIORITY="0"
  _QE_SESSION_TYPE="standard"; _QE_BRANCH="$4"; _QE_BRIEF_PATH="$5"
  _QE_AUTO_MODE="false"; _QE_SOLO_MODE="true"; _QE_PUSH_ON_COMPLETE="false"
  _QE_RETRY_COUNT="0"; _QE_MAX_RETRIES="3"; _QE_INDEPENDENT="false"
  _QE_FOLLOW_UP_OF="${6:-}"; _QE_WORK_ORDER_ID="${7:-}"
  _QE_CREATED_AT="$3"; _QE_UPDATED_AT="$3"
  _write_queue_entry "$_FU_Q/$2/$1.yaml"
}

_fu_field() {
  # $1 status dir · $2 id · $3 _QE_ variable suffix
  _load_queue_entry "$_FU_Q/$1/$2.yaml" 2>/dev/null
  eval "printf '%s' \"\${_QE_$3:-}\""
}

# ============================================================
# Round-trip: the field survives write → read, and old entries still load
# ============================================================
printf "\n# --- the field round-trips, and pre-v1.9.0 entries still load ---\n"

_B_RT=$(_fu_mk_brief fu-roundtrip "lib/rt.sh")
_fu_mk_entry fu-rt-child pending-review "2026-10-21T10:00:00Z" "" "$_B_RT" "fu-rt-parent"
_tap_eq "$(_fu_field pending-review fu-rt-child FOLLOW_UP_OF)" "fu-rt-parent" \
  "follow_up_of survives _write_queue_entry → _load_queue_entry"

# An entry written before v1.9.0 has no follow_up_of line at all. It must load
# as empty rather than inheriting the previous entry's parent — the reader
# resets every _QE_* before parsing, and this is the case that proves it.
grep -v '^  follow_up_of:' "$_FU_Q/pending-review/fu-rt-child.yaml" \
  > "$_FU_Q/pending-review/fu-rt-old.yaml"
sed -i.bak 's/^  id: .*/  id: "fu-rt-old"/' "$_FU_Q/pending-review/fu-rt-old.yaml" 2>/dev/null
rm -f "$_FU_Q/pending-review/fu-rt-old.yaml.bak"
_tap_eq "$(_fu_field pending-review fu-rt-old FOLLOW_UP_OF)" "" \
  "an entry with no follow_up_of line loads as empty, not as its neighbour's parent"
_tap_eq "$(_fu_field pending-review fu-rt-old ID)" "fu-rt-old" \
  "the pre-v1.9.0 entry otherwise loads intact"
rm -f "$_FU_Q/pending-review/fu-rt-old.yaml" "$_FU_Q/pending-review/fu-rt-child.yaml"

# ============================================================
# Branch resolution (the brief's branch/order table)
# ============================================================
printf "\n# --- where a follow-up runs, decided at dequeue ---\n"

_B_LIVE=$(_fu_mk_brief fu-live-parent "lib/live.sh")
_B_LANDED=$(_fu_mk_brief fu-landed-parent "lib/landed.sh")
_B_NOBRANCH=$(_fu_mk_brief fu-nobranch-parent "lib/nobranch.sh")

_fu_mk_entry fu-live-p    running        "2026-10-21T09:00:00Z" "feature/fu-live"   "$_B_LIVE"
_fu_mk_entry fu-landed-p  completed      "2026-10-21T09:00:00Z" "feature/fu-landed" "$_B_LANDED"
# pending-review, not approved: the dequeue-order block below counts on knowing
# exactly which entries are eligible, and this one exists only to be read.
_fu_mk_entry fu-nobr-p    pending-review "2026-10-21T09:00:00Z" ""                  "$_B_NOBRANCH"

_tap_eq "$(_followup_resolve_branch fu-live-p 1)" "feature/fu-live" \
  "a parent whose branch is still unmerged: the follow-up continues that branch"
_tap_eq "$(_followup_resolve_branch fu-landed-p 1)" "follow-up/fu-landed-1" \
  "a parent whose branch has landed in main: the follow-up gets its own branch"
_tap_eq "$(_followup_resolve_branch fu-nobr-p 1)" "follow-up/fu-nobranch-parent-1" \
  "a parent with no branch yet: the name falls back to its brief"
_tap_eq "$(_followup_resolve_branch fu-live-p 3)" "feature/fu-live" \
  "<n> does not change the answer when the parent's branch is continued"
_tap_eq "$(_followup_resolve_branch fu-landed-p 3)" "follow-up/fu-landed-3" \
  "<n> distinguishes sibling follow-ups of the same landed parent"
_tap_eq "$(_followup_resolve_branch no-such-entry 1)" "follow-up/no-such-entry-1" \
  "a parent that no longer exists still yields a usable branch name"

# The slug has to survive a branch name that is not already a safe ref leaf.
_tap_eq "$(_followup_slug 'feature/Task Group__Header!!')" "task-group-header" \
  "the slug folds case, separators and runs"
_tap_eq "$(_followup_slug '.claude/.automation/briefs/Brief-07.md')" "brief-07" \
  "the slug reads a brief basename without its extension"
_tap_eq "$(_followup_slug '///')" "entry" \
  "a slug with nothing usable in it still produces a ref-safe name"

# _followup_parent_state reads the directory, and must not disturb the caller's
# loaded entry — queue_dequeue calls it mid-candidate.
_tap_eq "$(_followup_parent_state fu-live-p)" "running" "parent state is read from its directory"
_tap_eq "$(_followup_parent_state fu-landed-p)" "completed" "a completed parent reports completed"
_tap_eq "$(_followup_parent_state no-such-entry)" "missing" "a pruned parent reports missing"
_tap_eq "$(_followup_parent_state '')" "missing" "an empty parent id reports missing"

# ============================================================
# Order: a follow-up never overtakes its parent
# ============================================================
printf "\n# --- a follow-up is dequeued only after its parent completes ---\n"

_B_FUCHILD=$(_fu_mk_brief fu-child-live "lib/child.sh")
_B_CONTROL=$(_fu_mk_brief fu-control "lib/control.sh")

# Created BEFORE the control entry, so if the guard were missing it would be
# dequeued first and the assertion below would be unambiguous about why.
_fu_mk_entry fu-live-c approved "2026-10-21T10:00:00Z" "" "$_B_FUCHILD" "fu-live-p"
_fu_mk_entry fu-ctl    approved "2026-10-21T11:00:00Z" "feature/ctl" "$_B_CONTROL"

_DQ=$(queue_dequeue); _DQ="${_DQ##*/}"; _DQ="${_DQ%.yaml}"
_tap_eq "${_DQ:-none}" "fu-ctl" \
  "the selector skips the follow-up of a running parent and takes the later entry"
_DQ=$(queue_dequeue); _DQ="${_DQ##*/}"; _DQ="${_DQ%.yaml}"
_tap_eq "${_DQ:-none}" "none" \
  "with only the follow-up left, the queue runs dry rather than starting it early"
_tap_eq "$(_fu_field approved fu-live-c BRANCH)" "" \
  "a follow-up that was not dequeued has not had its branch resolved yet"

# The parent finishes. Nothing else changes — no stop, no approval, no edit.
_transition fu-live-p running completed > /dev/null 2>&1
_DQ=$(queue_dequeue); _DQ="${_DQ##*/}"; _DQ="${_DQ%.yaml}"
_tap_eq "${_DQ:-none}" "fu-live-c" \
  "the parent completing is what releases the follow-up"
_tap_eq "$(_fu_field running fu-live-c BRANCH)" "feature/fu-live" \
  "the branch is resolved and written back at dequeue, onto the parent's unmerged branch"

# The other half of the table: a parent whose branch has landed. Same mechanism,
# different answer, so it is asserted through the selector too and not only
# through _followup_resolve_branch.
printf "\n# --- a follow-up of merged work starts a new branch, in normal order ---\n"
_B_LCHILD=$(_fu_mk_brief followup-fu-landed-p-2 "lib/lchild.sh")
_fu_mk_entry fu-landed-c approved "2026-10-21T12:00:00Z" "" "$_B_LCHILD" "fu-landed-p"
_DQ=$(queue_dequeue); _DQ="${_DQ##*/}"; _DQ="${_DQ%.yaml}"
_tap_eq "${_DQ:-none}" "fu-landed-c" \
  "a follow-up of an already-completed parent is eligible immediately"
_tap_eq "$(_fu_field running fu-landed-c BRANCH)" "follow-up/fu-landed-2" \
  "its branch is cut fresh, numbered from the brief filename rather than recounted"

# ============================================================
# A stopped parent holds its follow-up (clause 10 ∩ clause 14)
# ============================================================
printf "\n# --- a follow-up is held while its parent is stopped ---\n"

_B_STOPPED=$(_fu_mk_brief fu-stopped-parent "lib/stopped.sh")
_B_SCHILD=$(_fu_mk_brief fu-stopped-child "lib/schild.sh")
_B_SOTHER=$(_fu_mk_brief fu-stopped-other "lib/sother.sh")

_fu_mk_entry fu-stop-p approved "2026-10-21T13:00:00Z" "feature/fu-stopped" "$_B_STOPPED"
_transition fu-stop-p approved running  > /dev/null 2>&1
_transition fu-stop-p running  stopped  > /dev/null 2>&1

# Disjoint scope, unrelated branch, no shared work order: everything EXCEPT the
# follow-up link says release. If the child is held anyway, clause 14(d) is the
# only thing that can be holding it.
_fu_mk_entry fu-stop-c approved "2026-10-21T14:00:00Z" ""              "$_B_SCHILD" "fu-stop-p"
_fu_mk_entry fu-stop-o approved "2026-10-21T14:00:00Z" "feature/other" "$_B_SOTHER"

queue_hold_evaluate
_tap_eq "$(_fu_field approved fu-stop-c HELD_BY)" "fu-stop-p" \
  "a follow-up of the stopped entry is held, despite disjoint scope and no shared branch"
_tap_eq "$(_fu_field approved fu-stop-o HELD_BY)" "" \
  "control: an unrelated entry with the same disjoint scope is released"

_FU_HOLDING="$(queue_hold_holding fu-stop-p | sort | tr '\n' ' ')"
_tap_contains "$_FU_HOLDING" "fu-stop-c" "queue_hold_holding names the held follow-up"

# ============================================================
# The reverse direction
# ============================================================
printf "\n# --- queue_followups_of walks the link backwards ---\n"
_FU_OF="$(queue_followups_of fu-landed-p | tr '\t' '=' | sort | tr '\n' ' ')"
_tap_eq "$_FU_OF" "fu-landed-c=running " "queue_followups_of reports id and current status"
_tap_eq "$(queue_followups_of fu-stop-p | tr '\t' '=' | tr -d '\n')" "fu-stop-c=approved" \
  "a held follow-up is still reported, with the status it is waiting in"
_tap_eq "$(queue_followups_of fu-ctl)" "" "an entry with no follow-ups reports nothing"
_tap_eq "$(queue_followups_of '')" "" "an empty parent id reports nothing"

# ============================================================
# queue-cli.sh — the operator's side of all of the above
# ============================================================
printf "\n# === queue-cli.sh (t-0055 clause 14) ===\n"
cp "$_ADV_REAL_REPO/.claude/.automation/queue-cli.sh" "$ADV_SANDBOX/.claude/.automation/queue-cli.sh"
_FU_CLI="$ADV_SANDBOX/.claude/.automation/queue-cli.sh"

# A completed parent carrying the metadata a follow-up should inherit.
_B_CLIP=$(_fu_mk_brief fu-cli-parent "lib/cli.sh")
_load_queue_entry "$ADV_SANDBOX/.no-such-entry.yaml" 2>/dev/null
_QE_ID="fu-cli-p"; _QE_STATUS="completed"; _QE_PRIORITY="7"
_QE_SESSION_TYPE="standard"; _QE_BRANCH="feature/fu-live"; _QE_BRIEF_PATH="$_B_CLIP"
_QE_AUTO_MODE="false"; _QE_SOLO_MODE="true"; _QE_PUSH_ON_COMPLETE="false"
_QE_RETRY_COUNT="0"; _QE_MAX_RETRIES="3"; _QE_INDEPENDENT="false"
_QE_PROJECT="atlas"; _QE_MILESTONE_NAME="m1"; _QE_MILESTONE_INDEX="2"; _QE_MILESTONE_TOTAL="5"
_QE_CREATED_AT="2026-10-21T08:00:00Z"; _QE_UPDATED_AT="2026-10-21T08:00:00Z"
_write_queue_entry "$_FU_Q/completed/fu-cli-p.yaml"

_B_SRC=$(_fu_mk_brief fu-cli-source "lib/src.sh")

printf "\n# --- follow-up-entry ---\n"
OUT="$(bash "$_FU_CLI" follow-up-entry fu-cli-p --brief "$_B_SRC" 2>&1)"
_FU_CHILD_ID="$(printf '%s\n' "$OUT" | sed -n 's/^entry_id: *//p')"
_tap_contains "$OUT" "follow_up_of:    fu-cli-p (completed)" \
  "follow-up-entry names the parent and the status it found it in"
_tap_contains "$OUT" "followup-fu-cli-p-1.md" \
  "the brief is copied to briefs/followup-<parent-id>-<n>.md"
_tap_contains "$OUT" "resolved at dequeue" \
  "the branch is reported as a forecast, not as a stored value"
if [ -f "$_FU_BRIEFS_ABS/followup-fu-cli-p-1.md" ]; then
  _tap_pass "the renamed brief exists on disk"
else
  _tap_fail "the renamed brief exists on disk" "not found in $_FU_BRIEFS_ABS"
fi

if [ -n "$_FU_CHILD_ID" ] && [ -f "$_FU_Q/pending-review/$_FU_CHILD_ID.yaml" ]; then
  _tap_pass "the follow-up lands in pending-review/ without --auto-approve"
else
  _tap_fail "the follow-up lands in pending-review/ without --auto-approve" "id='$_FU_CHILD_ID'"
fi
_tap_eq "$(_fu_field pending-review "$_FU_CHILD_ID" FOLLOW_UP_OF)" "fu-cli-p" \
  "the new entry carries follow_up_of"
_tap_eq "$(_fu_field pending-review "$_FU_CHILD_ID" BRANCH)" "" \
  "branch is left empty on purpose — the selector resolves it"
_tap_eq "$(_fu_field pending-review "$_FU_CHILD_ID" PROJECT)" "atlas" \
  "project is inherited from the parent"
_tap_eq "$(_fu_field pending-review "$_FU_CHILD_ID" MILESTONE_NAME)" "m1" \
  "milestone is inherited from the parent"
_tap_eq "$(_fu_field pending-review "$_FU_CHILD_ID" PRIORITY)" "7" \
  "priority is inherited when not given"

# Second follow-up of the same parent: the number advances, and an explicit
# flag beats the inheritance.
OUT="$(bash "$_FU_CLI" --json follow-up-entry fu-cli-p --brief "$_B_SRC" --priority 1 --auto-approve 2>&1)"
_tap_contains "$OUT" '"follow_up_of":"fu-cli-p"' "follow-up-entry --json reports the link"
_tap_contains "$OUT" '"status":"approved"' "--auto-approve approves the new entry"
_tap_contains "$OUT" "followup-fu-cli-p-2.md" "<n> advances for a second follow-up of the same parent"
_tap_contains "$OUT" '"branch_forecast":"feature/fu-live"' \
  "the forecast agrees with what the selector would resolve"
_FU_CHILD2_ID="$(printf '%s\n' "$OUT" | sed -n 's/.*"entry_id":"\([^"]*\)".*/\1/p')"
_tap_eq "$(_fu_field approved "$_FU_CHILD2_ID" PRIORITY)" "1" \
  "an explicit --priority overrides the inherited one"

printf "\n# --- follow-up-entry refuses what it cannot link ---\n"
OUT="$(bash "$_FU_CLI" follow-up-entry no-such-parent --brief "$_B_SRC" 2>&1)"
_tap_contains "$OUT" "Parent entry no-such-parent not found" "an unknown parent is refused"
OUT="$(bash "$_FU_CLI" follow-up-entry fu-cli-p 2>&1)"
_tap_contains "$OUT" "requires --brief" "a missing brief is refused"
_tap_contains "$OUT" "follow-up-draft fu-cli-p" "and the error points at the draft command"
OUT="$(bash "$_FU_CLI" follow-up-entry fu-cli-p --brief "$ADV_SANDBOX/.claude/.automation/briefs/nope.md" 2>&1)"
_tap_contains "$OUT" "Brief file not found" "a missing brief file is refused"
OUT="$(bash "$_FU_CLI" follow-up-entry 2>&1)"
_tap_contains "$OUT" "requires <parent-id>" "no parent id at all is refused"

# A follow-up of a follow-up points at what it extends, not at the chain head.
OUT="$(bash "$_FU_CLI" follow-up-entry "$_FU_CHILD2_ID" --brief "$_B_SRC" 2>&1)"
_tap_contains "$OUT" "is itself a follow-up of fu-cli-p" "a chained follow-up says so"
_FU_CHILD3_ID="$(printf '%s\n' "$OUT" | sed -n 's/^entry_id: *//p')"
_tap_eq "$(_fu_field pending-review "$_FU_CHILD3_ID" FOLLOW_UP_OF)" "$_FU_CHILD2_ID" \
  "the chained follow-up points at its immediate parent, not at the head"
_tap_contains "$OUT" "held until $_FU_CHILD2_ID completes" \
  "a parent that has not run yet is reported as a wait"

# What the operator is told about WHEN it runs has to match what the dequeue
# guard will actually do, and the guard releases on `completed` and `missing`
# only. `failed/` is also where discard-entry puts an entry, so this is not a
# rare corner — and "held until it completes" would be a lie discovered only by
# waiting for a tick that never comes.
_B_FAILP=$(_fu_mk_brief fu-failed-parent "lib/failed.sh")
_load_queue_entry "$ADV_SANDBOX/.no-such-entry.yaml" 2>/dev/null
_QE_ID="fu-dead-p"; _QE_STATUS="failed"; _QE_PRIORITY="5"
_QE_SESSION_TYPE="standard"; _QE_BRANCH="feature/fu-landed"; _QE_BRIEF_PATH="$_B_FAILP"
_QE_AUTO_MODE="false"; _QE_SOLO_MODE="true"; _QE_PUSH_ON_COMPLETE="false"
_QE_RETRY_COUNT="0"; _QE_MAX_RETRIES="3"; _QE_INDEPENDENT="false"
_QE_CREATED_AT="2026-10-21T08:00:00Z"; _QE_UPDATED_AT="2026-10-21T08:00:00Z"
_write_queue_entry "$_FU_Q/failed/fu-dead-p.yaml"

OUT="$(bash "$_FU_CLI" follow-up-entry fu-dead-p --brief "$_B_SRC" 2>&1)"
_tap_contains "$OUT" "held indefinitely" \
  "a follow-up of a failed parent is told it will not be released on its own"
_tap_contains "$OUT" "discard this follow-up or re-queue the parent" \
  "and is told the two ways out"
_tap_lacks "$OUT" "held until fu-dead-p completes" \
  "it is not promised a completion that cannot happen"

OUT="$(bash "$_FU_CLI" follow-up-entry fu-cli-p --brief "$_B_SRC" 2>&1)"
_tap_lacks "$OUT" "order:" \
  "a follow-up of a completed parent reports no wait at all"

printf "\n# --- show --json and list --json link both directions ---\n"
OUT="$(bash "$_FU_CLI" --json show fu-cli-p 2>&1)"
_tap_contains "$OUT" '"follow_ups":[' "show --json on a parent carries a follow_ups array"
_tap_contains "$OUT" "\"id\":\"$_FU_CHILD_ID\"" "the array names the first follow-up"
_tap_contains "$OUT" "\"id\":\"$_FU_CHILD2_ID\"" "the array names the second follow-up"
_tap_contains "$OUT" '"status":"approved"' "the array carries each follow-up's current status"
_tap_contains "$OUT" '"follow_up_of":""' "a parent that is not itself a follow-up reports an empty link"

OUT="$(bash "$_FU_CLI" --json show "$_FU_CHILD_ID" 2>&1)"
_tap_contains "$OUT" '"follow_up_of":"fu-cli-p"' "show --json on a follow-up reports its parent"
_tap_contains "$OUT" '"follow_ups":[]' "a follow-up with no children of its own reports an empty array"
_tap_contains "$OUT" '"hold":{' "the other derived blocks still survive the added scan"

# A follow-up inherits its parent's milestone AND gets a work order, and that
# pair used to make _resolve_entry_metadata return 1 — which, called plainly
# under `set -e`, killed `show --json` with no output at all. Assert on output
# that only exists if the script reached the end.
_tap_contains "$OUT" '"milestone_total":5' \
  "show --json survives an entry that has both a work order and its own milestone"

# `list` reads the queue index, which the fixtures above wrote entry files
# behind the back of. Rebuild it so the rows exist to assert on.
_rebuild_queue_index
OUT="$(bash "$_FU_CLI" --json list 2>&1)"
_tap_contains "$OUT" '"follow_up_of":"fu-cli-p"' "list --json carries follow_up_of on the row"
_tap_contains "$OUT" '"follow_up_of":""' "a non-follow-up row reports an empty link rather than its neighbour's"

# ============================================================
# follow-up-draft — what the parent left undone
# ============================================================
printf "\n# --- follow-up-draft ---\n"

# A parent with one of each evidence source: two unticked boxes in its brief, a
# PARTIAL criterion in its verdict file, and an unresolved escalation.
cat > "$_FU_BRIEFS_ABS/fu-draft-parent.md" <<'BRIEF'
# Header shows the task name

## Goal

The operator can see which task a session belongs to.

## Verification checklist

- [x] The header renders on a running task.
- [ ] The header renders on a stopped task.
- [ ] The header survives a resume.

### Task Contract

```yaml
goal: "fixture"
scope_files:
  - "lib/draft.sh"
lifecycle: task-scoped
```
BRIEF
_fu_mk_entry fu-draft-p completed "2026-10-21T07:00:00Z" "feature/fu-live" \
  "$_FU_BRIEFS_ABS/fu-draft-parent.md" "" "wo-draft"

cat > "$ADV_SANDBOX/.claude/.state/sessions/daemon-fu-draft.yaml" <<'REC'
session_id: daemon-fu-draft
entry_id: fu-draft-p
REC

cat > "$ADV_SANDBOX/docs/ai/governance/criteria-verdicts/daemon-fu-draft.yaml" <<'VERDICT'
session_id: "daemon-fu-draft"
criteria:
  - criterion: "The header renders on a running task"
    verdict: MET
  - criterion: "The header survives a resume"
    verdict: PARTIAL
  - criterion: "The header is readable at narrow widths"
    verdict: INCONCLUSIVE
VERDICT

cat > "$ADV_SANDBOX/.claude/.automation/escalations/fu-draft-esc.yaml" <<'ESC'
escalation:
  queue_entry_id: "fu-draft-p"
  type: "gate-failure"
  resolved: false
ESC

OUT="$(bash "$_FU_CLI" follow-up-draft fu-draft-p 2>&1)"
_tap_contains "$OUT" "# Follow-up: Header shows the task name" \
  "the draft takes its title from the parent brief"
_tap_contains "$OUT" "## Parent task" "the draft opens with the parent's identity"
_tap_contains "$OUT" '- Entry: `fu-draft-p` (completed)' "it names the entry and its status"
_tap_contains "$OUT" '- Work order: `wo-draft`' "it names the work order when there is one"
_tap_contains "$OUT" '- Session: `daemon-fu-draft`' "it resolves the parent's session id"
_tap_contains "$OUT" "Its goal was: The operator can see which task a session belongs to." \
  "it carries the parent's goal as context"
_tap_contains "$OUT" "The header renders on a stopped task." \
  "it lists an unticked checklist item from the parent brief"
_tap_contains "$OUT" "Unticked in the parent brief (2)" "it counts only the unticked boxes"
_tap_lacks "$OUT" "The header renders on a running task." \
  "a ticked checklist item is not carried over"
_tap_contains "$OUT" "(PARTIAL in daemon-fu-draft)" "a PARTIAL criterion is carried over"
_tap_contains "$OUT" "The header is readable at narrow widths (INCONCLUSIVE in daemon-fu-draft)" \
  "an INCONCLUSIVE criterion is carried over — nobody could confirm it"
_tap_contains "$OUT" "Resolve escalation fu-draft-esc.yaml (gate-failure, unresolved)" \
  "an unresolved escalation naming the parent is carried over"
_tap_contains "$OUT" "### Task Contract" "the draft is a brief, contract and all"
_tap_contains "$OUT" "evidence of a" "the draft says the items are evidence, not an agreed goal"

OUT="$(bash "$_FU_CLI" --json follow-up-draft fu-draft-p 2>&1)"
_tap_contains "$OUT" '"unmet_checklist":2' "--json counts the unticked items"
_tap_contains "$OUT" '"open_criteria":2' "--json counts the unconfirmed criteria"
_tap_contains "$OUT" '"open_escalations":1' "--json counts the unresolved escalations"
_tap_contains "$OUT" '"parent_status":"completed"' "--json reports the parent's status"

# A parent with nothing detectable left undone must say so rather than emit an
# empty checklist that looks like a finding.
_B_CLEAN=$(_fu_mk_brief fu-clean-parent "lib/clean.sh")
_fu_mk_entry fu-clean-p completed "2026-10-21T07:00:00Z" "" "$_B_CLEAN"
OUT="$(bash "$_FU_CLI" follow-up-draft fu-clean-p 2>&1)"
_tap_contains "$OUT" "Nothing was detected as left undone" \
  "a parent with no detectable gap says so instead of pretending to one"
_tap_contains "$OUT" "Add the checks this follow-up must pass" \
  "and still leaves the operator a checklist to fill in"

OUT="$(bash "$_FU_CLI" follow-up-draft no-such-entry 2>&1)"
_tap_contains "$OUT" "Entry no-such-entry not found" "follow-up-draft refuses an unknown entry"

# The draft must not have queued anything — that is its whole contract.
_FU_DRAFT_QUEUED="$(ls "$_FU_Q/pending-review"/*.yaml 2>/dev/null | wc -l | tr -d ' ')"
OUT="$(bash "$_FU_CLI" follow-up-draft fu-draft-p 2>&1)"
_tap_eq "$(ls "$_FU_Q/pending-review"/*.yaml 2>/dev/null | wc -l | tr -d ' ')" "$_FU_DRAFT_QUEUED" \
  "follow-up-draft queues nothing"

# ============================================================
# Discarding a parent escalates its follow-ups
# ============================================================
printf "\n# --- discard-entry reaches follow-ups the hold list cannot ---\n"
# fu-draft-p is completed, so nothing holds its follow-up: this is exactly the
# case the union in discard-entry exists for.
_B_DCHILD=$(_fu_mk_brief fu-discard-child "lib/dchild.sh")
_fu_mk_entry fu-disc-c approved "2026-10-21T15:00:00Z" "" "$_B_DCHILD" "fu-draft-p"
_tap_eq "$(_fu_field approved fu-disc-c HELD_BY)" "" \
  "fixture: a follow-up of a COMPLETED parent is not held by anything"

OUT="$(bash "$_FU_CLI" discard-entry fu-draft-p --reason "superseded" 2>&1)"
_tap_contains "$OUT" "Discarded: fu-draft-p" "discard-entry discards the completed parent"
_FU_DISC_ESC="$(grep -l 'queue_entry_id: "fu-disc-c"' "$ADV_SANDBOX/.claude/.automation/escalations"/*.yaml 2>/dev/null | head -1)"
if [ -n "$_FU_DISC_ESC" ]; then
  _tap_pass "the unheld follow-up is escalated anyway"
  _tap_contains "$(cat "$_FU_DISC_ESC")" "parent-discarded" "the escalation is typed parent-discarded"
  _tap_contains "$(cat "$_FU_DISC_ESC")" "was waiting on fu-draft-p" \
    "the message says what the entry was waiting on"
else
  _tap_fail "the unheld follow-up is escalated anyway" "no escalation names fu-disc-c"
  _tap_fail "the escalation is typed parent-discarded" "skipped"
  _tap_fail "the message says what the entry was waiting on" "skipped"
fi

# ============================================================
# runner.sh — the Parent task section in the agent's prompt
# ============================================================
printf "\n# === runner.sh prompt assembly ===\n"
# runner.sh cannot be sourced (it parses argv and runs a daemon loop at load),
# so extract the one function under test, as test-operator-control.sh does.
_RUNNER_SRC="$_ADV_REAL_REPO/.claude/.automation/runner.sh"
_extract_runner_fn() {
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\) \\{" { inside=1 }
    inside { print }
    inside && /^}$/ { exit }
  ' "$_RUNNER_SRC"
}
_RUNNER_FNS="$ADV_SANDBOX/runner-fns-fu.sh"
_extract_runner_fn "_build_parent_task_section" > "$_RUNNER_FNS"
# shellcheck disable=SC1090
source "$_RUNNER_FNS"
if type _build_parent_task_section > /dev/null 2>&1; then
  _tap_pass "extracted _build_parent_task_section from runner.sh"
else
  _tap_fail "extracted _build_parent_task_section from runner.sh" "did runner.sh change shape?"
fi

OUT="$(_build_parent_task_section fu-live-c fu-live-p 2>&1)"
_tap_contains "$OUT" "## Parent task" "the section is headed ## Parent task"
_tap_contains "$OUT" "This entry is a FOLLOW-UP" "it tells the agent what kind of entry it is running"
_tap_contains "$OUT" '- Parent entry: `fu-live-p` (completed)' "it names the parent and its status"
_tap_contains "$OUT" '- Parent branch: `feature/fu-live`' "it names the parent's branch"
_tap_contains "$OUT" "- Parent title: fu-live-parent" "it reads the parent's title from its brief"
_tap_contains "$OUT" "- Its goal was: The fu-live-parent goal sentence." "it reads the parent's goal"
_tap_contains "$OUT" '- Commits it left: `main..feature/fu-live (1 commit(s))`' \
  "it reports the commit range the parent left on that branch"
_tap_contains "$OUT" "escalate rather" "it tells the agent not to silently reverse the parent's work"

# A parent whose branch has landed has no range to report, and that is correct
# rather than broken — the work is in main and the follow-up starts from there.
OUT="$(_build_parent_task_section fu-landed-c fu-landed-p 2>&1)"
_tap_contains "$OUT" '- Parent entry: `fu-landed-p` (completed)' "a landed parent is still described"
_tap_lacks "$OUT" "Commits it left" "a landed parent reports no commit range"

# Not a follow-up, or a parent that no longer exists: silence and a clean exit,
# never a half-written section and never a non-zero return that stops the entry.
OUT="$(_build_parent_task_section fu-ctl "" 2>&1)"
_FU_RC=$?
_tap_eq "$OUT" "" "an entry that is not a follow-up gets no section"
_tap_eq "$_FU_RC" "0" "and the builder still exits clean"
OUT="$(_build_parent_task_section fu-ctl no-such-parent 2>&1)"
_tap_contains "$OUT" "## Parent task" "a pruned parent still produces a section"
_tap_contains "$OUT" "(unknown)" "with its status reported as unknown rather than guessed"

# ============================================================
printf "\n1..%d\n" "$_TAP_NUM"
printf "# passed %d / %d\n" "$_TAP_PASS" "$_TAP_NUM"
if [ "$_TAP_FAIL" -gt 0 ]; then
  printf "# FAILURES:\n"
  printf "$_TAP_FAILURES"
  exit 1
fi
exit 0
