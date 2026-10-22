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
# shellcheck source=lib/group-worktree-sweep.sh
# Sourced BEFORE cleanup.sh: run_cleanup() calls sweep_stale_group_worktrees
# through a `type` guard, so the definition must already exist (Decision 0054).
source "$LIB_DIR/group-worktree-sweep.sh"
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
# The in-session FORCE-HALT watcher's pid. Declared here with its peer rather
# than only being assigned inside _start_force_halt_watcher: the whole file runs
# under `set -u`, so any read before the first launch would abort the daemon.
_FORCE_HALT_WATCHER_PID=""

# --- Worktree tracking (for cleanup on crash/FORCE-HALT) ---
_CURRENT_WORKTREE_DIR=""

# --- Task group worktree tracking (Decision 0054) ---
# A sequential task group's worktree outlives the session that created it, so
# every removal site must consult _CURRENT_WORKTREE_IS_GROUP before removing
# _CURRENT_WORKTREE_DIR. _CURRENT_GROUP_NAME names the group whose occupancy
# lock this runner holds; it is the handle the crash/FORCE-HALT paths use to
# release that lock without removing the worktree.
_CURRENT_WORKTREE_IS_GROUP=false
_CURRENT_GROUP_NAME=""

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
  # Release a held group worktree lock (Decision 0054).
  # Keyed on _CURRENT_GROUP_NAME alone, NOT on _CURRENT_WORKTREE_IS_GROUP: the
  # lock is acquired in _resolve_group_worktree, which runs before the worktree
  # block that sets _CURRENT_WORKTREE_IS_GROUP. A crash in that window would
  # otherwise skip this release. (A dead holder's lock is broken on the next
  # acquire anyway, so this is belt-and-suspenders — but it makes "the lock is
  # released on every crash path" true rather than merely self-correcting.)
  if [ -n "$_CURRENT_GROUP_NAME" ]; then
    release_group_worktree_lock "$_CURRENT_GROUP_NAME" "$$" "" 2>/dev/null || true
    _CURRENT_GROUP_NAME=""
  fi
  # Clean up worktree if one was created (Decision 0033).
  # Task group worktrees are exempt (Decision 0054): a crashed brief leaves its
  # worktree in place so the operator can inspect what the crash left behind,
  # and so the restart reuses the same tree.
  if [ "$_CURRENT_WORKTREE_IS_GROUP" = true ]; then
    if [ -n "$_CURRENT_WORKTREE_DIR" ]; then
      echo "Task group worktree '$_CURRENT_WORKTREE_DIR' left in place for inspection (Decision 0054)" >&2
    fi
    _CURRENT_WORKTREE_DIR=""
    _CURRENT_WORKTREE_IS_GROUP=false
  elif [ -n "$_CURRENT_WORKTREE_DIR" ] && [ -d "$_CURRENT_WORKTREE_DIR" ]; then
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
  # A corrupt count fails CLOSED, matching the epoch policy below. Previously
  # `[ xyz -ge 3 ]` exited 2, so an unreadable breaker file reported "not
  # tripped" and the daemon kept pulling entries — the opposite direction from
  # every other malformed-input path here, and the one that turns a hard stop
  # into an unbounded retry loop. A file that exists but cannot be read is not
  # evidence that nothing is wrong. `reset-breaker` is the way out.
  case "$count" in
    '') return 1 ;;                                  # no count line: not tripped
    *[!0-9]*)
      echo "Circuit breaker file has an unreadable consecutive_failures value ('$count') — treating the breaker as TRIPPED. Clear it with 'queue-cli.sh reset-breaker'." >&2
      return 0
      ;;
  esac
  [ "$count" -ge 3 ] || return 1

  # Cooldown. Before this, a tripped breaker had NO way out: nothing read the
  # timestamp, no command reset it, and the only reset path runs on a successful
  # entry — which the breaker itself prevents. On 2026-10-20 that left the daemon
  # wedged from 04:08 until the counter file was deleted by hand.
  #
  # Once the window has passed the breaker reports "not tripped" so ONE entry can
  # be attempted. The counter is deliberately NOT cleared: if that probe fails,
  # _circuit_breaker_increment bumps the count and writes a fresh timestamp, so
  # the breaker re-trips for another full window. That gives one probe per
  # window rather than the retry loop a counter reset would produce. Only a
  # SUCCESS clears the file, via the existing _circuit_breaker_reset.
  local cooldown
  cooldown=$(_parse_config_field "runner" "circuit_breaker_cooldown_seconds" 2>/dev/null || echo "")
  cooldown="${cooldown:-1800}"
  case "$cooldown" in ''|*[!0-9]*) cooldown=1800 ;; esac
  [ "$cooldown" -gt 0 ] || return 0   # 0 disables the cooldown — stay tripped

  # The epoch field is written alongside the ISO timestamp precisely so this
  # comparison needs no date parsing: `date -d` is GNU-only and `date -j` is
  # BSD-only, and this repo targets bash 3.2 on macOS.
  local failed_epoch
  failed_epoch=$(grep '^last_failure_epoch:' "$cb_file" 2>/dev/null \
    | sed 's/.*: *//' | tr -d '[:space:]' | head -1)
  # Missing or unparseable: stay tripped. Fails closed, not open — a breaker
  # written by an older runner has no epoch field and must not silently expire.
  case "$failed_epoch" in ''|*[!0-9]*) return 0 ;; esac

  local now_epoch elapsed
  now_epoch=$(date +%s)
  elapsed=$(( now_epoch - failed_epoch ))
  if [ "$elapsed" -ge "$cooldown" ]; then
    echo "Circuit breaker cooldown elapsed (${elapsed}s >= ${cooldown}s) — allowing ONE probe entry. The failure count stays at ${count}: if the probe fails the breaker re-trips for another ${cooldown}s. Diagnose with 'queue-cli.sh review', or clear it with 'queue-cli.sh reset-breaker'." >&2
    return 1
  fi
  return 0
}

_circuit_breaker_increment() {
  local cb_file
  cb_file=$(_cb_file)
  local count=0
  if [ -f "$cb_file" ]; then
    # `|| true`: this function is called as a plain command from the daemon
    # loop's failure arm, so errexit is live (unlike _circuit_breaker_tripped,
    # which is always called from an `if`). A breaker file with no
    # `consecutive_failures:` line makes grep exit 1, pipefail propagates it,
    # and the daemon dies while recording a failure — the count guard below
    # would never be reached.
    count=$(grep '^consecutive_failures:' "$cb_file" 2>/dev/null \
      | sed 's/.*: *//' | tr -d '[:space:]' | head -1) || true
    count="${count:-0}"
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  count=$((count + 1))
  local ts epoch
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # The epoch is written for _circuit_breaker_tripped's cooldown arithmetic;
  # the ISO timestamp stays because it is what operators read. Parsing the ISO
  # form back is not portable (`date -d` GNU-only, `date -j -f` BSD-only), so
  # the value is recorded in both shapes rather than converted later.
  epoch=$(date +%s)
  printf 'consecutive_failures: %s\nlast_failure_at: %s\nlast_failure_epoch: %s\n' \
    "$count" "$ts" "$epoch" \
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
            _sr_wo_status=$(wo_check_completion "$_QE_WORK_ORDER_ID" 2>/dev/null) || {
              echo "WARNING: wo_check_completion failed for work order $_QE_WORK_ORDER_ID after startup recovery of entry $entry_id" >&2
            }
            case "$_sr_wo_status" in
              failed)
                review_log_append "work-order-failed" "$_QE_WORK_ORDER_ID" "" \
                  "Work order $_QE_WORK_ORDER_ID failed — orphaned entry $entry_id recovered at startup. Recovery: queue-cli.sh reopen-wo $_QE_WORK_ORDER_ID" 2>/dev/null || true
                ;;
              escalated)
                review_log_append "work-order-escalated" "$_QE_WORK_ORDER_ID" "" \
                  "Work order $_QE_WORK_ORDER_ID escalated — orphaned entry $entry_id recovered at startup. Recovery: queue-cli.sh reopen-wo $_QE_WORK_ORDER_ID" 2>/dev/null || true
                ;;
              completed)
                review_log_append "work-order-completed" "$_QE_WORK_ORDER_ID" "" \
                  "Work order $_QE_WORK_ORDER_ID completed — all children terminal after startup recovery of $entry_id" 2>/dev/null || true
                ;;
              "")
                echo "WARNING: wo_check_completion returned empty status for work order $_QE_WORK_ORDER_ID (startup recovery, entry $entry_id)" >&2
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

  # 4. Orphaned session state — DIAGNOSTIC ONLY. Deliberately does not mutate.
  #
  # This step used to call `runner_external_cleanup` whenever
  # `.claude/.session-id` existed. Two things were wrong with that:
  #
  #   - It had NO liveness predicate. The condition was the mere existence of a
  #     file the glossary documents as persistent and immune, so it fired on
  #     essentially every daemon start.
  #   - `runner_external_cleanup` is a session CLOSE routine, not an orphan
  #     sweep: it unregisters the session, deletes its state directory via
  #     `cleanup_session_files`, and writes dirty-tree and unsealed-branch
  #     escalations. Called with an empty entry id it resolves the session
  #     itself through `get_session_id` — i.e. whichever session is CURRENT.
  #
  # So starting the daemon closed the live interactive session. On 2026-10-21
  # that deleted this very session's `.claude/.state/wt-sessions/<id>/` and its
  # registry entry, taking its plan approval and every recorded verdict with
  # them; `write-guard.sh` then refused every edit with "No phase-state" and the
  # session could not complete its own close. A daemon start must never be able
  # to brick a concurrent human session.
  #
  # The legitimate intent — clean up state left behind by a session that
  # actually died — is step 5's job. Adding a liveness predicate here would
  # have produced a second, independently-maintained notion of "live" sitting
  # six lines above an existing one, so the fix is a deletion.
  #
  # Being precise about what step 5 does guarantee, because an earlier version
  # of this comment overclaimed it: `sweep_stale_sessions` reaps per-process
  # sidecars on the decisive sidecar test, and removes a registry entry when the
  # recorded pid is dead. Its 24h and TTL arms used to remove the entry
  # "regardless of PID" — which took the state directory with it, since the
  # orphaned-state-dir loop keys on a missing registry entry. That is what
  # actually destroyed a live ~16h session's state on 2026-10-21, and both arms
  # are now gated on pid liveness. The deletion site itself — the orphaned
  # state-dir loop — is gated too, on the per-process sidecar and on
  # REPO_OS_SESSION_ID, so a live session keeps its state even if something else
  # has already removed its registry entry. That belt-and-braces matters because
  # the call below passes no exclude_sid and cannot: the daemon does not register
  # itself and has no way to name a concurrent interactive session.
  #
  # Known not covered by step 5, deliberately (see known-issues): repo-level
  # operational files that `cleanup_session_files` removes, and the out-of-tree
  # evidence manifest. A hard-killed session leaves those behind.
  local session_id_file="$REPO_ROOT/.claude/.session-id"
  if [ -f "$session_id_file" ]; then
    echo "Startup recovery: session-id file present — leaving it to the stale-session sweep (step 5). No state is touched here." >&2
  fi

  # 5. Sweep stale session registry entries (C7 orphan TTL patch)
  # Owns orphaned session state outright, since step 4 no longer mutates.
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
# Task group worktree resolution (Decision 0054)
# ============================================================
# A sequential task group gets ONE worktree for the whole life of its branch:
# brief 1 creates `.worktrees/tg-<group>`, briefs 2..N reuse it. Standalone
# entries keep the per-session worktree of Decision 0033; parallel task groups
# keep the per-brief branches and worktrees of Decision 0032.
#
# Outputs (globals, reset on every call):
#   _GWT_GROUP          group name ("" when not applicable)
#   _GWT_DIR            resolved group worktree path
#   _GWT_REUSE          true when an existing worktree is being reused, in which
#                       case the caller MUST skip branch_manager_setup
#   _GWT_BRANCH         sanitized group branch
#   _GWT_BLOCK_OUTCOME  _RESULT_OUTCOME value to report when blocked
_GWT_GROUP=""
_GWT_DIR=""
_GWT_REUSE=false
_GWT_BRANCH=""
_GWT_BLOCK_OUTCOME=""

