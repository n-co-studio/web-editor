#!/usr/bin/env bash
# template-sync-engine.sh — Custom template sync engine for child repos.
#
# Replaces PR-based actions-template-sync with a direct-push model.
# Runs inside GitHub Actions on child repos.
#
# Usage:
#   bash template-sync-engine.sh <template-repo-url> [<branch>]
#
# Arguments:
#   $1 — Template repository URL (HTTPS or SSH)
#   $2 — Template branch to sync from (default: main)
#
# Requirements:
#   - Git repository with write access to main
#   - .templatesyncignore in repo root (optional — if absent, all files synced)
#   - child-sync-decisions.sh in .claude/.automation/lib/ (optional — skipped if absent)
#
# Exit codes:
#   0  Sync completed (with or without changes)
#   1  Fatal error (bad args, fetch failure, push rejection)
#
# Decision 0015 — solo mode: sync is PR-free, direct commit to main
# Decision 0022 — template decision naming: integrates with child-sync-decisions.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# --- Arguments ---
TEMPLATE_REPO="${1:-}"
TEMPLATE_BRANCH="${2:-main}"

if [ -z "$TEMPLATE_REPO" ]; then
  echo "ERROR: Template repository URL required." >&2
  echo "Usage: template-sync-engine.sh <template-repo-url> [<branch>]" >&2
  exit 1
fi

# --- Constants ---
REMOTE_NAME="_template_upstream"
SYNCIGNORE="$REPO_ROOT/.templatesyncignore"
# Extract repo name from URL for safe logging (strip token, protocol, .git suffix)
TEMPLATE_REPO_NAME=$(echo "$TEMPLATE_REPO" | sed -E 's|https?://[^@]*@github\.com/||; s|https?://github\.com/||; s|\.git$||')
BEGIN_MARKER="# BEGIN REPO-OS MANAGED — template-sync, see AI.md"
END_MARKER="# END REPO-OS MANAGED"
MANAGED_COMMENT="# DO NOT EDIT between these markers — managed by template-sync"

# --- Logging ---
log() {
  printf '[template-sync] %s\n' "$*"
}

# --- Add template remote and fetch ---
setup_template_remote() {
  # Remove stale remote if it exists
  git remote remove "$REMOTE_NAME" 2>/dev/null || true

  log "Adding template remote: $TEMPLATE_REPO ($TEMPLATE_BRANCH)"
  git remote add "$REMOTE_NAME" "$TEMPLATE_REPO"
  git fetch "$REMOTE_NAME" "$TEMPLATE_BRANCH" --depth=1 || {
    echo "ERROR: Failed to fetch from template repo: $TEMPLATE_REPO" >&2
    git remote remove "$REMOTE_NAME" 2>/dev/null || true
    exit 1
  }
}

# --- Read .templatesyncignore ---
# Returns list of excluded patterns, one per line.
# Directories end with /, files are exact paths.
read_syncignore() {
  if [ ! -f "$SYNCIGNORE" ]; then
    return
  fi
  grep -v '^#' "$SYNCIGNORE" | grep -v '^[[:space:]]*$' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//'
}

# --- Check if a path is excluded by .templatesyncignore ---
# $1 — relative file path from repo root
# Returns 0 if excluded, 1 if not excluded.
is_excluded() {
  local file_path="$1"

  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue

    # Directory pattern (trailing /)
    if [[ "$pattern" == */ ]]; then
      local dir_prefix="${pattern%/}"
      if [[ "$file_path" == "$dir_prefix/"* ]] || [ "$file_path" = "$dir_prefix" ]; then
        return 0
      fi
    else
      # Exact file match
      if [ "$file_path" = "$pattern" ]; then
        return 0
      fi
    fi
  done < <(read_syncignore)

  return 1
}

# --- Copy files from template tree to working tree ---
sync_files() {
  local template_ref="$REMOTE_NAME/$TEMPLATE_BRANCH"
  local file_count=0
  local skip_count=0

  log "Syncing files from $template_ref..."

  # List all files in the template tree
  while IFS= read -r file_path; do
    [ -z "$file_path" ] && continue

    # Check exclusions
    if is_excluded "$file_path"; then
      skip_count=$((skip_count + 1))
      continue
    fi

    # Ensure parent directory exists
    local dir
    dir=$(dirname "$REPO_ROOT/$file_path")
    mkdir -p "$dir"

    # Extract file from template tree and write to working tree
    git show "$template_ref:$file_path" > "$REPO_ROOT/$file_path" 2>/dev/null || {
      log "  WARN: Could not extract $file_path — skipping"
      continue
    }

    file_count=$((file_count + 1))
  done < <(git ls-tree -r --name-only "$template_ref")

  log "Synced $file_count file(s), skipped $skip_count excluded"
}

