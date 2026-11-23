#!/usr/bin/env bash
# Governance kit — Decision t-0085 (Massimo R8)
#
# .claude/.automation/governance-kit.json lists the default governance's
# modules, statuses, session types, gates, agents and schema set. This suite
# keeps it true to the repo (drift), checks every problem code of
# .claude/tools/governance-kit.sh validate, and checks module_is_off, the rule
# the hooks use to honour a repo's overrides.
#
# Run against the code before t-0085 (verify-pristine) the cases fail: the kit,
# the tool and the helper do not exist.
# Bash 3.2 compatible.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_REPO="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TOOL="$REAL_REPO/.claude/tools/governance-kit.sh"
KIT="$REAL_REPO/.claude/.automation/governance-kit.json"
HELPER="$REAL_REPO/.claude/hooks/_governance-helper.sh"

_TAP_NUM=0; _TAP_PASS=0; _TAP_FAIL=0; _TAP_FAILURES=""
_tap_pass() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_PASS=$((_TAP_PASS+1)); printf "ok %d - %s\n" "$_TAP_NUM" "$1"; }
_tap_fail() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_FAIL=$((_TAP_FAIL+1)); printf "not ok %d - %s\n" "$_TAP_NUM" "$1"; [ -n "${2:-}" ] && printf "  # %s\n" "$2"; _TAP_FAILURES="${_TAP_FAILURES}  FAIL: $1\n"; }
_tap_eq() { if [ "$1" = "$2" ]; then _tap_pass "$3"; else _tap_fail "$3" "expected '$2', got '$1'"; fi; }
_tap_contains() { case "$1" in *"$2"*) _tap_pass "$3" ;; *) _tap_fail "$3" "output did not contain '$2': $1" ;; esac; }
_tap_lacks() { case "$1" in *"$2"*) _tap_fail "$3" "output contained '$2': $1" ;; *) _tap_pass "$3" ;; esac; }
_tap_true() { if eval "$1"; then _tap_pass "$2"; else _tap_fail "$2" "false: $1"; fi; }

printf "# === Governance kit (Decision t-0085) ===\n"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gk-test.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
run() { OUT=$(bash "$TOOL" "$@" 2>&1); RC=$?; }
kj() { jq -r "$1" "$KIT" 2>/dev/null; }

# --- the default kit ----------------------------------------------------------
printf "\n# the default kit validates\n"
run validate
_tap_eq "$RC" "0" "the default kit validates"
_tap_contains "$OUT" "Kit valid: repo-os" "it says which kit is valid"

printf "\n# drift: the default kit is true to the repo\n"
# Every session type get_phases_for_type knows, and each one's phases.
types=$(awk '/^get_phases_for_type\(\) \{/ {f=1; next} f && /^  esac/ {exit}
             f && /^    [a-z][a-z0-9|.-]*\)/ { sub(/\).*/, ""); gsub(/^ +/, ""); n=split($0, a, "|"); for (i=1;i<=n;i++) print a[i] }' \
        "$REAL_REPO/.claude/hooks/_phase-helper.sh" | sort)
_tap_eq "$(kj '.session_types | keys[]' | sort | tr '\n' ' ')" "$(printf '%s\n' "$types" | tr '\n' ' ')" \
  "session_types names every type _phase-helper.sh knows"
mismatch=""
for t in $types; do
  want=$(bash -c "source '$REAL_REPO/.claude/hooks/_analytics-helper.sh' >/dev/null 2>&1; source '$REAL_REPO/.claude/hooks/_phase-helper.sh' >/dev/null 2>&1; get_phases_for_type $t")
  got=$(jq -r --arg t "$t" '.session_types[$t] | join(" ")' "$KIT")
  [ "$want" = "$got" ] || mismatch="$mismatch $t"
done
_tap_eq "$mismatch" "" "each session type's phases equal get_phases_for_type"

qs=$(sed -n 's/^  status: [a-z-]* *# *//p' "$REAL_REPO/.claude/.automation/schemas/queue-entry.yaml" | head -1 | tr -d ' ' | tr '|' '\n' | sort | tr '\n' ' ')
_tap_eq "$(kj '.statuses | keys[]' | sort | tr '\n' ' ')" "$qs" "statuses are exactly the 8 queue-entry statuses"
_tap_eq "$(kj '[.statuses | to_entries[] | select(.key != .value)] | length')" "0" "each maps to itself"

