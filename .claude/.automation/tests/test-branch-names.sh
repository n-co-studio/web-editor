#!/usr/bin/env bash
# Branch names and commit-making git commands — Decision t-0088
#
# .claude/hooks/_branch-name-helper.sh holds the one list of valid branch
# names (bash-guard at creation, the push gate's B1 at push), the suggestion a
# refusal prints, the parser that finds the branch a command would create, and
# git_commit_bypass, which finds a merge, cherry-pick or revert that would
# make its own commit. The hooks themselves are tested in layer3.
#
# Run against the code before t-0088 (verify-pristine) the cases fail: the
# helper does not exist.
# Bash 3.2 compatible.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_REPO="$(cd "$SCRIPT_DIR/../../.." && pwd)"

_TAP_NUM=0; _TAP_PASS=0; _TAP_FAIL=0; _TAP_FAILURES=""
_tap_pass() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_PASS=$((_TAP_PASS+1)); printf "ok %d - %s\n" "$_TAP_NUM" "$1"; }
_tap_fail() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_FAIL=$((_TAP_FAIL+1)); printf "not ok %d - %s\n" "$_TAP_NUM" "$1"; [ -n "${2:-}" ] && printf "  # %s\n" "$2"; _TAP_FAILURES="${_TAP_FAILURES}  FAIL: $1\n"; }
_tap_eq() { if [ "$1" = "$2" ]; then _tap_pass "$3"; else _tap_fail "$3" "expected '$2', got '$1'"; fi; }

printf "# === Branch names and commit-making commands (Decision t-0088) ===\n"
# shellcheck disable=SC1091
source "$REAL_REPO/.claude/hooks/_git-command-helper.sh" 2>/dev/null || true
# shellcheck disable=SC1091
source "$REAL_REPO/.claude/hooks/_branch-name-helper.sh" 2>/dev/null || true
for f in branch_name_valid branch_name_suggest branch_created_name git_commit_bypass; do
  command -v "$f" >/dev/null 2>&1 || eval "$f() { echo MISSING; return 2; }"
done

printf "\n# valid names\n"
for n in feature/x fix/a-b hotfix/urgent release/v2 experiment/spike live-editor-7 feature/a/b; do
  branch_name_valid "$n"; _tap_eq "$?" "0" "valid: $n"
done
for n in feat/x main feature/ bug/x live-editor-x live-editor- chore/y x "" Feature/x; do
  branch_name_valid "$n"; rc=$?
  if [ "$rc" -ne 0 ]; then _tap_pass "invalid: [$n]"; else _tap_fail "invalid: [$n]" "accepted"; fi
done

printf "\n# suggestions\n"
s() { _tap_eq "$(branch_name_suggest "$1")" "$2" "suggest $1 -> $2"; }
s feat/login feature/login
s features/login feature/login
s bug/crash fix/crash
s bugfix/crash fix/crash
s fixes/crash fix/crash
s hot-fix/now hotfix/now
s spike/idea experiment/idea
s poc/idea experiment/idea
s prototype/idea experiment/idea
s exp/idea experiment/idea
s rel/v2 release/v2
s releases/v2 release/v2
s chore/tidy feature/chore/tidy
s login-page feature/login-page
s feature/ feature/work

printf "\n# the branch a command creates\n"
c() { _tap_eq "$(branch_created_name "$1")" "$2" "creates [$2]: $1"; }
c "git checkout -b feat/x" "feat/x"
c "git checkout -q -b feat/x origin/main" "feat/x"
c "git checkout -B feat/x" "feat/x"
c "git checkout --orphan feat/x" "feat/x"
c "git switch -c feat/x" "feat/x"
c "git switch --create feat/x" "feat/x"
c "git switch --create=feat/x" "feat/x"
c "git switch -C feat/x" "feat/x"
c "git worktree add -b feat/x ../wt" "feat/x"
c "git worktree add --detach -b feat/x ../wt" "feat/x"
c "git worktree add ../wt -b feat/x" "feat/x"
c "git worktree add -f ../wt -B feat/x main" "feat/x"
c "git branch feat/x" "feat/x"
c "git -C /repo checkout -b feat/x" "feat/x"
c "cd /repo && git checkout -b 'feat/x'" "feat/x"
c "git -c a=b switch -c \"feat/x\"" "feat/x"
c "git branch feat/x && git checkout feat/x" "feat/x"
c "git checkout -b feature/ok && git checkout -b bad" "feature/ok
bad"
c "git -C . worktree add ../wt -b feat/x; git branch bad" "feat/x
bad"
c "bash -c \"git checkout -b bad\"" "bad"
c "echo \"\$(git checkout -b bad)\"" "bad"
c "git \"checkout\" -b bad" "bad"
printf "\n# commands that create no branch\n"
c "git branch
pwd" ""
c "git commit -m \"use git checkout -b fix-x\"" ""
c "echo 'run git branch foo'" ""
c "git checkout main # then git checkout -b bad" ""
c "git checkout feat/x" ""
c "git checkout main" ""
c "git switch feature/x" ""
c "git branch" ""
c "git branch -d feat/x" ""
c "git branch -m feat/x" ""
c "git branch --list" ""
c "git branch feat/x origin/main" ""
c "git branch | grep x" ""
c "git log --grep checkout -b" ""
c "echo git checkout" ""

