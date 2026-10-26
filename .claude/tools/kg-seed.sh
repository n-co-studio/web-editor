#!/usr/bin/env bash
# Knowledge Graph Bootstrap Seeder — product graph
# Decision 0034 — Knowledge Graph Data Layer (Amendments 2 and 9)
#
# Creates docs/ai/knowledge-graph/product-graph.yaml from a child repo's source
# files: one node per file, no edges. The template knowledge graph (graph.yaml)
# and the governance seeding that built it were retired in Amendment 9.
#
# A SEED, not an updater: it refuses to run when product-graph.yaml already
# exists. It used to overwrite the file with only the nodes it had just
# generated, which on an existing graph would have destroyed every node and
# edge in it. Add nodes to an existing graph with kg-cover.sh.
#
# Every node is written with the description "Product source file". That is the
# seeder default the commit gate rejects (pre-commit-gates.sh, Amendment 9 rule
# 2): a seeded node is scaffolding until someone says what the file does.
#
# Node ids derive from the FULL relative path (see _kg_product_id), so two files
# with the same name in different packages cannot collide — the earlier
# product-<parent>-<file> scheme turned packages/a/src/tokens/store.ts and
# packages/b/src/tokens/store.ts into the same id.
#
# Usage:
#   bash .claude/tools/kg-seed.sh [--target product] [--file-pattern PATTERN] [--dry-run]
#
#   --file-pattern  <base-dir>/**/*.<ext>, e.g. src/**/*.tsx (default src/**/*.ts).
#                   Repeatable — seed every extension coverage.yaml declares in
#                   one run, since the seeder will not run on an existing graph.
#   --target        product only; `template` is retired and exits 1.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TODAY=$(date -u +%Y-%m-%d)
DRY_RUN=false
TARGET="product"
FILE_PATTERNS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --target) shift; TARGET="${1:-product}" ;;
    --file-pattern) shift; FILE_PATTERNS="${FILE_PATTERNS}${1:-src/**/*.ts}
" ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: kg-seed.sh [--target product] [--file-pattern PATTERN] [--dry-run]" >&2
      exit 1
      ;;
  esac
  shift
done

case "$TARGET" in
  product) ;;
  template)
    echo "ERROR: the template knowledge graph was retired (Decision t-0034 Amendment 9); kg-seed.sh seeds product-graph.yaml only." >&2
    exit 1
    ;;
  *)
    echo "ERROR: --target must be 'product', got '$TARGET'" >&2
    exit 1
    ;;
esac

GRAPH_FILE="$REPO_ROOT/docs/ai/knowledge-graph/product-graph.yaml"
LOCK_DIR="$REPO_ROOT/docs/ai/knowledge-graph/.product-graph-lock"

if [ -f "$GRAPH_FILE" ]; then
  echo "ERROR: $GRAPH_FILE already exists — kg-seed.sh only creates a graph." >&2
  echo "  Add nodes for specific files with: bash .claude/tools/kg-cover.sh --target product <file>..." >&2
  exit 1
fi

# Node id from a repo-relative path. The SAME function is in kg-cover.sh; a test
# (.claude/hooks/tests/test-kg-tools.sh) pins that both produce the same id, so
# the two copies cannot drift apart unnoticed.
#   src/app/Settings.tsx → product-src-app-settings-tsx
_kg_product_id() {
  printf 'product-%s\n' "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//')"
}

acquire_lock() {
  local attempts=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 30 ]; then
      echo "ERROR: Failed to acquire knowledge graph lock after 30 attempts" >&2
      exit 1
    fi
    sleep 1
  done
}
release_lock() { rmdir "$LOCK_DIR" 2>/dev/null || true; }
trap release_lock EXIT

[ -n "$FILE_PATTERNS" ] || FILE_PATTERNS="src/**/*.ts
"

echo "Target: product → $GRAPH_FILE"

NODE_LINES=""
SEEN_IDS=","
NODE_COUNT=0

# Lists the files one pattern matches, sorted. Each pattern is
# <base-dir>/**/*.<ext>; a pattern with no base dir defaults to src, one with no
# extension to ts.
_kg_seed_files() {
  local pattern="$1" base ext root
  base="${pattern%%/**/*}"
  [ "$base" = "$pattern" ] && base="src"
  ext="${pattern##*.}"
  { [ "$ext" = "$pattern" ] || [ -z "$ext" ]; } && ext="ts"
  root="$REPO_ROOT/$base"
  if [ ! -d "$root" ]; then
    echo "  Source directory not found: $root — nothing seeded for $pattern" >&2
    echo "  Tip: set --file-pattern to match your project layout (e.g. app/**/*.ts)" >&2
    return 0
  fi
  echo "  Scanning: $root for *.${ext} files" >&2
  find "$root" \
    -not \( -path "*/node_modules/*" \) -not \( -path "*/dist/*" \) \
    -not \( -path "*/build/*" \) -not \( -path "*/.git/*" \) \
    -not \( -path "*/coverage/*" \) -not \( -path "*/.next/*" \) \
    -type f -name "*.${ext}" 2>/dev/null | sort
}

while IFS= read -r _pattern; do
  [ -n "$_pattern" ] || continue
  while IFS= read -r fpath; do
    [ -n "$fpath" ] || continue
    rel_path="${fpath#$REPO_ROOT/}"
    node_id=$(_kg_product_id "$rel_path")
    case "$SEEN_IDS" in *",$node_id,"*) continue ;; esac
    SEEN_IDS="${SEEN_IDS}${node_id},"
    NODE_COUNT=$((NODE_COUNT + 1))
    NODE_LINES="${NODE_LINES}  - id: \"${node_id}\"
    type: \"file\"
    path: \"${rel_path}\"
    description: \"Product source file\"
    last_verified: \"${TODAY}\"
    status: \"unverified\"
    layer: \"product\"
"
  done < <(_kg_seed_files "$_pattern")
done <<EOF
$FILE_PATTERNS
EOF

if [ "$NODE_COUNT" -eq 0 ]; then
  echo "  No files matched — nothing to seed"
  exit 0
fi
echo "  Found $NODE_COUNT file(s)"

if [ "$DRY_RUN" = true ]; then
  echo "[dry-run] Would write $NODE_COUNT node(s) to $GRAPH_FILE"
  exit 0
fi

acquire_lock
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > "$GRAPH_FILE" << GRAPH_EOF
# Knowledge Graph — Product Layer
# Decision 0034 — Knowledge Graph Data Layer (Amendments 2, 9)
# Seeded by kg-seed.sh on ${TIMESTAMP}. Every node says "Product source file"
# until someone describes it; the commit gate rejects that default.

schema_version: 1
last_updated: "${TIMESTAMP}"

nodes:
${NODE_LINES}
edges:
GRAPH_EOF
release_lock
echo "Graph written to $GRAPH_FILE"

KG_VALIDATE="$(dirname "$0")/kg-validate.sh"
if [ -f "$KG_VALIDATE" ]; then
  echo ""
  echo "Running schema validation..."
  if ! bash "$KG_VALIDATE" --strict --target product; then
    echo "ERROR: Schema validation failed for $GRAPH_FILE — graph may contain invalid data" >&2
    exit 1
  fi
fi
echo "Done."
