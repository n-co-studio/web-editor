#!/usr/bin/env bash
# Knowledge Graph Schema Validator
# Decision 0034 — Knowledge Graph Data Layer (Amendment 4)
#
# Validates graph.yaml and/or product-graph.yaml against the enum constraints
# defined in docs/ai/knowledge-graph/schema.yaml. Uses grep/sed only —
# no external dependencies (no yq, no Python, no Node.js).
#
# Checks:
#   - relation: values against 8-type taxonomy
#   - node type: values against 7 valid types
#   - status: values against 3 valid statuses
#   - source_type: values against 2 valid source types
#   - Required fields presence for nodes and edges
#
# Does NOT check:
#   - Referential integrity (source/target → existing node IDs)
#   - Node ID format (feat: prefix convention)
#
# Usage:
#   kg-validate.sh [--target template|product|both] [--strict]
#
#   --target   Which graph(s) to validate (default: both)
#   --strict   Exit non-zero on violations (default: exit 0 with warnings)
#
# Exit codes:
#   0  Clean (or --strict not set)
#   1  Violations found (only when --strict)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCHEMA_FILE="$REPO_ROOT/docs/ai/knowledge-graph/schema.yaml"
TEMPLATE_GRAPH="$REPO_ROOT/docs/ai/knowledge-graph/graph.yaml"
PRODUCT_GRAPH="$REPO_ROOT/docs/ai/knowledge-graph/product-graph.yaml"

TARGET="both"
STRICT=false

# --- Parse arguments ---
while [ $# -gt 0 ]; do
  case "$1" in
    --target)
      shift
      TARGET="${1:-both}"
      ;;
    --strict)
      STRICT=true
      ;;
    --help|-h)
      sed -n '/^# Usage:/,/^$/p' "$0" | grep -v '^#!' | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: kg-validate.sh [--target template|product|both] [--strict]" >&2
      exit 1
      ;;
  esac
  shift
done

# Validate target
case "$TARGET" in
  template|product|both) ;;
  *)
    echo "ERROR: --target must be 'template', 'product', or 'both', got '$TARGET'" >&2
    exit 1
    ;;
esac

# --- Fail-open guard: schema.yaml must exist ---
if [ ! -f "$SCHEMA_FILE" ]; then
  echo "WARNING: schema.yaml not found at $SCHEMA_FILE — skipping validation (fail-open)" >&2
  exit 0
fi

# --- Valid enum values (from schema.yaml) ---
VALID_RELATIONS="governs constrains implements depends-on produces consumes tests supersedes"
VALID_NODE_TYPES="file decision hook prompt contract concept convention"
VALID_STATUSES="active stale unverified"
VALID_SOURCE_TYPES="agent-inferred operator-curated"

# --- Violation tracking ---
TOTAL_VIOLATIONS=0
VIOLATION_OUTPUT=""

_add_violation() {
  local vfile="$1" vline="$2" vmsg="$3"
  VIOLATION_OUTPUT="${VIOLATION_OUTPUT}  ${vfile}:${vline}: ${vmsg}
"
  TOTAL_VIOLATIONS=$((TOTAL_VIOLATIONS + 1))
}

# --------------------------------------------------------
# _is_valid_enum VAL VALID_LIST
# Returns 0 if VAL is in the space-delimited VALID_LIST, 1 otherwise.
# Safe with set -e: always returns a defined value.
# --------------------------------------------------------
_is_valid_enum() {
  local val="$1" valid_list="$2"
  local v
  for v in $valid_list; do
    if [ "$val" = "$v" ]; then
      return 0
    fi
  done
  return 1
}

