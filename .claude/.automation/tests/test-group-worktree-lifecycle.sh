#!/usr/bin/env bash
# Task group worktree lifecycle — runner-level integration test (Decision 0054).
#
# Layer 8 (.claude/hooks/tests/layer8-group-worktree.sh) covers the primitives in
# _cleanup-helper.sh in isolation. This test covers the stage this change spans:
# _resolve_group_worktree() in runner.sh, which sits between branch-manager.sh
# and the worktree launch, and must agree with both.
#
# Full lifecycle exercised, in order:
#   brief 1 creates → gitignored state written → brief 2 reuses the same path
#   → brief 2 refuses on a dirty tree → second session blocked by the lock
#   → crashed brief's worktree survives and is reused on restart
#   → parallel and standalone entries still take the per-session path
#   → final seal removes the worktree
#
# Bash 3.2 compatible. Uses real git worktrees in a /tmp sandbox.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/sandbox-setup.sh"

_TAP_NUM=0; _TAP_PASS=0; _TAP_FAIL=0; _TAP_FAILURES=""
_tap_pass() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_PASS=$((_TAP_PASS+1)); printf "ok %d - %s\n" "$_TAP_NUM" "$1"; }
_tap_fail() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_FAIL=$((_TAP_FAIL+1)); printf "not ok %d - %s\n" "$_TAP_NUM" "$1"; [ -n "${2:-}" ] && printf "  # %s\n" "$2"; _TAP_FAILURES="${_TAP_FAILURES}  FAIL: $1\n"; }
_tap_eq() {
  if [ "$1" = "$2" ]; then _tap_pass "$3"; else _tap_fail "$3" "expected '$2', got '$1'"; fi
}

printf "# === Task Group Worktree Lifecycle (Decision 0054) ===\n"

setup_adversarial_sandbox
trap 'teardown_adversarial_sandbox' EXIT

REPO_ROOT="$ADV_SANDBOX"
export REPO_ROOT
AUTOMATION_DIR="$ADV_SANDBOX/.claude/.automation"
export AUTOMATION_DIR

# --- Source the pieces _resolve_group_worktree depends on ---
# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/hooks/_cleanup-helper.sh"
# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/.automation/lib/branch-manager.sh"   # sanitize_branch_name
# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/.automation/lib/cohesion-trigger.sh" # _extract_group_name
# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/.automation/lib/group-worktree-sweep.sh"

# _resolve_group_worktree, _brief_is_sequential_group and
# _write_group_worktree_escalation live in runner.sh, which cannot be sourced
# (it parses argv and runs a daemon loop at load). Extract just those three
# functions — the same technique other runner-level tests would need, and it
# keeps the test honest: it runs the real code, not a restatement of it.
# sandbox-setup.sh copies lib/*.sh and hooks/*.sh but not runner.sh itself, so
# extract from the real repo — which is the code under test in any case.
_RUNNER_SRC="$_ADV_REAL_REPO/.claude/.automation/runner.sh"
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
} > "$_RUNNER_FNS"
# shellcheck disable=SC1090
source "$_RUNNER_FNS"

for _fn in _write_group_worktree_escalation _brief_is_sequential_group _resolve_group_worktree; do
  if type "$_fn" > /dev/null 2>&1; then
    _tap_pass "extracted $_fn from runner.sh"
  else
    _tap_fail "extracted $_fn from runner.sh" "function not found — did runner.sh change shape?"
  fi
done

# --- Fixture: a sequential task group on one branch ---
GROUP="demo-group"
GROUP_BRANCH="feature/tg-demo-group"
BRIEF_DIR=".claude/.automation/briefs"
SEQ_BRIEF="$BRIEF_DIR/brief-1.md"
PAR_BRIEF="$BRIEF_DIR/brief-par.md"

printf '### Task Group\n\nGroup: %s\nBrief: 1 of 3\n' "$GROUP" > "$ADV_SANDBOX/$SEQ_BRIEF"
printf '### Task Group\n\nGroup: %s\nBrief: 1 of 3\nExecution: parallel\n' "par-group" > "$ADV_SANDBOX/$PAR_BRIEF"

git -C "$ADV_SANDBOX" branch "$GROUP_BRANCH" main > /dev/null 2>&1 \
  || git -C "$ADV_SANDBOX" branch "$GROUP_BRANCH" master > /dev/null 2>&1 || true
# sandbox-setup leaves HEAD on feature/test; normalise the base branch name to
# main so the freshness comparisons in _resolve_group_worktree resolve.
_base=$(git -C "$ADV_SANDBOX" rev-parse --abbrev-ref HEAD)
if ! git -C "$ADV_SANDBOX" rev-parse --verify main > /dev/null 2>&1; then
  git -C "$ADV_SANDBOX" branch main "$_base" > /dev/null 2>&1 || true
