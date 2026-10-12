#!/usr/bin/env bash
# Branch manager tests — verifies three-case freshness check in branch_manager_setup().
# Uses adversarial sandbox infrastructure for git isolation.
# Bash 3.2 compatible.
#
# Tests (each run under BOTH worktree-isolate modes):
#   BM.1: Branch doesn't exist → created from main
#   BM.2: Branch exists, is ancestor of main (stale) → deleted and recreated
#   BM.3: Branch exists, ahead of main, main is ancestor → selected as-is
#   BM.4: Branch exists, ahead AND behind main (diverged) → rebased onto main
#   BM.5: Rebase conflict → rebase aborted, branch selected as-is
#   BM.6: Standalone (no existing_branch) → new branch from main
#   BM.7: Log messages emitted for Cases 1 and 3
#
# Two modes, because Decision t-0033 changed what this function does:
#   default                     — ensures the branch REF exists, leaves HEAD on
#                                 main (runner.sh then creates a worktree)
#   REPO_OS_WORKTREE_ISOLATE=0  — legacy: checks the branch out
#
# Assertions target `_SETUP_BRANCH`, the documented output variable runner.sh
# consumes, plus an explicit per-mode HEAD assertion. The suite previously
# asserted `git branch --show-current` == the branch, which silently encoded the
# legacy behaviour; after t-0033 it failed every case and stayed red.
#
# Note `branch_manager_setup` is invoked with output redirected to a FILE, not
# captured via $( ). Command substitution runs it in a subshell, where
# _SETUP_BRANCH is set and then discarded — unobservable to the caller.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/sandbox-setup.sh"

# --- TAP counters ---
# NOTE: every BM case body runs in a ( ... ) subshell for git isolation, so
# _tap_pass/_tap_fail increment in a CHILD shell and never reach the parent.
# finish_tests therefore always reported "Tests: 0 Pass: 0 Fail: 0" and the
# script always exited 0 — which is why this suite being fully red after
# Decision t-0033 went unnoticed. Each subshell now ends with
# [ "$_TAP_FAIL" -eq 0 ] so its exit status encodes its own failures, and the
# parent accumulates them in _BM_FAILED.
_BM_FAILED=0
_BM_MODE_LABEL=""
_BM_OUT="${TMPDIR:-/tmp}/bm-output.$$"
_TAP_TEST_NUM=0
_TAP_PASS=0
_TAP_FAIL=0
_TAP_FAILURES=""

_tap_pass() {
  local desc="$1"
  _TAP_TEST_NUM=$((_TAP_TEST_NUM + 1))
  _TAP_PASS=$((_TAP_PASS + 1))
  printf "ok %d - %s\n" "$_TAP_TEST_NUM" "$desc"
}

_tap_fail() {
  local desc="$1"
  local detail="${2:-}"
  _TAP_TEST_NUM=$((_TAP_TEST_NUM + 1))
  _TAP_FAIL=$((_TAP_FAIL + 1))
  printf "not ok %d - %s\n" "$_TAP_TEST_NUM" "$desc"
  if [ -n "$detail" ]; then
    printf "  # %s\n" "$detail"
  fi
  _TAP_FAILURES="${_TAP_FAILURES}  FAIL: ${desc}"
  if [ -n "$detail" ]; then
    _TAP_FAILURES="${_TAP_FAILURES} (${detail})"
  fi
  _TAP_FAILURES="${_TAP_FAILURES}
"
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local desc="$3"
  if [ "$actual" = "$expected" ]; then
    _tap_pass "$desc"
  else
    _tap_fail "$desc" "expected '$expected', got '$actual'"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local desc="$3"
  case "$haystack" in
    *"$needle"*)
      _tap_pass "$desc"
      ;;
    *)
      _tap_fail "$desc" "'$needle' not found in output"
      ;;
  esac
}

assert_neq() {
  local actual="$1"
  local not_expected="$2"
  local desc="$3"
  if [ "$actual" != "$not_expected" ]; then
    _tap_pass "$desc"
  else
    _tap_fail "$desc" "expected not '$not_expected', but got it"
  fi
}

finish_tests() {
  printf "\n# Case groups failed: %d\n" "$_BM_FAILED"
  if [ "$_BM_FAILED" -gt 0 ]; then
    printf "# Re-run with the failing mode to see per-assertion detail.\n"
    return 1
  fi
  printf "# All branch-manager case groups passed (both worktree-isolate modes).\n"
  return 0
}

