#!/usr/bin/env bash
# Review log — NDJSON event stream for work order and entry lifecycle events.
# Sourced by runner.sh. NOT executed standalone.
# Decision 0017 — Operator Automation Layer.
#
# Daily log files: queue/review-log-YYYY-MM-DD.jsonl
# Each line is a JSON object per review-log-entry.yaml schema.
# Single-daemon assumption: seq counter is safe without locking.
#
# Depends on (sourced by runner.sh before this file):
#   runner.sh sets AUTOMATION_DIR, REPO_ROOT, CONFIG_FILE
#   queue-manager.sh — _queue_dir, _parse_config_field
#   cleanup.sh — _file_age_days

set -euo pipefail

# --- Resolve today's log file path ---
_review_log_file() {
  local today
  today=$(date -u +%Y-%m-%d)
  printf '%s/review-log-%s.jsonl' "$(_queue_dir)" "$today"
}

# --- JSON string escape (zero-fork) ---
# Escapes backslash, double quote, and control characters for JSON safety.
# Arguments:
#   $1 — raw string
# Output: escaped string on stdout
_json_escape() {
  local raw="$1"
  # Escape backslash first, then double quotes, then control characters
  raw="${raw//\\/\\\\}"
  raw="${raw//\"/\\\"}"
  raw="${raw//$'\n'/\\n}"
  raw="${raw//$'\t'/\\t}"
  raw="${raw//$'\r'/\\r}"
  printf '%s' "$raw"
}

# --- Read last seq from today's log file ---
# Returns 0 if file is empty or missing.
# Output: integer on stdout
_last_seq() {
  local log_file="$1"
  if [ ! -f "$log_file" ] || [ ! -s "$log_file" ]; then
    echo "0"
    return
  fi
  # Extract seq from last line — look for "seq":N pattern
  local last_line
  last_line=$(tail -1 "$log_file")
  local seq_val
  seq_val=$(printf '%s' "$last_line" \
    | grep -oE '"seq":[0-9]+' \
    | grep -oE '[0-9]+' \
    | head -1 || true)
  echo "${seq_val:-0}"
}

# ============================================================
# Public API
# ============================================================

# --- Append an event to the review log ---
# Writes a single NDJSON line to today's log file.
# Arguments:
#   $1 — event (entry-completed | entry-escalated | entry-failed |
#                work-order-opened | work-order-completed | work-order-escalated)
#   $2 — work_order_id
#   $3 — entry_id (empty string for work-order-level events)
#   $4 — summary (human-readable description)
#   $5 — detail_json (optional, pre-formatted JSON object string; default "{}")
review_log_append() {
  local event="$1"
  local work_order_id="$2"
  local entry_id="${3:-}"
  local summary="$4"
  local detail_json="${5:-{}}"

  local log_file
  log_file=$(_review_log_file)

  # Ensure queue directory exists
  mkdir -p "$(dirname "$log_file")" 2>/dev/null || true

  # Compute next seq
  local last_seq
  last_seq=$(_last_seq "$log_file")
  local seq=$((last_seq + 1))

  # Timestamp
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Escape string fields for JSON safety
  local esc_summary esc_wo_id esc_entry_id esc_event
  esc_summary=$(_json_escape "$summary")
  esc_wo_id=$(_json_escape "$work_order_id")
  esc_entry_id=$(_json_escape "$entry_id")
  esc_event=$(_json_escape "$event")

  # Build and append JSON line (append-only — safe for single daemon)
  printf '{"seq":%d,"timestamp":"%s","event":"%s","work_order_id":"%s","entry_id":"%s","summary":"%s","detail":%s}\n' \
    "$seq" "$timestamp" "$esc_event" "$esc_wo_id" "$esc_entry_id" "$esc_summary" "$detail_json" \
    >> "$log_file"
}

# --- Compact review log files older than retention days ---
# Deletes review-log-*.jsonl files beyond the configured retention period.
# Arguments:
#   $1 — max_days (optional, default from config review_log_days)
# Output: count of deleted files on stdout, summary to stderr
review_log_compact() {
  local max_days="${1:-}"
  if [ -z "$max_days" ]; then
    max_days=$(_parse_config_field "retention" "review_log_days" 2>/dev/null || true)
    max_days="${max_days:-90}"
  fi

  local qdir
  qdir=$(_queue_dir)
  local deleted=0

  [ -d "$qdir" ] || { echo "0"; return; }

  local f
  for f in "$qdir"/review-log-*.jsonl; do
    [ -f "$f" ] || continue
    local age
    age=$(_file_age_days "$f")
    if [ "$age" -ge "$max_days" ]; then
      rm -f "$f"
      deleted=$((deleted + 1))
    fi
  done

  [ "$deleted" -gt 0 ] && echo "review-log: compacted $deleted files (>${max_days}d)" >&2
  echo "$deleted"
}

# --- Tail the most recent review log entries ---
# Reads the last N lines across recent log files.
# Arguments:
#   $1 — n (optional, default 20)
# Output: NDJSON lines on stdout
review_log_tail() {
  local n="${1:-20}"
  local qdir
  qdir=$(_queue_dir)

  [ -d "$qdir" ] || return 0

  # Collect log files sorted by name (date-based names sort chronologically).
  # Use while-read loop to handle paths with spaces (audit 6.7).
  local _combined=""
  local _f
  while IFS= read -r _f; do
    [ -f "$_f" ] || continue
    _combined="${_combined}$(tail -n "$n" "$_f" 2>/dev/null)"$'\n'
  done <<< "$(ls -1 "$qdir"/review-log-*.jsonl 2>/dev/null | sort || true)"

  if [ -z "$_combined" ]; then
    return 0
  fi

  printf '%s\n' "$_combined" | grep -v '^$' | tail -n "$n"
}
