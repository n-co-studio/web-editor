#!/usr/bin/env bash
# Outcome detector + blocker reporter, against a real repo and a real linked
# worktree (known-issue R34).
#
# (a) detect_outcome decided "dirty" from `git diff` and `git diff --cached`
#     only, so a session that left nothing but NEW files was recorded
#     completed:clean-noop — a completed entry with its work uncommitted and
#     nothing flagging it. write_blocker_report repeated the same check, and ran
#     it with no -C at all, so it described the runner's CWD (the main repo)
#     rather than the session's tree.
# (b) Blocker reports were written to "$repo_root/.claude/.automation/reports",
#     and for a worktree session repo_root IS the worktree, which
#     remove_session_worktree deletes straight afterwards (runner.sh). Storage
#     belongs to the main repo; git facts belong to the session's tree.
#
# Self-contained: a /tmp repo with a linked worktree, helpers rooted in it
# through the test seam. Bash 3.2 compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
LIB_DIR="$REAL_ROOT/.claude/.automation/lib"

_TAP_NUM=0; _TAP_PASS=0; _TAP_FAIL=0; _TAP_FAILURES=""
_tap_pass() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_PASS=$((_TAP_PASS+1)); printf "ok %d - %s\n" "$_TAP_NUM" "$1"; }
_tap_fail() {
  _TAP_NUM=$((_TAP_NUM+1)); _TAP_FAIL=$((_TAP_FAIL+1))
  printf "not ok %d - %s\n" "$_TAP_NUM" "$1"
  if [ -n "${2:-}" ]; then printf "  # %s\n" "$2"; fi
  _TAP_FAILURES="${_TAP_FAILURES}  FAIL: $1\n"
}
_tap_eq() { if [ "$1" = "$2" ]; then _tap_pass "$3"; else _tap_fail "$3" "expected '$2', got '$1'"; fi; }

printf "# === Outcome detector + blocker reporter (R34) ===\n"

T=$(mktemp -d /tmp/repo-os-od-XXXXXX) || { echo "Bail out! mktemp failed"; exit 2; }
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
MAIN="$T/main"
WT="$T/wt"

git init -q "$MAIN"
git -C "$MAIN" symbolic-ref HEAD refs/heads/main
git -C "$MAIN" config user.email t@t
git -C "$MAIN" config user.name t
git -C "$MAIN" config commit.gpgsign false
printf 'ignored.log\n' > "$MAIN/.gitignore"
printf 'base\n' > "$MAIN/a.txt"
git -C "$MAIN" add -A
git -C "$MAIN" commit -q -m base
git -C "$MAIN" worktree add -q -b feature/od "$WT" 2>/dev/null
BASE=$(git -C "$WT" rev-parse HEAD)

# Helpers rooted in the scratch main repo. The analytics dir is redirected so
# _capture_analytics_events never reads the operator's real event log.
export REPO_OS_TEST_MODE=1
export _REPO_OS_TEST_ROOT="$MAIN"
export REPO_OS_SESSION_ID="od-test-$$"
export HOME="$T/home"
mkdir -p "$HOME"
# shellcheck disable=SC1091
source "$REAL_ROOT/.claude/hooks/_analytics-helper.sh"
# shellcheck disable=SC1091
source "$REAL_ROOT/.claude/hooks/_phase-helper.sh"
_parse_config_field() { return 1; }   # queue-manager.sh is not loaded here
# Same order as runner.sh: outcome-detector.sh first, because blocker-reporter
# uses its helpers. blocker-reporter.sh turns errexit on, so it is turned off
# again after: a case returning non-zero must be recorded, not end the suite.
# shellcheck disable=SC1091
. "$LIB_DIR/outcome-detector.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/blocker-reporter.sh"
set +e

# Restores the worktree to a clean tree at BASE between cases.
_reset_wt() {
  git -C "$WT" reset -q --hard "$BASE"
  git -C "$WT" clean -qfdx -e .gitignore
}

# Runs detect_outcome from the MAIN repo's directory, as runner.sh does (the
# daemon lives in the main checkout and hands the worktree over as repo_root).
_detect() {
  (cd "$MAIN" && detect_outcome "$1" "$BASE" "$WT" "entry-od" "" "" 2>/dev/null)
}

