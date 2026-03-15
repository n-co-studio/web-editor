#!/usr/bin/env bash
# DEPRECATED: Bash calls are now handled by bash-guard.sh (Phase 3a consolidation).
# This file is retained for rollback support. To revert, replace the single
# Bash PreToolUse entry in .claude/settings.json with the original two entries
# (write-guard.sh + branch-guard.sh for Bash). See exec-summary.md Phase 3a.
#
# Branch guard — blocks file modifications on main and without plan approval.
# Previously wired to PreToolUse on Bash via .claude/settings.json.
#
# Gate 1: Catches work on the wrong branch BEFORE any files are changed,
#          rather than at commit time when all the work is already done.
# Gate 2: Phase gate / plan approval (blocking). Phase-state check
#          (assert_phase build). Fail-closed when sentinel present and
#          phase-state absent/stale (Decision 0019). Advisory warn when
#          sentinel absent (backward compat). Experiment branches exempt
#          (Decision 0006). Session types without plan phase exempt.
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

# --- Read tool call input (before sourcing — cat needs no libraries) ---
INPUT=$(cat)

# --- Inline branch detection (no sourced deps) ---
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

# --- Gate 7: Pattern detection (builtins only — no sourcing needed) ---
# Uses [[ ]] built-in string matching: no jq, no subshells, no sourced functions.
# Sets _TG_MERGE_BLOCK flag for enforcement after sourcing.
_TG_MERGE_BLOCK=false
_TG_MERGE_REASON=""

if [ "${REPO_OS_RECOVER:-0}" != "1" ] && [ "${REPO_OS_SKIP_MERGE_GUARD:-0}" != "1" ]; then
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
fi

# --- Fast-exit: deferred sourcing (Phase 2c) ---
# When no Gate 7 match AND no write patterns, exit without sourcing libraries.
# Saves ~14ms sourcing overhead for ~56% of fires (no-write Bash commands).
# Analytics logging is skipped on this path (acceptable trade-off per Phase 2 spec).
if [ "$_TG_MERGE_BLOCK" = false ] \
&& [[ "$INPUT" != *'"file_path"'* ]] && [[ "$INPUT" != *'>'* ]] && [[ "$INPUT" != *'tee '* ]]; then
  exit 0
fi

# --- Source libraries (only paths that need them reach here) ---
source "$SCRIPT_DIR/_analytics-helper.sh"
source "$SCRIPT_DIR/_phase-helper.sh"
START_MS=$(now_ms)

REPO_ROOT="$(get_repo_root)"

# --- Gate 7: Enforcement (uses sourced functions) ---
# Separated from pattern detection: sourced functions (get_phase, get_session_type)
# are needed here but not for the pattern matching above.
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
      echo "GATE-RECOVERABLE: Task group merge blocked outside close phase. NEXT: Wait for close phase to merge. (override: REPO_OS_SKIP_MERGE_GUARD=1)" >&2
      exit 2
    fi
  fi
elif [ "${REPO_OS_SKIP_MERGE_GUARD:-0}" = "1" ]; then
  log_override "branch-guard" "REPO_OS_SKIP_MERGE_GUARD"
fi

# --- Fast-exit: Bash commands without write patterns (with analytics) ---
# Post-sourcing fast-exit for commands that triggered Gate 7 pattern detection
# but weren't blocked (non-taskgroup session or close-phase exempt).
if [[ "$INPUT" != *'"file_path"'* ]] && [[ "$INPUT" != *'>'* ]] && [[ "$INPUT" != *'tee '* ]]; then
  log_hook_event "branch-guard" "PreToolUse" "Bash" "allow" "$START_MS" "bash_no_write_target"
  exit 0
fi

# --- jq presence guard (fail-closed) ---
if [ "$_REPO_OS_HAS_JQ" = false ]; then
  echo "GATE-FINAL: jq is required for branch-guard but was not found. Install jq (https://jqlang.github.io/jq/download/) and retry. (no override)" >&2
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
  echo "GATE-RECOVERABLE: On main branch. NEXT: git checkout -b feature/<description>. (override: REPO_OS_ALLOW_MAIN=1)" >&2
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
        echo "GATE-RECOVERABLE: Session in '$CURRENT_PHASE' phase — plan not yet approved. NEXT: Use AskUserQuestion to present your plan for operator approval (triggers plan-approval hook). (override: REPO_OS_SKIP_PLAN_GATE=1)" >&2
        exit 2
      fi
    else
      ALLOW_REASON="session_type_no_plan_gate"
    fi
  else
    # Phase-state absent/stale — sentinel controls fail-closed vs advisory (Decision 0019).
    if [ -f "$REPO_ROOT/docs/ai/decisions/.fail-closed-enforced" ]; then
      log_hook_event "branch-guard" "PreToolUse" "" "block" "$START_MS" "phase_gate_no_state"
      echo "GATE-RECOVERABLE: No phase-state — session not initialized. NEXT: Call init_phase() via the orchestrator. (override: REPO_OS_SKIP_PLAN_GATE=1)" >&2
      exit 2
    else
      log_hook_event "branch-guard" "PreToolUse" "" "warn" "$START_MS" "phase_gate_no_state_advisory"
      echo "Advisory: No phase-state found — session may not be initialized. Consider calling init_phase() via the orchestrator." >&2
      ALLOW_REASON="no_phase_state"
    fi
  fi
fi

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
    echo "GATE-RECOVERABLE: Branch '$CURRENT_BRANCH' was sealed by a previous session. NEXT: git checkout -b <category>/<description>. (override: REPO_OS_SKIP_BRANCH_REUSE=1)" >&2
    exit 2
  fi
fi

log_hook_event "branch-guard" "PreToolUse" "" "allow" "$START_MS" "$ALLOW_REASON"
