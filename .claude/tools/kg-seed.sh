#!/usr/bin/env bash
# Knowledge Graph Bootstrap Seeder
# Decision 0034 — Knowledge Graph Data Layer
#
# Generates the initial graph from existing governance metadata:
# - Parses DIGEST.md trigger annotations for decision -> code path edges
# - Parses AI.md source-of-truth section for governance file nodes
# - Parses AI.md hook table for hook -> state file edges
# - Parses prompt file cross-references for implements/consumes edges
#
# Two-graph architecture (Amendment 2):
#   --target template  →  writes docs/ai/knowledge-graph/graph.yaml (default)
#   --target product   →  writes docs/ai/knowledge-graph/product-graph.yaml
#
# Product file discovery (Amendment 2 §10):
#   --source files     →  discover product source files (default for --target product)
#   --file-pattern     →  glob pattern for file discovery (default: src/**/*.ts)
#                         Format: <base-dir>/**/*.<ext>  e.g. src/**/*.tsx
#
# Output: writes to the target graph file
# All edges are agent-inferred and unverified.
#
# Usage: bash .claude/tools/kg-seed.sh [--target template|product]
#          [--source files|governance] [--file-pattern PATTERN] [--dry-run]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIGEST_FILE="$REPO_ROOT/docs/ai/decisions/DIGEST.md"
AI_MD="$REPO_ROOT/AI.md"
TODAY=$(date -u +%Y-%m-%d)
DRY_RUN=false
TARGET="template"
SOURCE="files"                # files | governance
FILE_PATTERN="src/**/*.ts"    # glob pattern for product file discovery

# --- Parse arguments ---
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      ;;
    --target)
      shift
      TARGET="${1:-template}"
      ;;
    --source)
      shift
      SOURCE="${1:-files}"
      ;;
    --file-pattern)
      shift
      FILE_PATTERN="${1:-src/**/*.ts}"
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: kg-seed.sh [--target template|product] [--source files|governance] [--file-pattern PATTERN] [--dry-run]" >&2
      exit 1
      ;;
  esac
  shift
done

# Validate target
case "$TARGET" in
  template|product) ;;
  *)
    echo "ERROR: --target must be 'template' or 'product', got '$TARGET'" >&2
    exit 1
    ;;
esac

# Validate source
case "$SOURCE" in
  files|governance) ;;
  *)
    echo "ERROR: --source must be 'files' or 'governance', got '$SOURCE'" >&2
    exit 1
    ;;
esac

# --- Set paths based on target ---
if [ "$TARGET" = "template" ]; then
  GRAPH_FILE="$REPO_ROOT/docs/ai/knowledge-graph/graph.yaml"
  LOCK_DIR="$REPO_ROOT/docs/ai/knowledge-graph/.graph-lock"
else
  GRAPH_FILE="$REPO_ROOT/docs/ai/knowledge-graph/product-graph.yaml"
  LOCK_DIR="$REPO_ROOT/docs/ai/knowledge-graph/.product-graph-lock"
fi

# The other graph file (for cross-graph integrity check)
if [ "$TARGET" = "template" ]; then
  OTHER_GRAPH="$REPO_ROOT/docs/ai/knowledge-graph/product-graph.yaml"
else
  OTHER_GRAPH="$REPO_ROOT/docs/ai/knowledge-graph/graph.yaml"
fi

echo "Target: $TARGET → $GRAPH_FILE"

# --- Lock for concurrent write safety (Decision 0030 pattern) ---
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
trap release_lock EXIT

# --- Collector variables (Bash 3 compatible) ---
NODE_LINES=""
EDGE_LINES=""
SEEN_NODES=""
NODE_COUNT=0
EDGE_COUNT=0

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

add_edge() {
  local src="$1" tgt="$2" rel="$3" ctx="$4"
  EDGE_COUNT=$((EDGE_COUNT + 1))
  EDGE_LINES="${EDGE_LINES}  - source: \"${src}\"
    target: \"${tgt}\"
    relation: \"${rel}\"
    context: \"${ctx}\"
    source_type: \"agent-inferred\"
    last_verified: \"${TODAY}\"
    status: \"unverified\"
"
}

