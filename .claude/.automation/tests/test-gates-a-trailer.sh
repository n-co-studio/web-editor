#!/usr/bin/env bash
# Gates-A trailer — Decision t-0086
#
# The commit gate saves what each A check did; the git commit-msg hook calls
# .claude/.automation/lib/gates-a-trailer.sh, which writes that as the Gates-A
# trailer in place of anything the agent wrote. This suite runs the script on
# message files in scratch repos, then runs real commits through the installed
# commit-msg hook.
#
# Run against the code before t-0086 (verify-pristine) the cases fail: the
# script does not exist and commit-msg does not call it.
# Bash 3.2 compatible.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_REPO="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$REAL_REPO/.claude/.automation/lib/gates-a-trailer.sh"
HOOK="$REAL_REPO/.claude/.automation/git-hooks/commit-msg"

_TAP_NUM=0; _TAP_PASS=0; _TAP_FAIL=0; _TAP_FAILURES=""
_tap_pass() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_PASS=$((_TAP_PASS+1)); printf "ok %d - %s\n" "$_TAP_NUM" "$1"; }
_tap_fail() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_FAIL=$((_TAP_FAIL+1)); printf "not ok %d - %s\n" "$_TAP_NUM" "$1"; [ -n "${2:-}" ] && printf "  # %s\n" "$2"; _TAP_FAILURES="${_TAP_FAILURES}  FAIL: $1\n"; }
_tap_eq() { if [ "$1" = "$2" ]; then _tap_pass "$3"; else _tap_fail "$3" "expected '$2', got '$1'"; fi; }
_tap_contains() { case "$1" in *"$2"*) _tap_pass "$3" ;; *) _tap_fail "$3" "output did not contain '$2': $1" ;; esac; }
_tap_lacks() { case "$1" in *"$2"*) _tap_fail "$3" "output contained '$2': $1" ;; *) _tap_pass "$3" ;; esac; }

printf "# === Gates-A trailer (Decision t-0086) ===\n"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ga-test.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

LINE='A1-pass A2-pass A3-skip A4-pass A5-n/a A6-n/a'
AGENT_MSG='feat: x

body

Decisions: t-0001
Gates-A: A1-pass A6-pass
Gates-A: A1-pass A2-pass A3-pass A4-pass A5-pass A6-pass
Co-Authored-By: a <a@example.com>
'

# A scratch repo with one staged file. $1 names it.
new_repo() {
  local d="$WORK/$1"
  mkdir -p "$d/.claude/.state" "$d/.claude/.automation/lib" "$d/.claude/hooks"
  git -C "$d" init -q
  git -C "$d" config user.email t@example.com; git -C "$d" config user.name t
  printf 'one\n' > "$d/a.txt"; git -C "$d" add a.txt
  REPO="$d"
}
# Record for the repo's current index ($1 = line, $2 = tree override).
record() {
  local tree="${2:-$(git -C "$REPO" write-tree)}"
  printf 'tree: %s\nline: %s\n' "$tree" "$1" > "$REPO/.claude/.state/gates-a-result"
}
# Run the script on a message; $1 = CLAUDECODE value ("" unsets it).
run_script() {
  printf '%s' "$AGENT_MSG" > "$REPO/msg"
  if [ -n "$1" ]; then
    (cd "$REPO" && CLAUDECODE="$1" bash "$SCRIPT" msg 2>"$REPO/err"); RC=$?
  else
    (cd "$REPO" && env -u CLAUDECODE bash "$SCRIPT" msg 2>"$REPO/err"); RC=$?
  fi
  MSG=$(cat "$REPO/msg")
  TRAILERS=$(git -C "$REPO" interpret-trailers --parse < "$REPO/msg")
}
ga_lines() { printf '%s\n' "$MSG" | grep -ciE '^gates-a[[:space:]]*:'; }

printf "\n# a record for exactly this tree\n"
new_repo match; record "$LINE"
run_script 1
_tap_eq "$RC" "0" "exits 0"
_tap_contains "$TRAILERS" "Gates-A: $LINE" "the trailer is the record's line"
_tap_eq "$(ga_lines)" "1" "every agent-written Gates-A line is gone; one remains"
_tap_contains "$TRAILERS" "Decisions: t-0001" "Decisions stays a trailer"
_tap_contains "$TRAILERS" "Co-Authored-By: a <a@example.com>" "Co-Authored-By stays a trailer"
_tap_contains "$MSG" "body" "the body is kept"
run_script ""
_tap_contains "$TRAILERS" "Gates-A: $LINE" "a human commit of the checked tree gets the line too"

printf "\n# no record, or a record for another tree\n"
new_repo other; record "$LINE" "0000000000000000000000000000000000000000"
run_script 1
_tap_contains "$TRAILERS" "Gates-A: unchecked" "another tree, agent commit: unchecked"
_tap_eq "$(ga_lines)" "1" "and the agent's lines are gone"
run_script ""
_tap_eq "$MSG" "$(printf '%s' "$AGENT_MSG")" "another tree, human commit: message untouched"
new_repo none
run_script 1
_tap_contains "$TRAILERS" "Gates-A: unchecked" "no record, agent commit: unchecked"
run_script ""
_tap_eq "$MSG" "$(printf '%s' "$AGENT_MSG")" "no record, human commit: message untouched"

