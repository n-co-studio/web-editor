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

# Set by _bm_rebase_onto_main() on failure: space-separated conflicting files
# (may be empty, e.g. when git refused to start because of a dirty tree) and a
# one-line description of what happened, including the post-abort verification.
_BM_REBASE_CONFLICT_FILES=""
_BM_REBASE_DETAIL=""

# --- Is a rebase in progress in <dir>? ---
# Returns 0 if rebase-merge/ or rebase-apply/ exists in the git dir of <dir>.
_bm_rebase_in_progress() {
  local dir="${1:-.}" p gp
  for p in rebase-merge rebase-apply; do
    gp=$(git -C "$dir" rev-parse --git-path "$p" 2>/dev/null) || continue
    case "$gp" in
      /*) ;;
      *) gp="$dir/$gp" ;;
    esac
    [ -d "$gp" ] && return 0
  done
  return 1
}

# --- Rebase the branch checked out in <dir> onto main, leaving it launchable ---
# On success returns 0. On failure: records the conflicting files, aborts the
# rebase IN <dir> (git -C, so the abort cannot run in the wrong directory),
# VERIFIES the abort took (no rebase in progress, no tracked changes), and
# returns 3. The branch ref is never moved by a failed rebase.
# Arguments:
#   $1 — directory holding the checkout (default: current directory)
_bm_rebase_onto_main() {
  local dir="${1:-.}" out
  _BM_REBASE_CONFLICT_FILES=""
  _BM_REBASE_DETAIL=""
  if out=$(git -C "$dir" rebase main 2>&1); then
    return 0
  fi
  _BM_REBASE_CONFLICT_FILES=$(git -C "$dir" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ' || true)
  _BM_REBASE_CONFLICT_FILES="${_BM_REBASE_CONFLICT_FILES% }"
  git -C "$dir" rebase --abort >/dev/null 2>&1 || true
  if _bm_rebase_in_progress "$dir"; then
    _BM_REBASE_DETAIL="rebase STILL in progress after abort in $dir"
  elif [ -n "$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null || true)" ]; then
    _BM_REBASE_DETAIL="tracked changes remain in $dir after abort"
  else
    # Return the checkout to main. `rebase --abort` restores HEAD to the branch
    # being rebased, so without this the worktree is left sitting on the
    # conflicting feature branch after a setup that selected no branch and
    # returned 3. A main worktree parked on a stray branch is precisely the
    # state that wedged the task-details-header group for two days: later
    # briefs found an unexpected branch and refused to launch.
    #
    # Only attempted after the abort has been VERIFIED clean above — checking
    # out over a dirty tree or an in-progress rebase would fail or, worse,
    # carry changes across. A failure here is reported in the detail string
    # rather than swallowed, because the caller is already escalating.
    # ONLY in the main worktree. A linked worktree must keep its own branch:
    # a task group's worktree exists to hold the group branch, and the next
    # brief of that group expects to find it there — checking out main in it
    # would break the group rather than protect it. A linked worktree has a
    # `.git` FILE; the main worktree has a `.git` DIRECTORY. That is a local
    # test needing no knowledge of who called.
    if [ -d "$dir/.git" ]; then
      if git -C "$dir" checkout main >/dev/null 2>&1; then
        _BM_REBASE_DETAIL="rebase aborted; $dir verified clean and restored to main ($(printf '%s' "$out" | tail -1 | tr -d '"\\'))"
      else
        _BM_REBASE_DETAIL="rebase aborted and $dir verified clean, but checkout of main FAILED — worktree left on $(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
      fi
    else
      _BM_REBASE_DETAIL="rebase aborted; $dir verified clean, left on its own branch (linked worktree) ($(printf '%s' "$out" | tail -1 | tr -d '"\\'))"
    fi
  fi
  return 3
}

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
# Returns: 0 on success, 1 on failure, 3 when Case 3's rebase onto main hit a
#   conflict (rebase aborted and verified clean; branch ref unchanged;
#   _BM_REBASE_CONFLICT_FILES / _BM_REBASE_DETAIL describe it).
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
        local _bm_rc=0
        if [ "$_wt_isolate" != "0" ]; then
          # Must checkout the branch to rebase — git rebase only updates the
          # branch ref when HEAD is on that branch
          git checkout "$safe_branch" 2>/dev/null || {
            echo "ERROR: Cannot checkout branch for rebase: $safe_branch" >&2
            return 1
          }
          _bm_rebase_onto_main "." || _bm_rc=$?
          # Restore HEAD to main so the main worktree stays on main
          git checkout main 2>/dev/null || true
        else
          git checkout "$safe_branch" 2>/dev/null || {
            echo "ERROR: Cannot checkout branch: $safe_branch" >&2
            return 1
          }
          _bm_rebase_onto_main "." || _bm_rc=$?
        fi
        if [ "$_bm_rc" -ne 0 ]; then
          # A branch left behind main is NOT launchable as-is: the session would
          # build on a stale base and the final merge would conflict. Report the
          # conflict so the caller can escalate before any worktree is created.
          echo "WARNING: Rebase of $safe_branch onto main failed — aborting rebase; branch left unchanged (conflicts: ${_BM_REBASE_CONFLICT_FILES:-none reported}; ${_BM_REBASE_DETAIL})" >&2
          return 3
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
