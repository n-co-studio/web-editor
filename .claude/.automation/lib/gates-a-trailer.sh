#!/usr/bin/env bash
# gates-a-trailer.sh — set a commit's Gates-A trailer from what the commit gate
# actually checked (Decision t-0086).
#
# Called by the git commit-msg hook with the message file. pre-commit-gates.sh
# saves .claude/.state/gates-a-result on every commit it allows: the staged tree
# it checked and one outcome per A check. .claude/.state is closed to agent
# writes, so the record is the gate's word, not the agent's.
#
#   record for exactly this tree    → Gates-A: <the record's line>
#   no record, or another tree,
#     in an agent commit            → Gates-A: unchecked
#     in a human commit             → message left alone
#
# Either way an agent-written Gates-A trailer is replaced. "Another tree" is
# what a `git add` chained into the commit call or `git commit -a` produces:
# the gate ran before those staged anything, so it did not check this content.
# The record is not consumed (the sandbox cannot delete under .claude/.state);
# a second commit of the identical tree would carry the same, still true, line.
#
# Never blocks: any failure leaves the message as it was and says so.
set -uo pipefail

MSG_FILE="${1:-}"
[ -n "$MSG_FILE" ] && [ -f "$MSG_FILE" ] || exit 0
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
RECORD="$ROOT/.claude/.state/gates-a-result"
OUTCOME='(pass|n/a|skip|advisory)'

line=""
if [ -f "$RECORD" ]; then
  rec_tree=$(sed -n 's/^tree: //p' "$RECORD" 2>/dev/null | head -1)
  rec_line=$(sed -n 's/^line: //p' "$RECORD" 2>/dev/null | head -1)
  # write-tree honours GIT_INDEX_FILE, so this is the tree being committed.
  now_tree=$(git write-tree 2>/dev/null || true)
  if [ -n "$rec_tree" ] && [ "$rec_tree" = "$now_tree" ] \
     && printf '%s\n' "$rec_line" | grep -qE "^A1-$OUTCOME A2-$OUTCOME A3-$OUTCOME A4-$OUTCOME A5-$OUTCOME A6-$OUTCOME\$"; then
    line="$rec_line"
  fi
fi
if [ -z "$line" ]; then
  [ "${CLAUDECODE:-}" = "1" ] || exit 0
  line="unchecked"
fi

tmp=$(mktemp "$MSG_FILE.gates-a.XXXXXX" 2>/dev/null) || {
  echo "gates-a-trailer: could not set the Gates-A trailer; the message is unchanged" >&2; exit 0; }
# Every existing Gates-A line goes first: `--if-exists replace` removes only one,
# so a second written line would survive it.
if grep -viE '^gates-a[[:space:]]*:' "$MSG_FILE" \
     | git interpret-trailers --if-exists replace --if-missing add \
         --trailer "Gates-A: $line" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
  cat "$tmp" > "$MSG_FILE"
else
  echo "gates-a-trailer: could not set the Gates-A trailer; the message is unchanged" >&2
fi
rm -f "$tmp"
exit 0