printf "# --- (a) a tree holding only new files is dirty ---\n"

_reset_wt
_tap_eq "$(_detect 0)" "completed:clean-noop" "clean tree, exit 0 → completed:clean-noop (control)"

_reset_wt
printf 'new work\n' > "$WT/new-file.txt"
_tap_eq "$(_detect 0)" "review:dirty-noop" "untracked-only work, exit 0 → review:dirty-noop, not clean-noop"

_reset_wt
printf 'new work\n' > "$WT/new-file.txt"
_tap_eq "$(_detect 1)" "failed:crash" "untracked-only work, exit 1 → failed:crash, not clean-failure"

_reset_wt
printf 'noise\n' > "$WT/ignored.log"
_tap_eq "$(_detect 0)" "completed:clean-noop" "gitignored-only file, exit 0 → still completed:clean-noop"

_reset_wt
printf 'edit\n' >> "$WT/a.txt"
_tap_eq "$(_detect 0)" "review:dirty-noop" "tracked modification, exit 0 → review:dirty-noop (unchanged behaviour)"

printf "# --- (b) blocker reports: stored in main, describing the session tree ---\n"

_report_files() { find "$1" -path '*/.claude/.automation/reports/report-*.yaml' -type f 2>/dev/null; }

_reset_wt
rm -rf "$MAIN/.claude/.automation/reports" "$WT/.claude/.automation/reports"
printf 'new work\n' > "$WT/new-file.txt"
_tap_eq "$(_detect 1)" "failed:crash" "crash with untracked work classifies as failed:crash"
_R_MAIN=$(_report_files "$MAIN" | head -1)
_tap_eq "$(_report_files "$WT" | wc -l | tr -d ' ')" "0" "no report is written inside the worktree"
if [ -n "$_R_MAIN" ]; then
  _tap_pass "the report is written under the MAIN repo's reports dir"
else
  _tap_fail "the report is written under the MAIN repo's reports dir" "none under $MAIN"
fi

# The report must describe the SESSION's tree, not the runner's CWD (main is
# clean and on `main`; the worktree is dirty and on feature/od).
if [ -n "$_R_MAIN" ]; then
  if grep -q '^  type: "crash"' "$_R_MAIN"; then
    _tap_pass "report type is crash — the dirty check ran against the worktree"
  else
    _tap_fail "report type is crash — the dirty check ran against the worktree" "$(grep '^  type:' "$_R_MAIN")"
  fi
  if grep -q '^  git_status: ".*new-file.txt' "$_R_MAIN"; then
    _tap_pass "report git_status lists the worktree's untracked file"
  else
    _tap_fail "report git_status lists the worktree's untracked file" "$(grep '^  git_status:' "$_R_MAIN")"
  fi
  if grep -q '^  branch: "feature/od"' "$_R_MAIN"; then
    _tap_pass "report branch is the session's branch"
  else
    _tap_fail "report branch is the session's branch" "$(grep '^  branch:' "$_R_MAIN")"
  fi
else
  _tap_fail "report content checks" "no report to inspect"
fi

# The analytics events a report quotes must be the FAILED session's. Storage
# moved to the main repo, and the main checkout's .claude/.session-id names a
# different session (the operator's or the daemon's): filtering on it would
# quote that session's block events as this one's.
_EV_DIR="$HOME/.local/share/repo-os-analytics/$(basename "$MAIN")/events"
mkdir -p "$_EV_DIR"
_EV_FILE="$_EV_DIR/$(date -u +%Y-%m-%d).ndjson"
printf '{"sid":"operator-session","hook":"bash-guard","out":"block","reason":"NOT-THIS-SESSION"}\n' > "$_EV_FILE"
printf '{"sid":"%s","hook":"pre-commit-gates","out":"block","reason":"THIS-SESSION"}\n' "$REPO_OS_SESSION_ID" >> "$_EV_FILE"
mkdir -p "$MAIN/.claude"
printf 'operator-session\n' > "$MAIN/.claude/.session-id"
_reset_wt
printf 'new work\n' > "$WT/new-file.txt"
rm -rf "$MAIN/.claude/.automation/reports"
_detect 1 > /dev/null
_R_EV=$(_report_files "$MAIN" | head -1)
_EV_LINE=$(grep '^  analytics_events:' "${_R_EV:-/dev/null}" 2>/dev/null || true)
case "$_EV_LINE" in
  *THIS-SESSION*) _tap_pass "report quotes the failed session's block events" ;;
  *) _tap_fail "report quotes the failed session's block events" "${_EV_LINE:-no analytics_events line}" ;;
