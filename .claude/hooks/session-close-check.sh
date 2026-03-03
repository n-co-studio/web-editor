#!/usr/bin/env bash
# Session close check (blocking)
# Runs via Stop hook in .claude/settings.json.
#
# Behavior:
#   - Single-pass failure collection: all blocking checks run; failures are
#     collected and reported together (no early exit per check).
#   - Solo merge path: when solo=true, feature/fix/hotfix branches are merged
#     directly to main at session close.
#   - Task group branch lifecycle: non-final brief sessions skip branch seal
#     so the branch stays open for the next brief in the group. Finality is
#     determined by next_brief (empty = final), not status: pending presence.
#   - Empty session type guard: when session type is missing/stale, checks
#     whether the current branch belongs to an active task group contract
#     before sealing (prevents accidental seal on state file loss).
#   - 3-attempt counter guard: replaces infinite-loop guard; after 3 stop
#     attempts the hook exits unconditionally (safety valve).
#
# Blocking checks (all collected before reporting):
#   1. Session log not updated
#   2. Uncommitted changes
#   3. HVST failures but known-issues.md not updated
#   4. Deferrals pending but known-issues.md not updated
#
# PARITY: runner.sh replicates post-session tasks externally (Decision 0017).
# See .claude/.automation/RUNNER-PARITY.md for the full mapping.
#
# Overrides: SKIP_SESSION_LOG=1, SKIP_UNCOMMITTED_CHECK=1,
#            SKIP_KNOWN_ISSUES_CHECK=1, SKIP_CONTRACT_CHECK=1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_analytics-helper.sh"
source "$SCRIPT_DIR/_phase-helper.sh"
source "$SCRIPT_DIR/_cleanup-helper.sh"
START_MS=$(now_ms)

INPUT=$(cat)

# --- Paths and state files ---
REPO_ROOT="$(get_repo_root)"
# In template mode, session log lives locally; in product mode, it's committed.
REPO_MODE_FILE="$REPO_ROOT/.claude/repo-mode"
IS_TEMPLATE=false
[ -f "$REPO_MODE_FILE" ] && grep -q "template" "$REPO_MODE_FILE" 2>/dev/null && IS_TEMPLATE=true
if [ "$IS_TEMPLATE" = true ]; then
  SESSION_LOG="$REPO_ROOT/.claude/local/session-log.md"
else
  SESSION_LOG="$REPO_ROOT/docs/ai/logs/session-log.md"
fi
HASH_FILE="$REPO_ROOT/.claude/.session-log-hash"
BASELINE_SHA_FILE="$REPO_ROOT/.claude/.session-baseline-sha"
COUNTER_FILE="$REPO_ROOT/.claude/.hvst-fail-count"
STOP_ATTEMPT_FILE="$REPO_ROOT/.claude/.state/.stop-attempt-count"
MERGE_STATE_FILE="$REPO_ROOT/.claude/.state/merge-source-branch"

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

# record_closed_branch() — provided by _cleanup-helper.sh (audit C5: shared cleanup)

# --- Check if a branch appears in any active task group contract ---
# Scans the briefs block of each contract YAML for a matching branch: value
# with a non-terminal status (in_progress or pending). Returns 0 if found.
# Uses awk to scope the search to the briefs: block only.
_branch_in_active_contract() {
  local target_branch="$1"
  [ -z "$target_branch" ] && return 1
  local contract_dir
  if [ "$IS_TEMPLATE" = true ]; then
    contract_dir="$REPO_ROOT/.claude/local/task-groups"
  else
    contract_dir="$REPO_ROOT/docs/ai/task-groups"
  fi
  [ -d "$contract_dir" ] || return 1
  local contract
  for contract in "$contract_dir"/*.yaml; do
    [ -f "$contract" ] || continue
    [ "$(basename "$contract")" = "_contract-template.yaml" ] && continue
    if awk -v target="$target_branch" '
      /^briefs:/ { in_briefs=1; next }
      /^[a-z]/ && !/^  / { in_briefs=0 }
      in_briefs && /^  - / {
        if (found_branch && is_active) { print "match"; exit 0 }
        found_branch=0; is_active=0
      }
      in_briefs && /branch:/ {
        val=$0; gsub(/.*branch: *"?/, "", val); gsub(/".*/, "", val)
        if (val == target) found_branch=1
      }
      in_briefs && /status:/ {
        if (/in_progress/ || /pending/) is_active=1
      }
      END { if (found_branch && is_active) print "match" }
    ' "$contract" 2>/dev/null | grep -q "match"; then
      return 0
    fi
  done
  return 1
}

