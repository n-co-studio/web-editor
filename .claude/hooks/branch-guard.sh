#!/usr/bin/env bash
# Branch guard — blocks file modifications on main and without plan approval.
# Wired to PreToolUse on Edit, Write, and Bash via .claude/settings.json.
#
# Gate 1: Catches work on the wrong branch BEFORE any files are changed,
#          rather than at commit time when all the work is already done.
# Gate 2: Enforces plan-before-code rule via plan-approved state file.
#          Experiment branches exempt (Decision 0006).
# Gate 3: Inter-session governance file check (advisory, first-fire).
#          Warns if docs/ai/governance/spec-compiled or advisory-reviewed missing.
# Gate 4: Phase chain verification (advisory, first-fire).
#          For task groups: warns if prior brief lacks governance evidence.
# Gate 5: Session branch isolation (Decision 0013). Blocks edits on branches
#          that were used by a previous session. Task groups exempt.
#
# For Bash: only fires on commands with in-repo write targets (redirect/tee).
# Bash commands without write targets fast-exit with no gate evaluation.
#
# Override: REPO_OS_ALLOW_MAIN=1 (main gate), REPO_OS_SKIP_PLAN_GATE=1 (plan gate)
#           REPO_OS_SKIP_BRANCH_REUSE=1 (session branch isolation gate)
#           REPO_OS_RECOVER=1 (bypass all gates — emergency recovery)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_analytics-helper.sh"
START_MS=$(now_ms)

# --- Read tool call input ---
INPUT=$(cat)

REPO_ROOT="$(get_repo_root)"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

# --- Fast-exit: Bash commands without write patterns ---
# For Bash calls (no file_path in JSON), skip all gates if no redirect/tee detected.
# Avoids jq cost for ~90% of Bash calls (git, npm, ls, etc.)
if [[ "$INPUT" != *'"file_path"'* ]] && [[ "$INPUT" != *'>'* ]] && [[ "$INPUT" != *'tee '* ]]; then
  log_hook_event "branch-guard" "PreToolUse" "Bash" "allow" "$START_MS" "bash_no_write_target"
  exit 0
fi

# --- Parse JSON fields ---
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)

# --- Bash write-target scoping ---
# For Bash calls: extract write targets, resolve paths, check if any are in-repo.
# If no in-repo write targets, exit 0 (no gates needed).
if [ -z "$FILE_PATH" ] && [ -n "$COMMAND" ]; then
  HAS_INREPO_WRITE=false
  TARGETS=$(extract_write_targets "$COMMAND")
  while IFS= read -r WT; do
    [ -z "$WT" ] && continue
    _wt_abs=$(resolve_path "$WT")
    if is_in_repo "$_wt_abs" "$REPO_ROOT"; then
      HAS_INREPO_WRITE=true
      break
    fi
  done <<< "$TARGETS"
  if [ "$HAS_INREPO_WRITE" = false ]; then
    log_hook_event "branch-guard" "PreToolUse" "Bash" "allow" "$START_MS" "bash_out_of_repo"
    exit 0
  fi
fi

# If neither file_path nor in-repo write target, nothing to guard
if [ -z "$FILE_PATH" ] && [ -z "$COMMAND" ]; then
  exit 0
fi

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
# Blocks edits/writes if no approved plan exists.
# Exempt: experiment/* branches (Decision 0006), .claude/.state/ writes (bootstrap).
# Override: REPO_OS_SKIP_PLAN_GATE=1 (logs override).
ALLOW_REASON="pass"

