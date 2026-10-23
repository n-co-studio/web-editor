#!/usr/bin/env bash
# Pull request close path tests — Decision t-0057 brief 2.
# Exercises lib/pr-manager.sh against a real git fixture (local repo + bare
# origin) and a stubbed `gh`. Bash 3.2 compatible.
#
# Cases:
#   PR.1  every changed file parses (bash -n)
#   PR.2  no Bash 4 constructs in the changed files
#   PR.3  _pr_tpl_sub substitutes every occurrence, multi-line values included
#   PR.4  the brief scrapers read title, goal, scope and verification
#   PR.5  the verification list carries the recorded criteria verdicts
#   PR.6  every pr.* config reading is sanitised to a documented default
#   PR.7  pr_gh_available names which half is missing
#   PR.8  pr_open with no origin remote: close_state ready, entry NOT failed
#   PR.9  pr_open with no gh: branch pushed, close_state ready, open-pr skipped
#   PR.10 pr_open happy path: pushed, PR created, pr.{number,url} recorded
#   PR.11 pr_open adopts an existing open PR instead of opening a second
#   PR.12 pr_refresh maps passing checks onto checks/done + pr_open
#   PR.13 pr_refresh maps a failing check onto checks/failed
#   PR.14 pr_refresh reports failed from an individual row, not the aggregate
#   PR.15 pr_refresh maps CONFLICTING onto conflict + review:merge-conflict
#   PR.16 pr_refresh does NOT treat mergeable: UNKNOWN as a conflict
#   PR.17 pr_refresh maps MERGED onto merged, and syncs local main
#   PR.18 pr_merge is refused on failing checks
#   PR.19 pr_merge is refused on mergeable: UNKNOWN
#   PR.20 pr_merge is refused by the entry-side gate from the wrong close_state
#   PR.21 pr_merge is refused on an unknown merge method
#   PR.22 pr_merge happy path: merged, local main fast-forwarded, state merged
#   PR.23 pr_rerun finds the latest failed run and re-runs its failed jobs
#   PR.24 pr_update_branch routes a rejected update to review:merge-conflict
#   PR.25 the runner and CLI actually call it (structural)
#
# WHAT THIS SUITE DOES NOT COVER, and why:
#
#  - The jq programs inside `gh --jq`. The stub cannot evaluate them — it has
#    no jq — so it returns the tab-delimited lines gh WOULD return and the
#    suite tests pr-manager's mapping of those lines. The programs themselves
#    are only exercisable against real gh, which is not available headlessly
#    (see the session decision on the unrun gh preflight). Treat a change to a
#    jq program as untested by this file.
#  - The runner and CLI wiring BEHAVIOURALLY. runner.sh parses argv and runs a
#    daemon loop at load so it cannot be sourced, and queue-cli.sh dispatches on
#    "$1". PR.25 asserts the call sites structurally instead — enough to catch a
#    pr-manager nothing calls, not enough to catch a call site that passes the
#    wrong entry. The daemon poll in particular has no behavioural coverage.
#  - Sealing. record_closed_branch lives in .claude/hooks/_cleanup-helper.sh and
#    is deliberately NOT sourced here, so PR.17/PR.22 exercise the documented
#    `type`-guard degrade instead. That is the branch an automation session
#    without the hook helpers actually takes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"
AUTO_DIR="$SCRIPT_DIR/.."

# --- TAP counters ---
# No case body runs in a subshell: the functions under test report through
# _PR_* and _QE_* globals, which a subshell would discard.
_TAP_TEST_NUM=0
_TAP_PASS=0
_TAP_FAIL=0

_tap_pass() {
  _TAP_TEST_NUM=$((_TAP_TEST_NUM + 1))
  _TAP_PASS=$((_TAP_PASS + 1))
  printf "ok %d - %s\n" "$_TAP_TEST_NUM" "$1"
}