fi
git -C "$ADV_SANDBOX" rev-parse --verify "$GROUP_BRANCH" > /dev/null 2>&1 \
  || git -C "$ADV_SANDBOX" branch "$GROUP_BRANCH" main > /dev/null 2>&1

WT="$ADV_SANDBOX/.worktrees/tg-$GROUP"

# ============================================================
printf "\n# --- Brief 1: creates the group worktree ---\n"
# ============================================================
_rc=0
_resolve_group_worktree "taskgroup" "$SEQ_BRIEF" "$GROUP_BRANCH" "entry-1" || _rc=$?
_tap_eq "$_rc" "0" "brief 1: _resolve_group_worktree is applicable (rc 0)"
_tap_eq "$_GWT_GROUP" "$GROUP" "brief 1: group name extracted from the brief"
_tap_eq "$_GWT_DIR" "$WT" "brief 1: resolved path is .worktrees/tg-{group}"
_tap_eq "$_GWT_REUSE" "false" "brief 1: reuse is false — nothing exists yet"
_tap_eq "$_GWT_BRANCH" "$GROUP_BRANCH" "brief 1: group branch recorded"

if [ -d "$(_group_worktree_lock_dir "$GROUP")" ]; then
  _tap_pass "brief 1: occupancy lock acquired"
else
  _tap_fail "brief 1: occupancy lock acquired"
fi

# The runner creates the worktree after branch setup; replicate that step.
git -C "$ADV_SANDBOX" worktree add "$WT" "$GROUP_BRANCH" > /dev/null 2>&1
if is_registered_worktree "$WT"; then
  _tap_pass "brief 1: group worktree created and registered"
else
  _tap_fail "brief 1: group worktree created and registered"
fi

# Brief 1 does work: one commit plus gitignored build state.
printf 'ignored-build/\n' > "$WT/.gitignore"
printf 'brief 1 output\n' > "$WT/brief1.txt"
git -C "$WT" add -A > /dev/null 2>&1
git -C "$WT" commit -qm "brief 1 work" > /dev/null 2>&1
mkdir -p "$WT/ignored-build"
printf 'expensive\n' > "$WT/ignored-build/.marker"

# Non-final brief close: lock released, worktree kept (runner behaviour).
release_group_worktree_lock "$GROUP" "$$" "" > /dev/null 2>&1 || true

# ============================================================
printf "\n# --- Brief 2: reuses the same worktree, gitignored state intact ---\n"
# ============================================================
_GWT_REUSE=false
_rc=0
_resolve_group_worktree "taskgroup" "$SEQ_BRIEF" "$GROUP_BRANCH" "entry-2" || _rc=$?
_tap_eq "$_rc" "0" "brief 2: _resolve_group_worktree succeeds"
_tap_eq "$_GWT_REUSE" "true" "brief 2: reuse is TRUE — no git worktree add needed"
_tap_eq "$_GWT_DIR" "$WT" "brief 2: resolves to the SAME path as brief 1"

if [ -f "$WT/ignored-build/.marker" ]; then
  _tap_pass "brief 2: gitignored file from brief 1 still present (the point of reuse)"
else
  _tap_fail "brief 2: gitignored file from brief 1 still present"
fi
if [ -f "$WT/brief1.txt" ]; then
  _tap_pass "brief 2: brief 1's committed work is present on the shared branch"
else
  _tap_fail "brief 2: brief 1's committed work is present on the shared branch"
fi

# ============================================================
printf "\n# --- Second session is blocked by the occupancy lock ---\n"
# ============================================================
# The lock is re-entrant for the same holder pid — deliberately, so a daemon
# whose previous brief leaked the lock does not block itself. A genuine second
# session is a DIFFERENT live process, so hold the lock as one: a live
# background process stands in for the occupying session.
release_group_worktree_lock "$GROUP" "$$" "" > /dev/null 2>&1 || true
sleep 120 &
_OCCUPANT_PID=$!
acquire_group_worktree_lock "$GROUP" "$_OCCUPANT_PID" "sid-occupant" > /dev/null 2>&1 || true

_rc=0
_resolve_group_worktree "taskgroup" "$SEQ_BRIEF" "$GROUP_BRANCH" "entry-2b" 2> /dev/null || _rc=$?
_tap_eq "$_rc" "2" "concurrent session: blocked (rc 2) while another live session holds the lock"
_tap_eq "$_GWT_BLOCK_OUTCOME" "failed:group-worktree-locked" \
  "concurrent session: outcome is failed:group-worktree-locked"

