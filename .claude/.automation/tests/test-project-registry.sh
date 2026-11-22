#!/usr/bin/env bash
# Project registry — Decision t-0079 (Massimo R1)
#
# docs/ai/project-registry.yaml holds the repo's projects and their ordered
# milestones. queue-cli reads it on add, follow-up-entry and edit of project /
# milestone.* fields, and `projects list|add` manage it. Each case drives the
# real queue-cli.sh in a sandbox, so the suite is also its syntax check.
#
# Run against the code before t-0079 (verify-pristine) every case that needs the
# registry fails: there is no `projects` subcommand and add ignores the file.
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

printf "# === Project registry (Decision t-0079) ===\n"
setup_adversarial_sandbox
trap 'teardown_adversarial_sandbox' EXIT
# The sourced helpers turn errexit on; half the cases below assert a failure.
set +e
cd "$ADV_SANDBOX" || exit 1
cp "$_ADV_REAL_REPO/.claude/.automation/queue-cli.sh" "$ADV_SANDBOX/.claude/.automation/queue-cli.sh"
CLI="$ADV_SANDBOX/.claude/.automation/queue-cli.sh"
REG="$ADV_SANDBOX/docs/ai/project-registry.yaml"
Q="$ADV_SANDBOX/.claude/.automation/queue"
# A fresh brief per add: queue-cli returns the existing entry for a brief that
# is already queued, which would hide what each case did.
nb() {
  local f="$ADV_SANDBOX/.claude/.automation/briefs/pr-$RANDOM$RANDOM.md"
  printf '# %s\n\n## Goal\n\nFixture brief %s.\n' "$f" "$f" > "$f"
  printf '%s' "$f"
}