# --- Advisory push to remote (shared logic) ---
# Pushes main to origin after a successful merge. Advisory only — failure
# does not block session close or trigger retry (exit 2).
# Skipped in template mode and when no remote is configured.
advisory_push_to_remote() {
  # Skip in template mode
  if [ "$IS_TEMPLATE" = true ]; then
    return 0
  fi
  # Skip when no remote configured
  if ! git remote get-url origin >/dev/null 2>&1; then
    return 0
  fi
  if ! git push origin main >/dev/null 2>&1; then
    echo "Advisory: push to origin failed — run 'git push origin main' manually" >&2
    log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "push_failed" "" "" || true
  else
    log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "push_success" "" "" || true
  fi
  return 0
}

# --- Conditional branch seal (shared logic) ---
# Task group non-final briefs keep the branch open; all other cases seal.
# Used by safety valve, skip-override, and normal close paths.
# When session type is empty (stale/missing phase-state), checks whether the
# current branch belongs to an active task group contract before sealing.
seal_branch_if_applicable() {
  local stype
  stype=$(get_session_type)
  if [ "$stype" = "taskgroup" ]; then
    local is_final
    is_final=$(is_final_brief)
    if [ "$is_final" = "true" ]; then
      record_closed_branch
    fi
  elif [ "$stype" = "taskgroup-merge" ]; then
    # Merge brief: seal only when completion markers exist (is_final_brief).
    # A merge session that opened but found no markers (briefs not yet complete)
    # should not seal — the branch stays open for retry.
    local is_final
    is_final=$(is_final_brief)
    if [ "$is_final" = "true" ]; then
      record_closed_branch
    fi
  elif [ -z "$stype" ]; then
    # Session type unknown — guard against sealing task group branches.
    # Check if current branch appears in any active contract's briefs block.
    local current_br
    current_br=$(get_branch)
    if _branch_in_active_contract "$current_br"; then
      log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "seal_skipped_empty_stype" "" "$current_br" || true
    else
      record_closed_branch
    fi
  else
    record_closed_branch
  fi
}

