#!/usr/bin/env bash
# Session close check (blocking)
# Runs via Stop hook in .claude/settings.json.
# Blocks session close (exit 2) if session log was not updated.
# Zero-change sessions (no commits, no working tree changes) downgrade to advisory.
# Records closed branch in .claude/local/closed-branches (Decision 0013).
# Override: SKIP_SESSION_LOG=1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_analytics-helper.sh"
START_MS=$(now_ms)

INPUT=$(cat)

# --- Paths and state files ---
REPO_ROOT="$(get_repo_root)"
# In template mode, session log lives locally; in product mode, it's committed.
REPO_MODE_FILE="$REPO_ROOT/.claude/repo-mode"
if [ -f "$REPO_MODE_FILE" ] && grep -q "template" "$REPO_MODE_FILE" 2>/dev/null; then
  SESSION_LOG="$REPO_ROOT/.claude/local/session-log.md"
else
  SESSION_LOG="$REPO_ROOT/docs/ai/logs/session-log.md"
fi
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

# --- Record closed branch (Decision 0013: session isolation) ---
# Appends current branch to closed-branches ledger so future sessions can't
# reuse it. Skips main (protected by branch-guard Gate 1 separately).
# Idempotent: won't add duplicate entries.
record_closed_branch() {
  local branch
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  [ -z "$branch" ] && return
  [ "$branch" = "main" ] && return
  local closed_file="$REPO_ROOT/.claude/local/closed-branches"
  mkdir -p "$(dirname "$closed_file")" 2>/dev/null || true
  if ! grep -qxF "$branch" "$closed_file" 2>/dev/null; then
    echo "$branch" >> "$closed_file"
  fi
}

# --- Session type inference ---
# Reads .session-type if set by operator, otherwise infers from behavioral signals.
infer_session_type() {
  local type_file="$REPO_ROOT/.claude/.session-type"
  if [ -f "$type_file" ]; then
    head -1 "$type_file" 2>/dev/null | tr -d '[:space:]'
    return
  fi
  # Infer from behavioral signals
  local has_commits=false
  local has_branch_guard=false
  local has_qa_verifier=false
  local events_dir
  events_dir="$(get_analytics_dir "$REPO_ROOT")"
  local today
  today="$(date +%Y-%m-%d)"
  local today_file="$events_dir/$today.ndjson"
  local sid
  sid="$(get_session_id "$REPO_ROOT")"
  if [ -f "$today_file" ]; then
    if grep -qE "\"sid\":\"$sid\".*\"hook\":\"branch-guard(-edit)?\"" "$today_file" 2>/dev/null; then
      has_branch_guard=true
    fi
    if grep -q "\"sid\":\"$sid\".*\"hook\":\"state-writer\".*\"qa-verifier\"" "$today_file" 2>/dev/null; then
      has_qa_verifier=true
    fi
  fi
  if [ -n "$RECENT_COMMITS" ]; then
    has_commits=true
  fi
  if [ "$has_qa_verifier" = true ]; then
    echo "qa"
  elif [ "$has_branch_guard" = true ] && [ "$has_commits" = true ]; then
    echo "build"
  elif [ -z "$UNCOMMITTED" ] && [ -z "$STAGED" ] && [ -z "$RECENT_COMMITS" ]; then
    # Check if session had only read activity (no edits at all)
    if [ -f "$today_file" ] && ! grep -q "\"sid\":\"$sid\".*\"hook\":\"mode-guard\"" "$today_file" 2>/dev/null; then
      echo "audit"
    else
      echo "explore"
    fi
  elif [ "$has_commits" = false ]; then
    echo "explore"
  else
    echo "unknown"
  fi
}

# --- Session cleanup (state files + HVST counter + session ID + analytics) ---
# Removes all session-scoped state files to prevent stale state leaking
# across sessions. Preserves .gitkeep.
cleanup_session() {
  rm -f "$COUNTER_FILE"
  rm -f "$REPO_ROOT/.claude/.session-id"
  rm -f "$REPO_ROOT/.claude/.session-type"
  rm -f "$REPO_ROOT/.claude/.deferrals-pending"
  cleanup_old_analytics "$REPO_ROOT"
  # Clean session-scoped governance state files
  local state_dir="$REPO_ROOT/.claude/.state"
  if [ -d "$state_dir" ]; then
    rm -f "$state_dir/plan-approved"
    rm -f "$state_dir/cohesion-reviewed"
    rm -f "$state_dir/qa-verified"
    rm -f "$state_dir/reviewer-signed"
    rm -f "$state_dir/security-signed"
    rm -f "$state_dir/high-risk-detected"
    rm -f "$state_dir/governance-checked"
    rm -f "$state_dir/phase-chain-checked"
    rm -f "$state_dir/overrides.log"
  fi
}

