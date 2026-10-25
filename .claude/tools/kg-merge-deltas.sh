#!/usr/bin/env bash
# Knowledge Graph Delta Aggregator
# Decision 0034 Amendment 5 — Parallel Task Group Delta Authoring
#
# Reads per-brief and merge-brief KG delta files from the shared state path,
# dedups nodes and edges, and applies the aggregated result to the appropriate
# shared graph (graph.yaml or product-graph.yaml) in a single locked write.
#
# Replaces the N+1 per-brief direct graph writes that previously occurred at
# the close of each parallel content brief.
#
# Inputs:
#   <group_name>           Task group name. Aggregates files matching
#                          $REPO_ROOT/.claude/.state/tg-<group_name>-brief-*.kg-delta.yaml
#
# Options:
#   --dry-run              Parse and dedup but do not write the graph
#   --start-time ISO8601   Stale-delta cutoff. Deltas with authored_at older
#                          than this are dropped with a warning. When omitted,
#                          all deltas are accepted.
#
# Exit codes:
#   0  Success (deltas applied or dry-run completed)
#   1  Usage error
#   2  Lock acquisition failure
#   3  Delta parse error (no deltas applied)
#
# Conflict reporting:
#   Status conflicts ((source,target,relation) tuple with different status
#   across deltas) are logged to $REPO_ROOT/.claude/.state/kg-aggregation-conflicts.log
#   so the merge brief's Critic can surface them as CRITICAL cohesion findings.
#   The first-seen status is kept in the aggregated output — the write itself
#   does not block.
#
# Operator-curated edges in the existing graph are never overwritten; deltas
# attempting to modify them are dropped with a warning.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="$REPO_ROOT/.claude/.state"
TEMPLATE_GRAPH="$REPO_ROOT/docs/ai/knowledge-graph/graph.yaml"
PRODUCT_GRAPH="$REPO_ROOT/docs/ai/knowledge-graph/product-graph.yaml"
TEMPLATE_LOCK="$REPO_ROOT/docs/ai/knowledge-graph/.graph-lock"
PRODUCT_LOCK="$REPO_ROOT/docs/ai/knowledge-graph/.product-graph-lock"
CONFLICT_LOG="$STATE_DIR/kg-aggregation-conflicts.log"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

DRY_RUN=false
START_TIME=""
GROUP_NAME=""

# --- Parse arguments ---
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --start-time)
      shift
      START_TIME="${1:-}"
      ;;
    -h|--help)
      sed -n '/^# Knowledge Graph Delta Aggregator/,/^set -euo pipefail/p' "$0" \
        | sed 's/^# //; s/^#//' | head -40
      exit 0
      ;;
    *)
      if [ -z "$GROUP_NAME" ]; then
        GROUP_NAME="$1"
      else
        echo "ERROR: unexpected argument: $1" >&2
        echo "Usage: kg-merge-deltas.sh <group_name> [--dry-run] [--start-time ISO]" >&2
        exit 1
      fi
      ;;
  esac
  shift
done

if [ -z "$GROUP_NAME" ]; then
  echo "Usage: kg-merge-deltas.sh <group_name> [--dry-run] [--start-time ISO]" >&2
  exit 1
fi

# --- Locate delta files ---
PATTERN="$STATE_DIR/tg-${GROUP_NAME}-brief-*.kg-delta.yaml"
# Avoid set -e tripping on no-match — collect via find for portability
DELTA_FILES=$(find "$STATE_DIR" -maxdepth 1 -type f -name "tg-${GROUP_NAME}-brief-*.kg-delta.yaml" 2>/dev/null | sort)

if [ -z "$DELTA_FILES" ]; then
  echo "kg-merge-deltas: no deltas found for group '${GROUP_NAME}' (pattern: $PATTERN)" >&2
  exit 0
fi

