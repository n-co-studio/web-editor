#!/usr/bin/env bash
# Session close check (blocking)
# Runs via Stop hook in .claude/settings.json.
# Blocks session close (exit 2) if session log was not updated.
# Override: SKIP_SESSION_LOG=1

set -euo pipefail

INPUT=$(cat)

# --- Infinite loop guard ---
# When a Stop hook blocks (exit 2), Claude continues working.
# On the next stop attempt, stop_hook_active=true. Allow it to prevent loops.
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

# --- Operator override ---
if [ "${SKIP_SESSION_LOG:-0}" = "1" ]; then
  exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
SESSION_LOG="$REPO_ROOT/docs/ai/logs/session-log.md"

if [ ! -f "$SESSION_LOG" ]; then
  exit 0
fi

# Check if session log was updated this session:
# 1. Uncommitted changes (modified or staged)
# 2. Committed within the last 4 hours (covers mid-session commits)
# Note: uses variable capture instead of pipe to grep -q to avoid SIGPIPE
# failures with pipefail (grep -q closes pipe early → git gets SIGPIPE → exit 141).
SESSION_LOG_MODIFIED=false
DIFF_OUT=$(git diff --name-only "$SESSION_LOG" 2>/dev/null || true)
if [ -n "$DIFF_OUT" ]; then
  SESSION_LOG_MODIFIED=true
fi
CACHED_OUT=$(git diff --cached --name-only "$SESSION_LOG" 2>/dev/null || true)
if [ -n "$CACHED_OUT" ]; then
  SESSION_LOG_MODIFIED=true
fi
LOG_OUT=$(git log --since="4 hours ago" --name-only --format="" -- "$SESSION_LOG" 2>/dev/null || true)
if [ -n "$LOG_OUT" ]; then
  SESSION_LOG_MODIFIED=true
fi

if [ "$SESSION_LOG_MODIFIED" = false ]; then
  echo "BLOCKED: Session log (docs/ai/logs/session-log.md) has not been updated." >&2
  echo "  Update the session log before closing the session." >&2
  echo "  Operator override: SKIP_SESSION_LOG=1" >&2
  exit 2
fi

# --- HVST known-issues check (advisory) ---
# If HVST failures occurred this session, check if known-issues.md was updated.
COUNTER_FILE="$REPO_ROOT/.claude/.hvst-fail-count"
KNOWN_ISSUES="$REPO_ROOT/docs/ai/logs/known-issues.md"

if [ -f "$COUNTER_FILE" ]; then
  FAIL_COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
  if [ "$FAIL_COUNT" -ge 2 ]; then
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
