#!/usr/bin/env bash
# TAP test helpers — sandbox factory, assertions, runner infrastructure.
# Pure Bash (no external framework). Bash 3.2 compatible.
#
# Usage (in test files):
#   source "$(dirname "$0")/test-helpers.sh"
#   setup_sandbox
#   # ... tests ...
#   finish_tests

# Strict mode (tests should fail loudly on unexpected errors)
set -euo pipefail

# --- TAP counters ---
_TAP_TEST_NUM=0
_TAP_PASS=0
_TAP_FAIL=0
_TAP_FAILURES=""

# --- All 14 session types (canonical order from Decision 0014) ---
SESSION_TYPES="standard taskgroup hotfix experiment spec-fresh spec-update prototype-napkin prototype-spike prototype-poc advisory-init advisory-reinit audit taskdef-query taskdef-brief"

# --- Sandbox management ---
_SANDBOX_DIR=""

setup_sandbox() {
  _SANDBOX_DIR=$(mktemp -d "${TMPDIR:-/tmp}/phase-test.XXXXXX")
  # Normalize path to canonical form (TMPDIR often has trailing slash,
  # producing //. resolve_path in hooks normalizes via python3 abspath,
  # so REPO_OS_TEST_ROOT must match or is_in_repo prefix checks fail.)
  _SANDBOX_DIR=$(cd "$_SANDBOX_DIR" && pwd)
  trap 'teardown_sandbox' EXIT

  # Scaffold repo structure
  mkdir -p "$_SANDBOX_DIR/.claude/.state"
  mkdir -p "$_SANDBOX_DIR/.claude/hooks"

  # Minimal git init (some helpers check for .git)
  git init -q "$_SANDBOX_DIR" 2>/dev/null || true

  # Create repo-mode file (template mode)
  echo "template" > "$_SANDBOX_DIR/.claude/repo-mode"

  # Create session ID
  echo "test-session-$(date +%s)" > "$_SANDBOX_DIR/.claude/.session-id"

  # Set the testability seam
  export REPO_OS_TEST_ROOT="$_SANDBOX_DIR"

  # Source the helpers (order matters: analytics first, then phase)
  local real_hooks_dir
  real_hooks_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  # shellcheck disable=SC1091
  source "$real_hooks_dir/_analytics-helper.sh"
  # shellcheck disable=SC1091
  source "$real_hooks_dir/_phase-helper.sh"
}

teardown_sandbox() {
  if [ -n "$_SANDBOX_DIR" ] && [ -d "$_SANDBOX_DIR" ]; then
    rm -rf "$_SANDBOX_DIR"
  fi
}

# --- Get sandbox path (for tests that need direct file access) ---
get_sandbox() {
  echo "$_SANDBOX_DIR"
}

# --- Get/set session ID in sandbox ---
get_test_session_id() {
  cat "$_SANDBOX_DIR/.claude/.session-id" 2>/dev/null
}

set_test_session_id() {
  echo "$1" > "$_SANDBOX_DIR/.claude/.session-id"
}

# --- TAP assertion functions ---

# Increment test counter and report pass
_tap_pass() {
  local desc="$1"
  _TAP_TEST_NUM=$((_TAP_TEST_NUM + 1))
  _TAP_PASS=$((_TAP_PASS + 1))
  printf "ok %d - %s\n" "$_TAP_TEST_NUM" "$desc"
}

# Increment test counter and report fail
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

# assert_ok <exit_code> <description>
# Pass if exit_code is 0.
assert_ok() {
  local rc="$1"
  local desc="$2"
  if [ "$rc" -eq 0 ]; then
    _tap_pass "$desc"
  else
    _tap_fail "$desc" "expected exit 0, got $rc"
  fi
}

# assert_fail <exit_code> <description>
# Pass if exit_code is non-zero.
assert_fail() {
  local rc="$1"
  local desc="$2"
  if [ "$rc" -ne 0 ]; then
    _tap_pass "$desc"
  else
    _tap_fail "$desc" "expected non-zero exit, got 0"
  fi
}

# assert_eq <actual> <expected> <description>
# Pass if actual equals expected (string comparison).
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

# assert_neq <actual> <not_expected> <description>
# Pass if actual does NOT equal not_expected.
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

# assert_contains <haystack> <needle> <description>
# Pass if haystack contains needle as a substring.
assert_contains() {
  local haystack="$1"
  local needle="$2"
  local desc="$3"
  case "$haystack" in
    *"$needle"*)
      _tap_pass "$desc"
      ;;
    *)
      _tap_fail "$desc" "'$needle' not found in '$haystack'"
      ;;
  esac
}

# assert_file_contains <file_path> <pattern> <description>
# Pass if file contains the pattern (grep -q).
assert_file_contains() {
  local file="$1"
  local pattern="$2"
  local desc="$3"
  if [ ! -f "$file" ]; then
    _tap_fail "$desc" "file not found: $file"
    return
  fi
  if grep -q "$pattern" "$file" 2>/dev/null; then
    _tap_pass "$desc"
  else
    _tap_fail "$desc" "pattern '$pattern' not found in $file"
  fi
}