# --- Per-delta header extraction ---
# Returns: target<TAB>authored_at<TAB>brief_seq for one delta file on stdout
_extract_header() {
  local f="$1"
  awk '
    /^target:/        { gsub(/.*target: *"?/, ""); gsub(/"? *$/, ""); target=$0 }
    /^authored_at:/   { gsub(/.*authored_at: *"?/, ""); gsub(/"? *$/, ""); authored=$0 }
    /^brief_seq:/     { gsub(/.*brief_seq: *"?/, ""); gsub(/"? *$/, ""); seq=$0 }
    /^nodes:/ { exit }
    /^edges:/ { exit }
    END { print target "\t" authored "\t" seq }
  ' "$f"
}

# --- Stale check (lexicographic ISO 8601 comparison) ---
_is_stale() {
  local authored="$1"
  [ -z "$START_TIME" ] && return 1
  [ -z "$authored" ] && return 1
  # ISO 8601 strings sort lexicographically — "<" via test is fine
  if [ "$authored" \< "$START_TIME" ]; then
    return 0
  fi
  return 1
}

# --- Build aggregation work files ---
# We accumulate normalized records into temp files keyed by target. A node
# record is one line: "node\t<id>\t<authored_at>\t<type>\t<path>\t<description>\t<last_verified>\t<status>\t<layer>".
# An edge record: "edge\t<source>\t<target>\t<relation>\t<authored_at>\t<context>\t<source_type>\t<last_verified>\t<status>\t<confidence>".
# Tabs are forbidden in YAML scalar values here — graph.yaml emits attributes
# inside double quotes without literal tabs (verified by inspection of seeded
# graph). Embedded quotes are not escaped in the existing graph either.
WORK_TEMPLATE_NODES=$(mktemp)
WORK_TEMPLATE_EDGES=$(mktemp)
WORK_PRODUCT_NODES=$(mktemp)
WORK_PRODUCT_EDGES=$(mktemp)

# Active lock + intermediates released on EXIT — _apply_target sets these
# before/after the lock window so an abort under set -euo pipefail still
# releases the lock directory and cleans the per-function tmpfiles. Without
# this, a failure between acquire_lock and release_lock would leave a stale
# .graph-lock / .product-graph-lock blocking all future KG writes.
ACTIVE_LOCK=""
ACTIVE_INTERMEDIATES=""

_kg_cleanup() {
  rm -f "$WORK_TEMPLATE_NODES" "$WORK_TEMPLATE_EDGES" "$WORK_PRODUCT_NODES" "$WORK_PRODUCT_EDGES" 2>/dev/null || true
  if [ -n "$ACTIVE_LOCK" ]; then
    rmdir "$ACTIVE_LOCK" 2>/dev/null || true
  fi
  if [ -n "$ACTIVE_INTERMEDIATES" ]; then
    # shellcheck disable=SC2086
    rm -f $ACTIVE_INTERMEDIATES 2>/dev/null || true
  fi
}
trap _kg_cleanup EXIT

