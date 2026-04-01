#!/usr/bin/env bash
# Knowledge Graph Relevance Scoring
# Decision 0034 — Knowledge Graph Data Layer
#
# Given a list of scope files from a task brief, produces a ranked list of
# also-relevant files by weighted graph traversal.
#
# Weight model:
#   - Files in brief scope: weight x50
#   - Direct edges from scope files: weight x10
#   - Governance edges (governs/constrains): weight x5
#   - Two-hop connections: weight x2
#   - Stale edges: weight x0.3
#   - Unverified edges: weight x0.5
#
# Output: ranked list of top-N files not already in the brief scope,
# with the edge path that makes them relevant.
#
# Usage: bash .claude/tools/kg-relevance.sh <scope-file1> [scope-file2] ... [--top N]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GRAPH_FILE="$REPO_ROOT/docs/ai/knowledge-graph/graph.yaml"

if [ ! -f "$GRAPH_FILE" ]; then
  echo "ERROR: Graph file not found at $GRAPH_FILE" >&2
  echo "Run .claude/tools/kg-seed.sh first to bootstrap the graph." >&2
  exit 1
fi

# --- Parse arguments ---
TOP_N=10
SCOPE_FILES=""
CONTEXT_INJECT=false
OUTPUT_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --top)
      shift
      TOP_N="${1:-10}"
      ;;
    --context-inject)
      CONTEXT_INJECT=true
      ;;
    --output)
      shift
      OUTPUT_FILE="${1:-}"
      ;;
    *)
      SCOPE_FILES="${SCOPE_FILES:+$SCOPE_FILES }$1"
      ;;
  esac
  shift
done

if [ -z "$SCOPE_FILES" ]; then
  echo "Usage: kg-relevance.sh <scope-file1> [scope-file2] ... [--top N] [--context-inject] [--output FILE]" >&2
  echo "" >&2
  echo "Example: kg-relevance.sh .claude/hooks/write-guard.sh AI.md --top 5" >&2
  echo "Context: kg-relevance.sh file1 file2 --context-inject --output .claude/.state/kg-relevance-context" >&2
  exit 1
fi

# --- Build scope node set ---
SCOPE_NODE_IDS=""
for scope_file in $SCOPE_FILES; do
  node_ids=$(grep -B5 "path: \"${scope_file}\"" "$GRAPH_FILE" 2>/dev/null | grep 'id: "' | sed 's/.*id: "\([^"]*\)".*/\1/' || true)
  if [ -n "$node_ids" ]; then
    SCOPE_NODE_IDS="${SCOPE_NODE_IDS:+$SCOPE_NODE_IDS }$node_ids"
  fi
  # Partial match for glob patterns
  node_ids=$(grep -B5 "path: \".*${scope_file}" "$GRAPH_FILE" 2>/dev/null | grep 'id: "' | sed 's/.*id: "\([^"]*\)".*/\1/' || true)
  if [ -n "$node_ids" ]; then
    SCOPE_NODE_IDS="${SCOPE_NODE_IDS:+$SCOPE_NODE_IDS }$node_ids"
  fi
done

SCOPE_NODE_IDS=$(echo "$SCOPE_NODE_IDS" | tr ' ' '\n' | sort -u | tr '\n' ' ')

if [ -z "$SCOPE_NODE_IDS" ]; then
  echo "No graph nodes found matching scope files: $SCOPE_FILES" >&2
  echo "The graph may need to be updated with these files." >&2
  exit 0
fi

echo "Scope nodes: $SCOPE_NODE_IDS"
echo "---"

# --- Weighted traversal ---
SCORE_FILE=$(mktemp)
trap "rm -f '$SCORE_FILE'" EXIT
_rank=0

for scope_id in $SCOPE_NODE_IDS; do
  # Forward edges (scope is source)
  grep -A8 "source: \"${scope_id}\"" "$GRAPH_FILE" 2>/dev/null | while IFS= read -r eline; do
    target=$(echo "$eline" | grep 'target: "' | sed 's/.*target: "\([^"]*\)".*/\1/')
    relation=$(echo "$eline" | grep 'relation: "' | sed 's/.*relation: "\([^"]*\)".*/\1/')
    status=$(echo "$eline" | grep 'status: "' | sed 's/.*status: "\([^"]*\)".*/\1/')
    if [ -n "$target" ]; then
      weight=10
      case "$relation" in governs|constrains) weight=5 ;; esac
      case "$status" in
        stale) weight=$((weight * 3 / 10)) ;;
        unverified) weight=$((weight * 5 / 10)) ;;
      esac
      echo "${target} ${weight} ${scope_id}->${relation}->${target}" >> "$SCORE_FILE"
    fi
  done || true

  # Reverse edges (scope is target)
  grep -A8 "target: \"${scope_id}\"" "$GRAPH_FILE" 2>/dev/null | while IFS= read -r eline; do
    source=$(echo "$eline" | grep 'source: "' | sed 's/.*source: "\([^"]*\)".*/\1/')
    relation=$(echo "$eline" | grep 'relation: "' | sed 's/.*relation: "\([^"]*\)".*/\1/')
    status=$(echo "$eline" | grep 'status: "' | sed 's/.*status: "\([^"]*\)".*/\1/')
    if [ -n "$source" ]; then
      weight=10
      case "$relation" in governs|constrains) weight=5 ;; esac
      case "$status" in
        stale) weight=$((weight * 3 / 10)) ;;
        unverified) weight=$((weight * 5 / 10)) ;;
      esac
      echo "${source} ${weight} ${source}->${relation}->${scope_id}" >> "$SCORE_FILE"
    fi
  done || true