_tap_fail() {
  _TAP_TEST_NUM=$((_TAP_TEST_NUM + 1))
  _TAP_FAIL=$((_TAP_FAIL + 1))
  printf "not ok %d - %s\n" "$_TAP_TEST_NUM" "$1"
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

# --- Files this brief changed ---
SHIPPED_FILES="
$LIB_DIR/pr-manager.sh
$LIB_DIR/queue-manager.sh
$AUTO_DIR/runner.sh
$AUTO_DIR/queue-cli.sh
"
CHANGED_FILES="$SHIPPED_FILES
$SCRIPT_DIR/test-pr-manager.sh
"

# ========================================================================
# PR.1 — syntax
# ========================================================================
for _f in $CHANGED_FILES; do
  [ -f "$_f" ] || { _tap_fail "[CRITICAL] PR.1 $(basename "$_f") exists" "not found: $_f"; continue; }
  _out=""
  if _out=$(bash -n "$_f" 2>&1); then
    _tap_pass "PR.1 $(basename "$_f") parses"
  else
    _tap_fail "[CRITICAL] PR.1 $(basename "$_f") parses" "$_out"
  fi
done

# ========================================================================
# PR.2 — Bash 3.2 floor (AI.md). Comment lines are stripped first: the
# libraries document the floor by naming the constructs they avoid, and this
# file carries the detector pattern itself.
# ========================================================================
for _f in $SHIPPED_FILES; do
  [ -f "$_f" ] || continue
  _bad=$(grep -nE 'declare -A|local -A|\$\{[A-Za-z_][A-Za-z0-9_]*\^\^|\$\{[A-Za-z_][A-Za-z0-9_]*,,|\bmapfile\b|\breadarray\b|\$BASHPID|\$\{BASHPID' "$_f" \
    | grep -vE '^[0-9]+:[[:space:]]*#') || _bad=""
  if [ -z "$_bad" ]; then
    _tap_pass "PR.2 $(basename "$_f") has no Bash 4 constructs"
  else
    _tap_fail "[HIGH] PR.2 $(basename "$_f") has no Bash 4 constructs" "$(printf '%s' "$_bad" | tr '\n' ' ')"
  fi
done

# --- Fixture -------------------------------------------------------------
_FIX=""

_fixture_destroy() {
  # Capture first, re-assert last: on bash 3.2 the status of the last command
  # in an EXIT trap becomes the shell's exit status, so a guarded `rm ... ||
  # true` would rewrite every failure — including a set -e abort — to 0.
  local _rc=$?
  if [ -n "$_FIX" ] && [ -d "$_FIX" ]; then
    rm -rf "$_FIX" 2>/dev/null || true
  fi
  exit "$_rc"
}
trap _fixture_destroy EXIT

_FIX=$(mktemp -d "${TMPDIR:-/tmp}/repo-os-prmgr-XXXXXX")
mkdir -p "$_FIX/repo/.claude/.automation/queue/completed" \
         "$_FIX/repo/.claude/.automation/queue/running" \
         "$_FIX/repo/.claude/.automation/queue/approved" \
         "$_FIX/repo/.claude/.automation/queue/work-orders" \
         "$_FIX/repo/.claude/.automation/escalations" \
         "$_FIX/repo/.claude/.automation/templates" \
         "$_FIX/repo/.claude/.state/sessions" \
         "$_FIX/repo/docs/ai/governance/criteria-verdicts" \
         "$_FIX/repo/docs/ai/briefs" \
         "$_FIX/bin" \
         "$_FIX/gh"

REPO="$_FIX/repo"
ORIGIN="$_FIX/origin.git"

# The real PR body template, not a copy: a test against its own fixture copy
# would pass while the shipped template was broken.
cp "$AUTO_DIR/templates/pr-body.md" "$REPO/.claude/.automation/templates/pr-body.md"

cat > "$REPO/.claude/.automation/config.yaml" <<'CFG'
runner:
  session_max_turns: 10
pr:
  merge_method: squash
  poll_seconds: 45
  delete_branch: false
CFG

# --- gh stub -------------------------------------------------------------
# Keyed on the first two argv words, with a flag as the second word collapsing
# to the first alone (`gh api -X PUT ...` -> `api`). Each key may have an
# `out-<key>` file printed on stdout and an `rc-<key>` file holding the exit
# code. Every invocation is appended to calls.log so a test can assert that a
# command was NOT run as well as that it was.
cat > "$_FIX/bin/gh" <<'GHSTUB'
#!/usr/bin/env bash
GD="${GH_STUB_DIR:?GH_STUB_DIR unset}"
printf '%s\n' "$*" >> "$GD/calls.log"
_k="${1:-}"
case "${2:-}" in
  ""|-*) ;;
  *) _k="${_k}-${2}" ;;
esac
[ -f "$GD/out-$_k" ] && cat "$GD/out-$_k"
if [ -f "$GD/rc-$_k" ]; then
  exit "$(cat "$GD/rc-$_k")"
fi
exit 0
GHSTUB
chmod +x "$_FIX/bin/gh"
GH_STUB_DIR="$_FIX/gh"
export GH_STUB_DIR
: > "$GH_STUB_DIR/calls.log"

_gh_reset() {
  rm -f "$GH_STUB_DIR"/out-* "$GH_STUB_DIR"/rc-* 2>/dev/null || true
  : > "$GH_STUB_DIR/calls.log"
}
_gh_out() { printf '%s\n' "$2" > "$GH_STUB_DIR/out-$1"; }
_gh_rc()  { printf '%s\n' "$2" > "$GH_STUB_DIR/rc-$1"; }
_gh_calls() { cat "$GH_STUB_DIR/calls.log"; }

# A tab, as a value — the stub's pr-view output is tab-delimited and a literal
# tab inside a heredoc is invisible and easy to convert to spaces by accident.
TAB=$(printf '\t')

# pr view output, assembled from rows so each test states only what it varies.
_gh_pr_view() {
  local state="$1" mergeable="$2" mss="$3" checks="${4:-}"
  {
    printf 'state%s%s\n' "$TAB" "$state"
    printf 'mergeable%s%s\n' "$TAB" "$mergeable"
    printf 'mergeStateStatus%s%s\n' "$TAB" "$mss"
    printf 'url%shttps://github.test/o/r/pull/42\n' "$TAB"
    local row
    for row in $checks; do
      # row is <VERDICT>:<name>
      printf 'check%s%s%s%s\n' "$TAB" "${row%%:*}" "$TAB" "${row#*:}"
    done
  } > "$GH_STUB_DIR/out-pr-view"
}

# --- git fixture ---------------------------------------------------------
# A real local repo and a real bare origin: push, fetch and --ff-only are the
# operations this file exists to check, and a stubbed git would check nothing.
git init --quiet --bare "$ORIGIN"
git init --quiet "$REPO"
git -C "$REPO" config user.email "test@repo-os.invalid"
git -C "$REPO" config user.name "Repo OS Test"
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" symbolic-ref HEAD refs/heads/main
printf 'base\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit --quiet -m "base"
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" push --quiet -u origin main

_new_branch() {
  local br="$1"
  git -C "$REPO" checkout --quiet -b "$br"
  printf '%s\n' "$br" > "$REPO/${br##*/}.txt"
  # Stage ONLY this branch's own file. `git add -A` would commit the fixture
  # itself (the queue, the brief, the PR body template) onto the branch, and
  # the checkout back to main below would then delete all of it from disk —
  # leaving every later case reading a repo with no template and no brief.
  git -C "$REPO" add "${br##*/}.txt"
  git -C "$REPO" commit --quiet -m "work on $br"
  git -C "$REPO" checkout --quiet main
}