# --- Parse one delta into normalized records, append to per-target work files ---
_parse_delta() {
  local f="$1" target="$2" authored="$3"
  local node_out edge_out
  case "$target" in
    template) node_out="$WORK_TEMPLATE_NODES"; edge_out="$WORK_TEMPLATE_EDGES" ;;
    product)  node_out="$WORK_PRODUCT_NODES";  edge_out="$WORK_PRODUCT_EDGES" ;;
    *)
      echo "WARNING: delta $f declares unknown target '$target' — dropped" >&2
      return 0
      ;;
  esac

  awk -v authored="$authored" -v node_out="$node_out" -v edge_out="$edge_out" '
    BEGIN { section=""; cur_id=""; cur_type=""; cur_path=""; cur_desc=""; cur_lv=""; cur_status=""; cur_layer="";
            cur_src=""; cur_tgt=""; cur_rel=""; cur_ctx=""; cur_st=""; cur_conf="" }

    function flush_node() {
      if (cur_id != "") {
        printf "node\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
          cur_id, authored, cur_type, cur_path, cur_desc, cur_lv, cur_status, cur_layer >> node_out
      }
      cur_id=""; cur_type=""; cur_path=""; cur_desc=""; cur_lv=""; cur_status=""; cur_layer=""
    }
    function flush_edge() {
      if (cur_src != "" && cur_tgt != "" && cur_rel != "") {
        printf "edge\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
          cur_src, cur_tgt, cur_rel, authored, cur_ctx, cur_st, cur_lv, cur_status, cur_conf >> edge_out
      }
      cur_src=""; cur_tgt=""; cur_rel=""; cur_ctx=""; cur_st=""; cur_lv=""; cur_status=""; cur_conf=""
    }
    function strip_quotes(s) { gsub(/^"|"$/, "", s); return s }
    function get_val(line) { sub(/^[^:]+: *"?/, "", line); sub(/"? *$/, "", line); return line }

    /^nodes:/ { flush_edge(); section="nodes"; next }
    /^edges:/ { flush_node(); section="edges"; next }

    section == "nodes" && /^  - id:/ {
      flush_node()
      cur_id = get_val($0)
      next
    }
    section == "nodes" && /^    type:/        { cur_type   = get_val($0); next }
    section == "nodes" && /^    path:/        { cur_path   = get_val($0); next }
    section == "nodes" && /^    description:/ { cur_desc   = get_val($0); next }
    section == "nodes" && /^    last_verified:/ { cur_lv  = get_val($0); next }
    section == "nodes" && /^    status:/      { cur_status = get_val($0); next }
    section == "nodes" && /^    layer:/       { cur_layer  = get_val($0); next }

    section == "edges" && /^  - source:/ {
      flush_edge()
      cur_src = get_val($0)
      next
    }
    section == "edges" && /^    target:/      { cur_tgt    = get_val($0); next }
    section == "edges" && /^    relation:/    { cur_rel    = get_val($0); next }
    section == "edges" && /^    context:/     { cur_ctx    = get_val($0); next }
    section == "edges" && /^    source_type:/ { cur_st     = get_val($0); next }
    section == "edges" && /^    last_verified:/ { cur_lv  = get_val($0); next }
    section == "edges" && /^    status:/      { cur_status = get_val($0); next }
    section == "edges" && /^    confidence:/  { cur_conf   = get_val($0); next }

    END { if (section == "nodes") flush_node(); else if (section == "edges") flush_edge() }
  ' "$f"
}

# --- Header pass ---
TOTAL=0
ACCEPTED=0
STALE=0
PARSE_ERR=0

for f in $DELTA_FILES; do
  TOTAL=$((TOTAL + 1))
  hdr=$(_extract_header "$f")
  target=$(echo "$hdr" | cut -f1)
  authored=$(echo "$hdr" | cut -f2)
  seq=$(echo "$hdr" | cut -f3)

  if [ -z "$target" ] || [ -z "$authored" ]; then
    echo "WARNING: delta $f missing required header fields (target=$target authored=$authored) — dropped" >&2
    PARSE_ERR=$((PARSE_ERR + 1))
    continue
  fi

  case "$target" in
    template|product) ;;
    *)
      echo "WARNING: delta $f declares unknown target '$target' (valid: template, product) — dropped" >&2
      PARSE_ERR=$((PARSE_ERR + 1))
      continue
      ;;
  esac

  if _is_stale "$authored"; then
    echo "WARNING: stale delta $f (authored_at=$authored < start_time=$START_TIME) — dropped" >&2
    STALE=$((STALE + 1))
    continue
  fi

  _parse_delta "$f" "$target" "$authored" || {
    echo "WARNING: parse error in $f — skipped" >&2
    PARSE_ERR=$((PARSE_ERR + 1))
    continue
  }
  ACCEPTED=$((ACCEPTED + 1))
  echo "  accepted: brief-${seq} target=${target} authored_at=${authored}"
done

echo ""
echo "Delta intake: ${ACCEPTED}/${TOTAL} accepted (${STALE} stale, ${PARSE_ERR} parse-error)"

