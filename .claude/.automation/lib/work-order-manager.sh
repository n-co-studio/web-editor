#!/usr/bin/env bash
# Work order manager — work order lifecycle for grouped queue entries.
# Sourced by runner.sh. NOT executed standalone.
# Decision 0017 — Operator Automation Layer.
#
# Work orders group related queue entries (e.g., all briefs in a task group)
# into a single operator-visible unit with aggregate status tracking.
# Status: open → completed | escalated. Reopen: escalated → open.
#
# Depends on (sourced by runner.sh before this file):
#   runner.sh sets AUTOMATION_DIR, REPO_ROOT, CONFIG_FILE
#   queue-manager.sh — _queue_dir, _load_queue_entry, _write_queue_entry,
#                       _QE_* variables, _parse_config_field

set -euo pipefail

# --- Work order directory ---
_WO_DIR=""
_wo_dir() {
  if [ -z "$_WO_DIR" ]; then
    _WO_DIR="$(_queue_dir)/work-orders"
  fi
  printf '%s' "$_WO_DIR"
}

# --- Ensure work order directory exists ---
_ensure_wo_dirs() {
  mkdir -p "$(_wo_dir)" 2>/dev/null || true
}

# --- Module variables (mirrors work-order.yaml fields) ---
_WO_ID="" _WO_TYPE="" _WO_LABEL="" _WO_ENTRY_IDS="" _WO_STATUS=""
_WO_CREATED_AT="" _WO_UPDATED_AT="" _WO_COMPLETED_AT=""

# --- Bulk-read work order YAML into _WO_* variables (zero-fork) ---
# Work order format: `work_order:` header followed by `  key: value` lines.
# entry_ids uses YAML list format (  - id). Stored as comma-separated in _WO_ENTRY_IDS.
# Returns 1 if the file is missing.
_load_work_order() {
  local wo_file="$1"
  _WO_ID="" _WO_TYPE="" _WO_LABEL="" _WO_ENTRY_IDS="" _WO_STATUS=""
  _WO_CREATED_AT="" _WO_UPDATED_AT="" _WO_COMPLETED_AT=""
  [ -f "$wo_file" ] || return 1

  local _line _in_list=false
  while IFS= read -r _line || [ -n "$_line" ]; do
    # Handle entry_ids list items
    if [ "$_in_list" = true ]; then
      case "$_line" in
        "  - "*)
          local _item="${_line#  - }"
          if [ -n "$_WO_ENTRY_IDS" ]; then
            _WO_ENTRY_IDS="${_WO_ENTRY_IDS},${_item}"
          else
            _WO_ENTRY_IDS="$_item"
          fi
          continue
          ;;
        *)
          _in_list=false
          ;;
      esac
    fi

    case "$_line" in
      "  id: "*)           _WO_ID="${_line#  id: }" ;;
      "  type: "*)         _WO_TYPE="${_line#  type: }" ;;
      "  label: "*)        _WO_LABEL="${_line#  label: }" ;;
      "  entry_ids: []")   _WO_ENTRY_IDS="" ;;
      "  entry_ids:")      _in_list=true ;;
      "  status: "*)       _WO_STATUS="${_line#  status: }" ;;
      "  created_at: "*)   _WO_CREATED_AT="${_line#  created_at: }" ;;
      "  updated_at: "*)   _WO_UPDATED_AT="${_line#  updated_at: }" ;;
      "  completed_at: "*) _WO_COMPLETED_AT="${_line#  completed_at: }" ;;
    esac
  done < "$wo_file"
}

# --- Write work order YAML from _WO_* variables (atomic) ---
# Writes to tmp file then mv for atomicity on POSIX/APFS.
# entry_ids rendered as YAML list when non-empty, [] when empty.
_write_work_order() {
  local wo_file="$1"
  local tmp_file="${wo_file}.tmp"

  {
    printf 'work_order:\n'
    printf '  id: %s\n' "$_WO_ID"
    printf '  type: %s\n' "$_WO_TYPE"
    printf '  label: %s\n' "$_WO_LABEL"
    if [ -z "$_WO_ENTRY_IDS" ]; then
      printf '  entry_ids: []\n'
    else
      printf '  entry_ids:\n'
      local _eid
      IFS=',' read -ra _ids <<< "$_WO_ENTRY_IDS"
      for _eid in "${_ids[@]}"; do
        printf '  - %s\n' "$_eid"
      done
    fi
    printf '  status: %s\n' "$_WO_STATUS"
    printf '  created_at: %s\n' "$_WO_CREATED_AT"
    printf '  updated_at: %s\n' "$_WO_UPDATED_AT"
    printf '  completed_at: %s\n' "$_WO_COMPLETED_AT"
  } > "$tmp_file"
  mv "$tmp_file" "$wo_file"
}

# --- Transition work order status ---
# Updates status, updated_at, and completed_at for terminal states.
_transition_work_order() {
  local new_status="$1"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _WO_STATUS="$new_status"
  _WO_UPDATED_AT="$timestamp"
  case "$new_status" in
    completed|escalated) _WO_COMPLETED_AT="$timestamp" ;;
  esac
}

# --- Find a queue entry file across all status directories ---
# Arguments:
#   $1 — entry_id
# Output: file path on stdout (empty if not found)
_find_entry_file() {
  local entry_id="$1"
  local qdir
  qdir=$(_queue_dir)
  local status
  for status in pending-review approved running completed failed review blocked; do
    local f="$qdir/$status/${entry_id}.yaml"
    if [ -f "$f" ]; then
      printf '%s' "$f"
      return
    fi
  done
}

# ============================================================
# Public API
# ============================================================

