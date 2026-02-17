#!/usr/bin/env bash
# Session close check (advisory)
# Runs via Stop hook in .claude/settings.json.
# Checks whether the session log was updated.
# Advisory only — prints a reminder, does not block.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
SESSION_LOG="$REPO_ROOT/docs/ai/logs/session-log.md"

if [ ! -f "$SESSION_LOG" ]; then
  exit 0
fi

# Check if session log has uncommitted changes (modified or staged)
if git diff --name-only "$SESSION_LOG" 2>/dev/null | grep -q .; then
  exit 0
fi
if git diff --cached --name-only "$SESSION_LOG" 2>/dev/null | grep -q .; then
  exit 0
fi

# Session log not modified — print reminder
echo "Reminder: Session log (docs/ai/logs/session-log.md) has not been updated this session."
echo "Repo OS requires a session log entry at session close."

# --- HVST known-issues check ---
# If HVST failures occurred this session, check if known-issues.md was updated.
COUNTER_FILE="$REPO_ROOT/.claude/.hvst-fail-count"
KNOWN_ISSUES="$REPO_ROOT/docs/ai/logs/known-issues.md"

if [ -f "$COUNTER_FILE" ]; then
  FAIL_COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
  if [ "$FAIL_COUNT" -ge 2 ]; then
    # Check if known-issues.md has uncommitted changes
    KI_MODIFIED=false
    if git diff --name-only "$KNOWN_ISSUES" 2>/dev/null | grep -q .; then
      KI_MODIFIED=true
    fi
    if git diff --cached --name-only "$KNOWN_ISSUES" 2>/dev/null | grep -q .; then
      KI_MODIFIED=true
    fi

    if [ "$KI_MODIFIED" = false ]; then
      echo ""
      echo "Reminder: $FAIL_COUNT HVST failures occurred but known-issues.md was not updated."
      echo "Record resolved issues per HVST Record step (docs/ai/workflow.md)."
    fi
  fi
  # Clean up counter file at session end
  rm -f "$COUNTER_FILE"
fi
