#!/usr/bin/env bash
# ec-report.sh — join declared Expected Changes to the commits that delivered
# them, and surface everything else as additional changes.
#
# Decision t-0050. Emits JSON on stdout for downstream consumers (UI, close
# summary, report).
#
# Usage:
#   .claude/tools/ec-report.sh                          # main...HEAD, auto-locate bundle
#   .claude/tools/ec-report.sh --range main...HEAD
#   .claude/tools/ec-report.sh --bundle path/to/b.yaml
#   .claude/tools/ec-report.sh --text                   # human-readable instead of JSON
#
# Sources of Expected Changes, in order:
#   1. --bundle <path>
#   2. .claude/local/handoff-bundles/<brief_id>.yaml  (singular, Decision t-0043)
#   3. .claude/local/task-contract.yaml               (task-group intent block)
#
# WHAT THIS DOES NOT DO (Decision t-0050 Consequences):
#   It never guesses. A commit is attributed to an Expected Change only when it
#   carries that ID in a `Changes:` trailer. Anything else is an additional
#   change — which is a result, not a failure. There is no line-level
#   attribution: a commit maps to an outcome, a hunk does not.

set -uo pipefail

RANGE=""
BUNDLE=""
FORMAT="json"

while [ $# -gt 0 ]; do
  case "$1" in
    --range)  RANGE="${2:-}"; shift 2 ;;
    --bundle) BUNDLE="${2:-}"; shift 2 ;;
    --text)   FORMAT="text"; shift ;;
    --json)   FORMAT="json"; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "ec-report: unknown argument: $1" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

command -v jq >/dev/null 2>&1 || { echo "ec-report: jq is required" >&2; exit 2; }

# --- Resolve the commit range ---------------------------------------------
if [ -z "$RANGE" ]; then
  # main...HEAD is the brief's own work: commits on this branch since it
  # diverged from main. Matches how the merge brief reads briefs[].branch.
  if git rev-parse --verify main >/dev/null 2>&1; then
    RANGE="main...HEAD"
  else
    RANGE="HEAD~20..HEAD"
  fi
fi

# --- Locate the Expected Changes source -----------------------------------
if [ -z "$BUNDLE" ]; then
  _brief_id=""
  if [ -f "$REPO_ROOT/.claude/local/task-contract.yaml" ]; then
    _brief_id=$(awk -F': *' '/^[[:space:]]*brief_id:/ { gsub(/"/,"",$2); print $2; exit }' \
      "$REPO_ROOT/.claude/local/task-contract.yaml" 2>/dev/null)
  fi
  if [ -n "$_brief_id" ] && [ -f "$REPO_ROOT/.claude/local/handoff-bundles/${_brief_id}.yaml" ]; then
    BUNDLE="$REPO_ROOT/.claude/local/handoff-bundles/${_brief_id}.yaml"
  else
    # Newest singular bundle, else the task contract itself.
    BUNDLE=$(ls -t "$REPO_ROOT"/.claude/local/handoff-bundles/*.yaml 2>/dev/null | head -1)
    [ -n "$BUNDLE" ] || BUNDLE="$REPO_ROOT/.claude/local/task-contract.yaml"
  fi
fi

# --- Parse expected_changes -----------------------------------------------
# Block form:
#   expected_changes:
#     - id: "EC-1"
#       statement: "People can sign in with a Google account"
# Tolerates quoted/unquoted values and any indentation depth.
EC_TSV=""
if [ -f "$BUNDLE" ]; then
  EC_TSV=$(awk '
    /^[[:space:]]*expected_changes:[[:space:]]*$/ { in_ec=1; next }
    in_ec && /^[[:space:]]*[a-zA-Z_]+:[[:space:]]*$/ && !/expected_changes/ { in_ec=0 }
    in_ec && /^[a-zA-Z_]/ { in_ec=0 }
    in_ec && /-[[:space:]]*id:/ {
      if (id != "") { print id "\t" stmt }
      line=$0
      sub(/^.*id:[[:space:]]*/, "", line)
      gsub(/^["'"'"']|["'"'"'][[:space:]]*$/, "", line)
      id=line; stmt=""
      next
    }
    in_ec && /statement:/ {
      line=$0
      sub(/^.*statement:[[:space:]]*/, "", line)
      gsub(/^["'"'"']|["'"'"'][[:space:]]*$/, "", line)
      stmt=line
      next
    }
    END { if (id != "") print id "\t" stmt }
  ' "$BUNDLE" 2>/dev/null)
fi

# --- Walk the range, bucket commits by Changes: trailer --------------------
_ec_ids=$(printf '%s\n' "$EC_TSV" | awk -F'\t' 'NF{print $1}')

_tmp=$(mktemp -t ec-report.XXXXXX) || exit 1
trap 'rm -f "$_tmp" "$_tmp.att" "$_tmp.add"' EXIT
: > "$_tmp.att"   # id \t sha \t subject
: > "$_tmp.add"   # sha \t subject