# --- Helper: set up a fresh sandbox git repo with main branch ---
setup_branch_test() {
  setup_adversarial_sandbox

  # Source the branch manager from sandbox
  # shellcheck disable=SC1091
  source "$ADV_SANDBOX/.claude/.automation/lib/branch-manager.sh"

  # Ensure we're on main with an initial commit
  (
    cd "$ADV_SANDBOX"
    git checkout -q main 2>/dev/null || git checkout -q -b main 2>/dev/null
  )
}

teardown_branch_test() {
  teardown_adversarial_sandbox
}

# --- Assert which branch branch_manager_setup selected, in either mode ---
# The branch SELECTION is mode-independent and is what these tests are really
# about; only whether HEAD moves differs:
#
#   REPO_OS_WORKTREE_ISOLATE=0 (legacy)  — the function checks the branch out,
#                                          so HEAD lands on it.
#   default (Decision t-0033)            — the function only ensures the branch
#                                          REF exists and leaves HEAD on main;
#                                          runner.sh then creates a worktree.
#
# Asserting `git branch --show-current` == the branch, as this suite did before,
# silently encoded the legacy behaviour. After t-0033 made worktree isolation
# the default, all six cases failed with "expected <branch>, got main" and the
# suite has been red ever since — masking any genuine branch-manager regression.
# Arguments:
#   $1 — expected branch name
#   $2 — description prefix
assert_setup_branch() {
  local expected="$1"
  local desc="$2"
  assert_eq "$_SETUP_BRANCH" "$expected" "$desc (_SETUP_BRANCH)"

  local head
  head=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [ "${REPO_OS_WORKTREE_ISOLATE:-1}" = "0" ]; then
    assert_eq "$head" "$expected" "$desc (legacy: HEAD checked out on the branch)"
  else
    assert_eq "$head" "main" "$desc (t-0033: HEAD stays on main, branch ref only)"
    if git rev-parse --verify "$expected" > /dev/null 2>&1; then
      _tap_pass "$desc (t-0033: branch ref exists)"
    else
      _tap_fail "$desc (t-0033: branch ref exists)" "ref '$expected' was not created"
    fi
  fi
}

# --- Does a branch's tree contain these paths? ---
# Mode-independent replacement for working-tree `[ -f ... ]` checks: in the
# default mode HEAD never moves to the branch, so the branch's files are not on
# disk and the tree must be inspected through the ref instead.
# Arguments:
#   $1 — branch name; rest — paths that must all be present
assert_branch_has_files() {
  local branch="$1"
  shift
  local desc_paths="$*"
  local listing missing=""
  listing=$(git ls-tree -r --name-only "$branch" 2>/dev/null || echo "")
  local p
  for p in "$@"; do
    case "
$listing
" in
      *"
$p
"*) ;;
      *) missing="$missing $p" ;;
    esac
  done
  if [ -z "$missing" ]; then
    _tap_pass "BM.4: rebased branch has both main and branch files"
  else
    _tap_fail "BM.4: rebased branch has both main and branch files" "missing on '$branch':$missing (wanted: $desc_paths)"
  fi
}