# --- library under test --------------------------------------------------
REPO_ROOT="$REPO"
AUTOMATION_DIR="$REPO/.claude/.automation"
CONFIG_FILE="$AUTOMATION_DIR/config.yaml"
CONFIG_LOCAL_FILE=""
export REPO_ROOT AUTOMATION_DIR CONFIG_FILE CONFIG_LOCAL_FILE
PATH="$_FIX/bin:$PATH"
export PATH

# shellcheck disable=SC1091
source "$LIB_DIR/file-lock.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/queue-manager.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/work-order-manager.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/pr-manager.sh"

QDIR="$AUTOMATION_DIR/queue"

# A v1.11.0 entry, written by hand so the fields under test are exactly the
# ones named here and none are acquired by accident from an enqueue helper.
_write_entry() {
  local id="$1" status="$2" branch="$3" state="${4:-}" prnum="${5:-0}" brief="${6:-}"
  local dir="$QDIR/$status"
  mkdir -p "$dir"
  cat > "$dir/${id}.yaml" <<ENTRY
entry:
  id: "$id"
  status: "$status"
  priority: "0"
  session_type: "standard"
  branch: "$branch"
  brief_path: "$brief"
  prompt: ""
  auto_mode: "false"
  solo_mode: "false"
  retry_count: "0"
  max_retries: "3"
  work_order_id: ""
  push_on_complete: "false"
  created_at: "2026-10-01T00:00:00Z"
  updated_at: "2026-10-01T00:00:00Z"
  completed_at: "2026-10-02T00:00:00Z"
  permission_profile: "build"
  reverified: ""
  overlap_files: []
  close_path: "pr"
  close_state: "$state"
  close_steps: []
  merge_hold: false
  pr:
    number: $prnum
    url: ""
ENTRY
  printf '%s' "$dir/${id}.yaml"
}

_steps_of() {
  _load_queue_entry "$1"
  printf '%s' "${_QE_CLOSE_STEPS:-}"
}

# ========================================================================
# PR.3 — _pr_tpl_sub
# ========================================================================
assert_eq "$(_pr_tpl_sub 'a {x} b {x} c' x 'Q')" "a Q b Q c" \
  "PR.3 every occurrence of a key is substituted"
assert_eq "$(_pr_tpl_sub 'a {x} b' y 'Q')" "a {x} b" \
  "PR.3 an unmatched key is left alone"
assert_eq "$(_pr_tpl_sub '[{x}]' x 'one
two')" "[one
two]" "PR.3 a multi-line value is inserted whole"
assert_eq "$(_pr_tpl_sub '{x}' x 'a&b\c|d')" 'a&b\c|d' \
  "PR.3 sed metacharacters in a value need no escaping"
assert_eq "$(_pr_tpl_sub 'a b' x 'Q')" "a b" \
  "PR.3 text with no keys is returned unchanged"

# ========================================================================
# PR.4 / PR.5 — brief scrapers
# ========================================================================
BRIEF="docs/ai/briefs/sample.md"
cat > "$REPO/$BRIEF" <<'BRIEF'
# Pull request path

## Why

Context nobody reads.

## Goal

An entry on close_path pr opens a pull request at close.

## Scope

- `.claude/.automation/lib/pr-manager.sh` (new)
- `.claude/.automation/runner.sh`

## Verification

- [ ] a PR-path entry pushes and opens a PR
- [x] bash -n passes
BRIEF

assert_eq "$(_pr_title "$REPO/$BRIEF" "feature/x" "eid")" "Pull request path" \
  "PR.4 the title is the brief's first level-1 heading"
assert_eq "$(_pr_title "$REPO/missing.md" "feature/x" "eid")" "feature/x" \
  "PR.4 a missing brief falls back to the branch, not a generic string"
assert_eq "$(_pr_title "" "" "eid-7")" "eid-7" \
  "PR.4 with no brief and no branch the entry id is the title"
assert_eq "$(_pr_brief_goal "$REPO/$BRIEF")" \
  "An entry on close_path pr opens a pull request at close." \
  "PR.4 the goal is the first non-empty line under ## Goal"
assert_contains "$(_pr_brief_scope "$REPO/$BRIEF")" "pr-manager.sh" \
  "PR.4 the scope section is copied verbatim"
assert_not_contains "$(_pr_brief_scope "$REPO/$BRIEF")" "Verification" \
  "PR.4 the scope section stops at the next heading"

_V=$(_pr_verification "$REPO/$BRIEF" "")
assert_contains "$_V" "- [ ] a PR-path entry pushes and opens a PR" \
  "PR.4 an unticked checklist item is carried over"
assert_contains "$_V" "- [x] bash -n passes" \
  "PR.4 a ticked checklist item is carried over with its tick"

cat > "$REPO/docs/ai/governance/criteria-verdicts/sid-1.yaml" <<'VERD'
criteria:
  - criterion: "the PR body carries the brief"
    verdict: VERIFIED
  - criterion: "the daemon re-reads an open PR"
    verdict: PARTIAL
VERD
_V5=$(_pr_verification "$REPO/$BRIEF" "sid-1")
assert_contains "$_V5" "VERIFIED" "PR.5 a met criterion is listed with its verdict"
assert_contains "$_V5" "PARTIAL"  "PR.5 an unmet criterion is listed with its verdict"
assert_contains "$_V5" "the daemon re-reads an open PR" \
  "PR.5 the criterion text accompanies the verdict"
