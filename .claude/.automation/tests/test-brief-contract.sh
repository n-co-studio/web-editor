#!/usr/bin/env bash
# Queue-run contracts come from the brief — Decision t-0086
#
# A queue run that changes files (standard, hotfix, taskgroup) works to the
# file list in its brief's ### Task Contract block. queue-cli approve refuses a
# brief without one; the runner refuses again before launch, then writes the
# block to the run's task contract and binds it in plan-approved, so the agent
# cannot widen it. The commit gate side (refusing an edited contract, the
# out-of-scope escalation) is in layer3.
#
# runner.sh cannot be sourced (it runs its loop on load), so its two call sites
# are checked by position; the functions they call are run for real here.
#
# Run against the code before t-0086 (verify-pristine) the cases fail: the
# functions do not exist and approve takes any brief.
# Bash 3.2 compatible.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/sandbox-setup.sh"

_TAP_NUM=0; _TAP_PASS=0; _TAP_FAIL=0; _TAP_FAILURES=""
_tap_pass() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_PASS=$((_TAP_PASS+1)); printf "ok %d - %s\n" "$_TAP_NUM" "$1"; }
_tap_fail() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_FAIL=$((_TAP_FAIL+1)); printf "not ok %d - %s\n" "$_TAP_NUM" "$1"; [ -n "${2:-}" ] && printf "  # %s\n" "$2"; _TAP_FAILURES="${_TAP_FAILURES}  FAIL: $1\n"; }
_tap_eq() { if [ "$1" = "$2" ]; then _tap_pass "$3"; else _tap_fail "$3" "expected '$2', got '$1'"; fi; }
_tap_contains() { case "$1" in *"$2"*) _tap_pass "$3" ;; *) _tap_fail "$3" "output did not contain '$2': $1" ;; esac; }

printf "# === Queue-run contracts from briefs (Decision t-0086) ===\n"
setup_adversarial_sandbox
trap 'teardown_adversarial_sandbox' EXIT
set +e
cd "$ADV_SANDBOX" || exit 1
cp "$_ADV_REAL_REPO/.claude/.automation/queue-cli.sh" "$ADV_SANDBOX/.claude/.automation/queue-cli.sh"
CLI="$ADV_SANDBOX/.claude/.automation/queue-cli.sh"
Q="$ADV_SANDBOX/.claude/.automation/queue"
BRIEFS="$ADV_SANDBOX/.claude/.automation/briefs"
mkdir -p "$BRIEFS"

CONTRACT='brief_id: "bc"
goal: "g"
scope_files:
  - "src/a.ts"
  - "docs/b.md"
verification:
  - "v1"
lifecycle: task-scoped'

# A brief; $1 = name, $2 = contract body ("" for no Task Contract section).
brief() {
  local f="$BRIEFS/$1.md"
  {
    printf '# %s\n\n## Goal\n\nFixture.\n\n' "$1"
    if [ -n "$2" ]; then
      printf '### Task Contract\n\n```yaml\n%s\n```\n\n### Notes\n\n```yaml\nscope_files:\n  - "not/this.ts"\n```\n' "$2"
    fi
  } > "$f"
  printf '.claude/.automation/briefs/%s.md' "$1"
}
lib() { (REPO_ROOT="$ADV_SANDBOX"; source "$ADV_SANDBOX/.claude/hooks/_analytics-helper.sh" >/dev/null 2>&1
         source "$ADV_SANDBOX/.claude/.automation/lib/queue-manager.sh" >/dev/null 2>&1; "$@"); }