# Records are \x1e-delimited and bodies contain newlines, so they must be read
# with -d rather than line-wise — a line-wise read tears each commit apart at
# the first newline of its body. Process substitution (not a pipe) keeps the
# loop in this shell.
while IFS= read -r -d $'\x1e' rec; do
  [ -n "$rec" ] || continue
  # Strip the leading newline left by the previous record's delimiter.
  rec="${rec#$'\n'}"
  sha="${rec%%$'\x1f'*}"
  _rest="${rec#*$'\x1f'}"
  subj="${_rest%%$'\x1f'*}"
  body="${_rest#*$'\x1f'}"
  sha=$(printf '%s' "$sha" | tr -d '[:space:]')
  case "$sha" in ''|*[!0-9a-f]*) continue ;; esac

  # Trailer may appear in body or subject; accept comma/space separated IDs.
  trailer=$(printf '%s\n%s' "$subj" "$body" | grep -oiE '^[[:space:]]*Changes:[[:space:]]*.*' | head -1)
  matched=0
  if [ -n "$trailer" ]; then
    ids=$(printf '%s' "$trailer" | sed -E 's/^[[:space:]]*[Cc]hanges:[[:space:]]*//' | tr ',' ' ')
    for id in $ids; do
      id=$(printf '%s' "$id" | tr -d '[:space:]')
      [ -n "$id" ] || continue
      if printf '%s\n' "$_ec_ids" | grep -qxF "$id"; then
        printf '%s\t%s\t%s\n' "$id" "$sha" "$subj" >> "$_tmp.att"
        matched=1
      fi
    done
  fi
  # No trailer, or a trailer naming no declared ID → additional change.
  # Both are genuinely unattributed; treating the second as attributed would
  # invent a mapping to an Expected Change that does not exist.
  [ "$matched" = "0" ] && printf '%s\t%s\n' "$sha" "$subj" >> "$_tmp.add"
done < <(git log --no-merges --format='%H%x1f%s%x1f%b%x1e' "$RANGE" 2>/dev/null)

_files_for() {  # files touched by a list of shas on stdin
  local shas; shas=$(cat)
  [ -n "$shas" ] || { echo ""; return; }
  # shellcheck disable=SC2086
  git show --pretty=format: --name-only $shas 2>/dev/null | awk 'NF' | sort -u
}

# --- Emit ------------------------------------------------------------------
{
  printf '{\n'
  printf '  "range": %s,\n' "$(jq -Rn --arg v "$RANGE" '$v')"
  printf '  "source": %s,\n' "$(jq -Rn --arg v "${BUNDLE#$REPO_ROOT/}" '$v')"
  printf '  "expected_changes": [\n'

  first=1
  if [ -n "$EC_TSV" ]; then
    while IFS=$'\t' read -r id stmt; do
      [ -n "$id" ] || continue
      shas=$(awk -F'\t' -v i="$id" '$1==i{print $2}' "$_tmp.att")
      n=$(printf '%s\n' "$shas" | awk 'NF' | wc -l | tr -d ' ')
      status="not-started"; [ "$n" -gt 0 ] && status="delivered"
      files=$(printf '%s\n' "$shas" | _files_for)

      [ "$first" = "0" ] && printf ',\n'
      first=0
      printf '    {"id": %s, "statement": %s, "status": %s, "commit_count": %s,\n' \
        "$(jq -Rn --arg v "$id" '$v')" "$(jq -Rn --arg v "$stmt" '$v')" \
        "$(jq -Rn --arg v "$status" '$v')" "$n"
      printf '     "commits": %s,\n' \
        "$(awk -F'\t' -v i="$id" '$1==i{print $2"\t"$3}' "$_tmp.att" \
           | jq -R -s 'split("\n")|map(select(length>0)|split("\t")|{sha:.[0],subject:.[1]})')"
      printf '     "files": %s}' "$(printf '%s\n' "$files" | jq -R -s 'split("\n")|map(select(length>0))')"
    done <<< "$EC_TSV"
  fi
  printf '\n  ],\n'

  add_shas=$(awk -F'\t' '{print $1}' "$_tmp.add")
  printf '  "additional_changes": %s,\n' \
    "$(jq -R -s 'split("\n")|map(select(length>0)|split("\t")|{sha:.[0],subject:.[1]})' < "$_tmp.add")"
  printf '  "additional_files": %s\n' \
    "$(printf '%s\n' "$add_shas" | _files_for | jq -R -s 'split("\n")|map(select(length>0))')"
  printf '}\n'
} > "$_tmp"

if ! jq -e . "$_tmp" >/dev/null 2>&1; then
  echo "ec-report: produced invalid JSON (this is a bug)" >&2
  cat "$_tmp" >&2
  exit 1
fi

if [ "$FORMAT" = "json" ]; then
  jq . "$_tmp"
else
  jq -r '
    "Range:  \(.range)",
    "Source: \(.source)",
    "",
    "Expected changes:",
    (if (.expected_changes|length) == 0 then "  (none declared)" else
      (.expected_changes[] |
        "  [\(if .status=="delivered" then "x" else " " end)] \(.id): \(.statement)" +
        (if .commit_count > 0 then "\n      \(.commit_count) commit(s), \(.files|length) file(s)" else "" end))
     end),
    "",
    "Additional changes (not predicted by any expected change):",
    (if (.additional_changes|length) == 0 then "  (none)" else
      (.additional_changes[] | "  - \(.sha[0:8]) \(.subject)") end)
  ' "$_tmp"
fi
