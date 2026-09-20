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
VERDICTS=""
FORMAT="json"

while [ $# -gt 0 ]; do
  case "$1" in
    --range)    RANGE="${2:-}"; shift 2 ;;
    --bundle)   BUNDLE="${2:-}"; shift 2 ;;
    --verdicts) VERDICTS="${2:-}"; shift 2 ;;
    --text)     FORMAT="text"; shift ;;
    --json)     FORMAT="json"; shift ;;
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
      # Emit the completed record INCLUDING vby, then clear every per-record
      # field. Omitting vby here dropped it for all but the last entry, and
      # failing to reset it carried the criteria of one EC onto the next.
      # NB: no apostrophes in this comment — it lives inside a single-quoted
      # shell string, so one would terminate the awk program early.
      if (id != "") { print id "\t" stmt "\t" vby }
      line=$0
      sub(/^.*id:[[:space:]]*/, "", line)
      gsub(/^["\047]|["\047][[:space:]]*$/, "", line)
      id=line; stmt=""; vby=""
      next
    }
    in_ec && /statement:/ {
      line=$0
      sub(/^.*statement:[[:space:]]*/, "", line)
      gsub(/^["\047]|["\047][[:space:]]*$/, "", line)
      stmt=line
      next
    }
    in_ec && /verified_by:/ {
      line=$0
      sub(/^.*verified_by:[[:space:]]*/, "", line)
      gsub(/[][ ]/, "", line)
      vby=line
      next
    }
    END { if (id != "") print id "\t" stmt "\t" vby }
  ' "$BUNDLE" 2>/dev/null)
fi

# --- Empty-range guard -----------------------------------------------------
# Once a branch is merged, `main...HEAD` is empty (nothing is unique to HEAD),
# so every EC would report not-started — the exact opposite of the truth, and
# silently. A UI showing "nothing delivered" for completed work is worse than
# showing nothing at all, so say so loudly and flag it in the JSON.
RANGE_COMMITS=$(git rev-list --no-merges --count "$RANGE" 2>/dev/null || echo 0)
RANGE_EMPTY=false
if [ "${RANGE_COMMITS:-0}" -eq 0 ]; then
  RANGE_EMPTY=true
  echo "ec-report: WARNING — range '$RANGE' contains no commits." >&2
  echo "  If this brief is already merged, its commits are no longer unique to HEAD." >&2
  echo "  Pass an explicit range, e.g. --range <fork-point>..<branch-tip>, or the" >&2
  echo "  merge commit's range. Statuses below are NOT meaningful as they stand." >&2
fi

# --- Lifecycle: is this brief closed? --------------------------------------
# "delivered" must mean more than "a commit exists". Two honest signals:
#   1. a task-group completion marker for this brief, or
#   2. the branch is merged (HEAD is an ancestor of main).
# Neither present → work is recorded but not finished → in-progress.
BRIEF_CLOSED=0
if ls "$REPO_ROOT"/.claude/.state/tg-*.complete >/dev/null 2>&1; then
  BRIEF_CLOSED=1
fi
# Check against whichever integration branch this repo actually uses. The
# template standardises on main, but a child repo may still be on master, and
# hardcoding main there would report merged work as in-progress forever.
for _base in main master; do
  [ "$BRIEF_CLOSED" = "0" ] || break
  git rev-parse --verify "$_base" >/dev/null 2>&1 || continue
  git merge-base --is-ancestor HEAD "$_base" 2>/dev/null && BRIEF_CLOSED=1
done

# --- Critic per-criterion verdicts (Decision t-0048) -----------------------
# Emits: index \t contract_verification \t completeness \t evidence
# Later rounds overwrite earlier ones for the same index, so processing the
# whole file naturally yields the most recent round's verdict per criterion.
if [ -z "$VERDICTS" ]; then
  VERDICTS=$(ls -t "$REPO_ROOT"/docs/ai/governance/criteria-verdicts/*.yaml 2>/dev/null | head -1)
fi
VERDICT_TSV=""
if [ -n "$VERDICTS" ] && [ -f "$VERDICTS" ]; then
  VERDICT_TSV=$(awk '
    /^[[:space:]]*-[[:space:]]*index:[[:space:]]*[0-9]+/ {
      line=$0; sub(/^.*index:[[:space:]]*/, "", line); gsub(/[^0-9]/, "", line)
      idx=line; blk=""; next
    }
    /^[[:space:]]*contract_verification:/ { blk="cv"; next }
    /^[[:space:]]*completeness:/          { blk="cm"; next }
    # \047 is an apostrophe. Writing it that way keeps this awk program free of
    # literal apostrophes, which would otherwise need shell quote-nesting and
    # make the script fragile to a one-character slip.
    # NB: this comment must itself stay apostrophe-free. It sits inside a
    # single-quoted shell string, so the shell counts every apostrophe here
    # even though awk treats the line as a comment.
    /^[[:space:]]*verdict:/ && idx != "" {
      line=$0; sub(/^.*verdict:[[:space:]]*/, "", line)
      gsub(/^["\047]|["\047][[:space:]]*$/, "", line); gsub(/[[:space:]]+$/, "", line)
      if (blk == "cv") cv[idx]=line
      else if (blk == "cm") cm[idx]=line
      next
    }
    /^[[:space:]]*evidence:/ && idx != "" && blk == "cv" {
      line=$0; sub(/^.*evidence:[[:space:]]*/, "", line)
      gsub(/^["\047]|["\047][[:space:]]*$/, "", line)
      gsub(/\t/, " ", line)
      ev[idx]=line; next
    }
    END { for (i in cv) print i "\t" cv[i] "\t" (i in cm ? cm[i] : "") "\t" (i in ev ? ev[i] : "") }
  ' "$VERDICTS" 2>/dev/null)
