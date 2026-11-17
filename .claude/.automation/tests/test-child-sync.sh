#!/usr/bin/env bash
# child-sync.sh pull step — each local clone's state gets its own outcome
#
# Template sync lands on a child's origin/main. The pull step must bring the
# clone's local main up to it whatever is checked out, and say plainly why when
# it cannot (dirty main, diverged main, fetch error) instead of a blanket
# "pull failed". Clones are throwaway repos against a local bare origin; only
# pull_locals runs, so gh is never called.
# Bash 3.2 compatible.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_TAP_NUM=0; _TAP_PASS=0; _TAP_FAIL=0; _TAP_FAILURES=""
_tap_pass() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_PASS=$((_TAP_PASS+1)); printf "ok %d - %s\n" "$_TAP_NUM" "$1"; }
_tap_fail() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_FAIL=$((_TAP_FAIL+1)); printf "not ok %d - %s\n" "$_TAP_NUM" "$1"; [ -n "${2:-}" ] && printf "  # %s\n" "$2"; _TAP_FAILURES="${_TAP_FAILURES}  FAIL: $1\n"; }
_tap_eq() {
  if [ "$1" = "$2" ]; then _tap_pass "$3"; else _tap_fail "$3" "expected '$2', got '$1'"; fi
}
_tap_contains() {
  case "$1" in
    *"$2"*) _tap_pass "$3" ;;
    *)      _tap_fail "$3" "output did not contain '$2'" ;;
  esac
}

printf "# === child-sync.sh pull step ===\n"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/child-sync-test-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Isolate git from the operator's config and hooks.
export HOME="$WORK/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name "test"
git config --global user.email "test@example.invalid"
git config --global init.defaultBranch main

_g() { git -C "$1" "${@:2}" >/dev/null 2>&1; }

# --- Origin with one commit on main ---
git init -q --bare "$WORK/origin.git"
git clone -q "$WORK/origin.git" "$WORK/seed" 2>/dev/null
echo one > "$WORK/seed/f.txt"
_g "$WORK/seed" add f.txt; _g "$WORK/seed" commit -m one; _g "$WORK/seed" push origin main

_clone() { git clone -q "$WORK/origin.git" "$WORK/$1" 2>/dev/null; }

_clone clean                                     # main checked out, clean
_clone dirty;    echo local > "$WORK/dirty/f.txt" # main checked out, tracked edit
_clone untracked; echo new > "$WORK/untracked/u.txt" # untracked file only
_clone feature;  _g "$WORK/feature" checkout -b feature/x
_clone nomain;   _g "$WORK/nomain" checkout -b feature/y; _g "$WORK/nomain" branch -D main
_clone diverged; echo mine > "$WORK/diverged/g.txt"
_g "$WORK/diverged" add g.txt; _g "$WORK/diverged" commit -m mine
_clone current
_clone nofetch;  _g "$WORK/nofetch" remote set-url origin "$WORK/missing.git"
mkdir -p "$WORK/plain"

# Template sync lands a second commit on origin/main after the clones were made.
echo two > "$WORK/seed/f.txt"
_g "$WORK/seed" commit -am two; _g "$WORK/seed" push origin main
ORIGIN_MAIN=$(git -C "$WORK/origin.git" rev-parse main)
# "current" is already level with it, and dirty — up to date is not a failure.
_g "$WORK/current" pull --ff-only; echo scratch > "$WORK/current/f.txt"

# --- Source child-sync.sh without running main ---
# A script without the source guard runs main on source; a failing gh stub
# keeps that from reaching GitHub (no workflow triggers, so no pulls either).
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/gh"; chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
export REPO_OS_GITHUB_ORG=test-org
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/child-sync.sh"
set +e
CONF="$WORK/child-repos.conf"
LOG="$WORK/child-sync.log"
{
  echo "# test registry"
  for n in clean dirty untracked feature nomain diverged current nofetch plain; do
    echo "repo-$n $WORK/$n"
  done
} > "$CONF"

