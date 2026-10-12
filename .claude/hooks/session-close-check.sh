#!/usr/bin/env bash
# Session close check — Stop (advisory/blocking) and SessionEnd (cleanup) handler.
# Wired to both Stop and SessionEnd hooks in .claude/settings.json (Decision 0047).
#
# Event split (Decision 0047):
#   Stop    — fires at the end of every assistant turn. Runs advisory/blocking
#             checks only. Never performs destructive close work (cleanup, seal,
#             merge). The 3-attempt safety valve unblocks without cleanup.
#   SessionEnd — fires exactly once at true session termination. Runs all
#             destructive close work: merge, seal, state cleanup. Exit code is
#             informational only (Claude Code ignores it). No blocking checks.
#
# Stop blocking checks (all collected before reporting):
#   1. Session log not updated
#   2. Uncommitted changes
# Stop advisory checks (non-blocking, reported in systemMessage):
#   3. HVST failures but known-issues.md not updated (Phase 2b)
#   4. Deferrals pending but known-issues.md not updated (Phase 2b)
#
# SessionEnd cleanup actions:
#   - Agent-merge signal detection (merge-source-branch file)
#   - Editor-live fallback branch seal
#   - Solo merge safety net (solo=true sessions)
#   - Branch sealing (Decision 0013)
#   - State file cleanup (cleanup_session)
#   - Baseline SHA update
#
# Output format (Phase 2a): JSON stdout with decision/reason/systemMessage.
#   Block: {"decision":"block","reason":"<concise for Claude>","systemMessage":"<full for operator>"}
#   Allow: {"decision":"allow","systemMessage":"<advisories>"} or plain exit 0
#   Fallback: when jq unavailable, legacy exit 2 + stderr for blocks.
#
# PARITY: runner.sh replicates post-session tasks externally (Decision 0017).
# See .claude/.automation/RUNNER-PARITY.md for the full mapping.
#
# Overrides: SKIP_SESSION_LOG=1, SKIP_UNCOMMITTED_CHECK=1,
#            SKIP_KNOWN_ISSUES_CHECK=1, SKIP_CONTRACT_CHECK=1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Read stdin early (needed for stop_hook_active parsing after sourcing) ---
INPUT=$(cat)

# --- Harness session_id plumbing (must precede first get_session_id call) ---
# Extracts session_id from the Stop hook JSON payload. The harness embeds the
# live session id here; exporting it allows get_session_id() (in
# _analytics-helper.sh) to prefer this over the .session-id file, keeping
# identity stable across turns without relying on file persistence alone.
export _REPO_OS_STDIN_SID
_REPO_OS_STDIN_SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"

# --- Detect hook event (Stop vs SessionEnd — Decision 0047) ---
# Stop fires at the end of every assistant turn (may fire many times per session).
# SessionEnd fires exactly once at true session termination (informational only;
# exit code is ignored by Claude Code). Destructive close work lives in SessionEnd.
HOOK_EVENT="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // "Stop"' 2>/dev/null || echo "Stop")"
export HOOK_EVENT

