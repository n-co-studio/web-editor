#!/usr/bin/env bash
# Automation bridge — wires plan-approval auto mode to runner activation.
# Sourced by plan-approval.sh ONLY when session_type=taskgroup AND mode=auto.
# Provides automation_activate_taskgroup() for queuing pending briefs.
#
# Design: minimal sourcing. Needs queue-manager.sh, file-lock.sh,
# work-order-manager.sh, and review-log.sh from the automation layer.
# Does NOT source runner.sh or its full chain.
# Decision 0017 — Operator Automation Layer.
#
# Caller must have already sourced:
#   _analytics-helper.sh — get_repo_root, get_session_type, log_hook_event, now_ms
#   _phase-helper.sh — (no direct usage; available for queue-manager.sh dependency)

# Note: no `set -euo pipefail` here — sourced helpers inherit the caller's
# shell options. plan-approval.sh already sets -euo pipefail.

# --- Bootstrap automation environment variables ---
# These are normally set by runner.sh. We derive them independently.
_BRIDGE_REPO_ROOT="$(get_repo_root)"
_BRIDGE_AUTOMATION_DIR="$_BRIDGE_REPO_ROOT/.claude/.automation"

# Export for queue-manager.sh and file-lock.sh dependency
AUTOMATION_DIR="$_BRIDGE_AUTOMATION_DIR"
REPO_ROOT="$_BRIDGE_REPO_ROOT"
CONFIG_FILE="$_BRIDGE_AUTOMATION_DIR/config.yaml"

# Guard: automation layer must be installed
if [ ! -f "$CONFIG_FILE" ]; then
  return 0 2>/dev/null || exit 0
fi

# Source only the libraries we need
# shellcheck source=../../.claude/.automation/lib/file-lock.sh
source "$_BRIDGE_AUTOMATION_DIR/lib/file-lock.sh"
# shellcheck source=../../.claude/.automation/lib/queue-manager.sh
source "$_BRIDGE_AUTOMATION_DIR/lib/queue-manager.sh"
# Audit C2: work-order-manager and review-log required for queue_enqueue()
# side effects (wo_create/review_log_append) — previously silently no-op'd.
# shellcheck source=../../.claude/.automation/lib/work-order-manager.sh
source "$_BRIDGE_AUTOMATION_DIR/lib/work-order-manager.sh"
# shellcheck source=../../.claude/.automation/lib/review-log.sh
source "$_BRIDGE_AUTOMATION_DIR/lib/review-log.sh"

# --- Detect repo mode (template vs product) ---
_BRIDGE_IS_TEMPLATE=false
_BRIDGE_MODE_FILE="$_BRIDGE_REPO_ROOT/.claude/repo-mode"
[ -f "$_BRIDGE_MODE_FILE" ] && grep -q "template" "$_BRIDGE_MODE_FILE" 2>/dev/null \
  && _BRIDGE_IS_TEMPLATE=true

# --- Find active task group contract ---
# Scans contract directory for a YAML file with status: in_progress.
# Output: absolute path on stdout (empty if not found)
_bridge_find_active_contract() {
  local contract_dir
  if [ "$_BRIDGE_IS_TEMPLATE" = true ]; then
    contract_dir="$_BRIDGE_REPO_ROOT/.claude/local/task-groups"
  else
    contract_dir="$_BRIDGE_REPO_ROOT/docs/ai/task-groups"
  fi

  [ -d "$contract_dir" ] || return 0

  local cf
  for cf in "$contract_dir"/*.yaml; do
    [ -f "$cf" ] || continue
    # Skip template files
    case "$(basename "$cf")" in _*) continue ;; esac
    if grep -q "status: in_progress" "$cf" 2>/dev/null; then
      printf '%s' "$cf"
      return
    fi
  done
}

# --- Extract group name from contract ---
# Arguments:
#   $1 — contract_file path
# Output: group_name on stdout
_bridge_extract_group_name() {
  local contract_file="$1"
  grep 'group_name:' "$contract_file" 2>/dev/null \
    | head -1 | sed 's/.*group_name: *"*//' | sed 's/"*[[:space:]]*$//'
}

# --- Extract branch from contract ---
# Reads branch from the first brief entry with a branch set.
# Arguments:
#   $1 — contract_file path
# Output: branch name on stdout
_bridge_extract_branch() {
  local contract_file="$1"
  sed -n '/^briefs:/,/^[a-z]/{ /branch:/p; }' "$contract_file" 2>/dev/null \
    | head -1 | sed 's/.*branch: *"*//' | sed 's/"*[[:space:]]*$//'
}

# --- Parse pending briefs from contract ---
# Extracts briefs with status: pending from the briefs roster.
# Output: one line per pending brief, pipe-delimited: sequence|title|branch
_bridge_parse_pending_briefs() {
  local contract_file="$1"
  awk '
    /^briefs:/ { in_briefs=1; next }
    /^[a-z]/ && !/^  / { in_briefs=0 }

    in_briefs && /^  - / {
      if (seq != "" && status == "pending") {
        printf "%s|%s|%s\n", seq, title, branch
      }
      seq=""; title=""; status=""; branch=""
    }
    in_briefs && /sequence:/ {
      val=$0; gsub(/.*sequence: */, "", val); gsub(/[[:space:]]*$/, "", val); seq=val
    }
    in_briefs && /title:/ {
      val=$0; gsub(/.*title: *"?/, "", val); gsub(/".*/, "", val); title=val
    }
    in_briefs && /status:/ {
      val=$0; gsub(/.*status: */, "", val); gsub(/[[:space:]]*$/, "", val); status=val
    }
    in_briefs && /branch:/ {
      val=$0; gsub(/.*branch: *"?/, "", val); gsub(/".*/, "", val); branch=val
    }

    END {
      if (seq != "" && status == "pending") {
        printf "%s|%s|%s\n", seq, title, branch
      }
    }
  ' "$contract_file"
}

