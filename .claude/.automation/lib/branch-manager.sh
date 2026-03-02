#!/usr/bin/env bash
# Branch manager — branch creation/checkout for headless runner sessions.
# Sourced by runner.sh. NOT executed standalone.
#
# Naming convention:
#   Standalone: feature/auto-<brief-id>-<timestamp>
#   Task group: operator supplies existing branch name via --branch

set -euo pipefail

# --- Sanitize a branch name to safe characters ---
# Whitelist: [a-zA-Z0-9/_-]. Everything else replaced with -.
# Collapses consecutive dashes, strips leading/trailing dashes.
# Truncates to 100 characters.
# Arguments:
#   $1 — raw branch name
# Output: sanitized name on stdout
sanitize_branch_name() {
  local raw="$1"
  local clean

  # Replace disallowed chars with -
  clean=$(printf '%s' "$raw" | tr -c 'a-zA-Z0-9/_\-\n' '-')

  # Collapse consecutive dashes (Bash 3.2 compatible loop)
  while true; do
    case "$clean" in
      *--*) clean="${clean//--/-}" ;;
      *) break ;;
    esac
  done

  # Strip leading/trailing dashes
  clean="${clean#-}"
  clean="${clean%-}"

  # Truncate to 100 chars
  clean="${clean:0:100}"

  printf '%s' "$clean"
}

# --- Branch setup ---
# Creates a new branch from main (standalone) or checks out an existing
# branch (task group brief 2+).
# Arguments:
#   $1 — brief_id (used for standalone branch naming)
#   $2 — existing_branch (optional; if set, checks out instead of creating)
# Returns: 0 on success, 1 on failure
branch_manager_setup() {
  local brief_id="$1"
  local existing_branch="${2:-}"

  if [ -n "$existing_branch" ]; then
    # Task group brief 2+: checkout existing branch
    local safe_branch
    safe_branch=$(sanitize_branch_name "$existing_branch")
    git checkout "$safe_branch" 2>/dev/null || {
      echo "ERROR: Cannot checkout branch: $safe_branch" >&2
      return 1
    }
  else
    # Standalone or first brief: create new branch from main
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local raw_name="feature/auto-${brief_id}-${timestamp}"
    local safe_name
    safe_name=$(sanitize_branch_name "$raw_name")

    git checkout main 2>/dev/null || {
      echo "ERROR: Cannot checkout main" >&2
      return 1
    }
    git checkout -b "$safe_name" 2>/dev/null || {
      echo "ERROR: Cannot create branch: $safe_name" >&2
      return 1
    }
  fi
}
