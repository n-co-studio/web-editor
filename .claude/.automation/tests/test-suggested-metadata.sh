#!/usr/bin/env bash
# Suggested project / milestone — Decision t-0081 (Massimo R4)
#
# In draft mode Prompt T suggests an existing project and milestone with
# `queue-cli.sh add ... --suggested`, which marks the entry
# `metadata_suggested: true` until the operator confirms or changes the value.
# Each case drives the real queue-cli.sh in a sandbox.
#
# Run against the code before t-0081 (verify-pristine) the cases fail: there is
# no --suggested flag and no metadata_suggested field.
# Bash 3.2 compatible.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/sandbox-setup.sh"

_TAP_NUM=0; _TAP_PASS=0; _TAP_FAIL=0; _TAP_FAILURES=""
_tap_pass() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_PASS=$((_TAP_PASS+1)); printf "ok %d - %s\n" "$_TAP_NUM" "$1"; }
_tap_fail() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_FAIL=$((_TAP_FAIL+1)); printf "not ok %d - %s\n" "$_TAP_NUM" "$1"; [ -n "${2:-}" ] && printf "  # %s\n" "$2"; _TAP_FAILURES="${_TAP_FAILURES}  FAIL: $1\n"; }
_tap_eq() { if [ "$1" = "$2" ]; then _tap_pass "$3"; else _tap_fail "$3" "expected '$2', got '$1'"; fi; }
_tap_contains() { case "$1" in *"$2"*) _tap_pass "$3" ;; *) _tap_fail "$3" "output did not contain '$2'" ;; esac; }

printf "# === Suggested project / milestone (Decision t-0081) ===\n"
setup_adversarial_sandbox
trap 'teardown_adversarial_sandbox' EXIT
# The sourced helpers turn errexit on; half the cases below assert a failure.
set +e
cd "$ADV_SANDBOX" || exit 1
cp "$_ADV_REAL_REPO/.claude/.automation/queue-cli.sh" "$ADV_SANDBOX/.claude/.automation/queue-cli.sh"
CLI="$ADV_SANDBOX/.claude/.automation/queue-cli.sh"
REG="$ADV_SANDBOX/docs/ai/project-registry.yaml"
Q="$ADV_SANDBOX/.claude/.automation/queue"
nb() {
  local f="$ADV_SANDBOX/.claude/.automation/briefs/sg-$RANDOM$RANDOM.md"
  printf '# %s\n\n## Goal\n\nFixture brief %s.\n' "$f" "$f" > "$f"
  printf '%s' "$f"
}
run() { OUT=$(bash "$CLI" "$@" 2>&1); RC=$?; ID=$(printf '%s\n' "$OUT" | sed -n 's/^entry_id: *//p' | head -1); }
efile() { ls "$Q"/*/"$1".yaml 2>/dev/null | head -1; }
sug() { sed -n 's/^  metadata_suggested: "\(.*\)"$/\1/p' "$(efile "$1")"; }
count() { ls "$Q"/*/*.yaml 2>/dev/null | wc -l | tr -d ' '; }
showsug() { bash "$CLI" --json show "$1" 2>/dev/null | grep -o '"metadata_suggested":[a-z]*'; }

printf "\n# --- refusals: nothing is queued ---\n"
N0=$(count)
run add --brief "$(nb)" --project "Core" --suggested
_tap_eq "$RC" "1" "--suggested with no registry is refused"
_tap_contains "$OUT" "no project registry" "...saying why"
_tap_eq "$(count)" "$N0" "...and queues nothing"
[ -f "$REG" ] && _tap_fail "...and creates no registry" || _tap_pass "...and creates no registry"

run projects add "Core" --milestone "Build" --milestone "Ship"
REG_BEFORE=$(cksum < "$REG")
run add --brief "$(nb)" --suggested
_tap_eq "$RC" "1" "--suggested without --project is refused"
run add --brief "$(nb)" --project "Guess" --suggested
_tap_eq "$RC" "1" "--suggested with an unregistered project is refused"
_tap_contains "$OUT" "not registered" "...saying why"
_tap_eq "$(count)" "$N0" "the refusals queue nothing"
_tap_eq "$(cksum < "$REG")" "$REG_BEFORE" "...and leave the registry unchanged (no auto-add of a guess)"