fi

# Aggregate a verification state across the criteria an EC points at.
# Worst verdict wins — a single UNVERIFIED is not cancelled out by four
# VERIFIEDs, and reporting otherwise would overstate confidence.
_verification_state() {
  local list="$1"
  [ -n "$list" ] || { echo "not-linked"; return; }
  [ -n "$VERDICT_TSV" ] || { echo "pending"; return; }
  local worst="verified" found=0 i cv cm
  for i in $(printf '%s' "$list" | tr ',' ' '); do
    [ -n "$i" ] || continue
    cv=$(printf '%s\n' "$VERDICT_TSV" | awk -F'\t' -v k="$i" '$1==k{print $2; exit}')
    cm=$(printf '%s\n' "$VERDICT_TSV" | awk -F'\t' -v k="$i" '$1==k{print $3; exit}')
    [ -n "$cv$cm" ] || continue
    found=1
    case "$cv" in UNVERIFIED) worst="unverified" ;; esac
    case "$cm" in INCOMPLETE) worst="unverified" ;; esac
    if [ "$worst" != "unverified" ]; then
      case "$cv" in INCONCLUSIVE) worst="inconclusive" ;; esac
      case "$cm" in PARTIAL) worst="inconclusive" ;; esac
    fi
  done
  [ "$found" = "0" ] && { echo "pending"; return; }
  echo "$worst"
}

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
  printf '  "range_empty": %s,\n' "$RANGE_EMPTY"
  printf '  "expected_changes": [\n'

  first=1
  if [ -n "$EC_TSV" ]; then
    while IFS=$'\t' read -r id stmt vby; do
      [ -n "$id" ] || continue
      shas=$(awk -F'\t' -v i="$id" '$1==i{print $2}' "$_tmp.att")
      n=$(printf '%s\n' "$shas" | awk 'NF' | wc -l | tr -d ' ')
      # Lifecycle and verification are independent axes. An EC can be
      # delivered-and-unverified, or verified-but-still-in-progress; collapsing
      # them into one enum would force a precedence that discards information.
      if [ "$n" -eq 0 ]; then status="not-started"
      elif [ "$BRIEF_CLOSED" = "1" ]; then status="delivered"
      else status="in-progress"
      fi
      vstate=$(_verification_state "$vby")
      files=$(printf '%s\n' "$shas" | _files_for)

      crit_json="[]"
      if [ -n "$vby" ] && [ -n "$VERDICT_TSV" ]; then
        crit_json=$(for i in $(printf '%s' "$vby" | tr ',' ' '); do
            [ -n "$i" ] || continue
            printf '%s\n' "$VERDICT_TSV" | awk -F'\t' -v k="$i" '$1==k{print}'
          done | jq -R -s 'split("\n")|map(select(length>0)|split("\t")|
                {index:(.[0]|tonumber? // .[0]), contract_verification:.[1],
                 completeness:.[2], evidence:.[3]})')
      fi

      [ "$first" = "0" ] && printf ',\n'
      first=0
      printf '    {"id": %s, "statement": %s, "status": %s, "verification": %s, "commit_count": %s,\n' \
        "$(jq -Rn --arg v "$id" '$v')" "$(jq -Rn --arg v "$stmt" '$v')" \
        "$(jq -Rn --arg v "$status" '$v')" "$(jq -Rn --arg v "$vstate" '$v')" "$n"
      printf '     "criteria": %s,\n' "$crit_json"
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
        "  [\(if .status=="delivered" then "x" elif .status=="in-progress" then "~" else " " end)] \(.id): \(.statement)" +
        "\n      status: \(.status)   verification: \(.verification)" +
        (if .commit_count > 0 then "\n      \(.commit_count) commit(s), \(.files|length) file(s)" else "" end) +
        (if (.criteria|length) > 0 then
          ([.criteria[] | "\n      · criterion \(.index): \(.contract_verification)/\(.completeness)"] | join(""))
         else "" end))
     end),
    "",
    "Additional changes (not predicted by any expected change):",
    (if (.additional_changes|length) == 0 then "  (none)" else
      (.additional_changes[] | "  - \(.sha[0:8]) \(.subject)") end)
  ' "$_tmp"
fi
