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
# Creates a new branch from main (standalone) or checks out / creates an
# existing branch (task group). For task groups the branch is checked for
# freshness against main:
#   Case 1: Branch is ancestor of main (stale/merged) — delete and recreate from main
#   Case 2: Branch is ahead of main, main is ancestor — checkout as-is (Brief 2+)
#   Case 3: Branch has commits ahead AND behind main — checkout and rebase onto main
# If the branch doesn't exist yet, create from main (Brief 1).
# Arguments:
#   $1 — brief_id (used for standalone branch naming)
#   $2 — existing_branch (optional; if set, create-or-checkout instead of auto-naming)
# Returns: 0 on success, 1 on failure
branch_manager_setup() {
  local brief_id="$1"
  local existing_branch="${2:-}"

  if [ -n "$existing_branch" ]; then
    local safe_branch
    safe_branch=$(sanitize_branch_name "$existing_branch")

    if git rev-parse --verify "$safe_branch" >/dev/null 2>&1; then
      # Branch exists — determine freshness relative to main
      if git merge-base --is-ancestor "$safe_branch" main 2>/dev/null; then
        # Case 1: Branch is ancestor of main (stale/merged) — delete and recreate
        echo "Branch $safe_branch exists but is ancestor of main — recreating from current main" >&2
        git checkout main 2>/dev/null || {
          echo "ERROR: Cannot checkout main" >&2
          return 1
        }
        git branch -D "$safe_branch" 2>/dev/null || true
        git checkout -b "$safe_branch" 2>/dev/null || {
          echo "ERROR: Cannot create branch: $safe_branch" >&2
          return 1
        }
      elif ! git merge-base --is-ancestor main "$safe_branch" 2>/dev/null; then
        # Case 3: Branch has unique commits but is behind main — checkout and rebase
        echo "Branch $safe_branch is behind main — rebasing onto current main" >&2
        git checkout "$safe_branch" 2>/dev/null || {
          echo "ERROR: Cannot checkout branch: $safe_branch" >&2
          return 1
        }
        if ! git rebase main 2>/dev/null; then
          echo "WARNING: Rebase of $safe_branch onto main failed — aborting rebase, continuing on branch as-is" >&2
          git rebase --abort 2>/dev/null || true
        fi
      else
        # Case 2: Branch is ahead of main and main is ancestor — normal checkout
        git checkout "$safe_branch" 2>/dev/null || {
          echo "ERROR: Cannot checkout branch: $safe_branch" >&2
          return 1
        }
      fi
    else
      # Branch doesn't exist yet — create from main
      git checkout main 2>/dev/null || {
        echo "ERROR: Cannot checkout main" >&2
        return 1
      }
      git checkout -b "$safe_branch" 2>/dev/null || {
        echo "ERROR: Cannot create branch: $safe_branch" >&2
        return 1
      }
    fi
  else
    # Standalone: create new branch from main
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