# --- Infinite loop guard ---
# When a Stop hook blocks (exit 2), Claude continues working.
# On the next stop attempt, stop_hook_active=true — allow unconditionally.
# Run cleanup_session (post-close continuation = new session, enforce fresh
# plan approval + governance). Do NOT call update_baseline: if the operator
# continues the conversation, the poisoned baseline would make the next stop
# see matching hashes and block. Keeping the original baseline lets the hash
# check detect any subsequent session-log amendment correctly.
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "second_attempt"
  record_closed_branch
  cleanup_session
  exit 0
fi

# --- Operator override ---
if [ "${SKIP_SESSION_LOG:-0}" = "1" ]; then
  log_override "session-close-check" "SKIP_SESSION_LOG"
  # Print override audit before cleanup (overrides.log is deleted by cleanup_session)
  OVERRIDES_LOG="$REPO_ROOT/.claude/.state/overrides.log"
  if [ -f "$OVERRIDES_LOG" ]; then
    OVERRIDE_COUNT=$(wc -l < "$OVERRIDES_LOG" | tr -d ' ')
    if [ "$OVERRIDE_COUNT" -gt 0 ]; then
      UNIQUE_OVERRIDES=$(awk '{print $3}' "$OVERRIDES_LOG" | sort -u | tr '\n' ', ' | sed 's/,$//')
      echo "Override audit: $OVERRIDE_COUNT override(s) this session — $UNIQUE_OVERRIDES" >&2
      log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "override_audit" "$OVERRIDE_COUNT:$UNIQUE_OVERRIDES"
    fi
  fi
  log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "skip_override"
  record_closed_branch
  update_baseline
  cleanup_session
  exit 0
fi

# --- Bootstrap ---
# If session log is missing, recover from git (product mode) or create empty (template mode) or skip.
if [ ! -f "$SESSION_LOG" ]; then
  if [ -f "$REPO_MODE_FILE" ] && grep -q "template" "$REPO_MODE_FILE" 2>/dev/null; then
    # Template mode: local file doesn't exist in git — create with structural header
    mkdir -p "$(dirname "$SESSION_LOG")"
    printf '# Session Log (Template Development)\n\nRolling cap: last 5 sessions.\n\n---\n' > "$SESSION_LOG"
  elif git show HEAD:"docs/ai/logs/session-log.md" > "$SESSION_LOG" 2>/dev/null; then
    : # Product mode: recovered from git — continue normal flow
  else
    log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "bootstrap_recovery"
    exit 0
  fi
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
  SESSION_TYPE=$(infer_session_type)
  log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "zero_change" "$SESSION_TYPE"
  cleanup_session
  update_baseline
  exit 0
fi

# --- Blocking check ---
# Session had real changes but session log was not updated.
if [ "$SESSION_LOG_MODIFIED" = false ]; then
  # Do NOT update baseline when blocking — prevents stale hash on retry.
  SESSION_TYPE=$(infer_session_type)
  log_hook_event "session-close-check" "Stop" "" "block" "$START_MS" "log_not_updated" "$SESSION_TYPE"
  # Show path relative to repo root for clarity
  SESSION_LOG_REL="${SESSION_LOG#"$REPO_ROOT/"}"
  echo "BLOCKED: Session log not updated — update $SESSION_LOG_REL (override: SKIP_SESSION_LOG=1)" >&2
  exit 2
fi