# --- Check if a brief is currently in-flight ---
# Scans pending-review, approved, running directories for matching brief_path.
# Intentionally excludes completed/failed/review/blocked — if a brief
# previously failed and the operator re-approves auto mode, it should be
# re-queued (retry semantics).
# Arguments:
#   $1 — brief_path to check
# Returns: 0 if found (in-flight), 1 if not found
_bridge_is_already_queued() {
  local brief_path="$1"
  local qdir="$AUTOMATION_DIR/queue"

  local status_dir
  for status_dir in pending-review approved running; do
    local dir="$qdir/$status_dir"
    [ -d "$dir" ] || continue
    local f
    for f in "$dir"/*.yaml; do
      [ -f "$f" ] || continue
      if grep -q "brief_path: ${brief_path}" "$f" 2>/dev/null; then
        return 0
      fi
    done
  done

  return 1
}

# --- Enable runner in config.yaml ---
# Changes enabled: false to enabled: true. Idempotent.
_bridge_enable_runner() {
  if grep -q 'enabled: false' "$CONFIG_FILE" 2>/dev/null; then
    # macOS-safe sed in-place
    if [[ "$OSTYPE" == darwin* ]]; then
      sed -i '' 's/enabled: false/enabled: true/' "$CONFIG_FILE"
    else
      sed -i 's/enabled: false/enabled: true/' "$CONFIG_FILE"
    fi
  fi
}

# --- Start runner daemon if not already running ---
_bridge_start_daemon_if_needed() {
  local runner_script="$_BRIDGE_AUTOMATION_DIR/runner.sh"
  [ -f "$runner_script" ] || return 0

  # Check if daemon is already running
  if pgrep -f "runner.sh --daemon" > /dev/null 2>&1; then
    return 0
  fi

  # Start daemon in background
  local log_dir="$_BRIDGE_AUTOMATION_DIR/logs"
  mkdir -p "$log_dir" 2>/dev/null || true
  nohup "$runner_script" --daemon >> "$log_dir/runner.log" 2>&1 &
}

# ============================================================
# Public API
# ============================================================

# --- Activate automation for a task group ---
# Reads the active contract, queues remaining pending briefs,
# enables the runner, and starts the daemon.
# Called from plan-approval.sh when mode=auto AND session_type=taskgroup.
automation_activate_taskgroup() {
  # Find active contract
  local contract_path
  contract_path=$(_bridge_find_active_contract)
  if [ -z "$contract_path" ]; then
    return 0
  fi

  # Extract group name and branch
  local group_name branch
  group_name=$(_bridge_extract_group_name "$contract_path")
  branch=$(_bridge_extract_branch "$contract_path")

  if [ -z "$group_name" ] || [ -z "$branch" ]; then
    return 0
  fi

  # Parse pending briefs
  local pending_briefs
  pending_briefs=$(_bridge_parse_pending_briefs "$contract_path")
  if [ -z "$pending_briefs" ]; then
    return 0
  fi

  # Determine final brief sequence (highest sequence in pending)
  local max_seq=0
  local _line
  while IFS= read -r _line; do
    local seq="${_line%%|*}"
    if [ "$seq" -gt "$max_seq" ] 2>/dev/null; then
      max_seq="$seq"
    fi
  done <<< "$pending_briefs"

  # Enqueue each pending brief
  local queued_count=0
  while IFS='|' read -r seq title brief_branch; do
    [ -z "$seq" ] && continue

    # Use brief-specific branch if set, otherwise group branch
    local entry_branch="${brief_branch:-$branch}"

    # Synthetic brief_path convention
    local brief_path=".claude/.automation/briefs/${group_name}/brief-${seq}.md"

    # Skip if already in-flight (allows retry after failure)
    if _bridge_is_already_queued "$brief_path"; then
      continue
    fi

    # Solo mode: true for final brief, false for non-final
    local solo="false"
    if [ "$seq" = "$max_seq" ]; then
      solo="true"
    fi

    # Enqueue and immediately approve (operator just confirmed auto mode)
    local entry_id
    if acquire_queue_lock 2>/dev/null; then
      entry_id=$(queue_enqueue "$brief_path" "taskgroup" "true" "$solo" "$entry_branch")
      if [ -n "$entry_id" ]; then
        queue_approve "$entry_id"
        queued_count=$((queued_count + 1))
      fi
      release_queue_lock
    fi
  done <<< "$pending_briefs"

  # If we queued anything, enable runner and start daemon
  if [ "$queued_count" -gt 0 ]; then
    _bridge_enable_runner
    _bridge_start_daemon_if_needed

    # Log activation event
    log_hook_event "plan-approval" "PostToolUse" "AskUserQuestion" "allow" \
      "$(now_ms)" "automation_activated" \
      "group:${group_name},queued:${queued_count}" 2>/dev/null || true
  fi
}
