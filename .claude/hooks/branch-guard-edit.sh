#!/usr/bin/env bash
# Branch guard (Edit/Write) — slim gate for file modifications.
# Wired to PreToolUse on Edit and Write via .claude/settings.json.
#
# Gate 1: Main branch protection — blocks edits on main.
# Gate 5: Session branch isolation (Decision 0013) — blocks edits on
#          branches closed by a previous session. Task groups exempt.
#
# Gates 2-4 (plan approval, governance advisory, phase chain) are enforced
# at commit-time via pre-commit-gates.sh. The full branch-guard.sh retains
# all 5 gates for the Bash matcher.
#
# Override: REPO_OS_ALLOW_MAIN=1 (Gate 1), REPO_OS_SKIP_BRANCH_REUSE=1 (Gate 5)
#           REPO_OS_RECOVER=1 (bypass all gates — emergency recovery)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_analytics-helper.sh"
START_MS=$(now_ms)

REPO_ROOT="$(get_repo_root)"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

# --- REPO_OS_RECOVER override ---
if [ "${REPO_OS_RECOVER:-0}" = "1" ]; then
  log_override "branch-guard-edit" "REPO_OS_RECOVER"
  log_hook_event "branch-guard-edit" "PreToolUse" "" "allow" "$START_MS" "recovery_bypass"
  exit 0
fi

ALLOW_REASON="pass"

# --- Gate 1: Main branch protection ---
if [ "$CURRENT_BRANCH" = "main" ] && [ "${REPO_OS_ALLOW_MAIN:-0}" != "1" ]; then
  log_hook_event "branch-guard-edit" "PreToolUse" "" "block" "$START_MS" "main_branch"
  echo "BLOCKED: On main — run: git checkout -b feature/<description> (override: REPO_OS_ALLOW_MAIN=1)" >&2
  exit 2
fi
if [ "$CURRENT_BRANCH" = "main" ] && [ "${REPO_OS_ALLOW_MAIN:-0}" = "1" ]; then
  log_override "branch-guard-edit" "REPO_OS_ALLOW_MAIN"
  ALLOW_REASON="main_override"
fi

# --- Gate 5: Session branch isolation (blocking, Decision 0013) ---
CLOSED_BRANCHES_FILE="$REPO_ROOT/.claude/local/closed-branches"

if [ -f "$CLOSED_BRANCHES_FILE" ] && grep -qxF "$CURRENT_BRANCH" "$CLOSED_BRANCHES_FILE" 2>/dev/null; then
  # Task group exemption: if any contract has pending briefs, allow
  TASK_GROUP_EXEMPT=false

  REPO_MODE_FILE="$REPO_ROOT/.claude/repo-mode"
  if [ -f "$REPO_MODE_FILE" ] && grep -q "template" "$REPO_MODE_FILE" 2>/dev/null; then
    CONTRACT_DIR="$REPO_ROOT/.claude/local/task-groups"
  else
    CONTRACT_DIR="$REPO_ROOT/docs/ai/task-groups"
  fi

  if [ -d "$CONTRACT_DIR" ]; then
    for CONTRACT in "$CONTRACT_DIR"/*.yaml; do
      [ -f "$CONTRACT" ] || continue
      [ "$(basename "$CONTRACT")" = "_contract-template.yaml" ] && continue
      if grep -q "status: pending" "$CONTRACT" 2>/dev/null; then
        TASK_GROUP_EXEMPT=true
        break
      fi
    done
  fi

  if [ "${REPO_OS_SKIP_BRANCH_REUSE:-0}" = "1" ]; then
    log_override "branch-guard-edit" "REPO_OS_SKIP_BRANCH_REUSE"
    ALLOW_REASON="branch_reuse_override"
  elif [ "$TASK_GROUP_EXEMPT" = true ]; then
    ALLOW_REASON="task_group_exempt"
  else
    log_hook_event "branch-guard-edit" "PreToolUse" "" "block" "$START_MS" "branch_reused"
    echo "BLOCKED: Branch '$CURRENT_BRANCH' was used by a previous session — create a new branch: git checkout -b <category>/<description> (override: REPO_OS_SKIP_BRANCH_REUSE=1)" >&2
    exit 2
  fi
fi

log_hook_event "branch-guard-edit" "PreToolUse" "" "allow" "$START_MS" "$ALLOW_REASON"
