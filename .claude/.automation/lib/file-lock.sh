#!/usr/bin/env bash
# File lock — exclusive lock for queue mutations.
# Sourced by runner.sh. NOT executed standalone.
# Decision 0017 — Operator Automation Layer.
#
# Provides acquire/release functions for exclusive queue access.
# Lock scope: single state transition (not entire session).
# Uses flock on Linux, mkdir-based lock on macOS (where flock is unavailable).
#
# Depends on (sourced by runner.sh before this file):
#   runner.sh sets AUTOMATION_DIR

set -euo pipefail

# --- Lock directory/file path ---
_LOCK_DIR=""
_lock_dir() {
  if [ -z "$_LOCK_DIR" ]; then
    _LOCK_DIR="${AUTOMATION_DIR:-.claude/.automation}/.queue-lock"
  fi
  printf '%s' "$_LOCK_DIR"
}

_LOCK_HELD=false
_LOCK_METHOD=""  # "flock" or "mkdir"

# --- Detect lock method ---
_detect_lock_method() {
  if [ -z "$_LOCK_METHOD" ]; then
    if command -v flock > /dev/null 2>&1; then
      _LOCK_METHOD="flock"
    else
      _LOCK_METHOD="mkdir"
    fi
  fi
}

# --- File descriptor for flock (use 9 to avoid conflicts) ---
_LOCK_FD=9

# ============================================================
# Public API
# ============================================================

# --- Acquire exclusive queue lock ---
# Uses flock (Linux) or mkdir (macOS) with 5-second timeout.
# Returns: 0 on success, 1 on timeout or error
acquire_queue_lock() {
  _detect_lock_method
  local lock_path
  lock_path=$(_lock_dir)

  # Ensure parent directory exists
  mkdir -p "$(dirname "$lock_path")" 2>/dev/null || true

  if [ "$_LOCK_METHOD" = "flock" ]; then
    # flock-based: open file descriptor and acquire exclusive lock
    local lock_file="${lock_path}.flock"
    eval "exec ${_LOCK_FD}>\"$lock_file\""
    if ! flock -w 5 -x "$_LOCK_FD" 2>/dev/null; then
      echo "ERROR: Queue lock timeout (5s) — another process holds the lock" >&2
      eval "exec ${_LOCK_FD}>&-" 2>/dev/null || true
      return 1
    fi
  else
    # mkdir-based: atomic directory creation as lock
    # Retry loop with 5-second timeout (0.5s intervals, 10 attempts)
    # Audit 6.5: increment attempts at top to prevent infinite spin on
    # stale lock detection (rm + continue was skipping the counter).
    local attempts=0 max_attempts=10
    local _lock_acquired_mkdir=false
    while [ "$attempts" -lt "$max_attempts" ]; do
      attempts=$((attempts + 1))
      if mkdir "$lock_path" 2>/dev/null; then
        # Write PID for stale lock detection
        echo "$$" > "$lock_path/pid" 2>/dev/null || true
        _lock_acquired_mkdir=true
        break
      fi

      # Check for stale lock (process no longer running)
      if [ -f "$lock_path/pid" ]; then
        local lock_pid
        lock_pid=$(cat "$lock_path/pid" 2>/dev/null || echo "")
        if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
          # Stale lock — remove and retry (counted against max_attempts)
          rm -rf "$lock_path" 2>/dev/null || true
          continue
        fi
      fi

      sleep 0.5
    done

    if [ "$_lock_acquired_mkdir" = false ]; then
      echo "ERROR: Queue lock timeout (5s) — another process holds the lock" >&2
      return 1
    fi
  fi

  _LOCK_HELD=true
  return 0
}

# --- Release queue lock ---
# Safe to call even if lock is not held.
release_queue_lock() {
  if [ "$_LOCK_HELD" = true ]; then
    _detect_lock_method
    local lock_path
    lock_path=$(_lock_dir)

    if [ "$_LOCK_METHOD" = "flock" ]; then
      eval "exec ${_LOCK_FD}>&-" 2>/dev/null || true
    else
      rm -rf "$lock_path" 2>/dev/null || true
    fi

    _LOCK_HELD=false
  fi
}