# --- Zero-change fast exit (before library sourcing — builtins + git only) ---
# Compute repo root using same logic as _analytics-helper.sh (including test seam).
# Avoids ~14ms sourcing cost for zero-change sessions with no pending state.
# Path prefix guard: _REPO_OS_TEST_ROOT must start with /tmp/ or /private/tmp/.
if [ "${REPO_OS_TEST_MODE:-0}" = "1" ] && [ -n "${_REPO_OS_TEST_ROOT:-}" ]; then
  case "$_REPO_OS_TEST_ROOT" in
    /tmp/*|/private/tmp/*)
      _EARLY_ROOT="$_REPO_OS_TEST_ROOT"
      ;;
    *)
      echo "WARNING: _REPO_OS_TEST_ROOT rejected — must start with /tmp/ or /private/tmp/ (got: $_REPO_OS_TEST_ROOT)" >&2
      _EARLY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
      ;;
  esac
else
  _EARLY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi
_ZC_BASELINE_FILE="$_EARLY_ROOT/.claude/.session-baseline-sha"
# Session-scoped state dir for zero-change fast exit (Decision 0030)
# All session types now route to per-session dirs under wt-sessions/{sid}/.
# Backward compat: if per-session dir doesn't exist, fall back to flat dir.
if [ -n "${REPO_OS_SESSION_ID:-}" ]; then
  _ZC_SID="${REPO_OS_SESSION_ID//\//_}"
  _ZC_SID="${_ZC_SID//\.\./_}"
  _ZC_STATE_DIR="$_EARLY_ROOT/.claude/.state/wt-sessions/$_ZC_SID"
else
  # Interactive session: derive SID from this process's per-process identity.
  # get_session_id is not sourced yet in this pre-source fast path, so mirror its
  # resolution with builtins: prefer the per-process sidecar .session-id.<dpid>
  # (dpid = durable claude $PPID, $$ fallback) over the shared flat .session-id,
  # so a concurrent window resolves its OWN state dir rather than a peer's id.
  _ZC_DPID="${PPID:-0}"
  if [ "$_ZC_DPID" -le 1 ] 2>/dev/null || ! kill -0 "$_ZC_DPID" 2>/dev/null; then
    _ZC_DPID="$$"
  fi
  _ZC_SID=""
  if [ -f "$_EARLY_ROOT/.claude/.session-id.$_ZC_DPID" ]; then
    _ZC_SID=$(cat "$_EARLY_ROOT/.claude/.session-id.$_ZC_DPID" 2>/dev/null)
  elif [ -f "$_EARLY_ROOT/.claude/.session-id" ]; then
    _ZC_SID=$(cat "$_EARLY_ROOT/.claude/.session-id" 2>/dev/null)
  fi
  if [ -n "$_ZC_SID" ]; then
    _ZC_SID="${_ZC_SID//\//_}"
    _ZC_SID="${_ZC_SID//\.\./_}"
    _ZC_PER_SESSION="$_EARLY_ROOT/.claude/.state/wt-sessions/$_ZC_SID"
    if [ -d "$_ZC_PER_SESSION" ]; then
      _ZC_STATE_DIR="$_ZC_PER_SESSION"
    else
      # Backward compat: flat dir for pre-migration sessions
      _ZC_STATE_DIR="$_EARLY_ROOT/.claude/.state"
    fi
  else
    _ZC_STATE_DIR="$_EARLY_ROOT/.claude/.state"
  fi
fi
_ZC_MERGE_FILE="$_ZC_STATE_DIR/merge-source-branch"
_ZC_PHASE_FILE="$_ZC_STATE_DIR/phase-state"

_ZC_UNCOMMITTED=$(git diff --name-only 2>/dev/null || echo "")
_ZC_STAGED=$(git diff --cached --name-only 2>/dev/null || echo "")
_ZC_RECENT=""
if [ -f "$_ZC_BASELINE_FILE" ]; then
  _ZC_BASELINE=$(cat "$_ZC_BASELINE_FILE")
  if git cat-file -e "$_ZC_BASELINE" 2>/dev/null; then
    _ZC_RECENT=$(git log --oneline "$_ZC_BASELINE..HEAD" 2>/dev/null || echo "")
  else
    _ZC_RECENT="baseline-missing"
  fi
else
  _ZC_RECENT=$(git log --oneline --since="4 hours ago" 2>/dev/null || echo "")
fi

if [ -z "$_ZC_UNCOMMITTED" ] && [ -z "$_ZC_STAGED" ] && [ -z "$_ZC_RECENT" ]; then
  # Zero-change session with no pending state — skip sourcing entirely.
  # Guard: only fast-exit when no agent merge signal and no phase-state
  # (sessions that initialized need sourced functions for proper cleanup/seal).
  # SessionEnd must always proceed to cleanup even for zero-change sessions.
  if [ ! -f "$_ZC_MERGE_FILE" ] && [ ! -f "$_ZC_PHASE_FILE" ] && [ "${HOOK_EVENT:-Stop}" != "SessionEnd" ]; then
    git rev-parse HEAD > "$_ZC_BASELINE_FILE" 2>/dev/null || true
    exit 0
  fi
fi

# --- Source libraries (non-zero-change or sessions needing cleanup) ---
source "$SCRIPT_DIR/_analytics-helper.sh"
source "$SCRIPT_DIR/_phase-helper.sh"
source "$SCRIPT_DIR/_cleanup-helper.sh"
source "$SCRIPT_DIR/_secret-pattern.sh"
START_MS=$(now_ms)


# --- Retry detection via stop_hook_active (Phase 1 optimization) ---
# On retry (stop_hook_active=true), skip advisory-only checks but run all
# blocking checks. Advisory checks run once on first attempt (sufficient).
IS_RETRY=false
if [ "$_REPO_OS_HAS_JQ" = true ]; then
  _SHA_VAL=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")
  [ "$_SHA_VAL" = "true" ] && IS_RETRY=true
fi

# --- Paths and state files ---
REPO_ROOT="$_REPO_OS_ROOT"
# Per-session log file: docs/ai/logs/sessions/session-{id}.md (product, tracked) or
# .claude/local/sessions/session-{id}.md (template, gitignored). Eliminates merge
# conflicts when multiple automation sessions complete concurrently.
#
# Template mode accepts EITHER path: the gitignored local default, or the tracked
# product path when the operator prefers worktree session logs to be committed on
# the feature branch (so the log travels with the merge). Child/autonomous modes
# use the product path exclusively. SESSION_LOG is the primary (mkdir + error
# message) target; SESSION_LOG_ALT is the additional candidate in template mode.
IS_TEMPLATE=false
[ "$(get_mode)" = "template" ] && IS_TEMPLATE=true
# Decouple the session-log filename from the live session id. Prefer the
# session_log_id persisted in phase-state at init_phase — this is stable across
# turns and robust against any future identity drift, not just the 9b6ec01
# regression. Fall back to get_session_id() for pre-fix sessions whose
# phase-state predates the field, or when phase-state is absent entirely.
_SESSION_LOG_ID=""
_SLI_STATE_DIR=$(get_session_state_dir 2>/dev/null || true)
if [ -n "$_SLI_STATE_DIR" ] && [ -f "$_SLI_STATE_DIR/phase-state" ]; then
  _SESSION_LOG_ID=$(_read_phase_field "session_log_id" "$_SLI_STATE_DIR/phase-state" 2>/dev/null || true)
fi
if [ -z "$_SESSION_LOG_ID" ]; then
  _SESSION_LOG_ID=$(get_session_id "$REPO_ROOT")
fi
SESSION_LOG_TRACKED="$REPO_ROOT/docs/ai/logs/sessions/session-${_SESSION_LOG_ID}.md"
SESSION_LOG_LOCAL="$REPO_ROOT/.claude/local/sessions/session-${_SESSION_LOG_ID}.md"
if [ "$IS_TEMPLATE" = true ]; then
  SESSION_LOG="$SESSION_LOG_LOCAL"
  SESSION_LOG_ALT="$SESSION_LOG_TRACKED"
else
  SESSION_LOG="$SESSION_LOG_TRACKED"
  SESSION_LOG_ALT=""
fi
BASELINE_SHA_FILE="$REPO_ROOT/.claude/.session-baseline-sha"
COUNTER_FILE="$REPO_ROOT/.claude/.hvst-fail-count"
_SESSION_STATE_DIR="$(get_session_state_dir)"
STOP_ATTEMPT_FILE="$_SESSION_STATE_DIR/.stop-attempt-count"
MERGE_STATE_FILE="$_SESSION_STATE_DIR/merge-source-branch"

# Branch seal tracking — set to true by solo merge path to avoid double-seal.
BRANCH_SEALED=false

# --- Merge serialization (Decision 0030: concurrent worktree close safety) ---
# Uses flock on Linux/macOS, mkdir-based lock fallback.
_MERGE_LOCK_FD=8
_MERGE_LOCK_HELD=false
_MERGE_LOCK_PATH=""

_acquire_merge_lock() {
  local lock_path="$1"
  _MERGE_LOCK_PATH="$lock_path"
  mkdir -p "$(dirname "$lock_path")" 2>/dev/null || true

  # Bounded retry: 3 attempts × 10s before fail-closed (C3 isolation patch)
  local retry=0
  while [ "$retry" -lt 3 ]; do
    retry=$((retry + 1))
    local _acquired=false

    if command -v flock > /dev/null 2>&1; then
      eval "exec ${_MERGE_LOCK_FD}>\"$lock_path\""
      if flock -n -x "$_MERGE_LOCK_FD" 2>/dev/null; then
        _acquired=true
      fi
    else
      # mkdir-based fallback (same pattern as .automation/lib/file-lock.sh)
      local attempts=0
      while [ "$attempts" -lt 20 ]; do
        attempts=$((attempts + 1))
        if mkdir "${lock_path}.dir" 2>/dev/null; then
          echo "$$" > "${lock_path}.dir/pid" 2>/dev/null || true
          _acquired=true
          break
        fi
        if [ -f "${lock_path}.dir/pid" ]; then
          local lock_pid
          lock_pid=$(cat "${lock_path}.dir/pid" 2>/dev/null || echo "")
          if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
            rm -rf "${lock_path}.dir" 2>/dev/null || true
            continue
          fi
        fi
        sleep 0.5
      done
    fi

    if [ "$_acquired" = true ]; then
      _MERGE_LOCK_HELD=true
      return 0
    fi

    if [ "$retry" -lt 3 ]; then
      echo "WARNING: Merge lock attempt $retry/3 failed — retrying in 10s" >&2
      sleep 10
    fi
  done

  # Fail-closed: all 3 attempts exhausted — do not proceed without lock
  echo "ERROR: Merge lock timeout (3 attempts × 10s) — fail-closed, merge blocked" >&2
  return 1
}

_release_merge_lock() {
  if [ "$_MERGE_LOCK_HELD" = true ] && [ -n "$_MERGE_LOCK_PATH" ]; then
    if command -v flock > /dev/null 2>&1; then
      eval "exec ${_MERGE_LOCK_FD}>&-" 2>/dev/null || true
    else
      rm -rf "${_MERGE_LOCK_PATH}.dir" 2>/dev/null || true
    fi
    _MERGE_LOCK_HELD=false
  fi
}

# --- Update baseline for next session ---
# Stores commit SHA for session-scoped change detection.
update_baseline() {
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
    echo "Advisory: push to origin failed (another session may have pushed first) — run 'git pull --rebase origin main && git push origin main' manually" >&2
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
# Session-bind guard (Decision 0013): skips seal if another session is active
# on the current branch (is_session_active check).
seal_branch_if_applicable() {
  # Guard (Decision 0047): sealing is owned by the SessionEnd path only.
  # This belt-and-suspenders check prevents mid-turn seal if call sites are
  # ever re-wired. Called legitimately only from the SessionEnd dispatch above.
  if [ "${HOOK_EVENT:-Stop}" != "SessionEnd" ]; then
    log_hook_event "session-close-check" "${HOOK_EVENT:-Stop}" "" "allow" "$START_MS" "seal_deferred_to_sessionend" || true
    return 0
  fi
  # Guard: skip seal if another session is active on this branch
  local seal_branch
  seal_branch=$(get_branch)
  if [ -n "$seal_branch" ] && [ "$seal_branch" != "main" ] && is_session_active "$seal_branch"; then
    log_hook_event "session-close-check" "${HOOK_EVENT:-Stop}" "" "allow" "$START_MS" "seal_skipped_active_session" "" "$seal_branch" || true
    return 0
  fi

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
  # Markers are cross-session: written by content briefs in their per-session dirs.
  if [ "$stype" = "taskgroup-merge" ]; then
    local marker_count
    marker_count=$(count_cross_session_markers "tg-*-brief-*.complete")
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
# Session-bind (Decision 0013): passes closing session ID so cleanup only
# deletes files owned by this session.
# Audit C5: shared cleanup eliminates divergence risk with state-manager.sh.
# Arguments:
#   $1 — is_closing (true|false, default true). Pass false on pause Stop paths
#         so .session-id/.session-type are preserved (belt-and-suspenders with
#         the pause guard above — the guard exits before calling cleanup_session,
#         but explicit gating here prevents accidental id churn if paths diverge).
cleanup_session() {
  local is_closing="${1:-true}"
  # Capture session type and ID before cleaning state files (phase-state is deleted below)
  local close_stype
  close_stype=$(get_session_type)
  local close_sid
  close_sid=$(get_session_id "$REPO_ROOT")
  # Unregister from session registry (before .session-id removal — needs session ID)
  unregister_session || true
  # Delegate to shared cleanup with session-bind and closing verdict
  cleanup_session_files "$REPO_ROOT" "$close_stype" "$close_sid" "$is_closing"
}

# --- Advisory accumulator (Phase 2a/2b) ---
# Non-blocking messages collected here and emitted via JSON systemMessage.
# Used by gates 3-4 (Phase 2b advisory downgrade) and advisory checks
# (override audit, governance evidence, next-brief reminder).
# Defined early: called by safety valve, operator override, and zero-change paths.
ADVISORIES=""
_add_advisory() {
  ADVISORIES="${ADVISORIES:+$ADVISORIES\n}$1"
}

# --- JSON stdout output helpers (Phase 2a) ---
# JSON stdout gives control over what Claude sees (reason) vs what the operator
# sees (systemMessage). Uses jq for safe JSON escaping when available.
# Fallback: legacy exit 2 + stderr when jq absent.

# Block response: reason → Claude (15-25 tokens), systemMessage → operator (zero token cost)
_output_block() {
  local reason="$1" sys_msg="$2"
  if [ "$_REPO_OS_HAS_JQ" = true ]; then
    jq -n --arg r "$reason" --arg m "$sys_msg" \
      '{decision:"block",reason:$r,systemMessage:$m}'
    exit 0
  else
    # Fallback: legacy stderr output
    printf '%s\n' "$sys_msg" >&2
    exit 2
  fi
}

# Allow response with optional advisory systemMessage
_output_allow() {
  local sys_msg="${1:-}"
  if [ -n "$sys_msg" ] && [ "$_REPO_OS_HAS_JQ" = true ]; then
    jq -n --arg m "$sys_msg" '{decision:"allow",systemMessage:$m}'
  fi
}

# --- KPI summary emission (Phase 3c) ---
# Emits session-level KPI metrics at all exit paths (safety valve, block, normal close).
# Captures: block count, retry depth, safety valve activation, token cost estimate.
# Called once per exit path; the function is idempotent (no state mutation).
_emit_kpi_summary() {
  local block_count="${1:-0}"
  local retry_depth="${2:-1}"
  local reason_text="${3:-}"
  local stype="${4:-}"
  local _kpi_valve=0
  [ "$retry_depth" -ge 3 ] && _kpi_valve=1
  local _kpi_tokens=0
  if [ -n "$reason_text" ]; then
    _kpi_tokens=$(( ${#reason_text} / 4 ))
  fi
  log_kpi_event "session_kpi_summary" \
    "blocks:${block_count},retries:${retry_depth},valve:${_kpi_valve},tokens:${_kpi_tokens}" \
    "${stype:-unknown}" "$START_MS" || true
}

# --- Close-path escalation writer (Decision 0030 / Decision t-0047) ---
# SessionEnd cannot block (Decision t-0047 §2: exit code is informational), so a
# failure on the destructive close path has nowhere to surface in-band. Before
# t-0047 the Stop path could _output_block and force the operator to resolve a
# merge conflict before the turn ended; that lever is gone. A durable escalation
# file is the replacement — without one, merge-lock failures and stale main
# working trees are silent by construction, which is the exact incident class
# Decision 0030 exists to prevent.
# Args: <id-prefix> <message> <context>
_write_close_escalation() {
  local _esc_prefix="$1" _esc_msg="$2" _esc_ctx="$3"
  # Escape for double-quoted YAML scalars. Branch names reach these fields and
  # may legally contain '"' and '\', which would otherwise terminate the scalar
  # early and let adjacent keys be injected (e.g. a forged 'resolved: true' that
  # silently suppresses the escalation). Backslashes first, then quotes.
  _esc_msg="${_esc_msg//\\/\\\\}"; _esc_msg="${_esc_msg//\"/\\\"}"
  _esc_ctx="${_esc_ctx//\\/\\\\}"; _esc_ctx="${_esc_ctx//\"/\\\"}"
  local _esc_dir="${_SE_MAIN_REPO:-$REPO_ROOT}/.claude/.automation/escalations"
  mkdir -p "$_esc_dir" 2>/dev/null || true
  local _esc_id="${_esc_prefix}-$(date +%Y%m%d-%H%M%S)"
  {
    printf 'escalation:\n'
    printf '  id: "%s"\n' "$_esc_id"
    printf '  queue_entry_id: "session-end-hook"\n'
    printf '  type: "gate-failure"\n'
    printf '  severity: "blocking"\n'
    printf '  phase_at_exit: "close"\n'
    printf '  tag_at_exit: "close"\n'
    printf '  message: "%s"\n' "$_esc_msg"
    printf '  context: "%s"\n' "$_esc_ctx"
    printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  resolved: false\n'
    printf '  resolution: ""\n'
  } > "$_esc_dir/${_esc_id}.yaml" 2>/dev/null || true
  echo "Escalation written: $_esc_id" >&2
}

# --- Foreign live state detection (identity-churn safety) ---
# Returns 0 when the state dir this process resolved to is owned by a DIFFERENT,
# independently-live process. See the long-form rationale at the Stop-path call
# site below; both paths share this one implementation so they cannot drift.
#
# Discriminator vs. legitimate context-window turnover (which ALSO makes the live
# harness stdin sid differ from the resolved state's session_id): a turned-over
# session's state still belongs to THIS claude process. register_session() stores
# the durable claude PID ($PPID) as the session's pid, so the resolved state's
# registry pid == our $PPID and this returns 1. Only a genuinely separate, live
# process (pid != $PPID, still alive) returns 0. A dead/orphaned foreign state
# (owner not live) is intentionally NOT caught — callers fall through to their
# existing zero-change / no-session-type exit paths.
#
# Only meaningful for interactive sessions: headless/worktree sessions set
# REPO_OS_SESSION_ID and therefore never alias on the shared .session-id file.
_is_foreign_live_state() {
  [ -z "${REPO_OS_SESSION_ID:-}" ] || return 1
  [ -n "${_REPO_OS_STDIN_SID:-}" ] || return 1
  local _fls_sid _fls_reg _fls_pid
  _fls_sid=$(_read_phase_field "session_id" "$_SESSION_STATE_DIR/phase-state" 2>/dev/null || true)
  [ -n "$_fls_sid" ] || return 1
  [ "$_fls_sid" != "$_REPO_OS_STDIN_SID" ] || return 1
  _fls_reg="$REPO_ROOT/.claude/.state/sessions/${_fls_sid}.yaml"
  [ -f "$_fls_reg" ] || return 1
  _fls_pid=$(grep '^pid: ' "$_fls_reg" 2>/dev/null | sed 's/^pid: *//' | tr -d '[:space:]')
  [ -n "$_fls_pid" ] || return 1
  [ "$_fls_pid" != "${PPID:-0}" ] || return 1
  kill -0 "$_fls_pid" 2>/dev/null || return 1
  # Export the offending sid for the caller's log line.
  _FOREIGN_STATE_SID="$_fls_sid"
  return 0
}

