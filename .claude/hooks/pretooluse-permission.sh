#!/usr/bin/env bash
# PreToolUse permission hook — headless-compatible permission control.
# Wired to PreToolUse Bash event via .claude/settings.json.
# Decision 0017 — Operator Automation Layer.
#
# This hook fires for EVERY Bash tool call (both interactive and headless).
# Unlike PermissionRequest, PreToolUse fires in claude -p mode, making it
# the primary permission gate for headless automation sessions.
#
# Decision flow:
#   1. Non-Bash tools: if in allow list → allow; otherwise exit 0 (pass through)
#   2. Bash deny list check (priority) → block with reason
#   3. Bash allow list check → allow
#   4. If CLAUDE_HEADLESS=1 → block (fail-closed — no dialog available)
#   5. If interactive → exit 0 (pass through to existing permission dialog)
#
# Structured JSON output:
#   Allow: {"decision":"allow"}
#   Block: {"decision":"block","reason":"..."}
#   Pass:  exit 0 with no output (hook pass-through)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_permission-allowlist.sh"
source "$SCRIPT_DIR/_analytics-helper.sh"
START_MS=$(now_ms)

# --- Read PreToolUse payload from stdin ---
INPUT=$(cat)

# --- jq presence guard ---
if [ "$_REPO_OS_HAS_JQ" = false ]; then
  if [ "${CLAUDE_HEADLESS:-0}" = "1" ]; then
    # Headless: fail-closed — no dialog fallback, jq required for payload parsing
    echo "GATE-FINAL: jq not found — required for PreToolUse permission parsing in headless mode." >&2
    exit 2
  fi
  # Interactive: fail-open (dialog is a safe fallback)
  exit 0
fi

# Single jq invocation for both fields (halves subprocess count)
_ptl_jq_out=$(echo "$INPUT" | jq -r '[.tool_name // "", .tool_input.command // ""] | join("\t")' 2>/dev/null || true)
TOOL_NAME="${_ptl_jq_out%%	*}"
TOOL_COMMAND="${_ptl_jq_out#*	}"

# --- Decision helpers ---
_ptl_allow() {
  local reason="$1"
  log_hook_event "pretooluse-permission" "PreToolUse" "$TOOL_NAME" "allow" "$START_MS" "$reason"
  printf '{"decision":"allow"}\n'
  exit 0
}

_ptl_block() {
  local reason="$1"
  log_hook_event "pretooluse-permission" "PreToolUse" "$TOOL_NAME" "block" "$START_MS" "$reason"
  local safe_reason="${reason//\\/\\\\}"
  safe_reason="${safe_reason//\"/\\\"}"
  printf '{"decision":"block","reason":"Blocked by PreToolUse permission hook: %s"}\n' "$safe_reason"
  exit 0
}

# ============================================================
# Decision Logic
# ============================================================

# Empty tool name — pass through
if [ -z "$TOOL_NAME" ]; then
  exit 0
fi

# --- Agent tool: session-type-aware gate (Decision 0027) ---
if [ "$TOOL_NAME" = "Agent" ]; then
  source "$SCRIPT_DIR/_phase-helper.sh"

  # Override: REPO_OS_ALLOW_AGENT=1 bypasses the gate
  if [ "${REPO_OS_ALLOW_AGENT:-0}" = "1" ]; then
    log_override "agent-gate" "REPO_OS_ALLOW_AGENT"
    _ptl_allow "agent_override"
  fi

  # Fail-closed: no phase-state means no Agent tool
  AGENT_SESSION_TYPE=$(get_session_type)
  if [ -z "$AGENT_SESSION_TYPE" ]; then
    _ptl_block "GATE-FINAL: Agent tool blocked — no phase-state (fail-closed). Initialize the session first. (override: REPO_OS_ALLOW_AGENT=1)"
  fi

  # No-write session types: only read-only agents permitted
  case "$AGENT_SESSION_TYPE" in
    taskdef-query|taskdef-brief|audit|ephemeral|queue-triage|advisory-init|advisory-reinit|spec-fresh|spec-update)
      AGENT_SUBTYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null || true)
      if [ -z "$AGENT_SUBTYPE" ]; then
        _ptl_block "GATE-FINAL: Agent tool blocked — no subagent_type specified in $AGENT_SESSION_TYPE session. Only named read-only agents are permitted. (override: REPO_OS_ALLOW_AGENT=1)"
      fi
      if is_readonly_agent "$AGENT_SUBTYPE"; then
        _ptl_allow "agent_readonly_allowlist"
      fi
      _ptl_block "GATE-FINAL: Agent tool blocked — subagent type '$AGENT_SUBTYPE' not permitted in $AGENT_SESSION_TYPE session. (override: REPO_OS_ALLOW_AGENT=1)"
      ;;
    *)
      # Write-capable session types (standard, taskgroup, etc.): allow all agents
      _ptl_allow "agent_write_session"
      ;;
  esac
fi

# Non-Bash tools: check allow list, otherwise pass through
if [ "$TOOL_NAME" != "Bash" ]; then
  if is_tool_allowed "$TOOL_NAME"; then
    _ptl_allow "tool_allowlist"
  fi
  # Non-Bash unknown tools — pass through (other hooks may handle)
  exit 0
fi

# Bash commands: deny list FIRST (takes priority)
if [ -n "$TOOL_COMMAND" ]; then
  if is_bash_denied "$TOOL_COMMAND"; then
    _ptl_block "$_DENY_REASON"
  fi

  # Then check allow list
  if is_bash_allowed "$TOOL_COMMAND"; then
    _ptl_allow "bash_allowlist"
  fi
fi

# Unknown Bash command — decision depends on mode
if [ "${CLAUDE_HEADLESS:-0}" = "1" ]; then
  # Headless: fail-closed — no interactive dialog available
  _ptl_block "headless_unknown_command"
fi

# Interactive: pass through (falls to permission dialog or other hooks)
exit 0