# --- Determine whether the current task group brief is the final one ---
# Parallel-aware (Decision 0011):
#   - taskgroup-merge: final when completion markers exist (marker-based)
#   - taskgroup + execution: parallel: always "false" (content briefs never merge)
#   - taskgroup + execution: sequential (or absent): check next_brief field
# Finality indicator: next_brief on the current brief (matched by
# status: in_progress, fallback by branch name). Empty = final, non-empty = non-final.
# All YAML parsing is awk-scoped to the briefs: and identity: blocks to prevent
# false matches against session_decisions or governance sections.
# Returns "true", "false", or "n/a".
is_final_brief() {
  local contract_dir
  if [ "$IS_TEMPLATE" = true ]; then
    contract_dir="$REPO_ROOT/.claude/local/task-groups"
  else
    contract_dir="$REPO_ROOT/docs/ai/task-groups"
  fi

  [ -d "$contract_dir" ] || { echo "n/a"; return; }

  local stype
  stype=$(get_session_type)

  # Merge brief: final only when completion markers exist.
  # Precise count validation happens at agent level (contract-init phase).
  if [ "$stype" = "taskgroup-merge" ]; then
    local state_dir="$REPO_ROOT/.claude/.state"
    local marker_count=0
    local marker
    for marker in "$state_dir"/tg-*-brief-*.complete; do
      [ -f "$marker" ] || continue
      marker_count=$((marker_count + 1))
    done
    if [ "$marker_count" -eq 0 ]; then
      echo "false"
      return
    fi
    echo "true"
    return
  fi

  # --- Sequential / non-merge finality check ---
  # Strategy: find the current brief entry by status: in_progress (primary)
  # or by branch name match (fallback after contract-update marks it complete).
  # Then check next_brief: empty = final, non-empty = non-final.
  # Uses awk to scope parsing to the briefs: and identity: blocks only.
  local current_branch
  current_branch=$(get_branch)

  local contract
  for contract in "$contract_dir"/*.yaml; do
    [ -f "$contract" ] || continue
    [ "$(basename "$contract")" = "_contract-template.yaml" ] && continue

    # Awk: parse briefs and identity blocks, find the current brief, extract
    # next_brief and execution mode. Priority: status: in_progress > branch match.
    local awk_result
    awk_result=$(awk -v branch="$current_branch" '
      /^identity:/ { in_id=1; in_briefs=0; next }
      /^briefs:/ { in_briefs=1; in_id=0; next }
      /^[a-z]/ && !/^  / { in_id=0; in_briefs=0 }

      in_id && /execution:/ {
        gsub(/.*execution: */, ""); gsub(/ *#.*/, "")
        exec_mode = $0
      }

      in_briefs && /^  - / {
        if (ip_match) { printf "IP|%s|%s\n", nb, exec_mode; exit 0 }
        if (br_match && !ip_match) br_res = sprintf("BR|%s|%s", nb, exec_mode)
        ip_match=0; br_match=0; nb=""
      }
      in_briefs && /status:/ && /in_progress/ { ip_match=1 }
      in_briefs && /branch:/ {
        val=$0; gsub(/.*branch: *"?/, "", val); gsub(/".*/, "", val)
        if (val == branch) br_match=1
      }
      in_briefs && /next_brief:/ {
        val=$0; gsub(/.*next_brief: *"?/, "", val); gsub(/"? *$/, "", val)
        nb = val
      }
      END {
        if (ip_match) printf "IP|%s|%s\n", nb, exec_mode
        else if (br_res != "") print br_res
      }
    ' "$contract" 2>/dev/null)

    [ -z "$awk_result" ] && continue

    # Parse awk output: MATCH_TYPE|next_brief_value|execution_mode
    local match_type next_brief exec_mode
    match_type=$(echo "$awk_result" | cut -d'|' -f1)
    next_brief=$(echo "$awk_result" | cut -d'|' -f2)
    exec_mode=$(echo "$awk_result" | cut -d'|' -f3)

    # Parallel content briefs never merge — only the merge brief merges
    if [ "$stype" = "taskgroup" ] && [ "$exec_mode" = "parallel" ]; then
      echo "false"
      return
    fi

    # Finality: empty next_brief = final, non-empty = non-final
    if [ -z "$next_brief" ]; then
      echo "true"
    else
      echo "false"
    fi
    return
  done

  echo "n/a"
}

# --- Session type resolution ---
# Reads from phase-state or .session-type file (via get_session_type from
# _analytics-helper.sh). Falls back to "unknown" when neither is available.
infer_session_type() {
  local stype
  stype=$(get_session_type)
  echo "${stype:-unknown}"
}

# --- Session cleanup (delegates to shared cleanup_session_files from _cleanup-helper.sh) ---
# Unregisters session, then removes all session-scoped state files.
# Audit C5: shared cleanup eliminates divergence risk with state-manager.sh.
cleanup_session() {
  # Capture session type before cleaning state files (phase-state is deleted below)
  local close_stype
  close_stype=$(get_session_type)
  # Unregister from session registry (before .session-id removal — needs session ID)
  unregister_session || true
  # Delegate to shared cleanup
  cleanup_session_files "$REPO_ROOT" "$close_stype"
}

