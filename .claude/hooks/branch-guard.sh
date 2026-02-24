#!/usr/bin/env bash
# Branch guard — blocks file modifications on main and without plan approval.
# Wired to PreToolUse on Edit and Write via .claude/settings.json.
#
# Gate 1: Catches work on the wrong branch BEFORE any files are changed,
#          rather than at commit time when all the work is already done.
# Gate 2: Enforces plan-before-code rule via plan-approved state file.
#          Experiment branches exempt (Decision 0006).
# Gate 3: Inter-session governance file check (advisory, first-fire).
#          Warns if docs/ai/governance/spec-compiled or advisory-reviewed missing.
# Gate 4: Phase chain verification (advisory, first-fire).
#          For task groups: warns if prior brief lacks governance evidence.
#
# Override: REPO_OS_ALLOW_MAIN=1 (main gate), REPO_OS_SKIP_PLAN_GATE=1 (plan gate)
#           REPO_OS_RECOVER=1 (bypass all gates — emergency recovery)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_analytics-helper.sh"
START_MS=$(now_ms)

REPO_ROOT="$(get_repo_root)"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

# --- REPO_OS_RECOVER override ---
if [ "${REPO_OS_RECOVER:-0}" = "1" ]; then
  log_override "branch-guard" "REPO_OS_RECOVER"
  log_hook_event "branch-guard" "PreToolUse" "" "allow" "$START_MS" "recovery_bypass"
  echo "REPO_OS_RECOVER=1 — bypassing branch-guard gates" >&2
  exit 0
fi

# --- Gate 1: Main branch protection ---
if [ "$CURRENT_BRANCH" = "main" ] && [ "${REPO_OS_ALLOW_MAIN:-0}" != "1" ]; then
  log_hook_event "branch-guard" "PreToolUse" "" "block" "$START_MS" "main_branch"
  echo "BLOCKED: On main — run: git checkout -b feature/<description> (override: REPO_OS_ALLOW_MAIN=1)" >&2
  exit 2
fi
if [ "$CURRENT_BRANCH" = "main" ] && [ "${REPO_OS_ALLOW_MAIN:-0}" = "1" ]; then
  log_override "branch-guard" "REPO_OS_ALLOW_MAIN"
fi

# --- Gate 2: Plan approval ---
# Blocks Edit/Write if no approved plan exists.
# Exempt: experiment/* branches (Decision 0006).
# Override: REPO_OS_SKIP_PLAN_GATE=1 (logs override).
ALLOW_REASON="pass"

if [[ "$CURRENT_BRANCH" == experiment/* ]]; then
  ALLOW_REASON="experiment_branch"
elif [ "${REPO_OS_SKIP_PLAN_GATE:-0}" = "1" ]; then
  log_override "branch-guard" "REPO_OS_SKIP_PLAN_GATE"
  ALLOW_REASON="plan_gate_override"
elif [ ! -f "$REPO_ROOT/.claude/.state/plan-approved" ]; then
  log_hook_event "branch-guard" "PreToolUse" "" "block" "$START_MS" "no_plan_approved"
  echo "BLOCKED: No approved plan — get operator approval before editing files. (override: REPO_OS_SKIP_PLAN_GATE=1)" >&2
  exit 2
fi

# --- Gate 3: Inter-session governance (advisory, first-fire) ---
# Checks that Prompt 0 (spec-compiled) and Prompt A (advisory-reviewed)
# governance files exist before Prompt B work begins.
# Non-blocking: prints warnings, does not exit 2.
GOVERNANCE_CHECKED_FILE="$REPO_ROOT/.claude/.state/governance-checked"

if [ ! -f "$GOVERNANCE_CHECKED_FILE" ]; then
  GOV_DIR="$REPO_ROOT/docs/ai/governance"
  GOV_WARNINGS=""

  case "$CURRENT_BRANCH" in
    feature/*|fix/*|hotfix/*|release/*)
      if [ ! -f "$GOV_DIR/spec-compiled" ]; then
        GOV_WARNINGS="${GOV_WARNINGS}Advisory: docs/ai/governance/spec-compiled not found — Prompt 0 may not have completed governance write.\n"
      fi
      if [ ! -f "$GOV_DIR/advisory-reviewed" ]; then
        GOV_WARNINGS="${GOV_WARNINGS}Advisory: docs/ai/governance/advisory-reviewed not found — Prompt A may not have completed governance write.\n"
      fi
      ;;
  esac

  if [ -n "$GOV_WARNINGS" ]; then
    printf '%b' "$GOV_WARNINGS" >&2
  fi

  # Write first-fire marker (shell I/O — not blocked by state-guard)
  mkdir -p "$REPO_ROOT/.claude/.state" 2>/dev/null || true
  echo "checked" > "$GOVERNANCE_CHECKED_FILE" 2>/dev/null || true
fi

# --- Gate 4: Phase chain verification (advisory, first-fire) ---
# For task group sessions: verifies the previous brief completed with
# governance evidence in the contract.
# Non-blocking: prints warning if prior brief lacks governance entry.
PHASE_CHECKED_FILE="$REPO_ROOT/.claude/.state/phase-chain-checked"

if [ ! -f "$PHASE_CHECKED_FILE" ]; then
  CONTRACT_DIR="$REPO_ROOT/docs/ai/task-groups"

  if [ -d "$CONTRACT_DIR" ]; then
    for CONTRACT in "$CONTRACT_DIR"/*.yaml; do
      [ -f "$CONTRACT" ] || continue
      [ "$(basename "$CONTRACT")" = "_contract-template.yaml" ] && continue

      # Find the pending brief (next to be worked on) — sequence number
      PENDING_SEQ=$(grep -B1 "status: pending" "$CONTRACT" 2>/dev/null \
        | grep "sequence:" | sed 's/.*sequence: *//' | head -1 || true)

      if [ -n "$PENDING_SEQ" ] && [ "$PENDING_SEQ" -gt 1 ] 2>/dev/null; then
        PREV_SEQ=$((PENDING_SEQ - 1))
        # Check if governance entry exists for previous brief
        if ! grep -q "brief_sequence: $PREV_SEQ" "$CONTRACT" 2>/dev/null; then
          GROUP_NAME=$(basename "$CONTRACT" .yaml)
          echo "Advisory: Task group '$GROUP_NAME' — prior brief (sequence $PREV_SEQ) has no governance evidence in contract." >&2
        fi
      fi
    done
  fi

  mkdir -p "$REPO_ROOT/.claude/.state" 2>/dev/null || true
  echo "checked" > "$PHASE_CHECKED_FILE" 2>/dev/null || true
fi

log_hook_event "branch-guard" "PreToolUse" "" "allow" "$START_MS" "$ALLOW_REASON"
