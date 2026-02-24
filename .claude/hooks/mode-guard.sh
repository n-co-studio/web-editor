#!/usr/bin/env bash
# Mode guard — restricts file edits based on active operating mode.
# Wired to PreToolUse on Edit, Write, and Bash via .claude/settings.json.
# Three modes: template (governance only), child (product + limited governance),
#              autonomous (product + minimal governance).
# Override: REPO_OS_SKIP_MODE_GUARD=1 (skip entirely)
#           REPO_OS_MODE=<mode> (force mode without reading file)
#           REPO_OS_UNLOCK_PATH=<path> (single-file governance unlock)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_analytics-helper.sh"
START_MS=$(now_ms)

# --- Operator override: skip entirely ---
if [ "${REPO_OS_SKIP_MODE_GUARD:-0}" = "1" ]; then
  log_override "mode-guard" "REPO_OS_SKIP_MODE_GUARD"
  log_hook_event "mode-guard" "PreToolUse" "" "allow" "$START_MS" "skip_override"
  exit 0
fi

# --- Read tool call input ---
INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# If neither file_path nor command, nothing to check
if [ -z "$FILE_PATH" ] && [ -z "$COMMAND" ]; then
  exit 0
fi

REPO_ROOT="$(get_repo_root)"

# --- Early exits for paths handled by other hooks ---
# .state/ paths: defer to state-guard (no double-block)
if [ -n "$FILE_PATH" ] && [[ "$FILE_PATH" == *".claude/.state/"* ]]; then
  exit 0