# --- Uncommitted changes check (blocking) ---
# Session log was updated but changes are not committed.
# Override: SKIP_UNCOMMITTED_CHECK=1
if [ "${SKIP_UNCOMMITTED_CHECK:-0}" != "1" ]; then
  if [ -n "$UNCOMMITTED" ] || [ -n "$STAGED" ]; then
    SESSION_TYPE=$(infer_session_type)
    log_hook_event "session-close-check" "Stop" "" "block" "$START_MS" "uncommitted_changes" "$SESSION_TYPE"
    echo "BLOCKED: Uncommitted changes detected — commit before closing (override: SKIP_UNCOMMITTED_CHECK=1)" >&2
    exit 2
  fi
fi

# --- Override audit (advisory) ---
# Summarize any governance overrides used during this session.
OVERRIDES_LOG="$REPO_ROOT/.claude/.state/overrides.log"
if [ -f "$OVERRIDES_LOG" ]; then
  OVERRIDE_COUNT=$(wc -l < "$OVERRIDES_LOG" | tr -d ' ')
  if [ "$OVERRIDE_COUNT" -gt 0 ]; then
    UNIQUE_OVERRIDES=$(awk '{print $3}' "$OVERRIDES_LOG" | sort -u | tr '\n' ', ' | sed 's/,$//')
    echo "Override audit: $OVERRIDE_COUNT override(s) this session — $UNIQUE_OVERRIDES" >&2
    echo "  Include in Overrides: git trailer if committing." >&2
    log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "override_audit" "$OVERRIDE_COUNT:$UNIQUE_OVERRIDES"
  fi
fi

# --- Log overrides (once each, covers respective checks) ---
if [ "${SKIP_CONTRACT_CHECK:-0}" = "1" ]; then
  log_override "session-close-check" "SKIP_CONTRACT_CHECK"
fi
if [ "${SKIP_UNCOMMITTED_CHECK:-0}" = "1" ]; then
  log_override "session-close-check" "SKIP_UNCOMMITTED_CHECK"
fi
if [ "${SKIP_PR_CHECK:-0}" = "1" ]; then
  log_override "session-close-check" "SKIP_PR_CHECK"
fi

# --- Governance evidence check (advisory) ---
# Verifies that governance evidence was recorded in task group contract.
# Model writes this as part of normal contract update; hook only verifies.
# In template mode, contracts live locally; in product mode, they're committed.
if [ "${SKIP_CONTRACT_CHECK:-0}" != "1" ]; then
  if [ -f "$REPO_MODE_FILE" ] && grep -q "template" "$REPO_MODE_FILE" 2>/dev/null; then
    CONTRACT_DIR="$REPO_ROOT/.claude/local/task-groups"
  else
    CONTRACT_DIR="$REPO_ROOT/docs/ai/task-groups"
  fi
  if [ -d "$CONTRACT_DIR" ]; then
    for CONTRACT in "$CONTRACT_DIR"/*.yaml; do
      [ -f "$CONTRACT" ] || continue
      [ "$(basename "$CONTRACT")" = "_contract-template.yaml" ] && continue

      # Check if any brief is marked in_progress (current session)
      if grep -q "status: in_progress" "$CONTRACT" 2>/dev/null; then
        GROUP_NAME=$(basename "$CONTRACT" .yaml)
        # Check for governance section presence
        if ! grep -q "^governance:" "$CONTRACT" 2>/dev/null; then
          echo "Advisory: Task group '$GROUP_NAME' contract has no governance: section — add gate evidence before final commit." >&2
        else
          # Check if governance entry exists for current brief sequence
          CURRENT_SEQ=$(grep -B1 "status: in_progress" "$CONTRACT" 2>/dev/null \
            | grep "sequence:" | sed 's/.*sequence: *//' | head -1 || true)
          if [ -n "$CURRENT_SEQ" ]; then
            if ! grep -q "brief_sequence: $CURRENT_SEQ" "$CONTRACT" 2>/dev/null; then
              echo "Advisory: Task group '$GROUP_NAME' — no governance entry for current brief (sequence $CURRENT_SEQ)." >&2
            fi
          fi
        fi
      fi
    done
  fi
fi

# --- PR check (blocking) ---
# Block if on a mergeable branch with no open PR.
# Override: SKIP_PR_CHECK=1
if [ "${SKIP_PR_CHECK:-0}" != "1" ]; then
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
        log_hook_event "session-close-check" "Stop" "" "block" "$START_MS" "no_pr"
        echo "BLOCKED: No open PR for '$CURRENT_BRANCH' — create PR or defer (override: SKIP_PR_CHECK=1)" >&2
        exit 2
      fi
      ;;
  esac
