#!/usr/bin/env bash
# PermissionRequest hook — auto-approve curated tools/commands, deny dangerous ones.
# Wired to PermissionRequest event via .claude/settings.json.
# Decision 0017 — Operator Automation Layer.
#
# Fires when Claude Code is about to show a permission dialog. This hook
# answers on behalf of the user for known-safe and known-dangerous patterns.
# Unknown commands fall through to the normal permission dialog.
#
# Decision flow:
#   1. Non-Bash tool in allow list → auto-approve
#   2. Bash command in deny list → deny with reason
#   3. Bash command in allow list → auto-approve
#   4. Anything else → fall through (exit 0, no JSON = show dialog)
#
# Every request is logged to the audit log (append-only, gitignored).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_analytics-helper.sh"
source "$SCRIPT_DIR/_permission-allowlist.sh"
START_MS=$(now_ms)

REPO_ROOT="$(get_repo_root)"
AUDIT_LOG="$REPO_ROOT/.claude/.automation/logs/permission-audit.log"

# --- Read PermissionRequest payload from stdin ---
INPUT=$(cat)

# --- jq presence guard ---
if [ "$_REPO_OS_HAS_JQ" = false ]; then
  # Without jq, fall through to dialog (fail-open for usability)
  exit 0
fi

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
TOOL_COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)

# --- Audit log helper ---
# Append-only log of every permission decision. Gitignored (runtime artifact).
# Format: ISO-timestamp | tool | command-prefix | decision
_log_audit() {
  local decision="$1"
  local detail="${2:-}"
  mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null || true
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # Truncate command to first 120 chars for audit readability
  local cmd_prefix="${TOOL_COMMAND:0:120}"
  printf '%s | %s | %s | %s | %s\n' "$ts" "$TOOL_NAME" "$cmd_prefix" "$decision" "$detail" \
    >> "$AUDIT_LOG" 2>/dev/null || true
}

# --- Decision: approve helper ---
_approve() {
  local reason="$1"
  _log_audit "allow" "$reason"
  log_hook_event "permission-request" "PermissionRequest" "$TOOL_NAME" "allow" "$START_MS" "$reason"
  printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}\n'
  exit 0
}

# --- Decision: deny helper ---
_deny() {
  local reason="$1"
  _log_audit "deny" "$reason"
  log_hook_event "permission-request" "PermissionRequest" "$TOOL_NAME" "block" "$START_MS" "$reason"
  # Sanitize reason for JSON embedding (escape backslashes, then double quotes)
  local safe_reason="${reason//\\/\\\\}"
  safe_reason="${safe_reason//\"/\\\"}"
  printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Blocked by permission hook: %s"}}}\n' "$safe_reason"
  exit 0
}

# --- Decision: fall through (show dialog) ---
_fall_through() {
  local reason="$1"
  _log_audit "dialog" "$reason"
  log_hook_event "permission-request" "PermissionRequest" "$TOOL_NAME" "dialog" "$START_MS" "fall_through:$reason"
  exit 0
}

# ============================================================
# Decision Logic
# ============================================================

# Empty tool name — can't classify, fall through
if [ -z "$TOOL_NAME" ]; then
  _fall_through "empty_tool_name"
fi

# Non-Bash tools: check allow list
if [ "$TOOL_NAME" != "Bash" ]; then
  if is_tool_allowed "$TOOL_NAME"; then
    _approve "tool_allowlist"
  fi
  _fall_through "tool_unknown:$TOOL_NAME"
fi

# Bash commands: deny list first (takes priority)
if [ -n "$TOOL_COMMAND" ]; then
  if is_bash_denied "$TOOL_COMMAND"; then
    _deny "$_DENY_REASON"
  fi

  # Then check allow list
  if is_bash_allowed "$TOOL_COMMAND"; then
    _approve "bash_allowlist"
  fi
fi

# Unknown Bash command — fall through to dialog
_fall_through "bash_unknown"
