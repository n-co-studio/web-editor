#!/usr/bin/env bash
# Knowledge Graph Schema Validator
# Decision 0034 — Knowledge Graph Data Layer (Amendment 4)
#
# Validates graph.yaml and/or product-graph.yaml against the enum constraints
# defined in docs/ai/knowledge-graph/schema.yaml. Uses awk (one pass per check)
# — no external dependencies (no yq, no Python, no Node.js).
#
# Checks:
#   - relation: values against 8-type taxonomy
#   - node type: values against 7 valid types
#   - status: values against 3 valid statuses
#   - source_type: values against 2 valid source types
#   - Required fields presence for nodes and edges
#   - Node ID uniqueness, per graph file — BLOCKING (t-0034 Amendment 8, R39)
#
# Reports but does NOT block:
#   - Referential integrity (source/target → a node id in the template+product
#     union). Advisory by decision, not by omission: t-0034 Amendment 2 §9 sets
#     that level for the equivalent kg-seed.sh check and Amendment 8 keeps it.
#
# Does NOT check:
#   - Node ID format, so `hook--mechanism-helper` passes (t-0034 Amendment 8)
#   - Node ID uniqueness ACROSS the two graphs — §10 intends it via distinct
#     prefixes, but that is a convention nothing enforces and the check would
#     need both graph files present
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
# _record_violations FILE RECORDS
# RECORDS is awk output: one "<line><TAB><message>" per violation.
# --------------------------------------------------------
_record_violations() {
  local graph_file="$1" records="$2" rec
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    _add_violation "$graph_file" "${rec%%$'\t'*}" "${rec#*$'\t'}"
  done <<EOF
$records
EOF
}

# --------------------------------------------------------
# Shared awk helpers (portable: POSIX/BSD awk, no gawk extensions).
#
# lastval(s, key) mirrors the former `sed -E 's/.*KEY: "([^"]+)".*/\1/'`:
# the greedy leading .* binds to the LAST `KEY: "..."` on the line, and a line
# with no such match is returned unchanged.
# addm(list, field) appends a field to a ", "-joined list.
# --------------------------------------------------------
_KG_AWK_LIB='
function lastval(s, key,    re, rest, hit, p) {
  re = key ": \"[^\"]+\""
  hit = ""
  rest = s
  while (match(rest, re)) {
    hit = substr(rest, RSTART, RLENGTH)
    rest = substr(rest, RSTART + 1)
  }
  if (hit == "") return s
  p = index(hit, "\"")
  return substr(hit, p + 1, length(hit) - p - 1)
}
function addm(list, field) {
  return (list == "") ? field : list ", " field
}
function emit(n, msg) {
  printf "%d\t%s\n", n, msg
}
'

# ============================================================
# Validate enum fields in a single graph file
# ============================================================
_validate_enums() {
  local graph_file="$1" nlines out
  # `read` drops an unterminated final line; cap awk at the newline count to match.
  nlines=$(wc -l < "$graph_file")

  out=$(awk -v last="$nlines" \
    -v rels="$VALID_RELATIONS" -v types="$VALID_NODE_TYPES" \
    -v stats="$VALID_STATUSES" -v srcs="$VALID_SOURCE_TYPES" \
    "$_KG_AWK_LIB"'
function inlist(v, list,    n, a, i) {
  n = split(list, a, " ")
  for (i = 1; i <= n; i++) if ((a[i] "") == (v "")) return 1
  return 0
}
NR > last { exit }
{
  line = $0
  # relation: "value" — only match quoted values (avoids matching YAML comments)
  if (line ~ /^ *relation: "[^"]+"/) {
    val = lastval(line, "relation")
    if (!inlist(val, rels)) emit(NR, "invalid relation: \"" val "\" (valid: " rels ")")
  }
  # node type: "value" — 4-space indent (node-level field, not edge)
  if (line ~ /^    type: "[^"]+"/) {
    val = lastval(line, "type")
    if (!inlist(val, types)) emit(NR, "invalid node type: \"" val "\" (valid: " types ")")
  }
  # status: "value"
  if (line ~ /^ *status: "[^"]+"/) {
    val = lastval(line, "status")
    if (!inlist(val, stats)) emit(NR, "invalid status: \"" val "\" (valid: " stats ")")
  }
  # source_type: "value"
  if (line ~ /^ *source_type: "[^"]+"/) {
    val = lastval(line, "source_type")
    if (!inlist(val, srcs)) emit(NR, "invalid source_type: \"" val "\" (valid: " srcs ")")
  }
}
' "$graph_file")

  _record_violations "$graph_file" "$out"
}

