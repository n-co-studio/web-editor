#!/usr/bin/env bash
# Remediation trigger — post-completion trigger for auto-generating remediation
# queue entries from audit health report findings.
# Sourced by runner.sh. NOT executed standalone.
# Decision 0017 — Operator Automation Layer.
#
# Single trigger condition:
#   Audit session completes with actionable health report findings
#   → enqueue remediation entry (standard session) with grouped findings.
#
# Depends on (sourced by runner.sh before this file):
#   runner.sh sets REPO_ROOT, AUTOMATION_DIR, CONFIG_FILE
#   queue-manager.sh — queue_enqueue, _parse_config_field, _queue_dir
#   file-lock.sh — acquire_queue_lock, release_queue_lock

set -euo pipefail

# --- Locate the newest health report by mtime ---
# Output: absolute path to report on stdout (empty if not found)
_find_latest_health_report() {
  local reports_dir="$AUTOMATION_DIR/reports"
  [ -d "$reports_dir" ] || return 0

  local latest=""
  local latest_mtime=0

  for f in "$reports_dir"/health-*-*.yaml; do
    [ -f "$f" ] || continue
    local mtime
    if stat -f '%m' "$f" > /dev/null 2>&1; then
      # macOS stat
      mtime=$(stat -f '%m' "$f" 2>/dev/null || echo "0")
    else
      # GNU stat
      mtime=$(stat -c '%Y' "$f" 2>/dev/null || echo "0")
    fi
    if [ "$mtime" -gt "$latest_mtime" ] 2>/dev/null; then
      latest_mtime="$mtime"
      latest="$f"
    fi
  done

  printf '%s' "$latest"
}

# --- Extract actionable findings from a health report ---
# Arguments:
#   $1 — report file path
#   $2 — severity filter (e.g., "CRITICAL" or "CRITICAL,RECOMMENDATION")
# Output: matching finding lines on stdout (one per line)
_extract_findings() {
  local report_file="$1"
  local severity_filter="$2"

  # Build grep pattern from severity filter
  local pattern=""
  if printf '%s' "$severity_filter" | grep -q "RECOMMENDATION"; then
    pattern='^[0-9]+\. (CRITICAL|RECOMMENDATION):'
  else
    pattern='^[0-9]+\. CRITICAL:'
  fi

  grep -E "$pattern" "$report_file" 2>/dev/null || true
}

# --- Check for duplicate remediation entry in queue ---
# Arguments:
#   $1 — report_filename (basename of the health report)
# Returns: 0 if a remediation entry for this report already exists
_has_pending_remediation_entry() {
  local report_filename="$1"
  local qdir
  qdir=$(_queue_dir)

  local status
  for status in pending-review approved running; do
    local dir="$qdir/$status"
    [ -d "$dir" ] || continue
    local f
    for f in "$dir"/*.yaml; do
      [ -f "$f" ] || continue
      # Check the brief_path field, then check the brief file itself
      local brief_path=""
      brief_path=$(grep '^  brief_path:' "$f" 2>/dev/null \
        | sed 's/.*brief_path: *//' | tr -d '[:space:]"' | head -1 || true)
      if [ -n "$brief_path" ]; then
        local abs_brief=""
        if [ -f "$brief_path" ]; then
          abs_brief="$brief_path"
        elif [ -f "$REPO_ROOT/$brief_path" ]; then
          abs_brief="$REPO_ROOT/$brief_path"
        fi
        if [ -n "$abs_brief" ] && grep -q "\[remediation-source: ${report_filename}\]" "$abs_brief" 2>/dev/null; then
          return 0
        fi
      fi
    done
  done

  return 1
}

# --- Compose and write a remediation brief file ---
# Arguments:
#   $1 — entry_id (source audit entry)
#   $2 — report_path (absolute path to health report)
#   $3 — report_filename (basename)
#   $4 — findings text (newline-separated finding lines)
#   $5 — sequence number (1-based)
# Output: brief file path on stdout
_write_remediation_brief() {
  local entry_id="$1"
  local report_path="$2"
  local report_filename="$3"
  local findings="$4"
  local seq="$5"

  local briefs_dir="$AUTOMATION_DIR/briefs"
  mkdir -p "$briefs_dir" 2>/dev/null || true

  local timestamp
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  local brief_file="$briefs_dir/remediation-${timestamp}-${seq}.md"

  cat > "$brief_file" <<BRIEF_EOF
## Remediation Brief
[remediation-source: ${report_filename}]
Source: audit session ${entry_id}, report ${report_path}

### Findings to Fix
${findings}

### Instructions
Fix each finding above. Read the referenced files, make the minimum changes needed, and verify each fix.
BRIEF_EOF

  printf '%s' "$brief_file"
}

