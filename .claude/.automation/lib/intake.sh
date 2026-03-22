#!/usr/bin/env bash
# Standalone brief intake — operator-facing CLI for queue entry creation.
# Creates queue entries without the interactive bridge (plan-approval.sh).
# Decision 0017 — Operator Automation Layer.
#
# Usage:
#   intake.sh --brief <path/to/brief.md> [options]
#
# Options:
#   --brief PATH          Path to task brief (required)
#   --auto-approve        Place entry directly in approved/ (default: pending-review/)
#   --session-type TYPE   Session type per Decision 0014 (default: standard)
#   --branch NAME         Branch name for task group entries
#   --solo                Enable solo mode (merge to main at close)
#   --push                Enable push_on_complete (push branch after session)
#
# For full lifecycle management (status, edit, remove, review), use queue-cli.sh.
#
# When entries are added, auto-enables the runner in config.yaml.
# Prints entry ID and status to stdout.
#
# Exit codes:
#   0  Entry created successfully
#   1  Validation or operational error

set -euo pipefail

# --- Self-locate and derive repo root ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOMATION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$AUTOMATION_DIR/../.." && pwd)"
LIB_DIR="$SCRIPT_DIR"
CONFIG_FILE="$AUTOMATION_DIR/config.yaml"
CONFIG_LOCAL_FILE="$AUTOMATION_DIR/config.local.yaml"

# --- Source shared helpers ---
# shellcheck source=../../../.claude/hooks/_analytics-helper.sh
source "$REPO_ROOT/.claude/hooks/_analytics-helper.sh"
# shellcheck source=../../../.claude/hooks/_phase-helper.sh
source "$REPO_ROOT/.claude/hooks/_phase-helper.sh"
# shellcheck source=../../../.claude/hooks/_cleanup-helper.sh
source "$REPO_ROOT/.claude/hooks/_cleanup-helper.sh"

# --- Source runner libraries (subset needed for intake) ---
# shellcheck source=branch-manager.sh
source "$LIB_DIR/branch-manager.sh"
# shellcheck source=queue-manager.sh
source "$LIB_DIR/queue-manager.sh"
# shellcheck source=queue-validator.sh
source "$LIB_DIR/queue-validator.sh"
# shellcheck source=work-order-manager.sh
source "$LIB_DIR/work-order-manager.sh"
# shellcheck source=review-log.sh
source "$LIB_DIR/review-log.sh"
# shellcheck source=file-lock.sh
source "$LIB_DIR/file-lock.sh"

# --- Parse arguments ---
BRIEF_PATH=""
AUTO_APPROVE=false
SESSION_TYPE="standard"
BRANCH_NAME=""
SOLO_MODE=false
PUSH_ON_COMPLETE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --brief)
      BRIEF_PATH="$2"
      shift 2
      ;;
    --auto-approve)
      AUTO_APPROVE=true
      shift
      ;;
    --session-type)
      SESSION_TYPE="$2"
      shift 2
      ;;
    --branch)
      BRANCH_NAME="$2"
      shift 2
      ;;
    --solo)
      SOLO_MODE=true
      shift
      ;;
    --push)
      PUSH_ON_COMPLETE=true
      shift
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      echo "Usage: intake.sh --brief <path> [--auto-approve] [--session-type <type>] [--branch <name>] [--solo] [--push]" >&2
      exit 1
      ;;
  esac
done

# --- Validate required arguments ---
if [ -z "$BRIEF_PATH" ]; then
  echo "ERROR: --brief is required" >&2
  echo "Usage: intake.sh --brief <path> [--auto-approve] [--session-type <type>] [--branch <name>] [--solo] [--push]" >&2
  exit 1
fi

# --- Reject shell metacharacters in BRIEF_PATH (injection defense) ---
case "$BRIEF_PATH" in
  *'$'*|*'`'*|*'|'*|*';'*|*'&'*|*'('*|*')'*)
    echo "ERROR: BRIEF_PATH contains shell metacharacters: $BRIEF_PATH" >&2
    exit 1
    ;;
esac

# --- Resolve brief path ---
RESOLVED_BRIEF=""
if [ -f "$BRIEF_PATH" ]; then
  RESOLVED_BRIEF="$BRIEF_PATH"
elif [ -f "$REPO_ROOT/$BRIEF_PATH" ]; then
  RESOLVED_BRIEF="$REPO_ROOT/$BRIEF_PATH"
