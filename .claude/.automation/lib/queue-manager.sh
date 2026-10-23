#!/usr/bin/env bash
# Queue manager — queue state machine for headless runner sessions.
# Sourced by runner.sh. NOT executed standalone.
# Decision 0017 — Operator Automation Layer.
#
# State machine: pending-review → approved → running → completed/failed/review/blocked
#                running → stopped → approved (operator stop/resume, t-0055)
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
  for status in pending-review approved running completed failed review blocked stopped; do
    mkdir -p "$qdir/$status" 2>/dev/null || true
  done
}

# --- Module variables (mirrors queue-entry.yaml fields) ---
_QE_ID="" _QE_STATUS="" _QE_PRIORITY="" _QE_SESSION_TYPE="" _QE_BRANCH="" _QE_BRIEF_PATH=""
_QE_PROMPT="" _QE_LAST_PROMPT="" _QE_AUTO_MODE="" _QE_SOLO_MODE="" _QE_PUSH_ON_COMPLETE="" _QE_RETRY_COUNT=""
_QE_MAX_RETRIES="" _QE_ERROR_LOG="" _QE_WORK_ORDER_ID="" _QE_CREATED_AT=""
_QE_UPDATED_AT="" _QE_COMPLETED_AT="" _QE_PERMISSION_PROFILE="" _QE_MODEL=""
# (v1.4.0) project / milestone — optional; resolved against work order at read time
_QE_PROJECT="" _QE_MILESTONE_NAME="" _QE_MILESTONE_INDEX="" _QE_MILESTONE_TOTAL=""
# (v1.7.0) operator stop/resume — t-0055
_QE_STOPPED_MODE="" _QE_RESUME=""
# (v1.8.0) hold the line behind a stopped entry — t-0055 clauses 9-11
_QE_HELD_BY="" _QE_INDEPENDENT="" _QE_FOLLOW_UP_OF=""

# --- Strip surrounding double quotes and unescape a YAML scalar value ---
# Handles both quoted ("value") and unquoted (value) formats for backward compat.
# After stripping quotes, reverses _yaml_escape_scalar escaping (\" → ", \\ → \).
# Bash 3.2 compatible: uses while-loop substitution instead of ${//}.
_strip_quotes() {
  local val="$1"
  case "$val" in
    \"*\")
      val="${val#\"}"; val="${val%\"}"
      # Unescape \" → " then \\ → \ (reverse order of escape)
      local out=""
      while case "$val" in *'\"'*) true ;; *) false ;; esac; do
        out="${out}${val%%\\\"*}\""
        val="${val#*\\\"}"
      done
      val="${out}${val}"
      out=""
      while case "$val" in *'\\'*) true ;; *) false ;; esac; do
        out="${out}${val%%\\\\*}\\"
        val="${val#*\\\\}"
      done
      val="${out}${val}"
      ;;
  esac
  printf '%s' "$val"
}

# --- Escape a value for YAML double-quoted scalar ---
# Backslashes and double quotes inside the value must be escaped
# to prevent malformed YAML output. Pure parameter expansion (zero-fork).
# Bash 3.2 compatible: uses while-loop substitution instead of ${//}.
_yaml_escape_scalar() {
  local val="$1" out=""
  # Escape existing backslashes first, then double quotes
  while case "$val" in *\\*) true ;; *) false ;; esac; do
    out="${out}${val%%\\*}\\\\"
    val="${val#*\\}"
  done
  val="${out}${val}"
  out=""
  while case "$val" in *'"'*) true ;; *) false ;; esac; do
    out="${out}${val%%\"*}\\\""
    val="${val#*\"}"
  done
  printf '%s' "${out}${val}"
}

# --- Bulk-read queue entry YAML into _QE_* variables (zero-fork) ---
# Queue entry format: `entry:` header followed by `  key: value` lines.
# Prompt field uses block scalar (`prompt: |`) — multi-line content follows indented.
# Returns 1 if the file is missing.
_load_queue_entry() {
  local entry_file="$1"
  _QE_ID="" _QE_STATUS="" _QE_PRIORITY="" _QE_SESSION_TYPE="" _QE_BRANCH="" _QE_BRIEF_PATH=""
  _QE_PROMPT="" _QE_LAST_PROMPT="" _QE_AUTO_MODE="" _QE_SOLO_MODE="" _QE_PUSH_ON_COMPLETE="" _QE_RETRY_COUNT=""
  _QE_MAX_RETRIES="" _QE_ERROR_LOG="" _QE_WORK_ORDER_ID="" _QE_CREATED_AT=""
  _QE_UPDATED_AT="" _QE_COMPLETED_AT=""
  _QE_PROJECT="" _QE_MILESTONE_NAME="" _QE_MILESTONE_INDEX="" _QE_MILESTONE_TOTAL=""
  _QE_REVERIFIED="" _QE_OVERLAP_FILES=""
  _QE_STOPPED_MODE="" _QE_RESUME=""
  _QE_HELD_BY="" _QE_INDEPENDENT="" _QE_FOLLOW_UP_OF=""
  [ -f "$entry_file" ] || return 1

  _QE_PERMISSION_PROFILE=""
  _QE_MODEL=""
  local _line _in_prompt=false _prompt_is_block=false _in_milestone=false
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

    # Handle milestone nested block (v1.4.0)
    if [ "$_in_milestone" = true ]; then
      case "$_line" in
        "    name: "*)  _QE_MILESTONE_NAME="${_line#    name: }"; continue ;;
        "    index: "*) _QE_MILESTONE_INDEX="${_line#    index: }"; continue ;;
        "    total: "*) _QE_MILESTONE_TOTAL="${_line#    total: }"; continue ;;
        "    "*)        continue ;;  # other 4-space sub-fields → stay in block
        *)              _in_milestone=false ;;  # 2-space sibling field → exit block, fall through
      esac
    fi

    case "$_line" in
      "  id: "*)           _QE_ID="${_line#  id: }" ;;
      "  status: "*)       _QE_STATUS="${_line#  status: }" ;;
      "  priority: "*)     _QE_PRIORITY="${_line#  priority: }" ;;
      "  session_type: "*) _QE_SESSION_TYPE="${_line#  session_type: }" ;;
      "  branch: "*)       _QE_BRANCH="${_line#  branch: }" ;;
      "  brief_path: "*)   _QE_BRIEF_PATH="${_line#  brief_path: }" ;;
      "  prompt: |")       _in_prompt=true; _prompt_is_block=true ;;
      "  prompt: "*)       _QE_PROMPT="${_line#  prompt: }" ;;
      "  last_prompt: "*)  _QE_LAST_PROMPT="${_line#  last_prompt: }" ;;
      "  auto_mode: "*)    _QE_AUTO_MODE="${_line#  auto_mode: }" ;;
      "  solo_mode: "*)    _QE_SOLO_MODE="${_line#  solo_mode: }" ;;
      "  push_on_complete: "*) _QE_PUSH_ON_COMPLETE="${_line#  push_on_complete: }" ;;
      "  retry_count: "*)  _QE_RETRY_COUNT="${_line#  retry_count: }" ;;
      "  max_retries: "*)  _QE_MAX_RETRIES="${_line#  max_retries: }" ;;
      "  error_log: "*)    _QE_ERROR_LOG="${_line#  error_log: }" ;;
      "  work_order_id: "*) _QE_WORK_ORDER_ID="${_line#  work_order_id: }" ;;
      "  stopped_mode: "*) _QE_STOPPED_MODE="${_line#  stopped_mode: }" ;;
      "  resume: "*)       _QE_RESUME="${_line#  resume: }" ;;
      "  held_by: "*)      _QE_HELD_BY="${_line#  held_by: }" ;;
      "  independent: "*)  _QE_INDEPENDENT="${_line#  independent: }" ;;
      "  follow_up_of: "*) _QE_FOLLOW_UP_OF="${_line#  follow_up_of: }" ;;
      "  project: "*)      _QE_PROJECT="${_line#  project: }" ;;
      "  milestone:")      _in_milestone=true ;;
      "  created_at: "*)   _QE_CREATED_AT="${_line#  created_at: }" ;;
      "  updated_at: "*)   _QE_UPDATED_AT="${_line#  updated_at: }" ;;
      "  completed_at: "*) _QE_COMPLETED_AT="${_line#  completed_at: }" ;;
      "  permission_profile: "*) _QE_PERMISSION_PROFILE="${_line#  permission_profile: }" ;;
      "  model: "*)              _QE_MODEL="${_line#  model: }" ;;
      "  reverified: "*)         _QE_REVERIFIED="${_line#  reverified: }" ;;
      # Carried as the literal YAML flow-sequence text, not as a parsed list —
      # see the note on _QE_OVERLAP_FILES at _write_queue_entry.
      "  overlap_files: "*)      _QE_OVERLAP_FILES="${_line#  overlap_files: }" ;;
    esac
  done < "$entry_file"

  # Strip surrounding double quotes and unescape from all inline-quoted scalar
  # fields (backward compat with both quoted and unquoted YAML formats).
  # Block scalar fields (prompt loaded via `|`) are not quoted and need no unescaping.
  _QE_ID=$(_strip_quotes "$_QE_ID")
  _QE_STATUS=$(_strip_quotes "$_QE_STATUS")
  _QE_PRIORITY=$(_strip_quotes "$_QE_PRIORITY")
  # Default missing priority to 0 (backward compat with entries created before priority support)
  [ -n "$_QE_PRIORITY" ] || _QE_PRIORITY="0"
  _QE_SESSION_TYPE=$(_strip_quotes "$_QE_SESSION_TYPE")
  _QE_BRANCH=$(_strip_quotes "$_QE_BRANCH")
  _QE_BRIEF_PATH=$(_strip_quotes "$_QE_BRIEF_PATH")
  # Prompt: only strip quotes if loaded from inline quoted scalar, not block scalar
  if [ "$_prompt_is_block" = false ]; then
    _QE_PROMPT=$(_strip_quotes "$_QE_PROMPT")
  fi
  _QE_LAST_PROMPT=$(_strip_quotes "$_QE_LAST_PROMPT")
  _QE_AUTO_MODE=$(_strip_quotes "$_QE_AUTO_MODE")
  _QE_SOLO_MODE=$(_strip_quotes "$_QE_SOLO_MODE")
  _QE_PUSH_ON_COMPLETE=$(_strip_quotes "$_QE_PUSH_ON_COMPLETE")
  _QE_RETRY_COUNT=$(_strip_quotes "$_QE_RETRY_COUNT")
  _QE_MAX_RETRIES=$(_strip_quotes "$_QE_MAX_RETRIES")
  _QE_ERROR_LOG=$(_strip_quotes "$_QE_ERROR_LOG")
  _QE_WORK_ORDER_ID=$(_strip_quotes "$_QE_WORK_ORDER_ID")
  _QE_STOPPED_MODE=$(_strip_quotes "$_QE_STOPPED_MODE")
  _QE_RESUME=$(_strip_quotes "$_QE_RESUME")
  _QE_HELD_BY=$(_strip_quotes "$_QE_HELD_BY")
  _QE_INDEPENDENT=$(_strip_quotes "$_QE_INDEPENDENT")
  _QE_FOLLOW_UP_OF=$(_strip_quotes "$_QE_FOLLOW_UP_OF")
  _QE_PROJECT=$(_strip_quotes "$_QE_PROJECT")
  _QE_MILESTONE_NAME=$(_strip_quotes "$_QE_MILESTONE_NAME")
  _QE_MILESTONE_INDEX=$(_strip_quotes "$_QE_MILESTONE_INDEX")
  _QE_MILESTONE_TOTAL=$(_strip_quotes "$_QE_MILESTONE_TOTAL")
  _QE_CREATED_AT=$(_strip_quotes "$_QE_CREATED_AT")
  _QE_UPDATED_AT=$(_strip_quotes "$_QE_UPDATED_AT")
  _QE_COMPLETED_AT=$(_strip_quotes "$_QE_COMPLETED_AT")
  _QE_PERMISSION_PROFILE=$(_strip_quotes "$_QE_PERMISSION_PROFILE")
  _QE_MODEL=$(_strip_quotes "$_QE_MODEL")
  _QE_REVERIFIED=$(_strip_quotes "$_QE_REVERIFIED")
  # _QE_OVERLAP_FILES is deliberately NOT unquoted: it is a flow sequence
  # (`["a","b"]`), not a scalar, and _strip_quotes would leave it alone anyway
  # since it neither starts nor ends with a double quote.
}