# --- 3-attempt counter guard ---
# When the Stop hook blocks (exit 2), Claude continues working and fires Stop
# again on the next close attempt. A counter tracks how many attempts have
# been made this session. After 3 attempts the safety valve fires
# unconditionally to prevent infinite loops.
STOP_ATTEMPT=$(cat "$STOP_ATTEMPT_FILE" 2>/dev/null || echo "0")
STOP_ATTEMPT=$(( STOP_ATTEMPT + 1 ))
mkdir -p "$(dirname "$STOP_ATTEMPT_FILE")" 2>/dev/null || true
printf '%s\n' "$STOP_ATTEMPT" > "$STOP_ATTEMPT_FILE" 2>/dev/null || true

if [ "$STOP_ATTEMPT" -ge 3 ]; then
  # Safety valve: unconditional exit after 3 attempts.
  UNCOMMITTED=$(git diff --name-only 2>/dev/null || echo "")
  STAGED=$(git diff --cached --name-only 2>/dev/null || echo "")
  if [ -z "$UNCOMMITTED" ] && [ -z "$STAGED" ]; then
    update_baseline
  fi
  log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "attempt_limit" "$STOP_ATTEMPT" || true
  seal_branch_if_applicable
  cleanup_session
  exit 0
fi

# --- No-init fast exit: session never called init_phase() ---
# If phase-state is absent, the session never initialized. Decision 0019
# fail-closed enforcement blocks all edits without phase-state, so no file
# changes could have occurred. Safe to exit after cleanup.
if [ ! -f "$REPO_ROOT/.claude/.state/phase-state" ]; then
  log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "no_phase_state" || true
  # Seal before cleanup — honour agent-merge signals from prior context windows
  # and seal the current branch (seal_branch_if_applicable uses the
  # _branch_in_active_contract guard when session type is unknown).
  if [ -f "$MERGE_STATE_FILE" ]; then
    _noinit_merged=$(cat "$MERGE_STATE_FILE" 2>/dev/null || true)
    if [ -n "$_noinit_merged" ]; then
      record_closed_branch "$_noinit_merged"
      advisory_push_to_remote
      log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "agent_merged" "" "$_noinit_merged" || true
    fi
  fi
  seal_branch_if_applicable
  cleanup_session
  exit 0
fi

# --- Ephemeral session types — no blocking checks (Decision 0014) ---
# taskdef-query, taskdef-brief, and audit sessions have no gates per the
# phase-aware gate profile. Allow close unconditionally after cleanup.
EPHEMERAL_STYPE=$(get_session_type)
case "$EPHEMERAL_STYPE" in
  taskdef-query|taskdef-brief|audit)
    log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "ephemeral_exempt" "$EPHEMERAL_STYPE" || true
    cleanup_session
    exit 0
    ;;
esac

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
  seal_branch_if_applicable
  update_baseline
  cleanup_session
  exit 0
fi

# --- Bootstrap ---
# If session log is missing, recover from git (product mode) or create empty (template mode) or skip.
if [ ! -f "$SESSION_LOG" ]; then
  if [ "$IS_TEMPLATE" = true ]; then
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
  # Seal before cleanup — honour agent-merge signals and seal current branch.
  if [ -f "$MERGE_STATE_FILE" ]; then
    _zc_merged=$(cat "$MERGE_STATE_FILE" 2>/dev/null || true)
    if [ -n "$_zc_merged" ]; then
      record_closed_branch "$_zc_merged"
      advisory_push_to_remote
      log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "agent_merged" "" "$_zc_merged" || true
    fi
  fi
  seal_branch_if_applicable
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

# 3 & 4. Known-issues checks (HVST + deferrals)
CURRENT_BRANCH=$(get_branch)
SOLO=$(get_solo)
# In template mode, known-issues lives locally; in product mode, it's committed.
if [ "$IS_TEMPLATE" = true ]; then
  KNOWN_ISSUES="$REPO_ROOT/.claude/local/known-issues.md"
else
  KNOWN_ISSUES="$REPO_ROOT/docs/ai/logs/known-issues.md"
fi