# assert_file_not_exists <file_path> <description>
# Pass if file does not exist.
assert_file_not_exists() {
  local file="$1"
  local desc="$2"
  if [ ! -f "$file" ]; then
    _tap_pass "$desc"
  else
    _tap_fail "$desc" "file exists but should not: $file"
  fi
}

# --- Section header (TAP diagnostic) ---
tap_section() {
  local title="$1"
  printf "\n# === %s ===\n" "$title"
}

# --- Finish tests and print summary ---
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

# --- Hook sandbox (extends base sandbox with git + branch setup) ---
# Creates a sandbox with a real git repo on a feature branch, suitable for
# testing hooks that call git rev-parse, git diff, etc.
# Also exports _HOOKS_DIR and sources test-fixtures.sh.
_HOOKS_DIR=""

setup_hook_sandbox() {
  setup_sandbox

  _HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  # Source fixtures
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  source "$script_dir/test-fixtures.sh"

  # Build a minimal git history so hooks see a valid branch
  (
    cd "$_SANDBOX_DIR"
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "init" > README.md
    git add README.md
    git commit -q -m "initial commit"

    # Create feature branch (hooks block edits on main)
    git checkout -q -b feature/test
  )

  # Create a dummy source file for edit/write tests
  mkdir -p "$_SANDBOX_DIR/src"
  echo "module.exports = {}" > "$_SANDBOX_DIR/src/foo.ts"
}

# --- Run a hook script in the sandbox, capturing output ---
# Usage: output=$(run_hook "branch-guard-edit.sh" "$fixture_json")
# Hooks inherit REPO_OS_TEST_ROOT (set by setup_sandbox) and run with
# CWD = sandbox (so git commands use the sandbox repo).
run_hook() {
  local hook="$1"
  local fixture="${2:-\{\}}"
  (cd "$_SANDBOX_DIR" && printf '%s' "$fixture" | bash "$_HOOKS_DIR/$hook" 2>&1)
}

# --- Run a hook and capture exit code ---
# Sets _LAST_RC to the hook's exit code.
# Usage: output=$(run_hook_rc "branch-guard-edit.sh" "$fixture_json"); echo "$_LAST_RC"
_LAST_RC=0
run_hook_rc() {
  local hook="$1"
  local fixture="${2:-\{\}}"
  _LAST_RC=0
  (cd "$_SANDBOX_DIR" && printf '%s' "$fixture" | bash "$_HOOKS_DIR/$hook" 2>&1) || _LAST_RC=$?
}

# --- Switch sandbox to a specific branch ---
# Creates the branch if it doesn't exist.
switch_sandbox_branch() {
  local branch="$1"
  (cd "$_SANDBOX_DIR" && git checkout -q "$branch" 2>/dev/null || git checkout -q -b "$branch" 2>/dev/null)
}

# --- Stage a file in the sandbox for commit-gate tests ---
stage_sandbox_file() {
  local relpath="$1"
  local content="${2:-test content}"
  local dir
  dir=$(dirname "$_SANDBOX_DIR/$relpath")
  mkdir -p "$dir"
  echo "$content" > "$_SANDBOX_DIR/$relpath"
  (cd "$_SANDBOX_DIR" && git add "$relpath")
}

# --- Reset phase state and reinitialize for a new test ---
reset_phase() {
  local stype="${1:-standard}"
  rm -f "$_SANDBOX_DIR/.claude/.state/phase-state"
  init_phase "$stype"
}

# --- Assert a file exists ---
assert_file_exists() {
  local file="$1"
  local desc="$2"
  if [ -f "$file" ]; then
    _tap_pass "$desc"
  else
    _tap_fail "$desc" "file not found: $file"
  fi
}

# --- Self-test block ---
# Validates that assertion functions themselves work correctly.
# Run only when this file is executed directly (not sourced).
_self_test() {
  printf "# Self-test: verifying assertion functions\n"

  # assert_ok with 0
  assert_ok 0 "self-test: assert_ok accepts 0"

  # assert_fail with 1
  assert_fail 1 "self-test: assert_fail accepts non-zero"

  # assert_eq match
  assert_eq "foo" "foo" "self-test: assert_eq matches equal strings"

  # assert_neq mismatch
  assert_neq "foo" "bar" "self-test: assert_neq passes on different strings"

  # assert_contains
  assert_contains "hello world" "world" "self-test: assert_contains finds substring"

  # assert_file_contains (use this script as test data)
  assert_file_contains "${BASH_SOURCE[0]}" "TAP_TEST_NUM" "self-test: assert_file_contains finds pattern in self"

  printf "# Self-test complete (%d passed)\n" "$_TAP_PASS"
}