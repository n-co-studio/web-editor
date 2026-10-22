#!/usr/bin/env bash
# Daemon recovery paths — behavioural tests for three defects found in the
# 2026-10-21 daemon log.
#
#   Defect A  An aborted group-worktree rebase "continued as-is": the group ran on
#             a branch left behind main, and a worktree left mid-rebase wedged the
#             group with no sanctioned exit. Now: a rebase that cannot complete
#             blocks the entry BEFORE launch, names the conflicting files, leaves
#             the tree clean, and `queue-cli.sh reset-group-worktree` is the
#             operator's explicit way out of a wedged worktree.
#   Defect B  The max_deferral_cycles path called queue_block on an entry that
#             queue_defer had already moved to approved/, got
#             "ERROR: Entry ... not found in running/", and `set -e` killed the
#             daemon with the queue lock held. Now: _handle_wo_deferral blocks the
#             entry and its approved siblings, writes one escalation naming the
#             blocking work order, releases the lock on every path, never exits.
#   Defect C  A non-final sequential group brief was logged as merge-idempotency
#             "not merged to main — retrying". Message only; the branch taken is
#             the normal-execution fall-through either way.
#
# Every case here was run against the unfixed code first and FAILED (see the
# session log for the recorded output). Sandbox only — real git repo and real
# worktrees under /tmp; nothing touches the live repo's queue.
#
# Bash 3.2 compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/sandbox-setup.sh"

_TAP_NUM=0; _TAP_PASS=0; _TAP_FAIL=0; _TAP_FAILURES=""
_tap_pass() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_PASS=$((_TAP_PASS+1)); printf "ok %d - %s\n" "$_TAP_NUM" "$1"; }
_tap_fail() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_FAIL=$((_TAP_FAIL+1)); printf "not ok %d - %s\n" "$_TAP_NUM" "$1"; [ -n "${2:-}" ] && printf "  # %s\n" "$2"; _TAP_FAILURES="${_TAP_FAILURES}  FAIL: $1\n"; return 0; }
_tap_eq() {
  if [ "$1" = "$2" ]; then _tap_pass "$3"; else _tap_fail "$3" "expected '$2', got '$1'"; fi
}
# _tap_has <haystack> <needle> <label>
_tap_has() {
  case "$1" in
    *"$2"*) _tap_pass "$3" ;;
    *)      _tap_fail "$3" "expected to find '$2' in: $(printf '%s' "$1" | head -c 300)" ;;
  esac
}
# _tap_lacks <haystack> <needle> <label>
_tap_lacks() {
  case "$1" in
    *"$2"*) _tap_fail "$3" "did not expect '$2' in: $(printf '%s' "$1" | head -c 300)" ;;
    *)      _tap_pass "$3" ;;
  esac
}
_have_fn() { type "$1" > /dev/null 2>&1; }

printf "# === Daemon recovery paths (Defects A / B / C) ===\n"

setup_adversarial_sandbox
_SLEEPER_PID=""
trap '[ -n "$_SLEEPER_PID" ] && kill "$_SLEEPER_PID" 2>/dev/null; teardown_adversarial_sandbox' EXIT

# Stand IN the sandbox. get_main_repo_root() resolves from the cwd's git dir and
# caches the answer; run from a live worktree it would point group worktree paths
# and lock dirs at the LIVE repo instead of the sandbox. Relative brief paths
# (resolved against the cwd) also need the sandbox as cwd.
cd "$ADV_SANDBOX"
_CACHED_MAIN_REPO_ROOT="$ADV_SANDBOX"

REPO_ROOT="$ADV_SANDBOX"
export REPO_ROOT
AUTOMATION_DIR="$ADV_SANDBOX/.claude/.automation"
export AUTOMATION_DIR
CONFIG_FILE="$AUTOMATION_DIR/config.yaml"
export CONFIG_FILE
ESC_DIR="$AUTOMATION_DIR/escalations"

# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/hooks/_cleanup-helper.sh"
# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/.automation/lib/branch-manager.sh"
# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/.automation/lib/cohesion-trigger.sh"
# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/.automation/lib/queue-manager.sh"
# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/.automation/lib/work-order-manager.sh"
# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/.automation/lib/review-log.sh"
# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/.automation/lib/file-lock.sh"

