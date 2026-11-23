#!/usr/bin/env bash
# governance-kit.sh — validate a governance kit and the repo's overrides.
#
# A kit (Decision t-0085) lists a governance's modules, statuses, session types,
# gates, agents and schema set. The default kit is the template's own
# .claude/.automation/governance-kit.json; Massimo's custom kits use the same
# format in their own folder.
#
# Usage:
#   governance-kit.sh validate [--kit FILE] [--root DIR]
#
# --kit   the kit to check (default: <root>/.claude/.automation/governance-kit.json)
# --root  where the kit's module files are, relative paths (default: this repo)
#
# With no --kit, the repo's .claude/.automation/governance-overrides.json is
# checked too when it exists. Prints one 'CODE: detail' line per problem.
# Warnings start 'WARN' and do not fail validation.
#
# Exit codes: 0 valid ('Kit valid: <id>'), 1 problems found, 2 usage
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUPPORTED_MAJOR=1
QUEUE_STATUSES='["pending-review","approved","running","completed","failed","review","blocked","stopped"]'
CATEGORIES='["agents","skills-prompts","workflows","hooks","rules","quality-gates","decisions","merge-close"]'

_usage() { sed -n '9,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[ "${1:-}" = "validate" ] || _usage
shift
kit="" root="" check_overrides=true
while [ $# -gt 0 ]; do
  case "$1" in
    --kit)  [ $# -ge 2 ] || _usage; kit="$2"; check_overrides=false; shift 2 ;;
    --root) [ $# -ge 2 ] || _usage; root="$2"; shift 2 ;;
    *) _usage ;;
  esac
done
command -v jq >/dev/null 2>&1 || { echo "governance-kit: jq is required" >&2; exit 1; }
if [ -z "$root" ]; then
  root=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null) || root="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi
[ -d "$root" ] || { echo "governance-kit: no such directory: $root" >&2; exit 2; }
[ -n "$kit" ] || kit="$root/.claude/.automation/governance-kit.json"

problems=0
_problem() { echo "$1"; problems=$((problems + 1)); }

if [ ! -f "$kit" ] || ! jq -e 'type == "object"' "$kit" >/dev/null 2>&1; then
  echo "KIT_UNREADABLE: $kit is missing or is not a JSON object"
  exit 1
fi

