#!/usr/bin/env bash
# Branch guard — blocks file modifications on main and without plan approval.
# Wired to PreToolUse on Edit, Write, and Bash via .claude/settings.json.
#
# Gate 1: Catches work on the wrong branch BEFORE any files are changed,
#          rather than at commit time when all the work is already done.
# Gate 2: Phase gate / plan approval (blocking). Phase-state check
#          (assert_phase build). Fail-open when phase-state absent/stale
#          (parity with branch-guard-edit.sh). Experiment branches exempt
#          (Decision 0006). Session types without plan phase exempt.
# Gate 3: Inter-session governance file check (advisory, first-fire).
#          Warns if docs/ai/governance/spec-compiled or advisory-reviewed missing.
# Gate 4: (Removed — covered by phase model contract-init phase.)
# Gate 5: Session branch isolation (Decision 0013). Blocks edits on branches
#          that were used by a previous session. Task group non-final briefs
#          never seal the branch, so no exemption logic needed.
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
source "$SCRIPT_DIR/_phase-helper.sh"
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

# --- Gate 2: Phase gate / plan approval (blocking) ---
# Phase-state check (assert_phase build — must be in build or later).
# Fail-open when phase-state absent/stale (parity with branch-guard-edit.sh).
# Exempt: experiment/* branches (Decision 0006), .claude/.state/ writes (bootstrap),
#         .claude/local/ writes (session-scoped), governance evidence paths,
#         session types without approval phase (self-exempting via has_plan_gate).
# Override: REPO_OS_SKIP_PLAN_GATE=1 (bypasses phase check).
ALLOW_REASON="pass"

if [[ "$CURRENT_BRANCH" == experiment/* ]]; then
  ALLOW_REASON="experiment_branch"
elif [[ -n "$FILE_PATH" && "$FILE_PATH" == "$REPO_ROOT/.claude/.state/"* ]]; then
  ALLOW_REASON="state_file_exempt"
elif [[ -n "$FILE_PATH" && "$FILE_PATH" == "$REPO_ROOT/.claude/local/"* ]]; then
  ALLOW_REASON="local_file_exempt"
elif [[ -n "$FILE_PATH" && "$FILE_PATH" == "$REPO_ROOT/docs/ai/governance/"* ]]; then
  ALLOW_REASON="governance_exempt"
elif [[ -n "$FILE_PATH" && "$FILE_PATH" == "$REPO_ROOT/docs/ai/task-groups/"* ]]; then
  ALLOW_REASON="task_group_path_exempt"
elif [ "${REPO_OS_SKIP_PLAN_GATE:-0}" = "1" ]; then
  log_override "branch-guard" "REPO_OS_SKIP_PLAN_GATE"
  ALLOW_REASON="plan_gate_override"
else
  # Phase-state primary check
  CURRENT_PHASE=$(get_phase)
  if [ -n "$CURRENT_PHASE" ]; then
    # Phase-state exists — use phase model
    SESSION_TYPE=$(get_session_type)
    if has_plan_gate "$SESSION_TYPE"; then
      if assert_phase "build"; then
        ALLOW_REASON="phase_gate_pass"
      else
        log_hook_event "branch-guard" "PreToolUse" "" "block" "$START_MS" "phase_gate" "phase:$CURRENT_PHASE"
        echo "BLOCKED: Session is in '$CURRENT_PHASE' phase — get plan approval before editing files. (override: REPO_OS_SKIP_PLAN_GATE=1)" >&2
        exit 2
      fi
    else
      ALLOW_REASON="session_type_no_plan_gate"
    fi
  else
    # Phase-state absent/stale — fail-open (branch-guard-edit.sh parity).
    # Phase model is the primary plan enforcement mechanism (Decision 0014).
    ALLOW_REASON="no_phase_state"
  fi
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

# --- Gate 4: Phase chain verification — REMOVED ---
# Covered by phase model's contract-init phase and init_phase session-type
# validation. See Decision 0014 and Brief 2 (Hook Phase Integration).
# Retained at commit-time in pre-commit-gates.sh as Gate 3 (governance advisory).

# --- Gate 5: Session branch isolation (blocking, Decision 0013) ---
# Task group non-final briefs no longer seal the branch at close, so
# active task group branches will not appear in closed-branches. No
# contract scanning needed — if the branch is sealed, it's sealed.
# Override: REPO_OS_SKIP_BRANCH_REUSE=1
CLOSED_BRANCHES_FILE="$REPO_ROOT/.claude/local/closed-branches"

if [ -f "$CLOSED_BRANCHES_FILE" ] && grep -qxF "$CURRENT_BRANCH" "$CLOSED_BRANCHES_FILE" 2>/dev/null; then
  if [ "${REPO_OS_SKIP_BRANCH_REUSE:-0}" = "1" ]; then
    log_override "branch-guard" "REPO_OS_SKIP_BRANCH_REUSE"
  else
    log_hook_event "branch-guard" "PreToolUse" "" "block" "$START_MS" "branch_reused"
    echo "BLOCKED: Branch '$CURRENT_BRANCH' was used by a previous session — create a new branch: git checkout -b <category>/<description> (override: REPO_OS_SKIP_BRANCH_REUSE=1)" >&2
    exit 2
  fi
fi

log_hook_event "branch-guard" "PreToolUse" "" "allow" "$START_MS" "$ALLOW_REASON"
