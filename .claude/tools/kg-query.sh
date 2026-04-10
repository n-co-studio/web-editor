#!/usr/bin/env bash
# kg-query.sh — Knowledge Graph query CLI for agents
# Usage: kg-query.sh <subcommand> [args] [--graph-dir <path>]
#
# Subcommands:
#   neighbors <node-id>           List direct neighbors with edge metadata
#   path <source-id> <target-id> Find shortest path (BFS)
#   hubs [--top N]                Top N nodes by edge count (default 10)
#   stats                         Node/edge counts, avg degree, layer breakdown
#   search <pattern>              Grep node IDs and descriptions matching pattern
#
# Requirements: yq (v4) OR python3 (fallback for YAML parsing)
# Security: No eval. All variables quoted. Node-id format validated.

set -euo pipefail

# ============================================================
# Config
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GRAPH_DIR="$REPO_ROOT/docs/ai/knowledge-graph"
GRAPH_FILE="$GRAPH_DIR/graph.yaml"
PRODUCT_FILE="$GRAPH_DIR/product-graph.yaml"
# Script-level default prevents "unbound variable" from EXIT traps registered
# inside subcommand functions (local tmpdir goes out of scope on function return).
tmpdir=""

# ============================================================
# Helpers
# ============================================================

usage() {
  cat >&2 <<'EOF'
Usage: kg-query.sh <subcommand> [args] [--graph-dir <path>]

Subcommands:
  neighbors <node-id>            Direct neighbors with edge metadata
  path <source-id> <target-id>  Shortest path between two nodes (BFS)
  hubs [--top N]                 Top N most-connected nodes (default: 10)
  stats                          Graph statistics (counts, avg degree, layers)
  search <pattern>               Search node IDs and descriptions

Options:
  --graph-dir <path>   Override graph directory (default: docs/ai/knowledge-graph/)

Requirements: yq v4 or python3
EOF
  exit 1
}

