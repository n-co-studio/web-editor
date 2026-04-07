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
# shellcheck source=lib/health-check.sh
source "$LIB_DIR/health-check.sh"
# shellcheck source=lib/remediation-trigger.sh
source "$LIB_DIR/remediation-trigger.sh"

# --- Runner merge lock helpers (Decision 0030 — worktree merge serialization) ---
_RUNNER_MERGE_LOCK_FD=7
_RUNNER_MERGE_LOCK_HELD=false
_RUNNER_MERGE_LOCK_PATH=""

_acquire_runner_merge_lock() {
  local lock_path="$1"
  _RUNNER_MERGE_LOCK_PATH="$lock_path"
  mkdir -p "$(dirname "$lock_path")" 2>/dev/null || true

  # Bounded retry: 3 attempts × 10s before fail-closed (C3 isolation patch)
  local retry=0
  while [ "$retry" -lt 3 ]; do
    retry=$((retry + 1))
    local _acquired=false

    if command -v flock > /dev/null 2>&1; then
      eval "exec ${_RUNNER_MERGE_LOCK_FD}>\"$lock_path\""
      if flock -n -x "$_RUNNER_MERGE_LOCK_FD" 2>/dev/null; then
        _acquired=true
      fi
    else
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
      _RUNNER_MERGE_LOCK_HELD=true
      return 0
    fi

    if [ "$retry" -lt 3 ]; then
      echo "WARNING: Runner merge lock attempt $retry/3 failed — retrying in 10s" >&2
      sleep 10
    fi
  done

  # Fail-closed: all 3 attempts exhausted
  echo "ERROR: Runner merge lock timeout (3 attempts × 10s) — fail-closed, merge blocked" >&2
  return 1
}

_release_runner_merge_lock() {
  if [ "$_RUNNER_MERGE_LOCK_HELD" = true ] && [ -n "$_RUNNER_MERGE_LOCK_PATH" ]; then
    if command -v flock > /dev/null 2>&1; then
      eval "exec ${_RUNNER_MERGE_LOCK_FD}>&-" 2>/dev/null || true
    else
      rm -rf "${_RUNNER_MERGE_LOCK_PATH}.dir" 2>/dev/null || true
    fi
    _RUNNER_MERGE_LOCK_HELD=false
  fi
}

# --- Config files ---
CONFIG_FILE="$AUTOMATION_DIR/config.yaml"
CONFIG_LOCAL_FILE="$AUTOMATION_DIR/config.local.yaml"

# --- Heartbeat state ---
_HEARTBEAT_PID=""

# --- Child process tracking (for FORCE-HALT) ---
_CLAUDE_CHILD_PID=""

# --- Worktree tracking (for cleanup on crash/FORCE-HALT) ---
_CURRENT_WORKTREE_DIR=""

# --- Daemon lifecycle state ---
_SHUTDOWN_REQUESTED=false
_DAEMON_START_EPOCH=""
_SESSIONS_COMPLETED=0
_SESSIONS_FAILED=0
_LAST_SESSION_AT="never"
_CURRENT_ENTRY_ID=""
_CONSECUTIVE_SESSION_COUNT=0

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

# Bootstrap config.local.yaml if absent — ensures the daemon's runtime toggle
# uses the gitignored override file so the tracked config.yaml is never
# modified at runtime (Decision 0017).
if [ ! -f "$CONFIG_LOCAL_FILE" ]; then
  printf 'runner:\n  enabled: true\n' > "$CONFIG_LOCAL_FILE"
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
      # Also update the health file to keep it current during long sessions
      _write_health "running" 2>/dev/null || true
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

# --- Crash cleanup handler (audit 2.2/3.1/3.3) ---
# On any exit (success, failure, SIGTERM), clean up session state, heartbeat
# files, and the session registry. Without this, runner crashes leave orphaned
# state files that block new sessions.
_runner_crash_cleanup() {
  # Clean heartbeat files (3.3: survive EXIT trap)
  local _qdir
  _qdir=$(_queue_dir 2>/dev/null) || true
  if [ -n "$_qdir" ] && [ -d "$_qdir/running" ]; then
    rm -f "$_qdir/running/"*.heartbeat 2>/dev/null || true
  fi
  # Clean up worktree if one was created (Decision 0033)
  if [ -n "$_CURRENT_WORKTREE_DIR" ] && [ -d "$_CURRENT_WORKTREE_DIR" ]; then
    git worktree remove --force "$_CURRENT_WORKTREE_DIR" 2>/dev/null || true
    git worktree prune 2>/dev/null || true
    _CURRENT_WORKTREE_DIR=""
  fi
  # Clean session state (3.1: runner_external_cleanup on crash)
  # With REPO_OS_SESSION_ID set, cleanup targets the per-session state dir.
  # Without it (legacy), fall back to .session-id file check.
  if [ -n "${REPO_ROOT:-}" ]; then
    if [ -n "${REPO_OS_SESSION_ID:-}" ] || [ -f "$REPO_ROOT/.claude/.session-id" ]; then
      runner_external_cleanup "$REPO_ROOT" "${_CURRENT_ENTRY_ID:-}" "crash" "${_RESULT_BASELINE:-}" 2>/dev/null || true
    fi
  fi
}

# Clean up on exit (guard each function to prevent cascade under set -euo pipefail)
trap '_stop_heartbeat || true; _runner_crash_cleanup || true' EXIT

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

# Health check functions sourced from lib/health-check.sh above.
# Provides: _health_file, _write_health, _remove_health, health_status, health_is_alive

# ============================================================
# Startup crash recovery — detect and clean orphaned state
# ============================================================