# Structure: one jq pass prints a line per problem.
structural=$(jq -r --argjson qs "$QUEUE_STATUSES" --argjson cats "$CATEGORIES" --argjson major "$SUPPORTED_MAJOR" '
  def semver: type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$");
  def major: split(".")[0] | tonumber;
  . as $root | (
  ( ["schema_version", "statuses", "session_types", "gates", "agents", "schema_set", "modules"][]
    | select(. as $k | $root[$k] == null) | "FIELD_MISSING: \(.)" ),
  ( if (.kit.id | type) != "string" or .kit.id == "" then "FIELD_MISSING: kit.id" else empty end ),
  ( if (.kit.name | type) != "string" or .kit.name == "" then "FIELD_MISSING: kit.name" else empty end ),
  ( if .schema_version != null and ((.schema_version | semver | not) or (.schema_version | major) != $major)
    then "SCHEMA_VERSION: schema_version \(.schema_version) (this template reads \($major).x.y)" else empty end ),
  ( if .schema_set != null and ((.schema_set | semver | not) or (.schema_set | major) != $major)
    then "SCHEMA_VERSION: schema_set \(.schema_set) (this template supports \($major).x.y)" else empty end ),
  ( .statuses | if . == null then empty
    elif type != "object" or length == 0 then "STATUS_UNMAPPED: no statuses are mapped"
    else to_entries[] | select(.value as $v | ($v | type) != "string" or ($qs | index([$v])) == null)
      | "STATUS_UNMAPPED: \(.key) maps to \(.value | tostring), not one of the 8 queue statuses" end ),
  ( .session_types | if . == null then empty
    elif type != "object" or length == 0 then "NO_PHASES: no session types are declared"
    else to_entries[] | select((.value | type) != "array" or (.value | length) == 0
      or ([.value[] | select(type != "string" or . == "")] | length) > 0)
      | "NO_PHASES: session type \(.key) has no phase list" end ),
  ( .gates | if . == null then empty
    elif type != "array" or length == 0 then "NO_GATES: the kit declares no gate"
    else .[] | select((.id | type) != "string" or .id == "") | "NO_GATES: a gate has no id" end ),
  ( .agents | if . == null then empty
    elif type != "array" or length == 0 then "NO_AGENTS: the kit declares no agent"
    else .[] | select(type != "string" or . == "") | "NO_AGENTS: an agent entry is not a name" end ),
  ( .modules | if . == null then empty
    elif type != "array" then "MODULE_INVALID: modules is not a list"
    else
      ( [.[] | .id] | group_by(.) | .[] | select(length > 1) | "MODULE_INVALID: duplicate id \(.[0])" ),
      ( to_entries[] | .key as $i | .value
        | (if (.id | type) != "string" or .id == "" then "MODULE_INVALID: module \($i) has no id" else empty end),
          (if .category as $c | ($c | type) != "string" or ($cats | index([$c])) == null then "MODULE_INVALID: \(.id) has unknown category \(.category | tostring)" else empty end),
          (if (.files | type) != "array" or (.files | length) == 0 or ([.files[] | select(type != "string" or . == "")] | length) > 0
           then "MODULE_INVALID: \(.id) lists no files" else empty end),
          (if (.turn_off_safe | type) != "boolean" then "MODULE_INVALID: \(.id) turn_off_safe is not true or false" else empty end) )
    end )
  )
' "$kit" 2>/dev/null) || structural="KIT_UNREADABLE: $kit could not be checked"
while IFS= read -r line; do
  [ -n "$line" ] && _problem "$line"
done <<EOF
$structural
EOF

# Every module file must exist under the root.
while IFS='|' read -r mid f; do
  [ -n "$f" ] || continue
  case "/$f/" in
    //*|*/../*) _problem "MODULE_INVALID: $mid lists $f, which is not a path inside the root"; continue ;;
  esac
  [ -e "$root/$f" ] || _problem "MODULE_FILE_MISSING: $mid lists $f, which is not under $root"
done <<EOF
$(jq -r '(.modules // []) | if type == "array" then .[] | select((.files | type) == "array") | .id as $i | .files[] | select(type == "string") | "\($i)|\(.)" else empty end' "$kit" 2>/dev/null)
EOF

# The repo's overrides, against the kit.
ov="$root/.claude/.automation/governance-overrides.json"
if [ "$check_overrides" = true ] && [ -f "$ov" ]; then
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/../hooks/_governance-helper.sh"
  if ! jq -e '(.modules | type) == "object"' "$ov" >/dev/null 2>&1; then
    _problem "OVERRIDE_VALUE: $ov is not a JSON object with a modules object"
  else
    claims="$root/.templatesyncignore.local"
    while IFS='|' read -r mid val; do
      [ -n "$mid" ] || continue
      if ! jq -e --arg id "$mid" '[(.modules // [])[] | select(.id == $id)] | length > 0' "$kit" >/dev/null 2>&1; then
        _problem "OVERRIDE_UNKNOWN: $mid is not a module of the kit"; continue
      fi
      case "$val" in
        off)
          if _gov_never_off "$mid" || ! jq -e --arg id "$mid" '[.modules[] | select(.id == $id and .turn_off_safe == true)] | length == 1' "$kit" >/dev/null 2>&1; then
            _problem "OVERRIDE_NOT_SAFE: $mid cannot be turned off"
          fi ;;
        customized)
          while IFS= read -r f; do
            [ -n "$f" ] || continue
            grep -qxF -- "$f" "$claims" 2>/dev/null \
              || echo "WARN OVERRIDE_NOT_CLAIMED: $mid file $f is not in .templatesyncignore.local, so the next template sync overwrites it"
          done <<FILES
$(jq -r --arg id "$mid" '.modules[] | select(.id == $id) | .files[]' "$kit" 2>/dev/null)
FILES
          ;;
        *) _problem "OVERRIDE_VALUE: $mid is set to '$val'; it must be off or customized" ;;
      esac
    done <<EOF
$(jq -r '.modules | to_entries[] | "\(.key)|\(.value | tostring)"' "$ov" 2>/dev/null)
EOF
  fi
fi

if [ "$problems" -gt 0 ]; then
  exit 1
fi
echo "Kit valid: $(jq -r '.kit.id' "$kit")"
exit 0
