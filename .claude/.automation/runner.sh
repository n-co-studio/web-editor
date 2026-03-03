#!/usr/bin/env bash
# Operator automation layer — headless session runner.
# Entry point for automated claude -p invocations with governance parity.
# Decision 0017 — Operator Automation Layer.
#
# Two modes:
#   Single-shot: runner.sh --brief-id <id> [--branch <branch>] [--session-type <type>]
#   Daemon:      runner.sh --daemon
#
# Single-shot mode runs one brief directly (backward compatible with Brief 2).
# Daemon mode loops: dequeue from approved queue, assemble prompt, execute,
# transition based on outcome. Supports live config toggle and HALT file.
#
# Exits:
#   0 — completed (success or clean no-op)
#   1 — failed (crash or clean failure)
#   2 — review (escalation or operator tag)

set -euo pipefail

# --- Self-locate and derive repo root ---
# runner.sh lives at .claude/.automation/ — repo root is two levels up.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AUTOMATION_DIR="$SCRIPT_DIR"
LIB_DIR="$AUTOMATION_DIR/lib"

# --- Source shared helpers ---
# shellcheck source=../../.claude/hooks/_analytics-helper.sh
source "$REPO_ROOT/.claude/hooks/_analytics-helper.sh"
# shellcheck source=../../.claude/hooks/_phase-helper.sh
source "$REPO_ROOT/.claude/hooks/_phase-helper.sh"
# shellcheck source=../../.claude/hooks/_cleanup-helper.sh
source "$REPO_ROOT/.claude/hooks/_cleanup-helper.sh"

# --- Source runner libraries ---
# shellcheck source=lib/state-manager.sh
source "$LIB_DIR/state-manager.sh"
# shellcheck source=lib/branch-manager.sh
source "$LIB_DIR/branch-manager.sh"
# shellcheck source=lib/outcome-detector.sh
source "$LIB_DIR/outcome-detector.sh"
# shellcheck source=lib/queue-manager.sh
source "$LIB_DIR/queue-manager.sh"
# shellcheck source=lib/prompt-assembler.sh
source "$LIB_DIR/prompt-assembler.sh"
# shellcheck source=lib/permission-profiles.sh
source "$LIB_DIR/permission-profiles.sh"
# shellcheck source=lib/blocker-reporter.sh
source "$LIB_DIR/blocker-reporter.sh"
# shellcheck source=lib/cohesion-trigger.sh
source "$LIB_DIR/cohesion-trigger.sh"
# shellcheck source=lib/cleanup.sh
source "$LIB_DIR/cleanup.sh"
# shellcheck source=lib/work-order-manager.sh
source "$LIB_DIR/work-order-manager.sh"
# shellcheck source=lib/review-log.sh
source "$LIB_DIR/review-log.sh"
# shellcheck source=lib/drift-detector.sh
source "$LIB_DIR/drift-detector.sh"
# shellcheck source=lib/queue-validator.sh
source "$LIB_DIR/queue-validator.sh"
# shellcheck source=lib/cache-builder.sh
source "$LIB_DIR/cache-builder.sh"
# shellcheck source=lib/file-lock.sh
source "$LIB_DIR/file-lock.sh"

# --- Config file ---
CONFIG_FILE="$AUTOMATION_DIR/config.yaml"

# --- Heartbeat state ---
_HEARTBEAT_PID=""

# --- Parse arguments ---
BRIEF_ID=""
EXISTING_BRANCH=""
SESSION_TYPE="standard"
DAEMON_MODE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --brief-id)
      BRIEF_ID="$2"
      shift 2
      ;;
    --branch)
      EXISTING_BRANCH="$2"
      shift 2
      ;;
    --session-type)
      SESSION_TYPE="$2"
      shift 2
      ;;
    --daemon)
      DAEMON_MODE=true
      shift
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      echo "Usage: runner.sh --brief-id <id> [--branch <name>] [--session-type <type>]" >&2
      echo "       runner.sh --daemon" >&2
      exit 1
      ;;
  esac
done

# Validate mode: --daemon and --brief-id are mutually exclusive
if [ "$DAEMON_MODE" = true ] && [ -n "$BRIEF_ID" ]; then
  echo "ERROR: --daemon and --brief-id are mutually exclusive" >&2
  exit 1
