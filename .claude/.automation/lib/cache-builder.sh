#!/usr/bin/env bash
# Cache builder — two-level decision cache merge for prompt assembly.
# Sourced by runner.sh. NOT executed standalone.
# Decision 0017 — Operator Automation Layer.
#
# Merges project-level (.claude/.automation/decision-cache.yaml) and
# local-level (.claude/.automation/local-decision-cache.yaml) caches.
# Local can extend or narrow, never elevate (can't change REQUIRE→GUIDE).
# Merged output: max 10 entries prepended to assembled prompt.
#
# Depends on (sourced by runner.sh before this file):
#   runner.sh sets REPO_ROOT

set -euo pipefail

# --- Enforcement severity ranking (higher = stricter) ---
_enforcement_rank() {
  case "$1" in
    BLOCK)   echo 3 ;;
    REQUIRE) echo 2 ;;
    GUIDE)   echo 1 ;;
    *)       echo 0 ;;
  esac
}

# --- Max entries in merged output ---
_MAX_CACHE_ENTRIES=10

# --- Parse a decision cache YAML file ---
# Reads entries into parallel arrays via nameref.
# Cache format:
#   entries:
#     - number: "0001"
#       summary: "one-line description"
#       enforcement: REQUIRE
#
# Arguments:
#   $1 — file path
# Output: lines of "number|summary|enforcement" on stdout (one per entry)
_parse_decision_cache() {
  local cache_file="$1"
  [ -f "$cache_file" ] || return 0

  local _num="" _sum="" _enf="" _in_entries=false
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      "entries:")
        _in_entries=true
        continue
        ;;
    esac

    [ "$_in_entries" = true ] || continue

    case "$_line" in
      "  - number: "*)
        # Emit previous entry if complete
        if [ -n "$_num" ] && [ -n "$_sum" ] && [ -n "$_enf" ]; then
          printf '%s|%s|%s\n' "$_num" "$_sum" "$_enf"
        fi
        _num="${_line#  - number: }"
        _num=$(printf '%s' "$_num" | tr -d '"'"'")
        _sum=""
        _enf=""
        ;;
      "    summary: "*)
        _sum="${_line#    summary: }"
        _sum=$(printf '%s' "$_sum" | tr -d '"'"'")
        ;;
      "    enforcement: "*)
        _enf="${_line#    enforcement: }"
        _enf=$(printf '%s' "$_enf" | tr -d '[:space:]"'"'")
        ;;
    esac
  done < "$cache_file"

  # Emit last entry
  if [ -n "$_num" ] && [ -n "$_sum" ] && [ -n "$_enf" ]; then
    printf '%s|%s|%s\n' "$_num" "$_sum" "$_enf"
  fi
}

# ============================================================
# Public API
# ============================================================

# --- Build merged decision cache ---
# Merges project and local caches. Local can extend or narrow, never elevate.
# Output: formatted cache lines on stdout (max 10).
# Format per line: "Decision NNNN: summary (MECHANISM)"
build_decision_cache() {
  local project_file="$REPO_ROOT/.claude/.automation/decision-cache.yaml"
  local local_file="$REPO_ROOT/.claude/.automation/local-decision-cache.yaml"

  # Parse both caches
  local project_entries="" local_entries=""
  project_entries=$(_parse_decision_cache "$project_file")
  local_entries=$(_parse_decision_cache "$local_file")

  # No entries at all — return empty
  if [ -z "$project_entries" ] && [ -z "$local_entries" ]; then
    return 0
  fi

  # Build merged set: start with project entries, apply local overrides
  # Using associative approach via sorted merge
  local merged=""

  # Add all project entries (ensure trailing newline for safe concatenation)
  if [ -n "$project_entries" ]; then
    merged="$project_entries
"
  fi

  # Process local entries: extend or narrow, never elevate
  if [ -n "$local_entries" ]; then
    local _lline
    while IFS= read -r _lline; do
      [ -n "$_lline" ] || continue
      local l_num="${_lline%%|*}"
      local l_rest="${_lline#*|}"
      local l_sum="${l_rest%%|*}"
      local l_enf="${l_rest#*|}"

      # Check if this number exists in project entries
      local found=false p_enf_val=""
      if [ -n "$project_entries" ]; then
        local _pline
        while IFS= read -r _pline; do
          [ -n "$_pline" ] || continue
          local p_num="${_pline%%|*}"
          if [ "$p_num" = "$l_num" ]; then
            found=true
            local p_rest="${_pline#*|}"
            p_enf_val="${p_rest#*|}"
            break
          fi
        done <<< "$project_entries"
      fi

      if [ "$found" = true ]; then
        # Override: never elevate (local enforcement must be >= project)
        local p_rank l_rank
        p_rank=$(_enforcement_rank "$p_enf_val")
        l_rank=$(_enforcement_rank "$l_enf")
        if [ "$l_rank" -lt "$p_rank" ]; then
          # Attempted elevation — keep project-level enforcement, use local summary
          l_enf="$p_enf_val"
        fi
        # Replace project entry with merged version
        local new_merged=""
        local _mline
        while IFS= read -r _mline; do
          [ -n "$_mline" ] || continue
          local m_num="${_mline%%|*}"
          if [ "$m_num" = "$l_num" ]; then
            new_merged="${new_merged}${l_num}|${l_sum}|${l_enf}
"
          else
            new_merged="${new_merged}${_mline}
"
          fi
        done <<< "$merged"
        merged="$new_merged"
      else
        # New entry from local — extend
        merged="${merged}${_lline}
"
      fi
    done <<< "$local_entries"
  fi

  # Output max 10 entries in formatted form
  local count=0
  local _oline
  while IFS= read -r _oline; do
    [ -n "$_oline" ] || continue
    [ "$count" -lt "$_MAX_CACHE_ENTRIES" ] || break

    local o_num="${_oline%%|*}"
    local o_rest="${_oline#*|}"
    local o_sum="${o_rest%%|*}"
    local o_enf="${o_rest#*|}"

    printf 'Decision %s: %s (%s)\n' "$o_num" "$o_sum" "$o_enf"
    count=$((count + 1))
  done <<< "$merged"
}
