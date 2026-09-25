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
# Patterns are loaded ONCE. Re-reading them per file through a process
# substitution inside the sync loop crashes bash 3.2 with SIGBUS (exit 138)
# when that loop sits inside a command substitution — macOS ships 3.2.57.
_SYNCIGNORE_PATTERNS=()
_load_syncignore_patterns() {
  _SYNCIGNORE_PATTERNS=()
  local src="" tmp _p

  # Prefer the TEMPLATE's .templatesyncignore over the child's copy.
  #
  # What the template ships is the template's policy, and reading the child's
  # copy made the first sync into a special case: a child that does not yet
  # have the file excludes NOTHING, so that sync overwrites its .gitignore,
  # its session logs and its compiled specs wholesale. It also let the child's
  # copy drift out of step with the machinery manifest, which is generated
  # against the template's list — the two must agree or the sweep reasons
  # about a different file set than the sync delivered.
  tmp=$(mktemp "${TMPDIR:-/tmp}/reposync-syncignore.XXXXXX")
  if git show "$REMOTE_NAME/$TEMPLATE_BRANCH:.templatesyncignore" > "$tmp" 2>/dev/null \
     && [ -s "$tmp" ]; then
    src="$tmp"
    log "Using the template's .templatesyncignore"
  elif [ -f "$SYNCIGNORE" ]; then
    src="$SYNCIGNORE"
    log "Template has no .templatesyncignore — falling back to the child's copy"
  else
    rm -f "$tmp"
    log "No .templatesyncignore found — every template file will be synced"
    return 0
  fi

  while IFS= read -r _p; do
    _p="$(printf '%s' "$_p" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$_p" in '#'*|'') continue ;; esac
    _SYNCIGNORE_PATTERNS[${#_SYNCIGNORE_PATTERNS[@]}]="$_p"
  done < "$src"
  rm -f "$tmp"
  log "Loaded ${#_SYNCIGNORE_PATTERNS[@]} exclusion pattern(s)"
}

is_excluded() {
  local file_path="$1"

  for pattern in ${_SYNCIGNORE_PATTERNS[@]+"${_SYNCIGNORE_PATTERNS[@]}"}; do
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
  done

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
    # Both markers present — replace the block between them (atomic).
    #
    # Assembled with cat from three pieces rather than passing the block
    # through `awk -v`. A -v assignment containing newlines is a GNU awk
    # extension; BSD awk (macOS) rejects it with "newline in string" and
    # produces an EMPTY file, which under the old code was then mv'd over the
    # child's .gitignore. On CI (gawk) it worked, so the failure only appears
    # when the engine is run on an operator machine — where it destroys the
    # file it was meant to edit.
    local _gi_tmp
    _gi_tmp=$(mktemp "${TMPDIR:-/tmp}/reposync-gi.XXXXXX")
    {
      # everything before BEGIN
      awk -v b="$BEGIN_MARKER" '$0 == b { exit } { print }' "$child_gitignore"
      printf '%s\n%s\n' "$BEGIN_MARKER" "$MANAGED_COMMENT"
      printf '%s\n' "$managed_block"
      printf '%s\n' "$END_MARKER"
      # everything after END
      awk -v e="$END_MARKER" 'f { print } $0 == e { f = 1 }' "$child_gitignore"
    } > "$_gi_tmp"
    if [ ! -s "$_gi_tmp" ]; then
      rm -f "$_gi_tmp"
      log "ERROR: .gitignore rebuild produced an empty file — leaving the child's copy untouched"
      return
    fi
    mv "$_gi_tmp" "$child_gitignore"
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

# --- Withdrawn-file sweep (machinery manifest) ---
#
# sync_files() is add/update-only, so a file the template DELETES lingers in
# every child indefinitely. branch-guard.sh survived in markpreston for seven
# months after deletion; innovator.md and researcher.md stayed dispatchable as
# agent types long after the template dropped them.
#
# The sweep deletes a child file only when it appears in the child's PREVIOUS
# manifest and not in the incoming one — i.e. the template shipped it and has
# now withdrawn it. A file the child authored has never appeared in any
# manifest, so it is never a candidate; that is what makes this safe to run
# unattended, and it is why the check is a manifest diff rather than "absent
# from the template tree". See rebuild-machinery-manifest.sh.
MANIFEST_REL=".claude/.automation/machinery-manifest.txt"
PREV_MANIFEST=""

# Strip comments/blanks from a manifest into a sorted list.
#
# Uses awk, NOT `grep -v | grep -v`. Under `set -euo pipefail` a grep that
# matches nothing exits 1 and takes the whole script down — which is precisely
# how the A1 digest pipeline turned every commit gate advisory (Decision
# t-0049). A header-only manifest is a legitimate input here (it is exactly the
# corruption case the sweep must survive), so the read must not be a grep
# pipeline. awk exits 0 on empty output.
_manifest_entries() {
  awk '!/^[[:space:]]*#/ && !/^[[:space:]]*$/ { print }' "$1" | LC_ALL=C sort
}

capture_previous_manifest() {
  # MUST run before sync_files overwrites the child's copy.
  if [ -f "$REPO_ROOT/$MANIFEST_REL" ]; then
    PREV_MANIFEST=$(mktemp "${TMPDIR:-/tmp}/reposync-prevmanifest.XXXXXX")
    _manifest_entries "$REPO_ROOT/$MANIFEST_REL" > "$PREV_MANIFEST"
    log "Previous machinery manifest: $(wc -l < "$PREV_MANIFEST" | tr -d ' ') entries"
  else
    log "No previous machinery manifest — skipping withdrawn-file sweep (first sync after t-0051)"
  fi
}

sweep_withdrawn_files() {
  [ -n "$PREV_MANIFEST" ] || return 0
  [ -f "$REPO_ROOT/$MANIFEST_REL" ] || { log "WARN: incoming manifest missing — skipping sweep"; return 0; }

  local new_manifest removed count=0
  new_manifest=$(mktemp "${TMPDIR:-/tmp}/reposync-newmanifest.XXXXXX")
  _manifest_entries "$REPO_ROOT/$MANIFEST_REL" > "$new_manifest"

  # Guard against a truncated or malformed incoming manifest deleting the world.
  if [ ! -s "$new_manifest" ]; then
    log "ERROR: incoming machinery manifest is empty — refusing to sweep"
    rm -f "$new_manifest"; return 0
  fi

  while IFS= read -r removed; do
    [ -z "$removed" ] && continue
    [ -e "$REPO_ROOT/$removed" ] || continue
    if git -C "$REPO_ROOT" rm -q --ignore-unmatch "$removed" 2>/dev/null; then
      log "  withdrawn: $removed"
    else
      rm -f "$REPO_ROOT/$removed"
      log "  withdrawn (untracked): $removed"
    fi
    count=$((count + 1))
  done < <(comm -23 "$PREV_MANIFEST" "$new_manifest")

  rm -f "$new_manifest" "$PREV_MANIFEST"
  if [ "$count" -eq 0 ]; then
    log "Withdrawn-file sweep: nothing to remove"
  else
    log "Withdrawn-file sweep: removed $count file(s) the template no longer ships"
  fi
}

# --- Rebuild the A1 trigger index in the child ---
#
# The index is per-repo: it is compiled from the decision files present in THIS
# repo, template and child alike. It is excluded from sync (see
# .templatesyncignore) because delivering the template's copy silently disabled
# A1 for every child-authored decision — the gate reads the index exclusively
# and only parses decision files when the index is absent.
#
# Must run AFTER decisions are synced and orphans cleaned, so the rebuild sees
# the final set.
rebuild_a1_index() {
  # Resolved from REPO_ROOT, not SCRIPT_DIR. SCRIPT_DIR is wherever the engine
  # file happens to live; when the engine is invoked by absolute path from
  # another checkout, SCRIPT_DIR's helper rebuilds THAT repo's index instead of
  # this child's. REPO_ROOT is always the repo being synced.
  local rebuild="$REPO_ROOT/.claude/.automation/lib/rebuild-trigger-index.sh"
  if [ ! -f "$rebuild" ]; then
    log "rebuild-trigger-index.sh not found — skipping A1 index rebuild"
    return 0
  fi
  if [ ! -d "$REPO_ROOT/docs/ai/decisions" ]; then
    log "No docs/ai/decisions — skipping A1 index rebuild"
    return 0
  fi
  log "Rebuilding A1 trigger index for this repo..."
  bash "$rebuild" || log "WARN: A1 index rebuild returned non-zero — continuing"
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

  # Ensure we're on main.
  # rev-parse --abbrev-ref, not `branch --show-current`: the latter needs git
  # 2.22+ and this script is documented as runnable standalone on an operator
  # machine (macOS ships git 2.19.2, where --show-current is not a flag but is
  # echoed back as a branch name pattern, so the check silently compares
  # garbage). --abbrev-ref works from git 1.7 and returns HEAD when detached.
  local current_branch
  current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [ "$current_branch" != "main" ]; then
    echo "ERROR: Must be on 'main' branch. Currently on: $current_branch" >&2
    exit 1
  fi

  # Set up template remote
  setup_template_remote

  # Trap to clean up remote on exit
  trap cleanup_remote EXIT

  # Load .templatesyncignore patterns once (bash 3.2 safety — see is_excluded)
  _load_syncignore_patterns

  # Snapshot the child's current machinery manifest BEFORE sync overwrites it —
  # the withdrawn-file sweep below diffs the old copy against the incoming one.
  capture_previous_manifest

  # Sync files (respecting .templatesyncignore)
  sync_files

  # Remove files the template shipped previously and has now withdrawn
  sweep_withdrawn_files

  # Merge .gitignore section markers
  merge_gitignore

  # Run decision cleanup (must happen BEFORE commit)
  run_decision_cleanup

  # Rebuild the A1 trigger index AFTER decisions are final (synced + swept)
  rebuild_a1_index

  # Commit and push
  commit_and_push

  log "=== Sync complete ==="
}

main "$@"
