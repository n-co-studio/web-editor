#!/usr/bin/env bash
# Drift detector — post-session advisory drift detection for task group briefs.
# Sourced by runner.sh. NOT executed standalone.
# Decision 0017 — Operator Automation Layer.
#
# Compares brief scope (file references in brief text + contract boundaries)
# against actual git changes. Flags:
#   - Unexpected changes (files in diff but not in brief scope)
#   - Incomplete implementation (files in brief scope but not in diff)
#   - Boundary violations (task group edits outside declared boundaries)
#
# Output: advisory YAML notice appended to completed queue entry.
# Non-blocking — drift findings are informational.
#
# Depends on (sourced by runner.sh before this file):
#   runner.sh sets REPO_ROOT, AUTOMATION_DIR
#   queue-manager.sh — _load_queue_entry, _write_queue_entry, _queue_dir

set -euo pipefail

# --- Extract file references from brief text ---
# Patterns: paths with extensions (foo/bar.sh), YAML boundary list items.
# Arguments:
#   $1 — brief_text content
# Output: one path per line on stdout
_extract_brief_file_refs() {
  local text="$1"

  # Extract paths with file extensions (e.g., lib/foo.sh, .claude/agents/bar.md)
  # Match patterns like: word/word.ext or .word/word.ext (including dotfile paths)
  local ext_refs
  ext_refs=$(printf '%s' "$text" \
    | grep -oE '[.a-zA-Z0-9_/-]+\.[a-zA-Z]{1,10}' 2>/dev/null \
    | grep '/' \
    | grep -v '^http' \
    | sort -u || true)

  # Also extract from YAML boundaries list (lines matching '      - "path"')
  local boundary_refs
  boundary_refs=$(printf '%s' "$text" \
    | grep -oE '"[^"]*\.[a-zA-Z]{1,10}"' 2>/dev/null \
    | tr -d '"' \
    | sort -u || true)

  # Combine and deduplicate
  {
    [ -n "$ext_refs" ] && printf '%s\n' "$ext_refs"
    [ -n "$boundary_refs" ] && printf '%s\n' "$boundary_refs"
  } | sort -u
}

# --- Extract contract boundary paths ---
# Reads boundaries from the task group contract for a specific brief.
# Arguments:
#   $1 — contract_file path
#   $2 — brief_title (to locate the right brief's boundaries)
# Output: one path per line on stdout
_extract_contract_boundaries() {
  local contract_file="$1"
  local brief_title="$2"

  [ -f "$contract_file" ] || return

  # Extract module paths from boundaries section
  # Pattern: `    - module: "path"` or `    - module: path`
  sed -n '/^  boundaries:/,/^[a-z]/{ /module:/p; }' "$contract_file" 2>/dev/null \
    | sed 's/.*module: *//' \
    | tr -d '"' \
    | sort -u
}

# --- Resolve contract path for group ---
_resolve_contract() {
  local group_name="$1"
  local path=""

  # Searches BOTH roots: this session's first, then the main repo's. A task group
  # contract belongs to the GROUP, not to one brief, but inside a worktree session
  # $REPO_ROOT is the worktree root — so each brief used to read only its own
  # private copy, and `git worktree remove` destroyed the group's definition of
  # done along with the worktree (2026-10-19, task-details-header). The main copy
  # is the one that survives that; the session copy is the live one while a brief
  # runs. Session-first so a stale main copy cannot shadow a fresher session copy
  # when both exist. See the fuller note in cohesion-trigger.sh
  # `_resolve_contract_path`, and known-issue R17 for the writer side.
  local _dd_main_root
  _dd_main_root="$(get_main_repo_root 2>/dev/null)" || _dd_main_root=""
  [ -n "$_dd_main_root" ] || _dd_main_root="$REPO_ROOT"

  local _dd_root
  for _dd_root in "$REPO_ROOT" "$_dd_main_root"; do
    [ -n "$_dd_root" ] || continue
    path="$_dd_root/.claude/local/task-groups/${group_name}.yaml"
    [ -f "$path" ] && { printf '%s' "$path"; return; }

    path="$_dd_root/docs/ai/task-groups/${group_name}.yaml"
    [ -f "$path" ] && { printf '%s' "$path"; return; }
  done
}