# ============================================================
# Check required fields for node blocks
# A node block starts with "  - id:" and must contain:
#   type, description, last_verified, status, layer
# ============================================================
_validate_node_fields() {
  local graph_file="$1" nlines out
  nlines=$(wc -l < "$graph_file")

  out=$(awk -v last="$nlines" "$_KG_AWK_LIB"'
function flush(    missing) {
  if (in_node && node_id != "") {
    missing = ""
    if (!has_type)   missing = addm(missing, "type")
    if (!has_desc)   missing = addm(missing, "description")
    if (!has_lv)     missing = addm(missing, "last_verified")
    if (!has_status) missing = addm(missing, "status")
    if (!has_layer)  missing = addm(missing, "layer")
    if (missing != "") emit(node_start_line, "node \"" node_id "\" missing required fields: " missing)
  }
}
NR > last { exit }
# Node block start: "  - id:"
/^  - id: / {
  flush()
  in_node = 1
  node_start_line = NR
  node_id = lastval($0, "id")
  has_type = has_desc = has_lv = has_status = has_layer = 0
  next
}
# Edge block start: "  - source:" — ends node section
/^  - source: / {
  flush()
  in_node = 0
  node_id = ""
  next
}
in_node {
  if (/^    type: /)          has_type = 1
  if (/^    description: /)   has_desc = 1
  if (/^    last_verified: /) has_lv = 1
  if (/^    status: /)        has_status = 1
  if (/^    layer: /)         has_layer = 1
}
END { flush() }
' "$graph_file")

  _record_violations "$graph_file" "$out"
}

# ============================================================
# Check required fields for edge blocks
# An edge block starts with "  - source:" and must contain:
#   target, relation, context, source_type, last_verified, status
# ============================================================
_validate_edge_fields() {
  local graph_file="$1" nlines out
  nlines=$(wc -l < "$graph_file")

  out=$(awk -v last="$nlines" "$_KG_AWK_LIB"'
function flush(    missing) {
  if (in_edge && edge_src != "") {
    missing = ""
    if (!has_tgt)    missing = addm(missing, "target")
    if (!has_rel)    missing = addm(missing, "relation")
    if (!has_ctx)    missing = addm(missing, "context")
    if (!has_st)     missing = addm(missing, "source_type")
    if (!has_lv)     missing = addm(missing, "last_verified")
    if (!has_status) missing = addm(missing, "status")
    if (missing != "") emit(edge_start_line, "edge from \"" edge_src "\" missing required fields: " missing)
  }
}
NR > last { exit }
# Edge block start: "  - source:"
/^  - source: / {
  flush()
  in_edge = 1
  edge_start_line = NR
  edge_src = lastval($0, "source")
  has_tgt = has_rel = has_ctx = has_st = has_lv = has_status = 0
  next
}
# Node block start: "  - id:" — ends edge section
/^  - id: / {
  flush()
  in_edge = 0
  edge_src = ""
  next
}
in_edge {
  if (/^    target: /)        has_tgt = 1
  if (/^    relation: /)      has_rel = 1
  if (/^    context: /)       has_ctx = 1
  if (/^    source_type: /)   has_st = 1
  if (/^    last_verified: /) has_lv = 1
  if (/^    status: /)        has_status = 1
}
END { flush() }
' "$graph_file")

  _record_violations "$graph_file" "$out"
}

# ============================================================
# Node id uniqueness — BLOCKING (known-issue R39)
# ============================================================
# The validator reported CLEAN on a graph holding TWO `- id: "tool-gate-conformance"`
# blocks with different descriptions and different last_verified dates. The graph
# therefore answered the same question two ways, decided by whether a consumer
# took the first match or the last, and nothing said so.
#
# This is a violation and not a warning because a duplicate id is not a style
# preference: it makes the graph self-contradictory. Dangling edge references are
# kept advisory below, matching t-0034 §9.
#
# Scope: per graph file. t-0034 §10 intends ids to be unique across the template
# and product graphs via distinct prefixes, but that is a convention the decision
# states and nothing enforces; a cross-graph check would need both files present
# and this template ships no product graph. Per-file is the part that is
# unambiguous today.
_validate_node_id_uniqueness() {
  local graph_file="$1" nlines out
  nlines=$(wc -l < "$graph_file")

  # First occurrence is remembered, every later one is reported against its own
  # line, so the message points at the copy a reader should delete.
  out=$(awk -v last="$nlines" "$_KG_AWK_LIB"'
NR > last { exit }
/^  - id: / {
  id = lastval($0, "id")
  if (id in seen_line) {
    emit(NR, "duplicate node id \"" id "\" — first declared at line " seen_line[id] "; the graph answers one question two ways")
  } else {
    seen_line[id] = NR
  }
}
' "$graph_file")

  _record_violations "$graph_file" "$out"
}

# ============================================================
# Edge referential integrity — ADVISORY (t-0034 §9)
# ============================================================
# t-0034 §9 states dangling references are "reported as warnings (advisory)",
# and kg-seed.sh already checks this at seed time in exactly that spirit. This
# adds the same reading to the validator without changing the enforcement level
# the decision set: it prints and does not block, and does not touch
# TOTAL_VIOLATIONS.
#
# Resolution uses the UNION of the template and product graphs, because edges
# live in the source node's graph (t-0034 §4) so a product-graph edge may
# legitimately point at a template node. A missing product graph is not an error.
_KG_ADVISORY_COUNT=0
_KG_ADVISORY_OUTPUT=""

_kg_union_node_ids() {
  local f
  for f in "$TEMPLATE_GRAPH" "$PRODUCT_GRAPH"; do
    [ -f "$f" ] || continue
    awk "$_KG_AWK_LIB"'/^  - id: / { print lastval($0, "id") }' "$f"
  done
}

_validate_edge_refs() {
  local graph_file="$1" nlines out ids_file
  nlines=$(wc -l < "$graph_file")
  ids_file="$(mktemp "${TMPDIR:-/tmp}/kg-ids-XXXXXX")"
  _kg_union_node_ids > "$ids_file"

  out=$(awk -v last="$nlines" -v idsfile="$ids_file" "$_KG_AWK_LIB"'
BEGIN {
  while ((getline line < idsfile) > 0) { if (line != "") known[line] = 1 }
  close(idsfile)
}
NR > last { exit }
/^  - source: / { ref = lastval($0, "source"); if (!(ref in known)) emit(NR, "edge source \"" ref "\" resolves to no node in the template+product union") }
/^    target: / { ref = lastval($0, "target"); if (!(ref in known)) emit(NR, "edge target \"" ref "\" resolves to no node in the template+product union") }
' "$graph_file")

  rm -f "$ids_file"

  local rec
  while IFS= read -r rec; do
    [ -z "$rec" ] && continue
    _KG_ADVISORY_OUTPUT="${_KG_ADVISORY_OUTPUT}  ${graph_file}:${rec%%$'\t'*}: ${rec#*$'\t'}
"
    _KG_ADVISORY_COUNT=$((_KG_ADVISORY_COUNT + 1))
  done <<EOF
$out
EOF
  return 0
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
  _validate_node_id_uniqueness "$graph_file"
  _validate_edge_refs "$graph_file"

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

# Advisory findings print whatever the violation count is, and never change the
# exit status (t-0034 §9). Printed before the result line so a clean run still
# surfaces them rather than ending on "CLEAN" with warnings hidden above.
if [ "$_KG_ADVISORY_COUNT" -gt 0 ]; then
  echo "Advisory: $_KG_ADVISORY_COUNT dangling edge reference(s) — not blocking (Decision t-0034 §9):"
  printf '%s' "$_KG_ADVISORY_OUTPUT"
  echo ""
fi

if [ "$TOTAL_VIOLATIONS" -eq 0 ]; then
  if [ "$_KG_ADVISORY_COUNT" -gt 0 ]; then
    echo "Result: CLEAN — no schema violations found ($_KG_ADVISORY_COUNT advisory finding(s) above)"
  else
    echo "Result: CLEAN — no schema violations found"
  fi
  exit 0
else
  echo "Result: $TOTAL_VIOLATIONS violation(s) found:"
  printf '%s' "$VIOLATION_OUTPUT"
  if [ "$STRICT" = true ]; then
    exit 1
  fi
  exit 0
fi
