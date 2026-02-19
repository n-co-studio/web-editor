#!/usr/bin/env bash
# Pre-push gate verification (B-gates)
# Runs automatically before git push via .claude/settings.json hook.
# Exit non-zero to block the push.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
FAILED=0

# --- B1: Process — Branch Naming Convention ---
# Warn if branch name doesn't match expected categories.
# Advisory — does not block, but prints a warning.

CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
VALID_PATTERNS="^(main|feature/|fix/|hotfix/|release/|experiment/).+$"

if [ -n "$CURRENT_BRANCH" ] && [ "$CURRENT_BRANCH" != "main" ]; then
  if ! echo "$CURRENT_BRANCH" | grep -qE "$VALID_PATTERNS"; then
    echo "GATE B1 WARNING: Branch '$CURRENT_BRANCH' does not match naming convention."
    echo "  Expected: <category>/<short-description> (feature/, fix/, hotfix/, release/, experiment/)"
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
  echo ""
  echo "Push blocked by pre-push gate check."
  exit 1
fi