# --- Create a new work order ---
# Creates a YAML file in queue/work-orders/ with generated UUID.
# Arguments:
#   $1 — type (single | group)
#   $2 — label (operator-provided description)
#   $3.. — entry_ids (optional, space-separated queue entry IDs)
# Output: UUID on stdout
wo_create() {
  local wo_type="$1"
  local wo_label="$2"
  shift 2

  _ensure_wo_dirs

  # Generate UUID
  local wo_id
  if command -v uuidgen > /dev/null 2>&1; then
    wo_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
  else
    wo_id="wo-$(date +%s)-$$-$RANDOM"
  fi

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Build comma-separated entry_ids from remaining args
  local ids=""
  local eid
  for eid in "$@"; do
    if [ -n "$ids" ]; then
      ids="${ids},${eid}"
    else
      ids="$eid"
    fi
  done

  # Populate module variables
  _WO_ID="$wo_id"
  _WO_TYPE="$wo_type"
  _WO_LABEL="$wo_label"
  _WO_ENTRY_IDS="$ids"
  _WO_STATUS="open"
  _WO_CREATED_AT="$timestamp"
  _WO_UPDATED_AT="$timestamp"
  _WO_COMPLETED_AT=""

  _write_work_order "$(_wo_dir)/${wo_id}.yaml"

  printf '%s' "$wo_id"
}

# --- Add a child entry to a work order ---
# Appends entry_id to work order and sets queue entry's work_order_id.
# Arguments:
#   $1 — wo_id (work order identifier)
#   $2 — entry_id (queue entry identifier)
wo_add_child() {
  local wo_id="$1"
  local entry_id="$2"
  local wo_file="$(_wo_dir)/${wo_id}.yaml"

  _load_work_order "$wo_file" || {
    echo "ERROR: Work order $wo_id not found" >&2
    return 1
  }

  # Append entry_id to work order
  if [ -n "$_WO_ENTRY_IDS" ]; then
    _WO_ENTRY_IDS="${_WO_ENTRY_IDS},${entry_id}"
  else
    _WO_ENTRY_IDS="$entry_id"
  fi
  _WO_UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _write_work_order "$wo_file"

  # Update queue entry's work_order_id field
  local entry_file
  entry_file=$(_find_entry_file "$entry_id")
  if [ -n "$entry_file" ]; then
    _load_queue_entry "$entry_file"
    _QE_WORK_ORDER_ID="$wo_id"
    _write_queue_entry "$entry_file"
  fi
}

# --- Check work order completion status ---
# Scans child entry statuses and transitions work order accordingly.
# All completed → completed. Any failed/review/blocked → escalated. Otherwise open.
# Arguments:
#   $1 — wo_id (work order identifier)
# Output: new status on stdout (open | completed | escalated)
wo_check_completion() {
  local wo_id="$1"
  local wo_file="$(_wo_dir)/${wo_id}.yaml"

  _load_work_order "$wo_file" || {
    echo "ERROR: Work order $wo_id not found" >&2
    return 1
  }

  if [ -z "$_WO_ENTRY_IDS" ]; then
    printf '%s' "open"
    return
  fi

  local all_completed=true
  local has_terminal_failure=false
  local _eid

  IFS=',' read -ra _ids <<< "$_WO_ENTRY_IDS"
  for _eid in "${_ids[@]}"; do
    local entry_file
    entry_file=$(_find_entry_file "$_eid")
    if [ -z "$entry_file" ]; then
      # Entry not found — treat as still in progress
      all_completed=false
      continue
    fi
    _load_queue_entry "$entry_file"
    case "$_QE_STATUS" in
      completed) ;;
      failed|review|blocked) has_terminal_failure=true; all_completed=false ;;
      *) all_completed=false ;;
    esac
  done

  # Reload work order — _load_queue_entry calls above clobbered _QE_* vars,
  # but _WO_* vars were NOT clobbered. Reload to ensure fresh state for write.
  _load_work_order "$wo_file"

  if [ "$all_completed" = true ]; then
    _transition_work_order "completed"
    _write_work_order "$wo_file"
    printf '%s' "completed"
  elif [ "$has_terminal_failure" = true ]; then
    _transition_work_order "escalated"
    _write_work_order "$wo_file"
    printf '%s' "escalated"
  else
    printf '%s' "open"
  fi
}

# --- Reopen an escalated work order ---
# Transitions escalated back to open (clears completed_at).
# Arguments:
#   $1 — wo_id (work order identifier)
wo_reopen() {
  local wo_id="$1"
  local wo_file="$(_wo_dir)/${wo_id}.yaml"

  _load_work_order "$wo_file" || {
    echo "ERROR: Work order $wo_id not found" >&2
    return 1
  }

  if [ "$_WO_STATUS" != "escalated" ]; then
    echo "ERROR: Work order $wo_id is not escalated (status: $_WO_STATUS)" >&2
    return 1
  fi

  _WO_STATUS="open"
  _WO_UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _WO_COMPLETED_AT=""
  _write_work_order "$wo_file"
}

# --- List work orders ---
# Lists work orders, optionally filtered by status.
# Arguments:
#   $1 — status filter (optional: open | completed | escalated)
# Output: one line per work order: id|status|type|label
wo_list() {
  local filter="${1:-}"
  local wo_dir
  wo_dir=$(_wo_dir)

  [ -d "$wo_dir" ] || return 0

  local f
  for f in "$wo_dir"/*.yaml; do
    [ -f "$f" ] || continue
    _load_work_order "$f"
    if [ -n "$filter" ] && [ "$_WO_STATUS" != "$filter" ]; then
      continue
    fi
    printf '%s|%s|%s|%s\n' "$_WO_ID" "$_WO_STATUS" "$_WO_TYPE" "$_WO_LABEL"
  done
}
