#!/usr/bin/env bash
# Work order manager — work order lifecycle for grouped queue entries.
# Sourced by runner.sh. NOT executed standalone.
# Decision 0017 — Operator Automation Layer.
#
# Work orders group related queue entries (e.g., all briefs in a task group)
# into a single operator-visible unit with aggregate status tracking.
# Status: open → completed | escalated | failed. Reopen: escalated|failed → open.
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
_WO_CREATED_AT="" _WO_UPDATED_AT="" _WO_COMPLETED_AT="" _WO_FAILURE_ENTRY_ID=""
# (v1.4.0) project / milestone — optional
_WO_PROJECT="" _WO_MILESTONE_NAME="" _WO_MILESTONE_INDEX="" _WO_MILESTONE_TOTAL=""

# --- Bulk-read work order YAML into _WO_* variables (zero-fork) ---
# Work order format: `work_order:` header followed by `  key: value` lines.
# entry_ids uses YAML list format (  - id). Stored as comma-separated in _WO_ENTRY_IDS.
# Returns 1 if the file is missing.
_load_work_order() {
  local wo_file="$1"
  _WO_ID="" _WO_TYPE="" _WO_LABEL="" _WO_ENTRY_IDS="" _WO_STATUS=""
  _WO_CREATED_AT="" _WO_UPDATED_AT="" _WO_COMPLETED_AT="" _WO_FAILURE_ENTRY_ID=""
  _WO_PROJECT="" _WO_MILESTONE_NAME="" _WO_MILESTONE_INDEX="" _WO_MILESTONE_TOTAL=""
  [ -f "$wo_file" ] || return 1

  local _line _in_list=false _in_milestone=false
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

    # Handle milestone nested block (v1.4.0)
    if [ "$_in_milestone" = true ]; then
      case "$_line" in
        "    name: "*)  _WO_MILESTONE_NAME="${_line#    name: }"; continue ;;
        "    index: "*) _WO_MILESTONE_INDEX="${_line#    index: }"; continue ;;
        "    total: "*) _WO_MILESTONE_TOTAL="${_line#    total: }"; continue ;;
        "    "*)        continue ;;  # other 4-space sub-fields → stay in block
        *)              _in_milestone=false ;;  # 2-space sibling field → exit block, fall through
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
      "  failure_entry_id: "*) _WO_FAILURE_ENTRY_ID="${_line#  failure_entry_id: }" ;;
      "  project: "*)      _WO_PROJECT="${_line#  project: }" ;;
      "  milestone:")      _in_milestone=true ;;
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
      # Bash 3.2 compatible (audit 5.1: read -ra not available)
      local _eid _old_ifs="$IFS"
      IFS=','
      set -- $_WO_ENTRY_IDS
      IFS="$_old_ifs"
      for _eid in "$@"; do
        printf '  - %s\n' "$_eid"
      done
    fi
    printf '  status: %s\n' "$_WO_STATUS"
    printf '  created_at: %s\n' "$_WO_CREATED_AT"
    printf '  updated_at: %s\n' "$_WO_UPDATED_AT"
    printf '  completed_at: %s\n' "$_WO_COMPLETED_AT"
    printf '  failure_entry_id: %s\n' "$_WO_FAILURE_ENTRY_ID"
    printf '  project: %s\n' "${_WO_PROJECT:-}"
    printf '  milestone:\n'
    printf '    name: %s\n' "${_WO_MILESTONE_NAME:-}"
    printf '    index: %s\n' "${_WO_MILESTONE_INDEX:-0}"
    printf '    total: %s\n' "${_WO_MILESTONE_TOTAL:-0}"
  } > "$tmp_file"
  mv "$tmp_file" "$wo_file"
}

