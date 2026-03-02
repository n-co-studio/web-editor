#!/usr/bin/env bash
# Queue manager — queue state machine for headless runner sessions.
# Sourced by runner.sh. NOT executed standalone.
# Decision 0017 — Operator Automation Layer.
#
# State machine: pending-review → approved → running → completed/failed/review/blocked
# All transitions use atomic write-to-tmp-then-mv pattern.
# queue-index.json is rebuilt from directory state on every transition.
#
# Depends on (sourced by runner.sh before this file):
#   runner.sh sets AUTOMATION_DIR, REPO_ROOT, CONFIG_FILE

set -euo pipefail

# --- Queue directory ---
_QUEUE_DIR=""
_queue_dir() {
  if [ -z "$_QUEUE_DIR" ]; then
    _QUEUE_DIR="$AUTOMATION_DIR/queue"
  fi
  printf '%s' "$_QUEUE_DIR"
}

# --- Ensure queue subdirectories exist ---
_ensure_queue_dirs() {
  local qdir
  qdir=$(_queue_dir)
  local status
  for status in pending-review approved running completed failed review blocked; do
    mkdir -p "$qdir/$status" 2>/dev/null || true
  done
}

# --- Module variables (mirrors queue-entry.yaml fields) ---
_QE_ID="" _QE_STATUS="" _QE_SESSION_TYPE="" _QE_BRANCH="" _QE_BRIEF_PATH=""
_QE_PROMPT="" _QE_AUTO_MODE="" _QE_SOLO_MODE="" _QE_RETRY_COUNT=""
_QE_MAX_RETRIES="" _QE_ERROR_LOG="" _QE_WORK_ORDER_ID="" _QE_CREATED_AT=""
_QE_UPDATED_AT="" _QE_COMPLETED_AT=""

# --- Bulk-read queue entry YAML into _QE_* variables (zero-fork) ---
# Queue entry format: `entry:` header followed by `  key: value` lines.
# Prompt field uses block scalar (`prompt: |`) — multi-line content follows indented.
# Returns 1 if the file is missing.
_load_queue_entry() {
  local entry_file="$1"
  _QE_ID="" _QE_STATUS="" _QE_SESSION_TYPE="" _QE_BRANCH="" _QE_BRIEF_PATH=""
  _QE_PROMPT="" _QE_AUTO_MODE="" _QE_SOLO_MODE="" _QE_RETRY_COUNT=""
  _QE_MAX_RETRIES="" _QE_ERROR_LOG="" _QE_WORK_ORDER_ID="" _QE_CREATED_AT=""
  _QE_UPDATED_AT="" _QE_COMPLETED_AT=""
  [ -f "$entry_file" ] || return 1

  local _line _in_prompt=false
  while IFS= read -r _line || [ -n "$_line" ]; do
    # Handle multi-line prompt block scalar
    if [ "$_in_prompt" = true ]; then
      # Block scalar content is indented by 4+ spaces (under `  prompt: |`)
      case "$_line" in
        "    "*)
          if [ -n "$_QE_PROMPT" ]; then
            _QE_PROMPT="${_QE_PROMPT}
${_line#    }"
          else
            _QE_PROMPT="${_line#    }"
          fi
          continue
          ;;
        *)
          _in_prompt=false
          ;;
      esac
    fi

    case "$_line" in
      "  id: "*)           _QE_ID="${_line#  id: }" ;;
      "  status: "*)       _QE_STATUS="${_line#  status: }" ;;
      "  session_type: "*) _QE_SESSION_TYPE="${_line#  session_type: }" ;;
      "  branch: "*)       _QE_BRANCH="${_line#  branch: }" ;;
      "  brief_path: "*)   _QE_BRIEF_PATH="${_line#  brief_path: }" ;;
      "  prompt: |")       _in_prompt=true ;;
      "  prompt: "*)       _QE_PROMPT="${_line#  prompt: }" ;;
      "  auto_mode: "*)    _QE_AUTO_MODE="${_line#  auto_mode: }" ;;
      "  solo_mode: "*)    _QE_SOLO_MODE="${_line#  solo_mode: }" ;;
      "  retry_count: "*)  _QE_RETRY_COUNT="${_line#  retry_count: }" ;;
      "  max_retries: "*)  _QE_MAX_RETRIES="${_line#  max_retries: }" ;;
      "  error_log: "*)    _QE_ERROR_LOG="${_line#  error_log: }" ;;
      "  work_order_id: "*) _QE_WORK_ORDER_ID="${_line#  work_order_id: }" ;;
      "  created_at: "*)   _QE_CREATED_AT="${_line#  created_at: }" ;;
      "  updated_at: "*)   _QE_UPDATED_AT="${_line#  updated_at: }" ;;
      "  completed_at: "*) _QE_COMPLETED_AT="${_line#  completed_at: }" ;;
    esac
  done < "$entry_file"
}