assert_contains "$(_pr_verification "$REPO/nope.md" "")" "No verification list" \
  "PR.5 an entry with no brief and no verdicts says so rather than rendering empty"

# ========================================================================
# PR.6 — config sanitising
# ========================================================================
assert_eq "$(_pr_merge_method)" "squash"  "PR.6 merge_method is read from config"
assert_eq "$(_pr_poll_seconds)" "45"      "PR.6 poll_seconds is read from config"
assert_eq "$(_pr_delete_branch)" "false"  "PR.6 delete_branch is read from config"

cat > "$AUTOMATION_DIR/config.yaml" <<'CFG'
pr:
  merge_method: cherry-pick
  poll_seconds: soon
  delete_branch: maybe
CFG
assert_eq "$(_pr_merge_method)" "merge" "PR.6 an unknown merge_method falls back to merge"
assert_eq "$(_pr_poll_seconds)" "120"  "PR.6 a non-numeric poll_seconds falls back to 120"
assert_eq "$(_pr_delete_branch)" "true" "PR.6 a non-boolean delete_branch falls back to true"

cat > "$AUTOMATION_DIR/config.yaml" <<'CFG'
runner:
  session_max_turns: 10
CFG
assert_eq "$(_pr_merge_method)" "merge" "PR.6 an absent pr block falls back to merge"
assert_eq "$(_pr_poll_seconds)" "120"  "PR.6 an absent pr block falls back to 120 seconds"
assert_eq "$(_pr_delete_branch)" "true" "PR.6 an absent pr block falls back to deleting the branch"

# ========================================================================
# PR.7 — pr_gh_available
# ========================================================================
_gh_reset
_gh_rc "auth-status" 1
if pr_gh_available; then
  _tap_fail "PR.7 unauthenticated gh is unavailable" "returned 0"
else
  assert_contains "$_PR_REASON" "not authenticated" \
    "PR.7 an unauthenticated gh names authentication as the remedy"
fi

_gh_reset
if pr_gh_available; then
  _tap_pass "PR.7 an installed, authenticated gh is available"
  assert_eq "$_PR_REASON" "" "PR.7 an available gh leaves no reason behind"
else
  _tap_fail "PR.7 an installed, authenticated gh is available" "$_PR_REASON"
fi

# `gh` absent cannot be staged by removing the stub — the suite's own PATH
# would still find a real gh on a developer machine, and the result would
# differ between that machine and CI. The binary-absent half is asserted on the
# code path instead: command -v is the only existence probe in the file.
_CV=$(grep -c 'command -v gh' "$LIB_DIR/pr-manager.sh") || _CV=0
assert_eq "$_CV" "1" "PR.7 gh existence is probed in exactly one place"

# ========================================================================
# PR.8 — pr_open degrades with no origin remote
# ========================================================================
_gh_reset
_new_branch "feature/no-origin"
E8=$(_write_entry "e8" "completed" "feature/no-origin")
# A second repo with no remote at all, so `remote get-url origin` really fails.
_NOREMOTE="$_FIX/noremote"
git init --quiet "$_NOREMOTE"
_SAVED_ROOT="$REPO_ROOT"
REPO_ROOT="$_NOREMOTE"
pr_open "$E8" && _rc8=0 || _rc8=$?
REPO_ROOT="$_SAVED_ROOT"
assert_eq "${_rc8:-0}" "0" "PR.8 pr_open returns success — a degrade never fails the entry"
_load_queue_entry "$E8"
assert_eq "$(queue_close_state)" "ready" \
  "PR.8 no origin remote leaves close_state ready, not pushed"
assert_contains "$(_steps_of "$E8")" '"step":"push-branch","status":"skipped"' \
  "PR.8 the skipped push is recorded as a step"
assert_contains "$_PR_REASON" "no origin remote" "PR.8 the reason names the missing remote"
assert_eq "$(_gh_calls)" "" "PR.8 gh is never called when there is nothing to open a PR from"

# ========================================================================
# PR.9 — pr_open degrades when gh is unauthenticated
# ========================================================================
_gh_reset
_gh_rc "auth-status" 1
_new_branch "feature/no-gh"
E9=$(_write_entry "e9" "completed" "feature/no-gh")
pr_open "$E9" && _rc9=0 || _rc9=$?
assert_eq "${_rc9:-0}" "0" "PR.9 pr_open returns success with gh unusable"
assert_eq "$(git -C "$REPO" rev-parse --verify --quiet refs/remotes/origin/feature/no-gh > /dev/null 2>&1 && echo yes || echo no)" \
  "yes" "PR.9 the branch reaches origin even though no PR is opened"
_load_queue_entry "$E9"
assert_eq "$(queue_close_state)" "ready" \
  "PR.9 close_state is ready, NOT pushed — pushed means merged-and-pushed"
_S9=$(_steps_of "$E9")
assert_contains "$_S9" '"step":"push-branch","status":"done"' "PR.9 the push is recorded as done"
assert_contains "$_S9" '"step":"open-pr","status":"skipped"' "PR.9 the skipped open is recorded"
assert_contains "$_S9" "not authenticated" "PR.9 the step detail says why gh was unusable"
assert_eq "${_QE_PR_NUMBER:-}" "0" "PR.9 no PR number is recorded when none was opened"

