#!/usr/bin/env bash
# Overlap report tests — verifies lib/overlap-report.sh against a git fixture.
# Bash 3.2 compatible.
#
# Cases (the whole set runs under BOTH conflict-prediction paths):
#   OR.1: two branches touch different hunks of one file  -> shared, no conflict
#   OR.2: two branches touch the same lines               -> conflict_likely
#   OR.3: a branch whose file main changed under it       -> main_changed
#   OR.4: merged and stale branches are excluded
#   OR.5: the fixture repo's HEAD, index and working tree are unchanged
#   OR.6: no scratch worktree is left registered
#   OR.7: the two prediction paths produce identical reports
#   OR.8: queue-cli.sh overlap is wired and stays read-only
#
# Two modes, because conflict prediction has two interchangeable
# implementations and the brief requires them to agree:
#   default                             — git merge-tree --write-tree (git >= 2.38)
#   REPO_OS_OVERLAP_NO_MERGE_TREE=1     — scratch-worktree trial merge
#
# The container image the runner uses (.claude/.automation/Dockerfile, FROM
# ubuntu:22.04) ships git 2.34.1, so the fallback is the ONLY path there. It is
# therefore asserted unconditionally; the merge-tree path is asserted only when
# the capability probe says it exists, so this suite is green on both gits.
#
# Note the report functions are called directly, NOT via $( ) for the build
# step: overlap_report_build populates module globals, and a subshell would
# discard them. Only the render functions are captured.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/overlap-report.sh"

# --- TAP counters ---
# No case body runs in a subshell here, so these increment in the shell that
# finish_tests reads. (test-branch-manager.sh needs subshells for git
# isolation and pays for it with an exit-status dance; this suite does not.)
_TAP_TEST_NUM=0
_TAP_PASS=0
_TAP_FAIL=0
_MODE=""

_tap_pass() {
  _TAP_TEST_NUM=$((_TAP_TEST_NUM + 1))
  _TAP_PASS=$((_TAP_PASS + 1))
  printf "ok %d - [%s] %s\n" "$_TAP_TEST_NUM" "$_MODE" "$1"
}

_tap_fail() {
  _TAP_TEST_NUM=$((_TAP_TEST_NUM + 1))
  _TAP_FAIL=$((_TAP_FAIL + 1))
  printf "not ok %d - [%s] %s\n" "$_TAP_TEST_NUM" "$_MODE" "$1"
  if [ -n "${2:-}" ]; then
    printf "  # %s\n" "$2"
  fi
}

assert_eq() {
  if [ "$1" = "$2" ]; then
    _tap_pass "$3"
  else
    _tap_fail "$3" "expected '$2', got '$1'"
  fi
}

assert_contains() {
  case "$1" in
    *"$2"*) _tap_pass "$3" ;;
    *)      _tap_fail "$3" "'$2' not found in: $1" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) _tap_fail "$3" "'$2' unexpectedly present in: $1" ;;
    *)      _tap_pass "$3" ;;
  esac
}

# --- Fixture -------------------------------------------------------------
_FIX=""
_FIX_BASE=""
_FIX_MERGE_SHA=""

_fixture_destroy() {
  if [ -n "$_FIX" ] && [ -d "$_FIX" ]; then
    rm -rf "$_FIX" 2>/dev/null || true
  fi
}
trap _fixture_destroy EXIT

# Branch $1 off main, rewrite line $3 of file $2 to $4, commit, return to main.
_fx_branch() {
  git -C "$_FIX" checkout -q -b "$1" main
  sed -i.bak "${3}s/.*/$4/" "$_FIX/$2"
  rm -f "$_FIX/$2.bak"
  git -C "$_FIX" commit -q -am "$1"
  git -C "$_FIX" checkout -q main
}