# Validate node ID: allow alphanumeric, hyphens, dots, underscores (no slashes, etc.)
validate_node_id() {
  local id="$1"
  if [[ ! "$id" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Error: Invalid node ID '$id'. Node IDs may only contain alphanumerics, hyphens, dots, underscores." >&2
    exit 1
  fi
}

# Parse YAML graph files into TSV format
parse_graphs() {
  local tmpdir="$1"
  local nodes_file="$tmpdir/nodes.tsv"
  local edges_file="$tmpdir/edges.tsv"

  : > "$nodes_file"
  : > "$edges_file"

  local files=()
  [ -f "$GRAPH_FILE" ] && files+=("$GRAPH_FILE")
  [ -f "$PRODUCT_FILE" ] && files+=("$PRODUCT_FILE")

  if [ "${#files[@]}" -eq 0 ]; then
    echo "Error: No graph files found in $GRAPH_DIR" >&2
    exit 1
  fi

  if command -v yq &>/dev/null && yq --version 2>&1 | grep -q "v4\|version 4"; then
    # yq v4 path
    for f in "${files[@]}"; do
      yq '.nodes[] | [.id, .type, (.layer // "template"), .description] | @tsv' "$f" >> "$nodes_file" 2>/dev/null || true
      yq '.edges[] | [.source, .target, .relation, (.source_type // "agent-inferred"), ((.confidence // 0.5) | tostring)] | @tsv' "$f" >> "$edges_file" 2>/dev/null || true
    done
  elif command -v python3 &>/dev/null; then
    for f in "${files[@]}"; do
      KG_NODES_FILE="$nodes_file" KG_EDGES_FILE="$edges_file" \
        python3 - "$f" <<'PYEOF' 2>/dev/null || true
import sys, os

filepath = sys.argv[1]
nodes_file = os.environ.get('KG_NODES_FILE', '/dev/null')
edges_file = os.environ.get('KG_EDGES_FILE', '/dev/null')

try:
    import yaml
    with open(filepath) as fh:
        data = yaml.safe_load(fh)
    with open(nodes_file, 'a') as nf:
        for n in (data or {}).get('nodes', []):
            nid = str(n.get('id', '')).replace('\t', ' ')
            ntype = str(n.get('type', '')).replace('\t', ' ')
            nlayer = str(n.get('layer', 'template')).replace('\t', ' ')
            ndesc = str(n.get('description', '')).replace('\t', ' ')
            nf.write(f"{nid}\t{ntype}\t{nlayer}\t{ndesc}\n")
    with open(edges_file, 'a') as ef:
        for e in (data or {}).get('edges', []):
            src = str(e.get('source', '')).replace('\t', ' ')
            tgt = str(e.get('target', '')).replace('\t', ' ')
            rel = str(e.get('relation', '')).replace('\t', ' ')
            stype = str(e.get('source_type', 'agent-inferred')).replace('\t', ' ')
            conf = str(e.get('confidence', 0.5)).replace('\t', ' ')
            ef.write(f"{src}\t{tgt}\t{rel}\t{stype}\t{conf}\n")
except ImportError:
    print("Warning: PyYAML not available. Install with: pip install pyyaml", file=sys.stderr)
except Exception as ex:
    print(f"Warning: could not parse {filepath}: {ex}", file=sys.stderr)
PYEOF
    done
  else
    echo "Error: kg-query.sh requires either yq (v4) or python3 with PyYAML." >&2
    echo "Install yq: brew install yq  or  https://github.com/mikefarah/yq" >&2
    exit 1
  fi

  export KG_NODES_FILE="$nodes_file"
  export KG_EDGES_FILE="$edges_file"
}

# ============================================================
# Subcommands
# ============================================================

cmd_neighbors() {
  local node_id="$1"
  validate_node_id "$node_id"

  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  parse_graphs "$tmpdir"

  # Check node exists
  if ! awk -F'\t' -v id="$node_id" '$1 == id { found=1; exit } END { exit !found }' "$KG_NODES_FILE" 2>/dev/null; then
    echo "Error: Node '$node_id' not found in graph." >&2
    exit 1
  fi

  echo "Neighbors of: $node_id"
  echo "---"
  local found=0
  while IFS=$'\t' read -r src tgt rel stype conf; do
    if [ "$src" = "$node_id" ]; then
      printf "  -> %-40s  %-14s  %-20s  conf=%s\n" "$tgt" "$rel" "$stype" "$conf"
      found=1
    elif [ "$tgt" = "$node_id" ]; then
      printf "  <- %-40s  %-14s  %-20s  conf=%s\n" "$src" "$rel" "$stype" "$conf"
      found=1
    fi
  done < "$KG_EDGES_FILE"

  if [ "$found" -eq 0 ]; then
    echo "  (no edges -- isolated node)"
  fi
}

cmd_path() {
  local src_id="$1"
  local tgt_id="$2"
  validate_node_id "$src_id"
  validate_node_id "$tgt_id"

  if [ "$src_id" = "$tgt_id" ]; then
    echo "Path: $src_id (same node)"
    exit 0
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  parse_graphs "$tmpdir"

  python3 - "$KG_EDGES_FILE" "$src_id" "$tgt_id" <<'PYEOF'
import sys
from collections import deque

edges_file = sys.argv[1]
src = sys.argv[2]
tgt = sys.argv[3]

adj = {}
edge_labels = {}

try:
    with open(edges_file) as fh:
        for line in fh:
            parts = line.rstrip('\n').split('\t')
            if len(parts) < 2:
                continue
            a, b = parts[0], parts[1]
            rel = parts[2] if len(parts) > 2 else '?'
            adj.setdefault(a, []).append(b)
            adj.setdefault(b, []).append(a)
            edge_labels[(a, b)] = rel
            edge_labels[(b, a)] = rel
except Exception as ex:
    print(f"Error reading edges: {ex}", file=sys.stderr)
    sys.exit(1)

visited = {src: None}
prev_edge = {src: None}
queue = deque([src])

while queue:
    node = queue.popleft()
    if node == tgt:
        break
    for neighbor in adj.get(node, []):
        if neighbor not in visited:
            visited[neighbor] = node
            prev_edge[neighbor] = edge_labels.get((node, neighbor), '?')
            queue.append(neighbor)

if tgt not in visited:
    print(f"No path found between '{src}' and '{tgt}'.")
    sys.exit(0)

path = []
node = tgt
while node is not None:
    path.append(node)
    node = visited[node]
path.reverse()

print(f"Shortest path ({len(path) - 1} hops):")
for i, step in enumerate(path):
    if i == 0:
        print(f"  {step}")
    else:
        rel = prev_edge.get(path[i], '?')
        print(f"  --[{rel}]--> {step}")
PYEOF
}

cmd_hubs() {
  local top_n=10
  while [ $# -gt 0 ]; do
    case "$1" in
      --top) shift; top_n="${1:-10}" ;;
      *) ;;
    esac
    shift 2>/dev/null || break
  done

  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  parse_graphs "$tmpdir"

  python3 - "$KG_EDGES_FILE" "$KG_NODES_FILE" "$top_n" <<'PYEOF'
import sys

edges_file = sys.argv[1]
nodes_file = sys.argv[2]
top_n = int(sys.argv[3])

counts = {}
try:
    with open(edges_file) as fh:
        for line in fh:
            parts = line.rstrip('\n').split('\t')
            if len(parts) < 2:
                continue
            src, tgt = parts[0], parts[1]
            counts[src] = counts.get(src, 0) + 1
            counts[tgt] = counts.get(tgt, 0) + 1
except Exception as ex:
    print(f"Error: {ex}", file=sys.stderr)
    sys.exit(1)

node_types = {}
node_layers = {}
try:
    with open(nodes_file) as fh:
        for line in fh:
            parts = line.rstrip('\n').split('\t')
            if len(parts) >= 3:
                nid, ntype, nlayer = parts[0], parts[1], parts[2]
                node_types[nid] = ntype
                node_layers[nid] = nlayer
except Exception:
    pass

ranked = sorted(counts.items(), key=lambda x: x[1], reverse=True)[:top_n]

print(f"Top {top_n} hub nodes:")
print(f"  {'Rank':<5}  {'Edges':<6}  {'Type':<12}  {'Layer':<10}  Node ID")
print(f"  {'-'*5}  {'-'*6}  {'-'*12}  {'-'*10}  {'-'*40}")
for i, (nid, cnt) in enumerate(ranked, 1):
    ntype = node_types.get(nid, '?')
    nlayer = node_layers.get(nid, '?')
    print(f"  {i:<5}  {cnt:<6}  {ntype:<12}  {nlayer:<10}  {nid}")
PYEOF
}

cmd_stats() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  parse_graphs "$tmpdir"

  python3 - "$KG_EDGES_FILE" "$KG_NODES_FILE" <<'PYEOF'
import sys

edges_file = sys.argv[1]
nodes_file = sys.argv[2]

nodes = []
layers = {}
types = {}
try:
    with open(nodes_file) as fh:
        for line in fh:
            parts = line.rstrip('\n').split('\t')
            if len(parts) >= 3:
                nid, ntype, nlayer = parts[0], parts[1], parts[2]
                nodes.append(nid)
                layers[nlayer] = layers.get(nlayer, 0) + 1
                types[ntype] = types.get(ntype, 0) + 1
except Exception as ex:
    print(f"Error reading nodes: {ex}", file=sys.stderr)
    sys.exit(1)

edges = []
edge_counts = {}
try:
    with open(edges_file) as fh:
        for line in fh:
            parts = line.rstrip('\n').split('\t')
            if len(parts) >= 2:
                src, tgt = parts[0], parts[1]
                edges.append((src, tgt))
                edge_counts[src] = edge_counts.get(src, 0) + 1
                edge_counts[tgt] = edge_counts.get(tgt, 0) + 1
except Exception as ex:
    print(f"Error reading edges: {ex}", file=sys.stderr)
    sys.exit(1)

total_nodes = len(nodes)
total_edges = len(edges)
avg_degree = (sum(edge_counts.values()) / total_nodes) if total_nodes > 0 else 0

print("Graph Statistics")
print("================")
print(f"  Total nodes:  {total_nodes}")
print(f"  Total edges:  {total_edges}")
print(f"  Avg degree:   {avg_degree:.2f}")
print()
print("Layer breakdown:")
for layer, count in sorted(layers.items()):
    print(f"  {layer:<12}  {count}")
print()
print("Type breakdown:")
for ntype, count in sorted(types.items()):
    print(f"  {ntype:<14}  {count}")
PYEOF
}

