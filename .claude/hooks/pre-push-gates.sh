#!/usr/bin/env bash
# Pre-push gate verification — blocking enforcement.
# Runs automatically before git push via .claude/settings.json hook.
# Exit non-zero to block the push.
#
# Gates enforced:
#   B1  Process — branch naming convention (blocking)
#
# Overrides:
#   REPO_OS_RECOVER=1 — skip all checks (emergency recovery)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_analytics-helper.sh"
START_MS=$(now_ms)

FAILED=0

# --- REPO_OS_RECOVER override ---
if [ "${REPO_OS_RECOVER:-0}" = "1" ]; then
  log_override "pre-push-gates" "REPO_OS_RECOVER"
  echo "REPO_OS_RECOVER=1 — skipping all push gate checks" >&2
  log_hook_event "pre-push-gates" "PreToolUse" "Bash" "allow" "$START_MS" "recover_override"
  exit 0
fi

# ============================================================
# B1: Process — Branch Naming Convention (blocking)
# ============================================================
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
VALID_PATTERNS="^(main|feature/|fix/|hotfix/|release/|experiment/).+$"

if [ -n "$CURRENT_BRANCH" ] && [ "$CURRENT_BRANCH" != "main" ]; then
  if [[ ! "$CURRENT_BRANCH" =~ $VALID_PATTERNS ]]; then
    echo "GATE B1 FAILED: Branch '$CURRENT_BRANCH' — expected: <category>/<description>" >&2
    echo "  Valid categories: feature/, fix/, hotfix/, release/, experiment/" >&2
    FAILED=1
  fi
fi

# ============================================================
# Project-Specific Push Checks
# ============================================================
# Uncomment and adapt for your project. Each check blocks on failure.
#
# # B2: Quality — Tests
# if command -v npx &>/dev/null && [ -f package.json ]; then
#   npx jest --ci || { echo "GATE B2 FAILED: Tests failing" >&2; FAILED=1; }
# fi
#
# # B2: Quality — Typecheck
# if command -v npx &>/dev/null && [ -f tsconfig.json ]; then
#   npx tsc --noEmit || { echo "GATE B2 FAILED: Type errors" >&2; FAILED=1; }
# fi
#
# # B3: Safety — Dependency Audit
# if git diff HEAD~1 --name-only 2>/dev/null | grep -qE 'package-lock\.json|yarn\.lock'; then
#   npm audit --audit-level=high || { echo "GATE B3 FAILED: Dependency vulnerabilities" >&2; FAILED=1; }
# fi

# ============================================================
# Final exit
# ============================================================
if [ "$FAILED" -ne 0 ]; then
  log_hook_event "pre-push-gates" "PreToolUse" "Bash" "block" "$START_MS" "B1_naming_violation" "branch:$CURRENT_BRANCH"
  echo "Push blocked by pre-push gate check." >&2
  exit 1
fi

log_hook_event "pre-push-gates" "PreToolUse" "Bash" "allow" "$START_MS" "pass"
