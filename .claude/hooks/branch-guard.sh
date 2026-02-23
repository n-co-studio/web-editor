#!/usr/bin/env bash
# Branch guard — blocks file modifications on main.
# Wired to PreToolUse on Edit and Write via .claude/settings.json.
# Catches work on the wrong branch BEFORE any files are changed,
# rather than at commit time when all the work is already done.
# Override: REPO_OS_ALLOW_MAIN=1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_analytics-helper.sh"
START_MS=$(now_ms)

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

if [ "$CURRENT_BRANCH" = "main" ] && [ "${REPO_OS_ALLOW_MAIN:-0}" != "1" ]; then
  log_hook_event "branch-guard" "PreToolUse" "" "block" "$START_MS" "main_branch"
  echo "BLOCKED: On main — run: git checkout -b feature/<description> (override: REPO_OS_ALLOW_MAIN=1)" >&2
  exit 2
fi

log_hook_event "branch-guard" "PreToolUse" "" "allow" "$START_MS" "not_main"