# --- SessionEnd event dispatch (Decision t-0047) ---
# Placed AFTER the function definitions above, not before them: this block
# calls _acquire_merge_lock, _release_merge_lock, update_baseline,
# advisory_push_to_remote, seal_branch_if_applicable, cleanup_session and
# _emit_kpi_summary. Bash resolves function names at call time against what
# has been defined so far, so dispatching earlier in the file made every one
# of them a 'command not found' and killed the whole SessionEnd path.
# Keep this block below every function it calls.
#
# SessionEnd fires exactly once at true session termination. This path runs
# all destructive close work (merge, seal, state cleanup). No blocking checks —
# SessionEnd is informational only (exit code is not used by Claude Code), so
# failures here are surfaced via _write_close_escalation, not via exit status.
#
# The Stop path (below) is advisory/blocking checks only; destructive actions
# moved here so mid-turn Stop firings cannot corrupt live session state.
if [ "$HOOK_EVENT" = "SessionEnd" ]; then
  REPO_ROOT="$_REPO_OS_ROOT"
  IS_TEMPLATE=false
  [ "$(get_mode)" = "template" ] && IS_TEMPLATE=true
  _SESSION_STATE_DIR="$(get_session_state_dir)"
  MERGE_STATE_FILE="$_SESSION_STATE_DIR/merge-source-branch"
  BASELINE_SHA_FILE="$REPO_ROOT/.claude/.session-baseline-sha"
  CURRENT_BRANCH=$(get_branch)
  SOLO=$(get_solo)
  BRANCH_SEALED=false

  # --- Foreign-state guard (identity-churn safety) ---
  # MUST run before any destructive action. The Stop path has always had this
  # guard; when Decision t-0047 moved merge/seal/cleanup here, the guard was left
  # behind at its original position further down the file, which this dispatch
  # exits before ever reaching. That is not merely a skipped check: cleanup_session()
  # resolves close_sid via get_session_id() against the same shared, first-writer-wins
  # .claude/.session-id, so a SessionEnd firing for process A would unregister
  # session B and delete B's session-scoped state — including B's phase-state —
  # while B is still running. Decision 0019 fail-closed enforcement blocks all edits
  # without phase-state, so that abruptly breaks a live, unrelated session mid-flight.
  # Bail out entirely: another live process owns this state and will close it itself.
  if _is_foreign_live_state; then
    log_hook_event "session-close-check" "SessionEnd" "" "allow" "$START_MS" \
      "foreign_state_skip" "${_FOREIGN_STATE_SID:-}" || true
    exit 0
  fi

  # Agent-merge signal detection — agent ran merge+signal before session ended
  if [ -f "$MERGE_STATE_FILE" ]; then
    _SE_MERGED=$(cat "$MERGE_STATE_FILE" 2>/dev/null || true)
    if [ -n "$_SE_MERGED" ]; then
      # The signal's contract is "the agent already merged" — this path only
      # seals, pushes and deletes, it does not merge. Verify the merge really
      # happened before sealing: a session that wrote the signal WITHOUT
      # merging (or whose merge failed) would otherwise get its branch sealed
      # and its work stranded on a branch governance then forbids reusing.
      # When unverified, leave BRANCH_SEALED=false so the solo merge safety
      # net below picks it up instead.
      _SE_MERGE_VERIFIED=false
      if is_full_worktree_session; then
        git -C "$_REPO_OS_ROOT" merge-base --is-ancestor "$_SE_MERGED" main >/dev/null 2>&1 \
          && _SE_MERGE_VERIFIED=true
      else
        git merge-base --is-ancestor "$_SE_MERGED" main >/dev/null 2>&1 \
          && _SE_MERGE_VERIFIED=true
      fi
    fi
    if [ -n "$_SE_MERGED" ] && [ "$_SE_MERGE_VERIFIED" = true ]; then
      record_closed_branch "$_SE_MERGED"
      BRANCH_SEALED=true
      advisory_push_to_remote
      if is_full_worktree_session; then
        delete_merged_session_branch "$_SE_MERGED" "$_REPO_OS_ROOT"
      else
        delete_merged_session_branch "$_SE_MERGED"
      fi
      log_hook_event "session-close-check" "SessionEnd" "" "allow" "$START_MS" "agent_merged" "" "$_SE_MERGED" || true
    elif [ -n "$_SE_MERGED" ]; then
      log_hook_event "session-close-check" "SessionEnd" "" "allow" "$START_MS" "agent_merge_signal_unverified" "" "$_SE_MERGED" || true
    fi
  fi

  # Editor-live fallback: seal orphaned live-editor branch (Decision 0023 Amendment 2)
  if [ "$BRANCH_SEALED" = false ]; then
    _SE_STYPE=$(get_session_type)
    if [ "$_SE_STYPE" = "editor-live" ]; then
      if is_full_worktree_session; then
        seal_orphaned_editor_live_branches "$_REPO_OS_ROOT"
      else
        seal_orphaned_editor_live_branches
      fi
      BRANCH_SEALED=true
    fi
  fi

  # Solo merge safety net — runs when agent did not merge (no merge-source-branch signal)
  if [ "$SOLO" = "true" ] && [ "$BRANCH_SEALED" = false ]; then
    _SE_SESSION_TYPE=$(get_session_type)
    _SE_MERGE_BRANCH="$CURRENT_BRANCH"
    _SE_SHOULD_MERGE=true
    case "$_SE_MERGE_BRANCH" in
      feature/*|fix/*|hotfix/*|live-editor-[0-9]*)
        if [ "$_SE_SESSION_TYPE" = "taskgroup" ]; then
          _SE_IS_FINAL=$(is_final_brief)
          [ "$_SE_IS_FINAL" != "true" ] && _SE_SHOULD_MERGE=false
        elif [ "$_SE_SESSION_TYPE" = "taskgroup-merge" ]; then
          : # always merge
        fi
        ;;
      *) _SE_SHOULD_MERGE=false ;;
    esac

    if [ "$_SE_SHOULD_MERGE" = true ]; then
      _SE_MERGE_OK=false
      # Two SEPARATE concerns — do not merge them into one variable.
      #   _SE_FAIL_REASON  : why the merge did not happen, set at EVERY throw site.
      #                      Preserves the per-failure-mode granularity the
      #                      pre-t-0047 code carried in five distinct log tags.
      #   _SE_ESC_WRITTEN  : whether a throw site already wrote its own escalation.
      #                      Only the sites that actually call _write_close_escalation
      #                      set this. The generic handler below writes exactly when
      #                      it is false, so every failure path yields exactly one
      #                      escalation — never zero, never two.
      _SE_FAIL_REASON=""
      _SE_ESC_WRITTEN=false
      if is_full_worktree_session; then
        _SE_MAIN_REPO="$_REPO_OS_ROOT"
        _SE_MERGE_LOCK="$_SE_MAIN_REPO/.claude/.state/.merge-lock"
        if _acquire_merge_lock "$_SE_MERGE_LOCK"; then
          _SE_MAIN_BRANCH=""
          _SE_MAIN_BRANCH=$(git -C "$_SE_MAIN_REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
          if [ "$_SE_MAIN_BRANCH" = "main" ]; then
            _SE_PRE_SHA=$(git -C "$_SE_MAIN_REPO" rev-parse HEAD 2>/dev/null || echo "")
            if git -C "$_SE_MAIN_REPO" merge --ff-only "$_SE_MERGE_BRANCH" 2>/dev/null || \
               git -C "$_SE_MAIN_REPO" merge --no-ff -m "Merge $_SE_MERGE_BRANCH" "$_SE_MERGE_BRANCH" 2>/dev/null; then
              _SE_MERGE_OK=true
              # Ref-move anomaly detection (Decision 0030): an unchanged HEAD means
              # the branch was already an ancestor, or a prior ref-move from the
              # worktree made main point there without syncing the working tree.
              _SE_POST_SHA=$(git -C "$_SE_MAIN_REPO" rev-parse HEAD 2>/dev/null || echo "")
              if [ -n "$_SE_PRE_SHA" ] && [ "$_SE_PRE_SHA" = "$_SE_POST_SHA" ]; then
                echo "WARNING: SessionEnd merge: 'Already up to date' — main HEAD unchanged by merge of '$_SE_MERGE_BRANCH'. Possible prior ref-move by agent. Applying working-tree sync." >&2
              fi
              # Post-merge working-tree sync (Decision 0030): a ref-move from the
              # worktree leaves index/tree frozen at the old state even though HEAD
              # advanced. Errors are reported, never silenced — staleness must not
              # be invisible.
              if ! git -C "$_SE_MAIN_REPO" reset HEAD -- . 2>/dev/null; then
                echo "WARNING: SessionEnd merge: post-merge index reset failed for '$_SE_MAIN_REPO'" >&2
              fi
              if ! git -C "$_SE_MAIN_REPO" checkout HEAD -- . 2>/dev/null; then
                echo "WARNING: SessionEnd merge: post-merge working tree restore failed for '$_SE_MAIN_REPO'" >&2
              fi
              # Stale-tree detection backstop: verify the sync actually worked.
              if ! git -C "$_SE_MAIN_REPO" diff HEAD --quiet 2>/dev/null; then
                echo "ERROR: Main working tree still stale after post-merge sync (SessionEnd) — index/tree differ from HEAD. Merged code committed but absent from disk. Repair: 'git -C $_SE_MAIN_REPO checkout HEAD -- . && git -C $_SE_MAIN_REPO clean -fd'" >&2
                _write_close_escalation "esc-stale-main" \
                  "Main working tree stale after worktree solo merge sync (SessionEnd) — index/tree differ from HEAD. Merged code committed but absent from disk." \
                  "main_repo: $_SE_MAIN_REPO, branch: $_SE_MERGE_BRANCH"
              fi
            else
              git -C "$_SE_MAIN_REPO" merge --abort 2>/dev/null || true
              _SE_FAIL_REASON="worktree merge of '$_SE_MERGE_BRANCH' into main failed (conflicts) — merge aborted"
            fi
          else
            echo "Advisory: Main repo is on '$_SE_MAIN_BRANCH', not 'main' — cannot merge from worktree. Merge manually." >&2
            _SE_FAIL_REASON="main repo checked out on '$_SE_MAIN_BRANCH', not 'main' — worktree merge not attempted"
            _SE_ESC_WRITTEN=true
            _write_close_escalation "esc-wt-not-main" \
              "Worktree solo merge skipped at SessionEnd — main repo is not on the main branch" \
              "main_repo_branch: $_SE_MAIN_BRANCH, branch: $_SE_MERGE_BRANCH"
            log_hook_event "session-close-check" "SessionEnd" "" "allow" "$START_MS" "wt_merge_skip_not_main" "" "$_SE_MERGE_BRANCH" || true
          fi
          _release_merge_lock
        else
          # Fail-closed (Decision 0030 C3): lock acquisition failed after retries.
          # SessionEnd cannot block, so the escalation file is the only durable
          # record the operator will ever see.
          echo "ERROR: Merge blocked — lock acquisition failed after 3 attempts." >&2
          _SE_FAIL_REASON="merge lock acquisition failed after 3 attempts (fail-closed)"
          _SE_ESC_WRITTEN=true
          _write_close_escalation "esc-merge-lock" \
            "Merge lock acquisition failed after 3 attempts — merge blocked (fail-closed)" \
            "lock_path: $_SE_MERGE_LOCK, branch: $_SE_MERGE_BRANCH"
          log_hook_event "session-close-check" "SessionEnd" "" "allow" "$START_MS" "merge_lock_failed" "" "$_SE_MERGE_BRANCH" || true
        fi
      else
        if git checkout main 2>/dev/null; then
          if git merge --ff-only "$_SE_MERGE_BRANCH" 2>/dev/null || \
             git merge --no-ff -m "Merge $_SE_MERGE_BRANCH" "$_SE_MERGE_BRANCH" 2>/dev/null; then
            _SE_MERGE_OK=true
          else
            git merge --abort 2>/dev/null || true
            git checkout "$_SE_MERGE_BRANCH" 2>/dev/null || true
            _SE_FAIL_REASON="merge of '$_SE_MERGE_BRANCH' into main failed (conflicts) — merge aborted, returned to branch"
          fi
        else
          _SE_FAIL_REASON="'git checkout main' failed — merge never attempted"
        fi
      fi

      if [ "$_SE_MERGE_OK" = true ]; then
        record_closed_branch "$_SE_MERGE_BRANCH"
        BRANCH_SEALED=true
        advisory_push_to_remote
        if is_full_worktree_session; then
          delete_merged_session_branch "$_SE_MERGE_BRANCH" "$_REPO_OS_ROOT"
        else
          delete_merged_session_branch "$_SE_MERGE_BRANCH"
        fi
        log_hook_event "session-close-check" "SessionEnd" "" "allow" "$START_MS" "solo_merge_success" "" "$_SE_MERGE_BRANCH" || true
      else
        # Merge did not happen. Pre-t-0047 the Stop path called _output_block here,
        # forcing the operator to resolve before the turn could end. SessionEnd has
        # no such lever, so record it durably instead of losing it to an analytics
        # line. Deliberately does NOT seal: an unmerged branch must stay reusable
        # (Decision 0013 §6) — sealing would strand the work.
        echo "ERROR: Solo merge of '$_SE_MERGE_BRANCH' into main did not complete: ${_SE_FAIL_REASON:-reason not recorded}. Resolve manually: git checkout main && git merge '$_SE_MERGE_BRANCH'" >&2
        # Write here unless a throw site already escalated. Keyed on _SE_ESC_WRITTEN,
        # NOT on _SE_FAIL_REASON: the reason is set at every throw site, so keying on
        # it would suppress this handler for the three paths that have no escalation
        # of their own (worktree merge conflict, non-worktree merge conflict, failed
        # 'git checkout main') and those failures would produce no durable signal at
        # all. Every _SE_MERGE_OK=false path must yield exactly one escalation.
        if [ "$_SE_ESC_WRITTEN" = false ]; then
          _write_close_escalation "esc-solo-merge" \
            "Solo merge into main did not complete at SessionEnd — branch left unsealed for retry" \
            "branch: $_SE_MERGE_BRANCH, repo: ${_SE_MAIN_REPO:-$REPO_ROOT}, reason: ${_SE_FAIL_REASON:-unclassified}"
        fi
        log_hook_event "session-close-check" "SessionEnd" "" "allow" "$START_MS" "solo_merge_failed" "" "$_SE_MERGE_BRANCH" || true
      fi
    fi
  fi

  # Seal branch (Decision 0013)
  # No-init guard: a session that never called init_phase did no governed work
  # (Decision 0019 fail-closed enforcement blocks every edit without phase-state),
  # so it must not seal a branch — sealing retires a branch nobody finished with,
  # stranding whatever is on it. State cleanup below still runs. Mirrors the Stop
  # path's no-init fast exit, which defers to SessionEnd for cleanup but never
  # intends it to seal.
  if [ "$BRANCH_SEALED" = false ] && [ -f "$_SESSION_STATE_DIR/phase-state" ]; then
    seal_branch_if_applicable
  fi

  # Release a task group worktree's occupancy lock (Decision 0054).
  # The group worktree itself is NOT removed here: it outlives this session for
  # the next brief, and a hook running inside the worktree cannot remove the
  # tree it is standing in anyway. Removal belongs to the terminal paths —
  # the runner after the final brief seals, work order failure, or the stale
  # sweep.
  #
  # The durable pid is passed so an INTERACTIVE session releases the lock it
  # claimed itself in init_phase (Decision 0054 Amendment) — that holder is
  # still alive at SessionEnd, so the orphan condition alone would never fire.
  # A runner-held lock carries the runner's pid instead, so it is still left
  # alone and released by the runner after its post-session merge.
  _SE_GROUP=""
  if _SE_GROUP=$(current_group_worktree_name 2>/dev/null); then
    if [ -n "$_SE_GROUP" ]; then
      release_group_worktree_lock_if_orphaned "$_SE_GROUP" \
        "$(get_session_id "$REPO_ROOT")" "$(_resolve_durable_pid)" \
        && log_hook_event "session-close-check" "SessionEnd" "" "allow" "$START_MS" \
             "group_worktree_lock_released" "" "$_SE_GROUP" || true
    fi
  fi

  # Update baseline for next session
  update_baseline

  # Final cleanup
  cleanup_session
  cleanup_evidence_manifest "$REPO_ROOT" || true

  SESSION_TYPE=$(infer_session_type)
  log_hook_event "session-close-check" "SessionEnd" "" "allow" "$START_MS" "session_complete" "$SESSION_TYPE" || true
  register_repo "$REPO_ROOT" || true
  _emit_kpi_summary 0 0 "" "$SESSION_TYPE"
  exit 0
fi

# --- Foreign-state guard (identity-churn safety) ---
# Interactive sessions (REPO_OS_SESSION_ID unset) resolve their per-session state
# dir via the shared repo-global .claude/.session-id file (first-writer-wins in
# get_session_id). When a SECOND session co-resides in the same working copy — a
# concurrent headless/daemon build, or a second interactive window — both
# processes read the same .session-id and therefore alias to one session id, so
# get_session_state_dir()/get_session_type()/is_session_closing() resolve to the
# OTHER session's phase-state. Enforcing close checks (session log, uncommitted
# changes) against another LIVE session's state produces a spurious block loop:
# the foreign session's in-flight work looks like unsaved changes, and this
# session's own ephemeral/queue-triage exemption is bypassed (the resolved type is
# the foreign one). Guard: if the resolved phase-state is owned by a DIFFERENT,
# independently-live process, do not enforce its close here.
#
# Discriminator vs. legitimate context-window turnover (which ALSO makes the live
# harness stdin sid differ from the resolved state's session_id): a turned-over
# session's state still belongs to THIS claude process. register_session() stores
# the durable claude PID ($PPID) as the session's pid, so the resolved state's
# registry pid == our $PPID and the guard does NOT fire. Only a genuinely
# separate, live process (pid != $PPID, still alive) trips it. A dead/orphaned
# foreign state (owner not live) is intentionally NOT caught here — it falls
# through to the existing zero-change / no-session-type exit paths below.
# Shared with the SessionEnd dispatch above via _is_foreign_live_state() so the
# two close paths cannot drift apart (Decision t-0047 hardening, 2026-09-01).
if _is_foreign_live_state; then
  log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" \
    "foreign_state_skip" "${_FOREIGN_STATE_SID:-}" || true
  exit 0
fi

# --- Pause vs close detection for interactive sessions ---
# Interactive sessions (REPO_OS_SESSION_ID unset) Stop for two reasons:
#   (a) Pause — context window turnover, operator interjection, watcher timeout.
#       Close sequence (cleanup, seal, solo merge) must NOT run: it would churn
#       .session-id, prematurely merge, or lock the branch.
#   (b) Close — agent has advanced into review/verify/op-review/close phases.
#       Full close sequence should run.
#
# Worktree/headless sessions (REPO_OS_SESSION_ID set) are unaffected — they use
# env-var identity and already follow the existing close path below.
#
# The generalized is_session_closing() predicate (in _phase-helper.sh) covers
# ALL interactive session types (standard, taskdef, editor-live, etc.).
# Editor-live is a strict subset: same predicate, same outcome as before.
#
# Placed before the 3-attempt counter so pauses never accumulate toward the
# safety valve, and before any cleanup/seal/merge exit path.
_IC_STYPE=$(get_session_type)
if [ -z "${REPO_OS_SESSION_ID:-}" ]; then
  _IC_CLOSING=false
  if is_session_closing 2>/dev/null; then
    _IC_CLOSING=true
  fi
  if [ "$_IC_CLOSING" = false ]; then
    # Pause Stop — preserve identity, branch, and attempt counter; no close work.
    # Use editor_live_pause reason for editor-live (parity/observability); use
    # interactive_pause for all other interactive session types.
    _IC_PAUSE_PHASE=$(_read_phase_field "current_phase" "$_SESSION_STATE_DIR/phase-state" 2>/dev/null || true)
    if [ "$_IC_STYPE" = "editor-live" ]; then
      log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "editor_live_pause" "$_IC_PAUSE_PHASE" || true
    else
      log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "interactive_pause" "$_IC_PAUSE_PHASE" || true
    fi
    exit 0
  fi
fi

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
  # Record in override audit for governance observability (Phase 1d).
  log_override "session-close-check" "SAFETY_VALVE_3_ATTEMPTS"
  UNCOMMITTED=$(git diff --name-only 2>/dev/null || echo "")
  STAGED=$(git diff --cached --name-only 2>/dev/null || echo "")
  if [ -z "$UNCOMMITTED" ] && [ -z "$STAGED" ]; then
    update_baseline
  fi
  # A4 secret scan preserved in safety valve (adversarial C5/H2): even on
  # forced exit, check staged diff for secrets. Valve still exits (no loop),
  # but writes an escalation so the operator is alerted.
  _SV_STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)
  if [ -n "$_SV_STAGED_FILES" ]; then
    _SV_DIFF=$(git diff --cached -U0 2>/dev/null || true)
    _SV_ADDED=$(printf '%s\n' "$_SV_DIFF" | awk '/^\+/ && !/^\+\+\+/ { print substr($0,2) }')
    _SV_MATCHES=$(printf '%s\n' "$_SV_ADDED" | grep -iE "$_REPO_OS_SECRET_PATTERN" 2>/dev/null || true)
    if [ -n "$_SV_MATCHES" ]; then
      echo "WARNING: A4 secret scan detected possible secrets in staged diff during safety valve exit" >&2
      _SV_ESC_DIR="$REPO_ROOT/.claude/.automation/escalations"
      mkdir -p "$_SV_ESC_DIR" 2>/dev/null || true
      {
        printf 'escalation:\n'
        printf '  type: "security-risk"\n'
        printf '  severity: "blocking"\n'
        printf '  message: "A4 secret scan found possible secrets in staged diff during safety valve exit"\n'
        printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '  resolved: false\n'
      } > "$_SV_ESC_DIR/esc-a4-valve-$(date +%Y%m%d-%H%M%S).yaml" 2>/dev/null || true
      log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "valve_a4_secret" || true
    fi
  fi
  log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "attempt_limit" "$STOP_ATTEMPT" || true
  _emit_kpi_summary 0 "$STOP_ATTEMPT" "" "$(infer_session_type)"
  # Decision 0047: destructive close work (cleanup, seal, merge) moved to SessionEnd.
  # The safety valve on Stop only unblocks — SessionEnd will handle cleanup when the
  # session truly terminates. Emit advisory so operator knows unresolved issues remain.
  _output_allow "Safety valve fired after $STOP_ATTEMPT Stop attempts — blocking checks could not be satisfied. SessionEnd will seal and clean up when the session ends. Review session log and any uncommitted changes manually."
  exit 0
fi

# --- No-init fast exit: session never called init_phase() ---
# If phase-state is absent, the session never initialized. Decision 0019
# fail-closed enforcement blocks all edits without phase-state, so no file
# changes could have occurred. Exit cleanly — SessionEnd will handle cleanup
# when the session terminates (Decision 0047).
if [ ! -f "$_SESSION_STATE_DIR/phase-state" ]; then
  log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "no_phase_state" || true
  exit 0
fi

# --- Fallback: no session type + no commits from this session (belt-and-suspenders) ---
# When get_session_type() returns empty (e.g., phase-state exists from a
# concurrent session but session ID doesn't match, or init_phase was never
# called), AND this session produced no commits since baseline, treat as
# zero-change ephemeral. This prevents concurrent sessions' uncommitted
# changes from causing false blocks on sessions that never wrote anything.
EPHEMERAL_STYPE=$(get_session_type)
if [ -z "$EPHEMERAL_STYPE" ]; then
  _FB_RECENT=""
  if [ -f "$BASELINE_SHA_FILE" ]; then
    _FB_BASELINE=$(cat "$BASELINE_SHA_FILE" 2>/dev/null || true)
    if [ -n "$_FB_BASELINE" ] && git cat-file -e "$_FB_BASELINE" 2>/dev/null; then
      _FB_RECENT=$(git log --oneline "$_FB_BASELINE..HEAD" 2>/dev/null || echo "")
    fi
  fi
  _FB_STAGED=$(git diff --cached --name-only 2>/dev/null || echo "")
  # Filter unstaged changes to only files owned by this session (exclude
  # .claude/.state/ which may be written by concurrent sessions' hooks,
  # and .claude/.automation/ which may be written by the runner daemon).
  _FB_UNSTAGED=$(git diff --name-only 2>/dev/null | grep -v '^\.claude/\.state/\|^\.claude/\.automation/' || echo "")
  if [ -z "$_FB_RECENT" ] && [ -z "$_FB_STAGED" ] && [ -z "$_FB_UNSTAGED" ]; then
    # No seal needed — no work was done. SessionEnd handles cleanup (Decision 0047).
    log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "no_session_type_zero_change" || true
    exit 0
  fi
fi

# --- Session types exempt from blocking close checks (Decision 0014) ---
# Ephemeral types (taskdef-query, taskdef-brief, audit, ephemeral, queue-triage) have no
# gates — allow close unconditionally after cleanup.
# Spec/prototype types produce documents, not implementation code — the session
# log check does not apply, but all other checks (uncommitted changes,
# governance evidence, solo merge, branch seal) still run.
SESSION_LOG_EXEMPT=false
case "$EPHEMERAL_STYPE" in
  taskdef-query|taskdef-brief|audit|ephemeral|queue-triage)
    # Ephemeral sessions (Phase 3b) have no blocking close checks.
    # They must NOT trigger solo merge (Decision 0015) or branch seal.
    # SessionEnd handles cleanup (Decision 0047).
    log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "ephemeral_exempt" "$EPHEMERAL_STYPE" || true
    exit 0
    ;;
  spec-fresh|spec-update|prototype-napkin|prototype-spike|prototype-poc)
    # Spec/prototype sessions produce spec or prototype documents, not
    # implementation code. Session log enforcement does not apply.
    # All other close checks (uncommitted, governance, seal, merge) still run.
    SESSION_LOG_EXEMPT=true
    log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "session_log_exempt" "$EPHEMERAL_STYPE" || true
    ;;
esac

# --- Operator override ---
if [ "${SKIP_SESSION_LOG:-0}" = "1" ]; then
  log_override "session-close-check" "SKIP_SESSION_LOG"
  # Print override audit before cleanup (overrides.log is deleted by cleanup_session)
  OVERRIDES_LOG="$_SESSION_STATE_DIR/overrides.log"
  if [ -f "$OVERRIDES_LOG" ]; then
    OVERRIDE_COUNT=$(wc -l < "$OVERRIDES_LOG" | tr -d ' ')
    if [ "$OVERRIDE_COUNT" -gt 0 ]; then
      UNIQUE_OVERRIDES=$(awk '{print $3}' "$OVERRIDES_LOG" | sort -u | tr '\n' ', ' | sed 's/,$//')
      log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "override_audit" "$OVERRIDE_COUNT:$UNIQUE_OVERRIDES" || true
      _OVR_MSG="Override audit: $OVERRIDE_COUNT override(s) this session — $UNIQUE_OVERRIDES\n  Include in Overrides: git trailer if committing."
    fi
  fi
  log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "skip_override" || true
  # Decision 0047: no seal/cleanup on Stop — SessionEnd owns destructive close work.
  _output_allow "${_OVR_MSG:-}"
  exit 0
fi

# --- Bootstrap ---
# Ensure per-session log directory exists. For per-session files, absence means
# the agent hasn't written the log yet — no recovery needed.
mkdir -p "$(dirname "$SESSION_LOG")" 2>/dev/null || true

# --- Session log check (existence + size) ---
# Per-session files: existence AND meaningful content (>100 bytes) signals the
# agent wrote the log. Absence or tiny file = not written yet.
SESSION_LOG_MODIFIED=false
if [ -f "$SESSION_LOG" ] && [ "$(wc -c < "$SESSION_LOG")" -gt 100 ]; then
  SESSION_LOG_MODIFIED=true
elif [ -n "$SESSION_LOG_ALT" ] && [ -f "$SESSION_LOG_ALT" ] && [ "$(wc -c < "$SESSION_LOG_ALT")" -gt 100 ]; then
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
  # Zero-change session — no blocking. SessionEnd handles cleanup (Decision 0047).
  if [ "$SESSION_LOG_MODIFIED" = false ]; then
    _ZC_MSG="Advisory: No code changes detected (zero-change session). Session log not updated."
  fi
  SESSION_TYPE=$(infer_session_type)
  log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "zero_change" "$SESSION_TYPE" || true
  _output_allow "${_ZC_MSG:-}"
  exit 0
fi

# --- Force-commit backstop (default-on) ---
# When the agent writes a session log claiming completion (`SESSION_LOG_MODIFIED=true`)
# but leaves the working tree dirty, the workflow's step 3 ("Commit all remaining
# changes including the session log") never happened. Without this backstop the
# hook escalates and the work is stranded — the dominant historical failure
# pattern (47% of dirty-tree escalations in the archive analysis: agent declared
# gates passed but never committed).
#
# The hook stages everything and commits with a clearly-marked `[backstop]`
# message before the failure collector runs. Pre-commit gates do NOT fire on
# this commit (the backstop is a subshell of the hook, not an agent tool call)
# — the work is committed on the agent's self-reported gate-pass authority.
# An escalation YAML is still written so the operator has an audit trail.
#
# Exempt from backstop: experiment/* branches; template mode; explicit
# SKIP_UNCOMMITTED_CHECK=1 override; explicit SKIP_FORCE_COMMIT_BACKSTOP=1
# override; sessions with no SESSION_LOG_MODIFIED (class C failures — workflow
# didn't engage at all, force-commit would create surprising commits with no
# narrative).
if [ "${SKIP_FORCE_COMMIT_BACKSTOP:-0}" != "1" ] \
   && [ "${SKIP_UNCOMMITTED_CHECK:-0}" != "1" ] \
   && [ "$IS_TEMPLATE" = false ] \
   && [ "$SESSION_LOG_MODIFIED" = true ] \
   && { [ -n "$UNCOMMITTED" ] || [ -n "$STAGED" ]; }; then
  _FCB_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  case "$_FCB_BRANCH" in
    experiment/*) ;;  # exempt per workflow.md
    *)
      # Log the fire (not an override — this is default behaviour now).
      # If the operator explicitly opted out via SKIP_FORCE_COMMIT_BACKSTOP=1,
      # this branch is unreachable.
      :
      _FCB_SESSION_ID=$(get_session_id 2>/dev/null || echo "unknown")
      _FCB_FILES_COUNT=$(printf '%s\n%s\n' "$UNCOMMITTED" "$STAGED" \
          | grep -cv '^$' 2>/dev/null || echo 0)
      _FCB_MSG="[backstop] close-phase commit — agent skipped step 3"$'\n\n'"\
The session log was updated but git commit was never run. Backstop staged \
$_FCB_FILES_COUNT file(s) and committed on the agent's self-reported gate-pass.\
"$'\n\n'"\
Session: $_FCB_SESSION_ID"$'\n'"\
Pre-commit gates: NOT enforced (backstop runs in close-hook, not as an agent \
tool call). Operator should review the commit if the session log's gate \
self-report is suspect."
      git add -A 2>/dev/null
      if git -c user.email='backstop@repo-os' -c user.name='Repo OS Backstop' \
             commit -m "$_FCB_MSG" 2>/dev/null; then
        _FCB_COMMIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "")
        log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" \
            "force_commit_backstop_fired" "$_FCB_COMMIT_SHA" "$_FCB_BRANCH" || true
        # Write an escalation for the audit trail.
        _FCB_ESC_DIR="$REPO_ROOT/.claude/.automation/escalations"
        mkdir -p "$_FCB_ESC_DIR" 2>/dev/null
        _FCB_ESC_TS=$(date -u +'%Y%m%d-%H%M%S')
        _FCB_ESC_FILE="$_FCB_ESC_DIR/esc-force-commit-backstop-$_FCB_ESC_TS.yaml"
        {
          printf 'escalation:\n'
          printf '  id: "esc-force-commit-backstop-%s"\n' "$_FCB_ESC_TS"
          printf '  session_id: "%s"\n' "$_FCB_SESSION_ID"
          printf '  type: "force-commit-backstop"\n'
          printf '  severity: "advisory"\n'
          printf '  phase_at_exit: "close"\n'
          printf '  message: "Force-commit backstop fired — agent updated session log but did not run git commit"\n'
          printf '  context: "branch: %s; commit: %s; files_count: %s"\n' \
              "$_FCB_BRANCH" "$_FCB_COMMIT_SHA" "$_FCB_FILES_COUNT"
          printf '  created_at: "%s"\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
          printf '  resolved: false\n'
          printf '  resolution: ""\n'
        } > "$_FCB_ESC_FILE" 2>/dev/null
        # Re-read uncommitted state so subsequent checks see the clean tree.
        UNCOMMITTED=$(git diff --name-only 2>/dev/null || echo "")
        STAGED=$(git diff --cached --name-only 2>/dev/null || echo "")
      else
        # Commit failed — leave UNCOMMITTED/STAGED alone so the normal
        # blocking flow fires below, but log the attempt for the operator.
        log_hook_event "session-close-check" "Stop" "" "block" "$START_MS" \
            "force_commit_backstop_failed" "" "$_FCB_BRANCH" || true
      fi
      ;;
  esac
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

# 1. Session log check (exempt for spec/prototype session types)
if [ "$SESSION_LOG_MODIFIED" = false ] && [ "$SESSION_LOG_EXEMPT" = false ]; then
  SESSION_LOG_REL="${SESSION_LOG#"$REPO_ROOT/"}"
  if [ -n "$SESSION_LOG_ALT" ]; then
    SESSION_LOG_ALT_REL="${SESSION_LOG_ALT#"$REPO_ROOT/"}"
    add_failure "Session log not updated — update $SESSION_LOG_REL or $SESSION_LOG_ALT_REL (override: SKIP_SESSION_LOG=1)"
  else
    add_failure "Session log not updated — update $SESSION_LOG_REL (override: SKIP_SESSION_LOG=1)"
  fi
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
    KNOWN_ISSUES_REL="${KNOWN_ISSUES#"$REPO_ROOT/"}"
    if echo "$UNCOMMITTED" | grep -qxF "$KNOWN_ISSUES_REL"; then
      KI_MODIFIED=true
    fi
    if echo "$STAGED" | grep -qxF "$KNOWN_ISSUES_REL"; then
      KI_MODIFIED=true
    fi
  fi
fi

if [ "${SKIP_KNOWN_ISSUES_CHECK:-0}" != "1" ]; then
  # 3. HVST known-issues check (Phase 2b: advisory, no longer blocking)
  if [ -f "$COUNTER_FILE" ]; then
    FAIL_COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
    if [ "$FAIL_COUNT" -ge 2 ] && [ "$KI_MODIFIED" = false ]; then
      _add_advisory "Advisory: $FAIL_COUNT HVST failures but known-issues.md not updated — document per HVST Record step"
    fi
  fi

  # 4. Deferrals known-issues check (Phase 2b: advisory, no longer blocking)
  if [ -f "$REPO_ROOT/.claude/.deferrals-pending" ]; then
    if [ "$KI_MODIFIED" = false ]; then
      _add_advisory "Advisory: Deferred findings pending but known-issues.md not updated — document deferrals"
    fi
  fi
else
  log_override "session-close-check" "SKIP_KNOWN_ISSUES_CHECK"
fi

# 5. Completeness advisory: warn if session is closing with incomplete deliverables
# (backward compat: absent cohesion-reviewed file or absent COMPLETENESS_GATE field is silent)
if [ "$IS_RETRY" = false ]; then
  _SCC_COHESION_FILE="$_SESSION_STATE_DIR/cohesion-reviewed"
  if [ -f "$_SCC_COHESION_FILE" ]; then
    _SCC_GATE=$(grep '^COMPLETENESS_GATE: ' "$_SCC_COHESION_FILE" 2>/dev/null | sed 's/^COMPLETENESS_GATE: *//' | head -1 || true)
    if [ "$_SCC_GATE" = "NEEDS_WORK" ]; then
      _SCC_SCORE=$(grep '^COMPLETENESS: ' "$_SCC_COHESION_FILE" 2>/dev/null | sed 's/^COMPLETENESS: *//' | head -1 || true)
      _add_advisory "Advisory: Session closing with incomplete deliverables — ${_SCC_SCORE:-criteria not fully met}. Operator review required before marking complete."
    fi
  fi
