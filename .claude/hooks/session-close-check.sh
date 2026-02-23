#!/usr/bin/env bash
# Session close check (blocking)
# Runs via Stop hook in .claude/settings.json.
# Blocks session close (exit 2) if session log was not updated.
# Zero-change sessions (no commits, no working tree changes) downgrade to advisory.
# Override: SKIP_SESSION_LOG=1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_analytics-helper.sh"
START_MS=$(now_ms)

INPUT=$(cat)

# --- Paths and state files ---
REPO_ROOT="$(get_repo_root)"
SESSION_LOG="$REPO_ROOT/docs/ai/logs/session-log.md"
HASH_FILE="$REPO_ROOT/.claude/.session-log-hash"
BASELINE_SHA_FILE="$REPO_ROOT/.claude/.session-baseline-sha"
COUNTER_FILE="$REPO_ROOT/.claude/.hvst-fail-count"

# --- Portable SHA-256 ---
file_hash() {
  [ -f "$1" ] || return 1
  if command -v shasum &>/dev/null; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum &>/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    openssl sha256 "$1" | awk '{print $NF}'
  fi
}

# --- Update baseline for next session ---
# Re-computes hash fresh (never uses cached value). Stores commit SHA for
# session-scoped change detection. Handles missing session log gracefully.
update_baseline() {
  if [ -f "$SESSION_LOG" ]; then
    file_hash "$SESSION_LOG" > "$HASH_FILE" 2>/dev/null || true
  fi
  git rev-parse HEAD > "$BASELINE_SHA_FILE" 2>/dev/null || true
}

# --- Session cleanup (HVST counter + session ID + old analytics) ---
cleanup_session() {
  rm -f "$COUNTER_FILE"
  rm -f "$REPO_ROOT/.claude/.session-id"
  cleanup_old_analytics "$REPO_ROOT"
}

# --- Infinite loop guard ---
# When a Stop hook blocks (exit 2), Claude continues working.
# On the next stop attempt, stop_hook_active=true. Allow it to prevent loops.
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  update_baseline
  cleanup_session
  exit 0
fi

# --- Operator override ---
if [ "${SKIP_SESSION_LOG:-0}" = "1" ]; then
  update_baseline
  cleanup_session
  exit 0
fi

# --- Bootstrap ---
# If session log is missing, recover from git (clean template) or skip.
if [ ! -f "$SESSION_LOG" ]; then
  git show HEAD:"docs/ai/logs/session-log.md" > "$SESSION_LOG" 2>/dev/null || exit 0
fi

# --- Session log modification check (content hash) ---
# Compares current file hash against baseline stored at last session close.
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

# --- Session weight check ---
# If no actual changes were made (no commits since baseline, no working tree
# changes), this is a zero-change session. Downgrade to advisory instead of
# blocking. Uses stored baseline commit SHA for reliable session-scoped
# detection (no hardcoded time window).
UNCOMMITTED=$(git diff --name-only 2>/dev/null || echo "")
STAGED=$(git diff --cached --name-only 2>/dev/null || echo "")

RECENT_COMMITS=""
if [ -f "$BASELINE_SHA_FILE" ]; then
  BASELINE_SHA=$(cat "$BASELINE_SHA_FILE")
  # Verify the baseline SHA still exists in the repo (handles force-push/reset)
  if git cat-file -e "$BASELINE_SHA" 2>/dev/null; then
    RECENT_COMMITS=$(git log --oneline "$BASELINE_SHA..HEAD" 2>/dev/null || echo "")
  else
    # Baseline SHA gone (rebased/reset) — treat as non-zero session
    RECENT_COMMITS="baseline-missing"
  fi
else
  # No baseline file — first session or file was cleaned up. Fall back to
  # time-based detection as a one-time bridge (next close will write the file).
  RECENT_COMMITS=$(git log --oneline --since="4 hours ago" 2>/dev/null || echo "")
fi

if [ -z "$UNCOMMITTED" ] && [ -z "$STAGED" ] && [ -z "$RECENT_COMMITS" ]; then
  # Zero-change session — no blocking
  if [ "$SESSION_LOG_MODIFIED" = false ]; then
    echo "Advisory: No code changes detected (zero-change session). Session log not updated." >&2
  fi
  log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "zero_change"
  cleanup_session
  update_baseline
  exit 0
fi

# --- Blocking check ---
# Session had real changes but session log was not updated.
if [ "$SESSION_LOG_MODIFIED" = false ]; then
  # Do NOT update baseline when blocking — prevents stale hash on retry.
  log_hook_event "session-close-check" "Stop" "" "block" "$START_MS" "log_not_updated"
  echo "BLOCKED: Session log not updated — update docs/ai/logs/session-log.md (override: SKIP_SESSION_LOG=1)" >&2
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
      echo "Reminder: No open PR for '$CURRENT_BRANCH' — ask operator about creating PR to main." >&2
    fi
    ;;
esac

# --- HVST known-issues check (advisory) ---
# If HVST failures occurred this session, check if known-issues.md was updated.
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
      echo "Reminder: $FAIL_COUNT HVST failures but known-issues.md not updated — record per HVST Record step." >&2
    fi
  fi
  cleanup_session
fi

# --- Task group next-brief reminder (advisory) ---
# If a task group contract exists with pending briefs, remind about next brief.
# Non-blocking: prints a reminder, does not exit 2. Override: SKIP_CONTRACT_CHECK=1
if [ "${SKIP_CONTRACT_CHECK:-0}" != "1" ]; then
  CONTRACT_DIR="$REPO_ROOT/docs/ai/task-groups"
  if [ -d "$CONTRACT_DIR" ]; then
    for CONTRACT in "$CONTRACT_DIR"/*.yaml; do
      [ -f "$CONTRACT" ] || continue
      # Skip the template file
      [ "$(basename "$CONTRACT")" = "_contract-template.yaml" ] && continue
      GROUP_NAME=$(basename "$CONTRACT" .yaml)
      # Look for a brief with status: complete that has a next_brief value
      if grep -q "status: complete" "$CONTRACT" 2>/dev/null; then
        NEXT_BRIEF=$(grep -A1 "status: complete" "$CONTRACT" | grep "next_brief:" | grep -v '""' | head -1 | sed 's/.*next_brief: *//' | sed 's/^"//' | sed 's/"$//' || true)
        if [ -n "$NEXT_BRIEF" ]; then
          echo "Reminder: Task group '$GROUP_NAME' has a next brief — start a new Prompt B session with: $NEXT_BRIEF" >&2
        fi
      fi
    done
  fi
fi

# --- Analytics: log successful close and register repo ---
log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "session_complete"
register_repo "$REPO_ROOT"

# --- Update baseline for next session ---
update_baseline
