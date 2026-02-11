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
