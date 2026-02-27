#!/usr/bin/env bash
# Session close check (blocking)
# Runs via Stop hook in .claude/settings.json.
#
# Behavior:
#   - Single-pass failure collection: all blocking checks run; failures are
#     collected and reported together (no early exit per check).
#   - Solo merge path: when solo=true, feature/fix/hotfix branches are merged
#     directly to main instead of requiring a PR.
#   - Task group branch lifecycle: non-final brief sessions skip branch seal
#     so the branch stays open for the next brief in the group.
#   - 3-attempt counter guard: replaces infinite-loop guard; after 3 stop
#     attempts the hook exits unconditionally (safety valve).
#
# Blocking checks (all collected before reporting):
#   1. Session log not updated
#   2. Uncommitted changes
#   3. No open PR on mergeable branch (solo-aware — skipped when solo=true)
#   4. HVST failures but known-issues.md not updated
#   5. Deferrals pending but known-issues.md not updated
#
# Overrides: SKIP_SESSION_LOG=1, SKIP_UNCOMMITTED_CHECK=1, SKIP_PR_CHECK=1,
#            SKIP_KNOWN_ISSUES_CHECK=1, SKIP_CONTRACT_CHECK=1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_analytics-helper.sh"
source "$SCRIPT_DIR/_phase-helper.sh"
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
STOP_ATTEMPT_FILE="$REPO_ROOT/.claude/.stop-attempt-count"

# Branch seal tracking — set to true by solo merge path to avoid double-seal.
BRANCH_SEALED=false