# --- Write a group-worktree escalation ---
# Uses the existing `governance-block` type and the `esc-dirty-tree-` /
# `esc-group-worktree-` id conventions rather than growing the escalation type
# enum: the schema's 10 types already cover "hook enforcement prevented action",
# and state-manager.sh already writes a dirty-tree escalation under that type.
# Arguments:
#   $1 — escalation id prefix
#   $2 — brief_id (queue entry id)
#   $3 — message
#   $4 — context
_write_group_worktree_escalation() {
  local prefix="$1"
  local brief_id="$2"
  local message="$3"
  local context="$4"
  local esc_dir="$REPO_ROOT/.claude/.automation/escalations"
  mkdir -p "$esc_dir" 2>/dev/null || true
  local esc_id="${prefix}-$(date +%Y%m%d-%H%M%S)"
  {
    printf 'escalation:\n'
    printf '  id: "%s"\n' "$esc_id"
    printf '  queue_entry_id: "%s"\n' "$brief_id"
    printf '  type: "governance-block"\n'
    printf '  severity: "blocking"\n'
    printf '  phase_at_exit: "init"\n'
    printf '  tag_at_exit: "operator"\n'
    printf '  message: "%s"\n' "$message"
    printf '  context: "%s"\n' "$context"
    printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  resolved: false\n'
    printf '  resolution: ""\n'
  } > "$esc_dir/${esc_id}.yaml" 2>/dev/null || true
  echo "$esc_id"
}

# --- Does this brief belong to a sequential task group? ---
# Parallel groups are out of scope for Decision 0054 — they keep per-brief
# branches (Decision 0032), so a shared group worktree would be wrong for them.
# Arguments:
#   $1 — brief path (repo-relative or absolute; may be empty)
# Returns: 0 sequential, 1 parallel or undeterminable
_brief_is_sequential_group() {
  local brief_path="${1:-}"
  [ -n "$brief_path" ] || return 1
  local resolved=""
  if [ -f "$REPO_ROOT/$brief_path" ]; then
    resolved="$REPO_ROOT/$brief_path"
  elif [ -f "$brief_path" ]; then
    resolved="$brief_path"
  else
    return 1
  fi
  # Absence of an Execution: line means sequential (the documented default).
  #
  # Both brief formats must match. The canonical one the templates emit is
  # `- **Execution:** parallel`; older briefs use a bare `Execution: parallel`.
  # The original pattern allowed the leading "- " but not the bold markers, so a
  # CANONICAL parallel brief fell through as sequential and would have been
  # handed a shared group worktree — precisely what Decision 0032 forbids, and a
  # race between parallel briefs on one working tree. Same root cause as the
  # `_extract_group_name` defect fixed alongside this.
  # Scoped to the ### Task Group section first, for the same reason
  # _extract_group_name is: a stray phrase elsewhere in the brief must not
  # decide execution mode.
  #
  # But the fallback is deliberately file-wide, NOT scope-only, because the two
  # error directions are not equally costly. Missing a `parallel` marker
  # (false negative) hands a parallel group a SHARED worktree and races its
  # briefs against one working tree — the exact harm Decision 0032 exists to
  # prevent. Spuriously reading `parallel` (false positive) merely gives a
  # sequential group per-session worktrees, i.e. the pre-t-0054 behaviour.
  # So when the section carries no Execution line at all, fall back to scanning
  # the whole brief: being permissive toward "parallel" is the fail-safe side.
  local _tg_section
  _tg_section=$(sed -n '/^### Task Group$/,/^###/p' "$resolved" 2>/dev/null || true)
  local _exec_pat='^[[:space:]]*(-[[:space:]]*)?(\*\*)?Execution:?(\*\*)?:?[[:space:]]*'
  if printf '%s\n' "$_tg_section" | grep -qE "${_exec_pat}parallel"; then
    return 1
  fi
  if printf '%s\n' "$_tg_section" | grep -qE "${_exec_pat}sequential"; then
    return 0
  fi
  # No Execution line in the section — scan the whole brief (legacy briefs).
  if grep -qE "${_exec_pat}parallel" "$resolved" 2>/dev/null; then
    return 1
  fi
  return 0
}

