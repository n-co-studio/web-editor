#!/usr/bin/env bash
# _mechanism-helper.sh — what "the enforcement mechanism" is, and what counts as
# fresh evidence that a change to it was verified (Decision t-0063).
#
# Sourced by pre-commit-gates.sh and .claude/tools/verify-pristine.sh so the gate
# and the tool cannot disagree. gate-conformance.sh deliberately does NOT source
# this file: it re-implements the hash independently so a defect here cannot make
# the conformance run agree with itself.
#
# Sourcing has no side effects. Bash 3.2 compatible; safe under `set -euo pipefail`.

MECH_EVIDENCE_DIR="docs/ai/governance/pristine-evidence"

# mech_is_path <path> — 0 if the path is part of the enforcement mechanism:
# hooks, tools, automation scripts (runner, libs, tests) and settings.json.
# Prose (agents, READMEs, decisions, specs) and product code are not.
mech_is_path() {
  case "$1" in
    .claude/settings.json) return 0 ;;
    .claude/hooks/*.sh|.claude/tools/*.sh|.claude/.automation/*.sh) return 0 ;;
  esac
  return 1
}

# mech_is_test_path <path> — 0 if the path is a copy-in-able test file. Harness
# files (test-helpers.sh, test-fixtures.sh, run-*.sh, sandbox-*.sh) are NOT tests:
# copying them into a pristine checkout would let a change carry its own altered
# harness into the checkout meant to be free of it.
mech_is_test_path() {
  case "$1" in
    .claude/hooks/tests/test-helpers.sh|.claude/hooks/tests/test-fixtures.sh) return 1 ;;
    .claude/hooks/tests/layer*.sh|.claude/hooks/tests/test-*.sh) return 0 ;;
    .claude/.automation/tests/test-*.sh) return 0 ;;
  esac
  return 1
}

# mech_filter "<newline list>" — keep only mechanism paths, in order.
mech_filter() {
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if mech_is_path "$line"; then printf '%s\n' "$line"; fi
  done <<EOF
$1
EOF
  return 0
}

# mech_change_hash "<newline list>" — hash of the INDEX state of the listed paths
# (mode + blob, or "deleted" when the path is no longer in the index), run from
# anywhere inside the repo. Empty list -> empty output. Order-insensitive; a
# working-tree-only edit does not move it, a mode flip or a deletion does.
mech_change_hash() {
  local list="$1" line state lines="" top
  [ -n "$list" ] || return 0
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    state=$(git -C "$top" ls-files -s -- "$line" 2>/dev/null | awk 'NR==1 {print $1 "," $2}') || state=""
    [ -n "$state" ] || state="deleted"
    lines="${lines}${line} ${state}"$'\n'
  done <<EOF
$list
EOF
  [ -n "$lines" ] || return 0
  printf '%s' "$lines" | LC_ALL=C sort | git hash-object --stdin
}

# _mech_field <yaml-text> <key> — first value of `key: value`.
_mech_field() {
  printf '%s\n' "$1" | awk -v k="$2" '
    index($0, k ":") == 1 { sub("^" k ":[ \t]*", ""); print; exit }'
}

# mech_evidence_status "<newline list>" — run from inside the repo. Prints:
#   none                                  no evidence file is in the index
#   stale                                 evidence exists but does not fit this change
#   empty                                 evidence fits but the run executed no test at all
#   fresh outcome=X pass=N fail=M         evidence matches
# Evidence is read from the INDEX (a file only in the working tree does not count)
# and must match the change hash AND name a merge_base that is an ancestor of HEAD.
# A run that counted zero passes and zero failures verified nothing and is `empty`
# (a tool_error record is the one exception: it is reported as such, not as empty).
mech_evidence_status() {
  local list="$1" cur f body h mb outcome pass fail any=0 top empties=0
  cur=$(mech_change_hash "$list")
  top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo none; return 0; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    any=1
    body=$(git -C "$top" show ":$f" 2>/dev/null) || continue
    h=$(_mech_field "$body" change_hash)
    mb=$(_mech_field "$body" merge_base)
    [ -n "$cur" ] && [ "$h" = "$cur" ] || continue
    [ -n "$mb" ] || continue
    git -C "$top" merge-base --is-ancestor "$mb" HEAD >/dev/null 2>&1 || continue
    outcome=$(_mech_field "$body" outcome)
    pass=$(_mech_field "$body" pass)
    fail=$(_mech_field "$body" fail)
    case "${pass:-0}${fail:-0}" in *[!0-9]*) pass=0; fail=0 ;; esac
    if [ "${outcome:-unknown}" != "tool_error" ] && [ $(( ${pass:-0} + ${fail:-0} )) -eq 0 ]; then
      empties=1
      continue
    fi
    printf 'fresh outcome=%s pass=%s fail=%s\n' "${outcome:-unknown}" "${pass:-0}" "${fail:-0}"
    return 0
  done <<EOF
$(git -C "$top" ls-files -- "$MECH_EVIDENCE_DIR" 2>/dev/null)
EOF
  if [ "$empties" = 1 ]; then echo empty
  elif [ "$any" = 1 ]; then echo stale
  else echo none; fi
  return 0
}