if [[ "$CURRENT_BRANCH" == experiment/* ]]; then
  ALLOW_REASON="experiment_branch"
elif [[ -n "$FILE_PATH" && "$FILE_PATH" == "$REPO_ROOT/.claude/.state/"* ]]; then
  ALLOW_REASON="state_file_exempt"
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
    # Build detail: which files are missing
    MISSING_FILES=""
    [ ! -f "$GOV_DIR/spec-compiled" ] && MISSING_FILES="spec-compiled"
    [ ! -f "$GOV_DIR/advisory-reviewed" ] && MISSING_FILES="${MISSING_FILES:+$MISSING_FILES,}advisory-reviewed"
    log_hook_event "branch-guard" "PreToolUse" "" "warn" "$START_MS" "gate3_gov_warning" "$MISSING_FILES"
  fi

  # Shell I/O — branch-guard's own .state/ writes are not intercepted
  # by Claude Code hooks (hooks only fire on model tool calls, not hook I/O)
  mkdir -p "$REPO_ROOT/.claude/.state" 2>/dev/null || true
  echo "checked" > "$GOVERNANCE_CHECKED_FILE" 2>/dev/null || true
  log_hook_event "branch-guard" "PreToolUse" "" "allow" "$START_MS" "gate3_checked"
fi

# --- Gate 4: Phase chain verification (advisory, first-fire) ---
# For task group sessions: verifies the previous brief completed with
# governance evidence in the contract.
# Non-blocking: prints warning if prior brief lacks governance entry.
PHASE_CHECKED_FILE="$REPO_ROOT/.claude/.state/phase-chain-checked"

if [ ! -f "$PHASE_CHECKED_FILE" ]; then
  # In template mode, contracts live locally; in product mode, they're committed.
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

      # Find the pending brief (next to be worked on) — sequence number
      PENDING_SEQ=$(grep -B1 "status: pending" "$CONTRACT" 2>/dev/null \
        | grep "sequence:" | sed 's/.*sequence: *//' | head -1 || true)

      if [ -n "$PENDING_SEQ" ] && [ "$PENDING_SEQ" -gt 1 ] 2>/dev/null; then
        PREV_SEQ=$((PENDING_SEQ - 1))
        # Check if governance entry exists for previous brief
        if ! grep -q "brief_sequence: $PREV_SEQ" "$CONTRACT" 2>/dev/null; then
          GROUP_NAME=$(basename "$CONTRACT" .yaml)
          echo "Advisory: Task group '$GROUP_NAME' — prior brief (sequence $PREV_SEQ) has no governance evidence in contract." >&2
          log_hook_event "branch-guard" "PreToolUse" "" "warn" "$START_MS" "gate4_chain_warning" "$GROUP_NAME:seq$PREV_SEQ"
        fi
      fi
    done
  fi

  # Shell I/O — not intercepted by Claude Code hooks (see Gate 3 comment)
  mkdir -p "$REPO_ROOT/.claude/.state" 2>/dev/null || true
  echo "checked" > "$PHASE_CHECKED_FILE" 2>/dev/null || true
  log_hook_event "branch-guard" "PreToolUse" "" "allow" "$START_MS" "gate4_checked"
fi

# --- Gate 5: Session branch isolation (blocking, Decision 0013) ---
# Blocks Edit/Write on a branch that was already closed by a previous session.
# One session per branch — merge via PR, then start fresh.
# Task groups exempt: multi-brief groups may reuse branches across sessions.
# Override: REPO_OS_SKIP_BRANCH_REUSE=1
CLOSED_BRANCHES_FILE="$REPO_ROOT/.claude/local/closed-branches"

if [ -f "$CLOSED_BRANCHES_FILE" ] && grep -qxF "$CURRENT_BRANCH" "$CLOSED_BRANCHES_FILE" 2>/dev/null; then
  # Task group exemption: if any contract has pending briefs, allow
  TASK_GROUP_EXEMPT=false

  # Determine contract dir (mode-aware — reuse REPO_MODE_FILE from Gate 4)
  if [ -z "${CONTRACT_DIR:-}" ]; then
    REPO_MODE_FILE="$REPO_ROOT/.claude/repo-mode"
    if [ -f "$REPO_MODE_FILE" ] && grep -q "template" "$REPO_MODE_FILE" 2>/dev/null; then
      CONTRACT_DIR="$REPO_ROOT/.claude/local/task-groups"
    else
      CONTRACT_DIR="$REPO_ROOT/docs/ai/task-groups"
    fi
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
    log_override "branch-guard" "REPO_OS_SKIP_BRANCH_REUSE"
  elif [ "$TASK_GROUP_EXEMPT" = true ]; then
    log_hook_event "branch-guard" "PreToolUse" "" "allow" "$START_MS" "task_group_exempt"
  else
    log_hook_event "branch-guard" "PreToolUse" "" "block" "$START_MS" "branch_reused"
    echo "BLOCKED: Branch '$CURRENT_BRANCH' was used by a previous session — create a new branch: git checkout -b <category>/<description> (override: REPO_OS_SKIP_BRANCH_REUSE=1)" >&2
    exit 2
  fi
fi

log_hook_event "branch-guard" "PreToolUse" "" "allow" "$START_MS" "$ALLOW_REASON"
