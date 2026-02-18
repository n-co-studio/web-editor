#!/usr/bin/env bash
# HVST failure tracker (PostToolUse + PostToolUseFailure on Bash)
# Tracks consecutive Bash failures. After 2+, reminds agent to check known-issues.md.
# Resets counter on success. Counter stored in .claude/.hvst-fail-count.
#
# PostToolUse fires on success → reset counter.
# PostToolUseFailure fires on failure → increment counter.
# Both receive JSON on stdin with hook_event_name.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
COUNTER_FILE="$REPO_ROOT/.claude/.hvst-fail-count"

# Read JSON payload from stdin
INPUT=$(cat)
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null || echo "")

if [ "$EVENT" = "PostToolUseFailure" ]; then
  # Bash command failed — increment counter
  CURRENT=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
  NEW_COUNT=$((CURRENT + 1))
  echo "$NEW_COUNT" > "$COUNTER_FILE"

  if [ "$NEW_COUNT" -ge 2 ]; then
    echo ""
    echo "HVST: $NEW_COUNT consecutive failures detected."
    echo "Check docs/ai/logs/known-issues.md for matching symptoms before continuing."
  fi
elif [ "$EVENT" = "PostToolUse" ]; then
  # Bash command succeeded — reset counter
  if [ -f "$COUNTER_FILE" ]; then
    echo "0" > "$COUNTER_FILE"
  fi
fi
