#!/usr/bin/env bash
# Blocks git commit and git push for non-orchestrator subagents.
# Used via frontmatter hooks in Builder, QA, and Security agents.
# Exit 2 = block the tool call.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_analytics-helper.sh"
START_MS=$(now_ms)

INPUT=$(cat)

# --- Harness session_id plumbing (must precede first get_session_id call) ---
export _REPO_OS_STDIN_SID
_REPO_OS_STDIN_SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"

# --- jq presence guard (fail-closed) ---
if [ "$_REPO_OS_HAS_JQ" = false ]; then
  echo "GATE-FINAL: jq is required for agent-git-guard but was not found. Install jq (https://jqlang.github.io/jq/download/) and retry. (no override)" >&2
  exit 2
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

if [[ "$COMMAND" =~ ^[[:space:]]*git[[:space:]]+(commit|push) ]]; then
  log_hook_event "agent-git-guard" "PreToolUse" "Bash" "block" "$START_MS" "subagent_git_blocked"
  echo "GATE-FINAL: Subagent cannot git commit/push — return to Orchestrator. (no override)" >&2
  exit 2
fi

log_hook_event "agent-git-guard" "PreToolUse" "Bash" "allow" "$START_MS" "not_git_commit_push"
exit 0
