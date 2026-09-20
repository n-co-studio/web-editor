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
#
# Index format:
#   Line 1:   # A1 trigger index — generated artifact. Do not hand-edit.
#   Line 2:   # Regenerate: bash .claude/.automation/lib/rebuild-trigger-index.sh
#   Line 3:   # digest: <sha256-hex>   (hex of concatenated ## Triggers sections, sorted)
#   Line 4+:  decision_id|path_regex|keywords  (pipe-delimited data rows)
#
# The digest line enables content-based staleness detection in pre-commit-gates.sh —
# the mtime comparison is only a fast pre-filter; a digest mismatch is the real gate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DECISIONS_DIR="$REPO_ROOT/docs/ai/decisions"
INDEX_FILE="$DECISIONS_DIR/.a1-trigger-index"

if [ ! -d "$DECISIONS_DIR" ]; then
  echo "ERROR: decisions directory not found at $DECISIONS_DIR" >&2
  exit 1
fi

# --- Collect trigger data rows into a temp file ---
_TMP_DATA=$(mktemp)
count=0
for f in "$DECISIONS_DIR"/t-*.md "$DECISIONS_DIR"/0*.md; do
  [ -f "$f" ] || continue
  grep -q '^## Triggers' "$f" || continue
  id=$(basename "$f" | sed -E 's/^(t-)?([0-9]+)-.*/\2/')
  block=$(sed -n '/^## Triggers/,/^## /{ /^## Triggers/d; /^## /d; p; }' "$f")
  paths=$(echo "$block" | grep -oE 'paths?:\s*`[^`]*`' | sed -E 's/^paths?:[[:space:]]*`//' | sed 's/`$//' || true)
  keywords=$(echo "$block" | grep -oE 'keywords?:\s*`[^`]*`' | sed -E 's/^keywords?:[[:space:]]*`//' | sed 's/`$//' || true)
  [ -z "$paths" ] && continue
  while IFS= read -r p; do
    p=$(echo "$p" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    [ -z "$p" ] && continue
    echo "${id}|${p}|${keywords}" >> "$_TMP_DATA"
    count=$((count + 1))
  done <<< "$paths"
done

# --- Compute content digest over ## Triggers sections ---
# Sort decision files in locale-independent order so the digest is stable across
# environments and git checkouts (which do not preserve mtime).
# Fall back to an empty digest when no sha256 tool is available (pre-commit-gates.sh
# then falls back to mtime behaviour for compatibility).
_DIGEST=""
_DIGEST_ALGO=""
if command -v sha256sum >/dev/null 2>&1; then
  _DIGEST_ALGO="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  _DIGEST_ALGO="shasum -a 256"
fi

if [ -n "$_DIGEST_ALGO" ]; then
  # `ls` exits non-zero when EITHER glob matches nothing, and a repo with only
  # t-*.md decisions (the template's own state) always trips the 0*.md glob.
  # Under `set -euo pipefail` that aborted this script before it wrote the
  # index — so the regenerate command advertised by pre-commit-gates.sh was a
  # silent no-op and the stored digest could never be refreshed. Must stay
  # byte-identical to the digest computation in pre-commit-gates.sh.
  _DIGEST=$(
    { LC_ALL=C ls "$DECISIONS_DIR"/t-*.md "$DECISIONS_DIR"/0*.md 2>/dev/null || true; } \
      | LC_ALL=C sort \
      | while IFS= read -r f; do
          [ -f "$f" ] || continue
          grep -q '^## Triggers' "$f" || continue
          sed -n '/^## Triggers/,/^## /{ /^## Triggers/d; /^## /d; p; }' "$f"
        done \
      | $_DIGEST_ALGO \
      | awk '{print $1}'
  )
fi

# --- Write index: header comment block, then data rows ---
{
  echo "# A1 trigger index — generated artifact. Do not hand-edit."
  echo "# Regenerate: bash .claude/.automation/lib/rebuild-trigger-index.sh"
  if [ -n "$_DIGEST" ]; then
    echo "# digest: ${_DIGEST}"
  fi
  cat "$_TMP_DATA"
} > "$INDEX_FILE"

rm -f "$_TMP_DATA"

echo "Rebuilt A1 trigger index: $count entries from $(LC_ALL=C ls "$DECISIONS_DIR"/t-*.md "$DECISIONS_DIR"/0*.md 2>/dev/null | wc -l | tr -d ' ') decision files"
