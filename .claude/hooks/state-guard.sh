#!/usr/bin/env bash
# State guard — blocks model from writing to .claude/.state/.
# Wired to PreToolUse on Edit, Write, and Bash via .claude/settings.json.
# Only state-writer.sh (SubagentStop hook) may write state files via shell I/O.
# Override: REPO_OS_SKIP_STATE_GUARD=1 (skip entirely)
#           REPO_OS_RECOVER=1 (allow writes for recovery/debugging)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_analytics-helper.sh"
START_MS=$(now_ms)

# --- Operator overrides (checked before stdin read for fast exit) ---
if [ "${REPO_OS_SKIP_STATE_GUARD:-0}" = "1" ]; then
  log_override "state-guard" "REPO_OS_SKIP_STATE_GUARD"
  log_hook_event "state-guard" "PreToolUse" "" "allow" "$START_MS" "skip_override"
  exit 0
fi

if [ "${REPO_OS_RECOVER:-0}" = "1" ]; then
  log_override "state-guard" "REPO_OS_RECOVER"
  log_hook_event "state-guard" "PreToolUse" "" "allow" "$START_MS" "recovery_bypass"
  exit 0
fi

# --- Read tool call input ---
INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# --- Check if call targets .claude/.state/ ---
TARGETS_STATE=false

if [ -n "$FILE_PATH" ] && [[ "$FILE_PATH" == *".claude/.state/"* ]]; then
  TARGETS_STATE=true
fi

if [ -n "$COMMAND" ]; then
  # Extract write targets from redirection and tee patterns (same as mode-guard.sh)
  REDIR_TARGETS=$(echo "$COMMAND" | grep -oE '[>]{1,2}\s*[^ |;&]+' | sed 's/[>]*//' | sed 's/^[[:space:]]*//' || true)
  TEE_TARGETS=$(echo "$COMMAND" | grep -oE 'tee\s+(-a\s+)?[^ |;&]+' | sed 's/tee\s*//' | sed 's/-a\s*//' || true)
  for WT in $REDIR_TARGETS $TEE_TARGETS; do
    [ -z "$WT" ] && continue
    [[ "$WT" == /dev/* ]] && continue
    if [[ "$WT" == *".claude/.state/"* ]]; then
      TARGETS_STATE=true
      break
    fi
  done
fi

if [ "$TARGETS_STATE" = false ]; then
  exit 0
fi

# --- Block the write ---
log_hook_event "state-guard" "PreToolUse" "" "block" "$START_MS" "state_path_protected"
echo "BLOCKED: .claude/.state/ is write-protected — state files are managed by governance hooks only (override: REPO_OS_RECOVER=1)" >&2
exit 2