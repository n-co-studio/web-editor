#!/usr/bin/env bash
# Branch manager tests — verifies three-case freshness check in branch_manager_setup().
# Uses adversarial sandbox infrastructure for git isolation.
# Bash 3.2 compatible.
#
# Tests:
#   BM.1: Branch doesn't exist → created from main
#   BM.2: Branch exists, is ancestor of main (stale) → deleted and recreated
#   BM.3: Branch exists, ahead of main, main is ancestor → checked out as-is
#   BM.4: Branch exists, ahead AND behind main (diverged) → rebased onto main
#   BM.5: Rebase conflict → rebase aborted, branch checked out as-is
#   BM.6: Standalone (no existing_branch) → new branch from main
#   BM.7: Log messages emitted for Cases 1 and 3

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/sandbox-setup.sh"

# --- TAP counters ---
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
  local total=$((_TAP_PASS + _TAP_FAIL))
  printf "\n1..%d\n" "$total"
  printf "# Tests: %d  Pass: %d  Fail: %d\n" "$total" "$_TAP_PASS" "$_TAP_FAIL"
  if [ "$_TAP_FAIL" -gt 0 ]; then
    printf "\n# Failures:\n%s" "$_TAP_FAILURES"
    return 1
  fi
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

# ============================================================
# BM.1: Branch doesn't exist → created from main
# ============================================================
printf "\n# === BM.1: Branch doesn't exist — created from main ===\n"

setup_branch_test

(
  cd "$ADV_SANDBOX"
  output=$(branch_manager_setup "test-brief" "feature/new-branch" 2>&1) || true
  current=$(git branch --show-current 2>/dev/null || git rev-parse --abbrev-ref HEAD)
  assert_eq "$current" "feature/new-branch" "BM.1: non-existent branch created from main"

  # Verify it points to same commit as main
  main_sha=$(git rev-parse main)
  branch_sha=$(git rev-parse HEAD)
  assert_eq "$branch_sha" "$main_sha" "BM.1: new branch points to main HEAD"
)

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
  output=$(branch_manager_setup "test-brief" "feature/stale-branch" 2>&1) || true
  current=$(git branch --show-current 2>/dev/null || git rev-parse --abbrev-ref HEAD)
  assert_eq "$current" "feature/stale-branch" "BM.2: stale branch name preserved after recreate"

  branch_sha=$(git rev-parse HEAD)
  assert_eq "$branch_sha" "$advanced_main_sha" "BM.2: recreated branch points to current main HEAD"
  assert_neq "$branch_sha" "$stale_sha" "BM.2: recreated branch differs from old stale position"

  assert_contains "$output" "ancestor of main" "BM.2: log message mentions ancestor of main"
)

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
  output=$(branch_manager_setup "test-brief" "feature/ahead-branch" 2>&1) || true
  current=$(git branch --show-current 2>/dev/null || git rev-parse --abbrev-ref HEAD)
  assert_eq "$current" "feature/ahead-branch" "BM.3: ahead branch checked out"

  branch_sha=$(git rev-parse HEAD)
  assert_eq "$branch_sha" "$ahead_sha" "BM.3: branch remains at its original commit"
)

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
  output=$(branch_manager_setup "test-brief" "feature/diverged" 2>&1) || true
  current=$(git branch --show-current 2>/dev/null || git rev-parse --abbrev-ref HEAD)
  assert_eq "$current" "feature/diverged" "BM.4: diverged branch checked out"

  # After rebase, main should be ancestor of branch
  if git merge-base --is-ancestor main feature/diverged 2>/dev/null; then
    _tap_pass "BM.4: main is ancestor of rebased branch"
  else
    _tap_fail "BM.4: main is ancestor of rebased branch" "main is NOT ancestor after rebase"
  fi

  # Branch should have both files (main-file from rebase, branch-file from branch commit)
  if [ -f branch-file.txt ] && [ -f main-file.txt ]; then
    _tap_pass "BM.4: rebased branch has both main and branch files"
  else
    _tap_fail "BM.4: rebased branch has both main and branch files" "missing files after rebase"
  fi

  assert_contains "$output" "behind main" "BM.4: log message mentions behind main"
)

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
  output=$(branch_manager_setup "test-brief" "feature/conflict-branch" 2>&1) || true
  current=$(git branch --show-current 2>/dev/null || git rev-parse --abbrev-ref HEAD)
  assert_eq "$current" "feature/conflict-branch" "BM.5: branch checked out despite rebase failure"

  # Branch should be at original SHA (rebase aborted)
  current_sha=$(git rev-parse HEAD)
  assert_eq "$current_sha" "$branch_sha" "BM.5: branch at original SHA after aborted rebase"

  assert_contains "$output" "WARNING" "BM.5: warning emitted on rebase failure"
  assert_contains "$output" "aborting rebase" "BM.5: log mentions aborting rebase"
)

teardown_branch_test

# ============================================================
# BM.6: Standalone (no existing_branch) → new branch from main
# ============================================================
printf "\n# === BM.6: Standalone — new branch from main ===\n"

setup_branch_test

(
  cd "$ADV_SANDBOX"

  main_sha=$(git rev-parse main)

  output=$(branch_manager_setup "my-brief-id" "" 2>&1) || true
  current=$(git branch --show-current 2>/dev/null || git rev-parse --abbrev-ref HEAD)

  # Branch name should contain the brief ID
  case "$current" in
    feature/auto-my-brief-id-*)
      _tap_pass "BM.6: standalone branch name contains brief ID"
      ;;
    *)
      _tap_fail "BM.6: standalone branch name contains brief ID" "got '$current'"
      ;;
  esac

  branch_sha=$(git rev-parse HEAD)
  assert_eq "$branch_sha" "$main_sha" "BM.6: standalone branch points to main HEAD"
)

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

  output=$(branch_manager_setup "test-brief" "feature/quiet-branch" 2>&1) || true

  # Case 2 should be silent (no ancestor/behind messages)
  case "$output" in
    *"ancestor of main"*|*"behind main"*)
      _tap_fail "BM.7: Case 2 (ahead) produces no staleness log" "got unexpected log: $output"
      ;;
    *)
      _tap_pass "BM.7: Case 2 (ahead) produces no staleness log"
      ;;
  esac
)

teardown_branch_test

# ============================================================
finish_tests