fi

# Single-shot mode requires --brief-id
if [ "$DAEMON_MODE" = false ] && [ -z "$BRIEF_ID" ]; then
  echo "ERROR: --brief-id is required (or use --daemon for queue mode)" >&2
  exit 1
fi

# Validate config file exists
if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: Config file not found: $CONFIG_FILE" >&2
  exit 1
fi

# ============================================================
# Heartbeat — background timestamp writer for running entries
# ============================================================

_start_heartbeat() {
  local entry_id="$1"
  local qdir
  qdir=$(_queue_dir)
  local hb_file="$qdir/running/${entry_id}.heartbeat"
  local interval
  interval=$(_parse_config_field "runner" "heartbeat_interval")
  interval="${interval:-30}"

  (
    while true; do
      date -u +%Y-%m-%dT%H:%M:%SZ > "${hb_file}.tmp" 2>/dev/null \
        && mv "${hb_file}.tmp" "$hb_file" 2>/dev/null || true
      sleep "$interval"
    done
  ) &
  _HEARTBEAT_PID=$!
}

_stop_heartbeat() {
  if [ -n "$_HEARTBEAT_PID" ]; then
    kill "$_HEARTBEAT_PID" 2>/dev/null || true
    wait "$_HEARTBEAT_PID" 2>/dev/null || true
    _HEARTBEAT_PID=""
  fi
}

# Clean up heartbeat on exit
trap '_stop_heartbeat' EXIT

# ============================================================
# Circuit breaker — 3 consecutive global failures pauses daemon
# ============================================================

_CB_FILE=""
_cb_file() {
  if [ -z "$_CB_FILE" ]; then
    _CB_FILE="$(_queue_dir)/.circuit-breaker"
  fi
  printf '%s' "$_CB_FILE"
}

_circuit_breaker_tripped() {
  local cb_file
  cb_file=$(_cb_file)
  [ -f "$cb_file" ] || return 1
  local count
  count=$(grep '^consecutive_failures:' "$cb_file" 2>/dev/null \
    | sed 's/.*: *//' | tr -d '[:space:]' | head -1)
  [ -n "$count" ] && [ "$count" -ge 3 ] && return 0
  return 1
}

_circuit_breaker_increment() {
  local cb_file
  cb_file=$(_cb_file)
  local count=0
  if [ -f "$cb_file" ]; then
    count=$(grep '^consecutive_failures:' "$cb_file" 2>/dev/null \
      | sed 's/.*: *//' | tr -d '[:space:]' | head -1)
    count="${count:-0}"
  fi
  count=$((count + 1))
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf 'consecutive_failures: %s\nlast_failure_at: %s\n' "$count" "$ts" \
    > "${cb_file}.tmp"
  mv "${cb_file}.tmp" "$cb_file"
}

_circuit_breaker_reset() {
  local cb_file
  cb_file=$(_cb_file)
  rm -f "$cb_file" 2>/dev/null || true
}

# ============================================================
# Pre-flight checks
# ============================================================

# Verify queue and repo are on the same filesystem (required for atomic mv).
_check_same_filesystem() {
  local qdir
  qdir=$(_queue_dir)
  mkdir -p "$qdir" 2>/dev/null || true
  local repo_dev queue_dev
  # Audit C4: cross-platform stat for device ID
  case "${OSTYPE:-}" in
    darwin*)
      repo_dev=$(stat -f %d "$REPO_ROOT" 2>/dev/null || echo "unknown_r")
      queue_dev=$(stat -f %d "$qdir" 2>/dev/null || echo "unknown_q")
      ;;
    *)
      repo_dev=$(stat -c %d "$REPO_ROOT" 2>/dev/null || echo "unknown_r")
      queue_dev=$(stat -c %d "$qdir" 2>/dev/null || echo "unknown_q")
      ;;
  esac
  if [ "$repo_dev" != "$queue_dev" ]; then
    echo "ERROR: Queue ($qdir) and repo ($REPO_ROOT) are on different filesystems" >&2
    echo "Atomic mv requires same filesystem. Aborting." >&2
    return 1
  fi
}

