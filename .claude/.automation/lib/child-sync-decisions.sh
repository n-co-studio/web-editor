#!/usr/bin/env bash
# Child-sync decision cleanup — removes orphaned template decisions.
# Called by the template-sync workflow's cleanup step in child repos.
#
# Logic: reads t-manifest.txt (delivered by template-sync), lists local
# t-*.md files, computes orphans (local files not in manifest), and
# deletes them via git rm.
#
# Usage:
#   bash child-sync-decisions.sh [--dry-run]
#
# Decision 0022 — Template Decision Naming Convention

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DECISIONS_DIR="$REPO_ROOT/docs/ai/decisions"
MANIFEST="$DECISIONS_DIR/t-manifest.txt"

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=true
fi

# --- Validate manifest exists ---
if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: t-manifest.txt not found at $MANIFEST" >&2
  echo "  Template sync may not have delivered it yet." >&2
  exit 1
fi

# --- Read manifest entries (skip comments and blank lines) ---
MANIFEST_FILES=()
while IFS= read -r line; do
  # Skip comments and blank lines
  case "$line" in
    '#'*|'') continue ;;
  esac
  # Trim whitespace
  line=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
  [ -z "$line" ] && continue
  MANIFEST_FILES+=("$line")
done < "$MANIFEST"

if [ ${#MANIFEST_FILES[@]} -eq 0 ]; then
  echo "WARNING: t-manifest.txt is empty (no entries after filtering comments)" >&2
  exit 0
fi

# --- List local t-*.md files ---
LOCAL_FILES=()
for f in "$DECISIONS_DIR"/t-*.md; do
  [ -f "$f" ] || continue
  LOCAL_FILES+=("$(basename "$f")")
done

if [ ${#LOCAL_FILES[@]} -eq 0 ]; then
  echo "No local t-*.md files found — nothing to clean up."
  exit 0
fi

# --- Compute orphans (local files not in manifest) ---
ORPHANS=()
for local_file in "${LOCAL_FILES[@]}"; do
  found=false
  for manifest_file in "${MANIFEST_FILES[@]}"; do
    if [ "$local_file" = "$manifest_file" ]; then
      found=true
      break
    fi
  done
  if [ "$found" = false ]; then
    ORPHANS+=("$local_file")
  fi
done

if [ ${#ORPHANS[@]} -eq 0 ]; then
  echo "No orphaned template decisions found — all local t-*.md files match manifest."
  exit 0
fi

# --- Report orphans ---
echo "Found ${#ORPHANS[@]} orphaned template decision(s):"
for orphan in "${ORPHANS[@]}"; do
  echo "  - $orphan"
done

# --- Delete orphans ---
if [ "$DRY_RUN" = true ]; then
  echo ""
  echo "DRY RUN — no files deleted. Run without --dry-run to remove orphans."
  exit 0
fi

cd "$REPO_ROOT"
for orphan in "${ORPHANS[@]}"; do
  git rm "docs/ai/decisions/$orphan"
done

# --- Commit if changes were made ---
STAGED=$(git diff --cached --name-only 2>/dev/null || true)
if [ -n "$STAGED" ]; then
  REPO_OS_RECOVER=1 git commit -m "chore: remove ${#ORPHANS[@]} orphaned template decision(s)

Removed by child-sync-decisions.sh based on t-manifest.txt.
Files not present in the upstream template manifest are considered orphaned.

Decisions: 0022"
  echo "Committed removal of ${#ORPHANS[@]} orphaned template decision(s)."
else
  echo "No staged changes — nothing to commit."
fi