missing=""
for f in "$REAL_REPO"/.claude/agents/*.md; do
  b=$(basename "$f" .md)
  case "$b" in _*) n=$(sed -n 's/^name: *//p' "$f" | head -1); [ -n "$n" ] || continue ;; *) n="$b" ;; esac
  jq -e --arg id "agent.$n" '[.modules[] | select(.id == $id)] | length == 1' "$KIT" >/dev/null || missing="$missing $n"
done
_tap_eq "$missing" "" "every agent has a module"
_tap_eq "$(kj '.agents | sort | join(" ")')" "$(kj '[.modules[] | select(.category == "agents") | .id | ltrimstr("agent.")] | sort | join(" ")')" \
  "agents names exactly the agent modules"

missing=""
for f in "$REAL_REPO"/docs/ai/prompts/prompt-*.md; do
  p="docs/ai/prompts/$(basename "$f")"
  jq -e --arg p "$p" '[.modules[] | select(.category == "skills-prompts" and (.files | index($p)))] | length == 1' "$KIT" >/dev/null || missing="$missing $p"
done
_tap_eq "$missing" "" "every prompt has a module"

missing=""
hooks=$(jq -r '.hooks[][] | .hooks[] | .command' "$REAL_REPO/.claude/settings.json" | sed 's|.*/||; s|\.sh.*||' | sort -u)
_tap_true "[ $(printf '%s\n' "$hooks" | grep -c .) -ge 10 ]" "settings.json registers the hooks this check reads"
for h in $hooks; do
  jq -e --arg id "hook.$h" '[.modules[] | select(.id == $id)] | length == 1' "$KIT" >/dev/null || missing="$missing $h"
done
_tap_eq "$missing" "" "every hook registered in settings.json has a module"

# auto-version-tag tags the template's own releases and does nothing in a child.
missing=""
for f in "$REAL_REPO"/.github/workflows/*.yml; do
  w=$(basename "$f" .yml); [ "$w" = "auto-version-tag" ] && continue
  jq -e --arg id "workflow.$w" '[.modules[] | select(.id == $id)] | length == 1' "$KIT" >/dev/null || missing="$missing $w"
done
_tap_eq "$missing" "" "every GitHub workflow that governs a repo has a module"

_tap_eq "$(kj '[.modules[] | select(.category == "decisions") | .files] | tostring')" '[["docs/ai/decisions/t-manifest.txt"]]' \
  "the decisions module lists t-manifest.txt"

missing="" notshipped=""
for f in $(kj '.modules[].files[]' | sort -u); do
  [ -e "$REAL_REPO/$f" ] || missing="$missing $f"
  grep -qxF "$f" "$REAL_REPO/.claude/.automation/machinery-manifest.txt" || notshipped="$notshipped $f"
done
_tap_eq "$missing" "" "every listed file exists"
_tap_eq "$notshipped" "" "every listed file is shipped to children, so the kit validates there too"
_tap_true "grep -qxF .claude/.automation/governance-kit.json '$REAL_REPO/.claude/.automation/machinery-manifest.txt'" "the kit itself is shipped"

_tap_eq "$(kj '.schema_set')" "$(sed -n 's/^## v\([0-9.]*\) .*/\1/p' "$REAL_REPO/.claude/.automation/schemas/SCHEMA-CHANGELOG.md" | head -1)" \
  "schema_set is the latest SCHEMA-CHANGELOG version"
missing=""
for g in $(kj '.gates[].id'); do
  jq -e --arg id "gate.$g" '[.modules[] | select(.id == $id)] | length == 1' "$KIT" >/dev/null || missing="$missing $g"
done
_tap_eq "$missing" "" "every gate has a module"

printf "\n# what can never be turned off\n"
_tap_eq "$(kj '[.modules[] | select(.category == "quality-gates" and .turn_off_safe)] | length')" "0" "no gate is turn_off_safe"
_tap_eq "$(kj '[.modules[] | select(.category == "hooks" and .turn_off_safe) | .id] | join(" ")')" "hook.hvst-failure-tracker" \
  "the failure tracker is the only hook that is turn_off_safe"