# --- .gitignore section-marker merge ---
# Reads template's .gitignore managed block entries and merges them into
# the child's .gitignore using section markers.
merge_gitignore() {
  local template_ref="$REMOTE_NAME/$TEMPLATE_BRANCH"
  local template_gitignore
  local child_gitignore="$REPO_ROOT/.gitignore"

  # Extract template's .gitignore
  template_gitignore=$(git show "$template_ref:.gitignore" 2>/dev/null || true)
  if [ -z "$template_gitignore" ]; then
    log ".gitignore: No template .gitignore found — skipping merge"
    return
  fi

  # Extract the managed block from template's .gitignore
  local managed_block
  managed_block=$(printf '%s\n' "$template_gitignore" | awk -v begin="$BEGIN_MARKER" -v end_marker="$END_MARKER" '
    $0 == begin { capture=1; next }
    $0 == end_marker { capture=0; next }
    capture { print }
  ')

  if [ -z "$managed_block" ]; then
    log ".gitignore: No managed block found in template — skipping merge"
    return
  fi

  # Build the full replacement block
  local full_block
  full_block=$(printf '%s\n%s\n%s\n%s' "$BEGIN_MARKER" "$MANAGED_COMMENT" "$managed_block" "$END_MARKER")

  # If child .gitignore doesn't exist, create it with the managed block
  if [ ! -f "$child_gitignore" ]; then
    printf '%s\n' "$full_block" > "$child_gitignore"
    log ".gitignore: Created with managed block"
    return
  fi

  # Check marker state in child's .gitignore
  local has_begin=false
  local has_end=false
  grep -qF "$BEGIN_MARKER" "$child_gitignore" 2>/dev/null && has_begin=true
  grep -qF "$END_MARKER" "$child_gitignore" 2>/dev/null && has_end=true

  if [ "$has_begin" = true ] && [ "$has_end" = true ]; then
    # Both markers present — replace the block between them (atomic)
    awk -v begin="$BEGIN_MARKER" -v end_marker="$END_MARKER" -v managed_comment="$MANAGED_COMMENT" -v block="$managed_block" '
      $0 == begin {
        print begin
        print managed_comment
        print block
        skip = 1
        next
      }
      $0 == end_marker {
        print end_marker
        skip = 0
        next
      }
      !skip { print }
    ' "$child_gitignore" > "$child_gitignore.tmp"
    mv "$child_gitignore.tmp" "$child_gitignore"
    log ".gitignore: Updated managed block (markers found)"

  elif [ "$has_begin" = false ] && [ "$has_end" = false ]; then
    # No markers — first sync: append the full block
    # Ensure trailing newline before appending
    if [ -s "$child_gitignore" ]; then
      local last_char
      last_char=$(tail -c 1 "$child_gitignore" | xxd -p)
      if [ "$last_char" != "0a" ] && [ -n "$last_char" ]; then
        printf '\n' >> "$child_gitignore"
      fi
      printf '\n' >> "$child_gitignore"
    fi
    printf '%s\n' "$full_block" >> "$child_gitignore"
    log ".gitignore: Appended managed block (first sync)"

  else
    # Partial markers — error, skip merge (fail-safe)
    log "ERROR: .gitignore has partial section markers (BEGIN without END or vice versa)"
    log "  Skipping .gitignore merge to avoid corruption. Fix markers manually."
  fi
}

# --- Run child-sync-decisions.sh cleanup ---
run_decision_cleanup() {
  local cleanup_script="$SCRIPT_DIR/child-sync-decisions.sh"
  if [ -f "$cleanup_script" ]; then
    log "Running decision cleanup (child-sync-decisions.sh --no-commit)..."
    bash "$cleanup_script" --no-commit || {
      log "WARN: Decision cleanup returned non-zero — continuing"
    }
  else
    log "child-sync-decisions.sh not found — skipping decision cleanup"
  fi
}

# --- Commit and push ---
commit_and_push() {
  cd "$REPO_ROOT"

  # Stage all changes
  git add -A

  # Check if there are any changes to commit
  if git diff --cached --quiet; then
    log "No changes detected — working tree matches template. Nothing to commit."
    return 0
  fi

  # Commit
  log "Committing changes..."
  REPO_OS_RECOVER=1 git commit -m "chore(template): sync from upstream

Synced from $TEMPLATE_REPO_NAME ($TEMPLATE_BRANCH).
Direct-push sync via template-sync-engine.sh.

Decisions: 0015, 0022"

  # Push to main (fail on non-fast-forward — NEVER force push)
  log "Pushing to main..."
  git push origin main || {
    echo "ERROR: Push failed. This may indicate:" >&2
    echo "  - Branch protection rules preventing direct push" >&2
    echo "  - Non-fast-forward rejection (child main has diverged)" >&2
    echo "  - Authentication failure" >&2
    echo "" >&2
    echo "The commit has been created locally. Resolve the issue and push manually." >&2
    exit 1
  }

  log "Push successful"
}

# --- Cleanup ---
cleanup_remote() {
  git remote remove "$REMOTE_NAME" 2>/dev/null || true
}

# --- Main ---
main() {
  log "=== Template Sync Engine ==="
  log "Template: $TEMPLATE_REPO"
  log "Branch: $TEMPLATE_BRANCH"
  log "Repo root: $REPO_ROOT"

  # Ensure we're on main
  local current_branch
  current_branch=$(git branch --show-current 2>/dev/null || echo "")
  if [ "$current_branch" != "main" ]; then
    echo "ERROR: Must be on 'main' branch. Currently on: $current_branch" >&2
    exit 1
  fi

  # Set up template remote
  setup_template_remote

  # Trap to clean up remote on exit
  trap cleanup_remote EXIT

  # Sync files (respecting .templatesyncignore)
  sync_files

  # Merge .gitignore section markers
  merge_gitignore

  # Run decision cleanup (must happen BEFORE commit)
  run_decision_cleanup

  # Commit and push
  commit_and_push

  log "=== Sync complete ==="
}

main "$@"