# ========================================================================
# PR.10 — pr_open happy path
# ========================================================================
_gh_reset
_gh_out "pr-list" ""
_gh_out "pr-create" "https://github.test/o/r/pull/42"
_new_branch "feature/open-ok"
E10=$(_write_entry "e10" "completed" "feature/open-ok" "" 0 "$BRIEF")
pr_open "$E10"
_load_queue_entry "$E10"
assert_eq "$(queue_close_state)" "pr_open" "PR.10 a successful open records close_state pr_open"
assert_eq "${_QE_PR_NUMBER:-}" "42" "PR.10 the PR number is recorded on the entry"
assert_eq "${_QE_PR_URL:-}" "https://github.test/o/r/pull/42" "PR.10 the PR url is recorded"
_S10=$(_steps_of "$E10")
assert_contains "$_S10" '"step":"push-branch","status":"done"' "PR.10 the push is recorded"
assert_contains "$_S10" '"step":"open-pr","status":"done"'     "PR.10 the open is recorded"
_C10=$(_gh_calls)
assert_contains "$_C10" "pr create --base main --head feature/open-ok" \
  "PR.10 the PR is opened against main from the entry's branch"
assert_contains "$_C10" "--title Pull request path" \
  "PR.10 the title comes from the brief's heading"
assert_contains "$_C10" "--body-file" "PR.10 the body is passed as a file, not an argv string"

# The body itself, rendered through the shipped template.
_SID10=""
_B10=$(_pr_body "e10" "feature/open-ok" "$REPO/$BRIEF" "" "" "$_SID10")
assert_contains "$_B10" "An entry on close_path pr opens a pull request at close." \
  "PR.10 the body opens with the brief's goal"
assert_contains "$_B10" "## Verification" "PR.10 the body carries a Verification section"
assert_contains "$_B10" "- [ ] a PR-path entry pushes and opens a PR" \
  "PR.10 the body carries the brief's verification list"
assert_contains "$_B10" "e10" "PR.10 the body carries the queue entry id"
assert_contains "$_B10" "did not run" \
  "PR.10 an empty reverified renders as did-not-run, not as a pass"
assert_not_contains "$_B10" "{goal}" "PR.10 no template placeholder survives rendering"
assert_not_contains "$_B10" "{entry_id}" "PR.10 the provenance placeholders are all substituted"

# ========================================================================
# PR.11 — an existing open PR is adopted, not duplicated
# ========================================================================
_gh_reset
_gh_out "pr-list" "7 https://github.test/o/r/pull/7"
_new_branch "feature/adopt"
E11=$(_write_entry "e11" "completed" "feature/adopt")
pr_open "$E11"
_load_queue_entry "$E11"
assert_eq "${_QE_PR_NUMBER:-}" "7" "PR.11 the existing PR number is adopted"
assert_eq "$(queue_close_state)" "pr_open" "PR.11 adopting reaches pr_open"
assert_not_contains "$(_gh_calls)" "pr create" "PR.11 no second PR is created"
assert_contains "$(_steps_of "$E11")" "adopted existing #7" "PR.11 the step says it adopted"

# A failed list read must NOT create: a duplicate PR costs a human two review
# threads, so the unreadable case fails closed.
_gh_reset
_gh_rc "pr-list" 1
_new_branch "feature/adopt-blind"
E11B=$(_write_entry "e11b" "completed" "feature/adopt-blind")
pr_open "$E11B"
assert_not_contains "$(_gh_calls)" "pr create" \
  "PR.11 an unreadable pr list refuses to create rather than risking a duplicate"
_load_queue_entry "$E11B"
assert_eq "$(queue_close_state)" "ready" "PR.11 the refused open stays retryable at ready"

# ========================================================================
# PR.12 / PR.13 / PR.14 — check mapping
# ========================================================================
_gh_reset
_gh_pr_view "OPEN" "MERGEABLE" "CLEAN" "SUCCESS:Gate_Conformance SUCCESS:Tests"
E12=$(_write_entry "e12" "completed" "feature/open-ok" "pr_open" 42)
pr_refresh "$E12"
assert_eq "$_PR_CHECKS" "passed" "PR.12 all-SUCCESS rows classify as passed"
assert_contains "$(_steps_of "$E12")" '"step":"checks","status":"done"' \
  "PR.12 passing checks record a done checks step"
_load_queue_entry "$E12"
assert_eq "$(queue_close_state)" "pr_open" "PR.12 a passing refresh leaves the entry at pr_open"

_gh_reset
_gh_pr_view "OPEN" "MERGEABLE" "BLOCKED" "SUCCESS:Tests FAILURE:Gate_Conformance"
E13=$(_write_entry "e13" "completed" "feature/open-ok" "pr_open" 42)
pr_refresh "$E13"
assert_eq "$_PR_CHECKS" "failed" "PR.13 one FAILURE row makes the whole rollup failed"
assert_contains "$_PR_CHECK_DETAIL" "Gate_Conformance" \
  "PR.13 the detail names the check that failed"
assert_contains "$(_steps_of "$E13")" '"step":"checks","status":"failed"' \
  "PR.13 a failing check records a failed checks step"

_gh_reset
_gh_pr_view "OPEN" "MERGEABLE" "CLEAN" "SUCCESS:A IN_PROGRESS:B"
E13B=$(_write_entry "e13b" "completed" "feature/open-ok" "pr_open" 42)
pr_refresh "$E13B"
assert_eq "$_PR_CHECKS" "pending" "PR.13 an unfinished run makes the rollup pending"
assert_contains "$(_steps_of "$E13B")" '"step":"checks","status":"running"' \
  "PR.13 pending checks record a running checks step"

_gh_reset
_gh_pr_view "OPEN" "MERGEABLE" "CLEAN" ""
E13C=$(_write_entry "e13c" "completed" "feature/open-ok" "pr_open" 42)
pr_refresh "$E13C"
assert_eq "$_PR_CHECKS" "none" "PR.13 no check rows classify as none, not as passed"
assert_contains "$(_steps_of "$E13C")" '"step":"checks","status":"skipped"' \
  "PR.13 a PR with no checks records a skipped step saying so"