_fixture_create() {
  _FIX=$(mktemp -d "${TMPDIR:-/tmp}/repo-os-overlap-fixture-XXXXXX")
  git -C "$_FIX" init -q
  git -C "$_FIX" config user.email "test@example.com"
  git -C "$_FIX" config user.name "Overlap Test"
  git -C "$_FIX" config commit.gpgsign false

  printf 'L1\nL2\nL3\nL4\nL5\nL6\nL7\nL8\nL9\nL10\n' > "$_FIX/shared.txt"
  printf 'C1\nC2\nC3\nC4\nC5\nC6\nC7\nC8\nC9\nC10\n' > "$_FIX/clash.txt"
  printf 'O1\n' > "$_FIX/other2.txt"
  git -C "$_FIX" add -A
  git -C "$_FIX" commit -q -m "base"
  # `git init -b main` is git 2.28+; renaming afterwards stays within the
  # git 2.5 tooling floor (AI.md).
  git -C "$_FIX" branch -M main
  _FIX_BASE=$(git -C "$_FIX" rev-parse HEAD)

  # OR.1 — different hunks of shared.txt: overlap without conflict.
  _fx_branch feature/alpha shared.txt 1 L1-alpha
  _fx_branch feature/beta shared.txt 10 L10-beta

  # OR.2 — the same line of clash.txt, two ways: overlap with conflict.
  _fx_branch feature/gamma clash.txt 1 C1-gamma
  _fx_branch feature/delta clash.txt 1 C1-delta

  # OR.3 — epsilon and merged both touch other2.txt; merged lands on main, so
  # main moves under epsilon.
  _fx_branch feature/epsilon other2.txt 1 O1-epsilon
  _fx_branch feature/merged other2.txt 1 O1-merged

  # OR.4 — stale: a branch ref left at main that never received a commit.
  git -C "$_FIX" branch feature/stale main

  git -C "$_FIX" merge --no-ff -q -m "merge feature/merged" feature/merged
  _FIX_MERGE_SHA=$(git -C "$_FIX" rev-parse --short HEAD)
}

# --- Find the set label whose branches include $1; empty if none ---
_label_containing() {
  local lbl
  while IFS= read -r lbl; do
    [ -n "$lbl" ] || continue
    if _or_set_branches "$lbl" | grep -qx "$1"; then
      printf '%s' "$lbl"
      return 0
    fi
  done <<EOF
$(_or_set_labels)
EOF
  printf ''
}

# --- Index of branch $1 in the report, or empty ---
_mc_files_for() {
  local i=0
  while [ "$i" -lt "$_OR_N" ]; do
    if [ "${_OR_BRANCH[$i]}" = "$1" ]; then
      printf '%s' "${_OR_MC_FILES[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  printf ''
}

_mc_commit_for() {
  local i=0
  while [ "$i" -lt "$_OR_N" ]; do
    if [ "${_OR_BRANCH[$i]}" = "$1" ]; then
      printf '%s' "${_OR_MC_COMMIT[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  printf ''
}

# --- Volatile fields removed so two runs can be compared byte for byte ---
_normalize_json() {
  sed -e 's/"generated_at":"[^"]*"/"generated_at":"X"/' \
      -e 's/"conflict_method":"[^"]*"/"conflict_method":"X"/'
}

