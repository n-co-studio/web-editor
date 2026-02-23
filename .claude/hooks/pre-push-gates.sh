#!/usr/bin/env bash
# Pre-push gate verification (B-gates)
# Runs automatically before git push via .claude/settings.json hook.
# Exit non-zero to block the push.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_analytics-helper.sh"
START_MS=$(now_ms)

FAILED=0
B1_WARN=false

# --- B1: Process — Branch Naming Convention ---
# Warn if branch name doesn't match expected categories.
# Advisory — does not block, but prints a warning.

CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
VALID_PATTERNS="^(main|feature/|fix/|hotfix/|release/|experiment/).+$"

if [ -n "$CURRENT_BRANCH" ] && [ "$CURRENT_BRANCH" != "main" ]; then
  if [[ ! "$CURRENT_BRANCH" =~ $VALID_PATTERNS ]]; then
    B1_WARN=true
    echo "GATE B1 WARNING: Branch '$CURRENT_BRANCH' — expected: <category>/<description>" >&2
  fi
fi

# --- Project-Specific Push Checks ---
# Add project-specific push gate checks below. Examples:
#
# # B2: Quality — Tests
# if command -v npx &>/dev/null && [ -f package.json ]; then
#   npx jest --ci || { echo "GATE B2 FAILED: Tests failing"; FAILED=1; }
# fi
#
# # B2: Quality — Typecheck
# if command -v npx &>/dev/null && [ -f tsconfig.json ]; then
#   npx tsc --noEmit || { echo "GATE B2 FAILED: Type errors"; FAILED=1; }
# fi
#
# # B3: Safety — Dependency Audit
# if git diff HEAD~1 --name-only 2>/dev/null | grep -qE 'package-lock\.json|yarn\.lock'; then
#   npm audit --audit-level=high || { echo "GATE B3 FAILED: Dependency vulnerabilities"; FAILED=1; }
# fi

if [ "$FAILED" -ne 0 ]; then
  log_hook_event "pre-push-gates" "PreToolUse" "Bash" "block" "$START_MS" "push_gate_failed"
  echo "Push blocked by pre-push gate check." >&2
  exit 1
fi

REASON="pass"
[ "$B1_WARN" = true ] && REASON="B1_naming_warning"
log_hook_event "pre-push-gates" "PreToolUse" "Bash" "allow" "$START_MS" "$REASON"
