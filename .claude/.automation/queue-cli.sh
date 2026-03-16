#!/usr/bin/env bash
# Unified queue CLI — operator entry point for queue lifecycle management.
# Lives alongside runner.sh at .claude/.automation/queue-cli.sh.
# Decision 0017 — Operator Automation Layer.
#
# Usage:
#   queue-cli.sh <subcommand> [options]
#
# Subcommands:
#   add --brief <path> [--branch NAME] [--session-type TYPE] [--auto-approve] [--solo] [--push]
#   approve <id>
#   remove <id>
#   edit <id> <field> <value>
#   status
#   list [--status <filter>]
#   show <id>
#   review
#   log [--lines N]
#   halt
#   resume
#
# Global flags:
#   --json    Machine-readable JSON output (status, list, show, review)
#
# Exit codes:
#   0  Success
#   1  Validation or operational error

set -euo pipefail

# --- Self-locate and derive repo root ---
# queue-cli.sh lives at .claude/.automation/ — repo root is two levels up.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AUTOMATION_DIR="$SCRIPT_DIR"
LIB_DIR="$AUTOMATION_DIR/lib"
CONFIG_FILE="$AUTOMATION_DIR/config.yaml"

# --- Source shared helpers ---
# shellcheck source=../../.claude/hooks/_analytics-helper.sh
source "$REPO_ROOT/.claude/hooks/_analytics-helper.sh"
# shellcheck source=../../.claude/hooks/_phase-helper.sh
source "$REPO_ROOT/.claude/hooks/_phase-helper.sh"
# shellcheck source=../../.claude/hooks/_cleanup-helper.sh
source "$REPO_ROOT/.claude/hooks/_cleanup-helper.sh"

# --- Source runner libraries ---
# shellcheck source=lib/queue-manager.sh
source "$LIB_DIR/queue-manager.sh"
# shellcheck source=lib/queue-reporter.sh
source "$LIB_DIR/queue-reporter.sh"
# shellcheck source=lib/work-order-manager.sh
source "$LIB_DIR/work-order-manager.sh"
# shellcheck source=lib/review-log.sh
source "$LIB_DIR/review-log.sh"
# shellcheck source=lib/file-lock.sh
source "$LIB_DIR/file-lock.sh"
# shellcheck source=lib/queue-validator.sh
source "$LIB_DIR/queue-validator.sh"
# shellcheck source=lib/branch-manager.sh
source "$LIB_DIR/branch-manager.sh"

# --- Global flags ---
JSON_OUTPUT=false

# --- Usage ---
_usage() {
  cat >&2 << 'EOF'
Usage: queue-cli.sh [--json] <subcommand> [args]

Subcommands:
  add --brief <path> [--branch NAME] [--session-type TYPE] [--auto-approve] [--solo] [--push]
  approve <id>
  remove <id>
  edit <id> <field> <value>
  status
  list [--status <filter>]
  show <id>
  review
  log [--lines N]
  halt
  resume
EOF
  exit 1
}

# --- JSON helpers ---
# Wraps _json_escape from review-log.sh for output formatting.
_json_kv() {
  local key="$1" val="$2"
  local esc_val
  esc_val=$(_json_escape "$val")
  printf '"%s":"%s"' "$key" "$esc_val"
}

_json_kv_raw() {
  local key="$1" val="$2"
  printf '"%s":%s' "$key" "$val"
}