# --- Suite ---------------------------------------------------------------
# Arguments: $1 — mode label; $2 — expected conflict_method, or empty to skip
# Output: the normalized JSON report is written to the file named by $3.
run_or_suite() {
  _MODE="$1"
  local expect_method="$2" json_out="$3"
  local head_before status_before head_after status_after
  local lbl_alpha lbl_gamma branches files state mc_files mc_commit
  local json wt_count touching

  head_before=$(git -C "$_FIX" rev-parse HEAD)
  status_before=$(git -C "$_FIX" status --porcelain)

  # The capability probe caches its answer; clear it so the mode takes effect.
  _OR_HAVE_MERGE_TREE=""

  if ! overlap_report_build "$_FIX" main; then
    _tap_fail "overlap_report_build succeeds" "returned non-zero"
    return 0
  fi
  _tap_pass "overlap_report_build succeeds"

  # --- OR.4: open-branch selection ---
  assert_eq "$_OR_N" "5" "OR.4 five open branches (merged and stale excluded)"
  local all_branches="" i=0
  while [ "$i" -lt "$_OR_N" ]; do
    all_branches="${all_branches}${_OR_BRANCH[$i]} "
    i=$((i + 1))
  done
  assert_not_contains "$all_branches" "feature/merged" "OR.4 merged branch excluded"
  assert_not_contains "$all_branches" "feature/stale" "OR.4 stale branch excluded"
  assert_contains "$all_branches" "feature/epsilon" "OR.4 unmerged branch included"

  # --- OR.1: shared without conflict ---
  lbl_alpha=$(_label_containing "feature/alpha")
  if [ -z "$lbl_alpha" ]; then
    _tap_fail "OR.1 alpha is in a set" "alpha not in any set"
  else
    _tap_pass "OR.1 alpha is in a set"
    branches=$(_or_set_branches "$lbl_alpha" | tr '\n' ' ')
    assert_contains "$branches" "feature/beta" "OR.1 alpha and beta share a set"
    files=$(_or_set_files "$lbl_alpha" | tr '\n' ' ')
    assert_contains "$files" "shared.txt" "OR.1 shared.txt is the shared file"
    state=$(_or_file_state "$lbl_alpha" "shared.txt")
    assert_eq "$state" "shared" "OR.1 different hunks report 'shared'"
  fi

  # --- OR.2: conflict predicted ---
  lbl_gamma=$(_label_containing "feature/gamma")
  if [ -z "$lbl_gamma" ]; then
    _tap_fail "OR.2 gamma is in a set" "gamma not in any set"
  else
    _tap_pass "OR.2 gamma is in a set"
    branches=$(_or_set_branches "$lbl_gamma" | tr '\n' ' ')
    assert_contains "$branches" "feature/delta" "OR.2 gamma and delta share a set"
    state=$(_or_file_state "$lbl_gamma" "clash.txt")
    assert_eq "$state" "conflict_likely" "OR.2 same lines report 'conflict_likely'"
  fi

  # Two independent sets, so a file shared by nobody creates none.
  assert_eq "$(_or_set_labels | grep -c .)" "2" "OR.2 exactly two sets"
  assert_eq "$(_label_containing feature/epsilon)" "" "OR.2 epsilon is in no set"

  # --- OR.3: main changed under a branch ---
  mc_files=$(_mc_files_for "feature/epsilon")
  assert_contains "$mc_files" "other2.txt" "OR.3 other2.txt listed in main_changed"
  mc_commit=$(_mc_commit_for "feature/epsilon")
  if [ -z "$mc_commit" ]; then
    _tap_fail "OR.3 by_commit is resolved" "empty"
  else
    touching=$(git -C "$_FIX" log --format=%h "$_FIX_BASE..main" -- other2.txt)
    assert_contains "$touching" "$mc_commit" "OR.3 by_commit touched other2.txt on main"
  fi
  assert_eq "$(_mc_files_for feature/alpha)" "" "OR.3 untouched branch has no main_changed"

  # --- Conflict path actually used ---
  if [ -n "$expect_method" ]; then
    assert_eq "$_OR_CONFLICT_METHOD" "$expect_method" "conflict prediction used $expect_method"
  fi

  # --- OR.5 / OR.6: the report is read-only ---
  head_after=$(git -C "$_FIX" rev-parse HEAD)
  status_after=$(git -C "$_FIX" status --porcelain)
  assert_eq "$head_after" "$head_before" "OR.5 HEAD unchanged"
  assert_eq "$status_after" "$status_before" "OR.5 working tree and index unchanged"
  wt_count=$(git -C "$_FIX" worktree list | grep -c .)
  assert_eq "$wt_count" "1" "OR.6 no scratch worktree left registered"

  json=$(overlap_report_json)
  assert_contains "$json" '"generated_at"' "JSON carries generated_at"
  assert_contains "$json" '"state":"conflict_likely"' "JSON carries the conflict state"
  printf '%s' "$json" | _normalize_json > "$json_out"
}

# ============================================================
# Run
# ============================================================
_fixture_create

_OR_DEFAULT_JSON="$_FIX/report-default.json"
_OR_FALLBACK_JSON="$_FIX/report-fallback.json"

# Default mode: merge-tree when the probe finds it, otherwise the fallback is
# the only path and asserting a method would be asserting the probe twice.
_OR_HAVE_MERGE_TREE=""
_OR_REPO="$_FIX"
_OR_MAIN="main"
if _or_merge_tree_available; then
  _EXPECT_DEFAULT="merge-tree"