esac
case "$_EV_LINE" in
  *NOT-THIS-SESSION*) _tap_fail "...and not the main checkout's session's" "$_EV_LINE" ;;
  *) _tap_pass "...and not the main checkout's session's" ;;
esac
rm -f "$MAIN/.claude/.session-id" "$_EV_FILE"

# outcome-detector.sh's own fallback writer, used when blocker-reporter.sh is
# not loaded, must root its report the same way.
_reset_wt
printf 'new work\n' > "$WT/new-file.txt"
rm -rf "$MAIN/.claude/.automation/reports"
(unset -f write_blocker_report; cd "$MAIN" && detect_outcome 1 "$BASE" "$WT" "entry-fb" "" "" > /dev/null 2>&1)
_tap_eq "$(_report_files "$WT" | wc -l | tr -d ' ')" "0" "fallback writer: no report inside the worktree"
_tap_eq "$(_report_files "$MAIN" | wc -l | tr -d ' ')" "1" "fallback writer: report under the MAIN repo"
_R_MAIN=$(_report_files "$MAIN" | head -1)

# What the fix is for: the report outlives the worktree.
git -C "$MAIN" worktree remove --force "$WT" 2>/dev/null
if [ -n "$_R_MAIN" ] && [ -f "$_R_MAIN" ]; then
  _tap_pass "the report survives removal of the worktree"
else
  _tap_fail "the report survives removal of the worktree" "${_R_MAIN:-no report}"
fi

# A session running in the main checkout itself: rooting must be a no-op.
rm -rf "$MAIN/.claude/.automation/reports"
printf 'main work\n' > "$MAIN/main-new.txt"
_R_OUT=$(cd "$MAIN" && detect_outcome 1 "$(git -C "$MAIN" rev-parse HEAD)" "$MAIN" "entry-main" "" "" 2>/dev/null)
_tap_eq "$_R_OUT" "failed:crash" "main-checkout session with untracked work → failed:crash"
_tap_eq "$(_report_files "$MAIN" | wc -l | tr -d ' ')" "1" "main-checkout session's report lands in its own reports dir"
rm -f "$MAIN/main-new.txt"

# A repo whose git dir lives elsewhere (--separate-git-dir; submodules look the
# same) reports an ABSOLUTE common dir that is not "<repo>/.git". It is not a
# linked worktree, so its reports belong in its own tree — dirname of that
# common dir would name an unrelated directory.
_SEP="$T/sep-repo"
git init -q --separate-git-dir "$T/sep-gitdir" "$_SEP" 2>/dev/null
_tap_eq "$(_session_storage_root "$_SEP")" "$_SEP" "separate-git-dir repo stores under its own root, not the git dir's parent"
_tap_eq "$(_session_storage_root "$MAIN")" "$MAIN" "main checkout stores under itself"

# A repo_root git cannot resolve: fall back to repo_root itself, never an
# empty path (which would write under /.claude).
_NOGIT="$T/not-a-repo"
mkdir -p "$_NOGIT"
(cd "$MAIN" && write_blocker_report 1 "$_NOGIT" "entry-nogit" "" "" 2>/dev/null) || true
_tap_eq "$(_report_files "$_NOGIT" | wc -l | tr -d ' ')" "1" "unresolvable repo_root falls back to its own reports dir"

printf "\n# === Summary ===\n"
printf "1..%d\n" "$_TAP_NUM"
printf "# pass %d / fail %d\n" "$_TAP_PASS" "$_TAP_FAIL"
if [ "$_TAP_FAIL" -gt 0 ]; then
  printf "%b" "$_TAP_FAILURES"
  exit 1
fi
exit 0
