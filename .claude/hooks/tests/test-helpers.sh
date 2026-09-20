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

# --- All 17 session types (canonical order from Decision 0014 + Phase 3b ephemeral) ---
SESSION_TYPES="standard taskgroup taskgroup-merge hotfix experiment editor-live spec-fresh spec-update prototype-napkin prototype-spike prototype-poc advisory-init advisory-reinit audit taskdef-query taskdef-brief ephemeral"

# --- Test Seam Contract ---
# All hooks resolve repo root via _REPO_OS_ROOT (set in _analytics-helper.sh lines 83-92).
# Test isolation uses a dual-guard:
#   1. REPO_OS_TEST_MODE=1  — enables the override path
#   2. _REPO_OS_TEST_ROOT   — redirects _REPO_OS_ROOT to the sandbox
# Path prefix guard: _REPO_OS_TEST_ROOT must start with /tmp/ or /private/tmp/
# to bound the redirect surface to temp directories only. Any other prefix is
# rejected and the real repo root is used instead (warning emitted).
#
# Two independent implementations of this guard exist:
#   - _analytics-helper.sh lines 83-92  (centralized, sourced by all hooks)
#   - session-close-check.sh lines 60-69 (early-exit guard before library sourcing)
# Both must accept the same prefix set. If you change the allowed prefixes,
# update both locations and the TMPDIR normalization below in setup_sandbox().

# --- Sandbox management ---
_SANDBOX_DIR=""