printf "\n# a record that is not the gate's format\n"
new_repo forged; record 'A1-pass A2-pass A3-pass A4-pass A5-pass A6-pass
Evil: trailer'
run_script 1
_tap_contains "$TRAILERS" "Gates-A: A1-pass A2-pass A3-pass A4-pass A5-pass A6-pass" "a well-formed first line is used"
_tap_lacks "$MSG" "Evil" "nothing after the line is copied"
new_repo bad; record 'A1-pass A2-maybe A3-pass A4-pass A5-pass A6-pass'
run_script 1
_tap_contains "$TRAILERS" "Gates-A: unchecked" "an unknown outcome is not copied: unchecked"
new_repo short; record 'A1-pass'
run_script 1
_tap_contains "$TRAILERS" "Gates-A: unchecked" "a short line is not copied: unchecked"

printf "\n# failures never block\n"
new_repo nomsg
(cd "$REPO" && CLAUDECODE=1 bash "$SCRIPT" missing-file); _tap_eq "$?" "0" "a missing message file exits 0"
(cd "$WORK" && CLAUDECODE=1 bash "$SCRIPT" "$REPO/msg" 2>/dev/null); _tap_eq "$?" "0" "outside a git repo exits 0"
new_repo ro; record "$LINE"; printf '%s' "$AGENT_MSG" > "$REPO/msg"; chmod 444 "$REPO/msg"
(cd "$REPO" && CLAUDECODE=1 bash "$SCRIPT" msg 2>"$REPO/err"); RC=$?
_tap_eq "$RC" "0" "an unwritable message exits 0"
_tap_eq "$(cat "$REPO/msg")" "$(printf '%s' "$AGENT_MSG")" "and the message is unchanged"
chmod 644 "$REPO/msg"

printf "\n# real commits through the installed commit-msg hook\n"
install_hook() {
  cp "$HOOK" "$REPO/.git/hooks/commit-msg"; chmod +x "$REPO/.git/hooks/commit-msg"
  cp "$SCRIPT" "$REPO/.claude/.automation/lib/gates-a-trailer.sh"
  cp "$REAL_REPO/.claude/hooks/_secret-pattern.sh" "$REPO/.claude/hooks/_secret-pattern.sh"
}
commit_with() {  # $1 CLAUDECODE ("" unsets), $2.. extra commit args
  local cc="$1"; shift
  printf '%s' "$AGENT_MSG" > "$WORK/commit-msg-in"
  if [ -n "$cc" ]; then
    (cd "$REPO" && CLAUDECODE="$cc" git commit -q -F "$WORK/commit-msg-in" "$@" >/dev/null 2>&1); RC=$?
  else
    (cd "$REPO" && env -u CLAUDECODE git commit -q -F "$WORK/commit-msg-in" "$@" >/dev/null 2>&1); RC=$?
  fi
  TRAILERS=$(git -C "$REPO" log -1 --format='%(trailers)')
  MSG=$(git -C "$REPO" log -1 --format='%B')
}
new_repo real; install_hook; record "$LINE"
commit_with 1
_tap_eq "$RC" "0" "the commit succeeds"
_tap_contains "$TRAILERS" "Gates-A: $LINE" "the commit carries the gate's line"
_tap_eq "$(ga_lines)" "1" "and only that Gates-A line"
_tap_contains "$TRAILERS" "Decisions: t-0001" "with its other trailers"
printf 'two\n' > "$REPO/a.txt"; git -C "$REPO" add a.txt; record "$LINE"
printf 'three\n' > "$REPO/a.txt"
commit_with 1 -a
_tap_contains "$TRAILERS" "Gates-A: unchecked" "commit -a changes what is committed after the gate: unchecked"
printf 'four\n' > "$REPO/a.txt"; git -C "$REPO" add a.txt
commit_with ""
_tap_lacks "$TRAILERS" "unchecked" "a human commit with no matching record keeps its own lines"
_tap_contains "$TRAILERS" "Gates-A: A1-pass A6-pass" "its first line is still there"

printf "\n# the template\n"
_tap_contains "$(cat "$HOOK")" ".claude/.automation/lib/gates-a-trailer.sh" "commit-msg calls the synced script"
_tap_contains "$(cat "$REAL_REPO/.claude/hooks/pre-commit-gates.sh")" "_write_gates_a_record" "the commit gate saves the record"

printf "\n# %d passed, %d failed\n" "$_TAP_PASS" "$_TAP_FAIL"
if [ "$_TAP_FAIL" -gt 0 ]; then printf "%b" "$_TAP_FAILURES"; exit 1; fi
exit 0
