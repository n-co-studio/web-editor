#!/usr/bin/env bash
# Blocker reporter — structured failure report writer for headless runner.
# Sourced by runner.sh. NOT executed standalone.
# Decision 0017 — runner-writes-state invariant (shell-written YAML, not model-written).
#
# Produces YAML reports per blocker-report.yaml schema with extensions:
#   type classification, branch, timestamp, stderr capture, analytics events.
#
# Depends on (sourced by runner.sh before this file):
#   runner.sh sets REPO_ROOT, AUTOMATION_DIR, CONFIG_FILE
#   _analytics-helper.sh — get_session_id
#   _phase-helper.sh — _validate_phase_session, _PS_* cache variables
#   queue-manager.sh — _parse_config_field

set -euo pipefail

# Audit C6: guard against missing _phase-helper.sh dependency
if ! declare -f _validate_phase_session > /dev/null 2>&1; then
  echo "ERROR: _phase-helper.sh must be sourced before $(basename "${BASH_SOURCE[0]}")" >&2
  return 1 2>/dev/null || exit 1
fi

# --- Classify failure type ---
# Arguments:
#   $1 — exit_code
#   $2 — has_dirty_tree (true/false)
# Output: type string on stdout
_classify_failure_type() {
  local exit_code="$1"
  local has_dirty_tree="$2"

  if [ "$exit_code" -eq 124 ]; then
    echo "timeout"
    return
  fi
  if [ "$exit_code" -ne 0 ] && [ "$has_dirty_tree" = "true" ]; then
    echo "crash"
    return
  fi
  if [ "$exit_code" -ne 0 ]; then
    echo "clean-failure"
    return
  fi
  # exit 0 but called as failure — likely gate issue
  echo "gate_failure"
}

# --- Capture stderr tail from file ---
# Arguments:
#   $1 — stderr_file path (may not exist)
#   $2 — max_lines
# Output: escaped single-line string on stdout
_capture_stderr_tail() {
  local stderr_file="$1"
  local max_lines="${2:-50}"

  if [ ! -f "$stderr_file" ]; then
    echo ""
    return
  fi

  local tail_content
  tail_content=$(tail -n "$max_lines" "$stderr_file" 2>/dev/null || true)
  # Escape double quotes and replace newlines with literal \n for YAML
  local escaped=""
  local _line _first=true
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line="${_line//\"/\\\"}"
    if [ "$_first" = true ]; then
      escaped="$_line"
      _first=false
    else
      escaped="${escaped}\\n${_line}"
    fi
  done <<< "$tail_content"
  printf '%s' "$escaped"
}

# --- Capture recent block analytics events ---
# Greps the current day's analytics NDJSON for block events from current session.
# Arguments:
#   $1 — repo_root
# Output: YAML list items on stdout (or "[]" if none)
_capture_analytics_events() {
  local repo_root="$1"

  local repo_name
  repo_name=$(basename "$repo_root")
  local today
  today=$(date -u +%Y-%m-%d)
  local events_file="$HOME/.local/share/repo-os-analytics/$repo_name/events/${today}.ndjson"

  if [ ! -f "$events_file" ]; then
    echo "[]"
    return
  fi

  local session_id=""
  if [ -f "$repo_root/.claude/.session-id" ]; then
    session_id=$(cat "$repo_root/.claude/.session-id" 2>/dev/null || true)
  fi

  if [ -z "$session_id" ]; then
    echo "[]"
    return
  fi

  # Grep for block events from this session (simple text grep, no jq dependency)
  local block_lines
  block_lines=$(grep "\"sid\":\"$session_id\"" "$events_file" 2>/dev/null \
    | grep '"out":"block"' 2>/dev/null \
    | tail -n 10 || true)

  if [ -z "$block_lines" ]; then
    echo "[]"
    return
  fi

  # Format as YAML list (compact — one line per event)
  local result=""
  local _evt_line _evt_first=true
  while IFS= read -r _evt_line || [ -n "$_evt_line" ]; do
    [ -z "$_evt_line" ] && continue
    _evt_line="${_evt_line//\"/\\\"}"
    if [ "$_evt_first" = true ]; then
      result="[\"${_evt_line}\""
      _evt_first=false
    else
      result="${result}, \"${_evt_line}\""
    fi
  done <<< "$block_lines"
  result="${result}]"
  printf '%s' "$result"
}