_tap_eq "$(kj '[.modules[] | select((.id | IN("agent.critic","agent.qa-verifier","agent.reviewer","agent.security-privacy","agent.pragmatist","agent.builder","agent.orchestrator")) and .turn_off_safe)] | length')" "0" \
  "no gate-required agent is turn_off_safe"
_tap_eq "$(kj '[.modules[] | select(.turn_off_safe == false and ((.why // "") == ""))] | length')" "0" "every module that is not safe says why"
# The helper's never-off list must cover every agent a gate or verdict needs:
# the governance agents state-writer captures, plus builder and the orchestrators.
nv=""
for a in $(sed -n 's/.*critic|qa-verifier|\([a-z|-]*\)).*/critic|qa-verifier|\1/p' "$REAL_REPO/.claude/hooks/pretooluse-permission.sh" | head -1 | tr '|' ' ') builder orchestrator dev-orchestrator; do
  ( . "$HELPER"; _gov_never_off "agent.$a" ) || nv="$nv $a"
done
_tap_eq "$nv" "" "the never-off list covers every gate-required agent"
_tap_true "( . '$HELPER'; ! _gov_never_off hook.hvst-failure-tracker )" "...and leaves out the failure tracker"
for h in $hooks; do [ "$h" = hvst-failure-tracker ] && continue; ( . "$HELPER"; _gov_never_off "hook.$h" ) || nv="$nv $h"; done
_tap_eq "$nv" "" "...and every other registered hook"

# --- a small kit, to break one rule at a time -----------------------------------
mkdir -p "$WORK/kit"; printf 'a\n' > "$WORK/kit/a.md"; printf 'c\n' > "$WORK/kit/c.md"
cat > "$WORK/kit/kit.json" <<'EOF'
{"schema": "governance-kit", "schema_version": "1.0.0",
 "kit": {"id": "my-kit", "name": "My kit"},
 "statuses": {"todo": "pending-review", "doing": "running", "done": "completed"},
 "session_types": {"standard": ["init", "build", "close"]},
 "gates": [{"id": "A1", "name": "Decisions", "enforced_by": "c.md"}],
 "agents": ["architect", "critic"],
 "schema_set": "1.18.0",
 "modules": [
   {"id": "agent.architect", "category": "agents", "name": "Architect", "files": ["a.md"], "turn_off_safe": true, "why": ""},
   {"id": "agent.critic", "category": "agents", "name": "Critic", "files": ["c.md"], "turn_off_safe": false, "why": "A5"}
 ]}
EOF
printf "\n# a custom kit in its own folder\n"
run validate --kit "$WORK/kit/kit.json" --root "$WORK/kit"
_tap_eq "$RC" "0" "a custom kit validates with --kit and --root"
_tap_contains "$OUT" "Kit valid: my-kit" "...and names itself"
run; _tap_eq "$RC" "2" "usage: no command exits 2"
run validate --bogus; _tap_eq "$RC" "2" "usage: an unknown option exits 2"
run validate --kit; _tap_eq "$RC" "2" "usage: --kit without a file exits 2"