printf "\n# --- add --suggested marks the entry ---\n"
run add --brief "$(nb)" --project "core" --milestone-index 2 --suggested; S="$ID"
_tap_eq "$RC" "0" "--suggested with a registered project succeeds"
_tap_eq "$(sug "$S")" "true" "the entry is marked metadata_suggested: true"
_tap_eq "$(showsug "$S")" '"metadata_suggested":true' "show --json reports true"
_tap_contains "$(bash "$CLI" --json list 2>/dev/null)" '"metadata_suggested":true' "list --json reports true"
run add --brief "$(nb)" --project "Core"; P="$ID"
_tap_eq "$(sug "$P")" "false" "an add without --suggested is false"
_tap_eq "$(showsug "$P")" '"metadata_suggested":false' "...and show --json reports false"
SB=$(sed -n 's/^  brief_path: "\(.*\)"$/\1/p' "$(efile "$P")")
run add --brief "$SB" --project "Core" --suggested
_tap_eq "$ID" "$P" "re-adding a queued brief with --suggested returns the existing entry"
_tap_eq "$(sug "$P")" "false" "...and does not mark it: its metadata is not this add's"
_tap_contains "$OUT" "duplicate:$P" "...and still tells the user it was a duplicate"
ls "${TMPDIR:-/tmp}"/queue-add.* >/dev/null 2>&1 && _tap_fail "...and leaves no capture file behind" || _tap_pass "...and leaves no capture file behind"

printf "\n# --- confirming and changing ---\n"
run edit "$S" metadata_suggested false
_tap_eq "$RC" "0" "edit metadata_suggested false succeeds"
_tap_eq "$(sug "$S")" "false" "...and confirms the suggestion"
run edit "$S" metadata_suggested true
_tap_eq "$(sug "$S")" "true" "edit metadata_suggested true marks it again"
run edit "$S" milestone.index 1
_tap_eq "$RC" "0" "an edit of milestone.index succeeds"
_tap_eq "$(sug "$S")" "false" "...and clears the mark"
run edit "$S" metadata_suggested true
run edit "$S" project "CORE"
_tap_eq "$(sug "$S")" "false" "an edit of project clears the mark"
run edit "$S" metadata_suggested maybe
_tap_eq "$RC" "1" "a value other than true or false is refused"
run edit "$S" metadata_suggested true
run edit "$S" priority 4
_tap_eq "$(sug "$S")" "true" "an edit of another field keeps the mark"

printf "\n# --- follow-ups, older entries, running entries ---\n"
run follow-up-entry "$S" --brief "$(nb)"; F="$ID"
_tap_eq "$RC" "0" "a follow-up of a suggested entry is queued"
_tap_eq "$(sug "$F")" "false" "...and is not marked suggested"
OLD=$(efile "$P")
grep -v '^  metadata_suggested:' "$OLD" > "$OLD.x" && mv "$OLD.x" "$OLD"
_tap_eq "$(showsug "$P")" '"metadata_suggested":false' "an entry with no field (written before t-0081) reads as false"
run edit "$P" priority 3
_tap_eq "$RC" "0" "...round-trips through an edit"
_tap_eq "$(sug "$P")" "false" "...which writes the field as false"
mkdir -p "$Q/running"
RF=$(efile "$S"); sed 's/^  status: .*/  status: "running"/' "$RF" > "$Q/running/$S.yaml" && rm -f "$RF"
run edit "$S" metadata_suggested false
_tap_eq "$RC" "0" "metadata_suggested can be edited on a running entry"

printf "\n# --- Prompt T draft mode tells the agent to suggest only listed values ---\n"
PT="$_ADV_REAL_REPO/docs/ai/prompts/prompt-t-task-definition.md"
_tap_contains "$(cat "$PT")" "queue-cli.sh projects list" "Prompt T reads the registry before the draft add"
_tap_contains "$(cat "$PT")" "never invent a project or milestone" "...and never invents a value"
_tap_contains "$(cat "$PT")" "metadata_suggested true" "...and restores the mark after changing its own suggestion"

printf "\n# === Summary ===\n"
printf "1..%d\n" "$_TAP_NUM"
printf "# Passed: %d / %d\n" "$_TAP_PASS" "$_TAP_NUM"
if [ "$_TAP_FAIL" -gt 0 ]; then printf "# Failures:\n%b" "$_TAP_FAILURES"; exit 1; fi
exit 0