done

# --- 2-hop traversal ---
if [ -f "$SCORE_FILE" ] && [ -s "$SCORE_FILE" ]; then
  HOP1_NODES=$(cut -d' ' -f1 "$SCORE_FILE" | sort -u)
  for hop1_id in $HOP1_NODES; do
    case " $SCOPE_NODE_IDS " in *" $hop1_id "*) continue ;; esac
    grep -A8 "source: \"${hop1_id}\"" "$GRAPH_FILE" 2>/dev/null | while IFS= read -r eline; do
      target=$(echo "$eline" | grep 'target: "' | sed 's/.*target: "\([^"]*\)".*/\1/')
      relation=$(echo "$eline" | grep 'relation: "' | sed 's/.*relation: "\([^"]*\)".*/\1/')
      if [ -n "$target" ]; then
        echo "${target} 2 ${hop1_id}->${relation}->${target}(2-hop)" >> "$SCORE_FILE"
      fi
    done || true
  done
fi

# --- Aggregate and rank ---
if [ ! -f "$SCORE_FILE" ] || [ ! -s "$SCORE_FILE" ]; then
  if [ "$CONTEXT_INJECT" = true ]; then
    _ci_output="# Knowledge Graph Context for: $SCOPE_FILES

No graph connections found for the specified scope files.

Files not in the graph may still be relevant — use search for undiscovered connections."
    if [ -n "$OUTPUT_FILE" ]; then
      printf '%s\n' "$_ci_output" > "$OUTPUT_FILE" 2>/dev/null || true
    else
      echo "$_ci_output"
    fi
    exit 0
  fi
  echo "No connections found from scope nodes."
  exit 0
fi

# --- Build ranked results (shared by both output modes) ---
# Produces: node_id, score, edge_path, file_path — tab-separated
RANKED_FILE=$(mktemp)
trap "rm -f '$SCORE_FILE' '$RANKED_FILE'" EXIT

awk -v scope="$SCOPE_NODE_IDS" '
BEGIN {
  split(scope, s, " ")
  for (i in s) skip[s[i]] = 1
}
{
  node = $1
  weight = $2
  path = ""
  for (i = 3; i <= NF; i++) path = path " " $i
  if (!(node in skip)) {
    scores[node] += weight
    if (!(node in paths)) paths[node] = path
  }
}
END {
  n = 0
  for (node in scores) {
    n++
    nodes[n] = node
    sc[n] = scores[node]
  }
  for (i = 2; i <= n; i++) {
    j = i
    while (j > 1 && sc[j] > sc[j-1]) {
      tmp = nodes[j]; nodes[j] = nodes[j-1]; nodes[j-1] = tmp
      tmp = sc[j]; sc[j] = sc[j-1]; sc[j-1] = tmp
      j--
    }
  }
  for (i = 1; i <= n && i <= '"$TOP_N"'; i++) {
    print nodes[i] "\t" sc[i] "\t" paths[nodes[i]]
  }
}
' "$SCORE_FILE" > "$RANKED_FILE"

# --- Context-inject output mode ---
if [ "$CONTEXT_INJECT" = true ]; then
  _ci_output="# Knowledge Graph Context for: $SCOPE_FILES
#
# Pre-computed relevance-scored connections from the knowledge graph.
# Consult these files before running broad codebase searches.
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
"
  _rank=0
  while IFS=$'\t' read -r _node_id _score _edge_path; do
    [ -z "$_node_id" ] && continue
    _rank=$((_rank + 1))
    _fpath=$(grep -A3 "id: \"${_node_id}\"" "$GRAPH_FILE" 2>/dev/null | grep 'path: "' | head -1 | sed 's/.*path: "\([^"]*\)".*/\1/' || true)
    _relation=$(echo "$_edge_path" | sed 's/.*->\([^-]*\)->.*$/\1/' | xargs)
    if [ -n "$_fpath" ]; then
      _ci_output="${_ci_output}
${_rank}. ${_fpath} — ${_relation} — via ${_edge_path}"
    else
      _ci_output="${_ci_output}
${_rank}. ${_node_id} — ${_relation} — via ${_edge_path}"
    fi
  done < "$RANKED_FILE"

  _ci_output="${_ci_output}

# Files not in the graph may still be relevant — use search for undiscovered connections."

  if [ -n "$OUTPUT_FILE" ]; then
    printf '%s\n' "$_ci_output" > "$OUTPUT_FILE" 2>/dev/null || true
  else
    echo "$_ci_output"
  fi
  exit 0
fi

# --- Standard output mode ---
echo ""
echo "Top-${TOP_N} also-relevant nodes:"
echo ""

_std_rank=0
while IFS=$'\t' read -r _node_id _score _edge_path; do
  [ -z "$_node_id" ] && continue
  _std_rank=$((_std_rank + 1))
  printf "%3d. [score=%s] %s\n     via:%s\n" "$_std_rank" "$_score" "$_node_id" "$_edge_path"
done < "$RANKED_FILE"

# --- File path lookup for top results ---
echo ""
echo "File paths for top results:"
while IFS=$'\t' read -r _node_id _score _edge_path; do
  [ -z "$_node_id" ] && continue
  file_path=$(grep -A3 "id: \"${_node_id}\"" "$GRAPH_FILE" 2>/dev/null | grep 'path: "' | head -1 | sed 's/.*path: "\([^"]*\)".*/\1/' || true)
  if [ -n "$file_path" ] && [ "$file_path" != "" ]; then
    echo "  $file_path"
  fi
done < "$RANKED_FILE"