# gh#14253: the aggregate rollup state can read SUCCESS while an individual
# check run carries a FAILURE conclusion. pr-manager reads rows only, so a
# payload whose aggregate disagrees with its rows must still report failed.
_gh_reset
{
  printf 'state%sOPEN\n' "$TAB"
  printf 'mergeable%sMERGEABLE\n' "$TAB"
  printf 'mergeStateStatus%sCLEAN\n' "$TAB"
  printf 'rollupState%sSUCCESS\n' "$TAB"
  printf 'url%shttps://github.test/o/r/pull/42\n' "$TAB"
  printf 'check%sFAILURE%sGate_Conformance\n' "$TAB" "$TAB"
} > "$GH_STUB_DIR/out-pr-view"
E14=$(_write_entry "e14" "completed" "feature/open-ok" "pr_open" 42)
pr_refresh "$E14"
assert_eq "$_PR_CHECKS" "failed" \
  "PR.14 a failing row beats an aggregate claiming SUCCESS (gh#14253)"

# ========================================================================
# PR.15 / PR.16 — conflict routing, and UNKNOWN is not a conflict
# ========================================================================
_gh_reset
_gh_pr_view "OPEN" "CONFLICTING" "DIRTY" "SUCCESS:Tests"
E15=$(_write_entry "e15" "completed" "feature/open-ok" "pr_open" 42)
pr_refresh "$E15"
_load_queue_entry "$E15"
assert_eq "$(queue_close_state)" "conflict" "PR.15 CONFLICTING records close_state conflict"
assert_eq "$_PR_OUTCOME" "review:merge-conflict" \
  "PR.15 the caller is handed the review:merge-conflict outcome"
assert_contains "$(_steps_of "$E15")" '"step":"merge-pr","status":"failed"' \
  "PR.15 the conflict is recorded as a failed merge-pr step"
_ESC="$AUTOMATION_DIR/escalations/${_PR_ESCALATION_ID}.yaml"
if [ -f "$_ESC" ]; then
  _tap_pass "PR.15 an escalation file is written"
  _EB=$(cat "$_ESC")
  assert_contains "$_EB" 'source: "pr"' "PR.15 the escalation says it came from the pr path"
  assert_contains "$_EB" 'queue_entry_id: "e15"' "PR.15 the escalation names the entry"
  assert_contains "$_EB" 'resolved: false' "PR.15 the escalation is unresolved"
  assert_contains "$_EB" "DIRTY" "PR.15 the escalation carries gh's mergeStateStatus"
  assert_contains "$_EB" "update-branch e15" "PR.15 the escalation gives the remedy command"
  assert_not_contains "$_EB" "conflict_files:" \
    "PR.15 no conflicting-file list is claimed — this path never ran a merge"
else
  _tap_fail "PR.15 an escalation file is written" "missing: $_ESC"
fi

_gh_reset
_gh_pr_view "OPEN" "UNKNOWN" "UNKNOWN" "SUCCESS:Tests"
E16=$(_write_entry "e16" "completed" "feature/open-ok" "pr_open" 42)
pr_refresh "$E16"
_load_queue_entry "$E16"
assert_eq "$(queue_close_state)" "pr_open" \
  "PR.16 mergeable UNKNOWN leaves the entry at pr_open (gh#9583 — it is transient)"
assert_eq "$_PR_OUTCOME" "" "PR.16 UNKNOWN does not hand the caller a conflict outcome"

# ========================================================================
# PR.17 — a PR merged on GitHub is landed locally
# ========================================================================
_gh_reset
_new_branch "feature/landed"
# Put the branch's commit on origin's main, so the local fast-forward is real.
git -C "$REPO" push --quiet origin "feature/landed:main"
_MAIN_BEFORE=$(git -C "$REPO" rev-parse HEAD)
_gh_pr_view "MERGED" "MERGEABLE" "CLEAN" "SUCCESS:Tests"
E17=$(_write_entry "e17" "completed" "feature/landed" "pr_open" 42)
pr_refresh "$E17"
_load_queue_entry "$E17"
assert_eq "$(queue_close_state)" "merged" "PR.17 a MERGED PR records close_state merged"
_S17=$(_steps_of "$E17")
assert_contains "$_S17" '"step":"merge-pr","status":"done"' "PR.17 the merge is recorded"
assert_contains "$_S17" '"step":"push","status":"done"'     "PR.17 the local main sync is recorded"
assert_contains "$_S17" "fast-forwarded" "PR.17 the step says main was fast-forwarded"
if [ "$(git -C "$REPO" rev-parse HEAD)" != "$_MAIN_BEFORE" ]; then
  _tap_pass "PR.17 local main actually advanced"
else
  _tap_fail "PR.17 local main actually advanced" "HEAD unchanged at $_MAIN_BEFORE"
fi
assert_contains "$_S17" '"step":"push-branch","status":"skipped"' \
  "PR.17 without the hook helpers loaded, sealing degrades to a skipped step"
assert_contains "$_S17" "closed-branches" "PR.17 the degrade says how to seal by hand"

# ========================================================================
# PR.18 / PR.19 / PR.20 / PR.21 — pr_merge refusals
# ========================================================================
_gh_reset
_gh_pr_view "OPEN" "MERGEABLE" "BLOCKED" "FAILURE:Gate_Conformance"
E18=$(_write_entry "e18" "completed" "feature/open-ok" "pr_open" 42)
if pr_merge "$E18"; then
  _tap_fail "PR.18 pr_merge is refused on failing checks" "returned 0"
