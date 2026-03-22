#!/usr/bin/env bash
# Cleanup — retention-based deletion of stale runtime artifacts.
# Sourced by runner.sh. NOT executed standalone.
# Decision 0017 — Operator Automation Layer.
#
# Cleanup targets:
#   - Completed queue entries older than queue_days config
#   - Brief files referenced by deleted queue entries (in .automation/briefs/ only)
#   - Failed/blocked/review queue entries older than 2x queue_days
#   - Blocker reports older than report_days config
#   - Resolved escalations older than escalation_days config
#   - Stale heartbeat files older than 24h
#   - Closed-branches compaction (branches no longer in reflog)
#
# Depends on (sourced by runner.sh before this file):
#   runner.sh sets REPO_ROOT, AUTOMATION_DIR, CONFIG_FILE
#   queue-manager.sh — _parse_config_field, _queue_dir, _rebuild_queue_index,
#                       _load_queue_entry

set -euo pipefail

# --- Portable stat for modification time (audit C4: cross-platform) ---
# Arguments:
#   $1 — file path
# Output: epoch seconds on stdout (0 on failure)
_portable_mod_epoch() {
  local file="$1"
  case "${OSTYPE:-}" in
    darwin*) stat -f %m "$file" 2>/dev/null || echo "0" ;;
    *)       stat -c %Y "$file" 2>/dev/null || echo "0" ;;
  esac
}

# --- Get file age in days ---
# Arguments:
#   $1 — file path
# Output: integer days on stdout
_file_age_days() {
  local file="$1"
  [ -f "$file" ] || { echo "0"; return; }

  local mod_epoch now_epoch
  mod_epoch=$(_portable_mod_epoch "$file")
  now_epoch=$(date +%s)

  if [ "$mod_epoch" -gt 0 ]; then
    echo $(( (now_epoch - mod_epoch) / 86400 ))
  else
    echo "0"
  fi
}

# --- Get file age in hours (for heartbeat staleness) ---
# Arguments:
#   $1 — file path
# Output: integer hours on stdout
_file_age_hours() {
  local file="$1"
  [ -f "$file" ] || { echo "0"; return; }

  local mod_epoch now_epoch
  mod_epoch=$(_portable_mod_epoch "$file")
  now_epoch=$(date +%s)

  if [ "$mod_epoch" -gt 0 ]; then
    echo $(( (now_epoch - mod_epoch) / 3600 ))
  else
    echo "0"
  fi
}

