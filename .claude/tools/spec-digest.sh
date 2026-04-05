#!/usr/bin/env bash
# spec-digest.sh — Deterministic spec digest generator.
# Reads compiled spec files and produces DIGEST.md with frontmatter summaries
# and first-paragraph extractions. Also updates manifest.json with the
# features array and spec_digest_sha provenance stamp.
#
# Usage:
#   .claude/tools/spec-digest.sh
#
# Outputs:
#   docs/spec/compiled/{active}/DIGEST.md
#   docs/spec/compiled/manifest.json (features[] + spec_digest_sha updated)
#
# Decision 0035 — Selective Spec Loading
#
# Deterministic extraction only — no LLM calls.
# Idempotent — same input always produces same output.
# Retroactive fallback — files without YAML frontmatter fall back to
# extracting `# Title` headers and first paragraphs (less structured).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="$REPO_ROOT/docs/spec/compiled/manifest.json"

# --- Read active version from manifest.json ---
if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: manifest.json not found at $MANIFEST" >&2
  exit 1
fi

# Extract active version (portable awk — no jq dependency)
ACTIVE_VERSION=$(awk -F'"' '/"active"/ { print $4 }' "$MANIFEST")
if [ -z "$ACTIVE_VERSION" ] || [ "$ACTIVE_VERSION" = "null" ]; then
  echo "ERROR: manifest.json has no active version. Run Prompt 0 first." >&2
  exit 1
fi

COMPILED_DIR="$REPO_ROOT/docs/spec/compiled/$ACTIVE_VERSION"
if [ ! -d "$COMPILED_DIR" ]; then
  echo "ERROR: compiled spec directory not found: $COMPILED_DIR" >&2
  exit 1
fi

DIGEST_FILE="$COMPILED_DIR/DIGEST.md"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- Helper: extract YAML frontmatter value ---
# Returns the value of a YAML key from frontmatter (lines between first --- markers).
# Usage: _fm_value <key> <file>
_fm_value() {
  local key="$1"
  local file="$2"
  awk -v key="$key" '
    /^---$/ { if (in_fm) { exit } else { in_fm=1; next } }
    in_fm && /^[a-z_]+:/ {
      split($0, parts, ": ")
      if (parts[1] == key) {
        val = substr($0, length(key) + 3)
        # Strip surrounding quotes
        gsub(/^"/, "", val); gsub(/"$/, "", val)
        print val
        exit
      }
    }
  ' "$file" 2>/dev/null || echo ""
}

# --- Helper: extract array values from YAML frontmatter ---
# Returns one value per line from a YAML list field in frontmatter.
# Usage: _fm_array <key> <file>
_fm_array() {
  local key="$1"
  local file="$2"
  awk -v key="$key" '
    /^---$/ { if (in_fm) { exit } else { in_fm=1; next } }
    in_fm && /^[a-z_]+:/ {
      if ($0 ~ "^" key ":") { in_key=1; next } else { in_key=0 }
    }
    in_fm && in_key && /^  - / {
      val = substr($0, 5)
      gsub(/^"/, "", val); gsub(/"$/, "", val)
      print val
    }
  ' "$file" 2>/dev/null || echo ""
}

# --- Helper: extract title from file ---
# Priority: YAML frontmatter title → first # heading → filename
_extract_title() {
  local file="$1"
  local fm_title
  fm_title=$(_fm_value "title" "$file")
  if [ -n "$fm_title" ] && [ "$fm_title" != "[]" ]; then
    echo "$fm_title"
    return
  fi
  # Fall back to first # heading
  awk '/^# / { sub(/^# /, ""); print; exit }' "$file" 2>/dev/null || basename "$file" .md
}

# --- Helper: extract first paragraph after first ## heading ---
# Returns the first non-empty paragraph following the first ## heading.
# Falls back to first non-empty paragraph in the file.
_extract_summary() {
  local file="$1"
  awk '
    /^---$/ { if (in_fm) { in_fm=0 } else if (!past_fm) { in_fm=1 }; next }
    in_fm { next }
    { past_fm=1 }
    /^## / { in_section=1; found_heading=1; blank=0; next }
    in_section && /^[[:space:]]*$/ {
      if (para) { exit }
      blank=1; next
    }
    in_section && !/^#/ {
      if (blank && para) exit
      para = para (para ? " " : "") $0
      blank=0
    }
    END { print para }
  ' "$file" 2>/dev/null | head -c 500 | tr '\n' ' ' | sed 's/  */ /g'
}