# Run queue-cli; sets RC, OUT (stdout+stderr) and ID (entry_id, if any).
run() { OUT=$(bash "$CLI" "$@" 2>&1); RC=$?; ID=$(printf '%s\n' "$OUT" | sed -n 's/^entry_id: *//p' | head -1); }
pending() { ls "$Q/pending-review" 2>/dev/null | wc -l | tr -d ' '; }
field() {   # field <entry-id> project|name|index|total
  local f; f=$(ls "$Q"/*/"$1".yaml 2>/dev/null | head -1)
  case "$2" in
    project) sed -n 's/^  project: "\(.*\)"$/\1/p' "$f" ;;
    name)    sed -n 's/^    name: "\(.*\)"$/\1/p' "$f" ;;
    index)   sed -n 's/^    index: //p' "$f" ;;
    total)   sed -n 's/^    total: //p' "$f" ;;
  esac
}

printf "\n# --- no registry: behaviour as before ---\n"
run add --brief "$(nb)" --project "Anything" --milestone-name "m" --milestone-index 3 --milestone-total 9
_tap_eq "$RC" "0" "add with no registry succeeds"
_tap_eq "$(field "$ID" index)/$(field "$ID" total)" "3/9" "...and keeps the milestone fields as given"
[ -f "$REG" ] && _tap_fail "...and creates no registry file" || _tap_pass "...and creates no registry file"

printf "\n# --- projects add / list ---\n"
run projects add "Massimo App" --milestone "Foundations" --milestone "Editor"
_tap_eq "$RC" "0" "projects add succeeds"
_tap_contains "$(cat "$REG" 2>/dev/null)" 'schema_version: "1.0.0"' "the registry is created with schema_version 1.0.0"
_tap_contains "$(cat "$REG" 2>/dev/null)" "      - index: 2" "milestones are numbered in order"
run projects add "  massimo   APP "
_tap_eq "$RC" "3" "a case/spacing variant of a registered name exits 3"
_tap_contains "$OUT" "NAME_TAKEN: Massimo App" "...and prints NAME_TAKEN with the registered name"
run projects list
_tap_contains "$OUT" "Massimo App" "projects list prints the project"
_tap_contains "$OUT" "  2. Editor" "...and its numbered milestones"

printf "\n# --- add against the registry ---\n"
run add --brief "$(nb)" --project "MASSIMOAPP" --milestone-index 2
_tap_eq "$RC" "0" "add with a spelling variant succeeds"
P_ID="$ID"
_tap_eq "$(field "$P_ID" project)" "Massimo App" "the registry's spelling is stored"
_tap_eq "$(field "$P_ID" name)/$(field "$P_ID" total)" "Editor/2" "the milestone name and total are filled from the registry"
_tap_contains "$OUT" "registered as 'Massimo App'" "...with a note that the spelling changed"
run add --brief "$(nb)" --project "Massimo App" --milestone-name "editor"
_tap_eq "$(field "$ID" index)" "2" "a milestone given by name alone resolves to its index"

n0=$(pending)
run add --brief "$(nb)" --project "Massimo App" --milestone-index 3
_tap_eq "$RC" "1" "a milestone index past the last one is an error"
_tap_eq "$(pending)" "$n0" "...and enqueues nothing"
run add --brief "$(nb)" --project "Massimo App" --milestone-index 1 --milestone-name "Editor"
_tap_eq "$RC" "1" "a milestone name that does not match its index is an error"
run add --brief "$(nb)" --project "Massimo App" --milestone-index 1 --milestone-total 5
_tap_eq "$RC" "1" "a wrong milestone total is an error"
_tap_eq "$(pending)" "$n0" "...none of the refused adds enqueued anything"

run add --brief "$(nb)" --project "Atlas" --milestone-index 4 --milestone-name "free" --milestone-total 6
_tap_eq "$RC" "0" "an unknown project is accepted"
_tap_contains "$OUT" "was not in the registry — added it" "...with a note naming it, so a typo is visible"
_tap_eq "$(field "$ID" index)/$(field "$ID" total)" "4/6" "...and its milestone fields stand (no milestones registered)"
run projects list
_tap_contains "$OUT" "Atlas" "...and it is now in the registry"

printf "\n# --- follow-up-entry ---\n"
run follow-up-entry "$P_ID" --brief "$(nb)" --milestone-index 3
_tap_eq "$RC" "1" "a follow-up with an out-of-range milestone is refused"
# Rename milestone 2 in the file, as an outside writer would.
sed 's/"Editor"/"Editor v2"/' "$REG" > "$REG.new" && mv "$REG.new" "$REG"
run follow-up-entry "$P_ID" --brief "$(nb)"
_tap_eq "$RC" "0" "a follow-up inheriting its parent's milestone succeeds"
_tap_eq "$(field "$ID" name)" "Editor v2" "...and its inherited milestone name is refilled from the registry"

printf "\n# --- edit ---\n"
run edit "$P_ID" milestone.index 1
_tap_eq "$RC" "0" "edit of milestone.index succeeds"
_tap_eq "$(field "$P_ID" name)/$(field "$P_ID" total)" "Foundations/2" "...and the name and total follow from the registry"
run edit "$P_ID" milestone.name "Nope"
_tap_eq "$RC" "1" "edit to a milestone name the registry does not have at that index is refused"
_tap_eq "$(field "$P_ID" name)" "Foundations" "...and changes nothing"
run edit "$P_ID" project "  atlas"
_tap_eq "$(field "$P_ID" project)" "Atlas" "edit of project stores the registry's spelling"

printf "\n# --- names with quotes and colons ---\n"
run projects add 'He said "hi": ok' --milestone 'a: "b"'
_tap_eq "$RC" "0" "a name with quotes and a colon is accepted"
run projects list
_tap_contains "$OUT" 'He said "hi": ok' "...and reads back exactly"
_tap_contains "$OUT" '  1. a: "b"' "...its milestone too"

printf "\n# --- another writer between read and write ---\n"
# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/.automation/lib/queue-manager.sh"
# queue-manager.sh turns errexit back on; off again before a source that is
# absent on the pre-t-0079 code, so a pristine run reports every case.
set +e
# shellcheck disable=SC1091
source "$ADV_SANDBOX/.claude/.automation/lib/project-registry.sh" 2>/dev/null
REPO_ROOT="$ADV_SANDBOX"
project_registry_load
printf '  - name: "Outsider"\n    milestones: []\n' >> "$REG"
project_registry_autoadd "Late" 2>/dev/null
run projects list
_tap_contains "$OUT" "Outsider" "a project another writer added after our read is kept"
_tap_contains "$OUT" "Late" "...alongside the one we added"

printf "\n# --- follow-ups that leave the parent's milestone ---\n"
run add --brief "$(nb)" --project "Massimo App" --milestone-index 1
P2="$ID"
run follow-up-entry "$P2" --brief "$(nb)" --milestone-name "editor v2"
_tap_eq "$RC" "0" "a follow-up naming another milestone without an index is accepted"
_tap_eq "$(field "$ID" index)/$(field "$ID" name)" "2/Editor v2" "...and moves to that milestone"
run follow-up-entry "$P2" --brief "$(nb)" --project "massimo  APP"
_tap_eq "$(field "$ID" index)/$(field "$ID" project)" "1/Massimo App" "a follow-up retyping its parent's project in another spelling keeps the milestone"
run projects add "Twin" --milestone "Alpha" --milestone " alpha"
_tap_eq "$RC" "1" "projects add refuses two milestones whose names match"
run follow-up-entry "$P2" --brief "$(nb)" --project "Atlas"
_tap_eq "$RC" "0" "a follow-up moved to another project is accepted"
_tap_eq "$(field "$ID" index)/$(field "$ID" total)" "0/0" "...and does not carry the parent's milestone into it"

printf "\n# --- an add of a brief already queued registers nothing ---\n"
DUP=$(nb)
run add --brief "$DUP" --project "Massimo App"
DUP_ID="$ID"
run add --brief "$DUP" --project "Zeta Unseen"
_tap_eq "$RC/$ID" "0/$DUP_ID" "a duplicate add succeeds and returns the existing entry"
run projects list
case "$OUT" in *"Zeta Unseen"*) _tap_fail "a duplicate add does not register its project" ;; *) _tap_pass "a duplicate add does not register its project" ;; esac

printf "\n# --- names are one line ---\n"
run add --brief "$(nb)" --project $'two\nlines'
_tap_eq "$RC" "1" "a project name with a newline is refused"
run projects add $'two\nlines'
_tap_eq "$RC" "1" "...by projects add too"
run projects list
_tap_eq "$RC" "0" "...and the registry is still readable"

printf "\n# --- layout edges ---\n"
cp "$REG" "$REG.keep"
cp "$ADV_SANDBOX/.claude/.automation/schemas/project-registry.yaml" "$REG"
run projects list
_tap_contains "$OUT" "  1. First" "the schema file's own example parses as a registry"
printf 'schema_version: "1.0.0"\r\nprojects:\r\n  - name: "Crlf"   \r\n    milestones: []\r\n' > "$REG"
run projects list
_tap_contains "$OUT" "Crlf" "CRLF line ends and trailing spaces are tolerated"
printf 'schema_version: "1.0.0"\nprojects:\n  - name: "Foo"  # a note\n    milestones: []\n' > "$REG"
run add --brief "$(nb)" --project "Foo"
_tap_eq "$RC" "1" "a trailing comment after a quoted name is refused, not read into the name"
cp "$REG.keep" "$REG"

printf "\n# --- a registry that cannot be read is an error, never absent ---\n"
cp "$REG" "$REG.good"
sed 's/^schema_version: .*/schema_version: "2.0.0"/' "$REG.good" > "$REG"
n0=$(pending)
run add --brief "$(nb)" --project "Atlas"
_tap_eq "$RC" "1" "an unsupported schema_version refuses the add"
_tap_contains "$OUT" "not supported" "...and says why"
{ cat "$REG.good"; printf '  - name: "massimo app"\n    milestones: []\n'; } > "$REG"
run add --brief "$(nb)" --project "Atlas"
_tap_eq "$RC" "1" "two projects with the same normalised name refuse the add"
printf 'schema_version: "1.0.0"\nprojects:\n  - name: "Gap"\n    milestones:\n      - index: 1\n        name: "a"\n      - index: 3\n        name: "c"\n' > "$REG"
run add --brief "$(nb)" --project "Gap"
_tap_eq "$RC" "1" "a gap in milestone indexes refuses the add"
_tap_eq "$(pending)" "$n0" "...and no refused add enqueued anything"

printf "\n1..%d\n# passed %d, failed %d\n" "$_TAP_NUM" "$_TAP_PASS" "$_TAP_FAIL"
if [ "$_TAP_FAIL" -gt 0 ]; then printf "\n# Failures:\n%b" "$_TAP_FAILURES"; exit 1; fi
exit 0