# --- The BM.1-BM.7 suite, runnable under either worktree-isolate mode ---
# Decision t-0033 made worktree isolation the default, which changed what
# branch_manager_setup does (ref-only, no checkout). Running the suite under
# BOTH settings keeps the legacy path covered while asserting the behaviour
# that actually ships.
run_bm_suite() {
# ============================================================
# BM.1: Branch doesn't exist → created from main
# ============================================================
printf "\n# === BM.1: Branch doesn't exist — created from main ===\n"

setup_branch_test

(
  cd "$ADV_SANDBOX"
  branch_manager_setup "test-brief" "feature/new-branch" > "$_BM_OUT" 2>&1 || true
  output=$(cat "$_BM_OUT")
  assert_setup_branch "feature/new-branch" "BM.1: non-existent branch created from main"

  # Verify it points to same commit as main
  main_sha=$(git rev-parse main)
  branch_sha=$(git rev-parse "$_SETUP_BRANCH")
  assert_eq "$branch_sha" "$main_sha" "BM.1: new branch points to main HEAD"
  [ "$_TAP_FAIL" -eq 0 ]
) || _BM_FAILED=$((_BM_FAILED + 1))

teardown_branch_test

# ============================================================
# BM.2: Branch is ancestor of main (stale) → deleted and recreated
# ============================================================
printf "\n# === BM.2: Stale branch (ancestor of main) — recreated ===\n"

setup_branch_test

(
  cd "$ADV_SANDBOX"

  # Create a branch at current main
  git checkout -q -b feature/stale-branch 2>/dev/null
  stale_sha=$(git rev-parse HEAD)

  # Go back to main and add a commit (main moves forward)
  git checkout -q main 2>/dev/null
  echo "new-content" > newfile.txt
  git add newfile.txt
  git commit -q -m "advance main" 2>/dev/null
  advanced_main_sha=$(git rev-parse main)

  # Now branch_manager_setup should detect stale and recreate
  branch_manager_setup "test-brief" "feature/stale-branch" > "$_BM_OUT" 2>&1 || true
  output=$(cat "$_BM_OUT")
  assert_setup_branch "feature/stale-branch" "BM.2: stale branch name preserved after recreate"

  branch_sha=$(git rev-parse "$_SETUP_BRANCH")
  assert_eq "$branch_sha" "$advanced_main_sha" "BM.2: recreated branch points to current main HEAD"
  assert_neq "$branch_sha" "$stale_sha" "BM.2: recreated branch differs from old stale position"

  assert_contains "$output" "ancestor of main" "BM.2: log message mentions ancestor of main"
  [ "$_TAP_FAIL" -eq 0 ]
) || _BM_FAILED=$((_BM_FAILED + 1))

teardown_branch_test

# ============================================================
# BM.3: Branch ahead of main, main is ancestor → checkout as-is
# ============================================================
printf "\n# === BM.3: Branch ahead of main — checkout as-is ===\n"

setup_branch_test

(
  cd "$ADV_SANDBOX"

  # Create branch with a commit ahead of main
  git checkout -q -b feature/ahead-branch 2>/dev/null
  echo "ahead-content" > ahead.txt
  git add ahead.txt
  git commit -q -m "ahead commit" 2>/dev/null
  ahead_sha=$(git rev-parse HEAD)

  # Go back to main (doesn't advance)
  git checkout -q main 2>/dev/null

  # branch_manager_setup should checkout as-is
  branch_manager_setup "test-brief" "feature/ahead-branch" > "$_BM_OUT" 2>&1 || true
  output=$(cat "$_BM_OUT")
  assert_setup_branch "feature/ahead-branch" "BM.3: ahead branch selected as-is"

  branch_sha=$(git rev-parse "$_SETUP_BRANCH")
  assert_eq "$branch_sha" "$ahead_sha" "BM.3: branch remains at its original commit"
  [ "$_TAP_FAIL" -eq 0 ]
) || _BM_FAILED=$((_BM_FAILED + 1))

teardown_branch_test

# ============================================================
# BM.4: Branch diverged (ahead AND behind main) → rebased
# ============================================================
printf "\n# === BM.4: Diverged branch — rebased onto main ===\n"

setup_branch_test

(
  cd "$ADV_SANDBOX"

  # Create branch with a commit
  git checkout -q -b feature/diverged 2>/dev/null
  echo "branch-content" > branch-file.txt
  git add branch-file.txt
  git commit -q -m "branch commit" 2>/dev/null
  branch_orig_sha=$(git rev-parse HEAD)

  # Go to main and add a different commit (diverge)
  git checkout -q main 2>/dev/null
  echo "main-content" > main-file.txt
  git add main-file.txt
  git commit -q -m "main advance" 2>/dev/null
  main_sha=$(git rev-parse main)

  # branch_manager_setup should rebase
  branch_manager_setup "test-brief" "feature/diverged" > "$_BM_OUT" 2>&1 || true
  output=$(cat "$_BM_OUT")
  assert_setup_branch "feature/diverged" "BM.4: diverged branch selected"

  # After rebase, main should be ancestor of branch
  if git merge-base --is-ancestor main feature/diverged 2>/dev/null; then
    _tap_pass "BM.4: main is ancestor of rebased branch"
  else
    _tap_fail "BM.4: main is ancestor of rebased branch" "main is NOT ancestor after rebase"
  fi

  # Branch should have both files (main-file from rebase, branch-file from branch
  # commit). Checked through the REF, not the working tree: in the default mode
  # HEAD never moves to the branch, so its files are not on disk.
  assert_branch_has_files "feature/diverged" branch-file.txt main-file.txt

  assert_contains "$output" "behind main" "BM.4: log message mentions behind main"
  [ "$_TAP_FAIL" -eq 0 ]
) || _BM_FAILED=$((_BM_FAILED + 1))

teardown_branch_test

# ============================================================
# BM.5: Rebase conflict → aborted, branch checked out as-is
# ============================================================
printf "\n# === BM.5: Rebase conflict — aborted gracefully ===\n"

setup_branch_test

(
  cd "$ADV_SANDBOX"

  # Create branch with a commit that modifies a file
  echo "base" > conflict.txt
  git add conflict.txt
  git commit -q -m "base file" 2>/dev/null

  git checkout -q -b feature/conflict-branch 2>/dev/null
  echo "branch-version" > conflict.txt
  git add conflict.txt
  git commit -q -m "branch modifies conflict.txt" 2>/dev/null
  branch_sha=$(git rev-parse HEAD)

  # Go to main and modify the same file differently (create conflict)
  git checkout -q main 2>/dev/null
  echo "main-version" > conflict.txt
  git add conflict.txt
  git commit -q -m "main modifies conflict.txt" 2>/dev/null

  # branch_manager_setup should attempt rebase, fail, abort, and leave branch as-is
  branch_manager_setup "test-brief" "feature/conflict-branch" > "$_BM_OUT" 2>&1 || true
  output=$(cat "$_BM_OUT")
  assert_setup_branch "feature/conflict-branch" "BM.5: branch selected despite rebase failure"

  # Branch should be at original SHA (rebase aborted)
  current_sha=$(git rev-parse "$_SETUP_BRANCH")
  assert_eq "$current_sha" "$branch_sha" "BM.5: branch at original SHA after aborted rebase"

  assert_contains "$output" "WARNING" "BM.5: warning emitted on rebase failure"
  assert_contains "$output" "aborting rebase" "BM.5: log mentions aborting rebase"
  [ "$_TAP_FAIL" -eq 0 ]
) || _BM_FAILED=$((_BM_FAILED + 1))

teardown_branch_test

# ============================================================
# BM.6: Standalone (no existing_branch) → new branch from main
# ============================================================
printf "\n# === BM.6: Standalone — new branch from main ===\n"

setup_branch_test

(
  cd "$ADV_SANDBOX"

  main_sha=$(git rev-parse main)

  branch_manager_setup "my-brief-id" "" > "$_BM_OUT" 2>&1 || true
  output=$(cat "$_BM_OUT")

  # Branch name should contain the brief ID
  case "$_SETUP_BRANCH" in
    feature/auto-my-brief-id-*)
      _tap_pass "BM.6: standalone branch name contains brief ID"
      ;;
    *)
      _tap_fail "BM.6: standalone branch name contains brief ID" "got '$_SETUP_BRANCH'"
      ;;
  esac

  branch_sha=$(git rev-parse "$_SETUP_BRANCH")
  assert_eq "$branch_sha" "$main_sha" "BM.6: standalone branch points to main HEAD"
  [ "$_TAP_FAIL" -eq 0 ]
) || _BM_FAILED=$((_BM_FAILED + 1))

