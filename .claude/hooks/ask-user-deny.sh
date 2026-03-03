#!/usr/bin/env bash
# Ask-user deny — blocks AskUserQuestion in headless automation mode.
# Wired to PreToolUse on AskUserQuestion via .claude/settings.json.
# When CLAUDE_HEADLESS=1 (set by runner.sh), denies with exit 2.
# Otherwise passes through (exit 0) for interactive sessions.
#
# Defense-in-depth: the build permission profile also blocks
# AskUserQuestion via --disallowedTools. This hook catches cases
# where a non-build profile is used or the disallow list is omitted.

set -euo pipefail

# Fast-exit for interactive sessions (no headless env var)
if [ "${CLAUDE_HEADLESS:-0}" != "1" ]; then
  exit 0
fi

# Headless mode — consume stdin (required by hook protocol) and deny
cat > /dev/null

echo "BLOCKED: AskUserQuestion is not available in headless automation mode. Proceed with best judgment per the task brief. If genuinely blocked, write an escalation file to .claude/.automation/escalations/." >&2
exit 2
