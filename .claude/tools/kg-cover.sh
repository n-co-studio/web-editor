#!/usr/bin/env bash
# Knowledge Graph Coverage Filler — product graph
# Decision 0034 — Knowledge Graph Data Layer (Amendments 7, 9)
#
# Scaffolds stub nodes in docs/ai/knowledge-graph/product-graph.yaml for the
# given files: the first step of the remediation the KG product-graph gate in
# pre-commit-gates.sh asks for when a staged product file has no node. The
# template graph it also used to write was retired in Amendment 9.
#
# A stub is NOT a fix by itself: it carries the description "Product source
# file", which the gate rejects (Amendment 9 rule 2) until someone writes what
# the file does. It also writes no kg-updated marker, so the graph must be
# staged with the commit: git add docs/ai/knowledge-graph/product-graph.yaml.
#
# Node ids come from _kg_product_id, the same function kg-seed.sh uses; a test
# pins that the two agree.
#
# Usage:
#   kg-cover.sh [--target product] [--dry-run] <file> [<file>...]
#
#   --target product   The only graph (default). `template` is retired: exit 1.
#   --dry-run          Print what would be written; write nothing.
#
# Exit codes:
#   0   All nodes written (or already present); kg-validate.sh --strict passes.
#   1   Retired target, graph not writable in the current mode, graph missing,
#       or schema validation failed.
#
# Mode writability: product-graph.yaml is writable in template and child mode.
#
# Constraint: shell I/O only — no Edit/Write tool writes to graph files
# (Decision 0034 §2). awk is used for in-place node insertion.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TODAY=$(date -u +%Y-%m-%d)
DRY_RUN=false
TARGET="product"

# --- Parse arguments ---
FILE_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      ;;
    --target)
      shift
      TARGET="${1:-product}"
      ;;
    -*)
      echo "Unknown option: $1" >&2
      echo "Usage: kg-cover.sh [--target product] [--dry-run] <file>..." >&2
      exit 1
      ;;
    *)
      FILE_ARGS+=("$1")
      ;;
  esac
  shift
done

if [ "${#FILE_ARGS[@]}" -eq 0 ]; then
  echo "Usage: kg-cover.sh [--target product] [--dry-run] <file>..." >&2
  exit 1
fi

# Validate target
case "$TARGET" in
  product) ;;
  template)
    echo "ERROR: the template knowledge graph was retired (Decision t-0034 Amendment 9); kg-cover.sh writes product-graph.yaml only." >&2
    exit 1
    ;;
  *)
    echo "ERROR: --target must be 'product', got '$TARGET'" >&2
    exit 1
    ;;
esac

GRAPH_FILE="$REPO_ROOT/docs/ai/knowledge-graph/product-graph.yaml"
LOCK_DIR="$REPO_ROOT/docs/ai/knowledge-graph/.product-graph-lock"

# --- Mode writability check ---
_current_mode="${REPO_OS_MODE:-}"
if [ -z "$_current_mode" ] && [ -f "$REPO_ROOT/.claude/repo-mode" ]; then
  _current_mode=$(cat "$REPO_ROOT/.claude/repo-mode" 2>/dev/null | tr -d '[:space:]')
fi
_current_mode="${_current_mode:-child}"

case "$_current_mode" in
  template|child) ;;
  *)
    echo "ERROR: kg-cover.sh — product-graph.yaml is not writable in mode '$_current_mode' (template or child mode only)." >&2
    exit 1
    ;;
esac

# --- Graph existence check ---
if [ ! -f "$GRAPH_FILE" ]; then
  echo "ERROR: Graph file not found: $GRAPH_FILE" >&2
  echo "  Run kg-seed.sh --target product to initialise the graph first." >&2
  exit 1
fi

# ============================================================
# Lock helpers — verbatim from kg-seed.sh (Decision 0034 §8)
# ============================================================
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
release_lock() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
# Also sweep scratch files: an aborted run (set -e) would otherwise leave
# product-graph.yaml.cover-tmp.$$ / .cover-nodes.$$ beside the graph, where they get
# picked up by `git add -A` and committed.
_cover_cleanup() {
  release_lock
  rm -f "${GRAPH_FILE}.cover-tmp.$$" "${GRAPH_FILE}.cover-nodes.$$" 2>/dev/null || true
}
trap _cover_cleanup EXIT

# ============================================================
# Node accumulator — verbatim pattern from kg-seed.sh add_node()
# ============================================================
NODE_LINES=""
SEEN_NODES=""
NODE_COUNT=0

add_node() {
  local id="$1" type="$2" path="$3" desc="$4"
  # Deduplicate
  case ",$SEEN_NODES," in
    *",$id,"*) return ;;
  esac
  SEEN_NODES="${SEEN_NODES:+$SEEN_NODES,}$id"
  NODE_COUNT=$((NODE_COUNT + 1))
  NODE_LINES="${NODE_LINES}  - id: \"${id}\"
    type: \"${type}\"
    path: \"${path}\"
    description: \"${desc}\"
    last_verified: \"${TODAY}\"
    status: \"unverified\"
    layer: \"${TARGET}\"
"
}

