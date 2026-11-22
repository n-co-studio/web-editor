#!/usr/bin/env bash
# Milestone plans — Decision t-0080 (Massimo R2, R3)
#
# `queue-cli.sh milestones <project> --file <plan.yaml> [--dry-run]` applies a
# project's new milestone list (add, rename, reorder, delete with a move) and an
# optional project rename to the registry and to every entry, in all statuses,
# and every work order in the project, all or nothing. `edit` of project and
# milestone.* is allowed on running entries. Each case drives the real
# queue-cli.sh in a sandbox.
#
# Run against the code before t-0080 (verify-pristine) the plan cases fail: there
# is no `milestones` subcommand, and edit refuses every running entry.
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

printf "# === Milestone plans (Decision t-0080) ===\n"
setup_adversarial_sandbox
trap 'chmod -R u+w "$ADV_SANDBOX" 2>/dev/null; teardown_adversarial_sandbox' EXIT
# The sourced helpers turn errexit on; half the cases below assert a failure.
set +e
cd "$ADV_SANDBOX" || exit 1
cp "$_ADV_REAL_REPO/.claude/.automation/queue-cli.sh" "$ADV_SANDBOX/.claude/.automation/queue-cli.sh"
CLI="$ADV_SANDBOX/.claude/.automation/queue-cli.sh"
REG="$ADV_SANDBOX/docs/ai/project-registry.yaml"
Q="$ADV_SANDBOX/.claude/.automation/queue"
PLAN="$ADV_SANDBOX/plan.yaml"
nb() {
  local f="$ADV_SANDBOX/.claude/.automation/briefs/mp-$RANDOM$RANDOM.md"
  printf '# %s\n\n## Goal\n\nFixture brief %s.\n' "$f" "$f" > "$f"
  printf '%s' "$f"
}
run() { OUT=$(bash "$CLI" "$@" 2>&1); RC=$?; ID=$(printf '%s\n' "$OUT" | sed -n 's/^entry_id: *//p' | head -1); }
efile() { ls "$Q"/*/"$1".yaml 2>/dev/null | head -1; }
field() {   # field <entry-id> project|name|index|total
  local f; f=$(efile "$1")
  case "$2" in
    project) sed -n 's/^  project: "\(.*\)"$/\1/p' "$f" ;;
    name)    sed -n 's/^    name: "\(.*\)"$/\1/p' "$f" ;;
    index)   sed -n 's/^    index: //p' "$f" ;;
    total)   sed -n 's/^    total: //p' "$f" ;;
  esac
}
ms() { printf '%s/%s/%s' "$(field "$1" index)" "$(field "$1" name)" "$(field "$1" total)"; }
woid() { sed -n 's/^  work_order_id: "\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$(efile "$1")"; }
wofield() {   # wofield <wo-id> project|name|index|total
  local f="$Q/work-orders/$1.yaml"
  case "$2" in
    project) sed -n 's/^  project: //p' "$f" ;;
    name)    sed -n 's/^    name: //p' "$f" ;;
    index)   sed -n 's/^    index: //p' "$f" ;;
    total)   sed -n 's/^    total: //p' "$f" ;;
  esac
}
setst() {   # setst <entry-id> <status>: move an entry to another status directory
  local f; f=$(efile "$1")
  mkdir -p "$Q/$2"
  sed "s/^  status: .*/  status: \"$2\"/" "$f" > "$Q/$2/$1.yaml" && rm -f "$f"
}
# A fingerprint of every live file the command may write.
snap() { { cat "$REG"; for f in "$Q"/*/*.yaml; do printf '%s\n' "$f"; cat "$f"; done; } 2>/dev/null | cksum; }
plan() { printf '%s\n' 'schema_version: "1.0.0"' "$@" > "$PLAN"; }

printf "\n# --- refusals before any registry ---\n"
plan 'milestones:' '  - name: "A"'
run milestones "Core" --file "$PLAN"
_tap_eq "$RC" "1" "with no registry the command refuses"
_tap_contains "$OUT" "no project registry" "...and says why"

printf "\n# --- one-line values even with no registry (the R3 carve-out widens edit) ---\n"
run add --brief "$(nb)" --project "Pre"; PRE="$ID"
run edit "$PRE" project $'x"\n  branch: "evil'
_tap_eq "$RC" "1" "an edit value with a newline is refused when no registry exists"
_tap_eq "$(sed -n 's/^  branch: "\(.*\)"$/\1/p' "$(efile "$PRE")")" "" "...and injects no field"
run edit --work-order "$(woid "$PRE")" milestone.name $'m\n  status: completed'
_tap_eq "$RC" "1" "a work order edit value with a newline is refused"
run remove "$PRE"

printf "\n# --- fixture: a project with three milestones, tasks in five statuses ---\n"
run projects add "Core App" --milestone "Design" --milestone "Build" --milestone "QA"
run projects add "Other" --milestone "Design"
run add --brief "$(nb)" --project "Core App" --milestone-index 1; E1="$ID"
run add --brief "$(nb)" --project "Core App" --milestone-index 2; E2="$ID"
run add --brief "$(nb)" --project "Core App" --milestone-index 3; E3="$ID"
run add --brief "$(nb)" --project "Core App" --milestone-index 2; E4="$ID"
run add --brief "$(nb)" --project "Core App" --milestone-index 1; E5="$ID"
run add --brief "$(nb)" --project "Core App";                     E6="$ID"
run add --brief "$(nb)" --project "Other" --milestone-index 1;    EO="$ID"
setst "$E2" approved; setst "$E3" running; setst "$E4" completed; setst "$E5" failed
W2=$(woid "$E2")
# An entry with no project of its own, in W2's work order: it belongs to the
# project through the work order.
run add --brief "$(nb)" --work-order "$W2" --milestone-index 1; EW="$ID"
# A hand-edited spelling variant (queue-cli itself always writes the registry's).
_e5=$(efile "$E5"); sed 's/^  project: .*/  project: "CORE  app"/' "$_e5" > "$_e5.x" && mv "$_e5.x" "$_e5"
_tap_eq "$(ms "$E3")" "3/QA/3" "fixture: the running entry is in milestone 3"
_tap_eq "$(wofield "$W2" index)" "2" "fixture: entries carry a work order with the milestone"

printf "\n# --- refusals change nothing ---\n"
BEFORE=$(snap)
plan 'milestones:' '  - name: "Design"' '    from: 1' '  - name: "Build"' '    from: 2'
run milestones "Core App" --file "$PLAN"
_tap_eq "$RC" "1" "a deleted milestone with no move refuses the plan"
_tap_contains "$OUT" "has no move" "...naming the missing move"
plan 'milestones:' '  - name: "Design"' '    from: 1' '  - name: "Build"' '    from: 1' '  - name: "QA"' '    from: 3'
run milestones "Core App" --file "$PLAN"
_tap_eq "$RC" "1" "a from used twice refuses the plan"
plan 'milestones:' '  - name: "Design"' '    from: 1' '  - name: "Build"' '    from: 2' '  - name: "QA"' '    from: 4'
run milestones "Core App" --file "$PLAN"
_tap_eq "$RC" "1" "an out-of-range from refuses the plan"
plan 'milestones:' '  - name: "Design"' '    from: 01' '  - name: "Build"' '    from: 2' '  - name: "QA"' '    from: 3'
run milestones "Core App" --file "$PLAN"
_tap_eq "$RC" "1" "an index with a leading zero refuses the plan"
plan 'milestones:' '  - name: "Design"' '    from: 1' 'milestones:' '  - name: "Build"' '    from: 2'
run milestones "Core App" --file "$PLAN"
_tap_eq "$RC" "1" "a second milestones: section refuses the plan"
_tap_contains "$OUT" "appears twice" "...naming the duplicate"
plan 'milestones:' '  - name: "Design"' '    from: 1' '  - name: "build"' '    from: 2' '  - name: "BUILD "' '    from: 3'
run milestones "Core App" --file "$PLAN"
_tap_eq "$RC" "1" "two new names that match ignoring case and spacing refuse the plan"
plan 'milestones:' '  - name: "Design"' '    from: 1' '  colour: blue'
run milestones "Core App" --file "$PLAN"
_tap_eq "$RC" "1" "a malformed plan line refuses the plan"
plan 'milestones:' '  - name: "Design"' '    from: 1' '  - name: "Build"' '    from: 2' 'moves:' '  - from: 3' '    to: 4'
run milestones "Core App" --file "$PLAN"
_tap_eq "$RC" "1" "a move to an index past the new list refuses the plan"
plan 'milestones:' '  - name: "Design"' '    from: 1' '  - name: "Build"' '    from: 2' '  - name: "QA"' '    from: 3' 'moves:' '  - from: 3' '    to: none'
run milestones "Core App" --file "$PLAN"
_tap_eq "$RC" "1" "a move for a kept milestone refuses the plan"
plan 'milestones:' '  - name: "A"'
run milestones "Nope" --file "$PLAN"
_tap_eq "$RC" "1" "an unregistered project refuses the plan"
plan 'rename_to: "other "' 'milestones:' '  - name: "Design"' '    from: 1' '  - name: "Build"' '    from: 2' '  - name: "QA"' '    from: 3'
run milestones "Core App" --file "$PLAN"
_tap_eq "$RC" "3" "rename_to matching another project exits 3"
_tap_contains "$OUT" "NAME_TAKEN: Other" "...and prints NAME_TAKEN with that project"
_tap_eq "$(snap)" "$BEFORE" "after every refusal the registry and all entries are byte-identical"

printf "\n# --- dry run ---\n"
plan 'milestones:' '  - name: "Build"' '    from: 2' '  - name: "Design v2"' '    from: 1' '  - name: "Launch"' 'moves:' '  - from: 3' '    to: 1'
run milestones "Core App" --file "$PLAN" --dry-run
_tap_eq "$RC" "0" "--dry-run succeeds"
_tap_contains "$OUT" "would: entry $E3 (running): milestone 3 \"QA\" -> 1 \"Build\"" "...and prints the change it would make"
_tap_eq "$(snap)" "$BEFORE" "...and writes nothing"

printf "\n# --- forced failure mid-apply restores every file ---\n"
chmod 555 "$Q/failed"
run milestones "Core App" --file "$PLAN"
chmod 755 "$Q/failed"
_tap_eq "$RC" "1" "an unwritable target makes the apply fail"
_tap_contains "$OUT" "every file was restored" "...and says every file was restored"
_tap_eq "$(snap)" "$BEFORE" "...leaving the registry and all entries byte-identical"
ls -d "$Q"/.milestone-plan.* >/dev/null 2>&1 && _tap_fail "...and no staging directory is left" || _tap_pass "...and no staging directory is left"

printf "\n# --- apply: reorder, rename, add, delete with a move ---\n"
run milestones "Core App" --file "$PLAN"
_tap_eq "$RC" "0" "the plan applies"
_tap_contains "$OUT" "registry: milestone 3 \"Launch\" (new)" "it prints the registry changes"
_tap_contains "$OUT" "entry $E4 (completed): milestone 2 \"Build\" -> 1 \"Build\"" "...and each entry it changed"
_tap_contains "$(cat "$REG")" '        name: "Design v2"' "the registry holds the renamed milestone"
_tap_eq "$(ms "$E1")" "2/Design v2/3" "pending-review: old 1 Design -> 2 Design v2"
_tap_eq "$(ms "$E2")" "1/Build/3" "approved: old 2 Build -> 1 Build"
_tap_eq "$(ms "$E3")" "1/Build/3" "running: old 3 QA (deleted, moved to 1) -> 1 Build"
_tap_eq "$(ms "$E4")" "1/Build/3" "completed: old 2 -> 1"
_tap_eq "$(ms "$E5")" "2/Design v2/3" "failed: old 1 -> 2"
_tap_eq "$(wofield "$W2" index)/$(wofield "$W2" name)" "1/Build" "the work orders are mapped too"
_tap_eq "$(ms "$EO")" "1/Design/1" "another project's entries are untouched"
_tap_eq "$(field "$E6" index)" "0" "an entry with no milestone keeps none"
_tap_eq "$(ms "$EW")" "2/Design v2/3" "an entry in the project only through its work order is mapped"
_tap_eq "$(field "$EW" project)" "" "...and keeps its empty project field"
_tap_eq "$(field "$E5" project)" "Core App" "a spelling variant of the project gets the registry's spelling"
ls -d "$Q"/.milestone-plan.* >/dev/null 2>&1 && _tap_fail "no staging directory is left" || _tap_pass "no staging directory is left"
run list
_tap_eq "$RC" "0" "the queue still lists after the apply"

printf "\n# --- delete with to: none, and a project rename ---\n"
plan 'rename_to: "Core"' 'milestones:' '  - name: "Build"' '    from: 1' '  - name: "Launch"' '    from: 3' 'moves:' '  - from: 2' '    to: none'
run milestones "core app" --file "$PLAN"
_tap_eq "$RC" "0" "a plan with a rename and a delete to none applies"
_tap_eq "$(field "$E1" index)/$(field "$E1" name)/$(field "$E1" total)" "0//0" "tasks of a milestone moved to none have no milestone"
_tap_eq "$(field "$E4" project)" "Core" "the project is renamed on entries (completed included)"
_tap_eq "$(wofield "$W2" project)" "Core" "...and on work orders"
_tap_contains "$(cat "$REG")" '  - name: "Core"' "...and in the registry"
_tap_eq "$(ms "$E2")" "1/Build/2" "kept milestones get the new total"

printf "\n# --- a project registered with no milestones maps tasks by name ---\n"
run add --brief "$(nb)" --project "Fresh" --milestone-name "Alpha" --milestone-index 1 --milestone-total 2; F1="$ID"
run add --brief "$(nb)" --project "Fresh" --milestone-name "Beta" --milestone-index 2 --milestone-total 2; F2="$ID"
plan 'milestones:' '  - name: "Beta"' '  - name: "alpha"'
run milestones "Fresh" --file "$PLAN"
_tap_eq "$RC" "0" "a plan for an auto-added project applies"
_tap_eq "$(ms "$F1")" "2/alpha/2" "tasks are matched to the new list by name"
_tap_eq "$(ms "$F2")" "1/Beta/2" "...in the new order"
run add --brief "$(nb)" --project "Fresh2" --milestone-name "Gamma" --milestone-index 1; G1="$ID"
plan 'milestones:' '  - name: "Delta"'
BEFORE=$(snap)
run milestones "Fresh2" --file "$PLAN"
_tap_eq "$RC" "1" "a task whose milestone matches nothing in the plan refuses it"
_tap_contains "$OUT" "entry $G1" "...listing the task"
_tap_eq "$(snap)" "$BEFORE" "...and changes nothing"

printf "\n# --- a task that disagrees with registered milestones refuses the plan ---\n"
run projects add "Three" --milestone "A"
run add --brief "$(nb)" --project "Three" --milestone-index 1; T1="$ID"
_t1=$(efile "$T1"); sed 's/^    index: .*/    index: 5/' "$_t1" > "$_t1.x" && mv "$_t1.x" "$_t1"
plan 'milestones:' '  - name: "A2"' '    from: 1'
BEFORE=$(snap)
run milestones "Three" --file "$PLAN"
_tap_eq "$RC" "1" "a task index past the registered milestones refuses the plan"
_tap_contains "$OUT" "entry $T1" "...listing the task"
sed -e 's/^    index: .*/    index: 0/' -e 's/^    name: .*/    name: "Zed"/' "$_t1" > "$_t1.x" && mv "$_t1.x" "$_t1"
BEFORE=$(snap)
run milestones "Three" --file "$PLAN"
_tap_eq "$RC" "1" "a task milestone name matching no registered milestone refuses the plan"
_tap_eq "$(snap)" "$BEFORE" "...and changes nothing"

printf "\n# --- the schema's field block is itself a valid plan ---\n"
run projects add "Two" --milestone "X" --milestone "Y"
run milestones "Two" --file "$_ADV_REAL_REPO/.claude/.automation/schemas/milestone-plan.yaml" --dry-run
_tap_eq "$RC" "0" "schemas/milestone-plan.yaml parses and checks as a plan"

printf "\n# --- R3: edits on running entries ---\n"
_tap_eq "$(efile "$E3" | sed 's|.*/queue/\([^/]*\)/.*|\1|')" "running" "fixture: E3 is running"
run edit "$E3" milestone.index 2
_tap_eq "$RC" "0" "edit of milestone.index on a running entry succeeds"
_tap_eq "$(ms "$E3")" "2/Launch/2" "...with the registry filling name and total"
run edit "$E3" milestone.index 9
_tap_eq "$RC" "1" "registry rules still apply to a running entry"
run edit "$E3" milestone.name "launch"
_tap_eq "$RC" "0" "edit of milestone.name on a running entry succeeds"
_tap_eq "$(ms "$E3")" "2/Launch/2" "...in the registry's spelling"
run edit "$E3" milestone.total 2
_tap_eq "$RC" "0" "edit of milestone.total on a running entry succeeds"
run edit "$E3" project "CORE"
_tap_eq "$RC" "0" "edit of project on a running entry succeeds"
_tap_eq "$(field "$E3" project)" "Core" "...in the registry's spelling"
run edit "$E3" project "Other"
_tap_eq "$RC" "1" "a project edit that leaves an invalid milestone is still refused"
_tap_contains "$OUT" "there is no milestone 2" "...for the registry's reason, not because it is running"
run edit "$E3" priority 5
_tap_eq "$RC" "1" "edit of any other field on a running entry is still refused"
_tap_contains "$OUT" "only project and milestone" "...and says which fields can change"

printf "\n# === Summary ===\n"
printf "1..%d\n" "$_TAP_NUM"
printf "# Passed: %d / %d\n" "$_TAP_PASS" "$_TAP_NUM"
if [ "$_TAP_FAIL" -gt 0 ]; then printf "# Failures:\n%b" "$_TAP_FAILURES"; exit 1; fi
exit 0