pull_locals < /dev/null
OUT="$(cat "$LOG")"
_line() { printf '%s\n' "$OUT" | grep -F "repo-$1" | head -1; }

# 1. main checked out, clean: fast-forwarded
_tap_eq "$(git -C "$WORK/clean" rev-parse main)" "$ORIGIN_MAIN" "clean main is fast-forwarded to origin/main"
_tap_contains "$(_line clean)" "Pulled: repo-clean" "clean main is logged as pulled"

# 2. main checked out, dirty: skipped with the reason, nothing moved
_tap_contains "$(_line dirty)" "FAIL: repo-dirty — main checked out and dirty, 1 files" "dirty main is reported as dirty"
_tap_eq "$(cat "$WORK/dirty/f.txt")" "local" "dirty main keeps its uncommitted edit"
_tap_eq "$(git -C "$WORK/untracked" rev-parse main)" "$ORIGIN_MAIN" "an untracked file alone does not block the fast-forward"
_tap_eq "$(cat "$WORK/untracked/u.txt")" "new" "the untracked file is left in place"

# 3. feature branch checked out: main updated in place, branch left alone
_tap_eq "$(git -C "$WORK/feature" rev-parse main)" "$ORIGIN_MAIN" "main is updated while a feature branch is checked out"
_tap_eq "$(git -C "$WORK/feature" symbolic-ref --short HEAD)" "feature/x" "the feature branch stays checked out"
_tap_contains "$(_line feature)" "feature/x checked out, 1 behind main" "the log says how far the feature branch is behind main"

# 4. no local main: created from origin/main
_tap_eq "$(git -C "$WORK/nomain" rev-parse main 2>/dev/null)" "$ORIGIN_MAIN" "a missing local main is created from origin/main"
_tap_contains "$(_line nomain)" "created local main" "the created main is logged"

# 5. diverged main: refused, counts given, local commit kept
_tap_contains "$(_line diverged)" "main diverged (1 ahead / 1 behind origin/main) — manual" "diverged main is reported with its counts"
_tap_eq "$(git -C "$WORK/diverged" log -1 --format=%s main)" "mine" "diverged main keeps its local commit"

# 6. already level with origin/main (dirty tree irrelevant): success
_tap_contains "$(_line current)" "Pulled: repo-current → $WORK/current (main up to date)" "an up-to-date main is a success even with a dirty tree"

# 7. fetch error: git's own message reaches the log
_tap_contains "$(_line nofetch)" "FAIL: repo-nofetch — fetch failed:" "a fetch error is logged as such"
_tap_contains "$(_line nofetch)" "missing.git" "git's error text is in the log line"

# 8. not a git clone
_tap_contains "$OUT" "SKIP: $WORK/plain (not a git clone)" "a non-clone path is skipped"

# 9. totals and the removed blanket message
_tap_eq "$_PULL_SUCCESS/$_PULL_FAILED" "5/4" "5 clones counted as synced, 4 as failed"

# 10. credentials in a remote URL are masked in the log line
_tap_eq "$(_oneline "fatal: unable to access 'https://tok3n@example.invalid/r.git/'")" \
  "fatal: unable to access 'https://***@example.invalid/r.git/'" "credentials in a URL are masked"
case "$OUT" in
  *"may have local changes"*) _tap_fail "the blanket 'may have local changes' message is gone" ;;
  *) _tap_pass "the blanket 'may have local changes' message is gone" ;;
esac

# --- Summary ---
printf "\n1..%d\n" "$_TAP_NUM"
printf "# Tests: %d  Pass: %d  Fail: %d\n" "$_TAP_NUM" "$_TAP_PASS" "$_TAP_FAIL"
[ "$_TAP_FAIL" -gt 0 ] && printf "# Failures:\n%b" "$_TAP_FAILURES"
exit "$_TAP_FAIL"