# --- Transition work order status ---
# Updates status, updated_at, and completed_at for terminal states.
# Validates legal transitions (adversarial H5/H6/M4): rejects illegal
# state changes to prevent forgery of work order completion.
_transition_work_order() {
  local new_status="$1"

  # Legal transition validation
  local _current="$_WO_STATUS"
  local _legal=false
  case "$_current" in
    open)
      case "$new_status" in
        in_progress|completed|escalated|failed) _legal=true ;;
      esac
      ;;
    in_progress)
      case "$new_status" in
        completed|escalated|failed|open) _legal=true ;;
      esac
      ;;
    escalated)
      case "$new_status" in
        in_progress|open|completed) _legal=true ;; # retry after escalation review; completed when all children terminal
      esac
      ;;
    failed)
      case "$new_status" in
        in_progress|open|completed) _legal=true ;; # retry after failure review; completed when all children terminal
      esac
      ;;
    completed)
      ;; # terminal — no further transitions allowed
  esac
  if [ "$_legal" = false ]; then
    echo "ERROR: Illegal work order transition '$_current' → '$new_status'" >&2
    return 1
  fi

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _WO_STATUS="$new_status"
  _WO_UPDATED_AT="$timestamp"
  case "$new_status" in
    completed|escalated|failed) _WO_COMPLETED_AT="$timestamp" ;;
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
  _WO_FAILURE_ENTRY_ID=""
  # (v1.4.0) project/milestone — callers may pre-set these before calling wo_create;
  # initialize to empty here so stale values from prior _load_work_order don't leak.
  _WO_PROJECT="${_WO_PROJECT:-}"
  _WO_MILESTONE_NAME="${_WO_MILESTONE_NAME:-}"
  _WO_MILESTONE_INDEX="${_WO_MILESTONE_INDEX:-0}"
  _WO_MILESTONE_TOTAL="${_WO_MILESTONE_TOTAL:-0}"

  _write_work_order "$(_wo_dir)/${wo_id}.yaml"

  printf '%s' "$wo_id"
}

# --- Edit a work order field ---
# Arguments:
#   $1 — wo_id (work order identifier)
#   $2 — field (project | milestone.name | milestone.index | milestone.total)
#   $3 — value
# Returns: 0 on success, 1 on error
wo_edit() {
  local wo_id="$1"
  local field="$2"
  local value="$3"
  local wo_file="$(_wo_dir)/${wo_id}.yaml"

  _load_work_order "$wo_file" || {
    echo "ERROR: Work order $wo_id not found" >&2
    return 1
  }

  case "$field" in
    project)           _WO_PROJECT="$value" ;;
    milestone.name)    _WO_MILESTONE_NAME="$value" ;;
    milestone.index)
      case "$value" in
        ''|*[!0-9]*) echo "ERROR: milestone.index must be a non-negative integer" >&2; return 1 ;;
      esac
      _WO_MILESTONE_INDEX="$value" ;;
    milestone.total)
      case "$value" in
        ''|*[!0-9]*) echo "ERROR: milestone.total must be a non-negative integer" >&2; return 1 ;;
      esac
      _WO_MILESTONE_TOTAL="$value" ;;
    *)
      echo "ERROR: Field '$field' is not editable on work orders (allowed: project, milestone.name, milestone.index, milestone.total)" >&2
      return 1
      ;;
  esac

  _WO_UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _write_work_order "$wo_file"
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