fi

# --- Knowledge graph update check (Decision 0034, Amendment 7) ---
# Blocking enforcement is at commit time (pre-commit-gates.sh KG Update Gate).
# This close-check is advisory only: fires when modified files have KG nodes but no
# kg-updated session marker is present (gate may not have been triggered yet).
# Audit sessions excluded — no write requirement.
# Two-graph architecture: check both template graph (graph.yaml) and product graph (product-graph.yaml).
KG_SESSION_TYPE=$(infer_session_type)
KG_TEMPLATE_GRAPH="$REPO_ROOT/docs/ai/knowledge-graph/graph.yaml"
KG_PRODUCT_GRAPH="$REPO_ROOT/docs/ai/knowledge-graph/product-graph.yaml"
if [ "$KG_SESSION_TYPE" != "audit" ] && { [ -f "$KG_TEMPLATE_GRAPH" ] || [ -f "$KG_PRODUCT_GRAPH" ]; }; then
  # Suppress advisory when kg-updated session marker is present (gate passed this session)
  _KG_PASS_MARKER="$_SESSION_STATE_DIR/kg-updated"
  _KG_ALREADY_PASSED=false
  if [ -f "$_KG_PASS_MARKER" ] && grep -q '^result: PASSED' "$_KG_PASS_MARKER" 2>/dev/null; then
    _KG_ALREADY_PASSED=true
  fi
  if [ "$_KG_ALREADY_PASSED" = false ]; then
    KG_MODIFIED_FILES=$(git -C "$REPO_ROOT" diff --cached --name-only 2>/dev/null || git -C "$REPO_ROOT" diff --name-only HEAD 2>/dev/null || true)
    KG_HAS_GRAPH_NODE=false
    KG_NODE_FILES=""
    for kgf in $KG_MODIFIED_FILES; do
      for kg_file in "$KG_TEMPLATE_GRAPH" "$KG_PRODUCT_GRAPH"; do
        if [ -f "$kg_file" ] && grep -qF "path: \"${kgf}\"" "$kg_file" 2>/dev/null; then
          KG_HAS_GRAPH_NODE=true
          KG_NODE_FILES="${KG_NODE_FILES:+$KG_NODE_FILES }$kgf"
          break
        fi
      done
    done
    if [ "$KG_HAS_GRAPH_NODE" = true ]; then
      _add_advisory "Advisory: Modified files have knowledge graph nodes but no kg-updated marker found — ensure graph.yaml/product-graph.yaml is updated before commit. Files: $KG_NODE_FILES. The KG Update Gate (Amendment 7) will block commit if graph not staged or updated this session. See Decision 0034."
    fi
  fi
