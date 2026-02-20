#!/usr/bin/env bash
# Pre-commit gate verification (A4 Safety + A2 Process)
# Runs automatically before git commit via .claude/settings.json hook.
# Exit non-zero to block the commit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_analytics-helper.sh"
START_MS=$(date +%s%3N 2>/dev/null || date +%s)

FAILED=0
A2_WARN=false

# --- A4: Safety — Secret Scanning ---
# Scan staged files for common secret patterns (single-pass grep).
# Patterns sourced from security-privacy agent definitions.

SECRET_PATTERN='sk_live_|sk_test_|ghp_[A-Za-z0-9]|AKIA[A-Z0-9]|AIza[A-Za-z0-9]|-----BEGIN.*PRIVATE KEY-----|password\s*=\s*["\x27][^"\x27]|secret\s*=\s*["\x27][^"\x27]|token\s*=\s*["\x27][^"\x27]'

STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)

if [ -n "$STAGED_FILES" ]; then
  MATCHES=$(echo "$STAGED_FILES" | xargs grep -lE "$SECRET_PATTERN" 2>/dev/null || true)
  if [ -n "$MATCHES" ]; then
    echo "GATE A4 FAILED: Possible secret in: $MATCHES" >&2
    FAILED=1
  fi
fi

# --- Branch Protection ---
# Moved to branch-guard.sh (PreToolUse on Edit/Write) so it fires
# before any work is done, not at commit time.

# --- A2: Process — Scope Check ---
# Warn if staged changes exceed small scope threshold (100 lines).
# This is advisory — does not block, but prints a warning.

if [ -n "$STAGED_FILES" ]; then
  LINES_CHANGED=$(git diff --cached --numstat | awk '{s+=$1+$2} END {print s+0}')
  if [ "$LINES_CHANGED" -gt 100 ]; then
    A2_WARN=true
    echo "GATE A2 WARNING: $LINES_CHANGED lines changed — exceeds 100-line threshold. Ensure operator approved." >&2
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
  log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "A4_secret_detected"
  echo "Commit blocked by pre-commit gate check." >&2
  exit 1
fi

REASON="pass"
[ "$A2_WARN" = true ] && REASON="A2_scope_warning"
log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "allow" "$START_MS" "$REASON"