# ============================================================
# Validate enum fields in a single graph file
# ============================================================
_validate_enums() {
  local graph_file="$1"
  local line_num=0
  local line val

  while IFS= read -r line; do
    line_num=$((line_num + 1))

    # relation: "value" — only match quoted values (avoids matching YAML comments)
    if echo "$line" | grep -qE '^ *relation: "[^"]+"'; then
      val=$(echo "$line" | sed -E 's/.*relation: "([^"]+)".*/\1/')
      if ! _is_valid_enum "$val" "$VALID_RELATIONS"; then
        _add_violation "$graph_file" "$line_num" "invalid relation: \"$val\" (valid: $VALID_RELATIONS)"
      fi
    fi

    # node type: "value" — 4-space indent (node-level field, not edge)
    if echo "$line" | grep -qE '^ {4}type: "[^"]+"'; then
      val=$(echo "$line" | sed -E 's/.*type: "([^"]+)".*/\1/')
      if ! _is_valid_enum "$val" "$VALID_NODE_TYPES"; then
        _add_violation "$graph_file" "$line_num" "invalid node type: \"$val\" (valid: $VALID_NODE_TYPES)"
      fi
    fi

    # status: "value"
    if echo "$line" | grep -qE '^ *status: "[^"]+"'; then
      val=$(echo "$line" | sed -E 's/.*status: "([^"]+)".*/\1/')
      if ! _is_valid_enum "$val" "$VALID_STATUSES"; then
        _add_violation "$graph_file" "$line_num" "invalid status: \"$val\" (valid: $VALID_STATUSES)"
      fi
    fi

    # source_type: "value"
    if echo "$line" | grep -qE '^ *source_type: "[^"]+"'; then
      val=$(echo "$line" | sed -E 's/.*source_type: "([^"]+)".*/\1/')
      if ! _is_valid_enum "$val" "$VALID_SOURCE_TYPES"; then
        _add_violation "$graph_file" "$line_num" "invalid source_type: \"$val\" (valid: $VALID_SOURCE_TYPES)"
      fi
    fi

  done < "$graph_file"
}

# ============================================================
# Check required fields for node blocks
# A node block starts with "  - id:" and must contain:
#   type, description, last_verified, status, layer
# ============================================================
_validate_node_fields() {
  local graph_file="$1"
  local in_node=false
  local node_start_line=0
  local node_id=""
  local has_type=false has_desc=false has_lv=false has_status=false has_layer=false
  local line_num=0
  local line

  _flush_node() {
    # Report missing required fields for the current node
    if [ "$in_node" = true ] && [ -n "$node_id" ]; then
      local missing=""
      if [ "$has_type" = false ];   then missing="${missing:+$missing, }type"; fi
      if [ "$has_desc" = false ];   then missing="${missing:+$missing, }description"; fi
      if [ "$has_lv" = false ];     then missing="${missing:+$missing, }last_verified"; fi
      if [ "$has_status" = false ]; then missing="${missing:+$missing, }status"; fi
      if [ "$has_layer" = false ];  then missing="${missing:+$missing, }layer"; fi
      if [ -n "$missing" ]; then
        _add_violation "$graph_file" "$node_start_line" "node \"$node_id\" missing required fields: $missing"
      fi
    fi
  }

  while IFS= read -r line; do
    line_num=$((line_num + 1))

    # Node block start: "  - id:"
    if echo "$line" | grep -qE '^ {2}- id: '; then
      _flush_node
      in_node=true
      node_start_line=$line_num
      node_id=$(echo "$line" | sed -E 's/.*id: "([^"]+)".*/\1/')
      has_type=false; has_desc=false; has_lv=false; has_status=false; has_layer=false
      continue
    fi

    # Edge block start: "  - source:" — ends node section
    if echo "$line" | grep -qE '^ {2}- source: '; then
      _flush_node
      in_node=false
      node_id=""
      continue
    fi

    if [ "$in_node" = true ]; then
      if echo "$line" | grep -qE '^ {4}type: ';         then has_type=true; fi
      if echo "$line" | grep -qE '^ {4}description: ';  then has_desc=true; fi
      if echo "$line" | grep -qE '^ {4}last_verified: '; then has_lv=true; fi
      if echo "$line" | grep -qE '^ {4}status: ';       then has_status=true; fi
      if echo "$line" | grep -qE '^ {4}layer: ';        then has_layer=true; fi
    fi
  done < "$graph_file"

  # Flush the last node
  _flush_node
}