bad() {  # <jq filter> <code> <description>
  jq "$1" "$WORK/kit/kit.json" > "$WORK/kit/bad.json"
  run validate --kit "$WORK/kit/bad.json" --root "$WORK/kit"
  if [ "$RC" -eq 1 ]; then _tap_contains "$OUT" "$2:" "$3"; else _tap_fail "$3" "rc=$RC $OUT"; fi
}
printf "\n# each problem code\n"
printf 'not json\n' > "$WORK/kit/broken.json"
run validate --kit "$WORK/kit/broken.json" --root "$WORK/kit"
_tap_eq "$RC" "1" "KIT_UNREADABLE exits 1"; _tap_contains "$OUT" "KIT_UNREADABLE:" "a file that is not JSON is KIT_UNREADABLE"
run validate --kit "$WORK/kit/none.json" --root "$WORK/kit"
_tap_contains "$OUT" "KIT_UNREADABLE:" "a missing kit is KIT_UNREADABLE"
bad 'del(.agents)' FIELD_MISSING "a missing field is FIELD_MISSING"
bad 'del(.kit.name)' FIELD_MISSING "a missing kit name is FIELD_MISSING"
bad '.statuses.waiting = "queued"' STATUS_UNMAPPED "a status mapped outside the 8 is STATUS_UNMAPPED"
bad '.statuses = {}' STATUS_UNMAPPED "no statuses at all is STATUS_UNMAPPED"
bad '.statuses.doing = ["running"]' STATUS_UNMAPPED "a status mapped to a list is STATUS_UNMAPPED"
bad '.statuses.doing = ["approved", "running"]' STATUS_UNMAPPED "...even a list of two adjacent statuses"
bad '.modules[0].category = ["agents"]' MODULE_INVALID "a category given as a list is MODULE_INVALID"
bad '.gates = [null]' NO_GATES "a gate with no id is NO_GATES"
bad '.agents = [3]' NO_AGENTS "an agent that is not a name is NO_AGENTS"
bad '.session_types.standard = []' NO_PHASES "a type with no phases is NO_PHASES"
bad '.session_types = {}' NO_PHASES "no session types is NO_PHASES"
bad '.gates = []' NO_GATES "no gate is NO_GATES"
bad '.agents = []' NO_AGENTS "no agent is NO_AGENTS"
bad '.schema_set = "2.0.0"' SCHEMA_VERSION "an unsupported major version is SCHEMA_VERSION"
bad '.schema_set = "latest"' SCHEMA_VERSION "a schema_set that is not a version is SCHEMA_VERSION"
bad '.modules += [.modules[0]]' MODULE_INVALID "a duplicate module id is MODULE_INVALID"
bad '.modules[0].category = "misc"' MODULE_INVALID "an unknown category is MODULE_INVALID"
bad '.modules[0].files = []' MODULE_INVALID "a module with no files is MODULE_INVALID"
bad '.modules[0].turn_off_safe = "yes"' MODULE_INVALID "a turn_off_safe that is not boolean is MODULE_INVALID"
bad '.modules[0].files = ["../kit/a.md"]' MODULE_INVALID "a file path that climbs out of the root is MODULE_INVALID"
bad '.modules[0].files = ["/etc/hosts"]' MODULE_INVALID "an absolute file path is MODULE_INVALID"
bad '.modules[0].files = ["nope.md"]' MODULE_FILE_MISSING "a listed file that is absent is MODULE_FILE_MISSING"

# --- the repo's overrides ---------------------------------------------------------
printf "\n# overrides\n"
R="$WORK/repo"; mkdir -p "$R/.claude/.automation"; cp "$WORK/kit/a.md" "$WORK/kit/c.md" "$R/"
cp "$WORK/kit/kit.json" "$R/.claude/.automation/governance-kit.json"
OV="$R/.claude/.automation/governance-overrides.json"
ov() { printf '%s\n' "$1" > "$OV"; run validate --root "$R"; }
ov '{"modules": {"agent.architect": "off"}}'
_tap_eq "$RC" "0" "off on a turn_off_safe module passes"
_tap_lacks "$OUT" "WARN" "...without a warning"
ov '{"modules": {"agent.ghost": "off"}}'
_tap_eq "$RC" "1" "an unknown module fails"; _tap_contains "$OUT" "OVERRIDE_UNKNOWN: agent.ghost" "...as OVERRIDE_UNKNOWN"
ov '{"modules": {"agent.architect": "disabled"}}'
_tap_contains "$OUT" "OVERRIDE_VALUE: agent.architect" "a value other than off or customized is OVERRIDE_VALUE"
ov '{"modules": []}'
_tap_contains "$OUT" "OVERRIDE_VALUE:" "a file without a modules object is OVERRIDE_VALUE"
ov '{"modules": {"agent.critic": "off"}}'
_tap_eq "$RC" "1" "off on a module that is not safe fails"; _tap_contains "$OUT" "OVERRIDE_NOT_SAFE: agent.critic" "...as OVERRIDE_NOT_SAFE"
jq '.modules[1].turn_off_safe = true' "$WORK/kit/kit.json" > "$R/.claude/.automation/governance-kit.json"
run validate --root "$R"
_tap_contains "$OUT" "OVERRIDE_NOT_SAFE: agent.critic" "off on a never-off agent fails even when the kit says safe"
cp "$WORK/kit/kit.json" "$R/.claude/.automation/governance-kit.json"
ov '{"modules": {"agent.architect": "customized"}}'
_tap_eq "$RC" "0" "customized with an unclaimed file still passes"
_tap_contains "$OUT" "WARN OVERRIDE_NOT_CLAIMED: agent.architect file a.md" "...with a warning that sync would overwrite it"
printf 'a.md\n' > "$R/.templatesyncignore.local"
ov '{"modules": {"agent.architect": "customized"}}'
_tap_eq "$RC" "0" "customized with its files claimed passes"
_tap_lacks "$OUT" "WARN" "...without a warning"
printf '{"modules": {"agent.ghost": "off"}}\n' > "$OV"; run validate --kit "$R/.claude/.automation/governance-kit.json" --root "$R"
_tap_eq "$RC" "0" "with --kit the repo's overrides are not checked"