fi

# --- Failure report (Phase 2a: JSON stdout) ---
if [ "$FAILURE_COUNT" -gt 0 ]; then
  SESSION_TYPE=$(infer_session_type)
  log_hook_event "session-close-check" "Stop" "" "block" "$START_MS" "single_pass_block" "$FAILURE_COUNT" "$SESSION_TYPE" || true

  # Build concise reason for Claude (15-25 tokens)
  _REASON_PARTS=""
  if [ "$SESSION_LOG_MODIFIED" = false ] && [ "$SESSION_LOG_EXEMPT" = false ]; then
    _REASON_PARTS="session log not updated"
  fi
  if [ "${SKIP_UNCOMMITTED_CHECK:-0}" != "1" ] && { [ -n "$UNCOMMITTED" ] || [ -n "$STAGED" ]; }; then
    _REASON_PARTS="${_REASON_PARTS:+$_REASON_PARTS; }uncommitted changes detected"
  fi
  _BLOCK_REASON="${_REASON_PARTS:-Close sequence incomplete} — resolve before closing"

  # Build full details for operator (systemMessage — zero token cost)
  _BLOCK_SYS_MSG="BLOCKED: $FAILURE_COUNT issue(s) must be resolved before closing:\n$(printf '%b' "$FAILURES")"
  if [ -n "$ADVISORIES" ]; then
    _BLOCK_SYS_MSG="${_BLOCK_SYS_MSG}\n${ADVISORIES}"
  fi

  _emit_kpi_summary "$FAILURE_COUNT" "$STOP_ATTEMPT" "$_BLOCK_REASON" "$SESSION_TYPE"
  _output_block "$_BLOCK_REASON" "$_BLOCK_SYS_MSG"