else
  _EXPECT_DEFAULT="worktree"
  printf "# git merge-tree --write-tree unavailable (git %s) — fallback is the only path\n" \
    "$(git --version | sed 's/^git version //')"
fi

unset REPO_OS_OVERLAP_NO_MERGE_TREE 2>/dev/null || true
run_or_suite "merge-tree" "$_EXPECT_DEFAULT" "$_OR_DEFAULT_JSON"

export REPO_OS_OVERLAP_NO_MERGE_TREE=1
run_or_suite "worktree" "worktree" "$_OR_FALLBACK_JSON"
unset REPO_OS_OVERLAP_NO_MERGE_TREE

# --- OR.7: the two paths agree ---
# Only meaningful where both paths exist. On git < 2.38 (e.g. the ubuntu:22.04
# image) the first run already fell back, so the two files are the same path's
# output twice and comparing them would assert nothing while reporting a pass.
# Say so instead of banking a tautology.
_MODE="both"
if [ "$_EXPECT_DEFAULT" = "worktree" ]; then
  printf "# OR.7 skipped: merge-tree unavailable, so only one path exists here\n"
elif diff -q "$_OR_DEFAULT_JSON" "$_OR_FALLBACK_JSON" >/dev/null 2>&1; then
  _tap_pass "OR.7 merge-tree and worktree paths produce identical reports"
else
  _tap_fail "OR.7 merge-tree and worktree paths produce identical reports" \
    "$(diff "$_OR_DEFAULT_JSON" "$_OR_FALLBACK_JSON" | head -20)"
fi

# --- OR.8: the CLI is wired, and polling it mutates nothing ---
# Run against the real repo: `overlap` is read-only by contract, so this is the
# cheapest honest end-to-end check. Assertions stay shape-only so the suite
# does not depend on which branches happen to be open.
_MODE="cli"
_CLI_HEAD=$(git -C "$REPO_ROOT" rev-parse HEAD)
_CLI_STATUS=$(git -C "$REPO_ROOT" status --porcelain)
_CLI_RC=0
_CLI_OUT=$(bash "$REPO_ROOT/.claude/.automation/queue-cli.sh" --json overlap 2>&1) || _CLI_RC=$?
assert_eq "$_CLI_RC" "0" "OR.8 queue-cli.sh --json overlap exits 0"
assert_contains "$_CLI_OUT" '"generated_at"' "OR.8 CLI emits a JSON report"
assert_contains "$_CLI_OUT" '"main_changed"' "OR.8 CLI report has main_changed"
assert_eq "$(git -C "$REPO_ROOT" rev-parse HEAD)" "$_CLI_HEAD" "OR.8 real repo HEAD unchanged"
assert_eq "$(git -C "$REPO_ROOT" status --porcelain)" "$_CLI_STATUS" \
  "OR.8 real repo working tree unchanged"

_CLI_RC=0
_CLI_OUT=$(bash "$REPO_ROOT/.claude/.automation/queue-cli.sh" overlap --branch main 2>&1) || _CLI_RC=$?
assert_eq "$_CLI_RC" "0" "OR.8 --branch filter accepted"
_CLI_RC=0
_CLI_OUT=$(bash "$REPO_ROOT/.claude/.automation/queue-cli.sh" overlap --bogus 2>&1) || _CLI_RC=$?
assert_eq "$_CLI_RC" "1" "OR.8 unknown overlap option rejected"

# A bare `--branch` must be diagnosed, not crash: queue-cli.sh runs under
# `set -u`, where dereferencing the missing value aborts with "unbound
# variable" and no indication of what the caller got wrong.
_CLI_RC=0
_CLI_OUT=$(bash "$REPO_ROOT/.claude/.automation/queue-cli.sh" overlap --branch 2>&1) || _CLI_RC=$?
assert_eq "$_CLI_RC" "1" "OR.8 valueless --branch rejected"
assert_contains "$_CLI_OUT" "--branch requires a value" \
  "OR.8 valueless --branch explains itself"

# ============================================================
printf "\n1..%d\n" "$_TAP_TEST_NUM"
printf "# Tests: %d  Pass: %d  Fail: %d\n" "$_TAP_TEST_NUM" "$_TAP_PASS" "$_TAP_FAIL"
if [ "$_TAP_FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
