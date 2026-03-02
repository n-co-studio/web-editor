#!/usr/bin/env bash
# Branch guard — blocks file modifications on main and without plan approval.
# Wired to PreToolUse on Edit, Write, and Bash via .claude/settings.json.
#
# Gate 1: Catches work on the wrong branch BEFORE any files are changed,
#          rather than at commit time when all the work is already done.
# Gate 2: Phase gate / plan approval (blocking). Phase-state check
#          (assert_phase build). Fail-closed when sentinel present and
#          phase-state absent/stale (Decision 0019). Advisory warn when
#          sentinel absent (backward compat). Experiment branches exempt
#          (Decision 0006). Session types without plan phase exempt.
# Gate 3: Inter-session governance file check (advisory, first-fire).
#          Warns if docs/ai/governance/spec-compiled or advisory-reviewed missing.
# Gate 4: (Removed — covered by phase model contract-init phase.)
# Gate 6: Session overlap check (Decision 0013). Blocks concurrent
#          non-task-group sessions on the same branch. Advisory for task
#          groups. Exempt: taskdef-query, taskdef-brief (Prompt T).
# Gate 5: Session branch isolation (Decision 0013). Blocks edits on branches
#          that were used by a previous session. Task group non-final briefs
#          never seal the branch, so no exemption logic needed.
# Gate 7: Task group merge protection (Decision 0018). Blocks git checkout main,
#          git switch main, and git merge (when on main) for taskgroup and
#          taskgroup-merge sessions during build phases. Close-phase exemption:
#          allows merge when current phase is "close". Fires BEFORE fast-exit.
#
# For Bash: only fires on commands with in-repo write targets (redirect/tee),
# EXCEPT Gate 7 which fires before the fast-exit for merge/checkout detection.
#
# Override: REPO_OS_ALLOW_MAIN=1 (main gate), REPO_OS_SKIP_PLAN_GATE=1 (plan gate)
#           REPO_OS_SKIP_OVERLAP_CHECK=1 (session overlap gate)
#           REPO_OS_SKIP_BRANCH_REUSE=1 (session branch isolation gate)
#           REPO_OS_SKIP_MERGE_GUARD=1 (task group merge protection gate)
#           REPO_OS_RECOVER=1 (bypass all gates — emergency recovery)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_analytics-helper.sh"
source "$SCRIPT_DIR/_phase-helper.sh"
START_MS=$(now_ms)

# --- Read tool call input ---
INPUT=$(cat)

REPO_ROOT="$(get_repo_root)"
CURRENT_BRANCH=$(get_branch)

