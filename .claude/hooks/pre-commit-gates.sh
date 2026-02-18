#!/usr/bin/env bash
# Pre-commit gate verification (A4 Safety + A2 Process)
# Runs automatically before git commit via .claude/settings.json hook.
# Exit non-zero to block the commit.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
FAILED=0

# --- A4: Safety — Secret Scanning ---
# Scan staged files for common secret patterns.
# Patterns sourced from security-privacy agent definitions.

SECRET_PATTERNS=(
  'sk_live_'
  'sk_test_'
  'ghp_[A-Za-z0-9]'
  'AKIA[A-Z0-9]'
  'AIza[A-Za-z0-9]'
  '-----BEGIN.*PRIVATE KEY-----'
  'password\s*=\s*["\x27][^"\x27]'
  'secret\s*=\s*["\x27][^"\x27]'
  'token\s*=\s*["\x27][^"\x27]'
)

STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)

if [ -n "$STAGED_FILES" ]; then
  for pattern in "${SECRET_PATTERNS[@]}"; do
    MATCHES=$(echo "$STAGED_FILES" | xargs grep -lE "$pattern" 2>/dev/null || true)
    if [ -n "$MATCHES" ]; then
      echo "GATE A4 FAILED: Possible secret detected (pattern: $pattern)"
      echo "  Files: $MATCHES"
      FAILED=1
    fi
  done
fi

# --- A2: Process — Scope Check ---
# Warn if staged changes exceed small scope threshold (100 lines).
# This is advisory — does not block, but prints a warning.

if [ -n "$STAGED_FILES" ]; then
  LINES_CHANGED=$(git diff --cached --stat | tail -1 | grep -oE '[0-9]+ insertion|[0-9]+ deletion' | grep -oE '[0-9]+' | paste -sd+ - | bc 2>/dev/null || echo "0")
  if [ "$LINES_CHANGED" -gt 100 ]; then
    echo "GATE A2 WARNING: $LINES_CHANGED lines changed — exceeds small scope threshold (100)."
    echo "  Ensure operator approved larger scope and rationale is documented."
  fi
fi

# --- Project-Specific Checks ---
# Add project-specific gate checks below. Examples:
#
# # A3: Quality — Lint
# if command -v npx &>/dev/null && [ -f package.json ]; then
#   npx eslint --quiet . || { echo "GATE A3 FAILED: Lint errors"; FAILED=1; }
# fi
#
# # A3: Quality — Format
# if command -v npx &>/dev/null && [ -f package.json ]; then
#   npx prettier --check . || { echo "GATE A3 FAILED: Formatting errors"; FAILED=1; }
# fi

if [ "$FAILED" -ne 0 ]; then
  echo ""
  echo "Commit blocked by pre-commit gate check."
  exit 1
fi