_esc_lock=$(ls "$ADV_SANDBOX/.claude/.automation/escalations"/esc-group-worktree-locked-*.yaml 2>/dev/null | head -1)
if [ -n "$_esc_lock" ]; then
  _tap_pass "concurrent session: escalation written"
  if grep -q "holder_pid: \|holder_pid:" "$_esc_lock"; then
    _tap_pass "concurrent session: escalation names the holder"
  else
    _tap_fail "concurrent session: escalation names the holder"
  fi
else
  _tap_fail "concurrent session: escalation written"
fi
if [ -d "$(_group_worktree_lock_dir "$GROUP")" ]; then
  _tap_pass "concurrent session: the occupant's lock is NOT stolen"
else
  _tap_fail "concurrent session: the occupant's lock is NOT stolen"
fi
rm -f "$ADV_SANDBOX/.claude/.automation/escalations"/esc-group-worktree-locked-*.yaml

# The occupant exits; its lock is now stale and must be broken on next acquire.
kill "$_OCCUPANT_PID" 2>/dev/null || true
wait "$_OCCUPANT_PID" 2>/dev/null || true
_rc=0
_resolve_group_worktree "taskgroup" "$SEQ_BRIEF" "$GROUP_BRANCH" "entry-2c" 2> /dev/null || _rc=$?
_tap_eq "$_rc" "0" "stale lock: a dead occupant's lock is broken, not inherited"
release_group_worktree_lock "$GROUP" "$$" "" > /dev/null 2>&1 || true

# ============================================================
printf "\n# --- Dirty worktree refuses to start the brief ---\n"
# ============================================================
printf 'uncommitted\n' > "$WT/leftover.txt"
_rc=0
_resolve_group_worktree "taskgroup" "$SEQ_BRIEF" "$GROUP_BRANCH" "entry-3" 2> /dev/null || _rc=$?
_tap_eq "$_rc" "2" "dirty tree: brief refuses to start (rc 2)"
_tap_eq "$_GWT_BLOCK_OUTCOME" "failed:group-worktree-dirty" \
  "dirty tree: outcome is failed:group-worktree-dirty"

_esc=$(ls "$ADV_SANDBOX/.claude/.automation/escalations"/esc-dirty-tree-*.yaml 2>/dev/null | head -1)
if [ -n "$_esc" ]; then
  _tap_pass "dirty tree: dirty-tree escalation written"
  if grep -q 'type: "governance-block"' "$_esc"; then
    _tap_pass "dirty tree: escalation uses the existing governance-block type"
  else
    _tap_fail "dirty tree: escalation uses the existing governance-block type"
  fi
  if grep -q 'leftover.txt' "$_esc"; then
    _tap_pass "dirty tree: escalation names the offending file"
  else
    _tap_fail "dirty tree: escalation names the offending file"
  fi
  if grep -q 'severity: "blocking"' "$_esc"; then
    _tap_pass "dirty tree: escalation is blocking, not advisory"
  else
    _tap_fail "dirty tree: escalation is blocking, not advisory"
  fi
else
  _tap_fail "dirty tree: dirty-tree escalation written" "no esc-dirty-tree-*.yaml found"
fi

if [ -d "$(_group_worktree_lock_dir "$GROUP")" ]; then
  _tap_fail "dirty tree: lock released on the refusal path"
else
  _tap_pass "dirty tree: lock released on the refusal path"
fi
if [ -d "$WT" ]; then
  _tap_pass "dirty tree: worktree left in place for the operator to resolve"
else
  _tap_fail "dirty tree: worktree left in place for the operator to resolve"
fi
rm -f "$ADV_SANDBOX/.claude/.automation/escalations"/esc-dirty-tree-*.yaml

# ============================================================
printf "\n# --- Crash recovery: cleaned tree is reused ---\n"
# ============================================================
# The crash left leftover.txt behind; the operator discards it (gitignored
# build state is deliberately kept), then restarts the brief.
rm -f "$WT/leftover.txt"
if [ -f "$WT/ignored-build/.marker" ]; then
  _tap_pass "crash recovery: gitignored state survived the crash"
else
  _tap_fail "crash recovery: gitignored state survived the crash"
fi
_GWT_REUSE=false
_rc=0
_resolve_group_worktree "taskgroup" "$SEQ_BRIEF" "$GROUP_BRANCH" "entry-3-retry" || _rc=$?
_tap_eq "$_rc" "0" "crash recovery: restart succeeds once the tree is clean"
_tap_eq "$_GWT_REUSE" "true" "crash recovery: restart REUSES the surviving worktree"
release_group_worktree_lock "$GROUP" "$$" "" > /dev/null 2>&1 || true