_startup_crash_recovery() {
  local recovered=0

  # 1. Stale health file — prior daemon crashed without cleanup
  local hf
  hf=$(_health_file)
  if [ -f "$hf" ]; then
    local old_pid
    old_pid=$(grep '^pid:' "$hf" 2>/dev/null | sed 's/.*: *//' | tr -d '[:space:]' | head -1)
    if [ -n "$old_pid" ] && ! kill -0 "$old_pid" 2>/dev/null; then
      echo "Startup recovery: stale health file from dead pid $old_pid — removing" >&2
      rm -f "$hf" 2>/dev/null || true
      recovered=$((recovered + 1))
    elif [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
      # Another daemon is still running — this shouldn't happen (PID guard catches it)
      echo "WARNING: Health file shows pid $old_pid is still running — aborting startup recovery" >&2
      return 0
    fi
  fi

  # 2. Orphaned running/ entries — no heartbeat or stale heartbeat with dead PID
  local qdir
  qdir=$(_queue_dir)
  if [ -d "$qdir/running" ]; then
    local entry_file
    for entry_file in "$qdir/running"/*.yaml; do
      [ -f "$entry_file" ] || continue
      local entry_id
      entry_id=$(basename "$entry_file" .yaml)
      local hb_file="$qdir/running/${entry_id}.heartbeat"

      # Determine if entry is truly orphaned or legitimately running
      local should_recover=false
      if [ ! -f "$hb_file" ]; then
        # No heartbeat at all — definitely orphaned
        should_recover=true
      else
        # Heartbeat exists — check if the writing process is still alive.
        # At startup, no heartbeat writer from THIS daemon exists yet,
        # so a fresh heartbeat implies another process wrote it.
        local hb_ts_raw
        hb_ts_raw=$(cat "$hb_file" 2>/dev/null || true)
        if [ -z "$hb_ts_raw" ]; then
          should_recover=true
        else
          local hb_epoch_sr now_epoch_sr hb_age_sr
          hb_epoch_sr=$(_iso_to_epoch "$hb_ts_raw" 2>/dev/null || echo "0")
          now_epoch_sr=$(date +%s)
          hb_age_sr=$((now_epoch_sr - hb_epoch_sr))
          # If heartbeat is older than 1 hour, the writer is dead
          if [ "$hb_age_sr" -gt 3600 ]; then
            should_recover=true
          else
            # Recent heartbeat with no live daemon — fail-closed: write escalation
            echo "WARNING: Running entry $entry_id has recent heartbeat (${hb_age_sr}s old) — writing escalation instead of recovering" >&2
            local esc_dir_ambig="$REPO_ROOT/.claude/.automation/escalations"
            mkdir -p "$esc_dir_ambig" 2>/dev/null || true
            local esc_id_ambig="esc-ambiguous-$(date +%Y%m%d-%H%M%S)"
            {
              printf 'escalation:\n'
              printf '  id: "%s"\n' "$esc_id_ambig"
              printf '  queue_entry_id: "%s"\n' "$entry_id"
              printf '  type: "gate-failure"\n'
              printf '  severity: "blocking"\n'
              printf '  phase_at_exit: "init"\n'
              printf '  tag_at_exit: "agent"\n'
              printf '  message: "Ambiguous state: running entry has recent heartbeat (%ss) but no live daemon PID"\n' "$hb_age_sr"
              printf '  context: "entry_id: %s, heartbeat_age: %ss"\n' "$entry_id" "$hb_age_sr"
              printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
              printf '  resolved: false\n'
              printf '  resolution: ""\n'
            } > "$esc_dir_ambig/${esc_id_ambig}.yaml" 2>/dev/null || true
            should_recover=false
          fi
        fi
      fi

      if [ "$should_recover" = true ]; then
        echo "Startup recovery: orphaned running entry $entry_id — transitioning to failed" >&2
        if acquire_queue_lock; then
          _load_queue_entry "$entry_file"
          _QE_STATUS="failed"
          _QE_ERROR_LOG="orphaned entry — recovered at daemon startup"
          _QE_COMPLETED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
          _QE_UPDATED_AT="$_QE_COMPLETED_AT"
          _write_queue_entry "$qdir/failed/${entry_id}.yaml"
          rm -f "$entry_file"
          rm -f "$hb_file" 2>/dev/null || true
          # Propagate failure to work order if entry belongs to one
          if [ -n "$_QE_WORK_ORDER_ID" ]; then
            _sr_wo_status=$(wo_check_completion "$_QE_WORK_ORDER_ID" 2>/dev/null) || true
            case "$_sr_wo_status" in
              failed)
                review_log_append "work-order-failed" "$_QE_WORK_ORDER_ID" "" \
                  "Work order $_QE_WORK_ORDER_ID failed — orphaned entry $entry_id recovered at startup. Recovery: queue-cli.sh reopen-wo $_QE_WORK_ORDER_ID" 2>/dev/null || true
                ;;
              escalated)
                review_log_append "work-order-escalated" "$_QE_WORK_ORDER_ID" "" \
                  "Work order $_QE_WORK_ORDER_ID escalated — orphaned entry $entry_id recovered at startup. Recovery: queue-cli.sh reopen-wo $_QE_WORK_ORDER_ID" 2>/dev/null || true
                ;;
            esac
          fi
          _rebuild_queue_index || true
          release_queue_lock
          recovered=$((recovered + 1))
        else
          echo "WARNING: Could not acquire lock for startup recovery of $entry_id — writing escalation" >&2
          local esc_dir="$REPO_ROOT/.claude/.automation/escalations"
          mkdir -p "$esc_dir" 2>/dev/null || true
          local esc_id="esc-startup-$(date +%Y%m%d-%H%M%S)"
          {
            printf 'escalation:\n'
            printf '  id: "%s"\n' "$esc_id"
            printf '  queue_entry_id: "%s"\n' "$entry_id"
            printf '  type: "gate-failure"\n'
            printf '  severity: "blocking"\n'
            printf '  phase_at_exit: "init"\n'
            printf '  tag_at_exit: "agent"\n'
            printf '  message: "Startup crash recovery could not acquire queue lock for orphaned entry"\n'
            printf '  context: "entry_id: %s, lock_file: %s"\n' "$entry_id" "$qdir/.queue-lock"
            printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf '  resolved: false\n'
            printf '  resolution: ""\n'
          } > "$esc_dir/${esc_id}.yaml" 2>/dev/null || true
        fi
      fi
    done
  fi

  # 3. Stale lock file — queue lock with no holder
  local lock_file="$qdir/.queue-lock"
  if [ -f "$lock_file" ]; then
    # flock-based locks are released on process death, but the file may remain
    # Try to acquire and immediately release to verify it's not stuck
    if acquire_queue_lock 2>/dev/null; then
      release_queue_lock
    else
      echo "WARNING: Stale queue lock detected at startup — cannot acquire" >&2
      echo "Investigate $lock_file before proceeding" >&2
    fi
  fi

  # 4. Orphaned session state
  local session_id_file="$REPO_ROOT/.claude/.session-id"
  if [ -f "$session_id_file" ]; then
    echo "Startup recovery: orphaned session-id file — running external cleanup" >&2
    runner_external_cleanup "$REPO_ROOT" "" "startup-recovery" 2>/dev/null || true
    recovered=$((recovered + 1))
  fi

  # 5. Sweep stale session registry entries (C7 orphan TTL patch)
  # Runs after step 4 to catch orphaned sessions with exceeded TTL.
  sweep_stale_sessions || true

  if [ "$recovered" -gt 0 ]; then
    echo "Startup recovery complete: $recovered item(s) recovered" >&2
  fi
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

    # Parse ISO 8601 to epoch (portable via _iso_to_epoch from _analytics-helper.sh)
    local hb_epoch now_epoch age_hours
    hb_epoch=$(_iso_to_epoch "$hb_ts" 2>/dev/null)
    [ -z "$hb_epoch" ] && hb_epoch=0
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
# Task group branch seal guard (Decision 0013)
# ============================================================
# Determines whether an entry is the final entry in a task group work order.
# Non-final entries must NOT have their branch sealed (recorded in closed-branches).
# Fail-open: on error, returns 0 (seal the branch — safe default).
#
# Arguments:
#   $1 — brief_id (queue entry ID)
#   $2 — work_order_id (empty for non-task-group entries)
# Returns: 0 if this is the final entry (seal OK), 1 if siblings remain (don't seal)
_is_final_taskgroup_entry() {
  local brief_id="$1"
  local work_order_id="${2:-}"

  # No work order → not a task group entry → seal normally
  if [ -z "$work_order_id" ]; then
    return 0
  fi

  # Load work order — fail-open on error
  local wo_file="$(_queue_dir)/work-orders/${work_order_id}.yaml"
  _load_work_order "$wo_file" 2>/dev/null || return 0

  # Check if any sibling entries remain in pending/approved status
  if [ -z "$_WO_ENTRY_IDS" ]; then
    return 0
  fi

  local _eid _old_ifs="$IFS"
  IFS=','
  # shellcheck disable=SC2086 — intentional word splitting on comma-delimited list
  set -- $_WO_ENTRY_IDS
  IFS="$_old_ifs"
  for _eid in "$@"; do
    # Skip self
    [ "$_eid" = "$brief_id" ] && continue
    local entry_file
    entry_file=$(_find_entry_file "$_eid") || true
    if [ -z "$entry_file" ]; then
      continue
    fi
    _load_queue_entry "$entry_file" 2>/dev/null || continue
    case "$_QE_STATUS" in
      pending-review|approved)
        # Sibling still pending — don't seal
        return 1
        ;;
    esac
  done

  # No pending/approved siblings remain — this is the final entry
  return 0
}

# ============================================================
# ============================================================
# Model routing — resolve CLI --model flag for claude -p
# ============================================================

# Maps config model names to Claude CLI model IDs.
# Returns the --model flag value for a given session type.
# Precedence: model_routing_overrides[session_type] → model_routing.default → "".
# Empty return means no --model flag (use CLI default).
_resolve_model_for_session() {
  local session_type="$1"
  local model=""

  # Check model_routing_overrides for this session type.
  # _parse_config_field handles local → tracked fallback.
  # model_routing_overrides is a top-level block (not nested under model_routing)
  # because _parse_config_field requires column-0 keys for its sed range pattern.
  model=$(_parse_config_field "model_routing_overrides" "$session_type")

  # Fall back to model_routing.default
  if [ -z "$model" ]; then
    model=$(_parse_config_field "model_routing" "default")
  fi

  # Map config names to CLI model IDs
  case "$model" in
    sonnet) printf '%s' "claude-sonnet-4-6" ;;
    haiku)  printf '%s' "claude-haiku-4-5-20251001" ;;
    "")     printf '' ;;  # no model flag — use CLI default
    *)      printf '%s' "$model" ;;  # pass through unknown values as-is
  esac
}

# ============================================================
# Core execution — run a single entry (used by both modes)
# ============================================================

# --- Global return variables (eliminates subshell stdout loss) ---
# Set by _run_single_entry, read by caller. No subshell = no lost output.
_RESULT_OUTCOME=""
_RESULT_BASELINE=""
_RESULT_SOLO_MODE=""
_RESULT_BRANCH=""

# Arguments:
#   $1 — brief_id (for branch naming)
#   $2 — prompt (assembled prompt text)
#   $3 — session_type (Decision 0014 enum)
#   $4 — existing_branch (optional, for task group)
#   $5 — permission_profile (optional, default: "build")
#   $6 — push_on_complete (optional, default: "false")
# Sets globals: _RESULT_OUTCOME, _RESULT_BASELINE, _RESULT_SOLO_MODE, _RESULT_BRANCH
_run_single_entry() {
  local brief_id="$1"
  local prompt="$2"
  local session_type="$3"
  local existing_branch="${4:-}"
  local permission_profile="${5:-build}"
  local push_on_complete="${6:-false}"

  # Reset globals
  _RESULT_OUTCOME=""
  _RESULT_BASELINE=""
  _RESULT_SOLO_MODE=""
  _RESULT_BRANCH=""

  # Generate per-session ID for state directory isolation (prevents daemon
  # sessions from overwriting interactive session phase-state). Exported so
  # hooks in the claude -p child process route state to wt-sessions/{id}/.
  if [ -n "${EPOCHREALTIME:-}" ]; then
    local _frac="${EPOCHREALTIME#*.}"
    export REPO_OS_SESSION_ID="daemon-$(date +%Y%m%d-%H%M%S)-${_frac:0:4}"
  else
    export REPO_OS_SESSION_ID="daemon-$(date +%Y%m%d-%H%M%S)-$$"
  fi

  # Pre-launch setup
  state_manager_setup "$REPO_ROOT" "$session_type"

  # Branch setup — sets _SETUP_BRANCH; when worktree-isolate active, does NOT checkout
  branch_manager_setup "$brief_id" "$existing_branch"

  # Record baseline SHA — when worktree-isolate active, HEAD is still main,
  # so use the branch ref directly
  if [ "${REPO_OS_WORKTREE_ISOLATE:-1}" != "0" ] && [ -n "$_SETUP_BRANCH" ]; then
    _RESULT_BASELINE=$(git rev-parse "$_SETUP_BRANCH")
  else
    _RESULT_BASELINE=$(git rev-parse HEAD)
  fi

  # Set automation context for analytics hooks (inherited by claude -p child)
  export REPO_OS_AUTOMATION_ENTRY="$brief_id"
  # Set headless flag for hooks. Consumed by:
  #   ask-user-deny.sh — blocks AskUserQuestion
  #   pre-commit-gates.sh — adjusts GATE-RECOVERABLE messages, writes A1 escalation
  #   permission-request.sh — denies fall-through (fail-closed)
  export CLAUDE_HEADLESS=1

  # Resolve permission profile to --disallowedTools string
  local disallowed
  disallowed=$(get_disallowed_tools "$permission_profile")

  # Capture stderr to temp file for blocker reports
  local stderr_file
  stderr_file=$(mktemp "${TMPDIR:-/tmp}/runner-stderr-XXXXXX" 2>/dev/null || echo "")

  # Resolve model for this session type (model routing — Decision 0017)
  local model_id
  model_id=$(_resolve_model_for_session "$session_type")
  local model_flag=""
  if [ -n "$model_id" ]; then
    model_flag="--model $model_id"
  fi

  # Launch headless session
  # Trust model for headless execution:
  #   --permission-mode bypassPermissions — required because PermissionRequest
  #   hooks do NOT fire in `claude -p` mode (Anthropic SDK documented limitation).
  #   Without bypass, every tool call would block on an unattended permission dialog.
  #
  #   Three-layer compensating defense:
  #     1. --disallowedTools — CLI-level deny list (primary gate, prevents tool
  #        invocation entirely for blocked tools)
  #     2. PreToolUse hooks (pretooluse-permission.sh) — belt-and-suspenders deny
  #        list + headless fail-closed for unknown commands
  #     3. Governance gates (pre-commit-gates.sh, pre-push-gates.sh, bash-guard.sh,
  #        write-guard.sh) — enforce phase model, secret scanning, branch isolation
  #
  #   REVISIT: check PermissionRequest hook behavior at each Anthropic SDK upgrade.
  #   If PermissionRequest hooks begin firing in -p mode, consider switching from
  #   bypassPermissions to a permission-request-based allow/deny model.

  # Worktree isolation (Decision 0033): create a worktree targeting the feature
  # branch so the session runs in isolation. Manual git worktree add is used
  # instead of --worktree flag because --worktree creates from the invoking
  # process's HEAD (main), not the target branch.
  local launch_dir="$REPO_ROOT"
  if [ "${REPO_OS_WORKTREE_ISOLATE:-1}" != "0" ] && [ -n "$_SETUP_BRANCH" ]; then
    local worktree_dir="${REPO_ROOT}/.worktrees/${REPO_OS_SESSION_ID}"
    if git worktree add "$worktree_dir" "$_SETUP_BRANCH" 2>/dev/null; then
      _CURRENT_WORKTREE_DIR="$worktree_dir"
      launch_dir="$worktree_dir"
    else
      echo "ERROR: Failed to create worktree at $worktree_dir for branch $_SETUP_BRANCH" >&2
      _RESULT_OUTCOME="failed:worktree-creation"
      unset REPO_OS_AUTOMATION_ENTRY
      unset CLAUDE_HEADLESS
      [ -n "$stderr_file" ] && rm -f "$stderr_file" 2>/dev/null || true
      # Clean up state initialized by state_manager_setup before early return
      runner_external_cleanup "$REPO_ROOT" "$brief_id" "close" "$_RESULT_BASELINE" 2>/dev/null || true
      unset REPO_OS_SESSION_ID
      return
    fi
  fi

  # Launch headless session in background to enable FORCE-HALT child kill.
  # SIGTERM deferral: when the daemon receives SIGTERM, the trap sets
  # _SHUTDOWN_REQUESTED=true and `wait` is interrupted (returns 128+signum).
  # The child may still be running — re-wait until it exits naturally.
  # This prevents SIGTERM from killing sessions during close phase output.

  # Session TTL guard (session_max_ttl_seconds: 0 = disabled, default 21600).
  # A background watchdog sends SIGTERM to the child after the TTL expires.
  # The wait-loop check provides belt-and-suspenders enforcement on each
  # SIGTERM-interrupted iteration. Exit code 143 is handled by outcome-detector.
  local _session_max_ttl
  _session_max_ttl=$(_parse_config_field "runner" "session_max_ttl_seconds" 2>/dev/null || echo "21600")
  _session_max_ttl="${_session_max_ttl:-21600}"
  local _session_launch_epoch
  _session_launch_epoch=$(date +%s)
  local _ttl_watchdog_pid=""

  local exit_code=0
  if [ -n "$stderr_file" ]; then
    # shellcheck disable=SC2086 — $model_flag intentionally unquoted (expands to nothing when empty)
    (cd "$launch_dir" && claude -p \
      --permission-mode bypassPermissions \
      --disallowedTools "$disallowed" \
      --max-turns 200 \
      $model_flag \
      <<< "$prompt" \
      2> >(tee "$stderr_file" >&2)) &
    _CLAUDE_CHILD_PID=$!
    # Start TTL watchdog: kills child directly after TTL seconds
    if [ "$_session_max_ttl" -gt 0 ]; then
      local _child_pid_capture="$_CLAUDE_CHILD_PID"
      ( sleep "$_session_max_ttl"
        if kill -0 "$_child_pid_capture" 2>/dev/null; then
          echo "Session exceeded TTL (${_session_max_ttl}s) — sending SIGTERM to child pid ${_child_pid_capture}" >&2
          kill -TERM "$_child_pid_capture" 2>/dev/null || true
        fi ) &
      _ttl_watchdog_pid=$!
    fi
    wait "$_CLAUDE_CHILD_PID" || exit_code=$?
    # Re-wait if child is still alive (SIGTERM interrupted wait, not child)
    while [ "$exit_code" -ne 0 ] && kill -0 "$_CLAUDE_CHILD_PID" 2>/dev/null; do
      # TTL belt-and-suspenders: send SIGTERM if elapsed exceeds threshold
      if [ "$_session_max_ttl" -gt 0 ]; then
        local _now_epoch _elapsed
        _now_epoch=$(date +%s)
        _elapsed=$(( _now_epoch - _session_launch_epoch ))
        if [ "$_elapsed" -gt "$_session_max_ttl" ]; then
          echo "Session exceeded TTL (${_session_max_ttl}s, elapsed ${_elapsed}s) — sending SIGTERM to child pid $_CLAUDE_CHILD_PID" >&2
          kill -TERM "$_CLAUDE_CHILD_PID" 2>/dev/null || true
        fi
      fi
      echo "SIGTERM deferred: child pid $_CLAUDE_CHILD_PID still running — re-waiting..." >&2
      exit_code=0
      wait "$_CLAUDE_CHILD_PID" || exit_code=$?
    done
  else
    # shellcheck disable=SC2086 — $model_flag intentionally unquoted (expands to nothing when empty)
    (cd "$launch_dir" && claude -p \
      --permission-mode bypassPermissions \
      --disallowedTools "$disallowed" \
      --max-turns 200 \
      $model_flag \
      <<< "$prompt") &
    _CLAUDE_CHILD_PID=$!
    # Start TTL watchdog: kills child directly after TTL seconds
    if [ "$_session_max_ttl" -gt 0 ]; then
      local _child_pid_capture="$_CLAUDE_CHILD_PID"
      ( sleep "$_session_max_ttl"
        if kill -0 "$_child_pid_capture" 2>/dev/null; then
          echo "Session exceeded TTL (${_session_max_ttl}s) — sending SIGTERM to child pid ${_child_pid_capture}" >&2
          kill -TERM "$_child_pid_capture" 2>/dev/null || true
        fi ) &
      _ttl_watchdog_pid=$!
    fi
    wait "$_CLAUDE_CHILD_PID" || exit_code=$?
    # Re-wait if child is still alive (SIGTERM interrupted wait, not child)
    while [ "$exit_code" -ne 0 ] && kill -0 "$_CLAUDE_CHILD_PID" 2>/dev/null; do
      # TTL belt-and-suspenders: send SIGTERM if elapsed exceeds threshold
      if [ "$_session_max_ttl" -gt 0 ]; then
        local _now_epoch _elapsed
        _now_epoch=$(date +%s)
        _elapsed=$(( _now_epoch - _session_launch_epoch ))
        if [ "$_elapsed" -gt "$_session_max_ttl" ]; then
          echo "Session exceeded TTL (${_session_max_ttl}s, elapsed ${_elapsed}s) — sending SIGTERM to child pid $_CLAUDE_CHILD_PID" >&2
          kill -TERM "$_CLAUDE_CHILD_PID" 2>/dev/null || true
        fi
      fi
      echo "SIGTERM deferred: child pid $_CLAUDE_CHILD_PID still running — re-waiting..." >&2
      exit_code=0
      wait "$_CLAUDE_CHILD_PID" || exit_code=$?
    done
  fi
  # Kill TTL watchdog if still running (session completed before TTL fired)
  if [ -n "$_ttl_watchdog_pid" ]; then
    kill "$_ttl_watchdog_pid" 2>/dev/null || true
    wait "$_ttl_watchdog_pid" 2>/dev/null || true
    _ttl_watchdog_pid=""
  fi
  _CLAUDE_CHILD_PID=""

  # Clear automation context (keep REPO_OS_SESSION_ID alive for cleanup)
  unset REPO_OS_AUTOMATION_ENTRY
  unset CLAUDE_HEADLESS

  # Capture solo mode and branch from worktree context BEFORE removal
  # Use _QE_SOLO_MODE global (populated by _load_queue_entry) instead of get_solo()
  # to avoid reading already-cleaned phase-state post-session (Bug fix — solo merge).
  if [ -n "$_CURRENT_WORKTREE_DIR" ] && [ -d "$_CURRENT_WORKTREE_DIR" ]; then
    _RESULT_SOLO_MODE="${_QE_SOLO_MODE:-false}"
    _RESULT_BRANCH=$(git -C "$_CURRENT_WORKTREE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    # Outcome detection from worktree context
    _RESULT_OUTCOME=$(detect_outcome "$exit_code" "$_RESULT_BASELINE" "$_CURRENT_WORKTREE_DIR" "$brief_id" "$stderr_file")
    # Remove worktree
    git worktree remove --force "$_CURRENT_WORKTREE_DIR" 2>/dev/null || true
    git worktree prune 2>/dev/null || true
    _CURRENT_WORKTREE_DIR=""
  else
    # Legacy path or worktree not created
    _RESULT_OUTCOME=$(detect_outcome "$exit_code" "$_RESULT_BASELINE" "$REPO_ROOT" "$brief_id" "$stderr_file")
    _RESULT_SOLO_MODE="${_QE_SOLO_MODE:-false}"
    _RESULT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  fi

  # External cleanup (Stop hook doesn't fire in headless mode)
  # With REPO_OS_SESSION_ID set, cleanup routes to the per-session state dir.
  runner_external_cleanup "$REPO_ROOT" "$brief_id" "close" "$_RESULT_BASELINE"

  # Clear per-session ID after cleanup
  unset REPO_OS_SESSION_ID

  # Clean up stderr temp file
  [ -n "$stderr_file" ] && rm -f "$stderr_file" 2>/dev/null || true

  # Output result summary to stderr (informational only — outcome is in globals)
  local outcome="${_RESULT_OUTCOME%%:*}"
  local outcome_detail="${_RESULT_OUTCOME#*:}"
  echo "outcome: $outcome" >&2
  echo "outcome_detail: $outcome_detail" >&2
  echo "exit_code: $exit_code" >&2
  echo "baseline_sha: $_RESULT_BASELINE" >&2
  echo "branch: $_RESULT_BRANCH" >&2
}

# ============================================================
# Solo merge + branch seal (extracted from _run_single_entry)
# ============================================================
# Called from daemon loop and single-shot mode AFTER _run_single_entry returns.
# Operates on _RESULT_* globals. Runs in the main shell — no subshell loss risk.
#
# Arguments:
#   $1 — entry_current_branch
#   $2 — push_on_complete ("true"/"false")
#   $3 — brief_id (for escalation context)
#   $4 — work_order_id (optional, for task group seal guard — Decision 0013)
# Reads: _RESULT_OUTCOME, _RESULT_SOLO_MODE
# May modify: _RESULT_OUTCOME (on merge conflict → review:merge-conflict)
_solo_merge_if_needed() {
  local entry_current_branch="$1"
  local push_on_complete="${2:-false}"
  local brief_id="${3:-}"
  local work_order_id="${4:-}"

  local _outcome_type="${_RESULT_OUTCOME%%:*}"

  if [ "$_outcome_type" = "completed" ] && [ "$_RESULT_SOLO_MODE" = "true" ] && [ -n "$entry_current_branch" ]; then
    case "$entry_current_branch" in
      feature/*|fix/*|hotfix/*)
        local _merge_ok=false
        local _merge_conflict=false
        local _conflict_files=""
        if is_full_worktree_session; then
          # Worktree merge path (Decision 0030)
          local _main_repo="$REPO_ROOT"
          local _merge_lock="$_main_repo/.claude/.state/.merge-lock"
          if ! _acquire_runner_merge_lock "$_merge_lock"; then
            # Fail-closed (C3): write escalation and skip merge
            local _esc_dir="$REPO_ROOT/.claude/.automation/escalations"
            mkdir -p "$_esc_dir" 2>/dev/null || true
            local _esc_id="esc-merge-lock-$(date +%Y%m%d-%H%M%S)"
            {
              printf 'escalation:\n'
              printf '  id: "%s"\n' "$_esc_id"
              printf '  queue_entry_id: "%s"\n' "$brief_id"
              printf '  type: "gate-failure"\n'
              printf '  severity: "blocking"\n'
              printf '  phase_at_exit: "close"\n'
              printf '  tag_at_exit: "agent"\n'
              printf '  message: "Runner merge lock acquisition failed after 3 attempts — merge blocked (fail-closed)"\n'
              printf '  context: "lock_path: %s, branch: %s"\n' "$_merge_lock" "$entry_current_branch"
              printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
              printf '  resolved: false\n'
              printf '  resolution: ""\n'
            } > "$_esc_dir/${_esc_id}.yaml" 2>/dev/null || true
            echo "ERROR: Runner merge blocked — lock acquisition failed. Escalation: $_esc_id" >&2
            _release_runner_merge_lock
            return 0
          fi
          local _main_br
          _main_br=$(git -C "$_main_repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
          if [ "$_main_br" = "main" ]; then
            if git -C "$_main_repo" merge --ff-only "$entry_current_branch" 2>/dev/null; then
              _merge_ok=true
            elif git -C "$_main_repo" merge --no-ff -m "Merge $entry_current_branch (auto)" "$entry_current_branch" 2>/dev/null; then
              _merge_ok=true
            else
              _merge_conflict=true
              _conflict_files=$(git -C "$_main_repo" diff --name-only --diff-filter=U 2>/dev/null || echo "unknown")
              git -C "$_main_repo" merge --abort 2>/dev/null || true
            fi
          else
            echo "WARNING: Main repo on '$_main_br', not 'main' — skipping worktree merge" >&2
          fi
          _release_runner_merge_lock
        elif git checkout main 2>/dev/null; then
          if git merge --ff-only "$entry_current_branch" 2>/dev/null; then
            _merge_ok=true
          else
            # ff-only failed — try --no-ff merge
            if git merge --no-ff -m "Merge $entry_current_branch (auto)" "$entry_current_branch" 2>/dev/null; then
              _merge_ok=true
            else
              # Merge conflict — capture conflict file list before aborting
              _merge_conflict=true
              _conflict_files=$(git diff --name-only --diff-filter=U 2>/dev/null || echo "unknown")
              git merge --abort 2>/dev/null || true
            fi
          fi
        fi
        if [ "$_merge_ok" = true ]; then
          if _is_final_taskgroup_entry "$brief_id" "$work_order_id"; then
            record_closed_branch "$entry_current_branch"
          fi
          echo "Solo merge: $entry_current_branch → main (success)" >&2
          # Push to remote — push_on_complete or advisory fallback
          local _repo_mode_file="$REPO_ROOT/.claude/repo-mode"
          local _is_template=false
          [ -f "$_repo_mode_file" ] && grep -q "template" "$_repo_mode_file" 2>/dev/null && _is_template=true
          if [ "$push_on_complete" = "true" ] && git remote get-url origin >/dev/null 2>&1; then
            if ! git push -u origin main >/dev/null 2>&1; then
              echo "WARNING: push_on_complete failed — run 'git push origin main' manually" >&2
            fi
          elif [ "$_is_template" = false ] && git remote get-url origin >/dev/null 2>&1; then
            if ! git push origin main >/dev/null 2>&1; then
              echo "Advisory: push to origin failed — run 'git push origin main' manually" >&2
            fi
          fi
        elif [ "$_merge_conflict" = true ]; then
          # Merge conflict — write scope-deviation escalation and transition to review
          git checkout "$entry_current_branch" 2>/dev/null || true
          local _esc_dir="$REPO_ROOT/.claude/.automation/escalations"
          mkdir -p "$_esc_dir" 2>/dev/null || true
          local _esc_id="esc-merge-$(date +%Y%m%d-%H%M%S)"
          local _esc_context
          _esc_context=$(printf '%s' "$_conflict_files" | tr '\n' ',' | sed 's/,$//')
          {
            printf 'escalation:\n'
            printf '  id: "%s"\n' "$_esc_id"
            printf '  queue_entry_id: "%s"\n' "$brief_id"
            printf '  type: "scope-deviation"\n'
            printf '  severity: "blocking"\n'
            printf '  phase_at_exit: "close"\n'
            printf '  tag_at_exit: "agent"\n'
            printf '  message: "Merge conflict during solo merge of %s into main"\n' "$entry_current_branch"
            printf '  context: "conflict_files: %s"\n' "$_esc_context"
            printf '  scope_classification: ""\n'
            printf '  risk_gain:\n'
            printf '    risk: "Branch has diverged from main — manual conflict resolution required"\n'
            printf '    gain: ""\n'
            printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf '  resolved: false\n'
            printf '  resolution: ""\n'
          } > "$_esc_dir/${_esc_id}.yaml" 2>/dev/null || true
          # Override outcome to review so daemon transitions entry correctly
          _RESULT_OUTCOME="review:merge-conflict"
          echo "Solo merge conflict: $entry_current_branch — escalation $_esc_id written, entry → review" >&2
        else
          # Non-conflict failure (e.g., checkout failed) — seal branch (Leak Point 6)
          git merge --abort 2>/dev/null || true
          git checkout "$entry_current_branch" 2>/dev/null || true
          if _is_final_taskgroup_entry "$brief_id" "$work_order_id"; then
            record_closed_branch "$entry_current_branch"
          fi
          echo "WARNING: Solo merge of '$entry_current_branch' into main failed — branch sealed" >&2
        fi
        ;;
      *)
        # Not a solo-mergeable branch type — seal only
        if _is_final_taskgroup_entry "$brief_id" "$work_order_id"; then
          record_closed_branch "$entry_current_branch"
        fi
        ;;
    esac
  elif [ "$_outcome_type" = "completed" ] && [ "$push_on_complete" = "true" ] && [ -n "$entry_current_branch" ] && [ "$entry_current_branch" != "main" ]; then
    # Non-solo completed entry with push_on_complete — push feature branch
    if git remote get-url origin >/dev/null 2>&1; then
      if ! git push -u origin "$entry_current_branch" >/dev/null 2>&1; then
        echo "WARNING: push_on_complete failed for $entry_current_branch — push manually" >&2
      fi
    fi
    if _is_final_taskgroup_entry "$brief_id" "$work_order_id"; then
      record_closed_branch "$entry_current_branch"
    fi
  elif [ -n "$entry_current_branch" ] && [ "$entry_current_branch" != "main" ]; then
    # Non-solo or failed outcome — still seal the branch
    if _is_final_taskgroup_entry "$brief_id" "$work_order_id"; then
      record_closed_branch "$entry_current_branch"
    fi
  fi
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

  # Log entry-started event
  review_log_append "entry-started" "" "$BRIEF_ID" \
    "Entry $BRIEF_ID started (single-shot)" 2>/dev/null || true

  # Execute (direct call — no subshell, outcome in globals)
  _run_single_entry "$BRIEF_ID" "$PROMPT" "$SESSION_TYPE" "$EXISTING_BRANCH" "build" "false"

  # Solo merge + branch seal (Phase 2: extracted from _run_single_entry)
  _solo_merge_if_needed "$_RESULT_BRANCH" "false" "$BRIEF_ID" ""

  # Belt-and-suspenders: check globals are populated
  if [ -z "$_RESULT_OUTCOME" ]; then
    echo "WARNING: Empty outcome from _run_single_entry — treating as failure" >&2
    exit 1
  fi

  OUTCOME="${_RESULT_OUTCOME%%:*}"

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

# --- PID file guard (flock-based atomic guard) ---
PID_FILE="$AUTOMATION_DIR/runner.pid"
DAEMON_LOCK_FILE="$AUTOMATION_DIR/.daemon-lock"

_cleanup_pid_file() {
  rm -f "$PID_FILE" 2>/dev/null || true
}

# Acquire exclusive daemon lock (flock on macOS/Linux, mkdir fallback)
_DAEMON_LOCK_FD=""
if command -v flock > /dev/null 2>&1; then
  # flock available — use file descriptor lock (held for daemon lifetime)
  exec 9>"$DAEMON_LOCK_FILE"
  if ! flock -n 9; then
    # Another daemon holds the lock — check PID file for diagnostics
    EXISTING_PID=$(cat "$PID_FILE" 2>/dev/null || echo "unknown")
    echo "Daemon already running (pid $EXISTING_PID, lock held)" >&2
    exit 0
  fi
  _DAEMON_LOCK_FD=9
else
  # flock unavailable (some macOS) — fall back to mkdir-based atomic lock
  if ! mkdir "$DAEMON_LOCK_FILE.d" 2>/dev/null; then
    # Lock dir exists — check if holder is still alive via PID file
    EXISTING_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
      echo "Daemon already running (pid $EXISTING_PID)" >&2
      exit 0
    else
      # Stale lock — reclaim (rm -rf: dir may be non-empty with pid file)
      echo "Removing stale daemon lock (pid $EXISTING_PID not running)" >&2
      rm -rf "$DAEMON_LOCK_FILE.d" 2>/dev/null || true
      if ! mkdir "$DAEMON_LOCK_FILE.d" 2>/dev/null; then
        echo "ERROR: Cannot acquire daemon lock" >&2
        exit 1
      fi
      # Write our PID immediately after acquiring the lock dir so the
      # secondary liveness check below reads fresh data (not stale PID).
      printf '%s' "$$" > "$PID_FILE" 2>/dev/null || true
      # Secondary liveness check (C10 TOCTOU patch): another process may have
      # raced us — if PID file was overwritten by a different daemon, yield.
      _post_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
      if [ -n "$_post_pid" ] && [ "$_post_pid" != "$$" ] && kill -0 "$_post_pid" 2>/dev/null; then
        echo "Race detected: daemon pid $_post_pid overwrote our PID — yielding" >&2
        rm -rf "$DAEMON_LOCK_FILE.d" 2>/dev/null || true
        exit 0
      fi
    fi
  fi
fi

# Write PID file (under lock — no race)
printf '%s' "$$" > "$PID_FILE"

_cleanup_daemon_lock() {
  rm -f "$PID_FILE" 2>/dev/null || true
  if [ -n "$_DAEMON_LOCK_FD" ]; then
    # flock released automatically on fd close
    eval "exec ${_DAEMON_LOCK_FD}>&-" 2>/dev/null || true
  else
    rm -rf "$DAEMON_LOCK_FILE.d" 2>/dev/null || true
  fi
}
_graceful_shutdown() {
  _SHUTDOWN_REQUESTED=true
  # SIGTERM source diagnostics — helps identify whether signal comes from
  # launchd, another runner instance, or macOS process management.
  local _sig_ts _sig_ppid _sig_parent_cmd
  _sig_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
  _sig_ppid=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ' || echo "unknown")
  _sig_parent_cmd=$(ps -o comm= -p "$_sig_ppid" 2>/dev/null || echo "unknown")
  echo "Shutdown requested at $_sig_ts — daemon pid $$, ppid $_sig_ppid ($_sig_parent_cmd), child_active=${_CLAUDE_CHILD_PID:+yes}${_CLAUDE_CHILD_PID:-no}" >&2
  echo "Deferring shutdown until active session completes and queue transition finishes..." >&2
}
trap '_graceful_shutdown' TERM INT
trap '_stop_heartbeat || true; _runner_crash_cleanup || true; _write_health "stopped" || true; _cleanup_daemon_lock || true' EXIT

echo "Runner daemon starting (pid $$)..." >&2

_ensure_queue_dirs

# Pre-flight: same-filesystem check (one-time at startup)
_check_same_filesystem

_DAEMON_START_EPOCH=$(date +%s)

# --- Startup crash recovery ---
_startup_crash_recovery

# --- Startup review-items sweep ---
# Remove stale review-items/ subdirectories older than 7 days.
# Follows the same startup-sweep pattern as sweep_stale_sessions above.
_ri_count=$(sweep_stale_review_items 2>/dev/null || echo "0")
[ "$_ri_count" -gt 0 ] && echo "startup: removed $_ri_count stale review-items directories (>7d)" >&2
unset _ri_count

# Cleanup tracking — run cleanup every N idle cycles
_IDLE_CYCLE_COUNT=0
_CLEANUP_INTERVAL=10  # Run cleanup every 10 idle cycles

while true; do
  # --- Shutdown check ---
  if [ "$_SHUTDOWN_REQUESTED" = true ]; then
    echo "Shutdown: exiting daemon loop (graceful)" >&2
    break
  fi

  # --- HALT file check ---
  if [ -f "$AUTOMATION_DIR/HALT" ]; then
    echo "HALT file present. Runner stopped." >&2
    break
  fi

  # --- FORCE-HALT file check (immediate — kill active session) ---
  if [ -f "$AUTOMATION_DIR/FORCE-HALT" ]; then
    echo "FORCE-HALT file present. Killing active session if any..." >&2
    if [ -n "$_CLAUDE_CHILD_PID" ] && kill -0 "$_CLAUDE_CHILD_PID" 2>/dev/null; then
      kill -TERM "$_CLAUDE_CHILD_PID" 2>/dev/null || true
      # Wait up to 10 seconds for graceful exit
      _fh_wait=0
      while [ "$_fh_wait" -lt 10 ] && kill -0 "$_CLAUDE_CHILD_PID" 2>/dev/null; do
        sleep 1
        _fh_wait=$((_fh_wait + 1))
      done
      # SIGKILL if still alive
      if kill -0 "$_CLAUDE_CHILD_PID" 2>/dev/null; then
        echo "FORCE-HALT: child still alive after 10s — sending SIGKILL" >&2
        kill -KILL "$_CLAUDE_CHILD_PID" 2>/dev/null || true
        wait "$_CLAUDE_CHILD_PID" 2>/dev/null || true
      fi
    fi
    # --- Clean up worktree if one was created (Decision 0033) ---
    if [ -n "$_CURRENT_WORKTREE_DIR" ] && [ -d "$_CURRENT_WORKTREE_DIR" ]; then
      git worktree remove --force "$_CURRENT_WORKTREE_DIR" 2>/dev/null || true
      git worktree prune 2>/dev/null || true
      _CURRENT_WORKTREE_DIR=""
    fi
    # --- Transition running entry to failed/ ---
    if [ -n "$_CURRENT_ENTRY_ID" ]; then
      _fh_qdir=$(_queue_dir)
      _fh_entry_file="$_fh_qdir/running/${_CURRENT_ENTRY_ID}.yaml"
      if [ -f "$_fh_entry_file" ]; then
        if acquire_queue_lock; then
          _load_queue_entry "$_fh_entry_file"
          _QE_STATUS="failed"
          _QE_ERROR_LOG="force-halted"
          _QE_COMPLETED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
          _QE_UPDATED_AT="$_QE_COMPLETED_AT"
          _write_queue_entry "$_fh_qdir/failed/${_CURRENT_ENTRY_ID}.yaml"
          rm -f "$_fh_entry_file"
          rm -f "$_fh_qdir/running/${_CURRENT_ENTRY_ID}.heartbeat" 2>/dev/null || true
          _rebuild_queue_index || true
          # Propagate failure to work order if entry belongs to one
          if [ -n "$_QE_WORK_ORDER_ID" ]; then
            _fh_wo_status=$(wo_check_completion "$_QE_WORK_ORDER_ID" 2>/dev/null) || true
            case "$_fh_wo_status" in
              failed)
                review_log_append "work-order-failed" "$_QE_WORK_ORDER_ID" "" \
                  "Work order $_QE_WORK_ORDER_ID failed — entry $_CURRENT_ENTRY_ID force-halted. Recovery: queue-cli.sh reopen-wo $_QE_WORK_ORDER_ID" 2>/dev/null || true
                ;;
              escalated)
                review_log_append "work-order-escalated" "$_QE_WORK_ORDER_ID" "" \
                  "Work order $_QE_WORK_ORDER_ID escalated — entry $_CURRENT_ENTRY_ID force-halted. Recovery: queue-cli.sh reopen-wo $_QE_WORK_ORDER_ID" 2>/dev/null || true
                ;;
            esac
          fi
          release_queue_lock
          echo "FORCE-HALT: entry $_CURRENT_ENTRY_ID transitioned to failed/" >&2
        else
          echo "WARNING: FORCE-HALT could not acquire lock — entry $_CURRENT_ENTRY_ID may be orphaned in running/" >&2
        fi
      fi
      # Write escalation file
      _fh_esc_dir="$REPO_ROOT/.claude/.automation/escalations"
      mkdir -p "$_fh_esc_dir" 2>/dev/null || true
      _fh_esc_id="esc-${_CURRENT_ENTRY_ID}-$(date +%Y%m%d-%H%M%S)"
      {
        printf 'escalation:\n'
        printf '  id: "%s"\n' "$_fh_esc_id"
        printf '  queue_entry_id: "%s"\n' "$_CURRENT_ENTRY_ID"
        printf '  type: "gate-failure"\n'
        printf '  severity: "blocking"\n'
        printf '  phase_at_exit: "unknown"\n'
        printf '  tag_at_exit: "agent"\n'
        printf '  message: "FORCE-HALT — entry terminated by operator"\n'
        printf '  context: "Daemon received FORCE-HALT file while entry was running"\n'
        printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '  resolved: false\n'
        printf '  resolution: ""\n'
      } > "$_fh_esc_dir/${_fh_esc_id}.yaml" 2>/dev/null || true
      _stop_heartbeat
      _CURRENT_ENTRY_ID=""
    fi
    rm -f "$AUTOMATION_DIR/FORCE-HALT" 2>/dev/null || true
    echo "FORCE-HALT: daemon exiting." >&2
    break
  fi

  # --- Config reload (live toggle support) ---
  RUNNER_ENABLED=$(_parse_config_field "runner" "enabled")
  if [ "$RUNNER_ENABLED" != "true" ]; then
    _write_health "disabled"
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
    _write_health "circuit-breaker"
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
    # Idle cycle — periodic cleanup + stale-running recovery
    _IDLE_CYCLE_COUNT=$((_IDLE_CYCLE_COUNT + 1))
    if [ "$_IDLE_CYCLE_COUNT" -ge "$_CLEANUP_INTERVAL" ]; then
      run_cleanup
      # Stale-running recovery: scan for entries with no heartbeat, stranded > 1 hour
      # Previous threshold (interval * 2 = 60s) caused false-positive recovery —
      # Claude sessions routinely run 10–20 minutes.
      _sr_qdir=$(_queue_dir)
      _sr_interval=$(_parse_config_field "runner" "heartbeat_interval")
      _sr_interval="${_sr_interval:-30}"
      _sr_threshold=$((_sr_interval * 120))
      _sr_now=$(date +%s)
      for _sr_entry_file in "$_sr_qdir/running"/*.yaml; do
        [ -f "$_sr_entry_file" ] || continue
        _sr_entry_id=$(basename "$_sr_entry_file" .yaml)
        _sr_hb_file="$_sr_qdir/running/${_sr_entry_id}.heartbeat"
        # Skip entries that have an active heartbeat (another runner is processing)
        if [ -f "$_sr_hb_file" ]; then
          _sr_hb_ts=$(cat "$_sr_hb_file" 2>/dev/null || true)
          if [ -n "$_sr_hb_ts" ]; then
            _sr_hb_epoch=$(_iso_to_epoch "$_sr_hb_ts" 2>/dev/null || echo "0")
            _sr_age=$((_sr_now - _sr_hb_epoch))
            if [ "$_sr_age" -lt "$_sr_threshold" ]; then
              continue  # Heartbeat is fresh — entry is legitimately running
            fi
          fi
          # Heartbeat exists but is stale — fall through to recovery
        fi
        # No heartbeat or stale heartbeat — check entry age via updated_at
        _load_queue_entry "$_sr_entry_file"
        _sr_entry_epoch=$(_iso_to_epoch "$_QE_UPDATED_AT" 2>/dev/null || echo "0")
        _sr_entry_age=$((_sr_now - _sr_entry_epoch))
        if [ "$_sr_entry_age" -gt "$_sr_threshold" ]; then
          echo "WARNING: Recovering stale entry $_sr_entry_id (no active heartbeat, age ${_sr_entry_age}s > ${_sr_threshold}s)" >&2
          if acquire_queue_lock; then
            _QE_STATUS="failed"
            _QE_ERROR_LOG="stranded entry — no heartbeat (recovered by daemon idle scan)"
            _QE_COMPLETED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            _QE_UPDATED_AT="$_QE_COMPLETED_AT"
            _write_queue_entry "$_sr_qdir/failed/${_sr_entry_id}.yaml"
            rm -f "$_sr_entry_file"
            rm -f "$_sr_hb_file" 2>/dev/null || true
            # Propagate failure to work order if entry belongs to one
            if [ -n "$_QE_WORK_ORDER_ID" ]; then
              _sr_wo_status=$(wo_check_completion "$_QE_WORK_ORDER_ID" 2>/dev/null) || true
              case "$_sr_wo_status" in
                failed)
                  review_log_append "work-order-failed" "$_QE_WORK_ORDER_ID" "" \
                    "Work order $_QE_WORK_ORDER_ID failed — stranded entry $_sr_entry_id recovered by idle scan. Recovery: queue-cli.sh reopen-wo $_QE_WORK_ORDER_ID" 2>/dev/null || true
                  ;;
                escalated)
                  review_log_append "work-order-escalated" "$_QE_WORK_ORDER_ID" "" \
                    "Work order $_QE_WORK_ORDER_ID escalated — stranded entry $_sr_entry_id recovered by idle scan. Recovery: queue-cli.sh reopen-wo $_QE_WORK_ORDER_ID" 2>/dev/null || true
                  ;;
              esac
            fi
            _rebuild_queue_index || true
            release_queue_lock
          else
            echo "WARNING: Could not acquire lock for stale entry recovery ($_sr_entry_id)" >&2
          fi
        fi
      done
      _IDLE_CYCLE_COUNT=0
    fi
    _CONSECUTIVE_SESSION_COUNT=0
    _write_health "idle"
    _poll_interval=$(_parse_config_field "runner" "poll_interval")
    _poll_interval="${_poll_interval:-60}"
    sleep "$_poll_interval"
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
  ENTRY_PUSH="${_QE_PUSH_ON_COMPLETE:-false}"

  echo "Processing entry: $ENTRY_ID (type: $ENTRY_SESSION_TYPE)" >&2

  # --- Merge-idempotency check (Phase 4: skip re-execution if already merged) ---
  _retry_count="${_QE_RETRY_COUNT:-0}"
  if [ "$_retry_count" -gt 0 ] && [ -n "$ENTRY_BRANCH" ]; then
    # Prior attempt created a branch — determine merge state
    _merge_skip=false
    if git rev-parse --verify "$ENTRY_BRANCH" >/dev/null 2>&1; then
      # Branch exists — count commits ahead of main
      _commits_ahead=$(git rev-list --count "main..$ENTRY_BRANCH" 2>/dev/null) || _commits_ahead=""
      if [ -z "$_commits_ahead" ] || [ "$_commits_ahead" -eq 0 ] 2>/dev/null; then
        # Zero commits ahead — branch was created but session crashed before committing.
        # Delete the stale branch so the retry can create a fresh one.
        echo "Entry $ENTRY_ID: branch $ENTRY_BRANCH has 0 commits ahead of main — stale branch from crashed session, deleting for retry" >&2
        git branch -D "$ENTRY_BRANCH" 2>/dev/null || true
        # Fall through to normal retry execution
      elif git merge-base --is-ancestor "$ENTRY_BRANCH" main 2>/dev/null; then
        # Commits ahead AND all reachable from main — genuinely merged
        echo "Entry $ENTRY_ID: branch $ENTRY_BRANCH has $_commits_ahead commit(s) ahead and is merged to main — skipping re-execution" >&2
        _merge_skip=true
      else
        # Commits ahead but NOT merged — unmerged work from prior attempt, retry
        echo "Entry $ENTRY_ID: branch $ENTRY_BRANCH has $_commits_ahead commit(s) ahead but is not merged to main — retrying" >&2
        # Fall through to normal retry execution
      fi
    else
      # Branch does not exist — fresh start, proceed normally
      echo "Entry $ENTRY_ID: branch $ENTRY_BRANCH does not exist — proceeding with fresh session" >&2
    fi

    if [ "$_merge_skip" = true ]; then
      # Transition directly to completed (locked)
      _skip_lock_attempts=0
      while ! acquire_queue_lock; do
        _skip_lock_attempts=$((_skip_lock_attempts + 1))
        if [ "$_skip_lock_attempts" -ge 3 ]; then
          echo "ERROR: Lock unavailable for idempotent completion ($ENTRY_ID)" >&2
          continue 2
        fi
        sleep 1
      done
      queue_complete "$ENTRY_ID"
      release_queue_lock
      _circuit_breaker_reset
      # Review log + work order lifecycle
      if [ -n "$ENTRY_WORK_ORDER_ID" ]; then
        review_log_append "entry-completed" "$ENTRY_WORK_ORDER_ID" "$ENTRY_ID" \
          "Entry $ENTRY_ID completed (idempotent — already merged)" 2>/dev/null || true
        _wo_new_status=$(wo_check_completion "$ENTRY_WORK_ORDER_ID" 2>/dev/null) || true
        case "$_wo_new_status" in
          completed)
            review_log_append "work-order-completed" "$ENTRY_WORK_ORDER_ID" "" \
              "Work order $ENTRY_WORK_ORDER_ID completed — all children done" 2>/dev/null || true
            ;;
          failed)
            review_log_append "work-order-failed" "$ENTRY_WORK_ORDER_ID" "" \
              "Work order $ENTRY_WORK_ORDER_ID failed — sibling entry failed. Recovery: queue-cli.sh reopen-wo $ENTRY_WORK_ORDER_ID" 2>/dev/null || true
            ;;
          escalated)
            review_log_append "work-order-escalated" "$ENTRY_WORK_ORDER_ID" "" \
              "Work order $ENTRY_WORK_ORDER_ID escalated — child failure detected. Recovery: queue-cli.sh reopen-wo $ENTRY_WORK_ORDER_ID" 2>/dev/null || true
            ;;
        esac
      fi
      sleep 2
      continue
    fi
  fi

  # --- Work-order deferral guard (skip entry if sibling is escalated or failed) ---
  # When an entry belongs to an escalated or failed work order, defer it back to
  # approved/ without incrementing retry_count. The entry resumes when the work
  # order is reopened. Failed work orders block siblings just like escalated ones.
  if [ -n "$ENTRY_WORK_ORDER_ID" ]; then
    _wo_defer_reason=""
    if wo_is_escalated "$ENTRY_WORK_ORDER_ID"; then
      _wo_defer_reason="escalated"
    elif wo_is_failed "$ENTRY_WORK_ORDER_ID"; then
      _wo_defer_reason="failed"
    fi
    if [ -n "$_wo_defer_reason" ]; then
      echo "Entry $ENTRY_ID: work order $ENTRY_WORK_ORDER_ID is $_wo_defer_reason — deferring" >&2
      _wo_lock_attempts=0
      while ! acquire_queue_lock; do
        _wo_lock_attempts=$((_wo_lock_attempts + 1))
        if [ "$_wo_lock_attempts" -ge 3 ]; then
          echo "ERROR: Lock unavailable for work-order defer ($ENTRY_ID)" >&2
          continue 2
        fi
        sleep 1
      done
      _defer_count=$(queue_defer "$ENTRY_ID" "work-order-${_wo_defer_reason}")
      # Check deferral cap — transition to blocked if exceeded
      _max_deferrals=$(_parse_config_field "runner" "max_deferral_cycles")
      _max_deferrals="${_max_deferrals:-3}"
      if [ "$_defer_count" -ge "$_max_deferrals" ] 2>/dev/null; then
        queue_block "$ENTRY_ID" "max_deferral_cycles exceeded ($_defer_count/$_max_deferrals)"
        release_queue_lock
        review_log_append "entry-blocked" "$ENTRY_WORK_ORDER_ID" "$ENTRY_ID" \
          "Entry $ENTRY_ID blocked — max deferral cycles exceeded ($_defer_count/$_max_deferrals)" 2>/dev/null || true
        # Check if this triggers work order escalation
        _wo_new_status=$(wo_check_completion "$ENTRY_WORK_ORDER_ID" 2>/dev/null) || true
        case "$_wo_new_status" in
          escalated|failed)
            review_log_append "work-order-${_wo_new_status}" "$ENTRY_WORK_ORDER_ID" "" \
              "Work order $ENTRY_WORK_ORDER_ID ${_wo_new_status} — entry blocked (deferral cap). Recovery: queue-cli.sh reopen-wo $ENTRY_WORK_ORDER_ID" 2>/dev/null || true
            ;;
        esac
      else
        release_queue_lock
        # Review log
        review_log_append "entry-deferred" "$ENTRY_WORK_ORDER_ID" "$ENTRY_ID" \
          "Entry $ENTRY_ID deferred — work order $ENTRY_WORK_ORDER_ID $_wo_defer_reason (sibling has failed or needs review) [cycle $_defer_count/$_max_deferrals]" 2>/dev/null || true
      fi
      sleep 2
      continue
    fi
  fi

  # Re-source phase helper to pick up session types added after daemon start.
  # Fixes: new session types registered in _phase-helper.sh after daemon launch are
  # not recognized without daemon restart. Re-sourcing is safe — all functions are
  # pure lookups with no state side effects.
  # shellcheck disable=SC1090
  source "$REPO_ROOT/.claude/hooks/_phase-helper.sh" 2>/dev/null || true

  # Validate session type
  if [ -z "$(get_phases_for_type "$ENTRY_SESSION_TYPE" 2>/dev/null)" ]; then
    echo "ERROR: Invalid session type '$ENTRY_SESSION_TYPE' for entry $ENTRY_ID" >&2
    _block_lock_attempts=0
    while ! acquire_queue_lock; do
      _block_lock_attempts=$((_block_lock_attempts + 1))
      if [ "$_block_lock_attempts" -ge 3 ]; then
        echo "ERROR: Lock unavailable for queue_block — skipping transition" >&2
        continue 2  # skip to next daemon cycle
      fi
      sleep 1
    done
    queue_block "$ENTRY_ID" "Invalid session type: $ENTRY_SESSION_TYPE"
    release_queue_lock
    continue
  fi

  # --- Dirty-tree guard (Phase 3: clean working tree between entries) ---
  # Prevents cascading dirty state from a prior failed entry.
  _dirty_check=$(git status --porcelain 2>/dev/null || true)
  if [ -n "$_dirty_check" ]; then
    echo "WARNING: Dirty working tree detected before entry $ENTRY_ID — cleaning" >&2
    git checkout -- . 2>/dev/null || true
    git clean -fd 2>/dev/null || true
  fi

  # --- Assemble prompt (lazy generation at dequeue time) ---
  PROMPT=$(assemble_prompt "$ENTRY_FILE")

  # --- Start heartbeat ---
  _start_heartbeat "$ENTRY_ID"

  # --- Log entry-started event ---
  review_log_append "entry-started" "$ENTRY_WORK_ORDER_ID" "$ENTRY_ID" \
    "Entry $ENTRY_ID started — work order $ENTRY_WORK_ORDER_ID" 2>/dev/null || true

  # --- Execute (direct call — no subshell, outcome in globals) ---
  _CURRENT_ENTRY_ID="$ENTRY_ID"
  _write_health "running"
  _run_single_entry "$ENTRY_ID" "$PROMPT" "$ENTRY_SESSION_TYPE" "$ENTRY_BRANCH" "build" "$ENTRY_PUSH"

  # --- Stop heartbeat ---
  _stop_heartbeat
  # Clean up heartbeat file
  rm -f "$(_queue_dir)/running/${ENTRY_ID}.heartbeat" 2>/dev/null || true
  _CURRENT_ENTRY_ID=""

  # --- Write branch name back to entry YAML (Phase 4: enables merge-idempotency on retry) ---
  if [ -n "$_RESULT_BRANCH" ] && [ "$_RESULT_BRANCH" != "main" ]; then
    _running_entry="$(_queue_dir)/running/${ENTRY_ID}.yaml"
    if [ -f "$_running_entry" ]; then
      _load_queue_entry "$_running_entry"
      if [ "$_QE_BRANCH" != "$_RESULT_BRANCH" ]; then
        _QE_BRANCH="$_RESULT_BRANCH"
        _write_queue_entry "$_running_entry"
      fi
    fi
  fi

  # --- Solo merge + branch seal (Phase 2: runs in main shell, not subshell) ---
  _solo_merge_if_needed "$_RESULT_BRANCH" "$ENTRY_PUSH" "$ENTRY_ID" "$ENTRY_WORK_ORDER_ID"

  # --- Handle empty outcome (belt-and-suspenders guard on globals) ---
  if [ -z "$_RESULT_OUTCOME" ]; then
    echo "WARNING: Empty outcome from _run_single_entry for $ENTRY_ID — treating as infrastructure failure" >&2
    OUTCOME_RAW="failed:empty-result"
    BASELINE_SHA=""
  else
    OUTCOME_RAW="$_RESULT_OUTCOME"
    BASELINE_SHA="$_RESULT_BASELINE"
  fi

  # --- Parse outcome ---
  OUTCOME="${OUTCOME_RAW%%:*}"
  echo "Entry $ENTRY_ID outcome: $OUTCOME_RAW" >&2

  # --- Queue state transition based on outcome ---
  # Lock with retry (3 attempts, 1s backoff). Entry must transition out of running/.
  _lock_acquired=false
  _lock_attempt=0
  while [ "$_lock_attempt" -lt 3 ]; do
    if acquire_queue_lock; then
      _lock_acquired=true
      break
    fi
    _lock_attempt=$((_lock_attempt + 1))
    echo "WARNING: Lock attempt $_lock_attempt/3 failed for outcome transition ($ENTRY_ID)" >&2
    sleep 1
  done
  if [ "$_lock_acquired" = false ]; then
    # Escalation is written, but transitions proceed unlocked below (intentional).
    # Unlike the dequeue path (which skips via `continue`), outcome transitions must
    # complete to avoid orphaning the entry in running/. Stale-running scanner is the
    # secondary safety net if even unlocked transition fails.
    echo "ERROR: Lock acquisition failed after 3 attempts for $ENTRY_ID — writing escalation" >&2
    _esc_dir="$REPO_ROOT/.claude/.automation/escalations"
    mkdir -p "$_esc_dir" 2>/dev/null || true
    _esc_id="esc-lock-$(date +%Y%m%d-%H%M%S)"
    {
      printf 'escalation:\n'
      printf '  id: "%s"\n' "$_esc_id"
      printf '  queue_entry_id: "%s"\n' "$ENTRY_ID"
      printf '  type: "gate-failure"\n'
      printf '  severity: "blocking"\n'
      printf '  phase_at_exit: "close"\n'
      printf '  tag_at_exit: "agent"\n'
      printf '  message: "Lock acquisition failed after 3 attempts during outcome transition"\n'
      printf '  context: "outcome: %s, entry: %s"\n' "$OUTCOME_RAW" "$ENTRY_ID"
      printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '  resolved: false\n'
      printf '  resolution: ""\n'
    } > "$_esc_dir/${_esc_id}.yaml" 2>/dev/null || true
  fi

  # Transition call with return-code checks
  _transition_ok=true
  case "$OUTCOME" in
    completed)
      if ! queue_complete "$ENTRY_ID"; then
        echo "ERROR: queue_complete failed for $ENTRY_ID" >&2
        _transition_ok=false
      fi
      ;;
    review)
      case "$OUTCOME_RAW" in
        review:incomplete-deliverable)
          # Completeness veto: route to review/ and write escalation file with criteria detail
          _ri_score=$(grep '^COMPLETENESS: ' "$(get_session_state_dir)/cohesion-reviewed" 2>/dev/null | sed 's/^COMPLETENESS: *//' | head -1 || true)
          if ! queue_incomplete "$ENTRY_ID" "${_ri_score:-COMPLETENESS_GATE: NEEDS_WORK}"; then
            echo "ERROR: queue_incomplete failed for $ENTRY_ID" >&2
            _transition_ok=false
          fi
          ;;
        *)
          if ! queue_escalate "$ENTRY_ID"; then
            echo "ERROR: queue_escalate failed for $ENTRY_ID" >&2
            _transition_ok=false
          fi
          ;;
      esac
      ;;
    failed)
      # Infrastructure failures (empty-result) are non-retriable — go directly to
      # terminal failed/ without incrementing retry_count. Retriable failures use
      # queue_fail which respects max_retries.
      case "$OUTCOME_RAW" in
        failed:empty-result)
          if ! queue_fail_terminal "$ENTRY_ID" "infrastructure failure: empty outcome from session"; then
            echo "ERROR: queue_fail_terminal failed for $ENTRY_ID" >&2
            _transition_ok=false
          fi
          ;;
        *)
          if ! queue_fail "$ENTRY_ID" "$OUTCOME_RAW"; then
            echo "ERROR: queue_fail failed for $ENTRY_ID" >&2
            _transition_ok=false
          fi
          ;;
      esac
      ;;
    *)
      if ! queue_fail "$ENTRY_ID" "$OUTCOME_RAW"; then
        echo "ERROR: queue_fail failed for $ENTRY_ID (wildcard outcome: $OUTCOME_RAW)" >&2
        _transition_ok=false
      fi
      ;;
  esac

  if [ "$_transition_ok" = false ]; then
    echo "WARNING: State transition failed for $ENTRY_ID — entry may be orphaned in running/" >&2
    review_log_append "transition-failed" "${ENTRY_WORK_ORDER_ID:-}" "$ENTRY_ID" \
      "State transition failed for $ENTRY_ID (outcome: $OUTCOME_RAW) — entry may be orphaned in running/" 2>/dev/null || true
  fi
  # Only release lock if we actually acquired it (Phase 6: prevents releasing another section's lock)
  if [ "$_lock_acquired" = true ]; then
    release_queue_lock
  fi

  # --- Post-transition actions (outside lock scope) ---
  # Reset work order status tracker (top-level code — no `local`)
  _wo_new_status=""

  case "$OUTCOME" in
    completed)
      _circuit_breaker_reset
      _SESSIONS_COMPLETED=$((_SESSIONS_COMPLETED + 1))
      _LAST_SESSION_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      _CONSECUTIVE_SESSION_COUNT=$((_CONSECUTIVE_SESSION_COUNT + 1))

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
          failed)
            review_log_append "work-order-failed" "$ENTRY_WORK_ORDER_ID" "" \
              "Work order $ENTRY_WORK_ORDER_ID failed — sibling entry failed. Recovery: queue-cli.sh reopen-wo $ENTRY_WORK_ORDER_ID" 2>/dev/null || true
            ;;
          escalated)
            review_log_append "work-order-escalated" "$ENTRY_WORK_ORDER_ID" "" \
              "Work order $ENTRY_WORK_ORDER_ID escalated — child failure detected. Recovery: queue-cli.sh reopen-wo $ENTRY_WORK_ORDER_ID" 2>/dev/null || true
            ;;
        esac
      fi

      # Cohesion triggers (all session types)
      check_cohesion_triggers "$ENTRY_ID" "$ENTRY_SESSION_TYPE" \
        "$BASELINE_SHA" "$ENTRY_BRIEF_PATH" "$ENTRY_BRANCH" \
        "$ENTRY_WORK_ORDER_ID" || true

      # Remediation trigger (audit sessions only)
      check_remediation_trigger "$ENTRY_ID" "$ENTRY_SESSION_TYPE" \
        "$ENTRY_BRIEF_PATH" "$ENTRY_BRANCH" \
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
      _LAST_SESSION_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      _CONSECUTIVE_SESSION_COUNT=$((_CONSECUTIVE_SESSION_COUNT + 1))
      # Review log + work order lifecycle
      if [ -n "$ENTRY_WORK_ORDER_ID" ]; then
        review_log_append "entry-escalated" "$ENTRY_WORK_ORDER_ID" "$ENTRY_ID" \
          "Entry $ENTRY_ID escalated ($ENTRY_SESSION_TYPE)" 2>/dev/null || true
        _wo_new_status=$(wo_check_completion "$ENTRY_WORK_ORDER_ID" 2>/dev/null) || true
        case "$_wo_new_status" in
          failed)
            review_log_append "work-order-failed" "$ENTRY_WORK_ORDER_ID" "" \
              "Work order $ENTRY_WORK_ORDER_ID failed — sibling entry failed. Recovery: queue-cli.sh reopen-wo $ENTRY_WORK_ORDER_ID" 2>/dev/null || true
            ;;
          escalated)
            review_log_append "work-order-escalated" "$ENTRY_WORK_ORDER_ID" "" \
              "Work order $ENTRY_WORK_ORDER_ID escalated — entry requires review" 2>/dev/null || true
            ;;
        esac
      fi
      ;;
    failed|*)
      _circuit_breaker_increment
      _SESSIONS_FAILED=$((_SESSIONS_FAILED + 1))
      _LAST_SESSION_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      _CONSECUTIVE_SESSION_COUNT=$((_CONSECUTIVE_SESSION_COUNT + 1))

      # Review log + work order lifecycle (only on terminal failure — retries exhausted)
      # Detect terminal failure by checking if queue_fail moved the entry to failed/
      if [ -n "$ENTRY_WORK_ORDER_ID" ]; then
        if [ -f "$(_queue_dir)/failed/${ENTRY_ID}.yaml" ]; then
          review_log_append "entry-failed" "$ENTRY_WORK_ORDER_ID" "$ENTRY_ID" \
            "Entry $ENTRY_ID failed — retries exhausted ($ENTRY_SESSION_TYPE)" 2>/dev/null || true
          _wo_new_status=$(wo_check_completion "$ENTRY_WORK_ORDER_ID" 2>/dev/null) || true
          case "$_wo_new_status" in
            failed)
              review_log_append "work-order-failed" "$ENTRY_WORK_ORDER_ID" "" \
                "Work order $ENTRY_WORK_ORDER_ID failed — entry $ENTRY_ID failed. Recovery: queue-cli.sh reopen-wo $ENTRY_WORK_ORDER_ID" 2>/dev/null || true
              ;;
            escalated)
              review_log_append "work-order-escalated" "$ENTRY_WORK_ORDER_ID" "" \
                "Work order $ENTRY_WORK_ORDER_ID escalated — entry failed" 2>/dev/null || true
              ;;
          esac
        fi
      fi
      ;;
  esac

  # Configurable cooldown between sessions
  _cooldown=$(_parse_config_field "runner" "cooldown_between_sessions")
  _cooldown="${_cooldown:-5}"
  sleep "$_cooldown"

  # Max consecutive sessions check
  _max_sessions=$(_parse_config_field "runner" "max_consecutive_sessions")
  _max_sessions="${_max_sessions:-0}"
  if [ "$_max_sessions" -gt 0 ] && [ "$_CONSECUTIVE_SESSION_COUNT" -ge "$_max_sessions" ]; then
    echo "Max consecutive sessions reached ($_max_sessions). Exiting daemon." >&2
    break
  fi
done

# Post-loop: daemon exiting
echo "Runner daemon stopped (pid $$)." >&2
exit 0
