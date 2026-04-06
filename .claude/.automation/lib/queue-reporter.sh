#!/usr/bin/env bash
# Queue reporter — read-only queue inspection functions.
# Sourced by queue-cli.sh. NOT executed standalone.
# Decision 0017 — Operator Automation Layer.
#
# Provides operator-facing read functions for queue status, entry listing,
# detail views, and actionable review items. All functions are read-only
# and do not require the queue lock.
#
# Depends on (sourced before this file):
#   queue-manager.sh — _queue_dir, _load_queue_entry, _QE_* variables
#   work-order-manager.sh — _find_entry_file
#   review-log.sh — review_log_tail

set -euo pipefail

# ============================================================
# Public API
# ============================================================

# --- Queue status summary ---
# Reads queue-index.json and outputs status counts.
# Output (text mode): one line per status with count.
# Output (pipe mode): pipe-delimited counts for machine consumption.
# Arguments:
#   $1 — output format: "text" (default) or "pipe"
queue_status() {
  local fmt="${1:-text}"
  local qdir
  qdir=$(_queue_dir)
  local index_file="$qdir/queue-index.json"

  # If no index file, scan directories directly
  if [ ! -f "$index_file" ]; then
    local statuses="pending-review approved running completed failed review blocked"
    local status
    # shellcheck disable=SC2086 — intentional word splitting
    for status in $statuses; do
      local count=0
      local dir="$qdir/$status"
      if [ -d "$dir" ]; then
        local f
        for f in "$dir"/*.yaml; do
          [ -f "$f" ] || continue
          count=$((count + 1))
        done
      fi
      if [ "$fmt" = "pipe" ]; then
        printf '%s|%d\n' "$status" "$count"
      else
        printf '%-16s %d\n' "$status" "$count"
      fi
    done
    return
  fi

  # Parse counts from index JSON (zero-fork line scanner)
  # Format: {"last_updated":"...","counts":{"pending_review":N,...},...}
  local content
  content=$(cat "$index_file")

  # Extract counts block
  local counts_block=""
  case "$content" in
    *'"counts":{'*)
      counts_block="${content#*\"counts\":\{}"
      counts_block="${counts_block%%\}*}"
      ;;
  esac

  if [ -z "$counts_block" ]; then
    echo "No queue data available" >&2
    return 1
  fi

  # Extract last_updated
  local last_updated=""
  case "$content" in
    *'"last_updated":"'*)
      last_updated="${content#*\"last_updated\":\"}"
      last_updated="${last_updated%%\"*}"
      ;;
  esac

  if [ "$fmt" = "text" ] && [ -n "$last_updated" ]; then
    printf 'Last updated: %s\n\n' "$last_updated"
  fi

  # Parse individual counts: "key":N pairs
  local remaining="$counts_block"
  while [ -n "$remaining" ]; do
    # Extract key
    case "$remaining" in
      *'"'*)
        local key="${remaining#*\"}"
        key="${key%%\"*}"
        # Extract value after the key
        local after_key="${remaining#*\"${key}\":}"
        local val="${after_key%%,*}"
        # Normalize key (replace _ with -)
        local display_key="${key//_/-}"

        if [ "$fmt" = "pipe" ]; then
          printf '%s|%s\n' "$display_key" "$val"
        else
          printf '%-16s %s\n' "$display_key" "$val"
        fi

        # Advance past this pair
        case "$after_key" in
          *','*'"'*) remaining="${after_key#*,}" ;;
          *) remaining="" ;;
        esac
        ;;
      *) remaining="" ;;
    esac
  done
}

# --- List queue entries ---
# Scans directory state directly for reliability. Optional status filter.
# Output: one line per entry: id|status|session_type|brief_path|<sort-field>
# The 5th column reflects the sort field for each status:
#   approved/pending-review/running → priority ASC, then created_at ASC (matches dequeue order)
#   completed                       → completed_at (DESC — newest first)
#   failed/blocked/review           → updated_at (DESC — most recently changed first)
# Arguments:
#   $1 — status filter (optional)
queue_list() {
  local filter="${1:-}"
  local qdir
  qdir=$(_queue_dir)

  # Scan directory state directly for reliability
  local statuses="pending-review approved running completed failed review blocked"
  local status
  # shellcheck disable=SC2086 — intentional word splitting
  for status in $statuses; do
    if [ -n "$filter" ] && [ "$status" != "$filter" ]; then
      continue
    fi
    local dir="$qdir/$status"
    [ -d "$dir" ] || continue

    # Determine sort field and order per status.
    # approved/pending-review/running: created_at ASC — matches queue_dequeue execution
    # order (sort contract parity: _sort_entries_by_ts "asc" in both paths).
    # completed: completed_at DESC — newest completed at top.
    # failed/blocked/review: updated_at DESC — most recently changed at top.
    local sort_order ts_field
    case "$status" in
      approved|pending-review|running)
        sort_order="asc"
        ts_field="created_at"
        ;;
      completed)
        sort_order="desc"
        ts_field="completed_at"
        ;;
      *)
        sort_order="desc"
        ts_field="updated_at"
        ;;
    esac

    # Collect entries into _se_ts_N/_se_fp_N parallel arrays.
    # For active statuses (asc order), use composite key (priority + timestamp)
    # to match dequeue sort contract (priority ASC, then timestamp ASC).
    local _se_count=0
    local f
    for f in "$dir"/*.yaml; do
      [ -f "$f" ] || continue
      _load_queue_entry "$f"
      local sort_ts
      case "$ts_field" in
        created_at)   sort_ts="$_QE_CREATED_AT" ;;
        completed_at) sort_ts="$_QE_COMPLETED_AT" ;;
        *)            sort_ts="$_QE_UPDATED_AT" ;;
      esac
      # Active statuses use composite key for priority-aware sort
      if [ "$sort_order" = "asc" ]; then
        local _pri="${_QE_PRIORITY:-0}"
        eval "_se_ts_${_se_count}=\"\$(printf '%05d_%s' \"\$_pri\" \"\$sort_ts\")\""
      else
        eval "_se_ts_${_se_count}=\"\$sort_ts\""
      fi
      eval "_se_fp_${_se_count}=\"\$f\""
      _se_count=$(( _se_count + 1 ))
    done

    # Sort using shared helper (same algorithm as queue_dequeue for asc order).
    _sort_entries_by_ts "$_se_count" "$sort_order"

    # Output sorted entries with sort-field timestamp in 5th column.
    # Prefix brief_path with [PN] for non-zero priority entries.
    local k=0
    while [ "$k" -lt "$_se_count" ]; do
      eval "f=\"\$_se_fp_${k}\""
      _load_queue_entry "$f"
      local display_ts
      case "$ts_field" in
        created_at)   display_ts="$_QE_CREATED_AT" ;;
        completed_at) display_ts="$_QE_COMPLETED_AT" ;;
        *)            display_ts="$_QE_UPDATED_AT" ;;
      esac
      local display_brief="$_QE_BRIEF_PATH"
      if [ "${_QE_PRIORITY:-0}" != "0" ]; then
        display_brief="[P${_QE_PRIORITY}] ${display_brief}"
      fi
      printf '%s|%s|%s|%s|%s\n' \
        "$_QE_ID" "$_QE_STATUS" "$_QE_SESSION_TYPE" "$display_brief" "$display_ts"
      k=$(( k + 1 ))
    done

    _se_cleanup "$_se_count"
  done
}

# --- Show full entry detail ---
# Loads a single entry and outputs all fields as key: value lines.
# Arguments:
#   $1 — entry_id
# Returns: 1 if entry not found
queue_show() {
  local entry_id="$1"

  local entry_file
  entry_file=$(_find_entry_file "$entry_id")
  if [ -z "$entry_file" ]; then
    echo "ERROR: Entry $entry_id not found" >&2
    return 1
  fi

  _load_queue_entry "$entry_file"

  printf 'id: %s\n' "$_QE_ID"
  printf 'status: %s\n' "$_QE_STATUS"
  printf 'priority: %s\n' "${_QE_PRIORITY:-0}"
  printf 'session_type: %s\n' "$_QE_SESSION_TYPE"
  printf 'branch: %s\n' "$_QE_BRANCH"
  printf 'brief_path: %s\n' "$_QE_BRIEF_PATH"
  printf 'auto_mode: %s\n' "$_QE_AUTO_MODE"
  printf 'solo_mode: %s\n' "$_QE_SOLO_MODE"
  printf 'push_on_complete: %s\n' "$_QE_PUSH_ON_COMPLETE"
  printf 'retry_count: %s\n' "$_QE_RETRY_COUNT"
  printf 'max_retries: %s\n' "$_QE_MAX_RETRIES"
  printf 'error_log: %s\n' "$_QE_ERROR_LOG"
  printf 'work_order_id: %s\n' "$_QE_WORK_ORDER_ID"
  printf 'created_at: %s\n' "$_QE_CREATED_AT"
  printf 'updated_at: %s\n' "$_QE_UPDATED_AT"
  printf 'completed_at: %s\n' "$_QE_COMPLETED_AT"
}

# --- Review items (operator attention needed) ---
# Scans review/ and blocked/ directories for entries requiring operator action.
# Output: one line per entry: id|status|session_type|error_log|work_order_id
review_items() {
  local qdir
  qdir=$(_queue_dir)

  local status
  for status in review blocked failed; do
    local dir="$qdir/$status"
    [ -d "$dir" ] || continue
    local f
    for f in "$dir"/*.yaml; do
      [ -f "$f" ] || continue
      _load_queue_entry "$f"
      printf '%s|%s|%s|%s|%s\n' \
        "$_QE_ID" "$_QE_STATUS" "$_QE_SESSION_TYPE" "$_QE_ERROR_LOG" "$_QE_WORK_ORDER_ID"
    done
  done

  # Surface failed work orders (entries may already appear above, but
  # the work order itself carries the failure_entry_id for diagnostics)
  local wo_dir="$qdir/work-orders"
  if [ -d "$wo_dir" ]; then
    local wf
    for wf in "$wo_dir"/*.yaml; do
      [ -f "$wf" ] || continue
      _load_work_order "$wf"
      if [ "$_WO_STATUS" = "failed" ]; then
        printf 'wo:%s|%s|work-order|failure_entry: %s|%s\n' \
          "$_WO_ID" "$_WO_STATUS" "$_WO_FAILURE_ENTRY_ID" "$_WO_LABEL"
      fi
    done
  fi
}