# --- Remove a child entry from a work order ---
# Removes entry_id from the work order's entry list.
# If the entry list becomes empty, removes the work order file entirely.
# Arguments:
#   $1 — wo_id (work order identifier)
#   $2 — entry_id (queue entry identifier to remove)
# Returns: 0 on success, 1 if work order not found
wo_remove_child() {
  local wo_id="$1"
  local entry_id="$2"
  local wo_file="$(_wo_dir)/${wo_id}.yaml"

  _load_work_order "$wo_file" || {
    echo "ERROR: Work order $wo_id not found" >&2
    return 1
  }

  # Rebuild entry list without the target entry_id
  if [ -z "$_WO_ENTRY_IDS" ]; then
    return 0
  fi
  local new_ids=""
  local old_ifs="$IFS"
  IFS=','
  set -- $_WO_ENTRY_IDS
  IFS="$old_ifs"
  local _eid
  for _eid in "$@"; do
    if [ "$_eid" != "$entry_id" ]; then
      if [ -n "$new_ids" ]; then
        new_ids="${new_ids},${_eid}"
      else
        new_ids="$_eid"
      fi
    fi
  done

  _WO_ENTRY_IDS="$new_ids"

  if [ -z "$_WO_ENTRY_IDS" ]; then
    # No remaining children — remove work order file
    rm -f "$wo_file"
  else
    _WO_UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    _write_work_order "$wo_file"
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
  local has_failed_entry=false
  local has_escalation=false
  local first_failed_eid=""
  local _eid

  # Bash 3.2 compatible (audit 5.1: read -ra not available)
  local _old_ifs="$IFS"
  IFS=','
  set -- $_WO_ENTRY_IDS
  IFS="$_old_ifs"
  for _eid in "$@"; do
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
      failed)
        has_failed_entry=true
        all_completed=false
        if [ -z "$first_failed_eid" ]; then
          first_failed_eid="$_eid"
        fi
        ;;
      review|blocked) has_escalation=true; all_completed=false ;;
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
  elif [ "$has_failed_entry" = true ]; then
    # Failed entry takes priority — block siblings from running
    _transition_work_order "failed"
    _WO_FAILURE_ENTRY_ID="$first_failed_eid"
    _write_work_order "$wo_file"
    printf '%s' "failed"
  elif [ "$has_escalation" = true ]; then
    _transition_work_order "escalated"
    _write_work_order "$wo_file"
    printf '%s' "escalated"
  else
    printf '%s' "open"
  fi
}

# --- Reopen an escalated or failed work order ---
# Transitions escalated/failed back to open (clears completed_at, failure_entry_id).
# Arguments:
#   $1 — wo_id (work order identifier)
wo_reopen() {
  local wo_id="$1"
  local wo_file="$(_wo_dir)/${wo_id}.yaml"

  _load_work_order "$wo_file" || {
    echo "ERROR: Work order $wo_id not found" >&2
    return 1
  }

  if [ "$_WO_STATUS" != "escalated" ] && [ "$_WO_STATUS" != "failed" ]; then
    echo "ERROR: Work order $wo_id is not escalated or failed (status: $_WO_STATUS)" >&2
    return 1
  fi

  _WO_STATUS="open"
  _WO_UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _WO_COMPLETED_AT=""
  _WO_FAILURE_ENTRY_ID=""
  _write_work_order "$wo_file"
}

# --- Check if a work order is escalated ---
# Lightweight read-only check. Returns 0 if the work order status is "escalated"
# (a sibling entry is in review/blocked), 1 otherwise.
# Only touches _WO_* variables (no _QE_* collision).
# Arguments:
#   $1 — wo_id (work order identifier)
# Returns: 0 if escalated, 1 otherwise
wo_is_escalated() {
  local wo_id="$1"
  local wo_file="$(_wo_dir)/${wo_id}.yaml"

  _load_work_order "$wo_file" || return 1

  if [ "$_WO_STATUS" = "escalated" ]; then
    return 0
  fi
  return 1
}

# --- Check if a work order has a failed entry ---
# Lightweight read-only check. Returns 0 if the work order status is "failed"
# (a sibling entry failed), 1 otherwise.
# Only touches _WO_* variables (no _QE_* collision).
# Arguments:
#   $1 — wo_id (work order identifier)
# Returns: 0 if failed, 1 otherwise
wo_is_failed() {
  local wo_id="$1"
  local wo_file="$(_wo_dir)/${wo_id}.yaml"

  _load_work_order "$wo_file" || return 1

  if [ "$_WO_STATUS" = "failed" ]; then
    return 0
  fi
  return 1
}

