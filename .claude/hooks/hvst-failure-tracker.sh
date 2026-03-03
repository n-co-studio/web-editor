#!/usr/bin/env bash
# HVST failure tracker (PostToolUse + PostToolUseFailure on Bash)
# Tracks consecutive Bash failures. After 2+, reminds agent to check known-issues.md.
# Resets counter on success. Counter stored in .claude/.hvst-fail-count.
#
# PostToolUse fires on success → reset counter.
# PostToolUseFailure fires on failure → increment counter.
# Both receive JSON on stdin with hook_event_name.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_analytics-helper.sh"
START_MS=$(now_ms)

REPO_ROOT="$_REPO_OS_ROOT"
COUNTER_FILE="$REPO_ROOT/.claude/.hvst-fail-count"

# Resolve known-issues path based on repo mode (template → .claude/local/, child/autonomous → docs/ai/logs/)
if [ "$(get_mode)" = "template" ]; then
  KNOWN_ISSUES_PATH=".claude/local/known-issues.md"
else
  KNOWN_ISSUES_PATH="docs/ai/logs/known-issues.md"
fi

# Read JSON payload from stdin
INPUT=$(cat)
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null || echo "")

# Fast-exit: PostToolUse with no counter file — nothing to reset
if [ "$EVENT" = "PostToolUse" ] && [ ! -f "$COUNTER_FILE" ]; then
  exit 0
fi

if [ "$EVENT" = "PostToolUseFailure" ]; then
  # Bash command failed — increment counter
  CURRENT=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
  NEW_COUNT=$((CURRENT + 1))
  echo "$NEW_COUNT" > "$COUNTER_FILE"

  if [ "$NEW_COUNT" -ge 2 ]; then
    log_hook_event "hvst-failure-tracker" "PostToolUseFailure" "Bash" "warn" "$START_MS" "failure_${NEW_COUNT}"
    echo "HVST: $NEW_COUNT consecutive failures — check $KNOWN_ISSUES_PATH" >&2
  else
    log_hook_event "hvst-failure-tracker" "PostToolUseFailure" "Bash" "allow" "$START_MS" "failure_${NEW_COUNT}"
  fi
elif [ "$EVENT" = "PostToolUse" ]; then
  # Bash command succeeded — emit only on state transition (counter resets from non-zero)
  # Suppresses already_zero and no_counter events (~80-90% noise reduction)
  if [ -f "$COUNTER_FILE" ]; then
    CURRENT=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
    if [ "$CURRENT" != "0" ]; then
      echo "0" > "$COUNTER_FILE"
      log_hook_event "hvst-failure-tracker" "PostToolUse" "Bash" "allow" "$START_MS" "reset_from_${CURRENT}"
    fi
  fi
fi