fi

# --- Override audit (advisory — first attempt only) ---
# Summarize any governance overrides used during this session.
# Skipped on retry: advisory check, not needed for resolution.
if [ "$IS_RETRY" = false ]; then
  OVERRIDES_LOG="$_SESSION_STATE_DIR/overrides.log"
  if [ -f "$OVERRIDES_LOG" ]; then
    OVERRIDE_COUNT=$(wc -l < "$OVERRIDES_LOG" | tr -d ' ')
    if [ "$OVERRIDE_COUNT" -gt 0 ]; then
      UNIQUE_OVERRIDES=$(awk '{print $3}' "$OVERRIDES_LOG" | sort -u | tr '\n' ', ' | sed 's/,$//')
      _add_advisory "Override audit: $OVERRIDE_COUNT override(s) this session — $UNIQUE_OVERRIDES\n  Include in Overrides: git trailer if committing."
      log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "override_audit" "$OVERRIDE_COUNT:$UNIQUE_OVERRIDES" || true
    fi
  fi
fi

# --- Governance evidence check (advisory — first attempt only) ---
# Verifies that governance evidence was recorded in task group contract.
# Model writes this as part of normal contract update; hook only verifies.
# In template mode, contracts live locally; in product mode, they're committed.
# Skipped on retry: advisory check, not needed for resolution.
if [ "$IS_RETRY" = false ] && [ "${SKIP_CONTRACT_CHECK:-0}" != "1" ]; then
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
          _add_advisory "Advisory: Task group '$GROUP_NAME' contract has no governance: section — add gate evidence before final commit."
        else
          if ! grep -q "brief_sequence: $CURRENT_SEQ" "$CONTRACT" 2>/dev/null; then
            _add_advisory "Advisory: Task group '$GROUP_NAME' — no governance entry for current brief (sequence $CURRENT_SEQ)."
          fi
        fi
      fi
    done
  fi