fi

if [ -z "$RESOLVED_BRIEF" ]; then
  echo "ERROR: Brief file not found: $BRIEF_PATH" >&2
  exit 1
fi

if [ ! -s "$RESOLVED_BRIEF" ]; then
  echo "ERROR: Brief file is empty: $BRIEF_PATH" >&2
  exit 1
fi

# --- Validate session type ---
VALID_PHASES=$(get_phases_for_type "$SESSION_TYPE" 2>/dev/null || true)
if [ -z "$VALID_PHASES" ]; then
  echo "ERROR: Invalid session type: $SESSION_TYPE (not in Decision 0014 enum)" >&2
  exit 1
fi

# --- Validate config file exists ---
if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: Config file not found: $CONFIG_FILE" >&2
  echo "The automation layer must be installed before using intake." >&2
  exit 1
fi

# --- Warn if --branch used with non-taskgroup session type ---
if [ -n "$BRANCH_NAME" ]; then
  case "$SESSION_TYPE" in
    taskgroup|taskgroup-merge) ;;
    *)
      echo "WARNING: --branch is intended for taskgroup/taskgroup-merge sessions (got: $SESSION_TYPE) — branch value will be stored but may be ignored by the runner" >&2
      ;;
  esac
fi

# --- Create queue entry ---
_ensure_queue_dirs

# Acquire queue lock
if ! acquire_queue_lock; then
  echo "ERROR: Queue lock unavailable — another process may be running" >&2
  exit 1
fi

# Determine auto_mode (auto-approve implies auto mode)
AUTO_MODE="false"
if [ "$AUTO_APPROVE" = true ]; then
  AUTO_MODE="true"
fi

# Convert solo/push booleans to string
SOLO_STR="false"
[ "$SOLO_MODE" = true ] && SOLO_STR="true"
PUSH_STR="false"
[ "$PUSH_ON_COMPLETE" = true ] && PUSH_STR="true"

# Enqueue (queue_enqueue returns entry_id on stdout)
ENTRY_ID=$(queue_enqueue "$BRIEF_PATH" "$SESSION_TYPE" "$AUTO_MODE" "$SOLO_STR" "$BRANCH_NAME" "" "$PUSH_STR")

if [ -z "$ENTRY_ID" ]; then
  release_queue_lock
  echo "ERROR: Failed to create queue entry" >&2
  exit 1
fi

# Validate entry against schema (Fix 1: wire validator at intake)
_INTAKE_ENTRY_FILE="$AUTOMATION_DIR/queue/pending-review/${ENTRY_ID}.yaml"
if ! validate_queue_entry "$_INTAKE_ENTRY_FILE"; then
  # Validation failed — remove the entry and abort
  rm -f "$_INTAKE_ENTRY_FILE" 2>/dev/null || true
  release_queue_lock
  echo "ERROR: Queue entry validation failed — entry removed" >&2
  exit 1
fi

# Auto-approve if requested
if [ "$AUTO_APPROVE" = true ]; then
  queue_approve "$ENTRY_ID"
fi

release_queue_lock

# --- Auto-enable runner via local config override (merge-safe) ---
if [ -f "$CONFIG_LOCAL_FILE" ]; then
  if ! grep -q 'enabled: true' "$CONFIG_LOCAL_FILE" 2>/dev/null; then
    if grep -q '^runner:' "$CONFIG_LOCAL_FILE" 2>/dev/null; then
      # runner: block exists — flip enabled: false to true
      sed -i '' '/^runner:/,/^[a-z]/{s/enabled: false/enabled: true/;}' "$CONFIG_LOCAL_FILE"
    else
      # No runner: block — append one
      printf '\nrunner:\n  enabled: true\n' >> "$CONFIG_LOCAL_FILE"
    fi
    echo "Runner auto-enabled in config.local.yaml" >&2
  fi
else
  printf 'runner:\n  enabled: true\n' > "$CONFIG_LOCAL_FILE"
  echo "Runner auto-enabled in config.local.yaml" >&2
fi

# --- Output ---
STATUS="pending-review"
[ "$AUTO_APPROVE" = true ] && STATUS="approved"

echo "entry_id: $ENTRY_ID"
echo "status: $STATUS"
echo "session_type: $SESSION_TYPE"
echo "brief_path: $BRIEF_PATH"
echo "solo_mode: $SOLO_STR"
echo "push_on_complete: $PUSH_STR"