run() { OUT=$(bash "$CLI" "$@" 2>&1); RC=$?; ID=$(printf '%s\n' "$OUT" | sed -n 's/^entry_id: *//p' | head -1); }
status_of() { basename "$(dirname "$(ls "$Q"/*/"$1".yaml 2>/dev/null | head -1)")"; }

B_OK=$(brief ok "$CONTRACT")
B_NONE=$(brief none "")
B_EMPTY=$(brief empty 'brief_id: "e"
goal: "g"
scope_files: []
verification:
  - "v"')
B_UNFENCED="$BRIEFS/unfenced.md"
printf '# u\n\n### Task Contract\n\nscope_files:\n  - "src/a.ts"\n' > "$B_UNFENCED"; B_UNFENCED=.claude/.automation/briefs/unfenced.md

printf "\n# reading the brief\n"
_tap_eq "$(lib queue_brief_contract "$B_OK")" "$CONTRACT" "the Task Contract block is read verbatim, and only that block"
lib queue_brief_has_scope "$B_OK"; _tap_eq "$?" "0" "a block with scope_files has a scope"
lib queue_brief_has_scope "$B_NONE"; _tap_eq "$?" "1" "no Task Contract section: no scope (a later section's list is not used)"
lib queue_brief_has_scope "$B_EMPTY"; _tap_eq "$?" "1" "scope_files: [] is no scope"
lib queue_brief_has_scope "$B_UNFENCED"; _tap_eq "$?" "1" "a section with no fenced block is no scope"
lib queue_brief_has_scope ".claude/.automation/briefs/missing.md"; _tap_eq "$?" "1" "a missing brief is no scope"
for t in standard hotfix taskgroup; do
  lib queue_entry_contract_ok "$t" "$B_NONE"; _tap_eq "$?" "1" "$t needs a file list"
done
for t in finish-loop spec-fresh governance; do
  lib queue_entry_contract_ok "$t" "$B_NONE"; _tap_eq "$?" "0" "$t does not"
done
_reason() { queue_entry_contract_ok "$1" "$2" || true; printf '%s' "$QUEUE_CONTRACT_MISSING_MSG"; }
_tap_contains "$(lib _reason standard "$B_NONE")" "$B_NONE lists no scope_files" "the reason names the brief"

printf "\n# queue-cli approve asks when the list is missing\n"
run add --brief "$B_NONE" --session-type standard
N=$ID
run approve "$N"
_tap_eq "$RC" "1" "approve refuses a standard entry whose brief has no scope_files"
_tap_contains "$OUT" "lists no scope_files" "...saying why"
_tap_contains "$OUT" "$B_NONE" "...naming the brief"
_tap_eq "$(status_of "$N")" "pending-review" "...and the entry stays pending"
run add --brief "$B_EMPTY" --session-type hotfix
run approve "$ID"; _tap_eq "$RC" "1" "approve refuses a hotfix entry with an empty list"
run add --brief "$B_OK" --session-type standard
OKID=$ID
run approve "$OKID"
_tap_eq "$RC" "0" "approve takes a brief with scope_files"
_tap_eq "$(status_of "$OKID")" "approved" "...and the entry is approved"
run add --brief "$(brief fl "")" --session-type finish-loop
run approve "$ID"; _tap_eq "$RC" "0" "a finish-loop entry needs no file list"

printf "\n# the runner writes and binds the contract\n"
WT="$ADV_SANDBOX/wt"; mkdir -p "$WT/.claude/.state/wt-sessions/s1"
PA="$WT/.claude/.state/wt-sessions/s1/plan-approved"
printf 'timestamp: t\nsession_id: s1\nsource: runner\ncontract_sha: stale\n' > "$PA"
lib runner_install_brief_contract "$WT" "$B_OK" "$PA"; RC=$?
TC="$WT/.claude/local/task-contract.yaml"
_tap_eq "$RC" "0" "install succeeds for a brief with scope_files"
_tap_contains "$(cat "$TC")" "$CONTRACT" "the contract is the brief's block"
_tap_contains "$(head -2 "$TC")" "do not edit it" "...headed as the runner's"
_digest() { portable_hash < "$1" | cut -c1-16; }
SHA=$(lib _digest "$TC")
_tap_eq "$(sed -n 's/^contract_sha: //p' "$PA")" "$SHA" "plan-approved binds the digest the commit gate checks"
_tap_eq "$(grep -c '^contract_sha:' "$PA")" "1" "...replacing any earlier one"
_tap_contains "$(cat "$PA")" "source: runner" "...and keeping the rest"
printf 'scope_files:\n  - "old.ts"\n' > "$TC"
lib runner_install_brief_contract "$WT" "$B_OK" "$PA"
_tap_contains "$(cat "$TC")" "src/a.ts" "a previous brief's contract in a reused worktree is overwritten"
cp "$TC" "$ADV_SANDBOX/tc.before"
lib runner_install_brief_contract "$WT" "$B_NONE" "$PA"; RC=$?
_tap_eq "$RC" "1" "a brief with no scope_files is refused"
_tap_eq "$(cat "$TC")" "$(cat "$ADV_SANDBOX/tc.before")" "...and writes nothing"
lib runner_install_brief_contract "$WT" "$B_OK" "$WT/no-such-plan-approved"; RC=$?
_tap_eq "$RC" "1" "with no plan-approved to bind to, install is refused (never installed unbound)"
: > "$ADV_SANDBOX/empty-pa"
lib runner_install_brief_contract "$WT" "$B_OK" "$ADV_SANDBOX/empty-pa"; RC=$?
_tap_eq "$RC" "1" "an empty plan-approved is refused, not rewritten to one line"
_tap_eq "$(wc -c < "$ADV_SANDBOX/empty-pa" | tr -d ' ')" "0" "...and is left as it was"
WT2="$ADV_SANDBOX/wt2"; mkdir -p "$WT2/.claude" "$ADV_SANDBOX/elsewhere"
ln -s "$ADV_SANDBOX/elsewhere" "$WT2/.claude/local"
lib runner_install_brief_contract "$WT2" "$B_OK" "$PA"; RC=$?
_tap_eq "$RC" "1" "a symlinked .claude/local is refused"
[ -e "$ADV_SANDBOX/elsewhere/task-contract.yaml" ] && _tap_fail "...and nothing is written through it" \
  || _tap_pass "...and nothing is written through it"
rm -f "$TC"; ln -s "$ADV_SANDBOX/elsewhere/target" "$TC"
lib runner_install_brief_contract "$WT" "$B_OK" "$PA"; RC=$?
_tap_eq "$RC" "0" "a contract path left as a symlink is replaced ..."
[ -e "$ADV_SANDBOX/elsewhere/target" ] && _tap_fail "...not written through" || _tap_pass "...not written through"
[ -L "$TC" ] && _tap_fail "...and is a regular file afterwards" || _tap_pass "...and is a regular file afterwards"

printf "\n# runner.sh wiring\n"
RUNNER="$_ADV_REAL_REPO/.claude/.automation/runner.sh"
CHECK=$(grep -n 'queue_entry_contract_ok "\$ENTRY_SESSION_TYPE" "\$ENTRY_BRIEF_PATH"' "$RUNNER" | head -1 | cut -d: -f1)
BLOCK=$(grep -n 'queue_block "\$ENTRY_ID" "\$QUEUE_CONTRACT_MISSING_MSG"' "$RUNNER" | head -1 | cut -d: -f1)
LAUNCH=$(grep -n '_run_single_entry "\$ENTRY_ID"' "$RUNNER" | head -1 | cut -d: -f1)
_tap_eq "$([ -n "$CHECK" ] && [ -n "$BLOCK" ] && [ "$CHECK" -lt "$BLOCK" ] && [ "$BLOCK" -lt "${LAUNCH:-0}" ] && echo yes)" "yes" \
  "the main loop checks the brief and blocks the entry before it starts a session"
INSTALL=$(grep -n 'runner_install_brief_contract "\$launch_dir"' "$RUNNER" | head -1 | cut -d: -f1)
BG=$(grep -n 'Launch headless session in background' "$RUNNER" | head -1 | cut -d: -f1)
WTSET=$(grep -n 'launch_dir="\$worktree_dir"' "$RUNNER" | head -1 | cut -d: -f1)
_tap_eq "$([ -n "$INSTALL" ] && [ "$WTSET" -lt "$INSTALL" ] && [ "$INSTALL" -lt "$BG" ] && echo yes)" "yes" \
  "the contract is installed after the worktree is set and before the agent launches"

printf "\n# %d passed, %d failed\n" "$_TAP_PASS" "$_TAP_FAIL"
if [ "$_TAP_FAIL" -gt 0 ]; then printf "%b" "$_TAP_FAILURES"; exit 1; fi
exit 0