# --- Resolve (create-or-reuse) a sequential task group's worktree ---
# Arguments:
#   $1 — session_type
#   $2 — brief_path
#   $3 — existing_branch (the group branch)
#   $4 — brief_id (for escalation context)
# Returns: 0 applicable and ready, 1 not applicable (standalone / parallel),
#          2 blocked — caller must abort the entry without launching
_resolve_group_worktree() {
  local session_type="$1"
  local brief_path="$2"
  local existing_branch="$3"
  local brief_id="$4"

  _GWT_GROUP=""
  _GWT_DIR=""
  _GWT_REUSE=false
  _GWT_BRANCH=""
  _GWT_BLOCK_OUTCOME=""

  # Only sequential task group entries with a real group branch qualify.
  [ "$session_type" = "taskgroup" ] || return 1
  [ -n "$existing_branch" ] || return 1
  [ "${REPO_OS_WORKTREE_ISOLATE:-1}" != "0" ] || return 1
  _brief_is_sequential_group "$brief_path" || return 1

  local group
  group=$(_extract_group_name "$brief_path" 2>/dev/null || true)
  if [ -z "$group" ]; then
    # No group name means no stable worktree identity. Fall back to the
    # per-session worktree rather than inventing one — correct, just without
    # the brief-to-brief carry-over.
    echo "WARNING: Task group entry $brief_id has no 'Group:' field — falling back to a per-session worktree (Decision 0054)" >&2
    return 1
  fi

  local wt_dir
  wt_dir=$(group_worktree_path "$group") || return 1
  _GWT_GROUP="$group"
  _GWT_DIR="$wt_dir"
  _GWT_BRANCH=$(sanitize_branch_name "$existing_branch")

  # --- Single occupant (Decision 0054) ---
  # Blocking, unlike the registry's advisory task-group overlap warning: a
  # shared worktree cannot tolerate two concurrent sessions the way a shared
  # branch across sequential briefs can.
  local lock_rc=0
  acquire_group_worktree_lock "$group" "$$" "${REPO_OS_SESSION_ID:-}" || lock_rc=$?
  if [ "$lock_rc" -ne 0 ]; then
    local lock_dir holder_pid holder_sid esc_id
    lock_dir=$(_group_worktree_lock_dir "$group" 2>/dev/null || echo "")
    holder_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "unknown")
    holder_sid=$(cat "$lock_dir/session_id" 2>/dev/null || echo "unknown")
    esc_id=$(_write_group_worktree_escalation "esc-group-worktree-locked" "$brief_id" \
      "Task group worktree already occupied — only one session may run in a group worktree at a time" \
      "group: $group, worktree: $wt_dir, holder_pid: $holder_pid, holder_session: $holder_sid")
    echo "ERROR: Group worktree for '$group' is occupied (holder pid $holder_pid) — escalation $esc_id" >&2
    _GWT_BLOCK_OUTCOME="failed:group-worktree-locked"
    return 2
  fi

  # --- Nothing there yet: brief 1 creates it ---
  if [ ! -d "$wt_dir" ]; then
    return 0
  fi

  # --- Something is there: it must be the group's worktree on the group branch ---
  if ! is_registered_worktree "$wt_dir"; then
    local esc_id
    esc_id=$(_write_group_worktree_escalation "esc-group-worktree-unregistered" "$brief_id" \
      "Path exists at the task group worktree location but git does not know it as a worktree — refusing to recreate it" \
      "group: $group, path: $wt_dir, recovery: inspect the directory, then 'git worktree prune' and remove it by hand")
    echo "ERROR: $wt_dir exists but is not a registered worktree — escalation $esc_id" >&2
    release_group_worktree_lock "$group" "$$" "${REPO_OS_SESSION_ID:-}" || true
    _GWT_BLOCK_OUTCOME="failed:group-worktree-unregistered"
    return 2
  fi

  local wt_branch
  wt_branch=$(group_worktree_branch "$wt_dir")
  if [ "$wt_branch" != "$_GWT_BRANCH" ]; then
    # Fail loudly, never silently recreate: a worktree on an unexpected branch
    # means either two groups collided on one name or someone moved it, and
    # both need a human.
    local esc_id
    esc_id=$(_write_group_worktree_escalation "esc-group-worktree-branch-mismatch" "$brief_id" \
      "Task group worktree is checked out on an unexpected branch — refusing to recreate it" \
      "group: $group, worktree: $wt_dir, expected_branch: $_GWT_BRANCH, actual_branch: ${wt_branch:-detached}")
    echo "ERROR: Group worktree '$wt_dir' is on '${wt_branch:-detached}', expected '$_GWT_BRANCH' — escalation $esc_id" >&2
    release_group_worktree_lock "$group" "$$" "${REPO_OS_SESSION_ID:-}" || true
    _GWT_BLOCK_OUTCOME="failed:group-worktree-branch-mismatch"
    return 2
  fi

  # --- Clean-start guarantee (Decision 0054) ---
  # Each brief must still begin from a clean committed state. Gitignored files
  # are exempt by construction (git status --porcelain omits them) — preserving
  # them is the entire point of reusing the worktree.
  local clean_rc=0 clean_reason=""
  clean_reason=$(check_group_worktree_clean "$wt_dir" "$_GWT_BRANCH") || clean_rc=$?
  if [ "$clean_rc" -ne 0 ]; then
    local esc_id
    esc_id=$(_write_group_worktree_escalation "esc-dirty-tree" "$brief_id" \
      "Task group worktree is not at a clean committed state — brief not started" \
      "group: $group, worktree: $wt_dir, branch: $_GWT_BRANCH, detail: $clean_reason, recovery: commit or discard the changes in the worktree, then requeue the brief")
    echo "ERROR: Group worktree '$wt_dir' is not clean ($clean_reason) — escalation $esc_id" >&2
    release_group_worktree_lock "$group" "$$" "${REPO_OS_SESSION_ID:-}" || true
    _GWT_BLOCK_OUTCOME="failed:group-worktree-dirty"
    return 2
  fi

  # --- Branch freshness, handled worktree-side ---
  # branch_manager_setup()'s own freshness paths cannot run against a branch
  # that is checked out in a live worktree: Case 1 does `git branch -D` and
  # Case 3 does `git checkout`, and git refuses both. Mirror the same three
  # cases here using `git -C <worktree>` instead, leaving branch-manager.sh
  # untouched for every other entry type.
  if git -C "$REPO_ROOT" merge-base --is-ancestor "$_GWT_BRANCH" main 2>/dev/null; then
    # Case 1: fully merged into main — the group is finished (or its branch was
    # merged out from under it). Retire the worktree and let the normal create
    # path rebuild it from current main.
    echo "Group branch $_GWT_BRANCH is an ancestor of main — retiring group worktree and recreating from current main" >&2
    release_group_worktree_lock "$group" "$$" "${REPO_OS_SESSION_ID:-}" || true
    remove_group_worktree "$group" "$$" "${REPO_OS_SESSION_ID:-}" || true
    local relock_rc=0
    acquire_group_worktree_lock "$group" "$$" "${REPO_OS_SESSION_ID:-}" || relock_rc=$?
    if [ "$relock_rc" -ne 0 ]; then
      _GWT_BLOCK_OUTCOME="failed:group-worktree-locked"
      return 2
    fi
    return 0
  fi

  if ! git -C "$REPO_ROOT" merge-base --is-ancestor main "$_GWT_BRANCH" 2>/dev/null; then
    # Case 3: has unique commits but is behind main — rebase inside the
    # worktree. The tree is known clean (checked above), so a rebase is safe.
    echo "Group branch $_GWT_BRANCH is behind main — rebasing inside $wt_dir" >&2
    local rebase_rc=0
    _bm_rebase_onto_main "$wt_dir" || rebase_rc=$?
    if [ "$rebase_rc" -ne 0 ]; then
      # A rebase that cannot be finished mechanically is NOT "continue as-is":
      # the group would build on a stale base, and its final merge would hit the
      # same conflict with the work already done. The abort has been verified
      # (tree clean, no rebase in progress), so the worktree is launchable once
      # an operator rebases the branch by hand — or reset-group-worktree clears it.
      local conflict_files="${_BM_REBASE_CONFLICT_FILES:-none reported}"
      local esc_id
      esc_id=$(_write_group_worktree_escalation "esc-group-worktree-rebase-conflict" "$brief_id" \
        "Task group branch cannot be rebased onto main without manual conflict resolution — brief not started" \
        "group: $group, worktree: $wt_dir, branch: $_GWT_BRANCH, conflicting_files: $conflict_files, detail: $_BM_REBASE_DETAIL, recovery: run 'git -C $wt_dir rebase main', resolve the conflicts, 'git -C $wt_dir add' them and 'git -C $wt_dir rebase --continue', then 'queue-cli.sh reopen-wo <work-order>' (or discard a wedged worktree with 'queue-cli.sh reset-group-worktree $group')")
      echo "ERROR: Group branch $_GWT_BRANCH cannot be rebased onto main — conflicting files: $conflict_files — escalation $esc_id" >&2
      release_group_worktree_lock "$group" "$$" "${REPO_OS_SESSION_ID:-}" || true
      _GWT_BLOCK_OUTCOME="failed:group-worktree-rebase-conflict"
      return 2
    fi
  fi

  # Case 2 (ahead of main, main is ancestor): nothing to do.
  _GWT_REUSE=true
  return 0
}

# --- Message for a branch with commits ahead of main that is not merged ---
# Defect C: the original message ("not merged to main — retrying") was logged
# unconditionally. For a NON-FINAL brief of a sequential task group the unmerged
# branch is the designed state (Decision t-0013 §7: only the final brief merges),
# so "retrying" was wrong. This is message-only: both cases fall through to the
# same normal execution path in the caller.
# Arguments: $1 entry_id, $2 branch, $3 commits_ahead, $4 brief path, $5 work_order_id
# Output: the message on stdout (caller redirects to stderr)
_unmerged_branch_message() {
  local entry_id="$1" branch="$2" ahead="$3" brief_path="${4:-}" wo_id="${5:-}"
  if [ -n "$wo_id" ] && _brief_is_sequential_group "$brief_path" \
     && ! _is_final_taskgroup_entry "$entry_id" "$wo_id"; then
    printf 'Entry %s: branch %s has %s commit(s) ahead of main and is intentionally unmerged — only the final brief of a sequential task group merges; running this brief on the group branch\n' \
      "$entry_id" "$branch" "$ahead"
  else
    printf 'Entry %s: branch %s has %s commit(s) ahead but is not merged to main — retrying\n' \
      "$entry_id" "$branch" "$ahead"
  fi
}

# --- Handle an entry whose work order is escalated or failed ---
# The entry is deferred back to approved/ (retry_count untouched). Once it has been
# deferred max_deferral_cycles times, the work order cannot make progress, so the
# entry AND every approved sibling of the same work order go to blocked/ with ONE
# escalation naming the work order — instead of starving unrelated queue entries.
#
# Defect B: the inline version called queue_block on an entry queue_defer had just
# moved to approved/; queue_block only accepts running/, so it failed under set -e,
# killed the daemon and left the queue lock held. This function never exits, never
# leaves the lock held, and always returns 0 — except when the queue lock cannot be
# taken (returns 1, entry still in running/; the caller ignores it; the entry is not lost but
# stays running until the idle-cycle stale-running warning / `queue-cli.sh recover-entry`).
# Arguments: $1 entry_id, $2 work_order_id, $3 reason ("failed" | "escalated")
_handle_wo_deferral() {
  local entry_id="$1" wo_id="$2" reason="$3"
  local attempts=0 defer_count max_deferrals
  while ! acquire_queue_lock; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 3 ]; then
      echo "ERROR: Lock unavailable for work-order defer ($entry_id)" >&2
      return 1
    fi
    sleep 1
  done

  defer_count=$(queue_defer "$entry_id" "work-order-${reason}") || defer_count=""
  max_deferrals=$(_parse_config_field "runner" "max_deferral_cycles" 2>/dev/null || true)
  max_deferrals="${max_deferrals:-3}"

  if ! [ "$defer_count" -ge "$max_deferrals" ] 2>/dev/null; then
    release_queue_lock || true
    review_log_append "entry-deferred" "$wo_id" "$entry_id" \
      "Entry $entry_id deferred — work order $wo_id $reason (sibling has failed or needs review) [cycle ${defer_count:-?}/$max_deferrals]" 2>/dev/null || true
    return 0
  fi

  # Cap reached: the work order cannot progress. Block this entry and its
  # approved siblings; one escalation covers them all.
  local qdir blocked_ids="" sib failure_entry=""
  qdir=$(_queue_dir)
  _WO_ENTRY_IDS=""
  _WO_FAILURE_ENTRY_ID=""
  _load_work_order "$qdir/work-orders/${wo_id}.yaml" 2>/dev/null || true
  failure_entry="${_WO_FAILURE_ENTRY_ID:-unknown}"
  local block_reason="work order $wo_id $reason (failed entry: $failure_entry) — max_deferral_cycles exceeded ($defer_count/$max_deferrals)"
  local old_ifs="$IFS" sibs="$entry_id"
  [ -n "$_WO_ENTRY_IDS" ] && sibs="$entry_id,$_WO_ENTRY_IDS"
  IFS=','
  # shellcheck disable=SC2086 — intentional word splitting on comma-delimited list
  set -- $sibs
  IFS="$old_ifs"
  for sib in "$@"; do
    case ",$blocked_ids," in *",$sib,"*) continue ;; esac
    [ -f "$qdir/approved/${sib}.yaml" ] || continue
    if queue_block_deferred "$sib" "$block_reason" >/dev/null 2>&1; then
      blocked_ids="${blocked_ids:+$blocked_ids,}$sib"
      rm -f "$qdir/.defer-count-${sib}"
      review_log_append "entry-blocked" "$wo_id" "$sib" \
        "Entry $sib blocked — $block_reason" 2>/dev/null || true
    fi
  done
  release_queue_lock || true

  local esc_id
  esc_id=$(_write_group_worktree_escalation "esc-wo-blocked-${wo_id}" "$entry_id" \
    "Work order $wo_id cannot progress ($reason) — its remaining entries were blocked so they do not starve the queue" \
    "work_order: $wo_id, status: $reason, failed_entry: $failure_entry, blocked_entries: ${blocked_ids:-none}, recovery: fix the cause, then run 'queue-cli.sh reopen-wo $wo_id' to restore the blocked entries") || esc_id=""
  echo "Work order $wo_id is $reason — blocked entries: ${blocked_ids:-none} — escalation ${esc_id:-not written}; recovery: queue-cli.sh reopen-wo $wo_id" >&2
  review_log_append "work-order-${reason}" "$wo_id" "" \
    "Work order $wo_id $reason — remaining entries blocked (deferral cap). Recovery: queue-cli.sh reopen-wo $wo_id" 2>/dev/null || true
  return 0
}

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

  # Map config names to CLI model IDs (Claude 5 family — Decision t-0046 Amendment 3)
  # Any cost or latency comparison straddling this change is not comparable:
  # audit/queue-triage (haiku) and standard/taskgroup-merge/eval/eval-cell (sonnet)
  # all moved from Claude 4 generation to Claude 5.
  case "$model" in
    sonnet) printf '%s' "claude-sonnet-5-5" ;;
    haiku)  printf '%s' "claude-haiku-5-5" ;;
    opus)   printf '%s' "claude-opus-5-5" ;;
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