printf "\n# merges, cherry-picks and reverts that make their own commit\n"
b() { _tap_eq "$(git_commit_bypass "$1")" "$2" "bypass [$2]: $1"; }
b "git merge feature/other" "merge"
b "git merge --no-ff feature/other" "merge"
b "git merge main-foo" "merge"
b "git merge origin/main-x" "merge"
b "git merge --continue" "merge"
b "git -C . merge feature/other" "merge"
b "git cherry-pick abc123" "cherry-pick"
b "git cherry-pick -x abc123" "cherry-pick"
b "git cherry-pick --continue" "cherry-pick"
b "git revert abc123" "revert"
b "git revert --no-edit HEAD" "revert"
b "git merge feature/x && git rebase --abort" "merge"
b "git merge main feature/x" "merge"
b "git merge feature/x; echo --no-commit" "merge"
b "git cherry-pick abc; git log -n 1" "cherry-pick"
b "git merge --abort; git merge other" "merge"
b "git merge --no-commit a; git merge b" "merge"
b "git merge --no-commit a && git merge b" "merge"
b "git cherry-pick -n a && git cherry-pick b" "cherry-pick"
b "git merge --no-commit a
git merge b" "merge"
b "git merge other # --no-commit" "merge"
b "git merge other; git checkout main" "merge"
b "git merge other # checkout main" "merge"
b "echo checkout main; git merge other" "merge"
b "git checkout main -- file && git merge x" "merge"
b "git checkout main && git checkout feature/y && git merge x" "merge"
b "bash -c \"git merge feat\"" "merge"
b "sh -c 'git -C . merge feat'" "merge"
b "x=\"\$(git merge feat)\"" "merge"
b "echo \"\$(git cherry-pick abc)\"" "cherry-pick"
b "git \"merge\" feat" "merge"
b "git 'revert' HEAD" "revert"
printf "\n# forms left for a normal commit, or making none\n"
b "git merge main" ""
b "git merge origin/main" ""
b "git merge --no-ff origin/main" ""
b "git merge --no-commit --no-ff feature/other" ""
b "git merge --squash feature/other" ""
b "git merge --abort" ""
b "git cherry-pick -n abc123" ""
b "git cherry-pick --no-commit abc123" ""
b "git cherry-pick --abort" ""
b "git cherry-pick --skip" ""
b "git revert -n abc123" ""
b "git revert --no-commit HEAD" ""
b "git revert --quit" ""
b "git merge-base main HEAD" ""
b "git merge -m \"bring main in\" main" ""
b "git merge -m 'x --no-ff' origin/main" ""
b "git checkout main && git merge --ff-only feature/x" ""
b "git switch main && git merge --no-ff feature/x" ""
b "git merge origin/main --no-edit" ""
b "git commit -m \"merge\" && git merge --no-commit x" ""
b "git commit -m \"docs: explain git merge and git revert\"" ""
b "git checkout -q main && git merge --ff-only feature/x" ""
b "git log --merges" ""
b "git show --grep revert" ""

printf "\n# %d passed, %d failed\n" "$_TAP_PASS" "$_TAP_FAIL"
if [ "$_TAP_FAIL" -gt 0 ]; then printf "%b" "$_TAP_FAILURES"; exit 1; fi
exit 0