# --- Parse global flags and extract subcommand ---
if [ $# -eq 0 ]; then
  _usage
fi

# Consume leading --json flag
if [ "$1" = "--json" ]; then
  JSON_OUTPUT=true
  shift
fi

if [ $# -eq 0 ]; then
  _usage
fi

SUBCOMMAND="$1"
shift

# ============================================================
# Subcommand dispatch
# ============================================================

case "$SUBCOMMAND" in

  # --- add: create a queue entry ---
  add)
    ADD_BRIEF="" ADD_BRANCH="" ADD_SESSION_TYPE="standard"
    ADD_AUTO_APPROVE=false ADD_SOLO=false ADD_PUSH=false

    while [ $# -gt 0 ]; do
      case "$1" in
        --brief)         ADD_BRIEF="$2"; shift 2 ;;
        --branch)        ADD_BRANCH="$2"; shift 2 ;;
        --session-type)  ADD_SESSION_TYPE="$2"; shift 2 ;;
        --auto-approve)  ADD_AUTO_APPROVE=true; shift ;;
        --solo)          ADD_SOLO=true; shift ;;
        --push)          ADD_PUSH=true; shift ;;
        *) echo "ERROR: Unknown add option: $1" >&2; exit 1 ;;
      esac
    done

    if [ -z "$ADD_BRIEF" ]; then
      echo "ERROR: add requires --brief <path>" >&2
      exit 1
    fi

    # Resolve brief path
    if [ ! -f "$ADD_BRIEF" ] && [ -f "$REPO_ROOT/$ADD_BRIEF" ]; then
      ADD_BRIEF="$REPO_ROOT/$ADD_BRIEF"
    fi
    if [ ! -f "$ADD_BRIEF" ]; then
      echo "ERROR: Brief file not found: $ADD_BRIEF" >&2
      exit 1
    fi

    # Validate session type
    VALID_PHASES=$(get_phases_for_type "$ADD_SESSION_TYPE" 2>/dev/null || true)
    if [ -z "$VALID_PHASES" ]; then
      echo "ERROR: Invalid session type: $ADD_SESSION_TYPE" >&2
      exit 1
    fi

    # Branch warning for non-taskgroup
    if [ -n "$ADD_BRANCH" ]; then
      case "$ADD_SESSION_TYPE" in
        taskgroup|taskgroup-merge) ;;
        *) echo "WARNING: --branch is intended for taskgroup/taskgroup-merge sessions" >&2 ;;
      esac
    fi

    # Convert flags
    ADD_AUTO_MODE="false"
    [ "$ADD_AUTO_APPROVE" = true ] && ADD_AUTO_MODE="true"
    ADD_SOLO_STR="false"
    [ "$ADD_SOLO" = true ] && ADD_SOLO_STR="true"
    ADD_PUSH_STR="false"
    [ "$ADD_PUSH" = true ] && ADD_PUSH_STR="true"

    # Mutating — acquire lock
    if ! acquire_queue_lock; then
      echo "ERROR: Queue lock unavailable" >&2
      exit 1
    fi

    _ensure_queue_dirs
    ENTRY_ID=$(queue_enqueue "$ADD_BRIEF" "$ADD_SESSION_TYPE" "$ADD_AUTO_MODE" "$ADD_SOLO_STR" "$ADD_BRANCH" "" "$ADD_PUSH_STR")

    if [ -z "$ENTRY_ID" ]; then
      release_queue_lock
      echo "ERROR: Failed to create queue entry" >&2
      exit 1
    fi

    ADD_STATUS="pending-review"
    if [ "$ADD_AUTO_APPROVE" = true ]; then
      queue_approve "$ENTRY_ID"
      ADD_STATUS="approved"
    fi

    release_queue_lock

    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s,%s,%s,%s}\n' \
        "$(_json_kv "entry_id" "$ENTRY_ID")" \
        "$(_json_kv "status" "$ADD_STATUS")" \
        "$(_json_kv "session_type" "$ADD_SESSION_TYPE")" \
        "$(_json_kv "brief_path" "$ADD_BRIEF")"
    else
      printf 'entry_id: %s\nstatus: %s\nsession_type: %s\nbrief_path: %s\n' \
        "$ENTRY_ID" "$ADD_STATUS" "$ADD_SESSION_TYPE" "$ADD_BRIEF"
    fi
    ;;

  # --- approve: move entry to approved ---
  approve)
    if [ $# -lt 1 ]; then
      echo "ERROR: approve requires <id>" >&2
      exit 1
    fi
    APPROVE_ID="$1"

    if ! acquire_queue_lock; then
      echo "ERROR: Queue lock unavailable" >&2
      exit 1
    fi

    queue_approve "$APPROVE_ID"
    release_queue_lock

    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s,%s}\n' "$(_json_kv "entry_id" "$APPROVE_ID")" "$(_json_kv "status" "approved")"
    else
      printf 'Approved: %s\n' "$APPROVE_ID"
    fi
    ;;

  # --- remove: delete entry from queue ---
  remove)
    if [ $# -lt 1 ]; then
      echo "ERROR: remove requires <id>" >&2
      exit 1
    fi
    REMOVE_ID="$1"

    if ! acquire_queue_lock; then
      echo "ERROR: Queue lock unavailable" >&2
      exit 1
    fi

    queue_remove "$REMOVE_ID"
    release_queue_lock

    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s,%s}\n' "$(_json_kv "entry_id" "$REMOVE_ID")" "$(_json_kv "action" "removed")"
    else
      printf 'Removed: %s\n' "$REMOVE_ID"
    fi
    ;;

  # --- edit: modify entry field ---
  edit)
    if [ $# -lt 3 ]; then
      echo "ERROR: edit requires <id> <field> <value>" >&2
      exit 1
    fi
    EDIT_ID="$1" EDIT_FIELD="$2" EDIT_VALUE="$3"

    if ! acquire_queue_lock; then
      echo "ERROR: Queue lock unavailable" >&2
      exit 1
    fi

    queue_edit "$EDIT_ID" "$EDIT_FIELD" "$EDIT_VALUE"
    release_queue_lock

    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s,%s,%s}\n' \
        "$(_json_kv "entry_id" "$EDIT_ID")" \
        "$(_json_kv "field" "$EDIT_FIELD")" \
        "$(_json_kv "value" "$EDIT_VALUE")"
    else
      printf 'Updated %s: %s = %s\n' "$EDIT_ID" "$EDIT_FIELD" "$EDIT_VALUE"
    fi
    ;;

  # --- status: queue summary ---
  status)
    if [ "$JSON_OUTPUT" = true ]; then
      # Build JSON from pipe-delimited output
      RAW=$(queue_status "pipe")
      printf '{'
      FIRST=true
      while IFS='|' read -r S_KEY S_VAL; do
        [ -z "$S_KEY" ] && continue
        # Normalize key for JSON (replace - with _)
        JSON_KEY="${S_KEY//-/_}"
        if [ "$FIRST" = true ]; then
          FIRST=false
        else
          printf ','
        fi
        printf '"%s":%s' "$JSON_KEY" "$S_VAL"
      done <<< "$RAW"
      printf '}\n'
    else
      queue_status "text"
    fi
    ;;

  # --- list: show entries ---
  list)
    LIST_FILTER=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --status) LIST_FILTER="$2"; shift 2 ;;
        *) echo "ERROR: Unknown list option: $1" >&2; exit 1 ;;
      esac
    done

    if [ "$JSON_OUTPUT" = true ]; then
      printf '['
      FIRST=true
      while IFS='|' read -r L_ID L_STATUS L_TYPE L_BRIEF L_UPDATED; do
        [ -z "$L_ID" ] && continue
        if [ "$FIRST" = true ]; then
          FIRST=false
        else
          printf ','
        fi
        printf '{%s,%s,%s,%s,%s}' \
          "$(_json_kv "id" "$L_ID")" \
          "$(_json_kv "status" "$L_STATUS")" \
          "$(_json_kv "session_type" "$L_TYPE")" \
          "$(_json_kv "brief_path" "$L_BRIEF")" \
          "$(_json_kv "updated_at" "$L_UPDATED")"
      done < <(queue_list "$LIST_FILTER")
      printf ']\n'
    else
      queue_list "$LIST_FILTER"
    fi
    ;;

  # --- show: entry detail ---
  show)
    if [ $# -lt 1 ]; then
      echo "ERROR: show requires <id>" >&2
      exit 1
    fi
    SHOW_ID="$1"

    if [ "$JSON_OUTPUT" = true ]; then
      ENTRY_FILE=$(_find_entry_file "$SHOW_ID")
      if [ -z "$ENTRY_FILE" ]; then
        echo "ERROR: Entry $SHOW_ID not found" >&2
        exit 1
      fi
      _load_queue_entry "$ENTRY_FILE"
      printf '{%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s}\n' \
        "$(_json_kv "id" "$_QE_ID")" \
        "$(_json_kv "status" "$_QE_STATUS")" \
        "$(_json_kv "session_type" "$_QE_SESSION_TYPE")" \
        "$(_json_kv "branch" "$_QE_BRANCH")" \
        "$(_json_kv "brief_path" "$_QE_BRIEF_PATH")" \
        "$(_json_kv "auto_mode" "$_QE_AUTO_MODE")" \
        "$(_json_kv "solo_mode" "$_QE_SOLO_MODE")" \
        "$(_json_kv "push_on_complete" "$_QE_PUSH_ON_COMPLETE")" \
        "$(_json_kv "retry_count" "$_QE_RETRY_COUNT")" \
        "$(_json_kv "max_retries" "$_QE_MAX_RETRIES")" \
        "$(_json_kv "error_log" "$_QE_ERROR_LOG")" \
        "$(_json_kv "work_order_id" "$_QE_WORK_ORDER_ID")" \
        "$(_json_kv "created_at" "$_QE_CREATED_AT")" \
        "$(_json_kv "updated_at" "$_QE_UPDATED_AT")" \
        "$(_json_kv "completed_at" "$_QE_COMPLETED_AT")"
    else
      queue_show "$SHOW_ID"
    fi
    ;;

  # --- review: items needing operator attention ---
  review)
    if [ "$JSON_OUTPUT" = true ]; then
      printf '['
      FIRST=true
      while IFS='|' read -r R_ID R_STATUS R_TYPE R_ERROR R_WO; do
        [ -z "$R_ID" ] && continue
        if [ "$FIRST" = true ]; then
          FIRST=false
        else
          printf ','
        fi
        printf '{%s,%s,%s,%s,%s}' \
          "$(_json_kv "id" "$R_ID")" \
          "$(_json_kv "status" "$R_STATUS")" \
          "$(_json_kv "session_type" "$R_TYPE")" \
          "$(_json_kv "error_log" "$R_ERROR")" \
          "$(_json_kv "work_order_id" "$R_WO")"
      done < <(review_items)
      printf ']\n'
    else
      ITEMS=$(review_items)
      if [ -z "$ITEMS" ]; then
        echo "No items need review."
      else
        echo "$ITEMS"
      fi
    fi
    ;;

  # --- log: review log tail ---
  log)
    LOG_LINES=20
    while [ $# -gt 0 ]; do
      case "$1" in
        --lines) LOG_LINES="$2"; shift 2 ;;
        *) echo "ERROR: Unknown log option: $1" >&2; exit 1 ;;
      esac
    done

    review_log_tail "$LOG_LINES"
    ;;

  # --- halt: stop daemon loop ---
  halt)
    touch "$AUTOMATION_DIR/HALT"
    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s}\n' "$(_json_kv "action" "halted")"
    else
      echo "HALT file created — daemon will stop after current entry completes."
    fi
    ;;

  # --- resume: clear halt ---
  resume)
    rm -f "$AUTOMATION_DIR/HALT"
    if [ "$JSON_OUTPUT" = true ]; then
      printf '{%s}\n' "$(_json_kv "action" "resumed")"
    else
      echo "HALT file removed — restart daemon with: runner.sh --daemon &"
    fi
    ;;

  *)
    echo "ERROR: Unknown subcommand: $SUBCOMMAND" >&2
    _usage
    ;;
esac