# ============================================================
# Public API
# ============================================================

# --- Write a structured blocker report ---
# Creates a YAML report in .claude/.automation/reports/ per schema.
# Arguments:
#   $1 — exit_code
#   $2 — repo_root
#   $3 — entry_id (queue entry that failed; empty for single-shot)
#   $4 — stderr_file (path to captured stderr; empty if not captured)
write_blocker_report() {
  local exit_code="$1"
  local repo_root="$2"
  local entry_id="${3:-}"
  local stderr_file="${4:-}"

  local reports_dir="$repo_root/.claude/.automation/reports"
  mkdir -p "$reports_dir" 2>/dev/null || true

  local report_id
  report_id="report-$(date +%Y%m%d-%H%M%S)-$$"
  local report_file="$reports_dir/${report_id}.yaml"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Read phase-state if available
  local phase_at_exit="" tag_at_exit=""
  local state_file="$repo_root/.claude/.state/phase-state"
  if [ -f "$state_file" ]; then
    if _validate_phase_session "$state_file" 2>/dev/null; then
      phase_at_exit="${_PS_CURRENT_PHASE:-}"
      tag_at_exit="${_PS_TAG:-}"
    fi
  fi

  # Capture git status
  local git_status_raw
  git_status_raw=$(git status --short 2>/dev/null || echo "unavailable")
  local git_status_output="" _gs_line _gs_first=true
  while IFS= read -r _gs_line; do
    _gs_line="${_gs_line//\"/\\\"}"
    if [ "$_gs_first" = true ]; then
      git_status_output="$_gs_line"
      _gs_first=false
    else
      git_status_output="${git_status_output}\\n${_gs_line}"
    fi
  done <<< "$git_status_raw"

  # Dirty tree detection for type classification
  local has_dirty_tree=false
  if [ -n "$(git diff --name-only 2>/dev/null)" ] || [ -n "$(git diff --cached --name-only 2>/dev/null)" ]; then
    has_dirty_tree=true
  fi

  # Classify failure type
  local failure_type
  failure_type=$(_classify_failure_type "$exit_code" "$has_dirty_tree")

  # Capture stderr tail
  local stderr_tail_lines
  stderr_tail_lines=$(_parse_config_field "runner" "stderr_tail_lines" 2>/dev/null || true)
  stderr_tail_lines="${stderr_tail_lines:-50}"
  local stderr_tail=""
  if [ -n "$stderr_file" ]; then
    stderr_tail=$(_capture_stderr_tail "$stderr_file" "$stderr_tail_lines")
  fi

  # Capture analytics block events
  local analytics_events
  analytics_events=$(_capture_analytics_events "$repo_root")

  # Current branch
  local branch
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

  # Write report (atomic: tmp then mv)
  local tmp_file="${report_file}.tmp"
  {
    printf 'report:\n'
    printf '  id: "%s"\n' "$report_id"
    printf '  queue_entry_id: "%s"\n' "$entry_id"
    printf '  timestamp: "%s"\n' "$timestamp"
    printf '  type: "%s"\n' "$failure_type"
    printf '  exit_code: %s\n' "$exit_code"
    printf '  branch: "%s"\n' "$branch"
    printf '  phase_at_exit: "%s"\n' "$phase_at_exit"
    printf '  tag_at_exit: "%s"\n' "$tag_at_exit"
    printf '  stderr_tail: "%s"\n' "$stderr_tail"
    printf '  git_status: "%s"\n' "$git_status_output"
    printf '  analytics_events: %s\n' "$analytics_events"
    printf '  resolution:\n'
    printf '    status: "unresolved"\n'
    printf '    notes: ""\n'
    printf '    resolved_at: ""\n'
  } > "$tmp_file"
  mv "$tmp_file" "$report_file"

  echo "Blocker report written: $report_file" >&2
}