# --- Reconcile a work order against its children's actual states ---
# Idempotent safety net: loads a WO, skips if already terminal (completed),
# and calls wo_check_completion for non-terminal WOs.
#
# Zero-children edge case: wo_check_completion returns "open" for empty entry
# lists (event-driven path is conservative). wo_reconcile instead transitions
# to "completed" — a WO with no entries has nothing to wait for. Note that
# wo_remove_child deletes the WO file when the last entry is removed, so the
# zero-children WO path is reached only via corruption or force-removal.
#
# Lock contract: does NOT call acquire_queue_lock — caller must hold the lock
# before calling this function. All write operations inside wo_check_completion
# and _write_work_order assume the caller holds the lock.
#
# Arguments:
#   $1 — wo_id (work order identifier)
# Output: new status on stdout (or empty if no change needed)
# Returns: 0 on success/no-op, 1 on error
wo_reconcile() {
  local wo_id="$1"
  local wo_file="$(_wo_dir)/${wo_id}.yaml"

  _load_work_order "$wo_file" || {
    echo "ERROR: wo_reconcile: work order $wo_id not found" >&2
    return 1
  }

  # Already terminal — nothing to do
  if [ "$_WO_STATUS" = "completed" ]; then
    return 0
  fi

  # Non-terminal: check if status matches children reality
  case "$_WO_STATUS" in
    open|in_progress|escalated|failed) ;;
    *)
      echo "WARNING: wo_reconcile: work order $wo_id has unknown status '$_WO_STATUS'" >&2
      return 1
      ;;
  esac

  # Zero-children edge case: if entry list is empty, complete the WO
  if [ -z "$_WO_ENTRY_IDS" ]; then
    echo "WARNING: wo_reconcile: work order $wo_id ($_WO_STATUS) has no children — transitioning to completed" >&2
    _transition_work_order "completed" || {
      echo "ERROR: wo_reconcile: failed to transition $wo_id to completed" >&2
      return 1
    }
    _write_work_order "$wo_file"
    printf '%s' "completed"
    return 0
  fi

  # Check whether all children are in terminal states before calling wo_check_completion
  local _all_terminal=true
  local _old_ifs="$IFS"
  IFS=','
  set -- $_WO_ENTRY_IDS
  IFS="$_old_ifs"
  local _eid
  for _eid in "$@"; do
    local _ef
    _ef=$(_find_entry_file "$_eid")
    if [ -z "$_ef" ]; then
      # Entry not found — treat as still in progress (matches wo_check_completion logic)
      _all_terminal=false
      break
    fi
    _load_queue_entry "$_ef" 2>/dev/null || { _all_terminal=false; break; }
    case "$_QE_STATUS" in
      completed|failed) ;;
      *) _all_terminal=false; break ;;
    esac
  done

  if [ "$_all_terminal" = true ]; then
    echo "WARNING: wo_reconcile: invariant violation — work order $wo_id is $_WO_STATUS but all children are terminal; reconciling" >&2
  fi

  # Delegate to wo_check_completion for the actual status derivation and write
  local new_status
  new_status=$(wo_check_completion "$wo_id") || {
    echo "ERROR: wo_reconcile: wo_check_completion failed for $wo_id" >&2
    return 1
  }
  if [ -n "$new_status" ]; then
    printf '%s' "$new_status"
  fi
  return 0
}

# --- List work orders ---
# Lists work orders, optionally filtered by status.
# Arguments:
#   $1 — status filter (optional: open | completed | escalated | failed)
# Output: one line per work order: id|status|type|label|failure_entry_id
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
    printf '%s|%s|%s|%s|%s\n' "$_WO_ID" "$_WO_STATUS" "$_WO_TYPE" "$_WO_LABEL" "$_WO_FAILURE_ENTRY_ID"
  done
}