# Warn about stale running entries (heartbeat older than 24h).
# Returns 1 if stale lock found (caller should break loop).
_check_stale_locks() {
  local qdir
  qdir=$(_queue_dir)
  local hb_file
  for hb_file in "$qdir/running"/*.heartbeat; do
    [ -f "$hb_file" ] || continue
    local hb_ts
    hb_ts=$(cat "$hb_file" 2>/dev/null || true)
    [ -z "$hb_ts" ] && continue

    # Parse ISO 8601 to epoch (macOS date -j -f)
    local hb_epoch now_epoch age_hours
    hb_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$hb_ts" "+%s" 2>/dev/null || echo "0")
    now_epoch=$(date +%s)
    if [ "$hb_epoch" -gt 0 ]; then
      age_hours=$(( (now_epoch - hb_epoch) / 3600 ))
      if [ "$age_hours" -ge 24 ]; then
        local stale_id
        stale_id=$(basename "$hb_file" .heartbeat)
        echo "WARNING: Stale lock detected — entry $stale_id heartbeat is ${age_hours}h old" >&2
        echo "Possible orphaned runner. Investigate before restarting." >&2
        return 1
      fi
    fi
  done
}

# ============================================================
# Core execution — run a single entry (used by both modes)
# ============================================================

# Arguments:
#   $1 — brief_id (for branch naming)
#   $2 — prompt (assembled prompt text)
#   $3 — session_type (Decision 0014 enum)
#   $4 — existing_branch (optional, for task group)
#   $5 — permission_profile (optional, default: "build")
# Output: "outcome:detail" on stdout
_run_single_entry() {
  local brief_id="$1"
  local prompt="$2"
  local session_type="$3"
  local existing_branch="${4:-}"
  local permission_profile="${5:-build}"

  # Pre-launch setup
  state_manager_setup "$REPO_ROOT" "$session_type"

  # Branch setup
  branch_manager_setup "$brief_id" "$existing_branch"

  # Record baseline SHA
  local baseline_sha
  baseline_sha=$(git rev-parse HEAD)

  # Set automation context for analytics hooks (inherited by claude -p child)
  export REPO_OS_AUTOMATION_ENTRY="$brief_id"

  # Resolve permission profile to --disallowedTools string
  local disallowed
  disallowed=$(get_disallowed_tools "$permission_profile")

  # Capture stderr to temp file for blocker reports
  local stderr_file
  stderr_file=$(mktemp "${TMPDIR:-/tmp}/runner-stderr-XXXXXX" 2>/dev/null || echo "")

  # Launch headless session
  local exit_code=0
  if [ -n "$stderr_file" ]; then
    claude -p \
      --disallowedTools "$disallowed" \
      --max-turns 200 \
      <<< "$prompt" \
      2> >(tee "$stderr_file" >&2) \
      || exit_code=$?
  else
    claude -p \
      --disallowedTools "$disallowed" \
      --max-turns 200 \
      <<< "$prompt" \
      || exit_code=$?
  fi

  # Clear automation context
  unset REPO_OS_AUTOMATION_ENTRY

  # Outcome detection (with entry_id and stderr for enriched blocker reports)
  local outcome_raw
  outcome_raw=$(detect_outcome "$exit_code" "$baseline_sha" "$REPO_ROOT" "$brief_id" "$stderr_file")

  # Capture solo mode and branch BEFORE cleanup deletes phase-state (audit C1)
  local entry_solo_mode=""
  entry_solo_mode=$(get_solo 2>/dev/null || echo "false")
  local entry_current_branch=""
  entry_current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

  # External cleanup (Stop hook doesn't fire in headless mode)
  if [ -f "$REPO_ROOT/.claude/.session-id" ]; then
    runner_external_cleanup "$REPO_ROOT"
  fi

  # Solo merge + branch seal (audit C1: Decision 0017 requires runners to handle externally)
  local _outcome_type="${outcome_raw%%:*}"
  if [ "$_outcome_type" = "completed" ] && [ "$entry_solo_mode" = "true" ] && [ -n "$entry_current_branch" ]; then
    case "$entry_current_branch" in
      feature/*|fix/*|hotfix/*)
        local _merge_ok=false
        if git checkout main 2>/dev/null; then
          if git merge --ff-only "$entry_current_branch" 2>/dev/null; then
            _merge_ok=true
          fi
        fi
        if [ "$_merge_ok" = true ]; then
          record_closed_branch "$entry_current_branch"
          echo "Solo merge: $entry_current_branch → main (success)" >&2
          # Advisory push to remote (skip template mode and no-remote)
          local _repo_mode_file="$REPO_ROOT/.claude/repo-mode"
          local _is_template=false
          [ -f "$_repo_mode_file" ] && grep -q "template" "$_repo_mode_file" 2>/dev/null && _is_template=true
          if [ "$_is_template" = false ] && git remote get-url origin >/dev/null 2>&1; then
            if ! git push origin main >/dev/null 2>&1; then
              echo "Advisory: push to origin failed — run 'git push origin main' manually" >&2
            fi
          fi
        else
          git merge --abort 2>/dev/null || true
          git checkout "$entry_current_branch" 2>/dev/null || true
          echo "WARNING: Solo merge of '$entry_current_branch' into main failed — branch left open for manual resolution" >&2
        fi
        ;;
      *)
        # Not a solo-mergeable branch type — seal only
        record_closed_branch "$entry_current_branch"
        ;;
    esac
  elif [ -n "$entry_current_branch" ] && [ "$entry_current_branch" != "main" ]; then
    # Non-solo or failed outcome — still seal the branch
    record_closed_branch "$entry_current_branch"
  fi

  # Clean up stderr temp file
  [ -n "$stderr_file" ] && rm -f "$stderr_file" 2>/dev/null || true

  # Output result summary to stderr (stdout reserved for outcome)
  local outcome="${outcome_raw%%:*}"
  local outcome_detail="${outcome_raw#*:}"
  echo "outcome: $outcome" >&2
  echo "outcome_detail: $outcome_detail" >&2
  echo "exit_code: $exit_code" >&2
  echo "baseline_sha: $baseline_sha" >&2
  echo "branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)" >&2

  # Return outcome and baseline on stdout for caller (pipe-delimited)
  printf '%s|%s' "$outcome_raw" "$baseline_sha"
}

# ============================================================
# Single-shot mode (backward compatible with Brief 2)
# ============================================================

if [ "$DAEMON_MODE" = false ]; then
  # Validate session type
  VALID_PHASES=$(get_phases_for_type "$SESSION_TYPE")
  if [ -z "$VALID_PHASES" ]; then
    echo "ERROR: Unknown session type: $SESSION_TYPE" >&2
    exit 1
  fi

  # Config enabled check
  RUNNER_ENABLED=$(_parse_config_field "runner" "enabled")
  if [ -z "$RUNNER_ENABLED" ]; then
    echo "ERROR: Could not parse runner.enabled from config" >&2
    exit 1
  fi
  if [ "$RUNNER_ENABLED" != "true" ]; then
    echo "Runner disabled (enabled: $RUNNER_ENABLED). Exiting." >&2
    exit 0
  fi

  # HALT file check
  if [ -f "$AUTOMATION_DIR/HALT" ]; then
    echo "HALT file present. Runner stopped." >&2
    exit 0
  fi

  # Build prompt (single-shot uses a minimal prompt)
  PROMPT="You are working on brief: $BRIEF_ID. Read the task brief and execute it."

  # Execute
  RESULT_RAW=$(_run_single_entry "$BRIEF_ID" "$PROMPT" "$SESSION_TYPE" "$EXISTING_BRANCH")
  OUTCOME_RAW="${RESULT_RAW%%|*}"
  OUTCOME="${OUTCOME_RAW%%:*}"

  case "$OUTCOME" in
    completed) exit 0 ;;
    review)    exit 2 ;;
    failed)    exit 1 ;;
    *)         exit 1 ;;
  esac
fi

# ============================================================
# Daemon mode — queue-driven loop
# ============================================================

echo "Runner daemon starting (pid $$)..." >&2

_ensure_queue_dirs

# Pre-flight: same-filesystem check (one-time at startup)
_check_same_filesystem

# Cleanup tracking — run cleanup every N idle cycles
_IDLE_CYCLE_COUNT=0
_CLEANUP_INTERVAL=10  # Run cleanup every 10 idle cycles

while true; do
  # --- HALT file check ---
  if [ -f "$AUTOMATION_DIR/HALT" ]; then
    echo "HALT file present. Runner stopped." >&2
    exit 0
  fi

  # --- Config reload (live toggle support) ---
  RUNNER_ENABLED=$(_parse_config_field "runner" "enabled")
  if [ "$RUNNER_ENABLED" != "true" ]; then
    echo "Runner disabled. Sleeping 30s..." >&2
    sleep 30
    continue
  fi

  # --- Stale lock check ---
  if ! _check_stale_locks; then
    echo "Stale lock detected. Breaking loop for investigation." >&2
    break
  fi

  # --- Circuit breaker check ---
  if _circuit_breaker_tripped; then
    echo "Circuit breaker tripped (3 consecutive failures). Sleeping 60s..." >&2
    sleep 60
    continue
  fi

  # --- Dequeue oldest approved entry (locked) ---
  ENTRY_FILE=""
  if acquire_queue_lock; then
    ENTRY_FILE=$(queue_dequeue) || true
    release_queue_lock
  else
    echo "WARNING: Queue lock unavailable, retrying next cycle" >&2
    sleep 5
    continue
  fi
  if [ -z "$ENTRY_FILE" ]; then
    # Idle cycle — periodic cleanup
    _IDLE_CYCLE_COUNT=$((_IDLE_CYCLE_COUNT + 1))
    if [ "$_IDLE_CYCLE_COUNT" -ge "$_CLEANUP_INTERVAL" ]; then
      run_cleanup
      _IDLE_CYCLE_COUNT=0
    fi
    sleep 10
    continue
  fi

  # Reset idle counter on activity
  _IDLE_CYCLE_COUNT=0

  # Load entry metadata
  _load_queue_entry "$ENTRY_FILE"
  ENTRY_ID="$_QE_ID"
  ENTRY_SESSION_TYPE="$_QE_SESSION_TYPE"
  ENTRY_BRANCH="$_QE_BRANCH"
  ENTRY_BRIEF_PATH="$_QE_BRIEF_PATH"
  ENTRY_WORK_ORDER_ID="$_QE_WORK_ORDER_ID"

  echo "Processing entry: $ENTRY_ID (type: $ENTRY_SESSION_TYPE)" >&2

  # Validate session type
  if [ -z "$(get_phases_for_type "$ENTRY_SESSION_TYPE" 2>/dev/null)" ]; then
    echo "ERROR: Invalid session type '$ENTRY_SESSION_TYPE' for entry $ENTRY_ID" >&2
    acquire_queue_lock || true
    queue_block "$ENTRY_ID" "Invalid session type: $ENTRY_SESSION_TYPE"
    release_queue_lock
    continue
  fi

  # --- Assemble prompt (lazy generation at dequeue time) ---
  PROMPT=$(assemble_prompt "$ENTRY_FILE")

  # --- Start heartbeat ---
  _start_heartbeat "$ENTRY_ID"

  # --- Execute ---
  RESULT_RAW=""
  RESULT_RAW=$(_run_single_entry "$ENTRY_ID" "$PROMPT" "$ENTRY_SESSION_TYPE" "$ENTRY_BRANCH") || true

  # --- Stop heartbeat ---
  _stop_heartbeat
  # Clean up heartbeat file
  rm -f "$(_queue_dir)/running/${ENTRY_ID}.heartbeat" 2>/dev/null || true

  # --- Parse outcome and baseline SHA ---
  OUTCOME_RAW="${RESULT_RAW%%|*}"
  BASELINE_SHA="${RESULT_RAW#*|}"
  OUTCOME="${OUTCOME_RAW%%:*}"
  echo "Entry $ENTRY_ID outcome: $OUTCOME_RAW" >&2

  # --- Queue state transition based on outcome ---
  # Lock is best-effort here: entry must transition out of running/ regardless,
  # so a lock failure degrades to unlocked transition (better than orphan entry).
  acquire_queue_lock || echo "WARNING: Lock unavailable for outcome transition" >&2
  case "$OUTCOME" in
    completed)
      queue_complete "$ENTRY_ID"
      ;;
    review)
      queue_escalate "$ENTRY_ID"
      ;;
    failed)
      queue_fail "$ENTRY_ID"
      ;;
    *)
      queue_fail "$ENTRY_ID"
      ;;
  esac
  release_queue_lock

  # --- Post-transition actions (outside lock scope) ---
  # Reset work order status tracker (top-level code — no `local`)
  _wo_new_status=""

  case "$OUTCOME" in
    completed)
      _circuit_breaker_reset

      # Review log + work order lifecycle
      if [ -n "$ENTRY_WORK_ORDER_ID" ]; then
        review_log_append "entry-completed" "$ENTRY_WORK_ORDER_ID" "$ENTRY_ID" \
          "Entry $ENTRY_ID completed ($ENTRY_SESSION_TYPE)" 2>/dev/null || true
        _wo_new_status=$(wo_check_completion "$ENTRY_WORK_ORDER_ID" 2>/dev/null) || true
        case "$_wo_new_status" in
          completed)
            review_log_append "work-order-completed" "$ENTRY_WORK_ORDER_ID" "" \
              "Work order $ENTRY_WORK_ORDER_ID completed — all children done" 2>/dev/null || true
            ;;
          escalated)
            review_log_append "work-order-escalated" "$ENTRY_WORK_ORDER_ID" "" \
              "Work order $ENTRY_WORK_ORDER_ID escalated — child failure detected" 2>/dev/null || true
            ;;
        esac
      fi

      # Cohesion triggers (all session types)
      check_cohesion_triggers "$ENTRY_ID" "$ENTRY_SESSION_TYPE" \
        "$BASELINE_SHA" "$ENTRY_BRIEF_PATH" "$ENTRY_BRANCH" \
        "$ENTRY_WORK_ORDER_ID" || true

      # Drift detection (task group sessions only)
      if [ "$ENTRY_SESSION_TYPE" = "taskgroup" ]; then
        _drift_group=""
        if [ -n "$ENTRY_BRIEF_PATH" ]; then
          _drift_group=$(_extract_group_name "$ENTRY_BRIEF_PATH") || true
        fi
        run_drift_detection "$ENTRY_ID" "$PROMPT" "$BASELINE_SHA" "$_drift_group" "" || true
      fi
      ;;
    review)
      # Escalations are operator-directed — do not count as failures
      # Review log + work order lifecycle
      if [ -n "$ENTRY_WORK_ORDER_ID" ]; then
        review_log_append "entry-escalated" "$ENTRY_WORK_ORDER_ID" "$ENTRY_ID" \
          "Entry $ENTRY_ID escalated ($ENTRY_SESSION_TYPE)" 2>/dev/null || true
        _wo_new_status=$(wo_check_completion "$ENTRY_WORK_ORDER_ID" 2>/dev/null) || true
        case "$_wo_new_status" in
          escalated)
            review_log_append "work-order-escalated" "$ENTRY_WORK_ORDER_ID" "" \
              "Work order $ENTRY_WORK_ORDER_ID escalated — entry requires review" 2>/dev/null || true
            ;;
        esac
      fi
      ;;
    failed|*)
      _circuit_breaker_increment

      # Review log + work order lifecycle (only on terminal failure — retries exhausted)
      # Detect terminal failure by checking if queue_fail moved the entry to failed/
      if [ -n "$ENTRY_WORK_ORDER_ID" ]; then
        if [ -f "$(_queue_dir)/failed/${ENTRY_ID}.yaml" ]; then
          review_log_append "entry-failed" "$ENTRY_WORK_ORDER_ID" "$ENTRY_ID" \
            "Entry $ENTRY_ID failed — retries exhausted ($ENTRY_SESSION_TYPE)" 2>/dev/null || true
          _wo_new_status=$(wo_check_completion "$ENTRY_WORK_ORDER_ID" 2>/dev/null) || true
          case "$_wo_new_status" in
            escalated)
              review_log_append "work-order-escalated" "$ENTRY_WORK_ORDER_ID" "" \
                "Work order $ENTRY_WORK_ORDER_ID escalated — entry failed" 2>/dev/null || true
              ;;
          esac
        fi
      fi
      ;;
  esac

  # Brief pause between entries
  sleep 5
done