# --- Extract runner functions (runner.sh cannot be sourced) ---
# REPO_OS_TEST_RUNNER_SRC lets the suite be pointed at a different runner.sh
# (e.g. a pre-fix copy) to demonstrate that it fails there.
_RUNNER_SRC="${REPO_OS_TEST_RUNNER_SRC:-$_ADV_REAL_REPO/.claude/.automation/runner.sh}"
_extract_runner_fn() {
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\) \\{" { inside=1 }
    inside { print }
    inside && /^}$/ { exit }
  ' "$_RUNNER_SRC"
}
_RUNNER_FNS="$ADV_SANDBOX/runner-fns.sh"
{
  _extract_runner_fn "_write_group_worktree_escalation"
  _extract_runner_fn "_brief_is_sequential_group"
  _extract_runner_fn "_resolve_group_worktree"
  _extract_runner_fn "_is_final_taskgroup_entry"
  _extract_runner_fn "_handle_wo_deferral"
  _extract_runner_fn "_unmerged_branch_message"
} > "$_RUNNER_FNS"
# shellcheck disable=SC1090
source "$_RUNNER_FNS"

for _fn in _resolve_group_worktree _handle_wo_deferral _unmerged_branch_message; do
  if _have_fn "$_fn"; then
    _tap_pass "extracted $_fn from runner.sh"
  else
    _tap_fail "extracted $_fn from runner.sh" "function not found in $_RUNNER_SRC"
  fi
done

# ============================================================
# Fixture: a repo where main has moved under three diverged branches
# ============================================================
SB="$ADV_SANDBOX"
BRIEF_DIR=".claude/.automation/briefs"
mkdir -p "$SB/$BRIEF_DIR"

if ! git -C "$SB" rev-parse --verify main > /dev/null 2>&1; then
  git -C "$SB" branch main "$(git -C "$SB" rev-list --max-parents=0 HEAD | head -1)" > /dev/null 2>&1
fi

# _main_commit <file> <content> <message> — commit one file onto main.
_main_commit() {
  git -C "$SB" checkout -q main
  printf '%s\n' "$2" > "$SB/$1"
  git -C "$SB" add "$1"
  git -C "$SB" commit -q -m "$3"
  git -C "$SB" checkout -q feature/test
}

# _mk_group <group> <file> — a sequential group on feature/tg-<group>, worktree
# at .worktrees/tg-<group>, one unique commit touching <file>, and its brief.
_mk_group() {
  local g="$1" f="$2"
  local br="feature/tg-$g" wt="$SB/.worktrees/tg-$g"
  {
    printf '## Task Brief: %s fixture\n\n### Task Group\n' "$g"
    printf -- '- **Group:** %s\n' "$g"
    printf -- '- **Brief:** 1 of 3\n'
    printf -- '- **Execution:** sequential\n'
  } > "$SB/$BRIEF_DIR/brief-$g.md"
  git -C "$SB" branch "$br" main > /dev/null 2>&1
  git -C "$SB" worktree add "$wt" "$br" > /dev/null 2>&1
  printf 'group version of %s\n' "$f" > "$wt/$f"
  git -C "$wt" add "$f"
  git -C "$wt" commit -q -m "group work on $f"
}