cmd_search() {
  local pattern="$1"
  if [ -z "$pattern" ]; then
    echo "Error: search requires a pattern argument." >&2
    exit 1
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  parse_graphs "$tmpdir"

  echo "Search results for: $pattern"
  echo "---"
  local found=0
  while IFS=$'\t' read -r nid ntype nlayer ndesc; do
    if echo "$nid" | grep -qi "$pattern" 2>/dev/null || \
       echo "$ndesc" | grep -qi "$pattern" 2>/dev/null; then
      printf "  %-40s  %-12s  %-10s  %s\n" "$nid" "$ntype" "$nlayer" "$ndesc"
      found=1
    fi
  done < "$KG_NODES_FILE"

  if [ "$found" -eq 0 ]; then
    echo "  (no matches)"
  fi
}

# ============================================================
# Argument parsing
# ============================================================

if [ $# -eq 0 ]; then
  usage
fi

# Parse --graph-dir override before subcommand dispatch
while [ $# -gt 0 ]; do
  case "$1" in
    --graph-dir)
      shift
      GRAPH_DIR="${1:-}"
      GRAPH_FILE="$GRAPH_DIR/graph.yaml"
      PRODUCT_FILE="$GRAPH_DIR/product-graph.yaml"
      shift
      ;;
    *)
      break
      ;;
  esac
done

SUBCOMMAND="${1:-}"
shift || true

case "$SUBCOMMAND" in
  neighbors)
    if [ $# -eq 0 ]; then
      echo "Error: neighbors requires a node-id argument." >&2
      exit 1
    fi
    cmd_neighbors "$1"
    ;;
  path)
    if [ $# -lt 2 ]; then
      echo "Error: path requires <source-id> <target-id>." >&2
      exit 1
    fi
    cmd_path "$1" "$2"
    ;;
  hubs)
    cmd_hubs "$@"
    ;;
  stats)
    cmd_stats
    ;;
  search)
    if [ $# -eq 0 ]; then
      echo "Error: search requires a pattern argument." >&2
      exit 1
    fi
    cmd_search "$1"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    echo "Error: Unknown subcommand '$SUBCOMMAND'." >&2
    usage
    ;;
esac
