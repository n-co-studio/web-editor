#!/usr/bin/env bash
# Branch manager — branch creation/checkout for headless runner sessions.
# Sourced by runner.sh. NOT executed standalone.
#
# Naming convention:
#   Standalone: feature/auto-<brief-id>-<timestamp>
#   Task group: operator supplies existing branch name via --branch
#
# Worktree isolation (Decision 0033):
#   When REPO_OS_WORKTREE_ISOLATE=1 (default), branch_manager_setup does NOT
#   checkout the feature branch — it only ensures the branch ref exists at the
#   right commit. The caller (runner.sh) creates a worktree targeting the branch.
#   When REPO_OS_WORKTREE_ISOLATE=0 (legacy), the original checkout behavior
#   is preserved for backward compatibility.
#
# Output: sets _SETUP_BRANCH to the branch name for the caller to use.

set -euo pipefail

# --- Global output variable ---
# Set by branch_manager_setup(), read by caller (runner.sh).
# Contains the branch name that was created or verified.
_SETUP_BRANCH=""

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
  local _wt_isolate="${REPO_OS_WORKTREE_ISOLATE:-1}"

  if [ -n "$existing_branch" ]; then
    local safe_branch
    safe_branch=$(sanitize_branch_name "$existing_branch")

    if git rev-parse --verify "$safe_branch" >/dev/null 2>&1; then
      # Branch exists — determine freshness relative to main
      if git merge-base --is-ancestor "$safe_branch" main 2>/dev/null; then
        # Case 1: Branch is ancestor of main (stale/merged) — delete and recreate
        echo "Branch $safe_branch exists but is ancestor of main — recreating from current main" >&2
        if [ "$_wt_isolate" != "0" ]; then
          git branch -D "$safe_branch" 2>/dev/null || true
          git branch "$safe_branch" main 2>/dev/null || {
            echo "ERROR: Cannot create branch: $safe_branch" >&2
            return 1
          }
        else
          git checkout main 2>/dev/null || {
            echo "ERROR: Cannot checkout main" >&2
            return 1
          }
          git branch -D "$safe_branch" 2>/dev/null || true
          git checkout -b "$safe_branch" 2>/dev/null || {
            echo "ERROR: Cannot create branch: $safe_branch" >&2
            return 1
          }
        fi
      elif ! git merge-base --is-ancestor main "$safe_branch" 2>/dev/null; then
        # Case 3: Branch has unique commits but is behind main — rebase
        echo "Branch $safe_branch is behind main — rebasing onto current main" >&2
        if [ "$_wt_isolate" != "0" ]; then
          # Must checkout the branch to rebase — git rebase only updates the
          # branch ref when HEAD is on that branch
          git checkout "$safe_branch" 2>/dev/null || {
            echo "ERROR: Cannot checkout branch for rebase: $safe_branch" >&2
            return 1
          }
          if ! git rebase main 2>/dev/null; then
            echo "WARNING: Rebase of $safe_branch onto main failed — aborting rebase, continuing branch as-is" >&2
            git rebase --abort 2>/dev/null || true
          fi
          # Restore HEAD to main so the main worktree stays on main
          git checkout main 2>/dev/null || true
        else
          git checkout "$safe_branch" 2>/dev/null || {
            echo "ERROR: Cannot checkout branch: $safe_branch" >&2
            return 1
          }
          if ! git rebase main 2>/dev/null; then
            echo "WARNING: Rebase of $safe_branch onto main failed — aborting rebase, continuing on branch as-is" >&2
            git rebase --abort 2>/dev/null || true
          fi
        fi
      else
        # Case 2: Branch is ahead of main and main is ancestor — no-op or checkout
        if [ "$_wt_isolate" != "0" ]; then
          : # No-op: branch exists and is ahead of main, no checkout needed
        else
          git checkout "$safe_branch" 2>/dev/null || {
            echo "ERROR: Cannot checkout branch: $safe_branch" >&2
            return 1
          }
        fi
      fi
    else
      # Branch doesn't exist yet — create from main (task group Brief 1)
      if [ "$_wt_isolate" != "0" ]; then
        git branch "$safe_branch" main 2>/dev/null || {
          echo "ERROR: Cannot create branch: $safe_branch" >&2
          return 1
        }
      else
        git checkout main 2>/dev/null || {
          echo "ERROR: Cannot checkout main" >&2
          return 1
        }
        git checkout -b "$safe_branch" 2>/dev/null || {
          echo "ERROR: Cannot create branch: $safe_branch" >&2
          return 1
        }
      fi
    fi
    _SETUP_BRANCH="$safe_branch"
  else
    # Standalone: create new branch from main
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local raw_name="feature/auto-${brief_id}-${timestamp}"
    local safe_name
    safe_name=$(sanitize_branch_name "$raw_name")

    if [ "$_wt_isolate" != "0" ]; then
      git branch "$safe_name" main 2>/dev/null || {
        echo "ERROR: Cannot create branch: $safe_name" >&2
        return 1
      }
    else
      git checkout main 2>/dev/null || {
        echo "ERROR: Cannot checkout main" >&2
        return 1
      }
      git checkout -b "$safe_name" 2>/dev/null || {
        echo "ERROR: Cannot create branch: $safe_name" >&2
        return 1
      }
    fi
    _SETUP_BRANCH="$safe_name"
  fi
}
