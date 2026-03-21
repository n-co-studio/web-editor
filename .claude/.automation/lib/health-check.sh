#!/usr/bin/env bash
# Health check — file-based daemon status reporting.
# Writes `.automation/.health` atomically each poll cycle.
# Sourced by runner.sh — requires AUTOMATION_DIR and daemon lifecycle globals.

# --- Health file path (lazy-init, cached) ---
_HEALTH_FILE=""
_health_file() {
  if [ -z "$_HEALTH_FILE" ]; then
    _HEALTH_FILE="$AUTOMATION_DIR/.health"
  fi
  printf '%s' "$_HEALTH_FILE"
}

# --- Write health status atomically ---
# Arguments:
#   $1 — status string (idle, running, disabled, stopped, circuit-breaker)
# Reads globals: _DAEMON_START_EPOCH, _CURRENT_ENTRY_ID,
#   _SESSIONS_COMPLETED, _SESSIONS_FAILED, _LAST_SESSION_AT
_write_health() {
  local status="$1"
  local hf
  hf=$(_health_file)
  local now_epoch
  now_epoch=$(date +%s)
  local uptime=0
  if [ -n "$_DAEMON_START_EPOCH" ] && [ "$_DAEMON_START_EPOCH" -gt 0 ] 2>/dev/null; then
    uptime=$((now_epoch - _DAEMON_START_EPOCH))
  fi
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  {
    printf 'status: %s\n' "$status"
    printf 'timestamp: %s\n' "$ts"
    printf 'pid: %s\n' "$$"
    printf 'uptime_seconds: %s\n' "$uptime"
    printf 'current_entry: %s\n' "${_CURRENT_ENTRY_ID:-}"
    printf 'sessions_completed: %s\n' "$_SESSIONS_COMPLETED"
    printf 'sessions_failed: %s\n' "$_SESSIONS_FAILED"
    printf 'last_session_at: %s\n' "$_LAST_SESSION_AT"
  } > "${hf}.tmp" 2>/dev/null && mv "${hf}.tmp" "$hf" 2>/dev/null || true
}

# --- Remove health file on shutdown ---
_remove_health() {
  local hf
  hf=$(_health_file)
  rm -f "$hf" "${hf}.tmp" 2>/dev/null || true
}

# --- Read health status (for external consumers) ---
# Prints the current status from the health file, or "unknown" if absent.
health_status() {
  local hf
  hf=$(_health_file)
  if [ -f "$hf" ]; then
    grep '^status:' "$hf" 2>/dev/null | sed 's/^status: *//' | head -1
  else
    printf 'unknown'
  fi
}

# --- Check if daemon is alive (for external consumers) ---
# Returns 0 if health file exists and PID is running, 1 otherwise.
health_is_alive() {
  local hf
  hf=$(_health_file)
  [ -f "$hf" ] || return 1
  local pid
  pid=$(grep '^pid:' "$hf" 2>/dev/null | sed 's/^pid: *//' | tr -d '[:space:]' | head -1)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}