# --- Write queue entry YAML from _QE_* variables (atomic) ---
# Writes to tmp file then mv for atomicity on POSIX/APFS.
# Prompt field uses block scalar for multi-line safety.
_write_queue_entry() {
  local entry_file="$1"
  local tmp_file="${entry_file}.tmp"

  {
    printf 'entry:\n'
    printf '  id: %s\n' "$_QE_ID"
    printf '  status: %s\n' "$_QE_STATUS"
    printf '  session_type: %s\n' "$_QE_SESSION_TYPE"
    printf '  branch: %s\n' "$_QE_BRANCH"
    printf '  brief_path: %s\n' "$_QE_BRIEF_PATH"
    # Prompt: use block scalar if multi-line, plain if empty/single-line
    if [ -z "$_QE_PROMPT" ]; then
      printf '  prompt: ""\n'
    elif [[ "$_QE_PROMPT" == *$'\n'* ]]; then
      printf '  prompt: |\n'
      # Indent each line by 4 spaces for YAML block scalar
      local _pline
      while IFS= read -r _pline || [ -n "$_pline" ]; do
        printf '    %s\n' "$_pline"
      done <<< "$_QE_PROMPT"
    else
      printf '  prompt: %s\n' "$_QE_PROMPT"
    fi
    printf '  auto_mode: %s\n' "$_QE_AUTO_MODE"
    printf '  solo_mode: %s\n' "$_QE_SOLO_MODE"
    printf '  retry_count: %s\n' "$_QE_RETRY_COUNT"
    printf '  max_retries: %s\n' "$_QE_MAX_RETRIES"
    printf '  error_log: %s\n' "$_QE_ERROR_LOG"
    printf '  work_order_id: %s\n' "$_QE_WORK_ORDER_ID"
    printf '  created_at: %s\n' "$_QE_CREATED_AT"
    printf '  updated_at: %s\n' "$_QE_UPDATED_AT"
    printf '  completed_at: %s\n' "$_QE_COMPLETED_AT"
  } > "$tmp_file"
  mv "$tmp_file" "$entry_file"
}

