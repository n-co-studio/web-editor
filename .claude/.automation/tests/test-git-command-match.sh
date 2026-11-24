#!/usr/bin/env bash
# git_invokes — Decision t-0087
#
# The commit gate, the push gate and the subagent git guard decide whether a
# Bash command is a commit or a push with git_invokes
# (.claude/hooks/_git-command-helper.sh). Before t-0087 they looked for the
# literal text "git commit" / "git push", so `git -C <path> commit` skipped
# them. This suite pins what counts and, as importantly, what must not: the
# commit gate blocks what it matches at most phases.
#
# Run against the code before t-0087 (verify-pristine) the cases fail: the
# helper does not exist.
# Bash 3.2 compatible.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_REPO="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HELPER="$REAL_REPO/.claude/hooks/_git-command-helper.sh"

_TAP_NUM=0; _TAP_PASS=0; _TAP_FAIL=0; _TAP_FAILURES=""
_tap_pass() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_PASS=$((_TAP_PASS+1)); printf "ok %d - %s\n" "$_TAP_NUM" "$1"; }
_tap_fail() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_FAIL=$((_TAP_FAIL+1)); printf "not ok %d - %s\n" "$_TAP_NUM" "$1"; [ -n "${2:-}" ] && printf "  # %s\n" "$2"; _TAP_FAILURES="${_TAP_FAILURES}  FAIL: $1\n"; }

printf "# === git_invokes (Decision t-0087) ===\n"
# shellcheck disable=SC1090
source "$HELPER" 2>/dev/null || true
command -v git_invokes >/dev/null 2>&1 || git_invokes() { return 2; }

yes_() { if git_invokes "$1" "$2"; then _tap_pass "$1: [$2]"; else _tap_fail "$1: [$2]" "not recognised"; fi; }
no_()  { git_invokes "$1" "$2"; rc=$?
         if [ "$rc" -eq 1 ]; then _tap_pass "not $1: [$2]"; else _tap_fail "not $1: [$2]" "rc=$rc"; fi; }

for sub in commit push; do
  printf "\n# %s: recognised\n" "$sub"
  yes_ $sub "git $sub"
  yes_ $sub "git $sub -q"
  yes_ $sub "git -C /Users/me/repo $sub -F /tmp/msg"
  yes_ $sub "git -C \"/Users/me/my repo\" $sub"
  yes_ $sub "git -C '/Users/me/my repo' $sub"
  yes_ $sub "git -c user.name=x -c core.hooksPath=/a=b $sub"
  yes_ $sub "git -c \"core.editor=code --wait\" $sub"
  yes_ $sub "git --git-dir=/r/.git --work-tree=/r $sub"
  yes_ $sub "git --git-dir /r/.git $sub"
  yes_ $sub "git --no-pager $sub"
  yes_ $sub "git -P $sub"
  yes_ $sub "cd /repo && git $sub"
  yes_ $sub "cd /repo;git -C . $sub"
  yes_ $sub "true || git $sub"
  yes_ $sub "x=\$(git -C . $sub)"
  yes_ $sub "(git $sub)"
  yes_ $sub "env A=1 git $sub"
  yes_ $sub "/usr/bin/git -C . $sub"
  yes_ $sub "git  -C  .   $sub"
  yes_ $sub "sh -c 'git -C . $sub'"
  yes_ $sub "bash -c \"git -c a=b $sub\""
  yes_ $sub "\"git\" -C . $sub"
  yes_ $sub "\\git -C . $sub"
  yes_ $sub "\$(which git) $sub"
  yes_ $sub "git -c user.name=\"A B\" $sub"
  yes_ $sub "git -c core.editor='code --wait' $sub"
  yes_ $sub "git -C \$(git rev-parse --show-toplevel) $sub"
  yes_ $sub "git -C \"\$HOME/r\" $sub"
  yes_ $sub "git -C . $sub>/dev/null"
  yes_ $sub "git -C . \\
  $sub"
  yes_ $sub "	git	-C	.	$sub"
  yes_ $sub "git \"$sub\""
  yes_ $sub "git -C . '$sub'"
  yes_ $sub "git -C /tmp/my\\ dir $sub"
  yes_ $sub "git -c user.name=a\\ b $sub"
  yes_ $sub "git -C \`pwd\` $sub"
  yes_ $sub "git -c alias.ci=$sub ci"
  yes_ $sub "git -c alias.x='!git $sub' x"
  yes_ $sub "git config alias.ci $sub && git ci"

  printf "\n# %s: not recognised\n" "$sub"
  no_ $sub "git log --grep $sub"
  no_ $sub "git show HEAD"
  no_ $sub "git -C /repo status"
  no_ $sub "echo ${sub}ted"
  no_ $sub "ls /tmp/$sub/git"
  no_ $sub "git config $sub.x true"
  no_ $sub "git -C /a/$sub/b status"
  no_ $sub "gitk $sub"
  no_ $sub "legit $sub"
  no_ $sub "git config alias.st status"
  no_ $sub "git -c alias.lg=log lg"
  no_ $sub ""
done
no_ commit "git commit-tree HEAD^{tree}"
no_ commit "git -C . commit-graph write"
no_ push "git push-hook"

printf "\n# %d passed, %d failed\n" "$_TAP_PASS" "$_TAP_FAIL"
if [ "$_TAP_FAIL" -gt 0 ]; then printf "%b" "$_TAP_FAILURES"; exit 1; fi
exit 0