setup_sandbox() {
  # Ensure sandbox paths pass the /tmp/ or /private/tmp/ prefix guard in hooks.
  # macOS sets TMPDIR=/var/folders/... which is rejected by the guard.
  case "${TMPDIR:-/tmp}" in
    /tmp/*|/private/tmp/*|/tmp|/private/tmp) ;;
    *) export TMPDIR=/private/tmp ;;
  esac
  _SANDBOX_DIR=$(mktemp -d "${TMPDIR:-/tmp}/phase-test.XXXXXX")
  # Normalize path to canonical form (TMPDIR often has trailing slash,
  # producing //. resolve_path in hooks normalizes via python3 abspath,
  # so _REPO_OS_TEST_ROOT must match or is_in_repo prefix checks fail.)
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

  # Set the testability seam (dual guard: both vars required)
  export REPO_OS_TEST_MODE=1
  export _REPO_OS_TEST_ROOT="$_SANDBOX_DIR"

  # --- Source-order contract (R11) ---
  # _analytics-helper.sh MUST be sourced AFTER setup_sandbox() sets
  # _REPO_OS_TEST_ROOT. It reads _REPO_OS_TEST_ROOT at source time to
  # set _REPO_OS_ROOT. If sourced before setup_sandbox(), _REPO_OS_ROOT
  # bakes in the real repo path and all sandbox isolation breaks silently.
  # _phase-helper.sh depends on _analytics-helper.sh, so it comes second.
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
# Generic "returned non-zero" assertion. CORRECT for shell FUNCTION return
# codes (has_plan_gate, bundle_valid, ...), where any non-zero means false.
#
# DO NOT use this for a HOOK's exit status. Hooks obey a different contract:
# Claude Code blocks a tool call on exit 2 ONLY, and treats every other
# non-zero as a non-blocking error that lets the call PROCEED. Asserting mere
# non-zero on a hook is how a gate script that CRASHED with exit 1 scored green
# as "blocks the commit", hiding a total fail-open of the commit gate.
# Use assert_hook_blocks() for hook exit codes.
assert_fail() {
  local rc="$1"
  local desc="$2"
  if [ "$rc" -ne 0 ]; then
    _tap_pass "$desc"
  else
    _tap_fail "$desc" "expected non-zero return, got 0"
  fi
}

# assert_hook_blocks <hook_exit_code> <description>
# Pass ONLY on exit 2 — the single status that blocks a tool call.
# Distinguishes "blocked deliberately" from "crashed", which bare non-zero
# cannot do. Use for every hook invocation; use assert_fail() for functions.
assert_hook_blocks() {
  local rc="$1"
  local desc="$2"
  if [ "$rc" -eq 2 ]; then
    _tap_pass "$desc"
  elif [ "$rc" -eq 0 ]; then
    _tap_fail "$desc" "expected blocking exit 2, got 0 — the hook allowed the call"
  else
    _tap_fail "$desc" "expected blocking exit 2, got $rc — a non-2 non-zero does NOT block; the tool call proceeds. This usually means the hook crashed rather than blocking deliberately."
  fi
}

# assert_exit <expected_code> <actual_code> <description>
# Explicit exact-status assertion for cases that are neither 0 nor 2.
assert_exit() {
  local expected="$1"
  local actual="$2"
  local desc="$3"
  if [ "$actual" -eq "$expected" ]; then
    _tap_pass "$desc"
  else
    _tap_fail "$desc" "expected exit $expected, got $actual"
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

  scaffold_sandbox_decisions
}

# --- Scaffold a production-SHAPED decisions directory -----------------------
# The sandbox previously had no docs/ai/decisions/ at all. pre-commit-gates.sh
# guards its entire A1 block with `[ -d "$DECISIONS_DIR" ]`, so that block —
# roughly a quarter of the gate script, including the trailer enforcement and
# the digest staleness path — never executed under test. A crash inside it was
# therefore invisible to this suite.
#
# Shape matters as much as presence: the real repo contains t-*.md decisions
# and ZERO 0*.md files, which is exactly what made A1's
# `ls "$DECISIONS_DIR"/t-*.md "$DECISIONS_DIR"/0*.md` return non-zero and abort
# the script under `set -euo pipefail`. A sandbox that creates both prefixes
# would mask the very defect it should catch. Keep it t-*.md only.
scaffold_sandbox_decisions() {
  local dir="$_SANDBOX_DIR/docs/ai/decisions"
  mkdir -p "$dir"

  local id slug
  for pair in "0001:baseline" "0004:mechanical-enforcement" "0012:file-edit-restrictions"; do
    id="${pair%%:*}"
    slug="${pair##*:}"
    cat > "$dir/t-${id}-${slug}.md" <<EOF
# Decision ${id} — ${slug}

## Status
Accepted

## Triggers

- type: file
- path: \`.claude/hooks/.*\.sh\`
- keywords: \`PreToolUse, PostToolUse, phase-state\`

## Decision

Sandbox fixture decision record.
EOF
  done

  # A1 enforcement sentinel — blocking mode, as in the real repo.
  : > "$dir/.a1-triggers-enforced"

  # Compiled index with a deliberately non-matching digest, and an mtime older
  # than the decision files, so the staleness/recompute path is exercised.
  {
    echo "# A1 trigger index — generated artifact. Do not hand-edit."
    echo "# Regenerate: bash .claude/.automation/lib/rebuild-trigger-index.sh"
    echo "# digest: 0000000000000000000000000000000000000000000000000000000000000000"
    echo '0001|\.claude/hooks/.*\.sh|PreToolUse, PostToolUse, phase-state'
  } > "$dir/.a1-trigger-index"
  touch -t 202001010000 "$dir/.a1-trigger-index"
}

# --- Run a hook script in the sandbox, capturing output ---
# Usage: output=$(run_hook "write-guard.sh" "$fixture_json")
# Hooks inherit _REPO_OS_TEST_ROOT + REPO_OS_TEST_MODE (set by setup_sandbox) and run with
# CWD = sandbox (so git commands use the sandbox repo).
run_hook() {
  local hook="$1"
  local fixture="${2:-\{\}}"
  (cd "$_SANDBOX_DIR" && printf '%s' "$fixture" | bash "$_HOOKS_DIR/$hook" 2>&1)
}

# --- Run a hook and capture exit code ---
# Sets _LAST_RC to the hook's exit code.
# Usage: output=$(run_hook_rc "write-guard.sh" "$fixture_json"); echo "$_LAST_RC"
_LAST_RC=0
_LAST_OUTPUT=""
run_hook_rc() {
  local hook="$1"
  local fixture="${2:-\{\}}"
  _LAST_RC=0
  _LAST_OUTPUT=""
  _LAST_OUTPUT=$( (cd "$_SANDBOX_DIR" && printf '%s' "$fixture" | bash "$_HOOKS_DIR/$hook" 2>&1) ) || _LAST_RC=$?
  printf '%s' "$_LAST_OUTPUT"
}

# assert_blocked <description>
# Pass if _LAST_RC is non-zero OR _LAST_OUTPUT contains JSON decision:block.
# Handles both legacy exit-2 blocks and Phase 2a JSON blocks (exit 0 + JSON).
assert_blocked() {
  local desc="$1"
  # Two legitimate ways to block: exit 2, or exit 0 carrying a JSON
  # decision:block payload (Phase 2a). Any OTHER non-zero is a crash, not a
  # block — the tool call proceeds — so it must fail here. Accepting bare
  # non-zero is what let a fail-open commit gate score green in this suite.
  if [ "$_LAST_RC" -eq 2 ]; then
    _tap_pass "$desc"
  elif [ "$_LAST_RC" -eq 0 ] && printf '%s' "$_LAST_OUTPUT" | grep -q '"decision".*"block"' 2>/dev/null; then
    _tap_pass "$desc"
  elif [ "$_LAST_RC" -eq 0 ]; then
    _tap_fail "$desc" "expected block, got exit 0 with no decision:block payload"
  else
    _tap_fail "$desc" "expected block (exit 2, or exit 0 + decision:block), got exit $_LAST_RC — a non-2 non-zero does NOT block; the tool call proceeds."
  fi
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
# Cleans phase-state and session registry entries to prevent stale-detection
# from blocking re-init within the same test process (same PID appears alive).
reset_phase() {
  local stype="${1:-standard}"
  # Deterministically remove the per-session state dir for the CURRENT session
  # id — not just the cached one. init_phase resolves/writes the per-session dir
  # (wt-sessions/{sid}/phase-state) and its double-init guard returns 1 if that
  # file already exists for the same session. Relying only on
  # _CACHED_SESSION_STATE_DIR left the dir behind whenever the cache was empty
  # (e.g. after upgrade_session_type invalidates it), so the next init_phase hit
  # the guard and aborted the whole layer under set -e. Computing the dir from
  # the live session id makes teardown deterministic and also clears any leaked
  # gate files (plan-approved, cohesion-reviewed, ...) for real per-test isolation.
  local _rp_sid
  _rp_sid=$(get_session_id "$_REPO_OS_ROOT" 2>/dev/null || true)
  if [ -z "$_rp_sid" ]; then
    _rp_sid=$(cat "$_SANDBOX_DIR/.claude/.session-id" 2>/dev/null || echo "")
  fi
  _rp_sid="${_rp_sid//\//_}"
  _rp_sid="${_rp_sid//\.\./_}"
  if [ -n "$_rp_sid" ]; then
    rm -rf "$_SANDBOX_DIR/.claude/.state/wt-sessions/$_rp_sid" 2>/dev/null || true
  fi
  # Also clear any cached dir and the flat (pre-migration) path.
  if [ -n "$_CACHED_SESSION_STATE_DIR" ] && [ -d "$_CACHED_SESSION_STATE_DIR" ]; then
    rm -rf "$_CACHED_SESSION_STATE_DIR" 2>/dev/null || true
  fi
  _CACHED_SESSION_STATE_DIR=""
  rm -f "$_SANDBOX_DIR/.claude/.state/phase-state"
  rm -f "$_SANDBOX_DIR/.claude/.state/sessions"/*.yaml 2>/dev/null || true
  # reset_phase is an intentional re-init between test cases — bypass the
  # double-init guard explicitly (precisely what the override exists for).
  REPO_OS_ALLOW_REINIT=1 init_phase "$stype"
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

# --- Create a fake session registry entry ---
# Usage: create_fake_session "other-sid" "standard" "feature/test" ["99999"] ["2026-01-01T00:00:00Z"]
create_fake_session() {
  local sid="$1"
  local stype="$2"
  local branch="$3"
  local pid="${4:-99999999}"
  local started_at="${5:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  local sessions_dir="$_SANDBOX_DIR/.claude/.state/sessions"
  mkdir -p "$sessions_dir"
  printf 'session_id: %s\nsession_type: %s\nbranch: %s\npid: %s\nstarted_at: %s\n' \
    "$sid" "$stype" "$branch" "$pid" "$started_at" \
    > "$sessions_dir/${sid}.yaml"
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