# --- Rebuild queue-index.json from directory state (atomic) ---
# Pure denormalized view — always scan-and-rebuild, never read-modify-write.
_rebuild_queue_index() {
  local qdir
  qdir=$(_queue_dir)
  local index_file="$qdir/queue-index.json"
  local tmp_file="${index_file}.tmp"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local statuses="pending-review approved running completed failed review blocked"
  local counts_json=""
  local entries_json=""
  local first_count=true
  local first_entry=true

  local status
  # shellcheck disable=SC2086 — intentional word splitting on space-delimited list
  for status in $statuses; do
    local count=0
    local dir="$qdir/$status"
    if [ -d "$dir" ]; then
      local f
      for f in "$dir"/*.yaml; do
        [ -f "$f" ] || continue
        count=$((count + 1))

        _load_queue_entry "$f"

        if [ "$first_entry" = true ]; then
          first_entry=false
        else
          entries_json="${entries_json},"
        fi
        # Escape any double quotes in field values for JSON safety
        local _json_bp="${_QE_BRIEF_PATH//\"/\\\"}"
        entries_json="${entries_json}\"${_QE_ID}\":{\"status\":\"${_QE_STATUS}\",\"session_type\":\"${_QE_SESSION_TYPE}\",\"brief_path\":\"${_json_bp}\",\"updated_at\":\"${_QE_UPDATED_AT}\"}"
      done
    fi

    if [ "$first_count" = true ]; then
      first_count=false
    else
      counts_json="${counts_json},"
    fi
    # Normalize status key for JSON (replace - with _)
    local json_key="${status//-/_}"
    counts_json="${counts_json}\"${json_key}\":${count}"
  done

  # --- Work orders section (additive) ---
  # Guarded: work-order-manager.sh may not be sourced (e.g., automation bridge)
  local wo_json=""
  if type _load_work_order > /dev/null 2>&1; then
    local wo_dir="$qdir/work-orders"
    local first_wo=true
    if [ -d "$wo_dir" ]; then
      local wf
      for wf in "$wo_dir"/*.yaml; do
        [ -f "$wf" ] || continue
        _load_work_order "$wf" 2>/dev/null || continue

        # Capture work order fields before child scan
        local _wo_snap_id="$_WO_ID"
        local _wo_snap_type="$_WO_TYPE"
        local _wo_snap_label="$_WO_LABEL"
        local _wo_snap_status="$_WO_STATUS"
        local _wo_snap_created="$_WO_CREATED_AT"
        local _wo_snap_ids="$_WO_ENTRY_IDS"

        # Count children and completed children
        local child_count=0 completed_count=0
        if [ -n "$_wo_snap_ids" ]; then
          local _wid
          IFS=',' read -ra _wids <<< "$_wo_snap_ids"
          for _wid in "${_wids[@]}"; do
            child_count=$((child_count + 1))
            local _wef
            _wef=$(_find_entry_file "$_wid")
            if [ -n "$_wef" ]; then
              _load_queue_entry "$_wef"
              if [ "$_QE_STATUS" = "completed" ]; then
                completed_count=$((completed_count + 1))
              fi
            fi
          done
        fi

        if [ "$first_wo" = true ]; then
          first_wo=false
        else
          wo_json="${wo_json},"
        fi
        local _json_label="${_wo_snap_label//\"/\\\"}"
        wo_json="${wo_json}\"${_wo_snap_id}\":{\"type\":\"${_wo_snap_type}\",\"label\":\"${_json_label}\",\"status\":\"${_wo_snap_status}\",\"child_count\":${child_count},\"completed_count\":${completed_count},\"created_at\":\"${_wo_snap_created}\"}"
      done
    fi
  fi

  printf '{"last_updated":"%s","counts":{%s},"entries":{%s},"work_orders":{%s}}\n' \
    "$timestamp" "$counts_json" "$entries_json" "$wo_json" \
    > "$tmp_file"
  mv "$tmp_file" "$index_file"
}

# --- Generic state transition ---
# Moves entry from one status directory to another atomically.
# Arguments:
#   $1 — entry_id (UUID, used as filename without .yaml)
#   $2 — from_status (current directory name)
#   $3 — to_status (target directory name)
_transition() {
  local entry_id="$1"
  local from_status="$2"
  local to_status="$3"
  local qdir
  qdir=$(_queue_dir)
  local src_file="$qdir/$from_status/${entry_id}.yaml"

  if [ ! -f "$src_file" ]; then
    echo "ERROR: Entry $entry_id not found in $from_status/" >&2
    return 1
  fi

  _load_queue_entry "$src_file"
  _QE_STATUS="$to_status"
  _QE_UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local dst_file="$qdir/$to_status/${entry_id}.yaml"
  _write_queue_entry "$dst_file"
  rm -f "$src_file"
  _rebuild_queue_index
}

# --- Parse a config field from config.yaml ---
# Arguments:
#   $1 — block name (e.g., "runner")
#   $2 — field name (e.g., "enabled")
# Output: field value on stdout
_parse_config_field() {
  local block="$1"
  local field="$2"
  sed -n "/^${block}:/,/^[a-z]/{ /${field}:/p; }" "$CONFIG_FILE" \
    | sed "s/.*${field}: *//" | tr -d '[:space:]' | head -1
}

# ============================================================
# Public API
# ============================================================

