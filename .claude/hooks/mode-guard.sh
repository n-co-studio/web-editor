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
  # Check write targets via shared helper — defer to state-guard if targeting .state/
  DEFER_TARGETS=$(extract_write_targets "$COMMAND")
  while IFS= read -r WT; do
    [ -z "$WT" ] && continue
    if [[ "$WT" == *".claude/.state/"* ]]; then
      exit 0
    fi
  done <<< "$DEFER_TARGETS"
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

# --- Path helpers (normalize_path, resolve_path sourced from _analytics-helper.sh) ---
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
    repo-os-explainer.html) return 0 ;;
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
        .claude/local/session-log.md) return 0 ;;
        .claude/local/known-issues.md) return 0 ;;
        .claude/local/task-groups/*) return 0 ;;
        docs/ai/prompts/*) return 0 ;;
        docs/ai/decisions/*) return 0 ;;
        docs/ai/logs/*) return 0 ;;
        docs/ai/workflow.md) return 0 ;;
        docs/ai/quality-gates.md) return 0 ;;
        docs/ai/task-groups/_contract-template.yaml) return 0 ;;
        docs/spec/_templates/*) return 0 ;;
        AI.md) return 0 ;;
        CLAUDE.md) return 0 ;;
        repo-os-explainer.html) return 0 ;;
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

# --- Fast-exit for non-template modes ---
# In child/autonomous modes, product code always passes and governance path
# blocking is deferred to review-time. Template mode retains full edit-time
# enforcement. Immune paths are still checked in all modes (self-protection).
if [ "$MODE" != "template" ]; then
  # Immune path check on Edit/Write file_path
  if [ -n "$FILE_PATH" ]; then
    ABS_PATH_FE=$(resolve_path "$FILE_PATH")
    if is_in_repo "$ABS_PATH_FE" "$REPO_ROOT"; then
      REL_PATH_FE=$(make_relative "$FILE_PATH")
      if is_immune "$REL_PATH_FE"; then
        log_hook_event "mode-guard" "PreToolUse" "" "block" "$START_MS" "file_immune_path" "" "$REL_PATH_FE"
        echo "BLOCKED: $REL_PATH_FE is an immune path — cannot be modified in any mode (no override)" >&2
        exit 2
      fi
    fi
  fi
  # Immune path check on Bash write targets (redirect/tee)
  if [ -n "$COMMAND" ] && [ -z "$FILE_PATH" ]; then
    FE_TARGETS=$(extract_write_targets "$COMMAND")
    while IFS= read -r FE_WT; do
      [ -z "$FE_WT" ] && continue
      FE_WT_ABS=$(resolve_path "$FE_WT")
      if is_in_repo "$FE_WT_ABS" "$REPO_ROOT"; then
        FE_WT_REL=$(make_relative "$FE_WT")
        if is_immune "$FE_WT_REL"; then
          log_hook_event "mode-guard" "PreToolUse" "" "block" "$START_MS" "bash_immune_path" "" "$FE_WT_REL"
          echo "BLOCKED: $FE_WT_REL is an immune path — cannot be modified in any mode (no override)" >&2
          exit 2
        fi
      fi
    done <<< "$FE_TARGETS"
  fi
  log_hook_event "mode-guard" "PreToolUse" "" "allow" "$START_MS" "fast_exit_${MODE}"
  exit 0
fi

# --- Check a single path against mode restrictions ---
check_path() {
  local rel="$1"
  local context="$2"  # "file" or "bash"

  # Immune paths — block unconditionally, no override
  if is_immune "$rel"; then
    log_hook_event "mode-guard" "PreToolUse" "" "block" "$START_MS" "${context}_immune_path" "" "$rel"
    echo "BLOCKED: $rel is an immune path — cannot be modified in any mode (no override)" >&2
    exit 2
  fi

  # REPO_OS_UNLOCK_PATH — single-file governance unlock
  if [ -n "${REPO_OS_UNLOCK_PATH:-}" ]; then
    UNLOCK_REL=$(make_relative "$REPO_OS_UNLOCK_PATH")
    if [ "$rel" = "$UNLOCK_REL" ]; then
      log_override "mode-guard" "REPO_OS_UNLOCK_PATH"
      log_hook_event "mode-guard" "PreToolUse" "" "allow" "$START_MS" "unlock_path" "" "$rel"
      exit 0
    fi
  fi

  # Governance vs product
  if is_governance "$rel"; then
    if ! is_carved_out "$MODE" "$rel"; then
      log_hook_event "mode-guard" "PreToolUse" "" "block" "$START_MS" "${context}_governance_${MODE}" "" "$rel"
      echo "BLOCKED: $rel is a governance path — not editable in '$MODE' mode (override: REPO_OS_UNLOCK_PATH=$rel or REPO_OS_SKIP_MODE_GUARD=1)" >&2
      exit 2
    fi
  else
    # Product code
    if [ "$MODE" = "template" ]; then
      log_hook_event "mode-guard" "PreToolUse" "" "block" "$START_MS" "${context}_product_in_template" "" "$rel"
      echo "BLOCKED: $rel is a product path — not editable in 'template' mode (override: REPO_OS_SKIP_MODE_GUARD=1)" >&2
      exit 2
    fi
  fi
}

# --- Resolve path for allow event (best-effort) ---
ALLOW_PATH=""

# --- File path check (Edit/Write) ---
if [ -n "$FILE_PATH" ]; then
  ABS_PATH=$(resolve_path "$FILE_PATH")
  if ! is_in_repo "$ABS_PATH" "$REPO_ROOT"; then
    log_hook_event "mode-guard" "PreToolUse" "" "allow" "$START_MS" "out_of_repo" "" "$FILE_PATH"
    exit 0
  fi
  REL_PATH=$(make_relative "$FILE_PATH")
  ALLOW_PATH="$REL_PATH"
  check_path "$REL_PATH" "file"
fi

# --- Bash command scanning for write patterns ---
if [ -n "$COMMAND" ] && [ -z "$FILE_PATH" ]; then
  # Extract write targets via shared helper
  TARGETS=$(extract_write_targets "$COMMAND")
  while IFS= read -r WT; do
    [ -z "$WT" ] && continue
    WT_ABS=$(resolve_path "$WT")
    if ! is_in_repo "$WT_ABS" "$REPO_ROOT"; then
      continue
    fi
    WT_REL=$(make_relative "$WT")
    [ -z "$ALLOW_PATH" ] && ALLOW_PATH="$WT_REL"
    check_path "$WT_REL" "bash"
  done <<< "$TARGETS"
fi

# --- Allow ---
log_hook_event "mode-guard" "PreToolUse" "" "allow" "$START_MS" "pass_${MODE}" "" "$ALLOW_PATH"
exit 0