# ============================================================
# Node id from file path
# ============================================================
# The SAME function is in kg-seed.sh; .claude/hooks/tests/test-kg-tools.sh pins
# that both produce the same id, so the two copies cannot drift apart unnoticed.
# The full path (not parent + file name) keeps monorepo files from colliding, and
# collapsing runs of '-' means a leading underscore cannot yield '--' (the old
# governance derivation produced hook--mechanism-helper that way).
#   src/app/Settings.tsx → product-src-app-settings-tsx
_kg_product_id() {
  printf 'product-%s\n' "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//')"
}

# ============================================================
# Process each input file
# ============================================================
SKIPPED_EXIST=0

for input_path in "${FILE_ARGS[@]}"; do
  # Normalise: strip leading ./ and repo root prefix
  rel_path="${input_path#./}"
  rel_path="${rel_path#$REPO_ROOT/}"

  # Skip a path that already has a LIVE node. A stale-only path counts as
  # uncovered — the commit gate ignores stale nodes — so it gets a new node;
  # the stale one stays as history.
  if awk -v p="$rel_path" '
       /^  - id: / { if (match_p && st != "stale") found = 1; match_p = 0; st = "" }
       /^edges:/   { exit }
       /^    path: / { v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); gsub(/^["'\'']|["'\'']$/, "", v); if (v == p) match_p = 1 }
       /^    status: / { st = $0; sub(/^[^:]*:[[:space:]]*/, "", st); gsub(/^["'\'']|["'\''][[:space:]]*(#.*)?$/, "", st) }
       END { if (match_p && st != "stale") found = 1; exit !found }' "$GRAPH_FILE" 2>/dev/null; then
    echo "  skip (exists): $rel_path" >&2
    SKIPPED_EXIST=$((SKIPPED_EXIST + 1))
    continue
  fi

  node_id=$(_kg_product_id "$rel_path")
  # Two different paths can sanitise to the same id (a_b.ts / a-b.ts). Suffix
  # rather than collide — a duplicate id fails kg-validate --strict. Checked
  # against the graph AND the ids queued by this run: add_node dedupes by id,
  # so a collision between two files passed together would drop the second.
  _id_taken() {
    grep -qF "  - id: \"$1\"" "$GRAPH_FILE" 2>/dev/null && return 0
    case ",$SEEN_NODES," in *",$1,"*) return 0 ;; esac
    return 1
  }
  if _id_taken "$node_id"; then
    _n=2
    while _id_taken "$node_id-$_n"; do _n=$((_n + 1)); done
    node_id="$node_id-$_n"
  fi

  echo "  stub: $rel_path  id=$node_id" >&2
  # "Product source file" is the seeder default the commit gate rejects on
  # purpose: the stub is scaffolding until someone says what the file does.
  add_node "$node_id" "file" "$rel_path" "Product source file"
done

if [ "$NODE_COUNT" -eq 0 ]; then
  echo "kg-cover: no new nodes to add ($SKIPPED_EXIST already present)" >&2
  exit 0
fi

echo "kg-cover: $NODE_COUNT new node(s) to add ($SKIPPED_EXIST already present)" >&2

if [ "$DRY_RUN" = true ]; then
  echo "[dry-run] Would insert before 'edges:' in $GRAPH_FILE:" >&2
  printf '%s\n' "$NODE_LINES" >&2
  exit 0
fi

# ============================================================
# Write: insert new nodes before the 'edges:' section.
# awk finds the 'edges:' marker and inserts NODE_LINES above it.
# Preserves all existing nodes and edges intact.
# ============================================================
acquire_lock

TMPFILE="${GRAPH_FILE}.cover-tmp.$$"
NODEFILE="${GRAPH_FILE}.cover-nodes.$$"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# NODE_LINES is multi-line; awk -v cannot carry literal newlines portably
# (BSD/macOS awk aborts with "newline in string"). Stage it in a file and
# read it back with getline at the insertion point instead.
printf '%s' "$NODE_LINES" > "$NODEFILE"

awk -v nodefile="$NODEFILE" -v ts="$TIMESTAMP" '
  /^edges:/ { while ((getline line < nodefile) > 0) print line; close(nodefile) }
  /^last_updated:/ { print "last_updated: \"" ts "\""; next }
  { print }
' "$GRAPH_FILE" > "$TMPFILE"

rm -f "$NODEFILE"

# Never replace the graph with a truncated file — a partial awk run would
# otherwise destroy every node and edge.
if [ ! -s "$TMPFILE" ]; then
  rm -f "$TMPFILE"
  echo "ERROR: node insertion produced an empty file — graph left unchanged" >&2
  exit 1
fi

mv "$TMPFILE" "$GRAPH_FILE"

release_lock

echo "kg-cover: wrote $NODE_COUNT node(s) to $GRAPH_FILE" >&2

# ============================================================
# Post-write schema validation (matches kg-seed.sh pattern, Amendment 4)
# ============================================================
KG_VALIDATE="$(dirname "$0")/kg-validate.sh"
if [ ! -f "$KG_VALIDATE" ]; then
  echo "Advisory: kg-validate.sh not found — skipping post-write validation" >&2
  exit 0
fi

echo "Running schema validation..." >&2
if ! bash "$KG_VALIDATE" --strict --target "$TARGET"; then
  echo "ERROR: Schema validation failed after writing — graph may contain invalid data" >&2
  exit 1
fi

echo "kg-cover: done (schema valid)" >&2