fi

# --- Decision 0047: merge/seal/cleanup moved to SessionEnd dispatch (above) ---
# Agent-merge detection, editor-live seal, solo merge, branch seal, cleanup,
# and update_baseline are no longer performed on the Stop event. They run
# exactly once when SessionEnd fires at true session termination.

# (Editor-live fallback and solo merge moved to SessionEnd dispatch — Decision 0047)


# --- Task group next-brief reminder (advisory — first attempt only) ---
# If a task group contract exists with pending briefs, remind about next brief.
# Non-blocking: prints a reminder, does not exit 2. Override: SKIP_CONTRACT_CHECK=1
# Skipped on retry: advisory check, not needed for resolution.
if [ "$IS_RETRY" = false ] && [ "${SKIP_CONTRACT_CHECK:-0}" != "1" ]; then
  # CONTRACT_DIR resolved above (governance evidence check — same IS_RETRY guard)
  if [ -d "${CONTRACT_DIR:-}" ]; then
    for CONTRACT in "${CONTRACT_DIR:-}"/*.yaml; do
      [ -f "$CONTRACT" ] || continue
      # Skip the template file
      [ "$(basename "$CONTRACT")" = "_contract-template.yaml" ] && continue
      GROUP_NAME=$(basename "$CONTRACT" .yaml)
      # Look for a brief with status: complete that has a next_brief value
      if grep -q "status: complete" "$CONTRACT" 2>/dev/null; then
        NEXT_BRIEF=$(grep -A1 "status: complete" "$CONTRACT" | grep "next_brief:" | grep -v '""' | head -1 | sed 's/.*next_brief: *//' | sed 's/^"//' | sed 's/"$//' || true)
        if [ -n "$NEXT_BRIEF" ]; then
          _add_advisory "Reminder: Task group '$GROUP_NAME' has a next brief — start a new Prompt B session with: $NEXT_BRIEF"
        fi
      fi
    done
  fi