else
  assert_contains "$_PR_REASON" "checks are failing" "PR.18 the refusal names the failing checks"
  assert_not_contains "$(_gh_calls)" "pr merge" "PR.18 gh pr merge is never called"
fi
_load_queue_entry "$E18"
assert_eq "$(queue_close_state)" "pr_open" "PR.18 a refused merge does not move the entry"

_gh_reset
_gh_pr_view "OPEN" "UNKNOWN" "UNKNOWN" "SUCCESS:Tests"
E19=$(_write_entry "e19" "completed" "feature/open-ok" "pr_open" 42)
if pr_merge "$E19"; then
  _tap_fail "PR.19 pr_merge is refused on mergeable UNKNOWN" "returned 0"
else
  assert_contains "$_PR_REASON" "UNKNOWN" "PR.19 the refusal reports the unknown mergeability"
  assert_eq "$_PR_OUTCOME" "" "PR.19 an UNKNOWN refusal is not escalated as a conflict"
  assert_not_contains "$(_gh_calls)" "pr merge" "PR.19 gh pr merge is never called"
fi

_gh_reset
_gh_pr_view "OPEN" "MERGEABLE" "CLEAN" "SUCCESS:Tests"
E20=$(_write_entry "e20" "completed" "feature/open-ok" "ready" 42)
if pr_merge "$E20"; then
  _tap_fail "PR.20 pr_merge is refused from close_state ready" "returned 0"
else
  assert_contains "$_PR_REASON" "close_state is ready" \
    "PR.20 the entry-side gate refuses a state that is not pr_open"
  assert_eq "$(_gh_calls)" "" "PR.20 gh is not called at all when the entry-side gate refuses"
fi

E20B=$(_write_entry "e20b" "running" "feature/open-ok" "pr_open" 42)
_gh_reset
_gh_pr_view "OPEN" "MERGEABLE" "CLEAN" "SUCCESS:Tests"
if pr_merge "$E20B"; then
  _tap_fail "PR.20 pr_merge is refused on an entry that is not completed" "returned 0"
else
  assert_contains "$_PR_REASON" "not completed" "PR.20 the refusal names the unfinished session"
fi

_gh_reset
E21=$(_write_entry "e21" "completed" "feature/open-ok" "pr_open" 42)
if pr_merge "$E21" "cherry-pick"; then
  _tap_fail "PR.21 pr_merge is refused on an unknown method" "returned 0"
else
  assert_contains "$_PR_REASON" "merge, squash or rebase" "PR.21 the refusal lists the valid methods"
  assert_eq "$(_gh_calls)" "" "PR.21 a bad method is rejected before any gh call"
fi

# ========================================================================
# PR.22 — pr_merge happy path
# ========================================================================
_gh_reset
_new_branch "feature/merge-ok"
git -C "$REPO" push --quiet origin "feature/merge-ok:main"
_MAIN_BEFORE22=$(git -C "$REPO" rev-parse HEAD)
_gh_pr_view "OPEN" "MERGEABLE" "CLEAN" "SUCCESS:Gate_Conformance"
E22=$(_write_entry "e22" "completed" "feature/merge-ok" "pr_open" 42)
if pr_merge "$E22" "squash"; then
  _tap_pass "PR.22 pr_merge succeeds when both gates pass"
else
  _tap_fail "PR.22 pr_merge succeeds when both gates pass" "$_PR_REASON"
fi
_C22=$(_gh_calls)
assert_contains "$_C22" "pr merge 42 --squash" "PR.22 the requested method is passed to gh"
assert_contains "$_C22" "--delete-branch" \
  "PR.22 the remote branch is deleted when delete_branch is on (the default)"
_load_queue_entry "$E22"
assert_eq "$(queue_close_state)" "merged" "PR.22 a successful merge records close_state merged"
_S22=$(_steps_of "$E22")
assert_contains "$_S22" '"step":"merge-pr","status":"running"' "PR.22 the in-flight merge is recorded"
assert_contains "$_S22" '"step":"merge-pr","status":"done"'    "PR.22 the finished merge is recorded"
if [ "$(git -C "$REPO" rev-parse HEAD)" != "$_MAIN_BEFORE22" ]; then
  _tap_pass "PR.22 local main was synced after the merge"
else
  _tap_fail "PR.22 local main was synced after the merge" "HEAD unchanged"
fi

# A gh pr merge that fails leaves the entry retryable at pr_open, not conflict.
_gh_reset
_gh_pr_view "OPEN" "MERGEABLE" "CLEAN" "SUCCESS:Tests"
_gh_rc "pr-merge" 1
E22B=$(_write_entry "e22b" "completed" "feature/open-ok" "pr_open" 42)
if pr_merge "$E22B"; then
  _tap_fail "PR.22 a failed gh pr merge returns failure" "returned 0"
else
  _tap_pass "PR.22 a failed gh pr merge returns failure"
fi
_load_queue_entry "$E22B"
assert_eq "$(queue_close_state)" "pr_open" \
  "PR.22 a failed merge returns the entry to pr_open so it can be retried"
assert_contains "$(_steps_of "$E22B")" '"step":"merge-pr","status":"failed"' \
  "PR.22 the failed merge is recorded as a step"

# ========================================================================
# PR.23 — pr_rerun
# ========================================================================
_gh_reset
_gh_out "run-list" "9911"
E23=$(_write_entry "e23" "completed" "feature/open-ok" "pr_open" 42)
if pr_rerun "$E23"; then
  _tap_pass "PR.23 pr_rerun succeeds when a failed run exists"
else
  _tap_fail "PR.23 pr_rerun succeeds when a failed run exists" "$_PR_REASON"