# ============================================================
# Public API
# ============================================================

# --- Check remediation trigger after audit completion ---
# Arguments:
#   $1 — entry_id (completed entry)
#   $2 — session_type of the completed entry
#   $3 — brief_path (path to the entry's brief)
#   $4 — branch (the entry's branch name)
#   $5 — work_order_id (optional)
check_remediation_trigger() {
  local entry_id="$1"
  local session_type="$2"
  local brief_path="${3:-}"
  local branch="${4:-}"
  local work_order_id="${5:-}"

  # Early return: only audit sessions trigger remediation
  if [ "$session_type" != "audit" ]; then
    return
  fi

  # Read config gate
  local auto_remediation
  auto_remediation=$(_parse_config_field "runner" "auto_remediation" 2>/dev/null || true)
  auto_remediation="${auto_remediation:-false}"
  if [ "$auto_remediation" != "true" ]; then
    return
  fi

  local severity_filter
  severity_filter=$(_parse_config_field "runner" "auto_remediation_severity" 2>/dev/null || true)
  severity_filter="${severity_filter:-CRITICAL}"

  # Locate the newest health report
  local report_path
  report_path=$(_find_latest_health_report)
  if [ -z "$report_path" ]; then
    echo "remediation-trigger: no health report found" >&2
    return
  fi

  local report_filename
  report_filename=$(basename "$report_path")

  # Extract findings
  local findings
  findings=$(_extract_findings "$report_path" "$severity_filter")
  if [ -z "$findings" ]; then
    echo "remediation-trigger: 0 actionable findings" >&2
    return
  fi

  # Deduplicate — check if remediation for this report is already queued
  if _has_pending_remediation_entry "$report_filename"; then
    echo "remediation-trigger: remediation entry already queued for $report_filename" >&2
    return
  fi

  # Cap at 3 entries — group findings into batches
  local total_lines
  total_lines=$(printf '%s\n' "$findings" | wc -l | tr -d '[:space:]')
  local max_entries=3
  local enqueued=0

  # Acquire lock before enqueue
  if ! acquire_queue_lock; then
    echo "remediation-trigger: WARNING — failed to acquire queue lock" >&2
    return
  fi

  if [ "$total_lines" -le 5 ]; then
    # Few findings — single entry with all of them
    local brief_file
    brief_file=$(_write_remediation_brief "$entry_id" "$report_path" "$report_filename" "$findings" "1")
    local new_id
    new_id=$(queue_enqueue "$brief_file" "standard" "" "" "" "$work_order_id")
    echo "remediation-trigger: enqueued entry $new_id for $report_filename" >&2
    enqueued=1
  else
    # Many findings — split across up to 3 entries
    local lines_per_entry=$(( (total_lines + max_entries - 1) / max_entries ))
    local seq=1
    local start=1

    while [ "$start" -le "$total_lines" ] && [ "$seq" -le "$max_entries" ]; do
      local chunk
      chunk=$(printf '%s\n' "$findings" | sed -n "${start},$((start + lines_per_entry - 1))p")
      if [ -n "$chunk" ]; then
        local brief_file
        brief_file=$(_write_remediation_brief "$entry_id" "$report_path" "$report_filename" "$chunk" "$seq")
        local new_id
        new_id=$(queue_enqueue "$brief_file" "standard" "" "" "" "$work_order_id")
        echo "remediation-trigger: enqueued entry $new_id (batch $seq) for $report_filename" >&2
        enqueued=$((enqueued + 1))
      fi
      start=$((start + lines_per_entry))
      seq=$((seq + 1))
    done
  fi

  release_queue_lock

  echo "remediation-trigger: enqueued $enqueued remediation entries for $report_filename" >&2
}