# --- Gate 7: Task group merge protection (blocking, Decision 0018) ---
# Blocks task group sessions from manually merging to main during build phases.
# Close-phase exemption: when the current phase is "close", Gate 7 allows merge
# commands — the agent has passed through all prior phases and determined merge
# appropriateness. The stop hook retains solo merge as a safety net.
# Must fire BEFORE the fast-exit: git merge/checkout have no redirect/tee patterns.
# Zero-fork: uses [[ ]] built-in string matching (no jq, no subshells).
# Override: REPO_OS_SKIP_MERGE_GUARD=1
if [ "${REPO_OS_RECOVER:-0}" != "1" ] && [ "${REPO_OS_SKIP_MERGE_GUARD:-0}" != "1" ]; then
  _TG_MERGE_BLOCK=false
  _TG_MERGE_REASON=""

  # Pattern: git checkout main / git switch main (exclude main-* and main/* false positives)
  if [[ "$INPUT" == *'git checkout main'* ]] || [[ "$INPUT" == *'git switch main'* ]]; then
    if [[ "$INPUT" != *'git checkout main-'* ]] && [[ "$INPUT" != *'git checkout main/'* ]] \
    && [[ "$INPUT" != *'git switch main-'* ]] && [[ "$INPUT" != *'git switch main/'* ]]; then
      _TG_MERGE_BLOCK=true
      _TG_MERGE_REASON="checkout_main"
    fi
  fi

  # Pattern: git merge when already on main (exclude git merge --abort, git merge-base)
  if [ "$_TG_MERGE_BLOCK" = false ] && [ "$CURRENT_BRANCH" = "main" ]; then
    if [[ "$INPUT" == *'git merge'* ]] \
    && [[ "$INPUT" != *'git merge --abort'* ]] && [[ "$INPUT" != *'git merge-base'* ]]; then
      _TG_MERGE_BLOCK=true
      _TG_MERGE_REASON="merge_on_main"
    fi
  fi

  if [ "$_TG_MERGE_BLOCK" = true ]; then
    # Audit C9: call get_phase first to populate _PS_* cache before get_session_type
    _TG_PHASE=$(get_phase)
    _TG_SESSION_TYPE=$(get_session_type)
    if [ "$_TG_SESSION_TYPE" = "taskgroup" ] || [ "$_TG_SESSION_TYPE" = "taskgroup-merge" ]; then
      # Close-phase exemption: allow merge when agent is in the close phase
      if [ "$_TG_PHASE" = "close" ]; then
        log_hook_event "branch-guard" "PreToolUse" "Bash" "allow" "$START_MS" "tg_merge_close_phase" "$_TG_MERGE_REASON"
      else
        log_hook_event "branch-guard" "PreToolUse" "Bash" "block" "$START_MS" "tg_merge_blocked" "$_TG_MERGE_REASON"
        echo "BLOCKED: Task group sessions must not manually merge to main — merge happens in the close phase (override: REPO_OS_SKIP_MERGE_GUARD=1)" >&2
        exit 2
      fi
    fi
  fi
elif [ "${REPO_OS_SKIP_MERGE_GUARD:-0}" = "1" ]; then
  log_override "branch-guard" "REPO_OS_SKIP_MERGE_GUARD"
fi

# --- Fast-exit: Bash commands without write patterns ---
# For Bash calls (no file_path in JSON), skip all gates if no redirect/tee detected.
# Avoids jq cost for ~90% of Bash calls (git, npm, ls, etc.)
if [[ "$INPUT" != *'"file_path"'* ]] && [[ "$INPUT" != *'>'* ]] && [[ "$INPUT" != *'tee '* ]]; then
  log_hook_event "branch-guard" "PreToolUse" "Bash" "allow" "$START_MS" "bash_no_write_target"
  exit 0
fi

# --- jq presence guard (fail-closed) ---
if [ "$_REPO_OS_HAS_JQ" = false ]; then
  echo "GATE BLOCKED: jq is required for branch-guard but was not found." >&2
  echo "  Install jq (https://jqlang.github.io/jq/download/) and retry." >&2
  exit 2
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
# Fail-closed when sentinel present and phase-state absent/stale (Decision 0019).
# Advisory warn when sentinel absent (backward compat).
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
    # Phase-state absent/stale — sentinel controls fail-closed vs advisory (Decision 0019).
    if [ -f "$REPO_ROOT/docs/ai/decisions/.fail-closed-enforced" ]; then
      log_hook_event "branch-guard" "PreToolUse" "" "block" "$START_MS" "phase_gate_no_state"
      echo "BLOCKED: No phase-state — session not initialized. Call init_phase() via the orchestrator before editing files. (override: REPO_OS_SKIP_PLAN_GATE=1)" >&2
      exit 2
    else
      log_hook_event "branch-guard" "PreToolUse" "" "warn" "$START_MS" "phase_gate_no_state_advisory"
      echo "Advisory: No phase-state found — session may not be initialized. Consider calling init_phase() via the orchestrator." >&2
      ALLOW_REASON="no_phase_state"
    fi
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

# --- Gate 6: Session overlap check (Decision 0013 concurrent awareness) ---
# Checks for same-branch overlap with another active session.
# Advisory for task groups; blocking for all other types.
# Override: REPO_OS_SKIP_OVERLAP_CHECK=1
if ! check_session_overlap; then
  log_hook_event "branch-guard" "PreToolUse" "" "block" "$START_MS" "session_overlap"
  exit 2
fi

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