# --- Check if a brief path is inside the runtime briefs directory ---
# Arguments:
#   $1 — brief_path (absolute or relative to REPO_ROOT)
# Output: resolved absolute path on stdout if safe, empty if not
_brief_in_safe_zone() {
  local brief_path="$1"
  local briefs_dir="${AUTOMATION_DIR:-$REPO_ROOT/.claude/.automation}/briefs"

  [ -n "$brief_path" ] || return 0

  # Resolve to absolute path if relative
  local abs_brief="$brief_path"
  if [ "${brief_path#/}" = "$brief_path" ]; then
    abs_brief="$REPO_ROOT/$brief_path"
  fi

  # Resolve briefs_dir to absolute for comparison
  local abs_briefs_dir
  abs_briefs_dir=$(cd "$briefs_dir" 2>/dev/null && pwd) || return 0

  # Get real directory of the brief file
  local brief_parent
  brief_parent=$(cd "$(dirname "$abs_brief")" 2>/dev/null && pwd) || return 0

  # Only safe if the brief is inside the runtime briefs directory
  case "$brief_parent" in
    "$abs_briefs_dir"|"$abs_briefs_dir"/*)
      printf '%s' "$abs_brief"
      ;;
  esac
}

# --- Delete brief file for a queue entry (if in runtime briefs directory) ---
# Only deletes briefs under .claude/.automation/briefs/ — never outside.
# Arguments:
#   $1 — queue entry YAML file path
# Output: 1 if a brief was deleted, 0 otherwise
_delete_brief_for_entry() {
  local entry_file="$1"

  # Load entry to read brief_path field
  _load_queue_entry "$entry_file" || { echo "0"; return; }

  local safe_path
  safe_path=$(_brief_in_safe_zone "$_QE_BRIEF_PATH")

  if [ -n "$safe_path" ] && [ -f "$safe_path" ]; then
    rm -f "$safe_path"
    echo "1"
  else
    echo "0"
  fi
}

# --- Clean queue entries by status and retention ---
# Arguments:
#   $1 — status directory name (completed, failed, review, blocked)
#   $2 — max age in days
# Output: count of deleted entries on stdout
_clean_queue_status() {
  local status="$1"
  local max_days="$2"
  local qdir
  qdir=$(_queue_dir)
  local dir="$qdir/$status"
  local deleted=0

  [ -d "$dir" ] || { echo "0"; return; }

  local f
  for f in "$dir"/*.yaml; do
    [ -f "$f" ] || continue
    local age
    age=$(_file_age_days "$f")
    if [ "$age" -ge "$max_days" ]; then
      # Delete referenced brief file before removing entry
      _delete_brief_for_entry "$f" > /dev/null
      rm -f "$f"
      deleted=$((deleted + 1))
    fi
  done

  echo "$deleted"
}

# --- Clean blocker reports by retention ---
# Arguments:
#   $1 — max age in days
# Output: count of deleted reports on stdout
_clean_reports() {
  local max_days="$1"
  local reports_dir="${AUTOMATION_DIR:-$REPO_ROOT/.claude/.automation}/reports"
  local deleted=0

  [ -d "$reports_dir" ] || { echo "0"; return; }

  local f
  for f in "$reports_dir"/*.yaml; do
    [ -f "$f" ] || continue
    local age
    age=$(_file_age_days "$f")
    if [ "$age" -ge "$max_days" ]; then
      rm -f "$f"
      deleted=$((deleted + 1))
    fi
  done

  echo "$deleted"
}

# --- Clean resolved escalations by retention ---
# Only deletes escalations where resolved: true.
# Arguments:
#   $1 — max age in days
# Output: count of deleted escalations on stdout
_clean_escalations() {
  local max_days="$1"
  local esc_dir="${AUTOMATION_DIR:-$REPO_ROOT/.claude/.automation}/escalations"
  local deleted=0

  [ -d "$esc_dir" ] || { echo "0"; return; }

  local f
  for f in "$esc_dir"/*.yaml; do
    [ -f "$f" ] || continue
    # Only delete resolved escalations
    if grep -q 'resolved: true' "$f" 2>/dev/null; then
      local age
      age=$(_file_age_days "$f")
      if [ "$age" -ge "$max_days" ]; then
        rm -f "$f"
        deleted=$((deleted + 1))
      fi
    fi
  done

  echo "$deleted"
}

# --- Clean stale heartbeat files ---
# Heartbeats older than 24h indicate orphaned runners.
# Output: count of deleted heartbeats on stdout
_clean_stale_heartbeats() {
  local qdir
  qdir=$(_queue_dir)
  local hb_dir="$qdir/running"
  local deleted=0

  [ -d "$hb_dir" ] || { echo "0"; return; }

  local f
  for f in "$hb_dir"/*.heartbeat; do
    [ -f "$f" ] || continue
    local age
    age=$(_file_age_hours "$f")
    if [ "$age" -ge 24 ]; then
      rm -f "$f"
      deleted=$((deleted + 1))
    fi
  done

  echo "$deleted"
}

# --- Compact closed-branches ledger ---
# Removes entries for branches no longer in git reflog.
# Uses atomic write-to-tmp-then-mv pattern.
# Output: count of removed entries on stdout
_compact_closed_branches() {
  local closed_file="$REPO_ROOT/.claude/local/closed-branches"
  local removed=0

  [ -f "$closed_file" ] || { echo "0"; return; }

  local tmp_file="${closed_file}.tmp"
  local kept_lines=""
  local branch

  while IFS= read -r branch || [ -n "$branch" ]; do
    [ -z "$branch" ] && continue
    # Check if branch exists in reflog (any trace of it)
    if git reflog show "$branch" > /dev/null 2>&1 || \
       git rev-parse --verify "$branch" > /dev/null 2>&1; then
      # Branch still has reflog or ref — keep entry
      if [ -z "$kept_lines" ]; then
        kept_lines="$branch"
      else
        kept_lines="${kept_lines}
${branch}"
      fi
    else
      removed=$((removed + 1))
    fi
  done < "$closed_file"

  # Write compacted file atomically
  if [ "$removed" -gt 0 ]; then
    if [ -n "$kept_lines" ]; then
      printf '%s\n' "$kept_lines" > "$tmp_file"
    else
      : > "$tmp_file"
    fi
    mv "$tmp_file" "$closed_file"
  fi

  echo "$removed"
}

# --- Clean terminal work orders by retention ---
# Deletes completed/escalated work orders older than max_days.
# Arguments:
#   $1 — max age in days
# Output: count of deleted work orders on stdout
_clean_work_orders() {
  local max_days="$1"
  local wo_dir
  wo_dir="$(_queue_dir)/work-orders"
  local deleted=0

  [ -d "$wo_dir" ] || { echo "0"; return; }

  local f
  for f in "$wo_dir"/*.yaml; do
    [ -f "$f" ] || continue
    # Only delete terminal work orders (completed or escalated)
    if grep -q 'status: completed' "$f" 2>/dev/null || \
       grep -q 'status: escalated' "$f" 2>/dev/null; then
      local age
      age=$(_file_age_days "$f")
      if [ "$age" -ge "$max_days" ]; then
        rm -f "$f"
        deleted=$((deleted + 1))
      fi
    fi
  done

  echo "$deleted"
}

# --- Clean brief files for completed entries without deleting entries ---
# Only scans completed/ status. Briefs for failed/blocked/review entries
# are cleaned when those entries age out via run_cleanup → _clean_queue_status.
# Arguments:
#   $1 — max age in days (entries older than this have briefs cleaned)
# Output: count of deleted briefs on stdout
_clean_briefs_only() {
  local max_days="$1"
  local qdir
  qdir=$(_queue_dir)
  local dir="$qdir/completed"
  local deleted=0

  [ -d "$dir" ] || { echo "0"; return; }

  local f
  for f in "$dir"/*.yaml; do
    [ -f "$f" ] || continue
    local age
    age=$(_file_age_days "$f")
    if [ "$age" -ge "$max_days" ]; then
      local brief_deleted
      brief_deleted=$(_delete_brief_for_entry "$f")
      deleted=$((deleted + brief_deleted))
    fi
  done

  echo "$deleted"
}

# --- Dry-run cleanup scan ---
# Shows what would be deleted without acting.
# Note: output is a point-in-time snapshot — concurrent runner activity
# may change results between dry-run and actual prune.
# Output: planned deletions to stdout
_dry_run_cleanup() {
  local queue_days report_days escalation_days
  queue_days=$(_parse_config_field "retention" "queue_days" 2>/dev/null || true)
  queue_days="${queue_days:-30}"
  report_days=$(_parse_config_field "retention" "report_days" 2>/dev/null || true)
  report_days="${report_days:-90}"
  escalation_days=$(_parse_config_field "retention" "escalation_days" 2>/dev/null || true)
  escalation_days="${escalation_days:-90}"

  local failed_days=$((queue_days * 2))
  local qdir
  qdir=$(_queue_dir)
  local total=0

  # Queue entries + their briefs
  local status max_d
  for status in completed; do
    max_d="$queue_days"
    local dir="$qdir/$status"
    [ -d "$dir" ] || continue
    local f
    for f in "$dir"/*.yaml; do
      [ -f "$f" ] || continue
      local age
      age=$(_file_age_days "$f")
      if [ "$age" -ge "$max_d" ]; then
        echo "would delete: $f (${age}d old, >${max_d}d)"
        total=$((total + 1))
        # Check for brief file in safe zone
        _load_queue_entry "$f" 2>/dev/null || continue
        local safe_path
        safe_path=$(_brief_in_safe_zone "$_QE_BRIEF_PATH")
        if [ -n "$safe_path" ] && [ -f "$safe_path" ]; then
          echo "would delete: $safe_path (brief for $(basename "$f" .yaml))"
          total=$((total + 1))
        fi
      fi
    done
  done

  for status in failed blocked review; do
    max_d="$failed_days"
    local dir="$qdir/$status"
    [ -d "$dir" ] || continue
    local f
    for f in "$dir"/*.yaml; do
      [ -f "$f" ] || continue
      local age
      age=$(_file_age_days "$f")
      if [ "$age" -ge "$max_d" ]; then
        echo "would delete: $f (${age}d old, >${max_d}d)"
        total=$((total + 1))
        # Check for brief file in safe zone
        _load_queue_entry "$f" 2>/dev/null || continue
        local safe_path
        safe_path=$(_brief_in_safe_zone "$_QE_BRIEF_PATH")
        if [ -n "$safe_path" ] && [ -f "$safe_path" ]; then
          echo "would delete: $safe_path (brief for $(basename "$f" .yaml))"
          total=$((total + 1))
        fi
      fi
    done
  done

  # Reports
  local reports_dir="${AUTOMATION_DIR:-$REPO_ROOT/.claude/.automation}/reports"
  if [ -d "$reports_dir" ]; then
    local f
    for f in "$reports_dir"/*.yaml; do
      [ -f "$f" ] || continue
      local age
      age=$(_file_age_days "$f")
      if [ "$age" -ge "$report_days" ]; then
        echo "would delete: $f (${age}d old, >${report_days}d)"
        total=$((total + 1))
      fi
    done
  fi

  # Escalations (resolved only)
  local esc_dir="${AUTOMATION_DIR:-$REPO_ROOT/.claude/.automation}/escalations"
  if [ -d "$esc_dir" ]; then
    local f
    for f in "$esc_dir"/*.yaml; do
      [ -f "$f" ] || continue
      if grep -q 'resolved: true' "$f" 2>/dev/null; then
        local age
        age=$(_file_age_days "$f")
        if [ "$age" -ge "$escalation_days" ]; then
          echo "would delete: $f (${age}d old, >${escalation_days}d)"
          total=$((total + 1))
        fi
      fi
    done
  fi

  # Work orders (terminal)
  local wo_dir="$qdir/work-orders"
  if [ -d "$wo_dir" ]; then
    local f
    for f in "$wo_dir"/*.yaml; do
      [ -f "$f" ] || continue
      if grep -q 'status: completed' "$f" 2>/dev/null || \
         grep -q 'status: escalated' "$f" 2>/dev/null; then
        local age
        age=$(_file_age_days "$f")
        if [ "$age" -ge "$queue_days" ]; then
          echo "would delete: $f (${age}d old, >${queue_days}d)"
          total=$((total + 1))
        fi
      fi
    done
  fi

  # Stale heartbeats
  local hb_dir="$qdir/running"
  if [ -d "$hb_dir" ]; then
    local f
    for f in "$hb_dir"/*.heartbeat; do
      [ -f "$f" ] || continue
      local age
      age=$(_file_age_hours "$f")
      if [ "$age" -ge 24 ]; then
        echo "would delete: $f (${age}h old, >24h)"
        total=$((total + 1))
      fi
    done
  fi

  echo "---"
  echo "dry-run: $total artifacts would be deleted"
}

# ============================================================
# Public API
# ============================================================

# --- Recover orphaned running entries (audit 3.4) ---
# Scans running/ for entries with no heartbeat or stale heartbeat (>1h).
# Transitions them to failed/. Standalone equivalent of daemon idle-cycle scanner.
# Output: count of recovered entries on stdout
recover_orphaned_running() {
  local qdir
  qdir=$(_queue_dir)
  local running_dir="$qdir/running"
  local recovered=0

  [ -d "$running_dir" ] || { echo "0"; return; }

  local hb_interval
  hb_interval=$(_parse_config_field "runner" "heartbeat_interval" 2>/dev/null || true)
  hb_interval="${hb_interval:-30}"
  local threshold=$((hb_interval * 120))
  local now
  now=$(date +%s)

  local entry_file
  for entry_file in "$running_dir"/*.yaml; do
    [ -f "$entry_file" ] || continue
    local entry_id
    entry_id=$(basename "$entry_file" .yaml)
    local hb_file="$running_dir/${entry_id}.heartbeat"

    # Skip entries with fresh heartbeat
    if [ -f "$hb_file" ]; then
      local hb_ts
      hb_ts=$(cat "$hb_file" 2>/dev/null || true)
      if [ -n "$hb_ts" ]; then
        local hb_epoch
        hb_epoch=$(_iso_to_epoch "$hb_ts" 2>/dev/null || echo "0")
        local age=$((now - hb_epoch))
        if [ "$age" -lt "$threshold" ]; then
          continue
        fi
      fi
    fi

    # No heartbeat or stale — recover
    _load_queue_entry "$entry_file"
    _QE_STATUS="failed"
    _QE_ERROR_LOG="orphaned entry — recovered by standalone cleanup"
    _QE_COMPLETED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    _QE_UPDATED_AT="$_QE_COMPLETED_AT"
    mkdir -p "$qdir/failed" 2>/dev/null || true
    _write_queue_entry "$qdir/failed/${entry_id}.yaml"
    rm -f "$entry_file"
    rm -f "$hb_file" 2>/dev/null || true
    recovered=$((recovered + 1))
  done

  echo "$recovered"
}

# --- Run full cleanup pass ---
# Reads retention config and cleans all stale artifacts.
# Output: summary to stderr
run_cleanup() {
  # Read retention config
  local queue_days report_days escalation_days
  queue_days=$(_parse_config_field "retention" "queue_days" 2>/dev/null || true)
  queue_days="${queue_days:-30}"
  report_days=$(_parse_config_field "retention" "report_days" 2>/dev/null || true)
  report_days="${report_days:-90}"
  escalation_days=$(_parse_config_field "retention" "escalation_days" 2>/dev/null || true)
  escalation_days="${escalation_days:-90}"

  local failed_days=$((queue_days * 2))

  local total_deleted=0 count

  # Queue entries (brief files deleted as side effect via _delete_brief_for_entry)
  count=$(_clean_queue_status "completed" "$queue_days")
  total_deleted=$((total_deleted + count))
  [ "$count" -gt 0 ] && echo "cleanup: removed $count completed entries (>${queue_days}d)" >&2

  count=$(_clean_queue_status "failed" "$failed_days")
  total_deleted=$((total_deleted + count))
  [ "$count" -gt 0 ] && echo "cleanup: removed $count failed entries (>${failed_days}d)" >&2

  count=$(_clean_queue_status "blocked" "$failed_days")
  total_deleted=$((total_deleted + count))
  [ "$count" -gt 0 ] && echo "cleanup: removed $count blocked entries (>${failed_days}d)" >&2

  count=$(_clean_queue_status "review" "$failed_days")
  total_deleted=$((total_deleted + count))
  [ "$count" -gt 0 ] && echo "cleanup: removed $count review entries (>${failed_days}d)" >&2

  # Blocker reports
  count=$(_clean_reports "$report_days")
  total_deleted=$((total_deleted + count))
  [ "$count" -gt 0 ] && echo "cleanup: removed $count reports (>${report_days}d)" >&2

  # Escalations (resolved only)
  count=$(_clean_escalations "$escalation_days")
  total_deleted=$((total_deleted + count))
  [ "$count" -gt 0 ] && echo "cleanup: removed $count resolved escalations (>${escalation_days}d)" >&2

  # Review log compaction
  if type review_log_compact > /dev/null 2>&1; then
    count=$(review_log_compact)
    total_deleted=$((total_deleted + count))
  fi

  # Work orders (terminal status, same retention as queue entries)
  count=$(_clean_work_orders "$queue_days")
  total_deleted=$((total_deleted + count))
  [ "$count" -gt 0 ] && echo "cleanup: removed $count terminal work orders (>${queue_days}d)" >&2

  # Orphaned running entries (audit 3.4: standalone recovery)
  count=$(recover_orphaned_running)
  total_deleted=$((total_deleted + count))
  [ "$count" -gt 0 ] && echo "cleanup: recovered $count orphaned running entries" >&2

  # Stale heartbeats
  count=$(_clean_stale_heartbeats)
  total_deleted=$((total_deleted + count))
  [ "$count" -gt 0 ] && echo "cleanup: removed $count stale heartbeats (>24h)" >&2

  # Closed-branches compaction
  count=$(_compact_closed_branches)
  [ "$count" -gt 0 ] && echo "cleanup: compacted $count stale closed-branch entries" >&2

  # Orphaned defer-count files (entry no longer in approved/ or running/)
  local _defer_cleaned=0
  local _qdir
  _qdir=$(_queue_dir)
  for _dcf in "$_qdir"/.defer-count-*; do
    [ -f "$_dcf" ] || continue
    local _dc_id="${_dcf##*/.defer-count-}"
    if [ ! -f "$_qdir/approved/${_dc_id}.yaml" ] && [ ! -f "$_qdir/running/${_dc_id}.yaml" ]; then
      rm -f "$_dcf"
      _defer_cleaned=$((_defer_cleaned + 1))
    fi
  done
  [ "$_defer_cleaned" -gt 0 ] && echo "cleanup: removed $_defer_cleaned orphaned defer-count files" >&2

  # Rebuild queue index if any queue entries were deleted
  if [ "$total_deleted" -gt 0 ]; then
    _rebuild_queue_index
  fi

  echo "cleanup: complete ($total_deleted artifacts removed)" >&2
}