# ============================================================
# Cross-graph integrity check (advisory)
# ============================================================
_integrity_check_cross_graph() {
  local other="$1"
  local this_graph="$2"

  if [ ! -f "$other" ]; then
    echo "  (other graph not found — skipping cross-graph check)"
    return 0
  fi

  echo "  Checking edge references across graphs..."
  local warnings=0

  # Collect all node IDs from both graphs
  local ALL_NODE_IDS
  ALL_NODE_IDS=$(grep 'id: "' "$this_graph" "$other" 2>/dev/null | sed 's/.*id: "\([^"]*\)".*/\1/' | sort -u)

  # Check all edges in both graphs for dangling references
  for gfile in "$this_graph" "$other"; do
    grep -E '(source|target): "' "$gfile" 2>/dev/null | sed 's/.*: "\([^"]*\)".*/\1/' | sort -u | while read -r ref_id; do
      if ! echo "$ALL_NODE_IDS" | grep -qx "$ref_id"; then
        echo "  WARNING: Dangling reference '$ref_id' in $(basename "$gfile") — no matching node in either graph"
        warnings=$((warnings + 1))
      fi
    done
  done

  echo "  Cross-graph integrity: check complete"
}

# ============================================================
# Product target: scan product source code (Amendment 2 §10)
# ============================================================
if [ "$TARGET" = "product" ]; then
  if [ "$SOURCE" = "files" ]; then
    echo "Discovering product files: $FILE_PATTERN"

    # Parse pattern: extract base dir (before /**) and extension (after *.)
    # Supports: src/**/*.ts  src/**/*.tsx  lib/**/*.py  etc.
    PATTERN_BASE="${FILE_PATTERN%%/**/*}"
    if [ "$PATTERN_BASE" = "$FILE_PATTERN" ]; then
      PATTERN_BASE="src"
    fi
    FILE_EXT="${FILE_PATTERN##*.}"
    if [ "$FILE_EXT" = "$FILE_PATTERN" ] || [ -z "$FILE_EXT" ]; then
      FILE_EXT="ts"
    fi

    SEARCH_ROOT="$REPO_ROOT/$PATTERN_BASE"

    if [ ! -d "$SEARCH_ROOT" ]; then
      echo "  Source directory not found: $SEARCH_ROOT — no nodes added"
      echo "  Tip: set --file-pattern to match your project layout (e.g. app/**/*.ts)"
    else
      echo "  Scanning: $SEARCH_ROOT for *.${FILE_EXT} files"

      # Load existing node IDs for deduplication
      EXISTING_IDS=""
      if [ -f "$GRAPH_FILE" ]; then
        EXISTING_IDS=$(grep '  id: "' "$GRAPH_FILE" | sed 's/.*id: "\([^"]*\)".*/\1/' | tr '\n' ',')
      fi

      ADDED=0
      SKIPPED_EXIST=0

      while IFS= read -r fpath; do
        [ -z "$fpath" ] && continue

        rel_path="${fpath#$REPO_ROOT/}"
        fname=$(basename "$fpath")
        fname_noext="${fname%.*}"

        # Derive feature label from immediate parent directory name
        parent_dir=$(dirname "$rel_path")
        feature=$(basename "$parent_dir" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')
        if [ -z "$feature" ] || [ "$feature" = "." ]; then
          feature="root"
        fi

        # Generate node ID: product-<feature>-<filename> (Decision 0034 Amendment 2 §10)
        sanitized=$(echo "$fname_noext" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')
        node_id="product-${feature}-${sanitized}"

        # Skip if node ID already exists in graph
        case ",$EXISTING_IDS," in
          *",$node_id,"*) SKIPPED_EXIST=$((SKIPPED_EXIST+1)); continue ;;
        esac

        add_node "$node_id" "file" "$rel_path" "Product source file"
        ADDED=$((ADDED+1))
      done < <(find "$SEARCH_ROOT" \
        -not \( -path "*/node_modules/*" \) \
        -not \( -path "*/dist/*" \) \
        -not \( -path "*/build/*" \) \
        -not \( -path "*/.git/*" \) \
        -not \( -path "*/coverage/*" \) \
        -not \( -path "*/.next/*" \) \
        -type f -name "*.${FILE_EXT}" 2>/dev/null | sort)

      echo "  Added $ADDED nodes, skipped $SKIPPED_EXIST (already exist in graph)"
    fi
  else
    # governance source: not implemented for product target
    echo "  --source governance: no product governance seeding implemented"
    echo "  Use --source files for automatic file node discovery"
  fi

  echo ""
  echo "Results: ${NODE_COUNT} nodes, ${EDGE_COUNT} edges"

  if [ "$DRY_RUN" = true ]; then
    echo "[dry-run] Would write to $GRAPH_FILE"
  else
    acquire_lock

    TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cat > "$GRAPH_FILE" << GRAPH_EOF
# Knowledge Graph — Product Layer
# Decision 0034 — Knowledge Graph Data Layer (Amendment 2)
# Generated by kg-seed.sh --target product on ${TIMESTAMP}

schema_version: 1
last_updated: "${TIMESTAMP}"

nodes:
${NODE_LINES}
edges:
${EDGE_LINES}
GRAPH_EOF

    release_lock
    echo "Graph written to $GRAPH_FILE"
  fi

  # Cross-graph integrity check (advisory)
  echo ""
  echo "Cross-graph integrity check..."
  _integrity_check_cross_graph "$OTHER_GRAPH" "$GRAPH_FILE"

  echo "Done."
  exit 0
fi

# ============================================================
# Template target passes (existing logic)
# ============================================================

# ============================================================
# Pass 1: Decision nodes from DIGEST.md
# ============================================================
echo "Pass 1: Extracting decision nodes from DIGEST.md..."
while IFS= read -r line; do
  if echo "$line" | grep -qE '^\*\*Decision [0-9]{4} '; then
    num=$(echo "$line" | sed -E 's/^\*\*Decision ([0-9]{4}).*/\1/')
    title=$(echo "$line" | sed -E 's/^\*\*Decision [0-9]{4} . ([^.]+)\..*/\1/' | head -c 80)
    add_node "decision-${num}" "decision" "docs/ai/decisions/t-${num}-*.md" "$title"
  fi
done < "$DIGEST_FILE"

# ============================================================
# Pass 2: Source-of-truth files from AI.md
# ============================================================
echo "Pass 2: Extracting source-of-truth nodes from AI.md..."
# Map paths to human-readable node IDs (must match graph.yaml IDs)
sot_path_to_id() {
  case "$1" in
    docs/spec/compiled/*) echo "compiled-spec" ;;
    docs/spec/prototypes/*) echo "prototypes" ;;
    docs/ai/workflow-summary.md) echo "workflow-summary" ;;
    docs/ai/quality-gates-summary.md) echo "quality-gates-summary" ;;
    docs/ai/hook-rules-summary.md) echo "hook-rules-summary" ;;
    docs/ai/decisions/*) echo "decisions" ;;
    docs/ai/logs/sessions/session-*.md) echo "session-log" ;;
    docs/ai/logs/known-issues.md) echo "known-issues" ;;
    docs/ai/governance/*) echo "governance" ;;
    AI.md) echo "ai-md" ;;
    .claude/agents/orchestrator.md) echo "orchestrator" ;;
    .claude/agents/_agent-glossary.md) echo "agent-glossary" ;;
    .claude/agents/_agent-workflow.md) echo "agent-workflow" ;;
    *) echo "$1" | sed 's|[/.]|-|g' | sed 's|[^a-zA-Z0-9-]||g' | tr '[:upper:]' '[:lower:]' ;;
  esac
}
in_sot=false
while IFS= read -r line; do
  if echo "$line" | grep -qE '^## Source of Truth'; then
    in_sot=true
    continue
  fi
  if [ "$in_sot" = true ] && echo "$line" | grep -qE '^## '; then
    break
  fi
  if [ "$in_sot" = true ]; then
    path=$(echo "$line" | sed -n 's/^- *\([^ (]*\).*/\1/p')
    if [ -n "$path" ] && [ "$path" != "-" ]; then
      path_id=$(sot_path_to_id "$path")
      ntype="file"
      case "$path" in
        docs/ai/decisions/*) ntype="decision" ;;
        docs/ai/prompts/*) ntype="prompt" ;;
        .claude/hooks/*) ntype="hook" ;;
      esac
      desc=$(echo "$line" | sed -n 's/^- *[^ ]* *(\([^)]*\)).*/\1/p')
      if [ -z "$desc" ]; then
        desc="Source of truth: $path"
      fi
      add_node "sot-${path_id}" "$ntype" "$path" "$desc"
    fi
  fi
done < "$AI_MD"

# ============================================================
# Pass 3: Hook nodes from AI.md hook table
# ============================================================
echo "Pass 3: Extracting hook nodes from AI.md hook table..."
in_hook_table=false
while IFS= read -r line; do
  if echo "$line" | grep -qE '^\| Hook \|'; then
    in_hook_table=true
    continue
  fi
  if [ "$in_hook_table" = true ] && ! echo "$line" | grep -qE '^\|'; then
    break
  fi
  if [ "$in_hook_table" = true ] && echo "$line" | grep -qE '^\| `'; then
    hook_name=$(echo "$line" | sed -E 's/^\| `([^`]+)`.*/\1/')
    event=$(echo "$line" | sed -E 's/^\| `[^`]+` *\| *([^|]+).*/\1/' | sed 's/ *$//')
    blocking="enforcement"
    if echo "$line" | grep -q 'advisory'; then
      blocking="advisory"
    fi

    hook_id=$(echo "$hook_name" | sed 's|\.sh$||' | sed 's|[/.]|-|g')
    add_node "hook-${hook_id}" "hook" ".claude/hooks/${hook_name}" "Hook: ${hook_name} (${event})"

    if echo "$line" | grep -qi 'phase'; then
      add_edge "hook-${hook_id}" "hook-phase-helper" "depends-on" "${hook_name} sources _phase-helper.sh"
    fi
  fi
done < "$AI_MD"

# Add core helper nodes
add_node "hook-phase-helper" "hook" ".claude/hooks/_phase-helper.sh" "Phase-aware flow management helper"
add_node "hook-analytics-helper" "hook" ".claude/hooks/_analytics-helper.sh" "Analytics and observability helper"
add_node "hook-mode-guard-helper" "hook" ".claude/hooks/_mode-guard-helper.sh" "Mode-guard policy helper"
add_node "hook-permission-allowlist" "hook" ".claude/hooks/_permission-allowlist.sh" "Permission allowlist for tools and commands"
add_node "hook-cleanup-helper" "hook" ".claude/hooks/_cleanup-helper.sh" "Session cleanup helper"
add_node "hook-headless-plan-approve" "hook" ".claude/hooks/_headless-plan-approve.sh" "Headless plan approval state writer"

# ============================================================
# Pass 4: Prompt nodes
# ============================================================
echo "Pass 4: Extracting prompt nodes..."
for prompt_file in "$REPO_ROOT"/docs/ai/prompts/prompt-*.md; do
  if [ ! -f "$prompt_file" ]; then continue; fi
  fname=$(basename "$prompt_file")
  prompt_id=$(echo "$fname" | sed 's|\.md$||' | sed 's|[/.]|-|g')
  desc=$(head -5 "$prompt_file" | grep -E '^# ' | head -1 | sed 's/^# //')
  if [ -z "$desc" ]; then desc="Prompt: $fname"; fi
  rel_path="docs/ai/prompts/$fname"
  add_node "${prompt_id}" "prompt" "$rel_path" "$desc"
done

# ============================================================
# Pass 5: Agent nodes
# ============================================================
echo "Pass 5: Extracting agent nodes..."
for agent_file in "$REPO_ROOT"/.claude/agents/*.md; do
  if [ ! -f "$agent_file" ]; then continue; fi
  fname=$(basename "$agent_file")
  case "$fname" in _*) continue ;; esac
  agent_id=$(echo "$fname" | sed 's|\.md$||' | sed 's|[/.]|-|g')
  desc=$(head -5 "$agent_file" | grep -E '^# ' | head -1 | sed 's/^# //')
  if [ -z "$desc" ]; then desc="Agent: $fname"; fi
  add_node "agent-${agent_id}" "file" ".claude/agents/$fname" "$desc"
done

# ============================================================
# Pass 6: Governance edges
# ============================================================
echo "Pass 6: Adding governance edges..."

add_edge "decision-0002" "hook-pre-commit-gates" "governs" "A1 gate enforces decision compliance at commit"
add_edge "decision-0004" "hook-write-guard" "governs" "Mechanical enforcement via write-guard hook"
add_edge "decision-0004" "hook-bash-guard" "governs" "Mechanical enforcement via bash-guard hook"
add_edge "decision-0004" "hook-pre-commit-gates" "governs" "Mechanical enforcement via pre-commit hook"
add_edge "decision-0004" "hook-agent-git-guard" "governs" "Subagent git operation blocking"
add_edge "decision-0004" "hook-state-writer" "governs" "State writer implements sentinel protocol"
add_edge "decision-0009" "hook-analytics-helper" "implements" "Analytics helper implements telemetry layer"
add_edge "decision-0012" "hook-mode-guard-helper" "implements" "Mode guard helper implements file edit restrictions"
add_edge "decision-0012" "hook-write-guard" "governs" "Write guard enforces mode-based restrictions"
add_edge "decision-0014" "hook-phase-helper" "implements" "Phase helper implements phase-aware flow model"
add_edge "decision-0017" "hook-permission-allowlist" "governs" "Automation layer governs permission allowlist"
add_edge "decision-0025" "agent-pragmatist" "governs" "Pragmatist agent governed by Decision 0025"
add_edge "decision-0027" "hook-pretooluse-permission" "implements" "Permission hook implements agent tool governance"
add_edge "decision-0030" "hook-session-close-check" "governs" "Worktree isolation governs session close"
add_edge "decision-0033" "hook-session-close-check" "governs" "Worktree default governs session close"

add_edge "hook-write-guard" "hook-phase-helper" "depends-on" "Write guard sources phase helper"
add_edge "hook-write-guard" "hook-mode-guard-helper" "depends-on" "Write guard sources mode guard helper"
add_edge "hook-write-guard" "hook-analytics-helper" "depends-on" "Write guard sources analytics helper"
add_edge "hook-bash-guard" "hook-phase-helper" "depends-on" "Bash guard sources phase helper"
add_edge "hook-bash-guard" "hook-analytics-helper" "depends-on" "Bash guard sources analytics helper"
add_edge "hook-bash-guard" "hook-mode-guard-helper" "depends-on" "Bash guard sources mode guard helper"
add_edge "hook-pre-commit-gates" "hook-phase-helper" "depends-on" "Pre-commit sources phase helper"
add_edge "hook-pre-commit-gates" "hook-analytics-helper" "depends-on" "Pre-commit sources analytics helper"
add_edge "hook-session-close-check" "hook-phase-helper" "depends-on" "Session close sources phase helper"
add_edge "hook-session-close-check" "hook-analytics-helper" "depends-on" "Session close sources analytics helper"
add_edge "hook-session-close-check" "hook-cleanup-helper" "depends-on" "Session close sources cleanup helper"
add_edge "hook-pretooluse-permission" "hook-permission-allowlist" "depends-on" "Permission hook sources allowlist"
add_edge "hook-pretooluse-permission" "hook-analytics-helper" "depends-on" "Permission hook sources analytics helper"
add_edge "hook-state-writer" "hook-analytics-helper" "depends-on" "State writer sources analytics helper"

add_edge "prompt-b-product-build" "sot-workflow-summary" "consumes" "Prompt B references workflow summary"
add_edge "prompt-b-product-build" "sot-quality-gates-summary" "consumes" "Prompt B references quality gates summary"
add_edge "prompt-a-repo-os" "sot-decisions" "consumes" "Prompt A reads decisions directory"
add_edge "prompt-0-spec-builder" "sot-compiled-spec" "produces" "Prompt 0 produces compiled spec"
add_edge "prompt-a-repo-os" "sot-ai-md" "consumes" "Prompt A reads AI.md"
add_edge "prompt-b-product-build" "sot-ai-md" "consumes" "Prompt B reads AI.md"

# ============================================================
# Pass 7: Convention nodes
# ============================================================
echo "Pass 7: Adding convention nodes..."
add_node "convention-kebab-case-files" "convention" "" "File naming uses kebab-case throughout governance layer"
add_node "convention-shell-io-state-writes" "convention" "" "State writes use shell I/O (Bash redirection) to bypass write-guard"
add_node "convention-decision-prefix-t" "convention" "" "Template decisions use t-NNNN prefix; child decisions use 0NNN+"
add_node "convention-fail-silent-analytics" "convention" "" "Analytics emissions are fail-silent — never block enforcement"
add_node "convention-source-before-use" "convention" "" "Helper scripts must be sourced (not executed) by consuming hooks"

add_edge "convention-kebab-case-files" "decision-0003" "constrains" "Agent structure standard mandates consistent naming"
add_edge "convention-shell-io-state-writes" "hook-phase-helper" "constrains" "Phase helper uses shell I/O for state writes"
add_edge "convention-fail-silent-analytics" "hook-analytics-helper" "constrains" "Analytics helper uses || true for all writes"
add_edge "convention-source-before-use" "hook-mode-guard-helper" "constrains" "Mode guard helper guards against direct execution"

# ============================================================
# Write output
# ============================================================
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo ""
echo "Results: ${NODE_COUNT} nodes, ${EDGE_COUNT} edges"

if [ "$DRY_RUN" = true ]; then
  echo "[dry-run] Would write to $GRAPH_FILE"
  exit 0
fi

acquire_lock

cat > "$GRAPH_FILE" << GRAPH_EOF
# Knowledge Graph — Repo OS
# Decision 0034 — Knowledge Graph Data Layer
# Generated by kg-seed.sh on ${TIMESTAMP}

schema_version: 1
last_updated: "${TIMESTAMP}"

nodes:
${NODE_LINES}
edges:
${EDGE_LINES}
GRAPH_EOF

release_lock

echo "Graph written to $GRAPH_FILE"

echo ""
echo "Cross-graph integrity check..."
_integrity_check_cross_graph "$OTHER_GRAPH" "$GRAPH_FILE"

echo "Done."