fi

# --- Known-issues modification detection ---
# Shared by HVST check and deferrals check below. Computed once.
# In template mode, known-issues lives locally; in product mode, it's committed.
if [ -f "$REPO_MODE_FILE" ] && grep -q "template" "$REPO_MODE_FILE" 2>/dev/null; then
  KNOWN_ISSUES="$REPO_ROOT/.claude/local/known-issues.md"
else
  KNOWN_ISSUES="$REPO_ROOT/docs/ai/logs/known-issues.md"
fi

KI_MODIFIED=false
if [ -f "$KNOWN_ISSUES" ]; then
  # Template mode: local file is gitignored, use session-id mtime as proxy
  # Product mode: use git diff for tracked file
  if [ -f "$REPO_MODE_FILE" ] && grep -q "template" "$REPO_MODE_FILE" 2>/dev/null; then
    SESSION_ID_FILE="$REPO_ROOT/.claude/.session-id"
    if [ -f "$SESSION_ID_FILE" ] && [ "$KNOWN_ISSUES" -nt "$SESSION_ID_FILE" ]; then
      KI_MODIFIED=true
    fi
  else
    if git diff --name-only "$KNOWN_ISSUES" 2>/dev/null | grep -q .; then
      KI_MODIFIED=true
    fi
    if git diff --cached --name-only "$KNOWN_ISSUES" 2>/dev/null | grep -q .; then
      KI_MODIFIED=true
    fi
  fi
fi

# --- HVST known-issues check (blocking) ---
# If HVST failures occurred this session, require known-issues.md update.
# Override: SKIP_KNOWN_ISSUES_CHECK=1
if [ "${SKIP_KNOWN_ISSUES_CHECK:-0}" != "1" ]; then
  if [ -f "$COUNTER_FILE" ]; then
    FAIL_COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
    if [ "$FAIL_COUNT" -ge 2 ] && [ "$KI_MODIFIED" = false ]; then
      SESSION_TYPE=$(infer_session_type)
      log_hook_event "session-close-check" "Stop" "" "block" "$START_MS" "hvst_ki_not_updated" "$FAIL_COUNT" "$SESSION_TYPE"
      echo "BLOCKED: $FAIL_COUNT HVST failures but known-issues.md not updated — document per HVST Record step. If failures were transient (network, timing), override with SKIP_KNOWN_ISSUES_CHECK=1" >&2
      exit 2
    fi
  fi

  # --- Deferrals known-issues check (blocking) ---
  # If audit/advisory deferrals occurred, require known-issues.md update.
  if [ -f "$REPO_ROOT/.claude/.deferrals-pending" ]; then
    if [ "$KI_MODIFIED" = false ]; then
      SESSION_TYPE=$(infer_session_type)
      log_hook_event "session-close-check" "Stop" "" "block" "$START_MS" "deferrals_ki_not_updated" "" "$SESSION_TYPE"
      echo "BLOCKED: Deferred findings pending but known-issues.md not updated — document deferrals in Known Limitations table (override: SKIP_KNOWN_ISSUES_CHECK=1)" >&2
      exit 2
    fi
  fi
else
  log_override "session-close-check" "SKIP_KNOWN_ISSUES_CHECK"
fi

# --- Task group next-brief reminder (advisory) ---
# If a task group contract exists with pending briefs, remind about next brief.
# Non-blocking: prints a reminder, does not exit 2. Override: SKIP_CONTRACT_CHECK=1
if [ "${SKIP_CONTRACT_CHECK:-0}" != "1" ]; then
  if [ -f "$REPO_MODE_FILE" ] && grep -q "template" "$REPO_MODE_FILE" 2>/dev/null; then
    CONTRACT_DIR="$REPO_ROOT/.claude/local/task-groups"
  else
    CONTRACT_DIR="$REPO_ROOT/docs/ai/task-groups"
  fi
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
SESSION_TYPE=$(infer_session_type)
log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "session_complete" "$SESSION_TYPE"
register_repo "$REPO_ROOT"

# --- Seal branch (Decision 0013) ---
record_closed_branch

# --- Update baseline for next session ---
update_baseline

# --- Final cleanup ---
cleanup_session