fi
if [ -n "$COMMAND" ]; then
  # Check write targets only (same pattern as state-guard.sh) — not raw substring
  DEFER_REDIR=$(echo "$COMMAND" | grep -oE '[>]{1,2}\s*[^ |;&]+' | sed 's/[>]*//' | sed 's/^[[:space:]]*//' || true)
  DEFER_TEE=$(echo "$COMMAND" | grep -oE 'tee\s+(-a\s+)?[^ |;&]+' | sed 's/tee\s*//' | sed 's/-a\s*//' || true)
  for WT in $DEFER_REDIR $DEFER_TEE; do
    [ -z "$WT" ] && continue
    [[ "$WT" == /dev/* ]] && continue
    if [[ "$WT" == *".claude/.state/"* ]]; then
      exit 0
    fi
  done
fi

# .claude/analytics/ paths: analytics passthrough (not governance)
if [ -n "$FILE_PATH" ] && [[ "$FILE_PATH" == *".claude/analytics/"* ]]; then
  exit 0
fi
if [ -n "$COMMAND" ] && [[ "$COMMAND" == *".claude/analytics/"* ]]; then
  exit 0
fi

# --- Resolve operating mode ---
# Priority: REPO_OS_MODE env var > .claude/repo-mode file > default "child"
MODE="${REPO_OS_MODE:-}"
if [ -n "$MODE" ]; then
  log_override "mode-guard" "REPO_OS_MODE"
fi
if [ -z "$MODE" ]; then
  MODE_FILE="$REPO_ROOT/.claude/repo-mode"
  if [ -f "$MODE_FILE" ]; then
    MODE=$(head -1 "$MODE_FILE" | tr -d '[:space:]')
  fi
fi
MODE="${MODE:-child}"

# Validate mode
case "$MODE" in
  template|child|autonomous) ;;
  *)
    echo "WARNING: Unknown mode '$MODE' in .claude/repo-mode — defaulting to child" >&2
    MODE="child"
    ;;
esac

# --- Path normalization (portable, macOS-safe) ---
normalize_path() {
  local raw="$1"
  if command -v python3 &>/dev/null; then
    python3 -c "import os.path,sys; print(os.path.normpath(sys.argv[1]))" "$raw" 2>/dev/null || echo "$raw"
  else
    echo "$raw"
  fi
}

# Make path relative to repo root for prefix matching
make_relative() {
  local p="$1"
  p=$(normalize_path "$p")
  # Strip repo root prefix if present
  p="${p#$REPO_ROOT/}"
  # Strip leading ./ if present
  p="${p#./}"
  echo "$p"
}

# --- Immune paths (never modifiable, no override) ---
is_immune() {
  local p="$1"
  case "$p" in
    .claude/hooks/mode-guard.sh) return 0 ;;
    .claude/repo-mode) return 0 ;;
    *) return 1 ;;
  esac
}

# --- Governance prefix check ---
is_governance() {
  local p="$1"
  case "$p" in
    .claude/*) return 0 ;;
    docs/ai/*) return 0 ;;
    docs/spec/_templates/*) return 0 ;;
    .github/*) return 0 ;;
    AI.md) return 0 ;;
    CLAUDE.md) return 0 ;;
    *) return 1 ;;
  esac
}

# --- Per-mode carve-outs (governance paths allowed in each mode) ---
is_carved_out() {
  local mode="$1"
  local p="$2"

  case "$mode" in
    template)
      case "$p" in
        .claude/agents/*) return 0 ;;
        .claude/hooks/*) return 0 ;;
        .claude/settings.json) return 0 ;;
        .claude/settings.local.json) return 0 ;;
        docs/ai/prompts/*) return 0 ;;
        docs/ai/decisions/*) return 0 ;;
        docs/ai/logs/*) return 0 ;;
        docs/ai/workflow.md) return 0 ;;
        docs/ai/quality-gates.md) return 0 ;;
        docs/ai/task-groups/_contract-template.yaml) return 0 ;;
        docs/spec/_templates/*) return 0 ;;
        AI.md) return 0 ;;
        CLAUDE.md) return 0 ;;
        .github/*) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    child)
      case "$p" in
        .claude/settings.local.json) return 0 ;;
        docs/ai/governance/*) return 0 ;;
        docs/ai/logs/*) return 0 ;;
        docs/ai/task-groups/_*) return 1 ;;
        docs/ai/task-groups/*.yaml) return 0 ;;
        docs/ai/decisions/0[1-9][0-9][0-9]-*.md) return 0 ;;
        docs/spec/compiled/*) return 0 ;;
        docs/spec/prototypes/*) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    autonomous)
      case "$p" in
        docs/ai/logs/*) return 0 ;;
        docs/ai/task-groups/_*) return 1 ;;
        docs/ai/task-groups/*.yaml) return 0 ;;
        *) return 1 ;;
      esac
      ;;
  esac
  return 1
}

# --- Check a single path against mode restrictions ---
check_path() {
  local rel="$1"
  local context="$2"  # "file" or "bash"

  # Immune paths — block unconditionally, no override
  if is_immune "$rel"; then
    log_hook_event "mode-guard" "PreToolUse" "" "block" "$START_MS" "${context}_immune_path"
    echo "BLOCKED: $rel is an immune path — cannot be modified in any mode (no override)" >&2
    exit 2
  fi

  # REPO_OS_UNLOCK_PATH — single-file governance unlock
  if [ -n "${REPO_OS_UNLOCK_PATH:-}" ]; then
    UNLOCK_REL=$(make_relative "$REPO_OS_UNLOCK_PATH")
    if [ "$rel" = "$UNLOCK_REL" ]; then
      log_override "mode-guard" "REPO_OS_UNLOCK_PATH"
      log_hook_event "mode-guard" "PreToolUse" "" "allow" "$START_MS" "unlock_path"
      exit 0
    fi
  fi

  # Governance vs product
  if is_governance "$rel"; then
    if ! is_carved_out "$MODE" "$rel"; then
      log_hook_event "mode-guard" "PreToolUse" "" "block" "$START_MS" "${context}_governance_${MODE}"
      echo "BLOCKED: $rel is a governance path — not editable in '$MODE' mode (override: REPO_OS_UNLOCK_PATH=$rel or REPO_OS_SKIP_MODE_GUARD=1)" >&2
      exit 2
    fi
  else
    # Product code
    if [ "$MODE" = "template" ]; then
      log_hook_event "mode-guard" "PreToolUse" "" "block" "$START_MS" "${context}_product_in_template"
      echo "BLOCKED: $rel is a product path — not editable in 'template' mode (override: REPO_OS_SKIP_MODE_GUARD=1)" >&2
      exit 2
    fi
  fi
}

# --- File path check (Edit/Write) ---
if [ -n "$FILE_PATH" ]; then
  REL_PATH=$(make_relative "$FILE_PATH")
  check_path "$REL_PATH" "file"
fi

# --- Bash command scanning for write patterns ---
if [ -n "$COMMAND" ] && [ -z "$FILE_PATH" ]; then
  # Extract potential write targets from redirection and tee patterns
  WRITE_TARGETS=""
  REDIR_TARGETS=$(echo "$COMMAND" | grep -oE '[>]{1,2}\s*[^ |;&]+' | sed 's/[>]*//' | sed 's/^[[:space:]]*//' || true)
  TEE_TARGETS=$(echo "$COMMAND" | grep -oE 'tee\s+(-a\s+)?[^ |;&]+' | sed 's/tee\s*//' | sed 's/-a\s*//' || true)
  WRITE_TARGETS="$REDIR_TARGETS $TEE_TARGETS"

  for WT in $WRITE_TARGETS; do
    [ -z "$WT" ] && continue
    # Skip /dev/null and other device files (not real write targets)
    [[ "$WT" == /dev/* ]] && continue
    WT_REL=$(make_relative "$WT")
    check_path "$WT_REL" "bash"
  done
fi

# --- Allow ---
log_hook_event "mode-guard" "PreToolUse" "" "allow" "$START_MS" "pass_${MODE}"
exit 0
