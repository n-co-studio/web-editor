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

# --- Bootstrap ---
# If session log is missing, recover from git (clean template) or skip.
if [ ! -f "$SESSION_LOG" ]; then
  git show HEAD:"docs/ai/logs/session-log.md" > "$SESSION_LOG" 2>/dev/null || exit 0
fi

# --- Portable SHA-256 ---
file_hash() {
  if command -v shasum &>/dev/null; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum &>/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    openssl sha256 "$1" | awk '{print $NF}'
  fi
}

# --- Session log modification check (content hash) ---
# Compares current file hash against baseline stored at last session close.
# Works for both tracked and untracked (gitignored) files.
HASH_FILE="$REPO_ROOT/.claude/.session-log-hash"
CURRENT_HASH=$(file_hash "$SESSION_LOG")

SESSION_LOG_MODIFIED=false
if [ -f "$HASH_FILE" ]; then
  STORED_HASH=$(cat "$HASH_FILE")
  if [ "$CURRENT_HASH" != "$STORED_HASH" ]; then
    SESSION_LOG_MODIFIED=true
  fi
else
  # First session — no baseline exists. Lenient: allow close.
  SESSION_LOG_MODIFIED=true
fi

if [ "$SESSION_LOG_MODIFIED" = false ]; then
  echo "BLOCKED: Session log (docs/ai/logs/session-log.md) has not been updated." >&2
  echo "  Update the session log before closing the session." >&2
  echo "  Operator override: SKIP_SESSION_LOG=1" >&2
  exit 2
fi

# --- PR reminder (advisory) ---
# Remind the agent to create a PR if on a mergeable branch with no open PR.
# Non-blocking: prints a reminder, does not exit 2.
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

case "$CURRENT_BRANCH" in
  feature/*|fix/*|hotfix/*|release/*)
    PR_EXISTS=false
    if command -v gh &>/dev/null; then
      PR_COUNT=$(gh pr list --head "$CURRENT_BRANCH" --state open --json number --jq 'length' 2>/dev/null || echo "0")
      if [ "$PR_COUNT" -gt 0 ]; then
        PR_EXISTS=true
      fi
    fi

    if [ "$PR_EXISTS" = false ]; then
      echo ""
      echo "Reminder: No open PR found for branch '$CURRENT_BRANCH'."
      echo "  Ask the operator whether to create a PR to merge to main."
      echo "  Do not skip or defer without explicit operator direction."
    fi
    ;;
esac

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

# --- Update baseline hash for next session ---
echo "$CURRENT_HASH" > "$HASH_FILE"