fi
_C23=$(_gh_calls)
assert_contains "$_C23" "run list --branch feature/open-ok --status failure" \
  "PR.23 the latest failed run on the entry's branch is looked up"
assert_contains "$_C23" "run rerun 9911 --failed" "PR.23 only the failed jobs are re-run"
assert_contains "$(_steps_of "$E23")" '"step":"checks","status":"running"' \
  "PR.23 the re-run is recorded as a running checks step"

_gh_reset
_gh_out "run-list" ""
E23B=$(_write_entry "e23b" "completed" "feature/open-ok" "pr_open" 42)
if pr_rerun "$E23B"; then
  _tap_fail "PR.23 pr_rerun refuses when there is no failed run" "returned 0"
else
  assert_contains "$_PR_REASON" "no failed workflow run" \
    "PR.23 the refusal says there was nothing to re-run"
  assert_not_contains "$(_gh_calls)" "run rerun" "PR.23 nothing is re-run"
fi

# ========================================================================
# PR.24 — pr_update_branch
# ========================================================================
_gh_reset
E24=$(_write_entry "e24" "completed" "feature/open-ok" "pr_open" 42)
if pr_update_branch "$E24"; then
  _tap_pass "PR.24 a successful update-branch returns success"
else
  _tap_fail "PR.24 a successful update-branch returns success" "$_PR_REASON"
fi
assert_contains "$(_gh_calls)" "pulls/42/update-branch" "PR.24 the update-branch API is called"
assert_contains "$(_steps_of "$E24")" '"step":"checks","status":"running"' \
  "PR.24 an updated branch records that its checks are re-running"

_gh_reset
_gh_out "api" "merge conflict between base and head"
_gh_rc "api" 1
E24B=$(_write_entry "e24b" "completed" "feature/open-ok" "pr_open" 42)
if pr_update_branch "$E24B"; then
  _tap_fail "PR.24 a conflicting update-branch returns failure" "returned 0"
else
  _tap_pass "PR.24 a conflicting update-branch returns failure"
fi
_load_queue_entry "$E24B"
assert_eq "$(queue_close_state)" "conflict" "PR.24 a rejected update records close_state conflict"
assert_eq "$_PR_OUTCOME" "review:merge-conflict" \
  "PR.24 a rejected update hands the caller review:merge-conflict"

_gh_reset
_gh_out "api" "503 Service Unavailable"
_gh_rc "api" 1
E24C=$(_write_entry "e24c" "completed" "feature/open-ok" "pr_open" 42)
pr_update_branch "$E24C" || true
_load_queue_entry "$E24C"
assert_eq "$(queue_close_state)" "pr_open" \
  "PR.24 a transport failure is NOT a conflict — the entry stays at pr_open"
assert_eq "$_PR_OUTCOME" "" "PR.24 a transport failure is not escalated"

# ========================================================================
# PR.25 — runner and CLI wiring, asserted structurally
#
# Neither file can be sourced: runner.sh parses argv and enters a daemon loop at
# load, and queue-cli.sh dispatches on "$1". So these are grep assertions on the
# shipped source — weaker than behavioural ones, and recorded as such. What they
# are for is the failure this suite could otherwise miss entirely: a green
# pr-manager that nothing ever calls.
# ========================================================================
_RUNNER="$AUTO_DIR/runner.sh"
_CLI="$AUTO_DIR/queue-cli.sh"

assert_contains "$(cat "$_RUNNER")" 'source "$LIB_DIR/pr-manager.sh"' \
  "PR.25 runner.sh sources pr-manager.sh"
assert_contains "$(cat "$_RUNNER")" 'pr_open "$_pr_entry_file"' \
  "PR.25 the runner's close path calls pr_open"
assert_contains "$(cat "$_RUNNER")" "_pr_poll_sweep" \
  "PR.25 the daemon loop runs the open-pull-request poll"
# The trigger is push_on_complete AND finality, not close_path alone: close_path
# defaults to pr for every non-solo entry, so a close_path-only trigger would
# start pushing branches on every existing install.
assert_contains "$(cat "$_RUNNER")" '_is_final_taskgroup_entry "$brief_id" "$work_order_id"; then
      local _pr_entry_file' \
  "PR.25 the PR route is gated on finality (Decision 0015 section 3)"

assert_contains "$(cat "$_CLI")" 'source "$LIB_DIR/pr-manager.sh"' \
  "PR.25 queue-cli.sh sources pr-manager.sh"
for _sub in pr_open pr_refresh pr_rerun pr_update_branch pr_merge; do
  assert_contains "$(cat "$_CLI")" "$_sub \"\$PR_FILE\"" \
    "PR.25 the CLI dispatches $_sub"
done
assert_contains "$(cat "$_CLI")" 'pr status <id>' \
  "PR.25 the pr subcommands are in the usage text"

# Registered in the functional runner — an unregistered suite is a suite that
# never runs again. brief 1's test-close-pipeline.sh shipped unregistered, which
# is why this is asserted rather than assumed.
_RUN_ALL="$SCRIPT_DIR/run-automation-tests.sh"
assert_contains "$(cat "$_RUN_ALL")" "test-pr-manager.sh" \
  "PR.25 this suite is registered in run-automation-tests.sh"
assert_contains "$(cat "$_RUN_ALL")" "test-close-pipeline.sh" \
  "PR.25 brief 1's suite is registered too"

# ========================================================================
printf "1..%d\n" "$_TAP_TEST_NUM"
printf "# pass %d  fail %d\n" "$_TAP_PASS" "$_TAP_FAIL"
[ "$_TAP_FAIL" -eq 0 ]