# --- Find existing work order by label ---
# Scans work-orders/ for an open work order matching the given label.
# Arguments:
#   $1 — label to match
# Output: work order ID on stdout (empty if not found)
_find_work_order_by_label() {
  local label="$1"
  local wo_dir
  wo_dir="$(_queue_dir)/work-orders"
  [ -d "$wo_dir" ] || return 0

  local f
  for f in "$wo_dir"/*.yaml; do
    [ -f "$f" ] || continue
    _load_work_order "$f" || continue
    if [ "$_WO_STATUS" = "open" ] && [ "$_WO_LABEL" = "$label" ]; then
      printf '%s' "$_WO_ID"
      return
    fi
  done
}

# --- Derive work order label from entry context ---
# For taskgroup entries: uses branch or brief_path to derive a group label.
# For standalone entries: uses brief_path basename.
# Arguments:
#   $1 — session_type
#   $2 — branch
#   $3 — brief_path
# Output: label on stdout
_derive_work_order_label() {
  local session_type="$1"
  local branch="$2"
  local brief_path="$3"

  case "$session_type" in
    taskgroup|taskgroup-merge)
      # Use branch as label (task group branches identify the group)
      if [ -n "$branch" ]; then
        printf '%s' "$branch"
      elif [ -n "$brief_path" ]; then
        printf '%s' "$(basename "$brief_path" .md)"
      else
        printf '%s' "taskgroup-$(date +%s)"
      fi
      ;;
    *)
      if [ -n "$brief_path" ]; then
        printf '%s' "$(basename "$brief_path" .md)"
      else
        printf '%s' "entry-$(date +%s)"
      fi
      ;;
  esac
}

# --- Enqueue a new entry ---
# Creates a queue entry in pending-review/ with generated UUID.
# Automatically associates the entry with a work order:
#   - If work_order_id is provided, uses it directly
#   - If taskgroup/taskgroup-merge type, finds or creates a group work order
#   - Otherwise, creates a single-type work order
# Arguments:
#   $1 — brief_path (path to task brief file)
#   $2 — session_type (Decision 0014 enum)
#   $3 — auto_mode (optional, default from config)
#   $4 — solo_mode (optional, default from config)
#   $5 — branch (optional, for task group briefs)
#   $6 — work_order_id (optional, explicit work order association)
# Output: UUID on stdout
queue_enqueue() {
  local brief_path="$1"
  local session_type="$2"
  local auto_mode="${3:-}"
  local solo_mode="${4:-}"
  local branch="${5:-}"
  local work_order_id="${6:-}"

  _ensure_queue_dirs

  # Generate UUID
  local entry_id
  if command -v uuidgen > /dev/null 2>&1; then
    entry_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
  else
    entry_id="$(date +%s)-$$-$RANDOM"
  fi

  # Defaults from config
  if [ -z "$auto_mode" ]; then
    auto_mode=$(_parse_config_field "runner" "default_auto_mode")
    auto_mode="${auto_mode:-false}"
  fi
  if [ -z "$solo_mode" ]; then
    solo_mode=$(_parse_config_field "runner" "default_solo_mode")
    solo_mode="${solo_mode:-false}"
  fi
  local max_retries
  max_retries=$(_parse_config_field "runner" "max_retries")
  max_retries="${max_retries:-3}"

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Populate module variables
  _QE_ID="$entry_id"
  _QE_STATUS="pending-review"
  _QE_SESSION_TYPE="$session_type"
  _QE_BRANCH="$branch"
  _QE_BRIEF_PATH="$brief_path"
  _QE_PROMPT=""
  _QE_AUTO_MODE="$auto_mode"
  _QE_SOLO_MODE="$solo_mode"
  _QE_RETRY_COUNT="0"
  _QE_MAX_RETRIES="$max_retries"
  _QE_ERROR_LOG=""
  _QE_WORK_ORDER_ID=""
  _QE_CREATED_AT="$timestamp"
  _QE_UPDATED_AT="$timestamp"
  _QE_COMPLETED_AT=""

  local qdir
  qdir=$(_queue_dir)
  _write_queue_entry "$qdir/pending-review/${entry_id}.yaml"

  # --- Work order association ---
  local _wo_was_created=false
  if type wo_create > /dev/null 2>&1; then
    if [ -n "$work_order_id" ]; then
      # Explicit work order — just add this entry as child
      wo_add_child "$work_order_id" "$entry_id" 2>/dev/null || true
    else
      # Auto-resolve: find or create work order
      local wo_label
      wo_label=$(_derive_work_order_label "$session_type" "$branch" "$brief_path")

      case "$session_type" in
        taskgroup|taskgroup-merge)
          # Look for existing open group work order with same label
          local existing_wo
          existing_wo=$(_find_work_order_by_label "$wo_label")
          if [ -n "$existing_wo" ]; then
            work_order_id="$existing_wo"
            wo_add_child "$work_order_id" "$entry_id" 2>/dev/null || true
          else
            work_order_id=$(wo_create "group" "$wo_label" "$entry_id")
            _wo_was_created=true
          fi
          ;;
        *)
          # Standalone — create a single-type work order
          work_order_id=$(wo_create "single" "$wo_label" "$entry_id")
          _wo_was_created=true
          ;;
      esac
    fi

    # Emit work-order-opened event when a new work order was just created
    if [ -n "$work_order_id" ] && [ "$_wo_was_created" = true ]; then
      if type review_log_append > /dev/null 2>&1; then
        review_log_append "work-order-opened" "$work_order_id" "$entry_id" \
          "Work order $work_order_id opened ($wo_label)" 2>/dev/null || true
      fi
    fi

    # Update entry with resolved work_order_id
    if [ -n "$work_order_id" ]; then
      _load_queue_entry "$qdir/pending-review/${entry_id}.yaml"
      _QE_WORK_ORDER_ID="$work_order_id"
      _write_queue_entry "$qdir/pending-review/${entry_id}.yaml"
    fi
  fi

  _rebuild_queue_index

  printf '%s' "$entry_id"
}

# --- Approve an entry ---
# Moves from pending-review to approved.
# Arguments:
#   $1 — entry_id
queue_approve() {
  local entry_id="$1"
  _transition "$entry_id" "pending-review" "approved"
}

# --- Dequeue the oldest approved entry ---
# Picks the entry with the earliest created_at from approved/.
# Moves it to running/ and outputs the entry file path.
# Returns 1 if no approved entries exist.
queue_dequeue() {
  local qdir
  qdir=$(_queue_dir)
  local oldest_file="" oldest_ts=""

  local f
  for f in "$qdir/approved"/*.yaml; do
    [ -f "$f" ] || continue
    _load_queue_entry "$f"
    local ts="$_QE_CREATED_AT"
    # ISO 8601 timestamps are lexicographically sortable
    if [ -z "$oldest_ts" ] || [[ "$ts" < "$oldest_ts" ]]; then
      oldest_ts="$ts"
      oldest_file="$f"
    fi
  done

  if [ -z "$oldest_file" ]; then
    return 1
  fi

  local entry_id
  entry_id=$(basename "$oldest_file" .yaml)
  _transition "$entry_id" "approved" "running"
  printf '%s' "$qdir/running/${entry_id}.yaml"
}

# --- Complete a running entry ---
# Moves from running to completed with completed_at timestamp.
# Arguments:
#   $1 — entry_id
queue_complete() {
  local entry_id="$1"
  local qdir
  qdir=$(_queue_dir)
  local src_file="$qdir/running/${entry_id}.yaml"

  if [ ! -f "$src_file" ]; then
    echo "ERROR: Entry $entry_id not found in running/" >&2
    return 1
  fi

  _load_queue_entry "$src_file"
  _QE_STATUS="completed"
  _QE_COMPLETED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _QE_UPDATED_AT="$_QE_COMPLETED_AT"

  _write_queue_entry "$qdir/completed/${entry_id}.yaml"
  rm -f "$src_file"
  _rebuild_queue_index
}

# --- Fail a running entry ---
# Increments retry_count. If retries exhausted, moves to failed/.
# Otherwise moves back to approved/ for retry.
# Arguments:
#   $1 — entry_id
queue_fail() {
  local entry_id="$1"
  local qdir
  qdir=$(_queue_dir)
  local src_file="$qdir/running/${entry_id}.yaml"

  if [ ! -f "$src_file" ]; then
    echo "ERROR: Entry $entry_id not found in running/" >&2
    return 1
  fi

  _load_queue_entry "$src_file"
  _QE_RETRY_COUNT=$(( ${_QE_RETRY_COUNT:-0} + 1 ))
  _QE_UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [ "$_QE_RETRY_COUNT" -ge "${_QE_MAX_RETRIES:-3}" ]; then
    # Retries exhausted — move to failed
    _QE_STATUS="failed"
    _QE_COMPLETED_AT="$_QE_UPDATED_AT"
    _write_queue_entry "$qdir/failed/${entry_id}.yaml"
  else
    # Retry — move back to approved
    _QE_STATUS="approved"
    _QE_PROMPT=""
    _write_queue_entry "$qdir/approved/${entry_id}.yaml"
  fi

  rm -f "$src_file"
  _rebuild_queue_index
}

# --- Escalate a running entry ---
# Moves from running to review/ for operator attention.
# Arguments:
#   $1 — entry_id
queue_escalate() {
  local entry_id="$1"
  local qdir
  qdir=$(_queue_dir)
  local src_file="$qdir/running/${entry_id}.yaml"

  if [ ! -f "$src_file" ]; then
    echo "ERROR: Entry $entry_id not found in running/" >&2
    return 1
  fi

  _load_queue_entry "$src_file"
  _QE_STATUS="review"
  _QE_COMPLETED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _QE_UPDATED_AT="$_QE_COMPLETED_AT"

  _write_queue_entry "$qdir/review/${entry_id}.yaml"
  rm -f "$src_file"
  _rebuild_queue_index
}

# --- Block a running entry ---
# Moves from running to blocked/ with reason.
# Arguments:
#   $1 — entry_id
#   $2 — reason (stored in error_log field)
queue_block() {
  local entry_id="$1"
  local reason="${2:-}"
  local qdir
  qdir=$(_queue_dir)
  local src_file="$qdir/running/${entry_id}.yaml"

  if [ ! -f "$src_file" ]; then
    echo "ERROR: Entry $entry_id not found in running/" >&2
    return 1
  fi

  _load_queue_entry "$src_file"
  _QE_STATUS="blocked"
  _QE_ERROR_LOG="$reason"
  _QE_COMPLETED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _QE_UPDATED_AT="$_QE_COMPLETED_AT"

  _write_queue_entry "$qdir/blocked/${entry_id}.yaml"
  rm -f "$src_file"
  _rebuild_queue_index
}