if [ "$ACCEPTED" -eq 0 ]; then
  if [ "$PARSE_ERR" -gt 0 ]; then
    echo "kg-merge-deltas: ${PARSE_ERR} delta(s) had parse errors and none were accepted — exiting 3 (parse-error)" >&2
    exit 3
  fi
  echo "kg-merge-deltas: no deltas accepted — nothing to apply" >&2
  exit 0
fi

# --- Lock acquisition (mkdir-based, Decision 0034 §8) ---
acquire_lock() {
  local lock_dir="$1"
  local attempts=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 30 ]; then
      echo "ERROR: kg-merge-deltas: failed to acquire lock $lock_dir after 30 attempts" >&2
      return 2
    fi
    sleep 1
  done
  return 0
}
release_lock() {
  rmdir "$1" 2>/dev/null || true
}

# --- Aggregate + apply for one target graph ---
# Reads the work files, dedups, and splices the merged nodes/edges into the
# target graph file. The graph file format produced by kg-seed.sh is:
#   schema_version: 1
#   last_updated: "..."
#
#   nodes:
#   <node entries>
#   edges:
#   <edge entries>
# We preserve any pre-existing nodes/edges in the target graph and merge in
# the delta's contributions per the dedup rules in Amendment 5.
_apply_target() {
  local target="$1"
  local node_work="$2"
  local edge_work="$3"
  local graph_file lock_dir
  case "$target" in
    template) graph_file="$TEMPLATE_GRAPH"; lock_dir="$TEMPLATE_LOCK" ;;
    product)  graph_file="$PRODUCT_GRAPH";  lock_dir="$PRODUCT_LOCK"  ;;
  esac

  # Skip targets with no contributions
  [ -s "$node_work" ] || [ -s "$edge_work" ] || return 0

  echo ""
  echo "Applying ${target} delta → $(basename "$graph_file")"

  if [ ! -f "$graph_file" ]; then
    echo "  WARNING: target graph $graph_file does not exist — creating empty graph" >&2
    cat > "$graph_file.tmp" << EOF
# Knowledge Graph — ${target} layer
# Decision 0034 — Knowledge Graph Data Layer

schema_version: 1
last_updated: "${NOW}"