# --- Write queue entry YAML from _QE_* variables (atomic) ---
# Writes to tmp file then mv for atomicity on POSIX/APFS.
# Prompt field uses block scalar for multi-line safety.
_write_queue_entry() {
  local entry_file="$1"
  local tmp_file="${entry_file}.tmp"

  {
    printf 'entry:\n'
    printf '  id: "%s"\n' "$(_yaml_escape_scalar "$_QE_ID")"
    printf '  status: "%s"\n' "$(_yaml_escape_scalar "$_QE_STATUS")"
    printf '  priority: "%s"\n' "$(_yaml_escape_scalar "${_QE_PRIORITY:-0}")"
    printf '  session_type: "%s"\n' "$(_yaml_escape_scalar "$_QE_SESSION_TYPE")"
    printf '  branch: "%s"\n' "$(_yaml_escape_scalar "$_QE_BRANCH")"
    printf '  brief_path: "%s"\n' "$(_yaml_escape_scalar "$_QE_BRIEF_PATH")"
    # Prompt: use block scalar if multi-line, quoted if single-line, empty-string if empty
    if [ -z "$_QE_PROMPT" ]; then
      printf '  prompt: ""\n'
    elif case "$_QE_PROMPT" in *"
"*) true ;; *) false ;; esac; then
      printf '  prompt: |\n'
      # Indent each line by 4 spaces for YAML block scalar
      local _pline
      printf '%s\n' "$_QE_PROMPT" | while IFS= read -r _pline || [ -n "$_pline" ]; do
        printf '    %s\n' "$_pline"
      done
    else
      printf '  prompt: "%s"\n' "$(_yaml_escape_scalar "$_QE_PROMPT")"
    fi
    printf '  last_prompt: "%s"\n' "$(_yaml_escape_scalar "$_QE_LAST_PROMPT")"
    printf '  auto_mode: "%s"\n' "$(_yaml_escape_scalar "$_QE_AUTO_MODE")"
    printf '  solo_mode: "%s"\n' "$(_yaml_escape_scalar "$_QE_SOLO_MODE")"
    printf '  push_on_complete: "%s"\n' "$(_yaml_escape_scalar "$_QE_PUSH_ON_COMPLETE")"
    printf '  retry_count: "%s"\n' "$(_yaml_escape_scalar "$_QE_RETRY_COUNT")"
    printf '  max_retries: "%s"\n' "$(_yaml_escape_scalar "$_QE_MAX_RETRIES")"
    printf '  error_log: "%s"\n' "$(_yaml_escape_scalar "$_QE_ERROR_LOG")"
    printf '  work_order_id: "%s"\n' "$(_yaml_escape_scalar "$_QE_WORK_ORDER_ID")"
    printf '  stopped_mode: "%s"\n' "$(_yaml_escape_scalar "${_QE_STOPPED_MODE:-}")"
    printf '  resume: "%s"\n' "$(_yaml_escape_scalar "${_QE_RESUME:-false}")"
    printf '  held_by: "%s"\n' "$(_yaml_escape_scalar "${_QE_HELD_BY:-}")"
    printf '  independent: "%s"\n' "$(_yaml_escape_scalar "${_QE_INDEPENDENT:-false}")"
    # Written from v1.8.0 but populated by a later brief's follow-up-entry.
    # Round-tripped from the start so a v1.8.0 rewrite of an entry created later
    # cannot silently drop the pointer — _write_queue_entry rewrites whole files.
    printf '  follow_up_of: "%s"\n' "$(_yaml_escape_scalar "${_QE_FOLLOW_UP_OF:-}")"
    printf '  project: "%s"\n' "$(_yaml_escape_scalar "${_QE_PROJECT:-}")"
    printf '  milestone:\n'
    printf '    name: "%s"\n' "$(_yaml_escape_scalar "${_QE_MILESTONE_NAME:-}")"
    printf '    index: %s\n' "${_QE_MILESTONE_INDEX:-0}"
    printf '    total: %s\n' "${_QE_MILESTONE_TOTAL:-0}"
    printf '  created_at: "%s"\n' "$(_yaml_escape_scalar "$_QE_CREATED_AT")"
    printf '  updated_at: "%s"\n' "$(_yaml_escape_scalar "$_QE_UPDATED_AT")"
    printf '  completed_at: "%s"\n' "$(_yaml_escape_scalar "$_QE_COMPLETED_AT")"
    printf '  permission_profile: "%s"\n' "$(_yaml_escape_scalar "${_QE_PERMISSION_PROFILE:-build}")"
    printf '  model: "%s"\n' "$(_yaml_escape_scalar "${_QE_MODEL:-}")"
    printf '  reverified: "%s"\n' "$(_yaml_escape_scalar "${_QE_REVERIFIED:-}")"
    # Emitted verbatim. _QE_OVERLAP_FILES holds the rendered flow sequence, not
    # a list, because load/write only ever has to round-trip it — nothing reads
    # the element values back, and storing the rendered form means there is no
    # flow-sequence parser to keep in step with the renderer. Build it with
    # queue_yaml_flow_seq; an unset value writes the empty sequence.
    printf '  overlap_files: %s\n' "${_QE_OVERLAP_FILES:-[]}"
  } > "$tmp_file"
  mv "$tmp_file" "$entry_file"
}

# --- Render a newline list as a YAML flow sequence ---
# Arguments: $1 — newline-separated values (blank lines skipped)
# Output:    `[]`, or `["a","b"]` with each element escaped as a YAML scalar.
# Lives here rather than in the caller so the escaping stays next to
# _yaml_escape_scalar, which is what _write_queue_entry uses for every other
# field.
queue_yaml_flow_seq() {
  local line out="" first=true
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "$first" = true ]; then
      first=false
    else
      out="${out},"
    fi
    out="${out}\"$(_yaml_escape_scalar "$line")\""
  done <<EOF
${1:-}
EOF
  printf '[%s]' "$out"
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

  local statuses="pending-review approved running completed failed review blocked stopped"
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
        local _json_br="${_QE_BRANCH//\"/\\\"}"
        local _json_woid="${_QE_WORK_ORDER_ID//\"/\\\"}"
        entries_json="${entries_json}\"${_QE_ID}\":{\"status\":\"${_QE_STATUS}\",\"session_type\":\"${_QE_SESSION_TYPE}\",\"brief_path\":\"${_json_bp}\",\"branch\":\"${_json_br}\",\"work_order_id\":\"${_json_woid}\",\"created_at\":\"${_QE_CREATED_AT}\",\"updated_at\":\"${_QE_UPDATED_AT}\"}"
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
          local _old_ifs="$IFS"
          IFS=','
          # shellcheck disable=SC2086 — intentional word splitting on comma-delimited list
          for _wid in $_wo_snap_ids; do
            IFS="$_old_ifs"
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
          IFS="$_old_ifs"
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
  # Post-removal verification: confirm source file is actually gone
  if [ -f "$src_file" ]; then
    echo "WARNING: Source file persisted after rm — retrying removal: $src_file" >&2
    rm -f "$src_file"
    if [ -f "$src_file" ]; then
      echo "ERROR: Unable to remove source file after retry: $src_file" >&2
      # Destination was already written — proceed with index rebuild
    fi
  fi
  _rebuild_queue_index || true
}