# --- Build DIGEST.md ---
{
  echo "# Spec Digest"
  echo ""
  echo "Derived artifact — deterministic extraction from \`docs/spec/compiled/$ACTIVE_VERSION/\`."
  echo "Compiled specs are authoritative. When digest and spec conflict, spec wins."
  echo ""
  echo "spec_version: $ACTIVE_VERSION"
  echo "generated: $TIMESTAMP"
  echo ""
  echo "---"
  echo ""

  # --- Core spec files ---
  echo "## Core Specs"
  echo ""
  for spec_file in product.md architecture.md design-system.md data-contracts.md integrations.md boundaries.md; do
    fp="$COMPILED_DIR/$spec_file"
    [ -f "$fp" ] || continue
    title=$(_extract_title "$fp")
    summary=$(_extract_summary "$fp")
    modules=$(_fm_array "scope_modules" "$fp" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
    keywords=$(_fm_array "keywords" "$fp" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')

    echo "### $title"
    echo "**File:** \`$spec_file\`"
    [ -n "$modules" ] && echo "**Modules:** $modules"
    [ -n "$keywords" ] && echo "**Keywords:** $keywords"
    if [ -n "$summary" ]; then
      echo ""
      echo "$summary"
    fi
    echo ""
  done

  # --- Feature files ---
  FEATURES_DIR="$COMPILED_DIR/features"
  if [ -d "$FEATURES_DIR" ] && [ -n "$(ls -A "$FEATURES_DIR" 2>/dev/null)" ]; then
    echo "## Feature Briefs"
    echo ""
    for feat_file in "$FEATURES_DIR"/*.md; do
      [ -f "$feat_file" ] || continue
      fname=$(basename "$feat_file")
      title=$(_extract_title "$feat_file")
      summary=$(_extract_summary "$feat_file")
      modules=$(_fm_array "scope_modules" "$feat_file" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
      keywords=$(_fm_array "keywords" "$feat_file" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')

      # Extract id from filename (e.g. brief-floating-session-system.md → floating-session-system)
      feat_id=$(echo "$fname" | sed 's/^brief-//' | sed 's/\.md$//')

      echo "### $title"
      echo "**File:** \`features/$fname\`  **ID:** \`$feat_id\`"
      [ -n "$modules" ] && echo "**Modules:** $modules"
      [ -n "$keywords" ] && echo "**Keywords:** $keywords"
      if [ -n "$summary" ]; then
        echo ""
        echo "$summary"
      fi
      echo ""
    done
  fi

} > "$DIGEST_FILE"

echo "DIGEST.md written to $DIGEST_FILE"

# --- Compute SHA of DIGEST.md for provenance ---
DIGEST_SHA=""
if command -v shasum &>/dev/null; then
  DIGEST_SHA=$(shasum -a 256 "$DIGEST_FILE" | awk '{print $1}')
elif command -v sha256sum &>/dev/null; then
  DIGEST_SHA=$(sha256sum "$DIGEST_FILE" | awk '{print $1}')
elif command -v openssl &>/dev/null; then
  DIGEST_SHA=$(openssl sha256 "$DIGEST_FILE" | awk '{print $NF}')
else
  echo "WARNING: no SHA command available (shasum/sha256sum/openssl) — spec_digest_sha will be empty. Staleness detection via SHA is disabled." >&2
fi

# --- Build features array from feature files ---
FEATURES_JSON=""
FEATURES_DIR="$COMPILED_DIR/features"
if [ -d "$FEATURES_DIR" ]; then
  for feat_file in "$FEATURES_DIR"/*.md; do
    [ -f "$feat_file" ] || continue
    fname=$(basename "$feat_file")
    feat_id=$(echo "$fname" | sed 's/^brief-//' | sed 's/\.md$//')
    title=$(_extract_title "$feat_file")
    # Extract status from frontmatter (optional field)
    status=$(_fm_value "status" "$feat_file")
    [ -z "$status" ] && status="active"
    # Build scope_modules array as JSON
    modules_json=$(_fm_array "scope_modules" "$feat_file" | awk '{ printf "\"%s\",", $0 }' | sed 's/,$//')
    keywords_json=$(_fm_array "keywords" "$feat_file" | awk '{ printf "\"%s\",", $0 }' | sed 's/,$//')
    entry="{\"id\":\"$feat_id\",\"title\":\"$title\",\"status\":\"$status\",\"scope_modules\":[$modules_json],\"keywords\":[$keywords_json]}"
    FEATURES_JSON="${FEATURES_JSON:+$FEATURES_JSON,}$entry"
  done
fi

# --- Update manifest.json with features array and spec_digest_sha ---
# Portable approach: rebuild JSON using awk (no jq dependency).
# Reads existing manifest, replaces/adds features and spec_digest_sha fields.
MANIFEST_TMP="${MANIFEST}.tmp.$$"

awk -v features="[$FEATURES_JSON]" -v digest_sha="$DIGEST_SHA" '
  BEGIN { added_features=0; added_sha=0 }
  # Replace existing features or spec_digest_sha fields
  /^  "features":/ {
    print "  \"features\": " features ","
    added_features=1
    # Skip the existing array (may span multiple lines — skip until matching ])
    if ($0 !~ /\[.*\]/) {
      depth=1
      while ((getline line) > 0) {
        for (i=1; i<=length(line); i++) {
          c = substr(line,i,1)
          if (c == "[") depth++
          if (c == "]") { depth--; if (depth==0) break }
        }
        if (depth == 0) break
      }
    }
    next
  }
  /^  "spec_digest_sha":/ {
    print "  \"spec_digest_sha\": \"" digest_sha "\","
    added_sha=1
    next
  }
  # Inject before closing brace if not yet added
  /^}$/ {
    if (!added_features) print "  \"features\": " features ","
    if (!added_sha && digest_sha != "") print "  \"spec_digest_sha\": \"" digest_sha "\","
    print $0
    next
  }
  { print }
' "$MANIFEST" > "$MANIFEST_TMP" && mv "$MANIFEST_TMP" "$MANIFEST"

echo "manifest.json updated with features array and spec_digest_sha"
echo "spec_digest_sha: $DIGEST_SHA"