_rebase_in_progress() {
  local d="$1" p
  p=$(git -C "$d" rev-parse --git-path rebase-merge 2>/dev/null || true)
  case "$p" in /*) ;; *) p="$d/$p" ;; esac
  [ -d "$p" ] && return 0
  p=$(git -C "$d" rev-parse --git-path rebase-apply 2>/dev/null || true)
  case "$p" in /*) ;; *) p="$d/$p" ;; esac
  [ -d "$p" ]
}

_main_commit conflict.txt "base" "base: conflict.txt"
_main_commit wedge.txt "base" "base: wedge.txt"
_main_commit bm.txt "base" "base: bm.txt"

GROUP="conflict-group"
WEDGE="wedge-group"
_mk_group "$GROUP" conflict.txt
_mk_group "$WEDGE" wedge.txt

# A plain branch (no worktree) for branch_manager_setup.
git -C "$SB" branch feature/bm-test main > /dev/null 2>&1
git -C "$SB" checkout -q feature/bm-test
printf 'bm version\n' > "$SB/bm.txt"
git -C "$SB" add bm.txt
git -C "$SB" commit -q -m "bm branch work"
git -C "$SB" checkout -q feature/test

# Now main moves with conflicting edits to all three files.
git -C "$SB" checkout -q main
printf 'main version\n' > "$SB/conflict.txt"
printf 'main version\n' > "$SB/wedge.txt"
printf 'main version\n' > "$SB/bm.txt"
git -C "$SB" add conflict.txt wedge.txt bm.txt
git -C "$SB" commit -q -m "main diverges on all three files"
git -C "$SB" checkout -q feature/test

WT="$SB/.worktrees/tg-$GROUP"
WTW="$SB/.worktrees/tg-$WEDGE"
BR="feature/tg-$GROUP"
BRW="feature/tg-$WEDGE"
BRIEF="$BRIEF_DIR/brief-$GROUP.md"
BRIEF_W="$BRIEF_DIR/brief-$WEDGE.md"
ERRF="$SB/stderr.out"

# ============================================================
printf "\n# --- Defect A: branch_manager_setup rebase conflict ---\n"
# ============================================================
_bm_orig=$(git -C "$SB" rev-parse feature/bm-test)
_bm_rc=0
pushd "$SB" > /dev/null
branch_manager_setup "brief-bm" "feature/bm-test" 2> "$ERRF" || _bm_rc=$?
popd > /dev/null
_bm_err=$(cat "$ERRF")
_tap_eq "$_bm_rc" "3" "A-bm: branch_manager_setup returns 3 when the rebase cannot complete"
_tap_eq "$(git -C "$SB" status --porcelain --untracked-files=no)" "" \
  "A-bm: main working tree is clean after the abort"
if _rebase_in_progress "$SB"; then
  _tap_fail "A-bm: no rebase left in progress"
else
  _tap_pass "A-bm: no rebase left in progress"
fi
_tap_eq "$(git -C "$SB" rev-parse feature/bm-test)" "$_bm_orig" \
  "A-bm: branch ref unchanged by the failed rebase"
_tap_eq "$(git -C "$SB" rev-parse --abbrev-ref HEAD)" "main" \
  "A-bm: main worktree restored to main"
_tap_has "${_BM_REBASE_CONFLICT_FILES:-}" "bm.txt" "A-bm: conflicting file named in _BM_REBASE_CONFLICT_FILES"
_tap_has "$_bm_err" "aborting rebase" "A-bm: the abort is still logged"
git -C "$SB" checkout -q feature/test

# ============================================================
printf "\n# --- Defect A: group worktree, rebase conflict ---\n"
# ============================================================
_orig_head=$(git -C "$WT" rev-parse HEAD)
_rc=0
_resolve_group_worktree "taskgroup" "$BRIEF" "$BR" "entry-conflict-1" 2> "$ERRF" || _rc=$?
_err=$(cat "$ERRF")
_tap_eq "$_rc" "2" "A-1: a conflicting rebase BLOCKS the entry (rc 2) instead of continuing as-is"
_tap_eq "${_GWT_BLOCK_OUTCOME:-}" "failed:group-worktree-rebase-conflict" "A-1: outcome is failed:group-worktree-rebase-conflict"
_tap_eq "$(git -C "$WT" status --porcelain)" "" "A-1: group worktree is clean after the abort (verified in the worktree)"
if _rebase_in_progress "$WT"; then
  _tap_fail "A-1: no rebase left in progress in the group worktree"
else
  _tap_pass "A-1: no rebase left in progress in the group worktree"
fi
_tap_eq "$(git -C "$WT" rev-parse HEAD)" "$_orig_head" "A-1: group branch HEAD is exactly where it was"
_tap_eq "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" "$BR" "A-1: worktree still on the group branch (not detached)"
if [ -d "$(_group_worktree_lock_dir "$GROUP")" ]; then
  _tap_fail "A-1: occupancy lock released on the block path"
else
  _tap_pass "A-1: occupancy lock released on the block path"
fi
_esc=$(ls "$ESC_DIR"/esc-group-worktree-rebase-conflict-*.yaml 2>/dev/null | head -1 || true)
if [ -n "$_esc" ]; then
  _tap_pass "A-1: escalation written"
  _esc_body=$(cat "$_esc")
  _tap_has "$_esc_body" "conflict.txt" "A-1: escalation names the conflicting file"
  _tap_has "$_esc_body" "entry-conflict-1" "A-1: escalation names the queue entry"
  _tap_has "$_esc_body" "rebase main" "A-1: escalation states the manual recovery step"
else
  _tap_fail "A-1: escalation written"
fi
_tap_has "$_err" "conflict.txt" "A-1: stderr names the conflicting file"

# Second attempt without operator action: blocks the same way, still clean.
_rc=0
_resolve_group_worktree "taskgroup" "$BRIEF" "$BR" "entry-conflict-2" 2> /dev/null || _rc=$?
_tap_eq "$_rc" "2" "A-1b: a retry with no operator action blocks again"
_tap_eq "$(git -C "$WT" status --porcelain)" "" "A-1b: tree still clean after the second abort"

printf "\n# --- Defect A: operator resolves by hand, group resumes ---\n"
git -C "$WT" rebase main > /dev/null 2>&1 || true
printf 'resolved by operator\n' > "$WT/conflict.txt"
git -C "$WT" add conflict.txt
GIT_EDITOR=true git -C "$WT" rebase --continue > /dev/null 2>&1 || true
_rc=0
_resolve_group_worktree "taskgroup" "$BRIEF" "$BR" "entry-conflict-3" 2> /dev/null || _rc=$?
_tap_eq "$_rc" "0" "A-2: after a manual rebase the group is launchable (rc 0)"
_tap_eq "${_GWT_REUSE:-}" "true" "A-2: the existing worktree is reused"
release_group_worktree_lock "$GROUP" "$$" "" > /dev/null 2>&1 || true

# ============================================================
printf "\n# --- Defect A: a worktree left mid-rebase is a wedge, not a launch ---\n"
# ============================================================
git -C "$WTW" rebase main > /dev/null 2>&1 || true
printf 'stray work\n' > "$WTW/stray.txt"
_wedge_branch_sha=$(git -C "$SB" rev-parse "$BRW")
if _rebase_in_progress "$WTW"; then
  _tap_pass "A-4: fixture is deliberately wedged (rebase in progress, stray file)"
else
  _tap_fail "A-4: fixture is deliberately wedged" "rebase did not stop on a conflict"
fi
_rc=0
_resolve_group_worktree "taskgroup" "$BRIEF_W" "$BRW" "entry-wedge-1" 2> /dev/null || _rc=$?
_tap_eq "$_rc" "2" "A-4: a wedged worktree blocks the entry (rc 2)"
case "${_GWT_BLOCK_OUTCOME:-}" in
  failed:group-worktree-*) _tap_pass "A-4: outcome is a group-worktree block" ;;
  *) _tap_fail "A-4: outcome is a group-worktree block" "got '${_GWT_BLOCK_OUTCOME:-}'" ;;
esac
if [ -d "$(_group_worktree_lock_dir "$WEDGE")" ]; then
  _tap_fail "A-4: lock released after blocking"
else
  _tap_pass "A-4: lock released after blocking"
fi

# ============================================================
printf "\n# --- Defect C: unmerged-branch message ---\n"
# ============================================================
mkdir -p "$SB/$BRIEF_DIR"
printf '## Task Brief: plain\n\nno task group here\n' > "$SB/$BRIEF_DIR/brief-plain.md"
_WO_C=$(wo_create "group" "feature/tg-c")
_C_SELF=$(queue_enqueue "$BRIEF_DIR/c-self.md" "standard" "false" "false" "" "$_WO_C" "false" 1)
_C_SIB=$(queue_enqueue "$BRIEF_DIR/c-sib.md" "standard" "false" "false" "" "$_WO_C" "false" 2)
queue_approve "$_C_SELF"
queue_approve "$_C_SIB"
if _have_fn _unmerged_branch_message; then
  _m_nonfinal=$(_unmerged_branch_message "$_C_SELF" "feature/tg-c" 2 "$BRIEF" "$_WO_C" 2>&1 || true)
  _tap_has "$_m_nonfinal" "intentionally unmerged" "C-1: non-final sequential group brief says the branch is intentionally unmerged"
  _tap_has "$_m_nonfinal" "final brief" "C-1: message explains that only the final brief merges"
  _tap_lacks "$_m_nonfinal" "retrying" "C-1: non-final brief is NOT described as 'retrying'"
  _tap_has "$_m_nonfinal" "$_C_SELF" "C-1: message carries the entry id"

  _WO_C2=$(wo_create "group" "feature/tg-c2")
  _C_ONLY=$(queue_enqueue "$BRIEF_DIR/c-only.md" "standard" "false" "false" "" "$_WO_C2" "false" 1)
  queue_approve "$_C_ONLY"
  _m_final=$(_unmerged_branch_message "$_C_ONLY" "feature/tg-c2" 2 "$BRIEF" "$_WO_C2" 2>&1 || true)
  _tap_has "$_m_final" "not merged to main — retrying" "C-2: FINAL group brief keeps the original 'retrying' message"
  _tap_lacks "$_m_final" "intentionally unmerged" "C-2: final brief is not told its branch is intentionally unmerged"

  _m_plain=$(_unmerged_branch_message "$_C_ONLY" "feature/auto-x" 2 "$BRIEF_DIR/brief-plain.md" "$_WO_C2" 2>&1 || true)
  _tap_has "$_m_plain" "not merged to main — retrying" "C-3: a non-group entry keeps the original message"

  _m_nowo=$(_unmerged_branch_message "$_C_ONLY" "feature/auto-x" 2 "" "" 2>&1 || true)
  _tap_has "$_m_nowo" "not merged to main — retrying" "C-4: an entry with no brief and no work order keeps the original message"
else
  _tap_fail "C-1..4: _unmerged_branch_message missing — Defect C message still unconditional"
fi

# ============================================================
printf "\n# --- Defect B: failed work order, deferral loop ---\n"
# ============================================================
_q_ids() { ls "$AUTOMATION_DIR/queue/$1" 2>/dev/null | sed 's/\.yaml$//' | tr '\n' ' ' || true; }

# Earlier sections left approved entries behind; they would be dequeued first.
rm -f "$AUTOMATION_DIR/queue/approved"/*.yaml
_WO_B=$(wo_create "group" "feature/tg-b")
_B1=$(queue_enqueue "$BRIEF_DIR/b1.md" "standard" "false" "false" "" "$_WO_B" "false" 1)
_B2=$(queue_enqueue "$BRIEF_DIR/b2.md" "standard" "false" "false" "" "$_WO_B" "false" 2)
_B2B=$(queue_enqueue "$BRIEF_DIR/b2b.md" "standard" "false" "false" "" "$_WO_B" "false" 2)
_B3=$(queue_enqueue "$BRIEF_DIR/b3.md" "standard" "false" "false" "" "" "false" 5)
for _id in "$_B1" "$_B2" "$_B2B" "$_B3"; do queue_approve "$_id"; done
for _id in "$_B1" "$_B2" "$_B2B"; do wo_add_child "$_WO_B" "$_id"; done

# B1 is dequeued first (priority 1) and fails terminally.
_dq=$(queue_dequeue) || true
_tap_eq "$(basename "$_dq" .yaml)" "$_B1" "B-0: fixture — highest-priority entry dequeued first"
queue_fail_terminal "$_B1" "deliberate failure" 2> /dev/null
_wo_state=$(wo_check_completion "$_WO_B" 2>/dev/null || true)
_tap_eq "$_wo_state" "failed" "B-0: fixture — the work order is failed"

# Characterise the original root cause. queue_defer moves the entry to approved/;
# queue_block only accepts running/. This is why the old inline code died.
_dq=$(queue_dequeue) || true
_probe=$(basename "$_dq" .yaml)
queue_defer "$_probe" "probe" > /dev/null
_probe_rc=0
queue_block "$_probe" "probe" 2> /dev/null || _probe_rc=$?
_tap_eq "$_probe_rc" "1" "B-root-cause: queue_block on an already-deferred entry fails (the old daemon-killing call)"
rm -f "$AUTOMATION_DIR/queue/.defer-count-$_probe"

if _have_fn _handle_wo_deferral && _have_fn queue_block_deferred; then
  # Drive the daemon's dequeue -> defer cycle. If _handle_wo_deferral exits the
  # shell (the old failure mode) this test dies here and reports nothing more.
  _cycles=0
  _last_rc=0
  _dequeued_unrelated=""
  while [ "$_cycles" -lt 6 ]; do
    _cycles=$((_cycles + 1))
    acquire_queue_lock
    _dq=$(queue_dequeue) || _dq=""
    release_queue_lock
    [ -n "$_dq" ] || break
    _id=$(basename "$_dq" .yaml)
    if [ "$_id" = "$_B3" ]; then _dequeued_unrelated="$_id"; break; fi
    _last_rc=0
    _handle_wo_deferral "$_id" "$_WO_B" "failed" 2> /dev/null || _last_rc=$?
  done
  _tap_eq "$_last_rc" "0" "B-1: _handle_wo_deferral returns 0 at the cap — the daemon survives"
  _tap_has "$(_q_ids blocked)" "$_B2" "B-2: the deferred entry lands in blocked/"
  _tap_has "$(_q_ids blocked)" "$_B2B" "B-2: its approved sibling in the same work order is blocked too"
  _tap_lacks "$(_q_ids approved)" "$_B2" "B-2: neither is left in approved/ to starve the queue"
  _tap_lacks "$(_q_ids approved)" "$_B2B" "B-2: sibling not left in approved/ either"
  _tap_eq "$(ls "$AUTOMATION_DIR/queue"/.defer-count-* 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "B-3: no .defer-count files left behind"
  _LOCK_HELD=false
  _lock_ok=0
  acquire_queue_lock 2> /dev/null && _lock_ok=1
  release_queue_lock
  _tap_eq "$_lock_ok" "1" "B-4: the queue lock is not left held"
  _tap_eq "$_dequeued_unrelated" "$_B3" "B-5: the unrelated lower-priority entry runs on the next cycle (no starvation)"
  _esc_b=$(ls "$ESC_DIR"/esc-wo-blocked-*.yaml 2>/dev/null | head -1 || true)
  if [ -n "$_esc_b" ]; then
    _tap_eq "$(ls "$ESC_DIR"/esc-wo-blocked-*.yaml 2>/dev/null | wc -l | tr -d ' ')" "1" \
      "B-6: exactly ONE escalation for the work order, not one per sibling"
    _esc_b_body=$(cat "$_esc_b")
    _tap_has "$_esc_b_body" "$_WO_B" "B-6: escalation names the blocking work order"
    _tap_has "$_esc_b_body" "$_B1" "B-6: escalation names the failed entry that blocks it"
    _tap_has "$_esc_b_body" "reopen-wo" "B-6: escalation states the recovery command"
  else
    _tap_fail "B-6: escalation written naming the blocking work order"
  fi

  # Recovery: reopen-wo's own sibling reset must be able to take blocked entries
  # back (pins the claim in the session log that blocked siblings are resumable).
  _blocked_status=$(grep '^[[:space:]]*status:' "$AUTOMATION_DIR/queue/blocked/${_B2}.yaml" 2>/dev/null | head -1 || true)
  _tap_has "$_blocked_status" "blocked" "B-7: blocked sibling records status: blocked"

  # Below the cap: defers, does not block.
  _WO_B2=$(wo_create "group" "feature/tg-b2")
  _D1=$(queue_enqueue "$BRIEF_DIR/d1.md" "standard" "false" "false" "" "$_WO_B2" "false" 1)
  _D2=$(queue_enqueue "$BRIEF_DIR/d2.md" "standard" "false" "false" "" "$_WO_B2" "false" 2)
  queue_approve "$_D1"; queue_approve "$_D2"
  wo_add_child "$_WO_B2" "$_D1"; wo_add_child "$_WO_B2" "$_D2"
  _dq=$(queue_dequeue) || true
  queue_fail_terminal "$_D1" "deliberate failure" 2> /dev/null
  wo_check_completion "$_WO_B2" > /dev/null 2>&1 || true
  _dq=$(queue_dequeue) || true
  _handle_wo_deferral "$_D2" "$_WO_B2" "failed" 2> /dev/null || true
  _tap_has "$(_q_ids approved)" "$_D2" "B-8: first deferral (below the cap) returns the entry to approved/"
  _tap_lacks "$(_q_ids blocked)" "$_D2" "B-8: and does not block it yet"
else
  _tap_fail "B-1..8: _handle_wo_deferral / queue_block_deferred missing — deferral cap still kills the daemon"
fi

# Structural wiring: the caller must use the handler, not the inline queue_block.
if grep -q 'queue_block "\$ENTRY_ID" "max_deferral_cycles' "$_RUNNER_SRC"; then
  _tap_fail "B-9: runner no longer calls queue_block on a deferred (approved/) entry"
else
  _tap_pass "B-9: runner no longer calls queue_block on a deferred (approved/) entry"
fi
if grep -q '_handle_wo_deferral "\$ENTRY_ID"' "$_RUNNER_SRC"; then
  _tap_pass "B-10: runner's deferral guard calls _handle_wo_deferral"
else
  _tap_fail "B-10: runner's deferral guard calls _handle_wo_deferral"
fi

# Structural wiring for Defect A in the launch path.
if grep -qE '^[[:space:]]*branch_manager_setup "\$brief_id" "\$existing_branch" \|\| _bm_rc=\$\?' "$_RUNNER_SRC"; then
  _tap_pass "A-5: _run_single_entry captures branch_manager_setup's return code"
else
  _tap_fail "A-5: _run_single_entry captures branch_manager_setup's return code" \
    "a bare call lets set -e abort the daemon on a non-zero return"
fi
if grep -q 'failed:group-worktree-rebase-conflict' "$_RUNNER_SRC" \
   && grep -qE 'failed:empty-result\|failed:group-worktree-rebase-conflict|failed:group-worktree-rebase-conflict\|' "$_RUNNER_SRC"; then
  _tap_pass "A-6: rebase-conflict outcomes route to the terminal-fail arm (no retries, no breaker)"
else
  _tap_fail "A-6: rebase-conflict outcomes route to the terminal-fail arm (no retries, no breaker)"
fi

# ============================================================
printf "\n# --- reset-group-worktree (queue-cli.sh) ---\n"
# ============================================================
cp "$_ADV_REAL_REPO/.claude/.automation/queue-cli.sh" "$AUTOMATION_DIR/queue-cli.sh"
_CLI="$AUTOMATION_DIR/queue-cli.sh"

_cli() { bash "$_CLI" "$@" < /dev/null 2>&1; }

# Command exists.
_help=$(bash "$_CLI" 2>&1 < /dev/null || true)
_tap_has "$_help" "reset-group-worktree" "R-0: usage lists reset-group-worktree"

# R-1: nothing to reset.
_rc=0
_out=$(_cli reset-group-worktree no-such-group --yes) || _rc=$?
_tap_eq "$_rc" "0" "R-1: no worktree for the group -> exit 0"
_tap_has "$_out" "nothing to reset" "R-1: says there is nothing to reset"

# R-2: a worktree with no work order at all is not a failed group -> refuse.
_rc=0
_out=$(_cli reset-group-worktree "$GROUP" --yes) || _rc=$?
_tap_eq "$_rc" "1" "R-2: refuses when no work order is found for the group"
_tap_eq "$(git -C "$WT" rev-parse HEAD)" "$(git -C "$WT" rev-parse "$BR")" "R-2: worktree untouched"

# R-3: wedged worktree, HEALTHY (open) work order -> refuse, change nothing.
_WO_W=$(wo_create "group" "$BRW")
_W1=$(queue_enqueue "$BRIEF_W" "taskgroup" "false" "false" "$BRW" "$_WO_W" "false" 1)
queue_approve "$_W1"
wo_add_child "$_WO_W" "$_W1"
_rc=0
_out=$(_cli reset-group-worktree "$WEDGE" --yes) || _rc=$?
_tap_eq "$_rc" "1" "R-3: REFUSES on a healthy (open) work order, even with --yes"
_tap_has "$_out" "open" "R-3: names the work order's status as the reason"
if [ -f "$WTW/stray.txt" ] && _rebase_in_progress "$WTW"; then
  _tap_pass "R-3: the stray file and the in-progress rebase are untouched"
else
  _tap_fail "R-3: the stray file and the in-progress rebase are untouched" "the refusal still modified the worktree"
fi

# Fail the work order (clear approved/ leftovers so W1 is the one dequeued).
for _f in "$AUTOMATION_DIR/queue/approved"/*.yaml; do
  [ -f "$_f" ] && [ "$(basename "$_f" .yaml)" != "$_W1" ] && rm -f "$_f"
done
_dq=$(queue_dequeue) || true
queue_fail_terminal "$_W1" "deliberate failure" 2> /dev/null
_ws=$(wo_check_completion "$_WO_W" 2>/dev/null || true)
_tap_eq "$_ws" "failed" "R-4: fixture — work order is failed"

# R-5: failed WO, no confirmation (no tty, no --yes) -> refuse, preview shown.
_rc=0
_out=$(_cli reset-group-worktree "$WEDGE") || _rc=$?
_tap_eq "$_rc" "1" "R-5: declines without --yes when there is no terminal to confirm on"
_tap_has "$_out" "stray.txt" "R-5: preview lists the file it would discard"
_tap_has "$_out" "rebase" "R-5: preview reports the in-progress rebase"
if [ -f "$WTW/stray.txt" ] && _rebase_in_progress "$WTW"; then
  _tap_pass "R-5: nothing was changed by the declined run"
else
  _tap_fail "R-5: nothing was changed by the declined run"
fi

# R-6: a live foreign occupant holds the group lock -> refuse.
sleep 120 &
_SLEEPER_PID=$!
acquire_group_worktree_lock "$WEDGE" "$_SLEEPER_PID" "sid-occupant" > /dev/null 2>&1 || true
_rc=0
_out=$(_cli reset-group-worktree "$WEDGE" --yes) || _rc=$?
_tap_eq "$_rc" "1" "R-6: refuses while a live session occupies the group worktree"
if [ -f "$WTW/stray.txt" ]; then
  _tap_pass "R-6: worktree untouched while occupied"
else
  _tap_fail "R-6: worktree untouched while occupied"
fi
kill "$_SLEEPER_PID" 2>/dev/null || true
_SLEEPER_PID=""
release_group_worktree_lock "$WEDGE" "" "sid-occupant" > /dev/null 2>&1 || true

# R-7: failed WO + --yes -> resets.
_rc=0
_out=$(_cli reset-group-worktree "$WEDGE" --yes) || _rc=$?
_tap_eq "$_rc" "0" "R-7: succeeds on a failed work order with --yes"
_tap_eq "$(git -C "$WTW" status --porcelain)" "" "R-7: worktree is clean afterwards"
if _rebase_in_progress "$WTW"; then
  _tap_fail "R-7: no rebase in progress afterwards"
else
  _tap_pass "R-7: no rebase in progress afterwards"
fi
_tap_eq "$(git -C "$WTW" rev-parse --abbrev-ref HEAD)" "$BRW" "R-7: back on the group branch"
_tap_eq "$(git -C "$SB" rev-parse "$BRW")" "$_wedge_branch_sha" "R-7: the group branch's committed work is untouched"
if [ -f "$WTW/stray.txt" ]; then
  _tap_fail "R-7: the stray file was discarded"
else
  _tap_pass "R-7: the stray file was discarded"
fi
_tap_has "$_out" "reopen-wo" "R-7: output tells the operator the next step"
_tap_has "$_out" "rebase main" "R-7: output tells the operator how to bring the branch up to date"

# R-8: idempotent — a second run on the now-clean worktree is a no-op success.
_rc=0
_out=$(_cli reset-group-worktree "$WEDGE" --yes) || _rc=$?
_tap_eq "$_rc" "0" "R-8: a second run on a clean worktree succeeds"

# R-9: the reset never runs implicitly: the runner never calls it.
# The only non-comment mentions allowed are the operator-facing "recovery:" text
# inside escalation context strings; anything else would be an invocation.
if grep -v '^[[:space:]]*#' "$_RUNNER_SRC" | grep 'reset-group-worktree' | grep -qv 'recovery:'; then
  _tap_fail "R-9: runner.sh never invokes the reset (it is operator-only)"
else
  _tap_pass "R-9: runner.sh never invokes the reset (it is operator-only)"
fi

# ============================================================
printf "\n# === Results: %d passed, %d failed, %d total ===\n" "$_TAP_PASS" "$_TAP_FAIL" "$_TAP_NUM"
if [ "$_TAP_FAIL" -gt 0 ]; then
  printf "%b" "$_TAP_FAILURES"
  exit 1
fi
exit 0
