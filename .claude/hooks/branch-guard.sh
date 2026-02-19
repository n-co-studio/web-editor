#!/usr/bin/env bash
# Branch guard — blocks file modifications on main.
# Wired to PreToolUse on Edit and Write via .claude/settings.json.
# Catches work on the wrong branch BEFORE any files are changed,
# rather than at commit time when all the work is already done.
# Override: REPO_OS_ALLOW_MAIN=1

set -euo pipefail

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

if [ "$CURRENT_BRANCH" = "main" ] && [ "${REPO_OS_ALLOW_MAIN:-0}" != "1" ]; then
  echo "BLOCKED: You are on main. Create a branch before making changes."
  echo "  git checkout -b feature/<description>"
  echo "  Override: REPO_OS_ALLOW_MAIN=1"
  exit 2
fi