KI_MODIFIED=false
if [ -f "$KNOWN_ISSUES" ]; then
  if [ "$IS_TEMPLATE" = true ]; then
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
  echo "" >&2
  echo "Close sequence (complete all before retrying):" >&2
  echo "  1. Update session log" >&2
  echo "  2. Commit all changes including session log" >&2
  echo "  3. Merge to main (solo mode)" >&2
  echo "  4. Present closing summary — then exit" >&2
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
  if [ "$IS_TEMPLATE" = true ]; then
    CONTRACT_DIR="$REPO_ROOT/.claude/local/task-groups"
  else
    CONTRACT_DIR="$REPO_ROOT/docs/ai/task-groups"
  fi
  if [ -d "$CONTRACT_DIR" ]; then
    for CONTRACT in "$CONTRACT_DIR"/*.yaml; do
      [ -f "$CONTRACT" ] || continue
      [ "$(basename "$CONTRACT")" = "_contract-template.yaml" ] && continue

      # Check if any brief is marked in_progress (current session).
      # Scoped to briefs: block using awk to avoid matching session_decisions.
      CURRENT_SEQ=$(awk '
        /^briefs:/ { in_briefs=1; next }
        /^[a-z]/ && !/^  / { in_briefs=0 }
        in_briefs && /sequence:/ {
          val=$0; gsub(/.*sequence: */, "", val); gsub(/ *$/, "", val)
          seq = val
        }
        in_briefs && /status:/ && /in_progress/ { print seq; exit 0 }
      ' "$CONTRACT" 2>/dev/null)
      if [ -n "$CURRENT_SEQ" ]; then
        GROUP_NAME=$(basename "$CONTRACT" .yaml)
        # Check for governance section presence
        if ! grep -q "^governance:" "$CONTRACT" 2>/dev/null; then
          echo "Advisory: Task group '$GROUP_NAME' contract has no governance: section — add gate evidence before final commit." >&2
        else
          if ! grep -q "brief_sequence: $CURRENT_SEQ" "$CONTRACT" 2>/dev/null; then
            echo "Advisory: Task group '$GROUP_NAME' — no governance entry for current brief (sequence $CURRENT_SEQ)." >&2
          fi
        fi
      fi
    done
  fi
fi

# --- Agent-merge detection ---
# If the agent already merged in the close phase (via write_merge_signal),
# skip the hook's own merge logic. The agent writes merge-source-branch
# after a successful git checkout main && git merge.
if [ -f "$MERGE_STATE_FILE" ]; then
  AGENT_MERGED_BRANCH=$(cat "$MERGE_STATE_FILE" 2>/dev/null || true)
  if [ -n "$AGENT_MERGED_BRANCH" ]; then
    record_closed_branch "$AGENT_MERGED_BRANCH"
    BRANCH_SEALED=true
    advisory_push_to_remote
    log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "agent_merged" "" "$AGENT_MERGED_BRANCH" || true
  fi
fi

# --- Solo merge path ---
# When solo=true and on a mergeable branch, merge directly to main instead
# Task group non-final briefs skip the merge to keep the
# branch open for the next brief. Experiment branches are excluded.
# Safety net: runs only when agent did not merge (merge-source-branch absent).
# SOLO and CURRENT_BRANCH are already set above.
if [ "$SOLO" = "true" ] && [ "$BRANCH_SEALED" = false ]; then
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
      elif [ "$SESSION_TYPE_PHASE" = "taskgroup-merge" ]; then
        : # always merge — merge brief is always the final brief
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
      echo "ERROR: Solo merge of '$MERGE_BRANCH' into main failed — resolve conflicts manually." >&2
      exit 2
    fi

    record_closed_branch "$MERGE_BRANCH"
    BRANCH_SEALED=true
    advisory_push_to_remote
    log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "solo_merge_success" "" "$MERGE_BRANCH" || true
  fi
fi

# --- Task group next-brief reminder (advisory) ---
# If a task group contract exists with pending briefs, remind about next brief.
# Non-blocking: prints a reminder, does not exit 2. Override: SKIP_CONTRACT_CHECK=1
if [ "${SKIP_CONTRACT_CHECK:-0}" != "1" ]; then
  # CONTRACT_DIR already resolved above (governance evidence check)
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
  seal_branch_if_applicable
fi

# --- Update baseline for next session ---
update_baseline

# --- Final cleanup ---
cleanup_session