# --- _start_force_halt_watcher ---
# Makes FORCE-HALT interrupt a RUNNING entry.
#
# The daemon loop checks the FORCE-HALT file only BETWEEN entries, so an
# operator who force-halted during a long brief had to wait for that brief to
# finish. On 2026-10-20 a running brief had to be stopped by signalling its
# process by hand, which is not something an operator should need to do. This
# watcher polls for the flag and ends the child at the next poll.
#
# It deliberately does NOT delete the flag. The loop handler still needs to see
# it to clean up the worktree and the entry and to stop the daemon; deleting it
# here would silently turn a force-halt into "kill this one brief and carry on".
#
# One helper, called from both launch sites, rather than two inline copies: the
# two branches are already near-duplicates and this keeps the kill ladder in a
# single place. The TTL watchdog stays inline and unchanged — unifying the
# watchers into one supervisor is a follow-up, not something to attempt inside a
# liveness repair, because the kill path is exactly what must stay stable.
#
# Arguments:
#   $1 — child pid to end when the flag appears
# Sets: _FORCE_HALT_WATCHER_PID ("" when no watcher could be started)
_start_force_halt_watcher() {
  local child_pid="$1"
  _FORCE_HALT_WATCHER_PID=""
  [ -n "$child_pid" ] || return 0
  [ -n "${AUTOMATION_DIR:-}" ] || return 0

  (
    while kill -0 "$child_pid" 2>/dev/null; do
      if [ -f "$AUTOMATION_DIR/FORCE-HALT" ]; then
        echo "FORCE-HALT seen while an entry is running — sending SIGTERM to child pid $child_pid" >&2
        kill -TERM "$child_pid" 2>/dev/null || true
        _fhw_waited=0
        while [ "$_fhw_waited" -lt 10 ] && kill -0 "$child_pid" 2>/dev/null; do
          sleep 1
          _fhw_waited=$(( _fhw_waited + 1 ))
        done
        if kill -0 "$child_pid" 2>/dev/null; then
          echo "FORCE-HALT: child pid $child_pid survived SIGTERM for 10s — sending SIGKILL" >&2
          kill -KILL "$child_pid" 2>/dev/null || true
        fi
        exit 0
      fi
      sleep 5
    done
  ) &
  _FORCE_HALT_WATCHER_PID=$!
}