# ============================================================
# Check required fields for edge blocks
# An edge block starts with "  - source:" and must contain:
#   target, relation, context, source_type, last_verified, status
# ============================================================
_validate_edge_fields() {
  local graph_file="$1"
  local in_edge=false
  local edge_start_line=0
  local edge_src=""
  local has_tgt=false has_rel=false has_ctx=false has_st=false has_lv=false has_status=false
  local line_num=0
  local line

  _flush_edge() {
    if [ "$in_edge" = true ] && [ -n "$edge_src" ]; then
      local missing=""
      if [ "$has_tgt" = false ];    then missing="${missing:+$missing, }target"; fi
      if [ "$has_rel" = false ];    then missing="${missing:+$missing, }relation"; fi
      if [ "$has_ctx" = false ];    then missing="${missing:+$missing, }context"; fi
      if [ "$has_st" = false ];     then missing="${missing:+$missing, }source_type"; fi
      if [ "$has_lv" = false ];     then missing="${missing:+$missing, }last_verified"; fi
      if [ "$has_status" = false ]; then missing="${missing:+$missing, }status"; fi
      if [ -n "$missing" ]; then
        _add_violation "$graph_file" "$edge_start_line" "edge from \"$edge_src\" missing required fields: $missing"
      fi
    fi
  }

  while IFS= read -r line; do
    line_num=$((line_num + 1))

    # Edge block start: "  - source:"
    if echo "$line" | grep -qE '^ {2}- source: '; then
      _flush_edge
      in_edge=true
      edge_start_line=$line_num
      edge_src=$(echo "$line" | sed -E 's/.*source: "([^"]+)".*/\1/')
      has_tgt=false; has_rel=false; has_ctx=false; has_st=false; has_lv=false; has_status=false
      continue
    fi

    # Node block start: "  - id:" — ends edge section
    if echo "$line" | grep -qE '^ {2}- id: '; then
      _flush_edge
      in_edge=false
      edge_src=""
      continue
    fi

    if [ "$in_edge" = true ]; then
      if echo "$line" | grep -qE '^ {4}target: ';       then has_tgt=true; fi
      if echo "$line" | grep -qE '^ {4}relation: ';     then has_rel=true; fi
      if echo "$line" | grep -qE '^ {4}context: ';      then has_ctx=true; fi
      if echo "$line" | grep -qE '^ {4}source_type: ';  then has_st=true; fi
      if echo "$line" | grep -qE '^ {4}last_verified: '; then has_lv=true; fi
      if echo "$line" | grep -qE '^ {4}status: ';       then has_status=true; fi
    fi
  done < "$graph_file"

  # Flush the last edge
  _flush_edge
}

# ============================================================
# Validate a single graph file
# ============================================================
validate_graph() {
  local graph_file="$1"
  local label="$2"

  if [ ! -f "$graph_file" ]; then
    echo "  SKIP: $label graph not found at $graph_file"
    return 0
  fi

  echo "  Validating $label: $(basename "$graph_file")"

  local violations_before=$TOTAL_VIOLATIONS

  _validate_enums "$graph_file"
  _validate_node_fields "$graph_file"
  _validate_edge_fields "$graph_file"

  local file_violations=$(( TOTAL_VIOLATIONS - violations_before ))
  if [ "$file_violations" -eq 0 ]; then
    echo "    OK — no violations"
  else
    echo "    VIOLATIONS: $file_violations violation(s)"
  fi
}

# ============================================================
# Main: run validation on selected targets
# ============================================================
echo "KG Schema Validator — Decision 0034 Amendment 4"
echo "Schema: $SCHEMA_FILE"
echo ""

case "$TARGET" in
  template)
    validate_graph "$TEMPLATE_GRAPH" "template"
    ;;
  product)
    validate_graph "$PRODUCT_GRAPH" "product"
    ;;
  both)
    validate_graph "$TEMPLATE_GRAPH" "template"
    validate_graph "$PRODUCT_GRAPH" "product"
    ;;
esac

echo ""

if [ "$TOTAL_VIOLATIONS" -eq 0 ]; then
  echo "Result: CLEAN — no schema violations found"
  exit 0
else
  echo "Result: $TOTAL_VIOLATIONS violation(s) found:"
  printf '%s' "$VIOLATION_OUTPUT"
  if [ "$STRICT" = true ]; then
    exit 1
  fi
  exit 0
fi