nodes:
edges:
EOF
    mv "$graph_file.tmp" "$graph_file"
  fi

  if [ "$DRY_RUN" = true ]; then
    echo "  [dry-run] would acquire $(basename "$lock_dir") and splice $(wc -l < "$node_work" | tr -d ' ') node-records, $(wc -l < "$edge_work" | tr -d ' ') edge-records"
    return 0
  fi

  if ! acquire_lock "$lock_dir"; then
    return 2
  fi

  # Hand the active lock + intermediates to the EXIT trap so a failure between
  # this point and the matching release_lock still cleans up. Intermediates
  # are the per-function tmpfiles created during splice (renamed/cleaned at
  # the bottom of this function on success).
  ACTIVE_LOCK="$lock_dir"
  ACTIVE_INTERMEDIATES="$graph_file.pre $graph_file.exnodes $graph_file.exedges $graph_file.kept_nodes $graph_file.skip_ids $graph_file.delta_nodes $graph_file.kept_edges $graph_file.skip_tups $graph_file.delta_edges $graph_file.merge.tmp"

  # Existing operator-curated edges (set of "source|target|relation" tuples)
  # Used to drop delta edges that would overwrite an operator-curated edge.
  local oc_edges
  oc_edges=$(awk '
    /^  - source:/ { src=""; tgt=""; rel=""; st=""; capture=1
      sub(/.*source: *"?/, ""); sub(/"? *$/, ""); src=$0; next
    }
    capture && /^    target:/      { sub(/.*target: *"?/, ""); sub(/"? *$/, ""); tgt=$0; next }
    capture && /^    relation:/    { sub(/.*relation: *"?/, ""); sub(/"? *$/, ""); rel=$0; next }
    capture && /^    source_type:/ {
      sub(/.*source_type: *"?/, ""); sub(/"? *$/, ""); st=$0
      if (st == "operator-curated") print src "|" tgt "|" rel
      capture=0
    }
  ' "$graph_file")

  # --- Dedup nodes per Amendment 5: by id, last authored_at wins on conflicts ---
  # Sort nodes ascending by authored_at, then awk keeps the LAST seen for each id.
  # Field layout: 1=node 2=id 3=authored 4=type 5=path 6=desc 7=lv 8=status 9=layer
  local merged_nodes
  merged_nodes=$(sort -t '	' -k3,3 "$node_work" 2>/dev/null | awk -F'\t' '
    { ids[$2]=$0 }
    END { for (i in ids) print ids[i] }
  ' | sort -t '	' -k2,2)

  # --- Dedup edges per Amendment 5 ---
  # by (source, target, relation): last authored_at wins on attribute updates,
  # max wins on confidence, status conflicts surfaced separately.
  # Field layout: 1=edge 2=src 3=tgt 4=rel 5=authored 6=ctx 7=src_type 8=lv 9=status 10=confidence
  # Conflict capture file: awk emits CONFLICT records to stderr, which we
  # redirect to a tmpfile so it cannot contaminate the merged_edges payload
  # if awk itself emits incidental warnings on some platforms.
  local conflict_tmp
  conflict_tmp=$(mktemp)
  ACTIVE_INTERMEDIATES="$ACTIVE_INTERMEDIATES $conflict_tmp"

  local merged_edges status_conflicts
  merged_edges=$(sort -t '	' -k2,2 -k3,3 -k4,4 -k5,5 "$edge_work" 2>/dev/null | awk -F'\t' '
    { tup = $2 "|" $3 "|" $4
      # Track distinct status values per tuple for conflict surfacing
      if (!(tup in status_seen)) status_seen[tup] = $9
      else if (status_seen[tup] != $9) status_conflicts[tup] = status_seen[tup] " vs " $9
      # Last-write-wins (sort placed newest authored_at last)
      prev = lines[tup]
      if (prev == "") {
        lines[tup] = $0
        max_conf[tup] = $10
      } else {
        # Update with the newer line, but carry forward the max confidence seen.
        new_conf = ($10 > max_conf[tup]) ? $10 : max_conf[tup]
        lines[tup] = $0
        max_conf[tup] = new_conf
      }
    }
    END {
      for (t in lines) {
        # Patch confidence to max-seen
        n = split(lines[t], f, "\t")
        f[10] = max_conf[t]
        # On status conflict, restore first-seen status (Amendment 5 — do not
        # silently let last-write-wins pick a status that disagrees with another
        # delta — surface the disagreement and keep the earliest).
        if (t in status_conflicts) f[9] = status_seen[t]
        printf "%s", f[1]
        for (i = 2; i <= n; i++) printf "\t%s", f[i]
        printf "\n"
      }
      for (t in status_conflicts) print t "\t" status_conflicts[t] > "/dev/stderr"
    }
  ' 2>"$conflict_tmp")
  status_conflicts=$(cat "$conflict_tmp")
  rm -f "$conflict_tmp"

  # --- Conflict log writing ---
  if [ -n "$status_conflicts" ]; then
    {
      echo "# kg-aggregation-conflicts — group=${GROUP_NAME} target=${target} run_at=${NOW}"
      printf '# Format: tuple(source|target|relation)\\tstatus_diff\n'
      printf '%s\n' "$status_conflicts"
    } >> "$CONFLICT_LOG"
    local conflict_count
    conflict_count=$(printf '%s\n' "$status_conflicts" | wc -l | tr -d ' ')
    echo "  CRITICAL: ${conflict_count} status conflict(s) recorded → $(basename "$CONFLICT_LOG")"
  fi

  # --- Drop delta edges that would overwrite operator-curated edges ---
  if [ -n "$oc_edges" ]; then
    local before_count after_count
    before_count=$(printf '%s\n' "$merged_edges" | grep -c '^edge	' || true)
    while IFS= read -r oc; do
      [ -z "$oc" ] && continue
      local oc_src oc_tgt oc_rel
      oc_src=$(echo "$oc" | cut -d'|' -f1)
      oc_tgt=$(echo "$oc" | cut -d'|' -f2)
      oc_rel=$(echo "$oc" | cut -d'|' -f3)
      merged_edges=$(printf '%s\n' "$merged_edges" \
        | awk -F'\t' -v s="$oc_src" -v t="$oc_tgt" -v r="$oc_rel" '
            !($2 == s && $3 == t && $4 == r)
          ')
    done <<< "$oc_edges"
    after_count=$(printf '%s\n' "$merged_edges" | grep -c '^edge	' || true)
    if [ "$before_count" -ne "$after_count" ]; then
      echo "  preserved $((before_count - after_count)) operator-curated edge(s) — delta versions dropped"
    fi
  fi

  # --- Render new graph and splice ---
  # Strategy: read existing file, separate into pre-nodes, existing nodes,
  # between-section, existing edges, post-edges. Merge our records in.
  local new_graph="$graph_file.merge.tmp"

  # Separate file into segments using awk
  awk -v out_pre="$graph_file.pre" \
      -v out_nodes="$graph_file.exnodes" \
      -v out_edges="$graph_file.exedges" '
    BEGIN { section="pre" }
    /^nodes:/ { print > out_pre; section="nodes"; next }
    /^edges:/ { section="edges"; next }
    section == "pre"   { print > out_pre }
    section == "nodes" { print > out_nodes }
    section == "edges" { print > out_edges }
  ' "$graph_file"

  # Merge nodes: existing nodes that are NOT in the merged set are kept as-is;
  # nodes in the merged set are replaced by the delta-derived rendering (so
  # attribute updates take effect). New nodes are appended.
  local existing_in_delta=""
  if [ -n "$merged_nodes" ]; then
    existing_in_delta=$(echo "$merged_nodes" | awk -F'\t' '{print $2}')
  fi

  # Render kept-from-existing nodes (those NOT in delta)
  local kept_nodes_file="$graph_file.kept_nodes"
  local skip_ids_file="$graph_file.skip_ids"
  : > "$kept_nodes_file"
  printf '%s\n' "$existing_in_delta" > "$skip_ids_file"
  if [ -f "$graph_file.exnodes" ]; then
    awk -v skip_file="$skip_ids_file" -v out="$kept_nodes_file" '
      BEGIN {
        while ((getline line < skip_file) > 0) if (line != "") skip[line] = 1
        close(skip_file)
      }
      /^  - id:/ {
        if (cur != "") { if (!(cur_id in skip)) printf "%s", cur > out }
        cur=""; cur_id=$0
        sub(/.*id: *"?/, "", cur_id); sub(/"? *$/, "", cur_id)
      }
      { cur = cur $0 "\n" }
      END { if (cur != "") { if (!(cur_id in skip)) printf "%s", cur > out } }
    ' "$graph_file.exnodes"
  fi
  rm -f "$skip_ids_file"

  # Render delta nodes (replaces matched IDs and adds new IDs)
  local delta_nodes_rendered="$graph_file.delta_nodes"
  : > "$delta_nodes_rendered"
  if [ -n "$merged_nodes" ]; then
    printf '%s\n' "$merged_nodes" | awk -F'\t' -v out="$delta_nodes_rendered" '
      $1 == "node" {
        printf "  - id: \"%s\"\n",            $2 > out
        printf "    type: \"%s\"\n",          $4 > out
        if ($5 != "") printf "    path: \"%s\"\n", $5 > out
        printf "    description: \"%s\"\n",   $6 > out
        printf "    last_verified: \"%s\"\n", $7 > out
        printf "    status: \"%s\"\n",        $8 > out
        printf "    layer: \"%s\"\n",         $9 > out
      }
    '
  fi

  # Same for edges: drop existing edges whose tuple is in delta, append delta-derived
  local delta_edge_tuples=""
  if [ -n "$merged_edges" ]; then
    delta_edge_tuples=$(echo "$merged_edges" | awk -F'\t' '$1 == "edge" { print $2 "|" $3 "|" $4 }')
  fi

  local kept_edges_file="$graph_file.kept_edges"
  local skip_tups_file="$graph_file.skip_tups"
  : > "$kept_edges_file"
  printf '%s\n' "$delta_edge_tuples" > "$skip_tups_file"
  if [ -f "$graph_file.exedges" ]; then
    awk -v skip_file="$skip_tups_file" -v out="$kept_edges_file" '
      BEGIN {
        while ((getline line < skip_file) > 0) if (line != "") skip[line] = 1
        close(skip_file)
      }
      /^  - source:/ {
        if (cur != "") { tup = cur_src "|" cur_tgt "|" cur_rel; if (!(tup in skip)) printf "%s", cur > out }
        cur=""; cur_src=$0; cur_tgt=""; cur_rel=""
        sub(/.*source: *"?/, "", cur_src); sub(/"? *$/, "", cur_src)
      }
      /^    target:/   { v=$0; sub(/.*target: *"?/, "", v); sub(/"? *$/, "", v); cur_tgt=v }
      /^    relation:/ { v=$0; sub(/.*relation: *"?/, "", v); sub(/"? *$/, "", v); cur_rel=v }
      { cur = cur $0 "\n" }
      END { if (cur != "") { tup = cur_src "|" cur_tgt "|" cur_rel; if (!(tup in skip)) printf "%s", cur > out } }
    ' "$graph_file.exedges"
  fi
  rm -f "$skip_tups_file"

  local delta_edges_rendered="$graph_file.delta_edges"
  : > "$delta_edges_rendered"
  if [ -n "$merged_edges" ]; then
    printf '%s\n' "$merged_edges" | awk -F'\t' -v out="$delta_edges_rendered" '
      $1 == "edge" {
        printf "  - source: \"%s\"\n",       $2 > out
        printf "    target: \"%s\"\n",       $3 > out
        printf "    relation: \"%s\"\n",     $4 > out
        printf "    context: \"%s\"\n",      $6 > out
        printf "    source_type: \"%s\"\n",  $7 > out
        printf "    last_verified: \"%s\"\n", $8 > out
        printf "    status: \"%s\"\n",       $9 > out
        if ($10 != "") printf "    confidence: %s\n", $10 > out
      }
    '
  fi

  {
    cat "$graph_file.pre"
    cat "$kept_nodes_file"
    cat "$delta_nodes_rendered"
    echo "edges:"
    cat "$kept_edges_file"
    cat "$delta_edges_rendered"
  } > "$new_graph"

  # Update last_updated in-place
  sed "s|^last_updated: .*|last_updated: \"${NOW}\"|" "$new_graph" > "$graph_file"

  rm -f "$graph_file.pre" "$graph_file.exnodes" "$graph_file.exedges" \
        "$kept_nodes_file" "$delta_nodes_rendered" \
        "$kept_edges_file" "$delta_edges_rendered" \
        "$new_graph"

  release_lock "$lock_dir"
  ACTIVE_LOCK=""
  ACTIVE_INTERMEDIATES=""

  local n_new e_new
  n_new=$(printf '%s\n' "$merged_nodes" | grep -c '^node	' || true)
  e_new=$(printf '%s\n' "$merged_edges" | grep -c '^edge	' || true)
  echo "  applied: ${n_new} node record(s), ${e_new} edge record(s)"

  # Post-write schema validation (Amendment 4)
  local kg_validate
  kg_validate="$(dirname "$0")/kg-validate.sh"
  if [ -f "$kg_validate" ]; then
    if ! bash "$kg_validate" --strict --target "$target" >/dev/null 2>&1; then
      echo "  WARNING: post-merge schema validation flagged $(basename "$graph_file") — review before commit" >&2
    fi
  fi
}

_apply_target template "$WORK_TEMPLATE_NODES" "$WORK_TEMPLATE_EDGES"
_apply_target product  "$WORK_PRODUCT_NODES"  "$WORK_PRODUCT_EDGES"

echo ""
echo "kg-merge-deltas: done. Run cleanup at session close to remove delta files."
exit 0