# --- _run_single_entry ---
# Arguments:
#   $1 — brief_id (for branch naming)
#   $2 — prompt (assembled prompt text)
#   $3 — session_type (Decision 0014 enum)
#   $4 — existing_branch (optional, for task group)
#   $5 — permission_profile (optional, default: "build")
#   $6 — push_on_complete (optional, default: "false")
#   $7 — brief_path (optional; required for sequential task group worktree
#        reuse — Decision 0054 reads the Group: and Execution: fields from it)
#   $8 — entry_model (optional; per-entry model pin — used verbatim, bypasses
#        _resolve_model_for_session; Decision t-0046 Amendment 3)
# Sets globals: _RESULT_OUTCOME, _RESULT_BASELINE, _RESULT_SOLO_MODE, _RESULT_BRANCH
_run_single_entry() {
  local brief_id="$1"
  local prompt="$2"
  local session_type="$3"
  local existing_branch="${4:-}"
  local permission_profile="${5:-build}"
  local push_on_complete="${6:-false}"
  local brief_path="${7:-}"
  local entry_model="${8:-}"

  # Reset globals
  _RESULT_OUTCOME=""
  _RESULT_BASELINE=""
  _RESULT_SOLO_MODE=""
  _RESULT_BRANCH=""
  _CURRENT_WORKTREE_IS_GROUP=false
  _CURRENT_GROUP_NAME=""

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

  # Task group worktree resolution (Decision 0054) — MUST run before
  # branch_manager_setup. When an existing group worktree is reused, the group
  # branch is already checked out in it, and branch_manager_setup's freshness
  # paths cannot operate on a checked-out branch (Case 1 does `git branch -D`,
  # Case 3 does `git checkout`, and git refuses both). _resolve_group_worktree
  # therefore handles freshness worktree-side and tells us to skip the branch
  # manager entirely on the reuse path.
  local _gwt_rc=0
  _resolve_group_worktree "$session_type" "$brief_path" "$existing_branch" "$brief_id" || _gwt_rc=$?
  if [ "$_gwt_rc" -eq 2 ]; then
    # Blocked: occupied, dirty, or on an unexpected branch. The escalation is
    # already written and the lock already released. Do not launch the session.
    _RESULT_OUTCOME="$_GWT_BLOCK_OUTCOME"
    _RESULT_BRANCH="$existing_branch"
    unset REPO_OS_AUTOMATION_ENTRY 2>/dev/null || true
    runner_external_cleanup "$REPO_ROOT" "$brief_id" "init" "" 2>/dev/null || true
    unset REPO_OS_SESSION_ID
    return
  fi
  if [ "$_gwt_rc" -eq 0 ] && [ -n "$_GWT_GROUP" ]; then
    _CURRENT_GROUP_NAME="$_GWT_GROUP"
  fi

  # Branch setup — sets _SETUP_BRANCH; when worktree-isolate active, does NOT checkout
  if [ "$_GWT_REUSE" = true ]; then
    # Reused group worktree: the branch already exists, is checked out, and has
    # been freshness-checked above. Set the output variable the caller expects
    # without touching the branch ref.
    _SETUP_BRANCH="$_GWT_BRANCH"
  else
    # Capture the return code: a bare call lets `set -e` kill the daemon on any
    # non-zero return. rc 3 = the branch is behind main and its rebase hit a
    # conflict (already aborted and verified clean) — block BEFORE any worktree
    # is created, with an escalation naming the files, instead of launching on a
    # stale base.
    local _bm_rc=0
    branch_manager_setup "$brief_id" "$existing_branch" || _bm_rc=$?
    if [ "$_bm_rc" -ne 0 ]; then
      local _bm_outcome="failed:branch-setup" _bm_esc=""
      if [ "$_bm_rc" -eq 3 ]; then
        _bm_outcome="failed:branch-rebase-conflict"
        _bm_esc=$(_write_group_worktree_escalation "esc-branch-rebase-conflict" "$brief_id" \
          "Branch cannot be rebased onto main without manual conflict resolution — brief not started" \
          "branch: $existing_branch, conflicting_files: ${_BM_REBASE_CONFLICT_FILES:-none reported}, detail: ${_BM_REBASE_DETAIL:-}, recovery: rebase the branch onto main by hand, resolve the conflicts, then requeue the brief")
        echo "ERROR: Branch $existing_branch cannot be rebased onto main — conflicting files: ${_BM_REBASE_CONFLICT_FILES:-none reported} — escalation $_bm_esc" >&2
      else
        echo "ERROR: Branch setup failed for $existing_branch (rc $_bm_rc)" >&2
      fi
      _RESULT_OUTCOME="$_bm_outcome"
      _RESULT_BRANCH="$existing_branch"
      unset REPO_OS_AUTOMATION_ENTRY 2>/dev/null || true
      runner_external_cleanup "$REPO_ROOT" "$brief_id" "init" "" 2>/dev/null || true
      unset REPO_OS_SESSION_ID
      return
    fi
  fi

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

  # Capture stderr AND stdout to temp files: blocker reports read stderr, and
  # detect_outcome scans the tail of both for the turn-budget banner (which stream
  # the CLI prints it on was never established). Both are needed or neither is:
  # if either mktemp fails the session runs uncaptured — no banner detection, but
  # no crash — which is the pre-existing degraded path.
  local stderr_file stdout_file
  stderr_file=$(mktemp "${TMPDIR:-/tmp}/runner-stderr-XXXXXX" 2>/dev/null || echo "")
  stdout_file=$(mktemp "${TMPDIR:-/tmp}/runner-stdout-XXXXXX" 2>/dev/null || echo "")
  if [ -z "$stderr_file" ] || [ -z "$stdout_file" ]; then
    [ -n "$stderr_file" ] && rm -f "$stderr_file" 2>/dev/null
    [ -n "$stdout_file" ] && rm -f "$stdout_file" 2>/dev/null
    stderr_file=""
    stdout_file=""
  fi

  # Resolve model: per-entry pin wins over session-type routing (Decision t-0046 Amendment 3).
  # A per-entry model is used verbatim — re-mapping it through the alias table
  # would let a later map change silently rewrite what a study used.
  local model_id
  if [ -n "${entry_model:-}" ]; then
    model_id="$entry_model"
  else
    model_id=$(_resolve_model_for_session "$session_type")
  fi
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
  #
  # Sequential task groups (Decision 0054) target the group-scoped path
  # `.worktrees/tg-<group>` instead, and reuse it across briefs rather than
  # creating one per session.
  local launch_dir="$REPO_ROOT"
  if [ "${REPO_OS_WORKTREE_ISOLATE:-1}" != "0" ] && [ -n "$_SETUP_BRANCH" ]; then
    local worktree_dir="${REPO_ROOT}/.worktrees/${REPO_OS_SESSION_ID}"
    local _wt_is_group=false
    local _wt_added=false
    if [ -n "$_GWT_GROUP" ] && [ -n "$_GWT_DIR" ]; then
      worktree_dir="$_GWT_DIR"
      _wt_is_group=true
    fi
    # Reuse path (Decision 0054): the worktree already exists on the right
    # branch and has passed the clean-start check, so `git worktree add` is
    # skipped. Everything after this point is shared with the create path —
    # notably the plan-approved mirror, which is per-SESSION and so must be
    # re-written for every brief that reuses the worktree.
    _wt_added=false
    if [ "$_GWT_REUSE" = true ]; then
      _wt_added=true
      echo "Reusing task group worktree $worktree_dir (group: $_GWT_GROUP, branch: $_SETUP_BRANCH)" >&2
    elif git worktree add "$worktree_dir" "$_SETUP_BRANCH" 2>/dev/null; then
      _wt_added=true
      if [ "$_wt_is_group" = true ]; then
        echo "Created task group worktree $worktree_dir (group: $_GWT_GROUP, branch: $_SETUP_BRANCH)" >&2
      fi
    fi

    if [ "$_wt_added" = true ]; then
      _CURRENT_WORKTREE_DIR="$worktree_dir"
      _CURRENT_WORKTREE_IS_GROUP="$_wt_is_group"
      launch_dir="$worktree_dir"
      # Propagate the operating mode into the worktree. `.claude/repo-mode` is
      # gitignored (Decision 0024 — child repos keep their own mode), so it is
      # NOT carried over by `git worktree add`. Without it the mode guard falls
      # back to its `child` default inside every headless worktree, which in a
      # template repo blocks legitimate writes to `.claude/hooks/` and invites
      # agents to route around write-guard instead. Copying preserves whatever
      # the parent declares rather than hardcoding a mode; this runs in the
      # runner before the session launches, so the immune-path rule in Decision
      # t-0012 §4 (which governs agent tool-call writes) does not apply.
      if [ -f "$REPO_ROOT/.claude/repo-mode" ]; then
        mkdir -p "$worktree_dir/.claude" 2>/dev/null || true
        if ! cp "$REPO_ROOT/.claude/repo-mode" "$worktree_dir/.claude/repo-mode" 2>/dev/null; then
          # Warn loudly — silently continuing reproduces the exact bug this guards.
          echo "WARNING: Failed to copy .claude/repo-mode into $worktree_dir — mode guard will default to 'child' in this session" >&2
        fi
      fi
      # Mirror plan-approved into the worktree state dir.
      # Decision 0028 (Amendment 2026-08-07): hooks inside the worktree session
      # resolve _REPO_OS_ROOT to the worktree root (settings.json uses relative
      # paths, so BASH_SOURCE[0] = worktree CWD). get_session_state_dir() in the
      # agent therefore targets <worktree>/.claude/.state/wt-sessions/{sid}/,
      # not the main repo path written by state_manager_setup above.
      # Mirroring plan-approved closes the two-root divergence without requiring
      # agents to fall back to a different root path.
      local wt_state_dir="$worktree_dir/.claude/.state/wt-sessions/${REPO_OS_SESSION_ID}"
      if mkdir -p "$wt_state_dir" 2>/dev/null; then
        local main_plan_approved="${REPO_ROOT}/.claude/.state/wt-sessions/${REPO_OS_SESSION_ID}/plan-approved"
        if [ -f "$main_plan_approved" ]; then
          if ! cp "$main_plan_approved" "$wt_state_dir/plan-approved" 2>/dev/null; then
            echo "WARNING: Failed to mirror plan-approved into worktree state dir $wt_state_dir — advance_phase(build) may require manual recovery" >&2
          fi
        else
          echo "WARNING: main repo plan-approved not found at $main_plan_approved — state_manager_setup may not have run" >&2
        fi
      else
        echo "WARNING: Failed to create worktree state dir $wt_state_dir — advance_phase(build) will find no plan-approved" >&2
      fi
    else
      echo "ERROR: Failed to create worktree at $worktree_dir for branch $_SETUP_BRANCH" >&2
      _RESULT_OUTCOME="failed:worktree-creation"
      # Release the group lock taken in _resolve_group_worktree — the session
      # never started, so holding it would wedge the group (Decision 0054).
      if [ -n "$_CURRENT_GROUP_NAME" ]; then
        release_group_worktree_lock "$_CURRENT_GROUP_NAME" "$$" "${REPO_OS_SESSION_ID:-}" 2>/dev/null || true
        _CURRENT_GROUP_NAME=""
      fi
      _CURRENT_WORKTREE_IS_GROUP=false
      unset REPO_OS_AUTOMATION_ENTRY
      unset CLAUDE_HEADLESS
      [ -n "$stderr_file" ] && rm -f "$stderr_file" 2>/dev/null || true
      [ -n "$stdout_file" ] && rm -f "$stdout_file" 2>/dev/null || true
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

  # Turn budget. Was hardcoded `--max-turns 200` at both launch sites, which is
  # what two briefs hit on 2026-10-21 after ~40 minutes each, producing nothing.
  # Tunable without editing code, and it is the documented way out of the
  # `review:turn-budget-exhausted` outcome the detector now raises.
  #
  # Daemon-global on purpose: a per-entry budget would need a queue-entry field,
  # serialisation, the editable-field allowlist and intake validation, and
  # nothing reads one yet.
  local _session_max_turns
  _session_max_turns=$(_parse_config_field "runner" "session_max_turns" 2>/dev/null || echo "400")
  _session_max_turns="${_session_max_turns:-400}"
  # Guard the value: it is interpolated into the CLI invocation, and a
  # non-numeric or absent reading must not produce `--max-turns ''`.
  case "$_session_max_turns" in ''|*[!0-9]*) _session_max_turns=400 ;; esac
  [ "$_session_max_turns" -gt 0 ] || _session_max_turns=400
  local _session_launch_epoch
  _session_launch_epoch=$(date +%s)
  local _ttl_watchdog_pid=""

  local exit_code=0
  if [ -n "$stderr_file" ]; then
    # shellcheck disable=SC2086 — $model_flag intentionally unquoted (expands to nothing when empty)
    # `exec` is load-bearing. Without it the subshell FORKS the child, so `$!`
    # is the SUBSHELL's pid and every kill path signals a wrapper while the real
    # process keeps running: FORCE-HALT and the TTL watchdog were both affected. Confirmed on a live run 2026-10-20 — the
    # tracked pid was a `bash runner.sh` subshell whose child was the real
    # process, and terminating the tracked pid left it running.
    #
    # `cd ... && exec` keeps the ordering: a failed cd still never runs the
    # child. The here-string and the two file redirects are established by the
    # subshell BEFORE exec replaces it, so all survive. `wait` now returns the
    # child's own status, including 143 on SIGTERM, which detect_outcome already
    # handles.
    #
    # Output goes straight to files, NOT through `2> >(tee ...)`. The tee that
    # used to sit here was an intermediate process the subshell's exec orphaned
    # and nothing waited on, so the banner — the LAST thing written — could still
    # be in the pipe when detect_outcome read the file (known-issues R26, which
    # materialised on 2026-10-21). With a direct redirect there is no process to
    # outlive the child: when `wait` returns, the files are complete. The cost is
    # that output reaches daemon.log after the session ends rather than live;
    # it is replayed below, before detect_outcome runs. Do not "fix" a missed
    # read with sleep/sync/retry — removing the intermediate process is the fix.
    (cd "$launch_dir" && exec claude -p \
      --permission-mode bypassPermissions \
      --disallowedTools "$disallowed" \
      --max-turns "$_session_max_turns" \
      $model_flag \
      <<< "$prompt" \
      >"$stdout_file" 2>"$stderr_file") &
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
    # FORCE-HALT must be able to interrupt THIS entry, not just the next one.
    _start_force_halt_watcher "$_CLAUDE_CHILD_PID"
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
    # `exec` for the same reason as the stderr branch above: the tracked pid must
    # be the real process, not a subshell wrapper, or every kill path signals the
    # wrapper and the child survives.
    (cd "$launch_dir" && exec claude -p \
      --permission-mode bypassPermissions \
      --disallowedTools "$disallowed" \
      --max-turns "$_session_max_turns" \
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
    # FORCE-HALT must be able to interrupt THIS entry, not just the next one.
    _start_force_halt_watcher "$_CLAUDE_CHILD_PID"
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
  # Same for the FORCE-HALT watcher. Its own loop exits when the child dies, but
  # reaping it here keeps the daemon from accumulating one zombie poller per
  # entry over a long run.
  if [ -n "${_FORCE_HALT_WATCHER_PID:-}" ]; then
    kill "$_FORCE_HALT_WATCHER_PID" 2>/dev/null || true
    wait "$_FORCE_HALT_WATCHER_PID" 2>/dev/null || true
    _FORCE_HALT_WATCHER_PID=""
  fi
  _CLAUDE_CHILD_PID=""

  # Replay the captured output so it still lands in daemon.log (stdout to stdout,
  # stderr to stderr, as before). The child has exited, so both files are
  # complete. This runs BEFORE detect_outcome, which may itself print to stderr.
  if [ -n "$stdout_file" ] && [ -f "$stdout_file" ]; then
    cat "$stdout_file"
  fi
  if [ -n "$stderr_file" ] && [ -f "$stderr_file" ]; then
    cat "$stderr_file" >&2
  fi

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
    _RESULT_OUTCOME=$(detect_outcome "$exit_code" "$_RESULT_BASELINE" "$_CURRENT_WORKTREE_DIR" "$brief_id" "$stderr_file" "$stdout_file")
    if [ "$_CURRENT_WORKTREE_IS_GROUP" = true ]; then
      # Task group worktree (Decision 0054): keep it for the next brief. The
      # occupancy lock is deliberately NOT released here — it stays held across
      # _solo_merge_if_needed so no other session can claim the worktree in the
      # window where the final brief's merge may be about to remove it. The
      # caller releases it after the merge/seal step.
      echo "Keeping task group worktree $_CURRENT_WORKTREE_DIR for the next brief (group: $_CURRENT_GROUP_NAME)" >&2
    else
      # Remove worktree
      git worktree remove --force "$_CURRENT_WORKTREE_DIR" 2>/dev/null || true
      git worktree prune 2>/dev/null || true
      _CURRENT_WORKTREE_DIR=""
    fi
  else
    # Legacy path or worktree not created
    _RESULT_OUTCOME=$(detect_outcome "$exit_code" "$_RESULT_BASELINE" "$REPO_ROOT" "$brief_id" "$stderr_file" "$stdout_file")
    _RESULT_SOLO_MODE="${_QE_SOLO_MODE:-false}"
    _RESULT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  fi

  # External cleanup (Stop hook doesn't fire in headless mode)
  # With REPO_OS_SESSION_ID set, cleanup routes to the per-session state dir.
  runner_external_cleanup "$REPO_ROOT" "$brief_id" "close" "$_RESULT_BASELINE"

  # Clear the per-brief session ID after cleanup. In daemon mode, restore the
  # daemon's own pinned identity so subsequent daemon-loop get_session_id calls
  # (e.g. the outcome-transition block) stay env-pinned and never write the shared
  # .claude/.session-id; in single brief-id mode there is no daemon id, so unset.
  if [ -n "${_DAEMON_SESSION_ID:-}" ]; then
    export REPO_OS_SESSION_ID="$_DAEMON_SESSION_ID"
  else
    unset REPO_OS_SESSION_ID
  fi

  # Clean up stderr/stdout temp files
  [ -n "$stderr_file" ] && rm -f "$stderr_file" 2>/dev/null || true
  [ -n "$stdout_file" ] && rm -f "$stdout_file" 2>/dev/null || true

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
#   $5 — group_name (optional; when set and this is the final brief, the group
#        worktree is removed after a successful seal — Decision 0054)
# Reads: _RESULT_OUTCOME, _RESULT_SOLO_MODE
# May modify: _RESULT_OUTCOME (on merge conflict → review:merge-conflict)
# BEFORE CHANGING THIS FUNCTION OR THE OUTCOME HANDLING AROUND IT, read this.
#
# Several queued briefs written on 2026-10-12 name this function and the runner's
# outcome handling in their scope. Between then and 2026-10-21 this region
# changed substantially, and a brief written against the older shape can rewrite
# it and silently drop one of the following. Nothing would fail; the behaviour
# would just be gone. Each of these was a live defect that cost a session:
#
#   - `exec claude -p` at BOTH launch sites. Without `exec` the subshell forks,
#     so the tracked `$!` is a wrapper and every kill path signals the wrapper
#     while the real process runs on.
#   - the DIRECT redirects (`>"$stdout_file" 2>"$stderr_file"`) at the capturing
#     launch site, replayed with `cat` after the child is reaped. The earlier
#     `2> >(tee ...)` left an orphaned tee that could still hold the banner when
#     detect_outcome read the file, silently restoring the turn-budget defect
#     (R26; it happened on 2026-10-21). Never reintroduce a process substitution
#     on the launch path, and never paper over a missed read with sleep/sync.
#   - the FORCE-HALT watcher call at both launch sites, which is what lets a
#     force-halt interrupt the entry it was raised against rather than the next.
#   - `--max-turns "$_session_max_turns"`, the configurable turn budget. It was
#     hardcoded at 200 and two briefs exhausted it, producing nothing.
#   - the turn-budget outcome branch in `lib/outcome-detector.sh`, which must
#     stay AHEAD of every exit-0 success branch. A session that runs out of turns
#     exits zero, so without it an exhausted brief is recorded `completed` and
#     its queue entry leaves the queue as though the work were done.
#   - the circuit-breaker cooldown and its FORCE-HALT exemption.
#   - the merge-finality gate here: this function merges only for a session the
#     runner considers final. RUNNER-PARITY row 16 records that task-group
#     finality is derived from the entry's `solo_mode` flag, so setting that flag
#     on a non-final group brief makes the runner merge and SEAL the group branch
#     early, stranding the remaining briefs. Checked on 2026-10-21: every
#     task-group entry in the queue had it set, including non-final ones.
#
# RUNNER-PARITY.md is the fuller catalogue of this region; `known-issues.md`
# R25-R30 carry the defect histories.
_solo_merge_if_needed() {
  local entry_current_branch="$1"
  local push_on_complete="${2:-false}"
  local brief_id="${3:-}"
  local work_order_id="${4:-}"
  local group_name="${5:-}"

  local _outcome_type="${_RESULT_OUTCOME%%:*}"

  # --- Non-final task group briefs must not merge (Decision 0013 §7) ---
  # The seal was already gated on finality below, but the MERGE was not, so
  # every completed solo task group brief merged to main as it finished rather
  # than only the final one. `session-close-check.sh` gates its merge on
  # is_final_brief; this is the runner side of that parity contract.
  #
  # The observed damage was not just an early merge: merging brief N made the
  # group branch an ancestor of main, so branch_manager_setup's Case 1 then
  # deleted and recreated the branch before brief N+1 — the shared group branch
  # did not survive between briefs at all.
  #
  # Standalone work is unaffected. _is_final_taskgroup_entry returns 0 (final)
  # when work_order_id is empty, and also for a `type: single` work order whose
  # only entry is this one, so single-entry merges behave exactly as before.
  if [ "$_outcome_type" = "completed" ] && [ "$_RESULT_SOLO_MODE" = "true" ] \
     && [ -n "$entry_current_branch" ] && ! _is_final_taskgroup_entry "$brief_id" "$work_order_id"; then
    echo "Task group brief is not final — skipping merge and seal; branch '$entry_current_branch' stays open for the next brief (Decision 0013 §7)" >&2
    if [ -n "$group_name" ]; then
      release_group_worktree_lock "$group_name" "$$" "${REPO_OS_SESSION_ID:-}" || true
      _CURRENT_GROUP_NAME=""
    fi
    return
  fi

  if [ "$_outcome_type" = "completed" ] && [ "$_RESULT_SOLO_MODE" = "true" ] && [ -n "$entry_current_branch" ]; then
    case "$entry_current_branch" in
      feature/*|fix/*|hotfix/*)
        local _merge_ok=false
        local _merge_conflict=false
        local _conflict_files=""
        local _pre_merge_sha=""
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
            _pre_merge_sha=$(git -C "$_main_repo" rev-parse HEAD 2>/dev/null || echo "")
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
          _pre_merge_sha=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "")
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
            delete_merged_session_branch "$entry_current_branch" "${_main_repo:-}"
          fi
          # Detect ref-move anomaly: if main HEAD was unchanged by the merge,
          # a 'git branch -f main' ref-move likely preceded this call. Log loudly.
          local _post_merge_sha
          _post_merge_sha=$(git -C "${_main_repo:-$REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo "")
          if [ -n "$_pre_merge_sha" ] && [ "$_pre_merge_sha" = "$_post_merge_sha" ]; then
            echo "WARNING: Solo merge: 'Already up to date' — main HEAD unchanged by merge of '$entry_current_branch'. Possible prior ref-move by agent. Applying working-tree sync." >&2
          fi
          echo "Solo merge: $entry_current_branch → main (success)" >&2
          # Post-merge working-tree sync (unconditional — Decision 0030).
          # Syncs the main repo index and working tree to HEAD. Critical when a
          # worktree agent moved the main ref (ref-move): the ref pointer advances
          # but the main working tree's index/content remain frozen at the old state.
          # Uses git -C in all cases (_main_repo set = worktree path; absent = runner
          # is already in REPO_ROOT which IS the main repo — both cases handled).
          local _sync_dir="${_main_repo:-$REPO_ROOT}"
          if ! git -C "$_sync_dir" reset HEAD -- . 2>/dev/null; then
            echo "WARNING: Solo merge: post-merge index reset failed for '$_sync_dir'" >&2
          fi
          if ! git -C "$_sync_dir" checkout HEAD -- . 2>/dev/null; then
            echo "WARNING: Solo merge: post-merge working tree restore failed for '$_sync_dir'" >&2
          fi
          # Stale-tree detection backstop (Decision 0030): after sync, verify main
          # tree matches HEAD. A non-quiet result means sync could not repair the
          # stale content — escalate rather than silently continue.
          if ! git -C "$_sync_dir" diff HEAD --quiet 2>/dev/null; then
            echo "ERROR: Main working tree still stale after post-merge sync — index/tree differ from HEAD. Merged code is committed but absent from disk. Repair: 'git -C $_sync_dir checkout HEAD -- . && git -C $_sync_dir clean -fd'" >&2
            local _esc_dir="$REPO_ROOT/.claude/.automation/escalations"
            mkdir -p "$_esc_dir" 2>/dev/null || true
            local _stale_esc_id="esc-stale-main-$(date +%Y%m%d-%H%M%S)-$$"
            {
              printf 'escalation:\n'
              printf '  id: "%s"\n' "$_stale_esc_id"
              printf '  queue_entry_id: "%s"\n' "$brief_id"
              printf '  type: "gate-failure"\n'
              printf '  severity: "blocking"\n'
              printf '  phase_at_exit: "close"\n'
              printf '  tag_at_exit: "close"\n'
              printf '  message: "Main working tree stale after solo merge sync — index/tree differ from HEAD. Merged code committed but absent from disk (likely caused by prior ref-move from worktree)."\n'
              printf '  context: "sync_dir: %s, branch: %s"\n' "$_sync_dir" "$entry_current_branch"
              printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
              printf '  resolved: false\n'
              printf '  resolution: ""\n'
            } > "$_esc_dir/${_stale_esc_id}.yaml" 2>/dev/null || true
            echo "Escalation written: $_stale_esc_id" >&2
          fi
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

  # --- Task group worktree lifetime (Decision 0054) ---
  # The group worktree outlives individual briefs, so it is removed only once
  # the final brief's branch has actually been sealed. The closed-branches
  # ledger is the primary signal rather than a flag threaded through the five
  # seal sites above: it is the same signal Decision 0013 uses, and it already
  # encodes the case that matters most — a merge conflict deliberately leaves
  # the branch unsealed for retry, so the worktree must survive too.
  # Either way the occupancy lock is released here: it was held across the
  # merge so no other session could claim the worktree mid-merge.
  if [ -n "$group_name" ]; then
    local _gwt_sealed=false
    if [ -n "$entry_current_branch" ] \
       && grep -qxF "$entry_current_branch" "$REPO_ROOT/.claude/local/closed-branches" 2>/dev/null \
       && _is_final_taskgroup_entry "$brief_id" "$work_order_id"; then
      _gwt_sealed=true
    fi
    if [ "$_gwt_sealed" = true ]; then
      remove_group_worktree "$group_name" "$$" "${REPO_OS_SESSION_ID:-}" || true
      echo "Removed task group worktree for '$group_name' — final brief merged and sealed" >&2
      _CURRENT_WORKTREE_DIR=""
      _CURRENT_WORKTREE_IS_GROUP=false
    else
      release_group_worktree_lock "$group_name" "$$" "${REPO_OS_SESSION_ID:-}" || true
    fi
    _CURRENT_GROUP_NAME=""
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
  # Single-shot mode builds a minimal prompt and has no brief path, so the
  # Decision 0054 group-worktree path does not engage here — the entry falls
  # back to a per-session worktree (Decision 0033).
  _run_single_entry "$BRIEF_ID" "$PROMPT" "$SESSION_TYPE" "$EXISTING_BRANCH" "${_QE_PERMISSION_PROFILE:-build}" "false" "${_QE_BRIEF_PATH:-}" ""

  # Solo merge + branch seal (Phase 2: extracted from _run_single_entry)
  _solo_merge_if_needed "$_RESULT_BRANCH" "false" "$BRIEF_ID" "" "$_CURRENT_GROUP_NAME"

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

# --- Pin a stable daemon-level identity (per-process session identity) ---
# The daemon's own loop calls get_session_id/get_session_state_dir (startup
# sweeps, review-item scoring, cleanup). Without REPO_OS_SESSION_ID those hit
# get_session_id's no-stdin fallback and write a SHARED flat .claude/.session-id,
# which an interactive window can then ADOPT (no sidecar exists to trigger a mint)
# — re-aliasing the very thing the per-process identity scheme fixes. Pinning an
# env id here makes the daemon's get_session_id return it and write neither the
# flat file nor a sidecar. Per-brief processing overrides this with its own
# isolated daemon-<ts> id (+ worktree); the loop re-asserts this id each iteration.
_DAEMON_SESSION_ID="daemon-main-${_DAEMON_START_EPOCH}-$$"
export REPO_OS_SESSION_ID="$_DAEMON_SESSION_ID"

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
  # Re-assert the daemon's own identity. Per-brief processing overrides
  # REPO_OS_SESSION_ID with an isolated daemon-<ts> id (and uses it for post-brief
  # cleanup); restoring it here keeps the daemon loop's own get_session_id calls
  # env-pinned so they never touch the shared .claude/.session-id.
  export REPO_OS_SESSION_ID="$_DAEMON_SESSION_ID"

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
    # Task group worktrees survive a force-halt (Decision 0054): the group is
    # mid-flight and its working state is what the operator will want on
    # restart. Only the occupancy lock is released.
    # Release the lock on _CURRENT_GROUP_NAME alone, for the same reason as
    # _runner_crash_cleanup: the lock is taken before _CURRENT_WORKTREE_IS_GROUP
    # is set, so gating the release on that flag would miss the window.
    if [ -n "$_CURRENT_GROUP_NAME" ]; then
      release_group_worktree_lock "$_CURRENT_GROUP_NAME" "$$" "${REPO_OS_SESSION_ID:-}" 2>/dev/null || true
      _CURRENT_GROUP_NAME=""
    fi
    if [ "$_CURRENT_WORKTREE_IS_GROUP" = true ]; then
      if [ -n "$_CURRENT_WORKTREE_DIR" ]; then
        echo "FORCE-HALT: task group worktree '$_CURRENT_WORKTREE_DIR' left in place (Decision 0054)" >&2
      fi
      _CURRENT_WORKTREE_DIR=""
      _CURRENT_WORKTREE_IS_GROUP=false
    elif [ -n "$_CURRENT_WORKTREE_DIR" ] && [ -d "$_CURRENT_WORKTREE_DIR" ]; then
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
            _fh_wo_status=$(wo_check_completion "$_QE_WORK_ORDER_ID" 2>/dev/null) || {
              echo "WARNING: wo_check_completion failed for work order $_QE_WORK_ORDER_ID after force-halt of entry $_CURRENT_ENTRY_ID" >&2
            }
            case "$_fh_wo_status" in
              failed)
                review_log_append "work-order-failed" "$_QE_WORK_ORDER_ID" "" \
                  "Work order $_QE_WORK_ORDER_ID failed — entry $_CURRENT_ENTRY_ID force-halted. Recovery: queue-cli.sh reopen-wo $_QE_WORK_ORDER_ID" 2>/dev/null || true
                ;;
              escalated)
                review_log_append "work-order-escalated" "$_QE_WORK_ORDER_ID" "" \
                  "Work order $_QE_WORK_ORDER_ID escalated — entry $_CURRENT_ENTRY_ID force-halted. Recovery: queue-cli.sh reopen-wo $_QE_WORK_ORDER_ID" 2>/dev/null || true
                ;;
              completed)
                review_log_append "work-order-completed" "$_QE_WORK_ORDER_ID" "" \
                  "Work order $_QE_WORK_ORDER_ID completed — all children terminal after force-halt of $_CURRENT_ENTRY_ID" 2>/dev/null || true
                ;;
              "")
                echo "WARNING: wo_check_completion returned empty status for work order $_QE_WORK_ORDER_ID (force-halt, entry $_CURRENT_ENTRY_ID)" >&2
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
    # Message stays general: the count can be 4+ after a failed probe, and the
    # fail-closed arm trips with no readable count at all. Naming the cooldown
    # here matters because this is the line an operator watches while waiting a
    # window out — it was previously the only breaker message that never
    # mentioned there was a way out.
    echo "Circuit breaker tripped. Sleeping 60s... (see 'queue-cli.sh status' for the failure count; it self-expires for one probe entry after runner.circuit_breaker_cooldown_seconds, or clear it with 'queue-cli.sh reset-breaker')" >&2
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
              _sr_wo_status=$(wo_check_completion "$_QE_WORK_ORDER_ID" 2>/dev/null) || {
                echo "WARNING: wo_check_completion failed for work order $_QE_WORK_ORDER_ID after idle-scan recovery of entry $_sr_entry_id" >&2
              }
              case "$_sr_wo_status" in
                failed)
                  review_log_append "work-order-failed" "$_QE_WORK_ORDER_ID" "" \
                    "Work order $_QE_WORK_ORDER_ID failed — stranded entry $_sr_entry_id recovered by idle scan. Recovery: queue-cli.sh reopen-wo $_QE_WORK_ORDER_ID" 2>/dev/null || true
                  ;;
                escalated)
                  review_log_append "work-order-escalated" "$_QE_WORK_ORDER_ID" "" \
                    "Work order $_QE_WORK_ORDER_ID escalated — stranded entry $_sr_entry_id recovered by idle scan. Recovery: queue-cli.sh reopen-wo $_QE_WORK_ORDER_ID" 2>/dev/null || true
                  ;;
                completed)
                  review_log_append "work-order-completed" "$_QE_WORK_ORDER_ID" "" \
                    "Work order $_QE_WORK_ORDER_ID completed — all children terminal after idle-scan recovery of $_sr_entry_id" 2>/dev/null || true
                  ;;
                "")
                  echo "WARNING: wo_check_completion returned empty status for work order $_QE_WORK_ORDER_ID (idle-scan recovery, entry $_sr_entry_id)" >&2
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

      # --- Work order reconciliation pass (level-triggered safety net) ---
      # Catches any WO left non-terminal by the event-driven path due to daemon
      # crashes, partial writes, or missed transitions. Runs inside queue lock.
      _wo_dir_path=$(_queue_dir)/work-orders
      if [ -d "$_wo_dir_path" ]; then
        for _rec_wo_file in "$_wo_dir_path"/*.yaml; do
          [ -f "$_rec_wo_file" ] || continue
          _load_work_order "$_rec_wo_file"
          # Skip already-terminal WOs
          case "$_WO_STATUS" in
            completed) continue ;;
          esac
          # Non-terminal WO — attempt reconciliation under queue lock
          _rec_wo_id="$_WO_ID"
          if acquire_queue_lock; then
            _rec_new_status=$(wo_reconcile "$_rec_wo_id" 2>/dev/null) || {
              echo "WARNING: wo_reconcile failed for work order $_rec_wo_id (idle-scan reconciliation pass)" >&2
            }
            _rebuild_queue_index || true
            release_queue_lock
            if [ -n "$_rec_new_status" ] && [ "$_rec_new_status" != "$_WO_STATUS" ]; then
              review_log_append "work-order-reconciled" "$_rec_wo_id" "" \
                "Work order $_rec_wo_id reconciled: $_WO_STATUS → $_rec_new_status (idle-scan safety net)" 2>/dev/null || true
              echo "INFO: Work order $_rec_wo_id reconciled: $_WO_STATUS → $_rec_new_status" >&2
            fi
          else
            echo "WARNING: Could not acquire lock for WO reconciliation of $_rec_wo_id" >&2
          fi
        done
      fi

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
  ENTRY_PERMISSION_PROFILE="${_QE_PERMISSION_PROFILE:-build}"
  ENTRY_MODEL="${_QE_MODEL:-}"

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
        # (message-only distinction: a non-final sequential group brief is expected
        # to have an unmerged branch — see _unmerged_branch_message)
        _unmerged_branch_message "$ENTRY_ID" "$ENTRY_BRANCH" "$_commits_ahead" "$ENTRY_BRIEF_PATH" "$ENTRY_WORK_ORDER_ID" >&2 || true
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
        _wo_new_status=$(wo_check_completion "$ENTRY_WORK_ORDER_ID" 2>/dev/null) || {
          echo "WARNING: wo_check_completion failed for work order $ENTRY_WORK_ORDER_ID after idempotent completion of entry $ENTRY_ID" >&2
        }
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
          "")
            echo "WARNING: wo_check_completion returned empty status for work order $ENTRY_WORK_ORDER_ID (idempotent completion, entry $ENTRY_ID)" >&2
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
      # Never fatal: at the cap the entry and its siblings are blocked with an
      # escalation (see _handle_wo_deferral) and the daemon moves on.
      _handle_wo_deferral "$ENTRY_ID" "$ENTRY_WORK_ORDER_ID" "$_wo_defer_reason" || true
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
  _run_single_entry "$ENTRY_ID" "$PROMPT" "$ENTRY_SESSION_TYPE" "$ENTRY_BRANCH" "$ENTRY_PERMISSION_PROFILE" "$ENTRY_PUSH" "$ENTRY_BRIEF_PATH" "$ENTRY_MODEL"

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
  # _CURRENT_GROUP_NAME is set by _resolve_group_worktree for sequential task
  # group entries (Decision 0054) and empty for every other entry type; passing
  # it makes the group worktree removal/lock release part of the same step that
  # seals the branch.
  _GWT_ENTRY_GROUP="$_CURRENT_GROUP_NAME"
  _solo_merge_if_needed "$_RESULT_BRANCH" "$ENTRY_PUSH" "$ENTRY_ID" "$ENTRY_WORK_ORDER_ID" "$_GWT_ENTRY_GROUP"

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
        failed:empty-result|failed:group-worktree-rebase-conflict|failed:branch-rebase-conflict)
          # A rebase conflict cannot be fixed by retrying: the group is blocked until
          # the operator rebases by hand (or reset-group-worktree) and runs reopen-wo.
          if ! queue_fail_terminal "$ENTRY_ID" "${OUTCOME_RAW#failed:}: terminal, operator action required (see escalation)"; then
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
        _wo_new_status=$(wo_check_completion "$ENTRY_WORK_ORDER_ID" 2>/dev/null) || {
          echo "WARNING: wo_check_completion failed for work order $ENTRY_WORK_ORDER_ID after completion of entry $ENTRY_ID" >&2
        }
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
          "")
            echo "WARNING: wo_check_completion returned empty status for work order $ENTRY_WORK_ORDER_ID (entry $ENTRY_ID completed)" >&2
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
        _wo_new_status=$(wo_check_completion "$ENTRY_WORK_ORDER_ID" 2>/dev/null) || {
          echo "WARNING: wo_check_completion failed for work order $ENTRY_WORK_ORDER_ID after escalation of entry $ENTRY_ID" >&2
        }
        case "$_wo_new_status" in
          failed)
            review_log_append "work-order-failed" "$ENTRY_WORK_ORDER_ID" "" \
              "Work order $ENTRY_WORK_ORDER_ID failed — sibling entry failed. Recovery: queue-cli.sh reopen-wo $ENTRY_WORK_ORDER_ID" 2>/dev/null || true
            ;;
          escalated)
            review_log_append "work-order-escalated" "$ENTRY_WORK_ORDER_ID" "" \
              "Work order $ENTRY_WORK_ORDER_ID escalated — entry requires review" 2>/dev/null || true
            ;;
          "")
            echo "WARNING: wo_check_completion returned empty status for work order $ENTRY_WORK_ORDER_ID (entry $ENTRY_ID escalated)" >&2
            ;;
        esac
      fi
      ;;
    failed|*)
      # An operator force-halt is not a repo failure. Since the in-session
      # watcher actually kills the child, a force-halted session now returns 143
      # and lands here, where it previously could not reach outcome detection at
      # all. Counting it would mean three operator force-halts trip the breaker
      # and block the next start for a full cooldown window — a failure the
      # operator did not earn. The flag is still present at this point because
      # the watcher deliberately leaves it: the loop-top handler needs it to
      # stop the daemon and to sweep the worktree. Note it does NOT re-handle
      # the entry — `_CURRENT_ENTRY_ID` is cleared before this arm runs, and the
      # entry has already been through `queue_fail` on the normal failure path.
      # Two consequences, both pre-existing and recorded rather than fixed here:
      # a force-halted entry gets no escalation artifact, and the halt consumes
      # one of its retries.
      if [ -f "$AUTOMATION_DIR/FORCE-HALT" ]; then
        echo "Session terminated by FORCE-HALT — not counted against the circuit breaker." >&2
      elif [ "$OUTCOME_RAW" = "failed:group-worktree-rebase-conflict" ] || [ "$OUTCOME_RAW" = "failed:branch-rebase-conflict" ]; then
        # No session ran; the conflict is a repo-content problem the operator must
        # resolve. Counting it would let one conflicted group trip the breaker
        # and stall every unrelated queue entry.
        echo "Rebase conflict — not counted against the circuit breaker." >&2
      else
        _circuit_breaker_increment
      fi
      _SESSIONS_FAILED=$((_SESSIONS_FAILED + 1))
      _LAST_SESSION_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      _CONSECUTIVE_SESSION_COUNT=$((_CONSECUTIVE_SESSION_COUNT + 1))

      # Review log + work order lifecycle (only on terminal failure — retries exhausted)
      # Detect terminal failure by checking if queue_fail moved the entry to failed/
      if [ -n "$ENTRY_WORK_ORDER_ID" ]; then
        if [ -f "$(_queue_dir)/failed/${ENTRY_ID}.yaml" ]; then
          review_log_append "entry-failed" "$ENTRY_WORK_ORDER_ID" "$ENTRY_ID" \
            "Entry $ENTRY_ID failed — retries exhausted ($ENTRY_SESSION_TYPE)" 2>/dev/null || true
          _wo_new_status=$(wo_check_completion "$ENTRY_WORK_ORDER_ID" 2>/dev/null) || {
            echo "WARNING: wo_check_completion failed for work order $ENTRY_WORK_ORDER_ID after terminal failure of entry $ENTRY_ID" >&2
          }
          case "$_wo_new_status" in
            failed)
              review_log_append "work-order-failed" "$ENTRY_WORK_ORDER_ID" "" \
                "Work order $ENTRY_WORK_ORDER_ID failed — entry $ENTRY_ID failed. Recovery: queue-cli.sh reopen-wo $ENTRY_WORK_ORDER_ID" 2>/dev/null || true
              ;;
            escalated)
              review_log_append "work-order-escalated" "$ENTRY_WORK_ORDER_ID" "" \
                "Work order $ENTRY_WORK_ORDER_ID escalated — entry failed" 2>/dev/null || true
              ;;
            "")
              echo "WARNING: wo_check_completion returned empty status for work order $ENTRY_WORK_ORDER_ID (terminal failure, entry $ENTRY_ID)" >&2
              ;;
          esac
        fi
      fi
      ;;
  esac

# --- Task group worktree lifetime: group failure (Decision 0054) ---
# A group worktree survives an individual brief's failure — the restart reuses
# it, and its working state is what the operator inspects. It does NOT survive
# the failure of the whole work order: at that point no further brief will run,
# and the tree is only debris holding a branch checked out. Placed after the
# outcome `case` rather than inside its three `failed)` arms so there is one
# removal site keyed on the work order's actual terminal status, not on which
# arm happened to run.
# Abandonment reaches the same end by a different route: queue-cli.sh moves the
# work order to a terminal status, and the next cleanup sweep removes any group
# worktree whose branch is sealed or stale (group-worktree-sweep.sh).
if [ -n "${_GWT_ENTRY_GROUP:-}" ] && [ -n "$ENTRY_WORK_ORDER_ID" ]; then
  if wo_is_failed "$ENTRY_WORK_ORDER_ID" 2>/dev/null; then
    remove_group_worktree "$_GWT_ENTRY_GROUP" "$$" "" 2>/dev/null || true
    echo "Removed task group worktree for '$_GWT_ENTRY_GROUP' — work order $ENTRY_WORK_ORDER_ID failed" >&2
  fi
fi
_GWT_ENTRY_GROUP=""

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
