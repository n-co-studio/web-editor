#!/usr/bin/env bash
# rebuild-trigger-index.sh — Regenerate the A1 trigger index from decision files.
#
# Reads all t-*.md and 0*.md decision files in docs/ai/decisions/, extracts
# ## Triggers sections, and writes the compiled index to .a1-trigger-index.
#
# Usage:
#   bash .claude/.automation/lib/rebuild-trigger-index.sh
#
# The index is used by pre-commit-gates.sh for fast trigger matching.
# See docs/ai/quality-gates.md § A1 Trigger Index for format details.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DECISIONS_DIR="$REPO_ROOT/docs/ai/decisions"
INDEX_FILE="$DECISIONS_DIR/.a1-trigger-index"

if [ ! -d "$DECISIONS_DIR" ]; then
  echo "ERROR: decisions directory not found at $DECISIONS_DIR" >&2
  exit 1
fi

count=0
for f in "$DECISIONS_DIR"/t-*.md "$DECISIONS_DIR"/0*.md; do
  [ -f "$f" ] || continue
  grep -q '^## Triggers' "$f" || continue
  id=$(basename "$f" | sed -E 's/^(t-)?([0-9]+)-.*/\2/')
  block=$(sed -n '/^## Triggers/,/^## /{ /^## Triggers/d; /^## /d; p; }' "$f")
  paths=$(echo "$block" | grep -oE 'paths?:\s*`[^`]*`' | sed -E 's/^paths?:[[:space:]]*`//' | sed 's/`$//')
  keywords=$(echo "$block" | grep -oE 'keywords?:\s*`[^`]*`' | sed -E 's/^keywords?:[[:space:]]*`//' | sed 's/`$//')
  [ -z "$paths" ] && continue
  while IFS= read -r p; do
    p=$(echo "$p" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    [ -z "$p" ] && continue
    echo "${id}|${p}|${keywords}"
    count=$((count + 1))
  done <<< "$paths"
done > "$INDEX_FILE"

echo "Rebuilt A1 trigger index: $count entries from $(ls "$DECISIONS_DIR"/t-*.md "$DECISIONS_DIR"/0*.md 2>/dev/null | wc -l | tr -d ' ') decision files"