# --- module_is_off, the rule the hooks use ----------------------------------------
printf "\n# module_is_off\n"
H="$WORK/h"; mkdir -p "$H/.claude/.automation"
cat > "$H/.claude/.automation/governance-kit.json" <<'EOF'
{"modules": [
  {"id": "agent.architect", "turn_off_safe": true},
  {"id": "agent.ux-designer", "turn_off_safe": false},
  {"id": "agent.critic", "turn_off_safe": true},
  {"id": "hook.bash-guard", "turn_off_safe": true},
  {"id": "hook.hvst-failure-tracker", "turn_off_safe": true}
]}
EOF
printf '{"modules": {"agent.architect": "off", "agent.ux-designer": "off", "agent.critic": "off", "hook.bash-guard": "off", "hook.hvst-failure-tracker": "off"}}\n' \
  > "$H/.claude/.automation/governance-overrides.json"
off() { ( _REPO_OS_ROOT="$H"; . "$HELPER"; module_is_off "$1" ) && echo on-off || echo stays-on; }
_tap_eq "$(off agent.architect)" "on-off" "an off module the kit marks safe is off"
_tap_eq "$(off agent.ux-designer)" "stays-on" "an off module the kit marks unsafe stays on"
_tap_eq "$(off agent.critic)" "stays-on" "a never-off agent stays on though kit and override say safe and off"
_tap_eq "$(off hook.bash-guard)" "stays-on" "a guard hook stays on though kit and override say safe and off"
_tap_eq "$(off hook.hvst-failure-tracker)" "on-off" "the failure tracker can be turned off"
_tap_eq "$(off agent.exploration)" "stays-on" "a module the override does not name stays on"
_tap_eq "$(off '')" "stays-on" "no id stays on"
printf 'not json' > "$H/.claude/.automation/governance-overrides.json"
_tap_eq "$(off agent.architect)" "stays-on" "a malformed override file turns nothing off"
rm -f "$H/.claude/.automation/governance-overrides.json"
_tap_eq "$(off agent.architect)" "stays-on" "no override file turns nothing off"
printf '{"modules": {"agent.architect": "off"}}\n' > "$H/.claude/.automation/governance-overrides.json"
printf 'not json' > "$H/.claude/.automation/governance-kit.json"
_tap_eq "$(off agent.architect)" "stays-on" "a malformed kit turns nothing off"
rm -f "$H/.claude/.automation/governance-kit.json"
_tap_eq "$(off agent.architect)" "stays-on" "no kit turns nothing off"

printf "\n# the real template\n"
_tap_true "grep -qx '.claude/.automation/governance-overrides.json' '$REAL_REPO/.templatesyncignore'" \
  "the override file is owned by the child, not synced"
_tap_true "[ -x '$TOOL' ]" "the tool is executable"

printf "\n# %d passed, %d failed\n" "$_TAP_PASS" "$_TAP_FAIL"
if [ "$_TAP_FAIL" -gt 0 ]; then printf "%b" "$_TAP_FAILURES"; exit 1; fi
exit 0