# --- Portable SHA-256 (file-based, delegates to portable_hash from _analytics-helper.sh) ---
file_hash() {
  [ -f "$1" ] || return 1
  portable_hash < "$1"
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
# Accepts an optional branch argument; if omitted, reads HEAD.
# Appends branch to closed-branches ledger so future sessions can't reuse it.
# Skips main (protected by branch-guard Gate 1 separately).
# Idempotent: won't add duplicate entries.
record_closed_branch() {
  local branch="${1:-}"
  if [ -z "$branch" ]; then
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  fi
  [ -z "$branch" ] && return
  [ "$branch" = "main" ] && return
  local closed_file="$REPO_ROOT/.claude/local/closed-branches"
  mkdir -p "$(dirname "$closed_file")" 2>/dev/null || true
  if ! grep -qxF "$branch" "$closed_file" 2>/dev/null; then
    echo "$branch" >> "$closed_file"
  fi
}

# --- Determine whether the current task group brief is the final one ---
# Scans for a contract with status: in_progress. If found:
#   - If the contract also has any brief with status: pending → echo "false"
#   - If no pending briefs → echo "true"
# If no in_progress contract found → echo "n/a"
is_final_brief() {
  local contract_dir
  if [ -f "$REPO_MODE_FILE" ] && grep -q "template" "$REPO_MODE_FILE" 2>/dev/null; then
    contract_dir="$REPO_ROOT/.claude/local/task-groups"
  else
    contract_dir="$REPO_ROOT/docs/ai/task-groups"
  fi

  [ -d "$contract_dir" ] || { echo "n/a"; return; }

  local found_in_progress=false
  local contract
  for contract in "$contract_dir"/*.yaml; do
    [ -f "$contract" ] || continue
    [ "$(basename "$contract")" = "_contract-template.yaml" ] && continue

    if grep -q "status: in_progress" "$contract" 2>/dev/null; then
      found_in_progress=true
      # Check whether any brief in this contract is still pending
      if grep -q "status: pending" "$contract" 2>/dev/null; then
        echo "false"
        return
      else
        echo "true"
        return
      fi
    fi
  done

  if [ "$found_in_progress" = false ]; then
    echo "n/a"
  fi
}

# --- Session type resolution ---
# Reads from phase-state or .session-type file (via get_session_type from
# _analytics-helper.sh). Falls back to "unknown" when neither is available.
infer_session_type() {
  local stype
  stype=$(get_session_type)
  echo "${stype:-unknown}"
}

# --- Session cleanup (state files + HVST counter + session ID + analytics) ---
# Removes all session-scoped state files to prevent stale state leaking
# across sessions. Preserves .gitkeep.
cleanup_session() {
  rm -f "$COUNTER_FILE"
  rm -f "$STOP_ATTEMPT_FILE"
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
    rm -f "$state_dir/phase-state"
    rm -f "$state_dir/overrides.log"
  fi
}

# --- 3-attempt counter guard ---
# When the Stop hook blocks (exit 2), Claude continues working and fires Stop
# again on the next close attempt. A counter tracks how many attempts have
# been made this session. After 3 attempts the safety valve fires
# unconditionally to prevent infinite loops.
STOP_ATTEMPT=$(cat "$STOP_ATTEMPT_FILE" 2>/dev/null || echo "0")
STOP_ATTEMPT=$(( STOP_ATTEMPT + 1 ))
printf '%s\n' "$STOP_ATTEMPT" > "$STOP_ATTEMPT_FILE" 2>/dev/null || true

if [ "$STOP_ATTEMPT" -ge 3 ]; then
  # Safety valve: unconditional exit after 3 attempts.
  UNCOMMITTED=$(git diff --name-only 2>/dev/null || echo "")
  STAGED=$(git diff --cached --name-only 2>/dev/null || echo "")
  if [ -z "$UNCOMMITTED" ] && [ -z "$STAGED" ]; then
    update_baseline
  fi
  log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "attempt_limit" "$STOP_ATTEMPT" || true
  # Apply same conditional seal as normal close: task group non-final briefs
  # keep the branch open; all other cases seal.
  VALVE_STYPE=$(get_session_type)
  if [ "$VALVE_STYPE" = "taskgroup" ]; then
    VALVE_FINAL=$(is_final_brief)
    if [ "$VALVE_FINAL" = "true" ]; then
      record_closed_branch
    fi
  else
    record_closed_branch
  fi
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
      log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "override_audit" "$OVERRIDE_COUNT:$UNIQUE_OVERRIDES" || true
    fi
  fi
  log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "skip_override" || true
  # Conditional seal: task group non-final briefs keep branch open
  SKIP_STYPE=$(get_session_type)
  if [ "$SKIP_STYPE" = "taskgroup" ]; then
    SKIP_FINAL=$(is_final_brief)
    if [ "$SKIP_FINAL" = "true" ]; then
      record_closed_branch
    fi
  else
    record_closed_branch
  fi
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
    log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "bootstrap_recovery" || true
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
  log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "zero_change" "$SESSION_TYPE" || true
  cleanup_session
  update_baseline
  exit 0
fi

# --- Log overrides (once each, before failure collection) ---
if [ "${SKIP_CONTRACT_CHECK:-0}" = "1" ]; then
  log_override "session-close-check" "SKIP_CONTRACT_CHECK"
fi
if [ "${SKIP_UNCOMMITTED_CHECK:-0}" = "1" ]; then
  log_override "session-close-check" "SKIP_UNCOMMITTED_CHECK"
fi
if [ "${SKIP_PR_CHECK:-0}" = "1" ]; then
  log_override "session-close-check" "SKIP_PR_CHECK"
fi

# --- Single-pass failure collection ---
# All blocking checks run in a single pass. Failures are accumulated and
# reported together so the operator can resolve all issues at once.
FAILURES=""
FAILURE_COUNT=0
add_failure() {
  FAILURE_COUNT=$(( FAILURE_COUNT + 1 ))
  FAILURES="${FAILURES}${FAILURE_COUNT}. $1\n"
}

# 1. Session log check
if [ "$SESSION_LOG_MODIFIED" = false ]; then
  SESSION_LOG_REL="${SESSION_LOG#"$REPO_ROOT/"}"
  add_failure "Session log not updated — update $SESSION_LOG_REL (override: SKIP_SESSION_LOG=1)"
fi

# 2. Uncommitted changes check
if [ "${SKIP_UNCOMMITTED_CHECK:-0}" != "1" ]; then
  if [ -n "$UNCOMMITTED" ] || [ -n "$STAGED" ]; then
    add_failure "Uncommitted changes detected — commit before closing (override: SKIP_UNCOMMITTED_CHECK=1)"
  fi
fi

# 3. PR check (solo-aware)
# Solo mode skips the PR check only for solo-mergeable branches (feature/*, fix/*,
# hotfix/*). release/* always requires a PR even in solo mode (Decision 0015).
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
SOLO=$(get_solo)
if [ "${SKIP_PR_CHECK:-0}" != "1" ]; then
  case "$CURRENT_BRANCH" in
    feature/*|fix/*|hotfix/*)
      if [ "$SOLO" != "true" ]; then
        PR_EXISTS=false
        if command -v gh &>/dev/null; then
          PR_COUNT=$(gh pr list --head "$CURRENT_BRANCH" --state open --json number --jq 'length' 2>/dev/null || echo "0")
          if [ "$PR_COUNT" -gt 0 ]; then
            PR_EXISTS=true
          fi
        fi
        if [ "$PR_EXISTS" = false ]; then
          add_failure "No open PR for '$CURRENT_BRANCH' — create PR or defer (override: SKIP_PR_CHECK=1)"
        fi
      fi
      ;;
    release/*)
      PR_EXISTS=false
      if command -v gh &>/dev/null; then
        PR_COUNT=$(gh pr list --head "$CURRENT_BRANCH" --state open --json number --jq 'length' 2>/dev/null || echo "0")
        if [ "$PR_COUNT" -gt 0 ]; then
          PR_EXISTS=true
        fi
      fi
      if [ "$PR_EXISTS" = false ]; then
        add_failure "No open PR for '$CURRENT_BRANCH' — create PR or defer (override: SKIP_PR_CHECK=1)"
      fi
      ;;
  esac
fi

# 4 & 5. Known-issues checks (HVST + deferrals)
# In template mode, known-issues lives locally; in product mode, it's committed.
if [ -f "$REPO_MODE_FILE" ] && grep -q "template" "$REPO_MODE_FILE" 2>/dev/null; then
  KNOWN_ISSUES="$REPO_ROOT/.claude/local/known-issues.md"
else
  KNOWN_ISSUES="$REPO_ROOT/docs/ai/logs/known-issues.md"
fi

KI_MODIFIED=false
if [ -f "$KNOWN_ISSUES" ]; then
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

if [ "${SKIP_KNOWN_ISSUES_CHECK:-0}" != "1" ]; then
  # 4. HVST known-issues check
  if [ -f "$COUNTER_FILE" ]; then
    FAIL_COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
    if [ "$FAIL_COUNT" -ge 2 ] && [ "$KI_MODIFIED" = false ]; then
      add_failure "$FAIL_COUNT HVST failures but known-issues.md not updated — document per HVST Record step (override: SKIP_KNOWN_ISSUES_CHECK=1)"
    fi
  fi

  # 5. Deferrals known-issues check
  if [ -f "$REPO_ROOT/.claude/.deferrals-pending" ]; then
    if [ "$KI_MODIFIED" = false ]; then
      add_failure "Deferred findings pending but known-issues.md not updated — document deferrals (override: SKIP_KNOWN_ISSUES_CHECK=1)"
    fi
  fi
else
  log_override "session-close-check" "SKIP_KNOWN_ISSUES_CHECK"
fi

# --- Failure report ---
if [ "$FAILURE_COUNT" -gt 0 ]; then
  SESSION_TYPE=$(infer_session_type)
  log_hook_event "session-close-check" "Stop" "" "block" "$START_MS" "single_pass_block" "$FAILURE_COUNT" "$SESSION_TYPE" || true
  echo "BLOCKED: $FAILURE_COUNT issue(s) must be resolved before closing:" >&2
  printf '%b' "$FAILURES" >&2
  exit 2
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
    log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "override_audit" "$OVERRIDE_COUNT:$UNIQUE_OVERRIDES" || true
  fi
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

# --- Solo merge path ---
# When solo=true and on a mergeable branch, merge directly to main instead
# of requiring a PR. Task group non-final briefs skip the merge to keep the
# branch open for the next brief. Experiment branches are excluded.
# SOLO and CURRENT_BRANCH are already set above.
if [ "$SOLO" = "true" ]; then
  SESSION_TYPE_PHASE=$(get_session_type)
  MERGE_BRANCH="$CURRENT_BRANCH"
  SHOULD_MERGE=true

  case "$MERGE_BRANCH" in
    feature/*|fix/*|hotfix/*)
      # Check for non-final task group brief — if so, skip merge
      if [ "$SESSION_TYPE_PHASE" = "taskgroup" ]; then
        IS_FINAL=$(is_final_brief)
        if [ "$IS_FINAL" != "true" ]; then
          SHOULD_MERGE=false
        fi
      fi
      ;;
    *)
      # experiment/*, release/*, or anything else — not a solo merge candidate
      SHOULD_MERGE=false
      ;;
  esac

  if [ "$SHOULD_MERGE" = true ]; then
    MERGE_OK=false
    if git checkout main 2>/dev/null; then
      if git merge --ff-only "$MERGE_BRANCH" 2>/dev/null; then
        MERGE_OK=true
      elif git merge --no-ff -m "Merge $MERGE_BRANCH" "$MERGE_BRANCH" 2>/dev/null; then
        MERGE_OK=true
      fi
    fi

    if [ "$MERGE_OK" = false ]; then
      git merge --abort 2>/dev/null || true
      git checkout "$MERGE_BRANCH" 2>/dev/null || true
      log_hook_event "session-close-check" "Stop" "" "block" "$START_MS" "solo_merge_failed" "" "$MERGE_BRANCH" || true
      echo "ERROR: Solo merge of '$MERGE_BRANCH' into main failed — resolve conflicts manually (or unset solo mode and create a PR)." >&2
      exit 2
    fi

    record_closed_branch "$MERGE_BRANCH"
    BRANCH_SEALED=true
    log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "solo_merge_success" "" "$MERGE_BRANCH" || true
  fi
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
log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "session_complete" "$SESSION_TYPE" || true
register_repo "$REPO_ROOT" || true

# --- Seal branch (Decision 0013) ---
# Conditional: task group non-final briefs skip seal; solo merge already sealed.
if [ "$BRANCH_SEALED" = false ]; then
  SESSION_TYPE_CLOSE=$(get_session_type)
  if [ "$SESSION_TYPE_CLOSE" = "taskgroup" ]; then
    IS_FINAL=$(is_final_brief)
    if [ "$IS_FINAL" = "true" ]; then
      record_closed_branch
    fi
    # Non-final: skip seal — branch stays open for next brief
  else
    record_closed_branch
  fi
fi

# --- Update baseline for next session ---
update_baseline

# --- Final cleanup ---
cleanup_session