# --- Parse a config field with local override support ---
# Checks config.local.yaml first (if it exists), then falls back to config.yaml.
# Arguments:
#   $1 — block name (e.g., "runner")
#   $2 — field name (e.g., "enabled")
# Output: field value on stdout
#
# ADDING A CONFIG FIELD — two traps, both of which have bitten:
#
# 1. Put the comment on its OWN LINE above the key, never after the value.
#    `s/.*${field}: *//` takes everything after the field name as the value, so
#    a trailing comment becomes part of it. If that comment contains a shell
#    metacharacter the sanitiser below then rejects the WHOLE value and the
#    field reads as ABSENT — the caller's hardcoded default silently wins and a
#    warning fires on every read. If it contains no metacharacter it is worse:
#    the comment text is passed through as the value. Measured on 2026-10-20:
#    `session_max_ttl_seconds` had been unconfigurable since it was added, and a
#    model override resolved to `sonnet#Per-cellagentrun-task...`, which was
#    being handed to `claude --model`.
#
# 2. The sed range is `/^${block}:/,/^[a-z]/` and the field pattern is an
#    unanchored `/${field}:/`, so ANY line in the block containing `<field>:` —
#    including a comment line — is matched, and `tr -d '[:space:]'` runs before
#    `head -1`, which concatenates multiple matches rather than discarding them.
#    Do not name a field inside a comment within its own block.
_parse_config_field() {
  local block="$1"
  local field="$2"
  local value=""
  # Check local override file first
  if [ -n "${CONFIG_LOCAL_FILE:-}" ] && [ -f "$CONFIG_LOCAL_FILE" ]; then
    value=$(sed -n "/^${block}:/,/^[a-z]/{ /${field}:/p; }" "$CONFIG_LOCAL_FILE" \
      | sed "s/.*${field}: *//" | tr -d '[:space:]' | head -1)
  fi
  # Fall back to tracked config
  if [ -z "$value" ]; then
    value=$(sed -n "/^${block}:/,/^[a-z]/{ /${field}:/p; }" "$CONFIG_FILE" \
      | sed "s/.*${field}: *//" | tr -d '[:space:]' | head -1)
  fi
  # Config value sanitization (adversarial M2): reject shell metacharacters
  case "$value" in
    *[\;\|\&\`\$\(\)]*)
      echo "WARNING: Config value for ${block}.${field} contains shell metacharacters — rejected" >&2
      printf ''
      return
      ;;
  esac
  printf '%s' "$value"
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

# --- Parse task group metadata from a brief file ---
# Extracts ### Task Group section fields and sets module variables.
# Arguments:
#   $1 — brief file path (must exist)
# Sets:
#   _BRIEF_TG_DETECTED    (true/false) — whether valid task group metadata found
#   _BRIEF_TG_GROUP_NAME  — extracted from "- **Group:** <value>" line
#   _BRIEF_TG_IS_MERGE    (true/false) — true if brief title contains "merge"
#   _BRIEF_TG_IS_PARALLEL (true/false) — true if "- **Execution:** parallel" found
_parse_brief_taskgroup_metadata() {
  local brief_file="$1"
  _BRIEF_TG_DETECTED=false
  _BRIEF_TG_GROUP_NAME=""
  _BRIEF_TG_IS_MERGE=false
  _BRIEF_TG_IS_PARALLEL=false

  [ -f "$brief_file" ] || return 0

  # Extract ### Task Group section (between exact level-3 heading and next ###)
  local tg_section
  tg_section=$(sed -n '/^### Task Group$/,/^###/{/^### Task Group$/d;/^###/d;p;}' "$brief_file")

  # No section found — not a task group brief
  [ -z "$tg_section" ] && return 0

  # Extract Group: field
  # Extract and trim leading/trailing whitespace only (Group values are kebab-case per template)
  # `|| true` is load-bearing. Callers source this library into scripts running
  # under `set -euo pipefail` (runner.sh, queue-cli.sh), where grep finding no
  # canonical Group line fails the pipeline and aborts the whole process at this
  # assignment — so the warning branch immediately below was unreachable dead
  # code, and enqueuing a brief with a ### Task Group section but no
  # `- **Group:**` line killed the enqueue instead of degrading to standard.
  _BRIEF_TG_GROUP_NAME=$(printf '%s\n' "$tg_section" | grep -m1 '^\- \*\*Group:\*\*' | sed 's/^- \*\*Group:\*\* *//;s/^[[:space:]]*//;s/[[:space:]]*$//' || true)

  if [ -z "$_BRIEF_TG_GROUP_NAME" ]; then
    echo "WARNING: Brief has ### Task Group section but no Group: field — treating as standard" >&2
    return 0
  fi

  _BRIEF_TG_DETECTED=true

  # Check for merge in brief title (first ## Task Brief: line)
  local title_line
  title_line=$(grep -m1 '^## Task Brief:' "$brief_file" 2>/dev/null || true)
  if [ -n "$title_line" ]; then
    # Case-insensitive merge check (Bash 3.2 compatible — use grep)
    if printf '%s' "$title_line" | grep -qi 'merge'; then
      _BRIEF_TG_IS_MERGE=true
    fi
  fi

  # Check for parallel execution.
  # The pattern must match runner.sh's _brief_is_sequential_group. This accepted
  # only the fully canonical '- **Execution:** parallel' while the runner also
  # accepted the bare and half-bold forms, so a legacy brief was classified
  # parallel by the runner (per-brief worktrees) and sequential here (which sets
  # the work order's group semantics) — a silent disagreement between the two
  # halves of the same decision. Both sides now accept the same three forms.
  # See known-issue R9: these parsers are deliberately duplicated, so a change
  # to one is a change to all of them.
  if printf '%s\n' "$tg_section" \
     | grep -qE '^[[:space:]]*(-[[:space:]]*)?(\*\*)?Execution:?(\*\*)?:?[[:space:]]*parallel'; then
    _BRIEF_TG_IS_PARALLEL=true
  fi
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
#   $7 — push_on_complete (optional, default from config)
#   $8 — priority (optional, default 0; lower = higher priority)
#   $9 — permission_profile (optional, default build)
#   ${10} — project (optional, v1.4.0)
#   ${11} — milestone_name (optional, v1.4.0)
#   ${12} — milestone_index (optional, v1.4.0; integer)
#   ${13} — milestone_total (optional, v1.4.0; integer)
#   ${14} — model (optional; per-entry model pin — bypasses _resolve_model_for_session
#             in runner.sh; default empty; Decision t-0046 Amendment 3)
#   ${15} — follow_up_of (optional, v1.9.0; id of the entry this one follows up on,
#             t-0055 clause 14). Positional rather than a post-create queue_edit
#             like `independent`, because the link is part of the entry's identity:
#             the generated brief filename encodes it, and the dequeue selector
#             reads it to decide both ordering and branch.
# Output: UUID on stdout
queue_enqueue() {
  local brief_path="$1"
  local session_type="$2"
  local auto_mode="${3:-}"
  local solo_mode="${4:-}"
  local branch="${5:-}"
  local work_order_id="${6:-}"
  local push_on_complete="${7:-}"
  local priority="${8:-0}"
  local permission_profile="${9:-build}"
  local project="${10:-}"
  local milestone_name="${11:-}"
  local milestone_index="${12:-0}"
  local milestone_total="${13:-0}"
  local model="${14:-}"
  local follow_up_of="${15:-}"

  _ensure_queue_dirs

  # --- Brief deduplication: check pending-review/ and approved/ for matching brief_path ---
  # Prevents double-queuing the same brief. Running/failed/completed are NOT checked
  # to allow re-queuing after failure or completion.
  local _dedup_dir _dedup_status
  local qdir_dedup
  qdir_dedup=$(_queue_dir)
  for _dedup_status in pending-review approved; do
    _dedup_dir="$qdir_dedup/$_dedup_status"
    [ -d "$_dedup_dir" ] || continue
    local _dedup_f
    for _dedup_f in "$_dedup_dir"/*.yaml; do
      [ -f "$_dedup_f" ] || continue
      _load_queue_entry "$_dedup_f" 2>/dev/null || continue
      if [ "$_QE_BRIEF_PATH" = "$brief_path" ]; then
        local _existing_id="$_QE_ID"
        echo "duplicate:$_existing_id" >&2
        echo "$_existing_id"
        return 0
      fi
    done
  done

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
  if [ -z "$push_on_complete" ]; then
    push_on_complete=$(_parse_config_field "runner" "default_push_on_complete")
    push_on_complete="${push_on_complete:-false}"
  fi
  local max_retries
  max_retries=$(_parse_config_field "runner" "max_retries")
  max_retries="${max_retries:-3}"

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Populate module variables
  _QE_ID="$entry_id"
  _QE_STATUS="pending-review"
  _QE_PRIORITY="$priority"
  _QE_SESSION_TYPE="$session_type"
  _QE_BRANCH="$branch"
  _QE_BRIEF_PATH="$brief_path"
  _QE_PROMPT=""
  _QE_LAST_PROMPT=""
  _QE_AUTO_MODE="$auto_mode"
  _QE_SOLO_MODE="$solo_mode"
  _QE_PUSH_ON_COMPLETE="$push_on_complete"
  _QE_RETRY_COUNT="0"
  _QE_MAX_RETRIES="$max_retries"
  _QE_ERROR_LOG=""
  _QE_WORK_ORDER_ID=""
  _QE_PROJECT="$project"
  _QE_MILESTONE_NAME="$milestone_name"
  _QE_MILESTONE_INDEX="$milestone_index"
  _QE_MILESTONE_TOTAL="$milestone_total"
  _QE_CREATED_AT="$timestamp"
  _QE_UPDATED_AT="$timestamp"
  _QE_COMPLETED_AT=""
  _QE_PERMISSION_PROFILE="${permission_profile:-build}"
  _QE_MODEL="${model:-}"
  _QE_FOLLOW_UP_OF="$follow_up_of"
  # The dedup scan above ran _load_queue_entry over other entries, so every
  # module variable this function does not assign still holds that last entry's
  # value. Every field above is assigned; these are the ones that were not, and
  # they are exactly the fields a scanned entry is likely to have set. Reset
  # them explicitly rather than relying on the caller having a fresh process.
  _QE_STOPPED_MODE="" _QE_RESUME="false"
  _QE_HELD_BY="" _QE_INDEPENDENT="false"
  _QE_REVERIFIED="" _QE_OVERLAP_FILES=""

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

      # Pre-set project/milestone so wo_create picks them up (v1.4.0)
      _WO_PROJECT="$project"
      _WO_MILESTONE_NAME="$milestone_name"
      _WO_MILESTONE_INDEX="$milestone_index"
      _WO_MILESTONE_TOTAL="$milestone_total"

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

  _rebuild_queue_index || true

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

# --- Return a reviewed entry to the queue ---
# Moves from review back to approved, and restores the retry budget.
#
# Until 2026-10-21 there was NO transition out of `review/` at all: queue_approve
# handles pending-review only, queue-cli's recover-entry handles running only,
# and reopen-wo resets blocked|failed siblings only. So every `review:*` outcome
# — escalation, scope-deviation, dirty-noop, incomplete-deliverable,
# finish-incomplete, merge-conflict and the new turn-budget-exhausted — put an
# entry somewhere the CLI could not move it from. `status` is not in
# queue_edit's allowlist, and `_repair_status_mismatches` would rewrite a
# hand-edited status back to match the directory, so the only exit was re-adding
# the brief as a new entry and losing the original's history. That is the shape
# this repo keeps producing: a guard with no documented way out.
#
# The retry budget is restored for the same reason reopen-wo restores it (R21):
# returning an entry to the queue is an explicit operator decision to try again,
# and an entry handed back at its retry ceiling fails on its first stumble.
# Arguments:
#   $1 — entry_id
#
# Lookup order is review/ then failed/. The name is historical: it was
# review-only until a crashed daemon showed the same guard-with-no-way-out in
# the other terminal directory. `recover-entry` rescues a stale `running` entry
# by writing it to `failed/` and leaving the parent work order `open` — and that
# pair had no exit at all, because `reopen-entry` demanded review/ while
# `reopen-wo` refused a work order that was not escalated or failed. The
# capability already existed (reopen-wo resets blocked|failed siblings); it was
# simply unreachable for a single entry whose work order was healthy. Hit live
# on 2026-10-23 when the daemon died with its parent process.
#
# "Terminal" in `queue_fail_terminal` means the DAEMON will not retry, not that
# the operator cannot: operator reopen is the intended exit. An infrastructure
# failure whose cause still stands will fail again, which is why the reason is
# written to the review log below before `error_log` is cleared.
queue_reopen_reviewed() {
  local entry_id="$1"
  local qdir
  qdir=$(_queue_dir)
  local src_file="$qdir/review/${entry_id}.yaml"
  local src_dir="review"
  if [ ! -f "$src_file" ]; then
    src_file="$qdir/failed/${entry_id}.yaml"
    src_dir="failed"
  fi
  if [ ! -f "$src_file" ]; then
    echo "ERROR: Entry $entry_id is not in review/ or failed/" >&2
    return 1
  fi
  _load_queue_entry "$src_file"
  # Preserve why it stopped. error_log is cleared below, and for a failed entry
  # that is the only record of the cause — losing it means the operator retries
  # blind and, if the cause stands, lands back here with no trail.
  if [ -n "${_QE_ERROR_LOG:-}" ]; then
    review_log_append "entry-reopen-reason" "${_QE_WORK_ORDER_ID:-}" "$entry_id" \
      "Reopened from ${src_dir}/ — prior failure: ${_QE_ERROR_LOG}" 2>/dev/null || true
  fi
  _REOPEN_SRC_DIR="$src_dir"
  _QE_STATUS="approved"
  _QE_UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _QE_RETRY_COUNT="0"
  _QE_COMPLETED_AT=""
  _QE_ERROR_LOG=""
  # Preserve the prompt before clearing it, the way queue_fail does. The
  # `review/` entry still holds the prompt the exhausted session actually ran,
  # and this function was destroying it — which sits badly next to the turn-budget
  # branch's own rationale that discarding the reason work was dropped is the
  # wrong half to keep. `queue-cli.sh show <id>` surfaces last_prompt.
  _QE_LAST_PROMPT="${_QE_PROMPT:-$_QE_LAST_PROMPT}"
  _QE_PROMPT=""
  _write_queue_entry "$qdir/approved/${entry_id}.yaml"
  rm -f "$src_file" 2>/dev/null || true

  # Reopen the parent work order, and clear the deferral counter.
  #
  # Without this the command does not do what it says. EVERY entry gets a work
  # order — `single` for a standalone entry, `group` for a task group — and when
  # a child goes to `review` the work order becomes `escalated`. The runner's
  # post-dequeue guard then sees an escalated work order, defers the entry, and
  # after `max_deferral_cycles` (default 3) transitions it to `blocked/`. So the
  # first version of this function returned the entry to `approved/` and the
  # daemon walked it straight into `blocked/` — the advertised exit relocated
  # the failure instead of clearing it, which is the very class of defect this
  # change set exists to remove. `wo_check_completion`'s `open` branch
  # deliberately does not write, so only `wo_reopen` can clear `escalated`.
  #
  # The defer counter is cleared for the same reason `reopen-wo` clears it: an
  # entry re-entering with a part-spent counter gets fewer cycles than a fresh
  # one, for no reason the operator can see.
  # Scoped, NOT unconditional. `wo_reopen` writes only the work-order file —
  # it has no sibling semantics — so for a `single` work order (one entry, the
  # standalone shape) it is exactly right. For a `group` work order it is too
  # broad in two ways: it flips the whole group to `open`, which un-gates
  # siblings the deferral guard was correctly holding back, and it clears
  # `failure_entry_id` while a sibling may still be sitting in `failed/`, losing
  # the pointer to the brief that actually broke. So a group is reopened here
  # only when no OTHER child is in a state the guard exists to respect;
  # otherwise the work order is left alone and the operator is pointed at
  # `reopen-wo`, which does reset siblings.
  #
  # Do not "fix" this by calling `wo_check_completion` afterwards: for a group
  # with another child in review or blocked it recomputes `escalated` and writes
  # it straight back, silently undoing the reopen.
  # Output variable, read by the caller: did the parent work order actually get
  # reopened? Without this the CLI printed the same success line and the same
  # JSON whether the work order was cleared or deliberately left failed, so
  # neither a human nor a script could tell the two apart — and the only signal
  # was three stderr lines.
  _RR_WO_REOPENED="n/a"
  _RR_WO_BLOCKERS=""
  if [ -n "${_QE_WORK_ORDER_ID:-}" ]; then
    if ! type wo_reopen > /dev/null 2>&1; then
      echo "WARNING: work-order-manager.sh not sourced — work order $_QE_WORK_ORDER_ID left as-is; entry $entry_id may be deferred on the next poll" >&2
      _RR_WO_REOPENED="false"
    else
      local _rr_wo_file="$(_wo_dir)/${_QE_WORK_ORDER_ID}.yaml"
      if [ -f "$_rr_wo_file" ]; then
        local _rr_loaded=true
        _load_work_order "$_rr_wo_file" 2>/dev/null || _rr_loaded=false
        local _rr_blockers=""
        # An unreadable work order is treated as a GROUP, not as a single. On a
        # failed load every `_WO_*` is empty, so a `${_WO_TYPE:-single}` default
        # would route an unreadable group straight down the unconditional
        # reopen path — reinstating exactly the over-reach this scoping exists
        # to prevent. The conservative direction is the one that declines.
        if [ "$_rr_loaded" = false ]; then
          _rr_blockers="(work order could not be read) "
        elif [ "$_WO_TYPE" != "single" ] && [ -n "${_WO_ENTRY_IDS:-}" ]; then
          local _rr_old_ifs="$IFS"
          IFS=','
          # shellcheck disable=SC2086 — intentional word splitting
          set -- $_WO_ENTRY_IDS
          IFS="$_rr_old_ifs"
          local _rr_sib
          for _rr_sib in "$@"; do
            [ "$_rr_sib" = "$entry_id" ] && continue
            local _rr_s
            for _rr_s in review blocked failed; do
              if [ -f "$qdir/$_rr_s/${_rr_sib}.yaml" ]; then
                _rr_blockers="${_rr_blockers}${_rr_sib} ($_rr_s) "
              fi
            done
          done
        fi
        if [ -n "$_rr_blockers" ]; then
          echo "NOTE: work order $_QE_WORK_ORDER_ID has other children still unresolved: $_rr_blockers" >&2
          echo "      Left as-is deliberately — reopening it here would un-gate those siblings and discard the group's failure pointer." >&2
          echo "      Entry $entry_id is back in approved/ but will be deferred until the group is reopened: queue-cli.sh reopen-wo $_QE_WORK_ORDER_ID" >&2
          _RR_WO_REOPENED="false"
          _RR_WO_BLOCKERS="$_rr_blockers"
        elif ! wo_is_escalated "$_QE_WORK_ORDER_ID" 2>/dev/null \
             && ! wo_is_failed "$_QE_WORK_ORDER_ID" 2>/dev/null; then
          # Not escalated and not failed, so there is nothing for the deferral
          # guard to catch and nothing to reopen. `wo_reopen` refuses a work
          # order in this state, and reporting that refusal as "may be deferred"
          # would be a warning about a healthy one. (There is no `wo_is_open`
          # predicate — the guard itself tests these same two, so testing them
          # here keeps the two in step.)
          _RR_WO_REOPENED="not-needed"
        else
          if wo_reopen "$_QE_WORK_ORDER_ID" > /dev/null 2>&1; then
            _RR_WO_REOPENED="true"
          else
            echo "WARNING: could not reopen work order $_QE_WORK_ORDER_ID — entry $entry_id may be deferred on the next poll" >&2
            _RR_WO_REOPENED="false"
          fi
        fi
      fi
    fi
  fi
  rm -f "$qdir/.defer-count-${entry_id}" 2>/dev/null || true

  # `|| true` to match every sibling transition (_transition, queue_complete,
  # queue_fail, queue_escalate, queue_block, queue_defer all guard it). Without
  # it, a rebuild failure returns non-zero AFTER the entry has already moved and
  # the work order has been reopened, so the caller reports failure and skips
  # its log line on a reopen that actually succeeded.
  _rebuild_queue_index || true
}

# --- Parse task group brief sequence number ---
# Extracts N from "**Brief:** N of M" in the ### Task Group section of a brief file.
# Returns the sequence number via stdout, or empty string if not found/parseable.
_parse_brief_sequence() {
  local brief_path="$1"
  [ -n "$brief_path" ] && [ -f "$brief_path" ] || return 0
  local line in_taskgroup=false after seq
  while IFS= read -r line; do
    case "$line" in
      "### Task Group") in_taskgroup=true ;;  # Exact match (consistent with _parse_brief_taskgroup_metadata)
      "### "*) [ "$in_taskgroup" = true ] && break ;;  # Left the section
      *"**Brief:**"*" of "*)
        [ "$in_taskgroup" = true ] || continue
        # Extract N from "**Brief:** N of M — title"
        after="${line#*\*\*Brief:\*\* }"
        seq="${after%% of *}"
        # Validate it's a number
        case "$seq" in
          ''|*[!0-9]*) return 0 ;;
          *) printf '%s' "$seq"; return 0 ;;
        esac
        ;;
    esac
  done < "$brief_path"
}

# --- Check if a task group entry has prior unfinished briefs ---
# Returns 0 (true) if a sibling taskgroup entry with a lower sequence number
# exists in approved/ or running/. Returns 1 (false) otherwise.
# Only checks session_type "taskgroup" — taskgroup-merge entries are excluded
# because merge briefs run after all content briefs, not as sequenced peers.
_has_prior_taskgroup_entry() {
  local work_order_id="$1"
  local my_seq="$2"
  local skip_file="$3"
  local qdir
  qdir=$(_queue_dir)

  local dir f
  for dir in "$qdir/approved" "$qdir/running"; do
    for f in "$dir"/*.yaml; do
      [ -f "$f" ] || continue
      [ "$f" = "$skip_file" ] && continue
      _load_queue_entry "$f"
      [ "$_QE_WORK_ORDER_ID" = "$work_order_id" ] || continue
      [ "$_QE_SESSION_TYPE" = "taskgroup" ] || continue
      local sib_seq
      sib_seq=$(_parse_brief_sequence "$_QE_BRIEF_PATH")
      # Unparseable sibling → skip (not a sequencing barrier). Graceful degradation:
      # a missing or malformed brief file does not block higher-sequence entries.
      [ -n "$sib_seq" ] || continue
      if [ "$sib_seq" -lt "$my_seq" ]; then
        return 0
      fi
    done
  done
  return 1
}

# --- Shared entry sort — selection sort on _se_ts_N/_se_fp_N parallel arrays ---
# Used by queue_dequeue (via _dq_cleanup alias below) and queue_list.
# Sort contract: approved/pending-review/running use "asc" (created_at ASC),
# matching dequeue execution order. completed uses "desc" (completed_at DESC).
# failed/blocked/review use "desc" (updated_at DESC).
# ISO 8601 timestamps are lexicographically comparable as strings.
# Arguments:
#   $1 — count of entries in _se_ts_N/_se_fp_N arrays
#   $2 — order: "asc" (smallest first) or "desc" (largest first)
_sort_entries_by_ts() {
  local count="$1" order="${2:-asc}"
  [ "$count" -gt 1 ] || return 0
  local i j min_idx tmp_ts tmp_fp a_ts b_ts
  i=0
  while [ "$i" -lt "$(( count - 1 ))" ]; do
    min_idx=$i
    j=$(( i + 1 ))
    while [ "$j" -lt "$count" ]; do
      eval "a_ts=\"\$_se_ts_${j}\""
      eval "b_ts=\"\$_se_ts_${min_idx}\""
      if [ "$order" = "asc" ]; then
        if expr "$a_ts" \< "$b_ts" > /dev/null 2>&1; then
          min_idx=$j
        fi
      else
        if expr "$a_ts" \> "$b_ts" > /dev/null 2>&1; then
          min_idx=$j
        fi
      fi
      j=$(( j + 1 ))
    done
    if [ "$min_idx" -ne "$i" ]; then
      eval "tmp_ts=\"\$_se_ts_${i}\""
      eval "tmp_fp=\"\$_se_fp_${i}\""
      eval "_se_ts_${i}=\"\$_se_ts_${min_idx}\""
      eval "_se_fp_${i}=\"\$_se_fp_${min_idx}\""
      eval "_se_ts_${min_idx}=\"\$tmp_ts\""
      eval "_se_fp_${min_idx}=\"\$tmp_fp\""
    fi
    i=$(( i + 1 ))
  done
}

# --- Clean up _se_ts_N/_se_fp_N parallel arrays ---
_se_cleanup() {
  local count="${1:-0}" k=0
  while [ "$k" -lt "$count" ]; do
    unset "_se_ts_${k}" "_se_fp_${k}" 2>/dev/null || true
    k=$(( k + 1 ))
  done
}

# --- Legacy cleanup alias (backward compatibility) ---
# queue_dequeue now uses the temp-file sort idiom instead of _se_* parallel arrays.
# _dq_cleanup is retained as an alias in case external callers depend on it.
_dq_cleanup() {
  _se_cleanup "$@"
}

# ============================================================
# Hold the line behind a stopped entry — Decision t-0055 clauses 9-11
# ============================================================
#
# While an entry is stopping or stopped, everything queued after it is held:
# its branch is unmerged and possibly dirty, and anything that could depend on
# it must not start. A held entry carries `held_by: <stopped-entry-id>` and is
# invisible to the dequeue selector.
#
# The hold is DERIVED, never operator-managed. `queue_hold_evaluate` recomputes
# every held_by from scratch on each dequeue tick, so there is no hold to forget
# to release and no second source of truth to drift. Re-evaluating every tick is
# required rather than merely tidy: the stopped branch's changed-file set grows
# while it is stopped, so an entry released on one tick can be held on the next.
#
# Release is a proof obligation, not a default. An entry is let through only
# when all four conditions in `_hold_release_ok` hold, and an entry whose brief
# declares no scope_files can never satisfy the first — unknown scope is treated
# as overlapping scope.

# Base ref every branch-change set is diffed against. A constant, mirroring
# overlap-report.sh's `_OR_MAIN`: this repo's governance fixes main as the
# integration branch, so there is no main branch to detect.
_QH_MAIN_REF="main"
_QH_NL='
'
_QH_TAB=$'\t'

# Snapshot of the stopped entry currently being evaluated. Module-scoped rather
# than passed as arguments because `_hold_release_ok` reads them alongside the
# candidate's `_QE_*` vars, and `_load_queue_entry` would clobber any attempt to
# keep both entries in `_QE_*` at once.
_QH_S_ID="" _QH_S_BRANCH="" _QH_S_WO="" _QH_S_PRI="" _QH_S_CREATED="" _QH_S_FILES=""

# --- scope_files from a brief's ### Task Contract block ---
# Same list shape pre-commit-gates.sh reads out of .claude/local/task-contract.yaml:
# `scope_files:` at column 0, then `  - "path"` items until a non-item line.
# Output: one path per line; empty when the brief has no contract or no list.
_parse_brief_scope_files() {
  local brief_path="$1"
  [ -n "$brief_path" ] && [ -f "$brief_path" ] || return 0
  local line val in_scope=false
  while IFS= read -r line; do
    case "$line" in
      "scope_files:"*) in_scope=true ;;
      "  - "*)
        if [ "$in_scope" = true ]; then
          val="${line#  - }"
          val="${val#\"}"; val="${val%\"}"
          if [ -n "$val" ]; then
            printf '%s\n' "$val"
          fi
        fi
        ;;
      *) in_scope=false ;;
    esac
  done < "$brief_path"
}

# --- Files a branch has changed, plus anything uncommitted in its worktree ---
# `git diff --name-only main...<branch>` is the committed set; the worktree's
# porcelain status adds the work a stopped session had not committed yet.
# Fail-soft everywhere: an unresolvable ref, a missing worktree or any git error
# contributes nothing. That is safe in this direction — a smaller changed set
# can only make a release LOOK permissible, and the no-scope_files rule plus the
# branch and work-order conditions still have to pass independently.
# Arguments: $1 — branch name; $2 — worktree directory (optional)
_branch_changed_files() {
  local branch="$1" worktree="${2:-}"
  [ -n "$branch" ] || return 0
  git -C "${REPO_ROOT:-.}" diff --name-only "${_QH_MAIN_REF}...${branch}" 2>/dev/null || true
  [ -n "$worktree" ] && [ -d "$worktree" ] || return 0
  local st path
  while IFS= read -r st; do
    [ -n "$st" ] || continue
    # Porcelain v1: two status columns, a space, then the path. Renames read
    # "orig -> new"; the new name is the one that can collide with other work.
    path="${st#???}"
    case "$path" in
      *" -> "*) path="${path##* -> }" ;;
    esac
    path="${path#\"}"; path="${path%\"}"
    if [ -n "$path" ]; then
      printf '%s\n' "$path"
    fi
  done <<EOF
$(git -C "$worktree" status --porcelain 2>/dev/null || true)
EOF
}

# --- Do two newline-separated path lists share an entry? ---
# Exact whole-line match via sentinel newlines — zero-fork, and no partial-path
# false positives (`lib/queue.sh` must not match `lib/queue.sh.bak`).
_file_sets_overlap() {
  local a="$1" b="$2" line
  [ -n "$a" ] && [ -n "$b" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "${_QH_NL}${b}${_QH_NL}" in
      *"${_QH_NL}${line}${_QH_NL}"*) return 0 ;;
    esac
  done <<EOF
$a
EOF
  return 1
}

# --- Is candidate ($1 priority, $2 created_at) after stopper ($3, $4)? ---
# "After" means later in dequeue order, which sorts priority ASC then
# created_at ASC. So: a numerically greater priority (= lower priority), or the
# same priority and a later created_at.
_entry_is_after() {
  local c_pri="${1:-0}" c_created="$2" s_pri="${3:-0}" s_created="$4"
  case "$c_pri" in ''|*[!0-9]*) c_pri=0 ;; esac
  case "$s_pri" in ''|*[!0-9]*) s_pri=0 ;; esac
  if [ "$c_pri" -gt "$s_pri" ]; then return 0; fi
  if [ "$c_pri" -lt "$s_pri" ]; then return 1; fi
  # ISO 8601 timestamps compare correctly as strings.
  expr "$c_created" \> "$s_created" > /dev/null 2>&1
}

# --- Was branch $1 created from branch $2? ---
# Approximated as "$2 is an ancestor of $1". The approximation errs toward
# holding: a branch cut from main while the stopped branch is still at main also
# answers yes. Holding an unrelated entry costs a tick; releasing a dependent
# one costs a broken build.
_branch_descends_from() {
  local child="$1" parent="$2"
  [ -n "$child" ] && [ -n "$parent" ] || return 1
  [ "$child" != "$parent" ] || return 1
  local g="${REPO_ROOT:-.}"
  git -C "$g" rev-parse --verify --quiet "$child" > /dev/null 2>&1 || return 1
  git -C "$g" rev-parse --verify --quiet "$parent" > /dev/null 2>&1 || return 1
  git -C "$g" merge-base --is-ancestor "$parent" "$child" > /dev/null 2>&1
}

# --- May the loaded candidate be released from the stopped entry's hold? ---
# Reads the candidate from `_QE_*` and the stopped entry from `_QH_S_*`.
# Returns 0 to release, 1 to keep held. Every condition must pass.
_hold_release_ok() {
  # (d) not a follow-up of the stopped entry (t-0055 clause 14)
  if [ -n "${_QE_FOLLOW_UP_OF:-}" ] && [ "$_QE_FOLLOW_UP_OF" = "$_QH_S_ID" ]; then
    return 1
  fi
  # (c) not a sibling in the stopped entry's work order
  if [ -n "${_QE_WORK_ORDER_ID:-}" ] && [ "$_QE_WORK_ORDER_ID" = "$_QH_S_WO" ]; then
    return 1
  fi
  # (b) not the stopped entry's own branch, and not cut from it
  if [ -n "${_QE_BRANCH:-}" ] && [ "$_QE_BRANCH" = "$_QH_S_BRANCH" ]; then
    return 1
  fi
  if _branch_descends_from "${_QE_BRANCH:-}" "$_QH_S_BRANCH"; then
    return 1
  fi
  # (a) scope must be KNOWN and disjoint. An entry whose brief declares no
  # scope_files is never auto-released: there is nothing to prove it with.
  local c_files
  c_files=$(_parse_brief_scope_files "${_QE_BRIEF_PATH:-}")
  [ -n "$c_files" ] || return 1
  if _file_sets_overlap "$c_files" "$_QH_S_FILES"; then
    return 1
  fi
  return 0
}

# --- Session id of the record naming entry $1 (empty when none) ---
# Session records are keyed by session id, so the only route from an entry to
# its record is a scan. Used for the live worktree path and for `show --json`.
_session_id_for_entry() {
  local eid="$1" dir rec
  [ -n "$eid" ] || return 0
  type get_main_repo_root > /dev/null 2>&1 || return 0
  dir="$(get_main_repo_root)/.claude/.state/sessions"
  [ -d "$dir" ] || return 0
  for rec in "$dir"/*.yaml; do
    [ -f "$rec" ] || continue
    if grep -Fqx "entry_id: $eid" "$rec" 2>/dev/null; then
      basename "$rec" .yaml
      return 0
    fi
  done
}

# --- Is entry $1 stopping, stopped-by-flag or discarded? ---
# Flag existence is the signal (t-0055 clause 4), so this answers for a running
# entry whose child has not exited yet — the `stopping` half of clause 10.
_hold_entry_is_stopping() {
  local eid="$1" cdir
  type get_control_dir > /dev/null 2>&1 || return 1
  cdir=$(get_control_dir "$eid" 2>/dev/null) || return 1
  [ -n "$cdir" ] || return 1
  [ -f "$cdir/STOP" ] || [ -f "$cdir/FORCE" ] || [ -f "$cdir/DISCARD" ]
}

# --- Directory entry $1 was last launched in (empty when unknown) ---
# resume.yaml is written when the runner honours a stop and outlives the session
# record; the record is the source while the entry is still running.
_hold_entry_worktree() {
  local eid="$1" cdir wt="" sid
  if type get_control_dir > /dev/null 2>&1; then
    cdir=$(get_control_dir "$eid" 2>/dev/null) || cdir=""
    if [ -n "$cdir" ] && [ -f "$cdir/resume.yaml" ]; then
      wt=$(grep -E '^worktree:' "$cdir/resume.yaml" 2>/dev/null | head -1) || wt=""
      wt="${wt#worktree:}"
      wt="${wt# }"
      wt="${wt#\"}"; wt="${wt%\"}"
    fi
  fi
  if [ -z "$wt" ] && type session_record_get > /dev/null 2>&1; then
    sid=$(_session_id_for_entry "$eid")
    if [ -n "$sid" ]; then
      wt=$(session_record_get "$sid" "worktree" 2>/dev/null || true)
    fi
  fi
  printf '%s' "$wt"
}

# --- Recompute every held_by from current queue state (the dequeue tick) ---
# Two passes so the result cannot depend on directory iteration order: pass 1
# builds the id→holder map across all stoppers, pass 2 reconciles each approved
# entry against it. An entry held by more than one stopper records the first;
# the hold lifts only when no stopper claims it, so which one is recorded does
# not change behaviour, only the explanation shown to the operator.
queue_hold_evaluate() {
  local qdir
  qdir=$(_queue_dir)

  local stoppers="" f eid
  for f in "$qdir/stopped"/*.yaml; do
    [ -f "$f" ] || continue
    stoppers="${stoppers}${f}${_QH_NL}"
  done
  for f in "$qdir/running"/*.yaml; do
    [ -f "$f" ] || continue
    eid=$(basename "$f" .yaml)
    if _hold_entry_is_stopping "$eid"; then
      stoppers="${stoppers}${f}${_QH_NL}"
    fi
  done

  # Pass 1 — map of candidate_id<TAB>holder_id, one per line.
  local map="" sf cand changed
  while IFS= read -r sf; do
    [ -n "$sf" ] || continue
    _load_queue_entry "$sf" || continue
    _QH_S_ID="$_QE_ID"
    _QH_S_BRANCH="$_QE_BRANCH"
    _QH_S_WO="$_QE_WORK_ORDER_ID"
    _QH_S_PRI="${_QE_PRIORITY:-0}"
    _QH_S_CREATED="$_QE_CREATED_AT"
    _QH_S_FILES=$(_parse_brief_scope_files "$_QE_BRIEF_PATH")
    changed=$(_branch_changed_files "$_QE_BRANCH" "$(_hold_entry_worktree "$_QH_S_ID")")
    if [ -n "$changed" ]; then
      _QH_S_FILES="${_QH_S_FILES:+${_QH_S_FILES}${_QH_NL}}${changed}"
    fi

    for cand in "$qdir/approved"/*.yaml; do
      [ -f "$cand" ] || continue
      _load_queue_entry "$cand" || continue
      [ "$_QE_ID" != "$_QH_S_ID" ] || continue
      # Already claimed by an earlier stopper — no need to re-prove it.
      case "$map" in *"${_QH_NL}${_QE_ID}${_QH_TAB}"*) continue ;; esac
      # Opt-out (t-0055 clause 10 amendment): never held, never evaluated.
      [ "${_QE_INDEPENDENT:-false}" != "true" ] || continue
      _entry_is_after "${_QE_PRIORITY:-0}" "$_QE_CREATED_AT" "$_QH_S_PRI" "$_QH_S_CREATED" || continue
      if _hold_release_ok; then
        continue
      fi
      map="${map}${_QH_NL}${_QE_ID}${_QH_TAB}${_QH_S_ID}"
    done
  done <<EOF
$stoppers
EOF

  # Pass 2 — reconcile. Writes only where held_by actually changes, so a tick
  # with no stoppers is also the path that clears stale holds.
  local desired writes=0
  for cand in "$qdir/approved"/*.yaml; do
    [ -f "$cand" ] || continue
    _load_queue_entry "$cand" || continue
    desired=""
    case "$map" in
      *"${_QH_NL}${_QE_ID}${_QH_TAB}"*)
        desired="${map#*"${_QH_NL}${_QE_ID}${_QH_TAB}"}"
        desired="${desired%%"${_QH_NL}"*}"
        ;;
    esac
    if [ "${_QE_HELD_BY:-}" != "$desired" ]; then
      _QE_HELD_BY="$desired"
      _QE_UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      _write_queue_entry "$cand"
      writes=$(( writes + 1 ))
    fi
  done

  if [ "$writes" -gt 0 ]; then
    _rebuild_queue_index || true
  fi
  return 0
}

# --- Entry ids currently held by $1, one per line ---
queue_hold_holding() {
  local holder="$1" qdir f
  [ -n "$holder" ] || return 0
  qdir=$(_queue_dir)
  for f in "$qdir/approved"/*.yaml; do
    [ -f "$f" ] || continue
    _load_queue_entry "$f" || continue
    [ "${_QE_HELD_BY:-}" = "$holder" ] || continue
    printf '%s\n' "$_QE_ID"
  done
}

# --- Entry ids the hold evaluation let through $1, one per line ---
# Derived on read rather than stored: an approved entry queued after $1 whose
# held_by is empty has either proved itself unrelated or opted out, and in both
# cases it is back in running order. Deriving it means `released` can never
# disagree with `held_by`, and there is no second lock-shaped file to keep.
queue_hold_released() {
  local holder="$1" qdir f hfile
  [ -n "$holder" ] || return 0
  qdir=$(_queue_dir)
  type _find_entry_file > /dev/null 2>&1 || return 0
  hfile=$(_find_entry_file "$holder") || hfile=""
  [ -n "$hfile" ] || return 0
  _load_queue_entry "$hfile" || return 0
  local s_id="$_QE_ID" s_pri="${_QE_PRIORITY:-0}" s_created="$_QE_CREATED_AT"
  for f in "$qdir/approved"/*.yaml; do
    [ -f "$f" ] || continue
    _load_queue_entry "$f" || continue
    [ "$_QE_ID" != "$s_id" ] || continue
    [ -z "${_QE_HELD_BY:-}" ] || continue
    _entry_is_after "${_QE_PRIORITY:-0}" "$_QE_CREATED_AT" "$s_pri" "$s_created" || continue
    printf '%s\n' "$_QE_ID"
  done
}

# --- Clear every held_by pointing at $1 (t-0055 clause 9) ---
# Used by resume-entry and discard-entry. Outputs the released ids, one per
# line, so the caller can log and report what the resolution freed.
queue_release_holds() {
  local holder="$1" qdir f writes=0
  [ -n "$holder" ] || return 0
  qdir=$(_queue_dir)
  for f in "$qdir/approved"/*.yaml; do
    [ -f "$f" ] || continue
    _load_queue_entry "$f" || continue
    [ "${_QE_HELD_BY:-}" = "$holder" ] || continue
    _QE_HELD_BY=""
    _QE_UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    _write_queue_entry "$f"
    printf '%s\n' "$_QE_ID"
    writes=$(( writes + 1 ))
  done
  if [ "$writes" -gt 0 ]; then
    _rebuild_queue_index || true
  fi
  return 0
}

# --- Discard an entry (t-0055 clause 9) ---
# Moves a non-running entry to failed/ with `error_log: discarded-by-operator`.
# Deliberately narrow: the branch, the worktree and the transcript are left
# alone — discard marks the work abandoned and leaves the evidence in place.
# The worktree decision and the fate of the entries this one held belong to the
# caller (queue-cli.sh discard-entry), which is where t-0054's single-task vs
# group distinction and the escalation writer live.
# Arguments:
#   $1 — entry_id
#   $2 — reason (optional; defaults to the discarded-by-operator marker)
queue_discard() {
  local entry_id="$1"
  local reason="${2:-discarded-by-operator}"
  local qdir
  qdir=$(_queue_dir)

  if ! type _find_entry_file > /dev/null 2>&1; then
    echo "ERROR: queue_discard requires work-order-manager.sh to be sourced (_find_entry_file)" >&2
    return 1
  fi

  local src_file
  src_file=$(_find_entry_file "$entry_id")
  if [ -z "$src_file" ]; then
    echo "ERROR: Entry $entry_id not found" >&2
    return 1
  fi

  case "$src_file" in
    */failed/*)
      echo "WARNING: Entry $entry_id already in failed/ — idempotent no-op" >&2
      return 0
      ;;
  esac

  _load_queue_entry "$src_file"
  if [ "$_QE_STATUS" = "running" ]; then
    echo "ERROR: Entry $entry_id is still running — stop it before discarding" >&2
    return 1
  fi

  _QE_STATUS="failed"
  _QE_ERROR_LOG="$reason"
  _QE_HELD_BY=""
  _QE_COMPLETED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _QE_UPDATED_AT="$_QE_COMPLETED_AT"
  # Preserve the last prompt for diagnostic review, as queue_fail_terminal does.
  if [ -n "$_QE_PROMPT" ]; then
    _QE_LAST_PROMPT="$_QE_PROMPT"
  fi

  _write_queue_entry "$qdir/failed/${entry_id}.yaml"
  rm -f "$src_file"
  _rebuild_queue_index || true
}

# ============================================================
# Follow-ups (t-0055 clause 14)
# ============================================================
#
# A follow-up is an ordinary queue entry carrying `follow_up_of: <parent-id>`.
# The link is a single forward pointer on the child; the parent owns no list.
# Two things are derived from the pointer rather than stored: the reverse
# direction (queue_followups_of, a scan) and the branch the follow-up runs on
# (_followup_resolve_branch, evaluated at dequeue). Both are derived for the
# same reason — the answer changes after the entry is created, so storing it
# would mean storing something that can go stale.

# --- Entries that follow up on $1, one `id<TAB>status` line each ---
# A scan, not a back-pointer. Clause 14 rejects a parent-side list because it
# would have to be kept in sync by whoever creates the child; this cannot
# disagree with `follow_up_of` because it reads nothing else.
# Clobbers _QE_*.
queue_followups_of() {
  local pid="$1" qdir st f
  [ -n "$pid" ] || return 0
  qdir=$(_queue_dir)
  for st in pending-review approved running completed failed review blocked stopped; do
    for f in "$qdir/$st"/*.yaml; do
      [ -f "$f" ] || continue
      _load_queue_entry "$f" || continue
      [ "${_QE_FOLLOW_UP_OF:-}" = "$pid" ] || continue
      printf '%s%s%s\n' "$_QE_ID" "$_QH_TAB" "$_QE_STATUS"
    done
  done
}

# --- Status of entry $1, read from the directory it sits in ---
# `missing` when no entry file exists anywhere; `unknown` when _find_entry_file
# is not sourced. The directory IS the status (_transition moves the file and
# rewrites the field together), so this needs no parse and clobbers nothing —
# which matters, because queue_dequeue calls it with a candidate loaded.
_followup_parent_state() {
  local pid="$1" pfile
  if [ -z "$pid" ]; then printf 'missing'; return 0; fi
  if ! type _find_entry_file > /dev/null 2>&1; then printf 'unknown'; return 0; fi
  pfile=$(_find_entry_file "$pid") || pfile=""
  if [ -z "$pfile" ]; then printf 'missing'; return 0; fi
  pfile="${pfile%/*}"
  printf '%s' "${pfile##*/}"
}

# --- Branch-name component from a branch name, brief path or id ---
# Keeps [a-z0-9], folds everything else to `-`, collapses runs and trims, so
# the result is safe in a git ref however odd the input was.
_followup_slug() {
  local raw="$1" out="" i=0 len ch
  raw="${raw##*/}"      # branch leaf, or brief basename
  raw="${raw%.md}"
  raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  len=${#raw}
  while [ "$i" -lt "$len" ]; do
    ch="${raw:$i:1}"
    case "$ch" in
      [a-z0-9]) out="${out}${ch}" ;;
      *)        out="${out}-" ;;
    esac
    i=$(( i + 1 ))
  done
  while case "$out" in *--*) true ;; *) false ;; esac; do
    out="${out%%--*}-${out#*--}"
  done
  while case "$out" in -*) true ;; *) false ;; esac; do out="${out#-}"; done
  while case "$out" in *-) true ;; *) false ;; esac; do out="${out%-}"; done
  [ -n "$out" ] || out="entry"
  printf '%s' "$out"
}

# --- Branch a follow-up of $1 should run on (its $2'th follow-up) ---
# The whole branch/order table in the brief collapses to one question: is the
# parent's branch still a live line of work? If it exists and is not already
# an ancestor of main, the follow-up continues it — that covers a parent that
# is queued, running, stopped, or completed-but-unmerged, all of which still
# have commits only reachable from that branch. Otherwise the branch is merged
# or sealed and there is nothing to continue, so the follow-up gets its own
# branch cut from current main.
#
# Errs toward continuing the parent's branch: if main cannot be resolved,
# `--is-ancestor` fails and we cannot prove the work landed. Continuing a
# branch that turns out to be merged costs an empty rebase; starting a new
# branch from main when the parent's work has NOT landed costs the follow-up
# its entire premise.
#
# Clobbers _QE_*.
_followup_resolve_branch() {
  local pid="$1" n="${2:-1}"
  local pfile="" pbranch="" slug g="${REPO_ROOT:-.}"

  if type _find_entry_file > /dev/null 2>&1; then
    pfile=$(_find_entry_file "$pid") || pfile=""
  fi
  if [ -n "$pfile" ] && _load_queue_entry "$pfile"; then
    pbranch="${_QE_BRANCH:-}"
    slug=$(_followup_slug "${pbranch:-${_QE_BRIEF_PATH:-$pid}}")
  else
    slug=$(_followup_slug "$pid")
  fi

  if [ -n "$pbranch" ] \
     && git -C "$g" rev-parse --verify --quiet "$pbranch" > /dev/null 2>&1 \
     && ! git -C "$g" merge-base --is-ancestor "$pbranch" "$_QH_MAIN_REF" > /dev/null 2>&1; then
    printf '%s' "$pbranch"
    return 0
  fi

  printf 'follow-up/%s-%s' "$slug" "$n"
}

# --- Dequeue the highest-priority approved entry ---
# Picks the entry with the lowest priority value from approved/ (priority ASC),
# breaking ties by earliest created_at (created_at ASC).
# Task group entries respect brief sequencing: Brief N waits until all
# briefs with lower sequence numbers have left approved/ and running/.
# Moves the selected entry to running/ and outputs the entry file path.
# Returns 1 if no approved entries exist (or all are deferred by sequencing).
# Note: _QE_* module variables are indeterminate after return (inner calls to
# _load_queue_entry during sibling scans overwrite them). Callers needing the
# dequeued entry's fields should re-load from the returned file path.
queue_dequeue() {
  local qdir
  qdir=$(_queue_dir)

  # Re-evaluate holds on every tick (t-0055 clause 11). The stopped branch's
  # changed-file set grows while it is stopped, so an entry released on one
  # tick can legitimately be held on the next. Fail-soft: a hold-evaluation
  # error must not stall the queue.
  queue_hold_evaluate || true

  # Collect approved entries into a temp file for sort-based dequeue.
  # Format per line: <zero-padded-priority>_<created_at><TAB><file_path>
  # Sort contract: priority ASC first, then created_at ASC as tiebreaker.
  # Avoids eval on queue-entry data; uses the temp-file sort idiom (security hardening).
  # ISO-8601 validation on _QE_CREATED_AT guards against malformed sort keys.
  local _dq_sort_file
  _dq_sort_file=$(mktemp)
  local f _pri
  for f in "$qdir/approved"/*.yaml; do
    [ -f "$f" ] || continue
    _load_queue_entry "$f"
    _pri="${_QE_PRIORITY:-0}"
    # ISO-8601 validation: reject entries with malformed created_at timestamps
    if ! printf '%s' "$_QE_CREATED_AT" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}'; then
      echo "WARNING: queue entry '$f' has invalid created_at '$_QE_CREATED_AT' — skipped in sort" >&2
      continue
    fi
    printf '%05d_%s\t%s\n' "$_pri" "$_QE_CREATED_AT" "$f"
  done | sort > "$_dq_sort_file"

  # Iterate sorted candidates (ASC), skip any blocked by task group sequencing.
  local _dq_key cand_file my_seq entry_id
  local _dq_fu_of _dq_fu_state _dq_fu_n _dq_fu_branch
  while IFS=$'\t' read -r _dq_key cand_file; do
    [ -f "$cand_file" ] || continue
    _load_queue_entry "$cand_file"

    # Held behind a stopping/stopped/discarded entry (t-0055 clause 10).
    # held_by is derived state, written by queue_hold_evaluate above.
    if [ -n "${_QE_HELD_BY:-}" ]; then
      continue
    fi

    # A follow-up never overtakes its parent (t-0055 clause 14). This is a
    # separate obligation from the hold above, which only fires when something
    # was actually STOPPED: a parent that is merely queued or running stops
    # nothing, yet running its follow-up first would build on work that does
    # not exist. `completed` is the only state that releases a follow-up;
    # `missing` releases it too, so a pruned parent cannot strand it forever.
    # Every other state — including `failed` and `unknown` — holds, on the
    # same reasoning as _hold_release_ok: a wasted tick is cheaper than a
    # session built on a premise that never landed.
    _dq_fu_of="${_QE_FOLLOW_UP_OF:-}"
    if [ -n "$_dq_fu_of" ]; then
      _dq_fu_state=$(_followup_parent_state "$_dq_fu_of")
      case "$_dq_fu_state" in
        completed|missing) ;;
        *) continue ;;
      esac
    fi

    # Task group sequencing check (Decision 0017)
    # Brief 1 is always eligible (no predecessor). Brief N>1 waits for all
    # lower-sequence siblings to leave approved/ and running/.
    if [ "$_QE_SESSION_TYPE" = "taskgroup" ] && [ -n "$_QE_WORK_ORDER_ID" ]; then
      my_seq=$(_parse_brief_sequence "$_QE_BRIEF_PATH")
      if [ -n "$my_seq" ] && [ "$my_seq" -gt 1 ]; then
        if _has_prior_taskgroup_entry "$_QE_WORK_ORDER_ID" "$my_seq" "$cand_file"; then
          continue  # Skip — prior brief still approved or running
        fi
      fi
    fi

    # This entry is eligible
    entry_id=$(basename "$cand_file" .yaml)

    # Resolve a follow-up's branch now, at the last moment before it runs, and
    # persist it. `follow-up-entry` deliberately leaves `branch` empty because
    # the parent's branch may be live when the follow-up is queued and merged
    # by the time it is dequeued. Writing the answer back means `show` reports
    # the branch the session actually used, and the runner reads `branch` the
    # same way for every entry — no follow-up special case downstream.
    #
    # `<n>` comes from the brief filename `followup-<parent-id>-<n>.md` that
    # follow-up-entry wrote, so the branch name and the brief agree. Recounting
    # here would drift if a sibling follow-up were pruned in between.
    if [ -n "$_dq_fu_of" ] && [ -z "${_QE_BRANCH:-}" ]; then
      _dq_fu_n="${_QE_BRIEF_PATH##*/}"
      _dq_fu_n="${_dq_fu_n%.md}"
      _dq_fu_n="${_dq_fu_n##*-}"
      case "$_dq_fu_n" in ''|*[!0-9]*) _dq_fu_n=1 ;; esac
      _dq_fu_branch=$(_followup_resolve_branch "$_dq_fu_of" "$_dq_fu_n")
      if [ -n "$_dq_fu_branch" ] && _load_queue_entry "$cand_file"; then
        _QE_BRANCH="$_dq_fu_branch"
        _QE_UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        _write_queue_entry "$cand_file"
      fi
    fi

    _transition "$entry_id" "approved" "running"
    printf '%s' "$qdir/running/${entry_id}.yaml"
    rm -f "$_dq_sort_file"
    return 0
  done < "$_dq_sort_file"

  rm -f "$_dq_sort_file"
  return 1
}

# --- Complete a running entry ---
# Moves from running to completed with completed_at timestamp.
# Arguments:
#   $1 — entry_id
#   $2 — note (optional, stored in error_log; omitted → error_log is left as loaded)
queue_complete() {
  local entry_id="$1"
  local note="${2:-}"
  local qdir
  qdir=$(_queue_dir)
  local src_file="$qdir/running/${entry_id}.yaml"

  if [ ! -f "$src_file" ]; then
    # Idempotency guard: if already in completed/, treat as success
    if [ -f "$qdir/completed/${entry_id}.yaml" ]; then
      echo "WARNING: Entry $entry_id already in completed/ — idempotent no-op" >&2
      return 0
    fi
    echo "ERROR: Entry $entry_id not found in running/" >&2
    return 1
  fi

  _load_queue_entry "$src_file"
  _QE_STATUS="completed"
  [ -z "$note" ] || _QE_ERROR_LOG="$note"
  _QE_COMPLETED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _QE_UPDATED_AT="$_QE_COMPLETED_AT"

  _write_queue_entry "$qdir/completed/${entry_id}.yaml"
  rm -f "$src_file"
  _rebuild_queue_index || true
}

# --- Fail a running entry ---
# Increments retry_count. If retries exhausted, moves to failed/.
# Otherwise moves back to approved/ for retry.
# Arguments:
#   $1 — entry_id
#   $2 — error_detail (optional, appended to error_log for diagnostics)
queue_fail() {
  local entry_id="$1"
  local error_detail="${2:-}"
  local qdir
  qdir=$(_queue_dir)
  local src_file="$qdir/running/${entry_id}.yaml"

  if [ ! -f "$src_file" ]; then
    # Idempotency guard: if already in failed/ or completed/, treat as success
    if [ -f "$qdir/failed/${entry_id}.yaml" ] || [ -f "$qdir/completed/${entry_id}.yaml" ]; then
      echo "WARNING: Entry $entry_id already transitioned (failed/ or completed/) — idempotent no-op" >&2
      return 0
    fi
    # Also check approved/ (retry path) — entry was already re-queued
    if [ -f "$qdir/approved/${entry_id}.yaml" ]; then
      echo "WARNING: Entry $entry_id already in approved/ (retry) — idempotent no-op" >&2
      return 0
    fi
    echo "ERROR: Entry $entry_id not found in running/" >&2
    return 1
  fi

  _load_queue_entry "$src_file"
  _QE_RETRY_COUNT=$(( ${_QE_RETRY_COUNT:-0} + 1 ))
  _QE_UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [ -n "$error_detail" ]; then
    _QE_ERROR_LOG="$error_detail"
  fi

  if [ "$_QE_RETRY_COUNT" -ge "${_QE_MAX_RETRIES:-3}" ]; then
    # Retries exhausted — move to failed
    _QE_STATUS="failed"
    _QE_COMPLETED_AT="$_QE_UPDATED_AT"
    # Preserve last prompt for diagnostic review
    if [ -n "$_QE_PROMPT" ]; then
      _QE_LAST_PROMPT="$_QE_PROMPT"
    fi
    _write_queue_entry "$qdir/failed/${entry_id}.yaml"
  else
    # Retry — move back to approved
    _QE_STATUS="approved"
    # Preserve last prompt for diagnostic review before clearing active prompt
    if [ -n "$_QE_PROMPT" ]; then
      _QE_LAST_PROMPT="$_QE_PROMPT"
    fi
    _QE_PROMPT=""
    _write_queue_entry "$qdir/approved/${entry_id}.yaml"
  fi

  rm -f "$src_file"
  _rebuild_queue_index || true
}

# --- Fail a running entry terminally (no retry) ---
# Moves directly from running to failed/ without incrementing retry_count.
# Used for infrastructure failures (e.g., empty outcome) that should not be retried.
# Arguments:
#   $1 — entry_id
#   $2 — reason (optional, stored in error_log field)
queue_fail_terminal() {
  local entry_id="$1"
  local reason="${2:-}"
  local qdir
  qdir=$(_queue_dir)
  local src_file="$qdir/running/${entry_id}.yaml"

  if [ ! -f "$src_file" ]; then
    # Idempotency guard: if already in failed/, completed/, or approved/ (concurrent retry), treat as success
    if [ -f "$qdir/failed/${entry_id}.yaml" ] || [ -f "$qdir/completed/${entry_id}.yaml" ]; then
      echo "WARNING: Entry $entry_id already transitioned (failed/ or completed/) — idempotent no-op" >&2
      return 0
    fi
    if [ -f "$qdir/approved/${entry_id}.yaml" ]; then
      echo "WARNING: Entry $entry_id already in approved/ (concurrent retry) — idempotent no-op" >&2
      return 0
    fi
    echo "ERROR: Entry $entry_id not found in running/" >&2
    return 1
  fi

  _load_queue_entry "$src_file"
  _QE_STATUS="failed"
  _QE_COMPLETED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _QE_UPDATED_AT="$_QE_COMPLETED_AT"
  if [ -n "$reason" ]; then
    _QE_ERROR_LOG="$reason"
  fi
  # Preserve last prompt for diagnostic review
  if [ -n "$_QE_PROMPT" ]; then
    _QE_LAST_PROMPT="$_QE_PROMPT"
  fi

  _write_queue_entry "$qdir/failed/${entry_id}.yaml"
  rm -f "$src_file"
  _rebuild_queue_index || true
}

# --- Route an incomplete-deliverable entry to review ---
# Moves from running to review/ and writes an escalation file noting incomplete criteria.
# Called by runner.sh for outcome review:incomplete-deliverable.
# Arguments:
#   $1 — entry_id
#   $2 — completeness_detail (optional; e.g., "3/5 criteria met")
#   $3 — error_log note (optional; passed through to queue_escalate)
queue_incomplete() {
  local entry_id="$1"
  local completeness_detail="${2:-}"

  # Delegate queue transition to queue_escalate (running → review/)
  queue_escalate "$entry_id" "${3:-}" || return $?

  # Write escalation file so operator can see which criteria were incomplete
  local esc_dir="$AUTOMATION_DIR/escalations"
  mkdir -p "$esc_dir" 2>/dev/null || true
  local esc_id="esc-${entry_id}-incomplete-$(date +%Y%m%d-%H%M%S)"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  {
    printf 'escalation:\n'
    printf '  id: "%s"\n' "$esc_id"
    printf '  queue_entry_id: "%s"\n' "$entry_id"
    printf '  type: "incomplete-deliverable"\n'
    printf '  severity: "review-required"\n'
    printf '  message: "Session completed with incomplete deliverables — completeness veto triggered"\n'
    printf '  context: "%s"\n' "${completeness_detail:-COMPLETENESS_GATE: NEEDS_WORK}"
    printf '  created_at: "%s"\n' "$timestamp"
    printf '  resolved: false\n'
    printf '  resolution: ""\n'
  } > "$esc_dir/${esc_id}.yaml" 2>/dev/null || true
}

# --- Escalate a running entry ---
# Moves from running to review/ for operator attention.
# Arguments:
#   $1 — entry_id
#   $2 — reason (optional, stored in error_log so `queue-cli.sh show` surfaces it;
#        omitted → error_log is left as loaded)
queue_escalate() {
  local entry_id="$1"
  local reason="${2:-}"
  local qdir
  qdir=$(_queue_dir)
  local src_file="$qdir/running/${entry_id}.yaml"

  if [ ! -f "$src_file" ]; then
    # Idempotency guard: if already in review/, treat as success
    if [ -f "$qdir/review/${entry_id}.yaml" ]; then
      echo "WARNING: Entry $entry_id already in review/ — idempotent no-op" >&2
      return 0
    fi
    echo "ERROR: Entry $entry_id not found in running/" >&2
    return 1
  fi

  _load_queue_entry "$src_file"
  _QE_STATUS="review"
  [ -z "$reason" ] || _QE_ERROR_LOG="$reason"
  _QE_COMPLETED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _QE_UPDATED_AT="$_QE_COMPLETED_AT"

  _write_queue_entry "$qdir/review/${entry_id}.yaml"
  rm -f "$src_file"
  _rebuild_queue_index || true
}

# --- Repair directory/status mismatches ---
# Scans every status directory. If an entry's YAML `status:` field
# does not match the directory it lives in, rewrite with the correct status.
# Arguments: none (operates on _queue_dir)
# Output: number of repairs on stdout
_repair_status_mismatches() {
  local qdir
  qdir=$(_queue_dir)
  local repaired=0

  local status
  for status in pending-review approved running completed failed review blocked stopped; do
    local dir="$qdir/$status"
    [ -d "$dir" ] || continue
    local f
    for f in "$dir"/*.yaml; do
      [ -f "$f" ] || continue
      _load_queue_entry "$f"
      if [ "$_QE_STATUS" != "$status" ]; then
        _QE_STATUS="$status"
        _QE_UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        _write_queue_entry "$f"
        repaired=$((repaired + 1))
      fi
    done
  done

  if [ "$repaired" -gt 0 ]; then
    _rebuild_queue_index || true
  fi
  printf '%s' "$repaired"
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
    # Idempotency guard: if already in blocked/, treat as success
    if [ -f "$qdir/blocked/${entry_id}.yaml" ]; then
      echo "WARNING: Entry $entry_id already in blocked/ — idempotent no-op" >&2
      return 0
    fi
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
  _rebuild_queue_index || true
}

# --- Block a DEFERRED entry (approved/ -> blocked/) ---
# queue_block only accepts running/, but a deferred entry has already been moved
# back to approved/ by queue_defer. This is the approved/ counterpart, used when
# a work order cannot progress: the entry (and its approved siblings) leave the
# dequeue pool so they stop starving unrelated entries. `queue-cli.sh reopen-wo`
# moves blocked siblings back to approved/.
# Arguments:
#   $1 — entry_id
#   $2 — reason (stored in error_log field)
# Returns: 0 on success (or already blocked), 1 if not found in approved/
queue_block_deferred() {
  local entry_id="$1"
  local reason="${2:-}"
  local qdir
  qdir=$(_queue_dir)
  local src_file="$qdir/approved/${entry_id}.yaml"

  if [ ! -f "$src_file" ]; then
    if [ -f "$qdir/blocked/${entry_id}.yaml" ]; then
      return 0
    fi
    echo "ERROR: Entry $entry_id not found in approved/" >&2
    return 1
  fi

  _load_queue_entry "$src_file"
  _QE_STATUS="blocked"
  _QE_ERROR_LOG="$reason"
  _QE_COMPLETED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _QE_UPDATED_AT="$_QE_COMPLETED_AT"

  _write_queue_entry "$qdir/blocked/${entry_id}.yaml"
  rm -f "$src_file"
  _rebuild_queue_index || true
}

# --- Defer a running entry (work-order pause) ---
# Moves from running back to approved/ WITHOUT incrementing retry_count.
# Used when a sibling entry in the same work order is in review/failed/blocked,
# and (in "nocount" mode) when HALT / FORCE-HALT appears after dequeue.
# The entry resumes automatically when the work order is reopened.
# Writes/increments a file-based defer count that survives daemon restarts.
# Arguments:
#   $1 — entry_id
#   $2 — reason (optional, stored in error_log field)
#   $3 — "nocount" (optional): return the entry WITHOUT consuming a deferral
#        cycle. The counter feeds max_deferral_cycles, which blocks a work order
#        that cannot progress; a HALT-return is not the entry's fault and must not
#        move it toward that cap. Prints 0 in this mode (nothing reads it).
# Output: new defer count on stdout
queue_defer() {
  local entry_id="$1"
  local reason="${2:-}"
  local count_mode="${3:-}"
  local qdir
  qdir=$(_queue_dir)
  local src_file="$qdir/running/${entry_id}.yaml"

  if [ ! -f "$src_file" ]; then
    # Idempotency guard: if already in approved/, treat as success
    if [ -f "$qdir/approved/${entry_id}.yaml" ]; then
      echo "WARNING: Entry $entry_id already in approved/ — idempotent no-op" >&2
      printf '0'
      return 0
    fi
    echo "ERROR: Entry $entry_id not found in running/" >&2
    return 1
  fi

  _load_queue_entry "$src_file"
  _QE_STATUS="approved"
  _QE_UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _QE_COMPLETED_AT=""  # Clear terminal timestamp — entry is returning to non-terminal state
  _QE_PROMPT=""  # Clear assembled prompt — regenerated on next dequeue
  if [ -n "$reason" ]; then
    # Reuses error_log (only free-text field in schema) for deferral reason
    _QE_ERROR_LOG="$reason"
  fi

  _write_queue_entry "$qdir/approved/${entry_id}.yaml"
  rm -f "$src_file"
  _rebuild_queue_index || true

  if [ "$count_mode" = "nocount" ]; then
    printf '0'
    return 0
  fi

  # Increment file-based defer count (survives daemon restarts)
  local defer_count_file="$qdir/.defer-count-${entry_id}"
  local current_count=0
  if [ -f "$defer_count_file" ]; then
    current_count=$(cat "$defer_count_file" 2>/dev/null || echo "0")
    # Sanitize: ensure numeric
    case "$current_count" in
      *[!0-9]*) current_count=0 ;;
    esac
  fi
  current_count=$((current_count + 1))
  printf '%s' "$current_count" > "$defer_count_file"
  printf '%s' "$current_count"
}

# --- Stop a running entry (operator stop, t-0055) ---
# Moves from running to stopped/ WITHOUT incrementing retry_count — an operator
# stop is not a failure. The worktree, the group lock and the Claude session all
# survive; `queue_resume` puts the entry back in approved/.
# Arguments:
#   $1 — entry_id
#   $2 — stopped_mode: graceful | forced
queue_stop() {
  local entry_id="$1"
  local mode="${2:-graceful}"
  local qdir
  qdir=$(_queue_dir)
  local src_file="$qdir/running/${entry_id}.yaml"

  if [ ! -f "$src_file" ]; then
    # Idempotency guard: if already in stopped/, treat as success
    if [ -f "$qdir/stopped/${entry_id}.yaml" ]; then
      echo "WARNING: Entry $entry_id already in stopped/ — idempotent no-op" >&2
      return 0
    fi
    echo "ERROR: Entry $entry_id not found in running/" >&2
    return 1
  fi

  _load_queue_entry "$src_file"
  _QE_STATUS="stopped"
  _QE_STOPPED_MODE="$mode"
  _QE_RESUME="false"
  _QE_UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # No completed_at — a stopped entry is paused, not finished.
  _QE_PROMPT=""  # Clear assembled prompt — the resume message replaces it

  _write_queue_entry "$qdir/stopped/${entry_id}.yaml"
  rm -f "$src_file"
  _rebuild_queue_index || true
}

# --- Resume a stopped entry (operator resume, t-0055) ---
# Moves from stopped/ back to approved/ with resume: true so the runner
# continues the recorded Claude session instead of launching a fresh one.
# Priority is left untouched — the entry's created_at predates anything queued
# since, so at equal priority it already sorts to the front of approved/.
# Arguments:
#   $1 — entry_id
queue_resume() {
  local entry_id="$1"
  local qdir
  qdir=$(_queue_dir)
  local src_file="$qdir/stopped/${entry_id}.yaml"

  if [ ! -f "$src_file" ]; then
    # Idempotency guard: if already in approved/, treat as success
    if [ -f "$qdir/approved/${entry_id}.yaml" ]; then
      echo "WARNING: Entry $entry_id already in approved/ — idempotent no-op" >&2
      return 0
    fi
    echo "ERROR: Entry $entry_id not found in stopped/" >&2
    return 1
  fi

  _load_queue_entry "$src_file"
  _QE_STATUS="approved"
  _QE_RESUME="true"
  _QE_UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _QE_COMPLETED_AT=""
  _QE_PROMPT=""  # Cleared at stop; the runner assembles the resume message
  # stopped_mode is deliberately preserved — the runner reads it to decide
  # whether the resume message warns about a force-stopped working tree.

  _write_queue_entry "$qdir/approved/${entry_id}.yaml"
  rm -f "$src_file"
  _rebuild_queue_index || true
}

# --- Edit a queue entry field ---
# Updates a single field on a non-running entry.
# Requires: _find_entry_file (from work-order-manager.sh)
# Arguments:
#   $1 — entry_id
#   $2 — field name (from whitelist)
#   $3 — new value
# Returns: 0 on success, 1 on error
# Caller holds queue lock.
# Set _QE_FORCE_EDIT=true to suppress review/blocked warnings.
queue_edit() {
  local entry_id="$1"
  local field="$2"
  local value="$3"

  if ! type _find_entry_file > /dev/null 2>&1; then
    echo "ERROR: queue_edit requires work-order-manager.sh to be sourced (_find_entry_file)" >&2
    return 1
  fi

  # Editable fields whitelist
  case "$field" in
    brief_path|session_type|branch|auto_mode|solo_mode|push_on_complete|max_retries|priority|\
    independent|project|milestone.name|milestone.index|milestone.total) ;;
    *)
      echo "ERROR: Field '$field' is not editable (allowed: brief_path, session_type, branch, auto_mode, solo_mode, push_on_complete, max_retries, priority, independent, project, milestone.name, milestone.index, milestone.total)" >&2
      return 1
      ;;
  esac

  local entry_file
  entry_file=$(_find_entry_file "$entry_id")
  if [ -z "$entry_file" ]; then
    echo "ERROR: Entry $entry_id not found" >&2
    return 1
  fi

  _load_queue_entry "$entry_file"

  # Running entries are immutable
  if [ "$_QE_STATUS" = "running" ]; then
    echo "ERROR: Cannot edit running entry $entry_id" >&2
    return 1
  fi

  # Warn on review/blocked unless force-edit
  if [ "${_QE_FORCE_EDIT:-}" != "true" ]; then
    case "$_QE_STATUS" in
      review|blocked)
        echo "WARNING: Entry $entry_id is in '$_QE_STATUS' status — editing may discard operator context. Set _QE_FORCE_EDIT=true to suppress." >&2
        ;;
    esac
  fi

  # Update the field
  case "$field" in
    brief_path)        _QE_BRIEF_PATH="$value" ;;
    session_type)      _QE_SESSION_TYPE="$value" ;;
    branch)            _QE_BRANCH="$value" ;;
    auto_mode)         _QE_AUTO_MODE="$value" ;;
    solo_mode)         _QE_SOLO_MODE="$value" ;;
    push_on_complete)  _QE_PUSH_ON_COMPLETE="$value" ;;
    max_retries)       _QE_MAX_RETRIES="$value" ;;
    priority)
      # Validate numeric (non-negative integer)
      case "$value" in
        ''|*[!0-9]*) echo "ERROR: priority must be a non-negative integer" >&2; return 1 ;;
      esac
      _QE_PRIORITY="$value" ;;
    independent)
      # Hold opt-out (t-0055 clause 10) — boolean only. held_by is deliberately
      # NOT editable: it is derived state owned by the dequeue tick.
      case "$value" in
        true|false) ;;
        *) echo "ERROR: independent must be true or false" >&2; return 1 ;;
      esac
      _QE_INDEPENDENT="$value" ;;
    project)           _QE_PROJECT="$value" ;;
    milestone.name)    _QE_MILESTONE_NAME="$value" ;;
    milestone.index)
      case "$value" in
        ''|*[!0-9]*) echo "ERROR: milestone.index must be a non-negative integer" >&2; return 1 ;;
      esac
      _QE_MILESTONE_INDEX="$value" ;;
    milestone.total)
      case "$value" in
        ''|*[!0-9]*) echo "ERROR: milestone.total must be a non-negative integer" >&2; return 1 ;;
      esac
      _QE_MILESTONE_TOTAL="$value" ;;
  esac

  _QE_UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _write_queue_entry "$entry_file"
  _rebuild_queue_index || true
}

# --- Remove a queue entry ---
# Deletes an entry and detaches it from its work order.
# If the work order has no remaining children, removes the work order too.
# Requires: _find_entry_file (from work-order-manager.sh)
# Arguments:
#   $1 — entry_id
# Returns: 0 on success, 1 on error
# Caller holds queue lock.
queue_remove() {
  local entry_id="$1"

  if ! type _find_entry_file > /dev/null 2>&1; then
    echo "ERROR: queue_remove requires work-order-manager.sh to be sourced (_find_entry_file)" >&2
    return 1
  fi

  local entry_file
  entry_file=$(_find_entry_file "$entry_id")
  if [ -z "$entry_file" ]; then
    echo "ERROR: Entry $entry_id not found" >&2
    return 1
  fi

  _load_queue_entry "$entry_file"

  # Running entries are immutable
  if [ "$_QE_STATUS" = "running" ]; then
    echo "ERROR: Cannot remove running entry $entry_id" >&2
    return 1
  fi

  # Capture work_order_id before deletion
  local wo_id="$_QE_WORK_ORDER_ID"

  # Remove entry file
  rm -f "$entry_file"

  # Detach from work order
  if [ -n "$wo_id" ] && type wo_remove_child > /dev/null 2>&1; then
    wo_remove_child "$wo_id" "$entry_id" 2>/dev/null || true
  fi

  _rebuild_queue_index || true
}