fi

# --- Phases-completed forensic check (advisory — first attempt only) ---
# Verifies that completed phases have corresponding governance evidence.
# Catches force-advance chains retroactively: if phases_completed shows
# "approval" but no plan-approved file exists, the agent skipped the gate.
# Advisory only — emits warning, does not block close.
if [ "$IS_RETRY" = false ]; then
  _FC_STATE_FILE="$_SESSION_STATE_DIR/phase-state"
  if [ -f "$_FC_STATE_FILE" ]; then
    _FC_STYPE=$(get_session_type)
    _FC_COMPLETED=$(_read_phase_field "phases_completed" "$_FC_STATE_FILE")
    # Map phases to expected state files (only phases with governance evidence)
    # approval → plan-approved, review → cohesion-reviewed, verify → qa-verified,
    # plan → pragmatist-signed (when plan gate exists)
    _FC_WARNINGS=""
    if has_plan_gate "$_FC_STYPE"; then
      case ",$_FC_COMPLETED," in
        *",approval,"*|*",approval")
          [ ! -f "$_SESSION_STATE_DIR/plan-approved" ] && \
            _FC_WARNINGS="${_FC_WARNINGS}approval phase completed but plan-approved state file missing; "
          ;;
      esac
      case ",$_FC_COMPLETED," in
        *",plan,"*|*",plan")
          # pragmatist-signed check — phase-state-aware (no sentinel needed)
          if [ ! -f "$_SESSION_STATE_DIR/pragmatist-signed" ]; then
            _FC_WARNINGS="${_FC_WARNINGS}plan phase completed but pragmatist-signed state file missing; "
          fi
          ;;
      esac
    fi
    case ",$_FC_COMPLETED," in
      *",review,"*|*",review")
        # cohesion-reviewed not expected on hotfix
        if [ "$_FC_STYPE" != "hotfix" ] && [ ! -f "$_SESSION_STATE_DIR/cohesion-reviewed" ]; then
          _FC_WARNINGS="${_FC_WARNINGS}review phase completed but cohesion-reviewed state file missing; "
        fi
        ;;
    esac
    case ",$_FC_COMPLETED," in
      *",verify,"*|*",verify")
        [ ! -f "$_SESSION_STATE_DIR/qa-verified" ] && \
          _FC_WARNINGS="${_FC_WARNINGS}verify phase completed but qa-verified state file missing; "
        ;;
    esac
    if [ -n "$_FC_WARNINGS" ]; then
      _add_advisory "Advisory (forensic): Phase evidence gaps detected — ${_FC_WARNINGS%%; }. This may indicate phases were force-advanced without completing required governance steps."
      log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "forensic_phase_gaps" "$_FC_WARNINGS" || true
    fi
  fi
fi

# --- Evidence Manifest Integrity Check (advisory — never blocks) ---
# Compare current evidence file hashes against the manifest captured at init_phase.
# Out-of-tree location earns the stronger claim: findings indicate writes not made
# through a sanctioned hook. See known-issues.md R2 for the bounded guarantee.
if [ "$IS_RETRY" = false ]; then
  compare_manifest 2>&1 | grep -v '^$' >&2 || true
fi

# --- Analytics: log Stop-path completion and register repo ---
# Note: session_complete is now emitted by the SessionEnd dispatch (Decision 0047).
# This records that the Stop advisory/blocking checks passed.
SESSION_TYPE=$(infer_session_type)
log_hook_event "session-close-check" "Stop" "" "allow" "$START_MS" "stop_checks_passed" "$SESSION_TYPE" || true
register_repo "$REPO_ROOT" || true

# --- KPI summary (Phase 3c) — Stop close path ---
_emit_kpi_summary 0 "$STOP_ATTEMPT" "" "$SESSION_TYPE"

# --- JSON stdout: emit collected advisories (Phase 2a) ---
_output_allow "$ADVISORIES"