teardown_branch_test

# ============================================================
# BM.7: Log messages emitted for Cases 1 and 3
# ============================================================
printf "\n# === BM.7: Log message verification ===\n"

# Case 1 log already verified in BM.2 (ancestor of main)
# Case 3 log already verified in BM.4 (behind main)
# Verify Case 2 does NOT emit log messages about staleness

setup_branch_test

(
  cd "$ADV_SANDBOX"

  git checkout -q -b feature/quiet-branch 2>/dev/null
  echo "content" > file.txt
  git add file.txt
  git commit -q -m "quiet branch commit" 2>/dev/null
  git checkout -q main 2>/dev/null

  branch_manager_setup "test-brief" "feature/quiet-branch" > "$_BM_OUT" 2>&1 || true
  output=$(cat "$_BM_OUT")

  # Case 2 should be silent (no ancestor/behind messages)
  case "$output" in
    *"ancestor of main"*|*"behind main"*)
      _tap_fail "BM.7: Case 2 (ahead) produces no staleness log" "got unexpected log: $output"
      ;;
    *)
      _tap_pass "BM.7: Case 2 (ahead) produces no staleness log"
      ;;
  esac
  [ "$_TAP_FAIL" -eq 0 ]
) || _BM_FAILED=$((_BM_FAILED + 1))

teardown_branch_test

}

# ============================================================
# Run the suite under both modes
# ============================================================
for _bm_mode in default legacy; do
  if [ "$_bm_mode" = legacy ]; then
    export REPO_OS_WORKTREE_ISOLATE=0
    _BM_MODE_LABEL="legacy (REPO_OS_WORKTREE_ISOLATE=0)"
  else
    unset REPO_OS_WORKTREE_ISOLATE 2>/dev/null || true
    _BM_MODE_LABEL="default (Decision t-0033 worktree isolation)"
  fi
  printf "\n########################################################\n"
  printf "# MODE: %s\n" "$_BM_MODE_LABEL"
  printf "########################################################\n"
  run_bm_suite
done
unset REPO_OS_WORKTREE_ISOLATE 2>/dev/null || true

# ============================================================
finish_tests
