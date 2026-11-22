#!/usr/bin/env bash
# test-commit-msg-scan.sh — the commit MESSAGE is scanned for secrets (PR #55).
#
# In March 2026 the template-sync engine wrote a token-bearing URL into its
# commit message and the commit reached five repos. This suite checks the two
# layers that now stop that: the commit-msg git hook, and the engine never
# printing the URL's credential.
#
# gate-conformance.sh and sync-conformance.sh carry the full set of probes. This
# file repeats the core cases as a test-*.sh suite, because verify-pristine.sh
# copies only test-*.sh files into the merge-base clone: run there, against the
# code before PR #55, these cases fail first.
#
# Credentials are assembled from fragments so this file does not trip A4.
# Everything runs in scratch repos under $TMPDIR. Bash 3.2 compatible.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SRC="$SCRIPT_DIR/../git-hooks/commit-msg"
ENGINE="$SCRIPT_DIR/../lib/template-sync-engine.sh"
PATTERN="$SCRIPT_DIR/../../hooks/_secret-pattern.sh"

_TAP_NUM=0; _TAP_PASS=0; _TAP_FAIL=0; _TAP_FAILURES=""
_tap_pass() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_PASS=$((_TAP_PASS+1)); printf "ok %d - %s\n" "$_TAP_NUM" "$1"; }
_tap_fail() {
  _TAP_NUM=$((_TAP_NUM+1)); _TAP_FAIL=$((_TAP_FAIL+1))
  printf "not ok %d - %s\n" "$_TAP_NUM" "$1"
  if [ -n "${2:-}" ]; then printf "  # %s\n" "$2"; fi
  _TAP_FAILURES="${_TAP_FAILURES}  FAIL: $1\n"
}
eq() { if [ "$1" = "$2" ]; then _tap_pass "$3"; else _tap_fail "$3" "expected '$2', got '$1'"; fi; }

CRED="FAKE""CRED""0123456789"
AT="@"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-commit-msg-scan.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

printf "# === commit-msg secret scan (PR #55) ===\n"

# --- The hook, run in a scratch repo carrying its own pattern file ---------
REPO="$WORK/repo"
git init -q "$REPO"
mkdir -p "$REPO/.claude/hooks"
cp "$PATTERN" "$REPO/.claude/hooks/"
cp "$HOOK_SRC" "$REPO/.git/hooks/commit-msg" 2>/dev/null

run_hook() {   # args: printf format and its arguments -> exit code
  # shellcheck disable=SC2059
  printf "$@" > "$WORK/msg"
  ( cd "$REPO" && bash .git/hooks/commit-msg "$WORK/msg" ) > "$WORK/out" 2>&1
  echo $?
}
no_cred_in_output() {
  if grep -q "$CRED" "$WORK/out" 2>/dev/null; then echo leaked; else echo clean; fi
}

eq "$(run_hook 'fix: x\n\nhttps://x-access-token:%s%sgithub.com/o/r.git\n' "$CRED" "$AT")" 1 \
  "a credential URL in the message blocks"
eq "$(no_cred_in_output)" clean "...and the refusal does not print it"
eq "$(run_hook 'fix: x\n# https://u:%s%sexample.invalid/r\n' "$CRED" "$AT")" 1 \
  "a credential on a '#' line blocks (git commit -m keeps those lines)"
eq "$(no_cred_in_output)" clean "...and the refusal does not print it"
eq "$(run_hook 'chore: x\n\n%s\n' "github""_pat_""11ABCDEFGHIJ")" 1 \
  "a GitHub token in the message blocks"
eq "$(run_hook 'fix: rotate the token handling\n')" 0 \
  "a plain message that mentions a token passes"

# --- Through git, with hooks kept outside .git/hooks -----------------------
GREPO="$WORK/grepo"
git init -q "$GREPO"
mkdir -p "$GREPO/.githooks" "$GREPO/.claude/hooks"
cp "$PATTERN" "$GREPO/.claude/hooks/"
cp "$HOOK_SRC" "$GREPO/.githooks/commit-msg" 2>/dev/null && chmod +x "$GREPO/.githooks/commit-msg"
git -C "$GREPO" config core.hooksPath .githooks
git_commit() {   # arg: second paragraph -> 0 if a commit was made, 1 if not
  git -C "$GREPO" -c user.name=t -c user.email=t@example.invalid \
    commit -q --allow-empty -m "fix: probe" -m "$1" > "$WORK/out" 2>&1 && echo 0 || echo 1
}
eq "$(git_commit "https://u:${CRED}${AT}example.invalid/r")" 1 \
  "core.hooksPath=.githooks: git refuses a message carrying a credential"
eq "$(grep -c 'BLOCKED' "$WORK/out" 2>/dev/null)" 1 "...and the refusal comes from the hook"
eq "$(git -C "$GREPO" rev-list --count HEAD 2>/dev/null || echo 0)" 0 "...and no commit was made"
eq "$(git_commit "a plain paragraph")" 0 "core.hooksPath=.githooks: a plain message commits"

# --- The sync engine never prints the URL's credential ---------------------
# A URL that cannot be fetched exercises every line the engine prints before it
# commits, git's own stderr included. Neither form is https github.com, so the
# generic userinfo strip is what keeps them clean.
CHILD="$WORK/child"
git init -q "$CHILD"
git -C "$CHILD" checkout -q -b main 2>/dev/null
git -C "$CHILD" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "child v1"
for url in "nosuch://x-access-token:${CRED}${AT}example.invalid/o/r.git" \
           "https://u:${CRED}${AT}example.invalid/o/r.git"; do
  scheme="${url%%://*}"
  ( cd "$CHILD" && GIT_TERMINAL_PROMPT=0 bash "$ENGINE" "$url" main ) > "$WORK/out" 2>&1
  rc=$?
  [ "$rc" -ne 0 ] && rc=1
  eq "$rc" 1 "$scheme: an unfetchable template URL fails the sync"
  eq "$(no_cred_in_output)" clean "$scheme: nothing the engine prints contains the credential"
done

printf "\n1..%d\n# passed %d, failed %d\n" "$_TAP_NUM" "$_TAP_PASS" "$_TAP_FAIL"
if [ "$_TAP_FAIL" -gt 0 ]; then printf "\n# Failures:\n%b" "$_TAP_FAILURES"; exit 1; fi
exit 0
