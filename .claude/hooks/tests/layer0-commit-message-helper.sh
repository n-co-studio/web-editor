#!/usr/bin/env bash
# Unit tests for _commit-message-helper.sh.
#
# Layer 0: pure functions, no git repo, no hook payload. The integration-level
# behaviour is covered by gate-conformance.sh C8a-C8e; this file pins the
# resolution rules themselves, including the ones that must NOT fire.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../_commit-message-helper.sh"

PASS=0; FAIL=0
eq()  { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'ok   %s\n' "$1";
        else FAIL=$((FAIL+1)); printf 'FAIL %s\n       want [%s]\n       got  [%s]\n' "$1" "$3" "$2"; fi; }
has() { if printf '%s' "$2" | grep -q "$3"; then PASS=$((PASS+1)); printf 'ok   %s\n' "$1";
        else FAIL=$((FAIL+1)); printf 'FAIL %s\n       [%s] does not contain [%s]\n' "$1" "$2" "$3"; fi; }
hasnt() { if printf '%s' "$2" | grep -q "$3"; then FAIL=$((FAIL+1)); printf 'FAIL %s\n       [%s] unexpectedly contains [%s]\n' "$1" "$2" "$3";
        else PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
MSG="$TMP/msg.txt"; printf 'feat: thing\n\nDecisions: 0051, 0052\n' > "$MSG"
BAIT="$TMP/notes";  printf 'Decisions: 9999\n' > "$BAIT"

printf '# _commit-message-helper — resolution rules\n\n'

# --- inline messages: behaviour must be exactly as before ---
has   "-m inline trailer is found" \
      "$(extract_trailer "$(resolve_commit_text 'git commit -m "x" -m "Decisions: 0004"')" 'Decisions')" \
      "Decisions: 0004"
has   "multi-line -m trailer is found" \
      "$(extract_trailer "$(resolve_commit_text 'git commit -m "body
Decisions: 0007"')" 'Decisions')" "Decisions: 0007"
eq    "absent trailer stays absent" \
      "$(extract_trailer "$(resolve_commit_text 'git commit -m "nope"')" 'Decisions')" ""

# --- -F: the defect this fixes ---
has   "-F file trailer is found" \
      "$(extract_trailer "$(resolve_commit_text "git commit -F $MSG")" 'Decisions')" \
      "Decisions: 0051, 0052"
has   "--file= trailer is found" \
      "$(extract_trailer "$(resolve_commit_text "git commit --file=$MSG")" 'Decisions')" \
      "Decisions: 0051, 0052"

# --- the evasion path that must NOT exist ---
# A -F-shaped substring inside a quoted -m message must never cause a file read:
# git refuses -m with -F, so such text is message content, not a flag.
cd "$TMP" || exit 1
hasnt "a -F shape inside an -m message does not read that file" \
      "$(resolve_commit_text 'git commit -m "see -F notes"')" "Decisions: 9999"
hasnt "a --file= shape inside an -m message does not read that file" \
      "$(resolve_commit_text 'git commit -m "try --file=notes"')" "Decisions: 9999"
# Bundled short-option clusters. An earlier anchor enumerated -m/-am/-ma with
# trailing spaces; `git commit -sm "..."` walked straight through it. The rule
# is "any short cluster containing m", so each of these must be inert.
hasnt "-sm (sign-off bundled with message)" \
      "$(resolve_commit_text 'git commit -sm "see -F notes"')" "Decisions: 9999"
hasnt "-qm (quiet bundled with message)" \
      "$(resolve_commit_text 'git commit -qm "see -F notes"')" "Decisions: 9999"
hasnt "-am with no space before the text" \
      "$(resolve_commit_text 'git commit -am"see -F notes"')" "Decisions: 9999"
hasnt "-ma (reversed cluster)" \
      "$(resolve_commit_text 'git commit -ma "see -F notes"')" "Decisions: 9999"
hasnt "--message= long form" \
      "$(resolve_commit_text 'git commit --message="see -F notes"')" "Decisions: 9999"
# git accepts any unambiguous abbreviation of a long option — --m, --me, --mes
# and --mess were all verified to work against real git. A literal --message
# check missed every one, which is the long-option twin of the short-cluster
# enumeration above. No other `git commit` long option starts with m.
hasnt "--mess= abbreviation" \
      "$(resolve_commit_text 'git commit --mess="see -F notes"')" "Decisions: 9999"
hasnt "--mes= abbreviation" \
      "$(resolve_commit_text 'git commit --mes="see -F notes"')" "Decisions: 9999"
hasnt "--me= abbreviation" \
      "$(resolve_commit_text 'git commit --me="see -F notes"')" "Decisions: 9999"
hasnt "--m= shortest abbreviation" \
      "$(resolve_commit_text 'git commit --m="see -F notes"')" "Decisions: 9999"
cd - >/dev/null || exit 1

# --- the anchor must not suppress a genuine -F read ---
has   "-s -F still reads the file (no m cluster)" \
      "$(extract_trailer "$(resolve_commit_text "git commit -s -F $MSG")" 'Decisions')" \
      "Decisions: 0051, 0052"
has   "--amend -F still reads the file" \
      "$(extract_trailer "$(resolve_commit_text "git commit --amend -F $MSG")" 'Decisions')" \
      "Decisions: 0051, 0052"
# --file abbreviations git actually accepts. --fi and --f are rejected by git
# itself as ambiguous with --fixup, so --fil is the shortest real form.
has   "--file (space form) reads the file" \
      "$(extract_trailer "$(resolve_commit_text "git commit --file $MSG")" 'Decisions')" \
      "Decisions: 0051, 0052"
has   "--fil abbreviation reads the file" \
      "$(extract_trailer "$(resolve_commit_text "git commit --fil $MSG")" 'Decisions')" \
      "Decisions: 0051, 0052"
has   "--fil= abbreviation reads the file" \
      "$(extract_trailer "$(resolve_commit_text "git commit --fil=$MSG")" 'Decisions')" \
      "Decisions: 0051, 0052"

# Forms git itself rejects must not be recognised either — the helper should
# claim exactly the grammar git has, no wider. `[Ff](ile|il)?` once accepted
# bare `--f` and lowercase `-f`, which git has no option for.
eq    "--f is not recognised (git rejects it as ambiguous)" \
      "$(extract_trailer "$(resolve_commit_text "git commit --f $MSG")" 'Decisions')" ""
eq    "lowercase -f is not recognised (no such git option)" \
      "$(extract_trailer "$(resolve_commit_text "git commit -f $MSG")" 'Decisions')" ""
eq    "--fi is not recognised (ambiguous with --fixup)" \
      "$(extract_trailer "$(resolve_commit_text "git commit --fi $MSG")" 'Decisions')" ""

# A dash-leading path containing `m` trips the message anchor and suppresses the
# read. Safe (falls back to the command string) but inert — pinned so the
# behaviour is a known property rather than a surprise.
eq    "dash-leading path containing m falls back, does not error" \
      "$(extract_trailer "$(resolve_commit_text 'git commit -F -my-notes.txt')" 'Decisions')" ""

# --- unresolvable inputs fall back to the command string, never error ---
eq    "-F with a file that does not exist yet" \
      "$(extract_trailer "$(resolve_commit_text 'git commit -F /nonexistent/m.txt')" 'Decisions')" ""
eq    "-F - (message on stdin)" \
      "$(extract_trailer "$(resolve_commit_text 'git commit -F -')" 'Decisions')" ""
eq    "-F pointing at a directory" \
      "$(extract_trailer "$(resolve_commit_text "git commit -F $TMP")" 'Decisions')" ""
eq    "-F as the last token with no argument" \
      "$(extract_trailer "$(resolve_commit_text 'git commit -F')" 'Decisions')" ""

# --- extract_trailer is key-scoped ---
eq    "a different key is not matched" \
      "$(extract_trailer "$(resolve_commit_text "git commit -F $MSG")" 'Overrides')" ""

printf '\npassed %d  failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