# ============================================================
printf "\n# --- Branch mismatch fails loudly, never recreates ---\n"
# ============================================================
git -C "$ADV_SANDBOX" branch "feature/other" main > /dev/null 2>&1 || true
git -C "$WT" checkout -q "feature/other" 2> /dev/null || true
_rc=0
_resolve_group_worktree "taskgroup" "$SEQ_BRIEF" "$GROUP_BRANCH" "entry-4" 2> /dev/null || _rc=$?
_tap_eq "$_rc" "2" "branch mismatch: blocked (rc 2)"
_tap_eq "$_GWT_BLOCK_OUTCOME" "failed:group-worktree-branch-mismatch" \
  "branch mismatch: outcome is failed:group-worktree-branch-mismatch"
if [ -d "$WT" ]; then
  _tap_pass "branch mismatch: worktree NOT silently recreated"
else
  _tap_fail "branch mismatch: worktree NOT silently recreated"
fi
if ls "$ADV_SANDBOX/.claude/.automation/escalations"/esc-group-worktree-branch-mismatch-*.yaml > /dev/null 2>&1; then
  _tap_pass "branch mismatch: escalation written"
else
  _tap_fail "branch mismatch: escalation written"
fi
rm -f "$ADV_SANDBOX/.claude/.automation/escalations"/esc-group-worktree-branch-mismatch-*.yaml
git -C "$WT" checkout -q "$GROUP_BRANCH" 2> /dev/null || true
release_group_worktree_lock "$GROUP" "$$" "" > /dev/null 2>&1 || true

# ============================================================
printf "\n# --- Not applicable: parallel, standalone, no group, isolate off ---\n"
# ============================================================
_rc=0
_resolve_group_worktree "taskgroup" "$PAR_BRIEF" "feature/tg-par-group" "entry-p" 2> /dev/null || _rc=$?
_tap_eq "$_rc" "1" "parallel group: not applicable (rc 1) — keeps Decision 0032 per-brief worktrees"
_tap_eq "$_GWT_GROUP" "" "parallel group: no group worktree resolved"

_rc=0
_resolve_group_worktree "standard" "$SEQ_BRIEF" "feature/standalone" "entry-s" 2> /dev/null || _rc=$?
_tap_eq "$_rc" "1" "standard session: not applicable (rc 1) — keeps per-session worktree"

_rc=0
_resolve_group_worktree "taskgroup" "" "$GROUP_BRANCH" "entry-nb" 2> /dev/null || _rc=$?
_tap_eq "$_rc" "1" "taskgroup with no brief path: falls back to per-session worktree"

_rc=0
REPO_OS_WORKTREE_ISOLATE=0 _resolve_group_worktree "taskgroup" "$SEQ_BRIEF" "$GROUP_BRANCH" "entry-off" 2> /dev/null || _rc=$?
_tap_eq "$_rc" "1" "REPO_OS_WORKTREE_ISOLATE=0: not applicable (rc 1)"

if [ -d "$(_group_worktree_lock_dir "$GROUP")" ]; then
  _tap_fail "not-applicable paths take no lock"
else
  _tap_pass "not-applicable paths take no lock"
fi

# ============================================================
printf "\n# --- Final brief: seal removes the worktree ---\n"
# ============================================================
mkdir -p "$ADV_SANDBOX/.claude/local"
printf '%s\n' "$GROUP_BRANCH" > "$ADV_SANDBOX/.claude/local/closed-branches"
_swept=$(sweep_stale_group_worktrees)
_tap_eq "$_swept" "1" "final brief: sealed group branch means the worktree is removed"
if [ -d "$WT" ]; then
  _tap_fail "final brief: worktree directory gone"
else
  _tap_pass "final brief: worktree directory gone"
fi
if git -C "$ADV_SANDBOX" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $WT"; then
  _tap_fail "final brief: git worktree list no longer shows it"
else
  _tap_pass "final brief: git worktree list no longer shows it"
fi

# ============================================================
printf "\n# --- Fresh group after removal ---\n"
# ============================================================
# A group whose worktree was removed must be creatable again from scratch.
: > "$ADV_SANDBOX/.claude/local/closed-branches"
_GWT_REUSE=false
_rc=0
_resolve_group_worktree "taskgroup" "$SEQ_BRIEF" "$GROUP_BRANCH" "entry-new" || _rc=$?
_tap_eq "$_rc" "0" "post-removal: group resolves again"
_tap_eq "$_GWT_REUSE" "false" "post-removal: reuse is false — create path, not reuse path"
release_group_worktree_lock "$GROUP" "$$" "" > /dev/null 2>&1 || true

# --- Summary ---
printf "\n1..%d\n" "$_TAP_NUM"
printf "# Tests: %d  Pass: %d  Fail: %d\n" "$_TAP_NUM" "$_TAP_PASS" "$_TAP_FAIL"
if [ "$_TAP_FAIL" -gt 0 ]; then
  printf "\n# Failures:\n%b" "$_TAP_FAILURES"
  exit 1
fi
exit 0