# --- Check if a path matches a glob-style boundary ---
# Simple prefix/wildcard matching (boundaries often use * suffix).
# Arguments:
#   $1 — file path to check
#   $2 — boundary pattern
# Returns: 0 if match, 1 if no match
_path_matches_boundary() {
  local filepath="$1"
  local boundary="$2"

  # Remove trailing wildcard for prefix matching
  local prefix="${boundary%\*}"
  prefix="${prefix%/}"

  # Direct match
  if [ "$filepath" = "$boundary" ]; then
    return 0
  fi

  # Prefix match (boundary is a directory pattern)
  case "$filepath" in
    "${prefix}"/*) return 0 ;;
    "${prefix}") return 0 ;;
  esac

  return 1
}

# --- Check if file is within any of the declared boundaries ---
# Arguments:
#   $1 — file path
#   $2 — newline-delimited boundary list
# Returns: 0 if within boundaries, 1 if outside
_within_boundaries() {
  local filepath="$1"
  local boundaries="$2"

  [ -z "$boundaries" ] && return 0  # No boundaries = no restriction

  local boundary
  while IFS= read -r boundary || [ -n "$boundary" ]; do
    [ -z "$boundary" ] && continue
    if _path_matches_boundary "$filepath" "$boundary"; then
      return 0
    fi
  done <<< "$boundaries"

  return 1
}

# ============================================================
# Public API
# ============================================================

# --- Run drift detection for a completed entry ---
# Arguments:
#   $1 — entry_id (completed queue entry)
#   $2 — brief_text (the brief content used for this entry)
#   $3 — baseline_sha (git SHA before the session ran)
#   $4 — group_name (optional; enables boundary violation detection)
#   $5 — brief_title (optional; for contract boundary lookup)
run_drift_detection() {
  local entry_id="$1"
  local brief_text="$2"
  local baseline_sha="${3:-}"
  local group_name="${4:-}"
  local brief_title="${5:-}"

  if [ -z "$baseline_sha" ] || [ -z "$brief_text" ]; then
    return
  fi

  # Verify baseline SHA is valid
  if ! git cat-file -t "$baseline_sha" > /dev/null 2>&1; then
    return
  fi

  # Get actual changed files
  local actual_changes
  actual_changes=$(git diff --name-only "$baseline_sha"..HEAD 2>/dev/null | sort -u || true)

  if [ -z "$actual_changes" ]; then
    return  # No changes — nothing to detect
  fi

  # Extract expected files from brief
  local expected_files
  expected_files=$(_extract_brief_file_refs "$brief_text")

  # --- Unexpected changes: in diff but not in brief scope ---
  local unexpected=""
  local actual_file
  while IFS= read -r actual_file || [ -n "$actual_file" ]; do
    [ -z "$actual_file" ] && continue
    local found=false
    local expected
    while IFS= read -r expected || [ -n "$expected" ]; do
      [ -z "$expected" ] && continue
      if _path_matches_boundary "$actual_file" "$expected"; then
        found=true
        break
      fi
    done <<< "$expected_files"
    if [ "$found" = false ]; then
      if [ -z "$unexpected" ]; then
        unexpected="$actual_file"
      else
        unexpected="${unexpected}, ${actual_file}"
      fi
    fi
  done <<< "$actual_changes"

  # --- Incomplete implementation: in brief scope but not in diff ---
  local incomplete=""
  if [ -n "$expected_files" ]; then
    while IFS= read -r expected || [ -n "$expected" ]; do
      [ -z "$expected" ] && continue
      # Skip wildcard patterns (directories)
      case "$expected" in *"*"*) continue ;; esac
      local found=false
      while IFS= read -r actual_file || [ -n "$actual_file" ]; do
        [ -z "$actual_file" ] && continue
        if [ "$actual_file" = "$expected" ]; then
          found=true
          break
        fi
      done <<< "$actual_changes"
      if [ "$found" = false ]; then
        if [ -z "$incomplete" ]; then
          incomplete="$expected"
        else
          incomplete="${incomplete}, ${expected}"
        fi
      fi
    done <<< "$expected_files"
  fi

  # --- Boundary violations (task groups only) ---
  local violations=""
  if [ -n "$group_name" ]; then
    local contract_path
    contract_path=$(_resolve_contract "$group_name")
    if [ -n "$contract_path" ]; then
      local boundaries
      boundaries=$(_extract_contract_boundaries "$contract_path" "$brief_title")
      if [ -n "$boundaries" ]; then
        while IFS= read -r actual_file || [ -n "$actual_file" ]; do
          [ -z "$actual_file" ] && continue
          if ! _within_boundaries "$actual_file" "$boundaries"; then
            if [ -z "$violations" ]; then
              violations="$actual_file"
            else
              violations="${violations}, ${actual_file}"
            fi
          fi
        done <<< "$actual_changes"
      fi
    fi
  fi

  # --- Build advisory notice ---
  local has_findings=false
  local notice="drift-detection:"
  if [ -n "$unexpected" ]; then
    notice="${notice} unexpected_changes=[${unexpected}]"
    has_findings=true
  fi
  if [ -n "$incomplete" ]; then
    notice="${notice} incomplete_implementation=[${incomplete}]"
    has_findings=true
  fi
  if [ -n "$violations" ]; then
    notice="${notice} boundary_violations=[${violations}]"
    has_findings=true
  fi

  if [ "$has_findings" = false ]; then
    echo "drift-detector: no drift detected for entry $entry_id" >&2
    return
  fi

  echo "drift-detector: findings for entry $entry_id — $notice" >&2

  # Append notice to completed queue entry's error_log field
  local qdir
  qdir=$(_queue_dir)
  local entry_file="$qdir/completed/${entry_id}.yaml"
  if [ -f "$entry_file" ]; then
    _load_queue_entry "$entry_file"
    if [ -z "$_QE_ERROR_LOG" ]; then
      _QE_ERROR_LOG="$notice"
    else
      _QE_ERROR_LOG="${_QE_ERROR_LOG} | ${notice}"
    fi
    _write_queue_entry "$entry_file"
  fi
}
