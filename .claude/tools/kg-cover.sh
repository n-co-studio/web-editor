#!/usr/bin/env bash
# Knowledge Graph Coverage Filler
# Decision 0034 — Knowledge Graph Data Layer (Amendment 7)
#
# Generates schema-complete stub nodes for a given list of file paths and
# appends them to the appropriate graph (graph.yaml or product-graph.yaml).
# Designed as the one-command remediation path for the KG Update Gate in
# pre-commit-gates.sh when a governance file lacks a graph node.
#
# Reuses add_node() and the mkdir-based locking pattern verbatim from
# kg-seed.sh — do not reimplement either.
#
# Usage:
#   kg-cover.sh [--target template|product] [--dry-run] <file> [<file>...]
#
#   --target template|product   Which graph to write (default: template).
#   --dry-run                   Print what would be written; write nothing.
#
# Exit codes:
#   0   All nodes written (or already present); kg-validate.sh --strict passes.
#   1   Graph not writable in current mode, or schema validation failed.
#
# Mode writability:
#   template graph (graph.yaml)        — writable in template mode only.
#   product graph (product-graph.yaml) — writable in template or child mode.
#   If the target graph is not writable in the current mode, exits 1.
#   This matches the exemption matrix in pre-commit-gates.sh which
#   downgrades to advisory when the graph is not writable.
#
# Constraint: shell I/O only — no Edit/Write tool writes to graph files
# (Decision 0034 §2). awk is used for in-place node insertion.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TODAY=$(date -u +%Y-%m-%d)
DRY_RUN=false
TARGET="template"

# --- Parse arguments ---
FILE_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      ;;
    --target)
      shift
      TARGET="${1:-template}"
      ;;
    -*)
      echo "Unknown option: $1" >&2
      echo "Usage: kg-cover.sh [--target template|product] [--dry-run] <file>..." >&2
      exit 1
      ;;
    *)
      FILE_ARGS+=("$1")
      ;;
  esac
  shift
done

if [ "${#FILE_ARGS[@]}" -eq 0 ]; then
  echo "Usage: kg-cover.sh [--target template|product] [--dry-run] <file>..." >&2
  exit 1
fi

# Validate target
case "$TARGET" in
  template|product) ;;
  *)
    echo "ERROR: --target must be 'template' or 'product', got '$TARGET'" >&2
    exit 1
    ;;
esac

# --- Resolve graph path ---
if [ "$TARGET" = "template" ]; then
  GRAPH_FILE="$REPO_ROOT/docs/ai/knowledge-graph/graph.yaml"
  LOCK_DIR="$REPO_ROOT/docs/ai/knowledge-graph/.graph-lock"
else
  GRAPH_FILE="$REPO_ROOT/docs/ai/knowledge-graph/product-graph.yaml"
  LOCK_DIR="$REPO_ROOT/docs/ai/knowledge-graph/.product-graph-lock"
fi

# --- Mode writability check ---
_current_mode="${REPO_OS_MODE:-}"
if [ -z "$_current_mode" ] && [ -f "$REPO_ROOT/.claude/repo-mode" ]; then
  _current_mode=$(cat "$REPO_ROOT/.claude/repo-mode" 2>/dev/null | tr -d '[:space:]')
fi
_current_mode="${_current_mode:-child}"

_mode_ok=false
case "$TARGET" in
  template)
    [ "$_current_mode" = "template" ] && _mode_ok=true
    ;;
  product)
    { [ "$_current_mode" = "template" ] || [ "$_current_mode" = "child" ]; } && _mode_ok=true
    ;;
esac

if [ "$_mode_ok" = false ]; then
  echo "ERROR: kg-cover.sh — target '$TARGET' graph is not writable in mode '$_current_mode'." >&2
  echo "  template graph: template mode only. product graph: template or child mode." >&2
  exit 1
fi

# --- Graph existence check ---
if [ ! -f "$GRAPH_FILE" ]; then
  echo "ERROR: Graph file not found: $GRAPH_FILE" >&2
  echo "  Run kg-seed.sh --target $TARGET to initialise the graph first." >&2
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
# graph.yaml.cover-tmp.$$ / .cover-nodes.$$ beside the graph, where they get
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
# Node ID and type derivation from file path
# ============================================================
_derive_node_id() {
  local p="$1"
  local fname
  fname=$(basename "$p")
  local stem="${fname%.*}"
  local sanitized
  sanitized=$(echo "$stem" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')

  case "$p" in
    .claude/hooks/*)
      echo "hook-${sanitized}" ;;
    .claude/tools/*)
      echo "tool-${sanitized}" ;;
    docs/ai/decisions/t-*)
      local num
      num=$(echo "$stem" | sed -n 's/^t-\([0-9][0-9]*\)-.*/\1/p')
      if [ -n "$num" ]; then
        echo "decision-${num}"
      else
        echo "decision-${sanitized}"
      fi
      ;;
    docs/ai/prompts/*)
      echo "${sanitized}" ;;
    .claude/agents/*)
      echo "agent-${sanitized}" ;;
    *)
      echo "file-${sanitized}" ;;
  esac
}

_derive_node_type() {
  local p="$1"
  case "$p" in
    .claude/hooks/*)          echo "hook" ;;
    .claude/tools/*)          echo "file" ;;   # No "tool" type in schema (Decision 0034 §4); use "file"
    docs/ai/decisions/*)      echo "decision" ;;
    docs/ai/prompts/*)        echo "prompt" ;;
    *)                        echo "file" ;;
  esac
}

_derive_description() {
  local p="$1"
  local fname
  fname=$(basename "$p")
  case "$p" in
    .claude/hooks/*)          echo "Hook: $fname" ;;
    .claude/tools/*)          echo "KG tooling: $fname" ;;
    docs/ai/decisions/*)      echo "Decision record: $fname" ;;
    docs/ai/prompts/*)        echo "Prompt: $fname" ;;
    .claude/agents/*)         echo "Agent: $fname" ;;
    *)                        echo "Governance file: $fname" ;;
  esac
}

# ============================================================
# Process each input file
# ============================================================
SKIPPED_EXIST=0

for input_path in "${FILE_ARGS[@]}"; do
  # Normalise: strip leading ./ and repo root prefix
  rel_path="${input_path#./}"
  rel_path="${rel_path#$REPO_ROOT/}"

  # Check if a node already exists for this path
  if grep -qF "path: \"$rel_path\"" "$GRAPH_FILE" 2>/dev/null; then
    echo "  skip (exists): $rel_path" >&2
    SKIPPED_EXIST=$((SKIPPED_EXIST + 1))
    continue
  fi

  node_id=$(_derive_node_id "$rel_path")
  node_type=$(_derive_node_type "$rel_path")
  node_desc=$(_derive_description "$rel_path")

  echo "  stub: $rel_path  id=$node_id  type=$node_type" >&2
  add_node "$node_id" "$node_type" "$rel_path" "$node_desc"
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
