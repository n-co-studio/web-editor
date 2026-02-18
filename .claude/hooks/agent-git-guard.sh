#!/usr/bin/env bash
# Blocks git commit and git push for non-orchestrator subagents.
# Used via frontmatter hooks in Builder, QA, and Security agents.
# Exit 2 = block the tool call.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

if echo "$COMMAND" | grep -qE '^\s*git\s+(commit|push)\b'; then
  echo "BLOCKED: This agent cannot run git commit or git push." >&2
  echo "  Return control to the Orchestrator for commit/push operations." >&2
  exit 2
fi

exit 0
