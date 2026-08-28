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

# --- jq presence guard (fail-open for push gate — B1 uses git, not jq) ---
# jq is used only for self-filter payload parsing below.
# If absent, skip self-filter (fail-open) so B1 branch-naming still runs.
_PUSH_HAS_JQ=false
if command -v jq &>/dev/null; then
  _PUSH_HAS_JQ=true
fi

# --- Read hook payload (PreToolUse JSON on stdin) ---
INPUT=$(cat)

# --- Harness session_id plumbing ---
export _REPO_OS_STDIN_SID
if [ "$_PUSH_HAS_JQ" = true ]; then
  _REPO_OS_STDIN_SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
fi

PUSH_CMD=""
if [ "$_PUSH_HAS_JQ" = true ]; then
  PUSH_CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
fi

# --- Self-filter: skip gate chain for non-push commands ---
# The matcher is now "Bash" (fires on every Bash call); only run B1 when the
# command is actually a git push. Permissive: cd ... && git push, git -C . push.
if [ "$_PUSH_HAS_JQ" = true ]; then
  case "$PUSH_CMD" in
    *"git push"*) ;;
    *) exit 0 ;;
  esac
fi

FAILED=0

# --- REPO_OS_RECOVER override (env var or file-based signal) ---
RECOVER_SIGNAL_FILE="$(get_repo_root)/.claude/.state/.recover-signal"
if [ "${REPO_OS_RECOVER:-0}" = "1" ]; then
  log_override "pre-push-gates" "REPO_OS_RECOVER"
  echo "REPO_OS_RECOVER=1 — skipping all push gate checks" >&2
  log_hook_event "pre-push-gates" "PreToolUse" "Bash" "allow" "$START_MS" "recover_override"
  exit 0
elif [ -f "$RECOVER_SIGNAL_FILE" ]; then
  log_override "pre-push-gates" "recover-signal-file"
  rm -f "$RECOVER_SIGNAL_FILE"
  echo "Recovery signal consumed — skipping all push gate checks" >&2
  log_hook_event "pre-push-gates" "PreToolUse" "Bash" "allow" "$START_MS" "recover_signal_file"
  exit 0
fi

# ============================================================
# B1: Process — Branch Naming Convention (blocking)
# ============================================================
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
# live-editor-N uses anchored alternation (digits only) so 'live-editor-foo' is rejected.
VALID_PATTERNS="^(main|feature/.+|fix/.+|hotfix/.+|release/.+|experiment/.+|live-editor-[0-9]+)$"

if [ -n "$CURRENT_BRANCH" ] && [ "$CURRENT_BRANCH" != "main" ]; then
  if [[ ! "$CURRENT_BRANCH" =~ $VALID_PATTERNS ]]; then
    echo "GATE B1 FAILED: Branch '$CURRENT_BRANCH' — expected: <category>/<description> or live-editor-N" >&2
    echo "  Valid categories: feature/, fix/, hotfix/, release/, experiment/, live-editor-N (digits only)" >&2
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
  exit 2
fi

log_hook_event "pre-push-gates" "PreToolUse" "Bash" "allow" "$START_MS" "pass"
