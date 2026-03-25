#!/usr/bin/env bash
# Bash guard — unified Bash PreToolUse hook.
# Replaced the former branch-guard.sh — consolidates write-guard.sh (Sections
# 1-2) and branch-guard gates into a single hook for Bash calls. Eliminates
# duplicate stdin reads, JSON parses, and library sourcing that occurred when
# both hooks fired on every Bash call.
#
# Phase 3a of stop-hook optimization (exec-summary.md).
#
# Logical ordering (preserves Decision 0012 point 12):
#   1. Pre-source fast-exits (builtins only — no library sourcing)
#      a. Gate 7: Task group merge protection pattern detection
#      b. Override pre-checks (REPO_OS_SKIP_STATE_GUARD, REPO_OS_RECOVER, REPO_OS_SKIP_MODE_GUARD)
#      c. Combined fast-exit: no Gate 7 match AND no write patterns AND all guards skipped
#   2. Source libraries (single sourcing of _analytics-helper.sh + _phase-helper.sh)
#   3. Gate 7 enforcement (task group merge protection — Decision 0018)
#   4. Fast-exit for no-write-target Bash commands
#   5. JSON parse (single jq invocation for file_path + command)
#   6. Bash write-target scoping (exit if no in-repo write targets)
#   7. State-guard (blocks writes to .claude/.state/ and .claude/.session-id)
#   8. Mode-guard (enforces operating mode restrictions)
#   9. Branch-guard gates:
#      - Gate 1: Main branch protection
#      - Gate 2: Phase gate / plan approval
#      - Gate 6: Session overlap (Decision 0013)
#      - Gate 5: Session branch isolation (Decision 0013)
#
# Overrides (state-guard scope):
#   REPO_OS_SKIP_STATE_GUARD=1  — skip state-guard checks
#   REPO_OS_RECOVER=1           — allow recovery writes to .state/ + bypass branch-guard gates
#   .claude/.state/.recover-signal — file-based recovery (autonomous mode)
#
# Overrides (mode-guard scope):
#   REPO_OS_SKIP_MODE_GUARD=1   — skip mode-guard checks entirely
#   REPO_OS_MODE=<mode>         — force operating mode
#   REPO_OS_UNLOCK_PATH=<path>  — single-file governance unlock
#
# Overrides (branch-guard scope):
#   REPO_OS_ALLOW_MAIN=1        — allow edits on main
#   REPO_OS_SKIP_PLAN_GATE=1    — skip phase gate
#   REPO_OS_SKIP_OVERLAP_CHECK=1 — skip overlap check
#   REPO_OS_SKIP_BRANCH_REUSE=1 — skip branch isolation check
#   REPO_OS_SKIP_MERGE_GUARD=1  — skip task group merge protection gate

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ============================================================
# Phase 1: Read stdin + Pre-source fast-exits (builtins only)
# ============================================================

INPUT=$(cat)

# --- Override pre-checks (before sourcing — for potential fast exit) ---
SKIP_STATE_GUARD=false
_RECOVER_VIA_SIGNAL=false
RECOVER_SIGNAL_FILE="$(cd "$(dirname "$0")/../.." && pwd)/.claude/.state/.recover-signal"
if [ "${REPO_OS_SKIP_STATE_GUARD:-0}" = "1" ]; then
  SKIP_STATE_GUARD=true
fi
if [ "${REPO_OS_RECOVER:-0}" = "1" ]; then
  SKIP_STATE_GUARD=true
elif [ -f "$RECOVER_SIGNAL_FILE" ]; then
  _RECOVER_VIA_SIGNAL=true
  SKIP_STATE_GUARD=true
fi

SKIP_MODE_GUARD=false
if [ "${REPO_OS_SKIP_MODE_GUARD:-0}" = "1" ] || [ "${REPO_OS_RECOVER:-0}" = "1" ] || [ "$_RECOVER_VIA_SIGNAL" = true ]; then
  SKIP_MODE_GUARD=true
fi

# --- Gate 7: Pattern detection (builtins only — no sourcing needed) ---
# Uses [[ ]] built-in string matching: no jq, no subshells, no sourced functions.
_TG_MERGE_BLOCK=false
_TG_MERGE_REASON=""

# Inline branch detection (no sourced deps)
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

if [ "${REPO_OS_RECOVER:-0}" != "1" ] && [ "$_RECOVER_VIA_SIGNAL" != true ] && [ "${REPO_OS_SKIP_MERGE_GUARD:-0}" != "1" ]; then
  if [[ "$INPUT" == *'git checkout main'* ]] || [[ "$INPUT" == *'git switch main'* ]]; then
    if [[ "$INPUT" != *'git checkout main-'* ]] && [[ "$INPUT" != *'git checkout main/'* ]] \
    && [[ "$INPUT" != *'git switch main-'* ]] && [[ "$INPUT" != *'git switch main/'* ]]; then
      _TG_MERGE_BLOCK=true
      _TG_MERGE_REASON="checkout_main"
    fi
  fi
  if [ "$_TG_MERGE_BLOCK" = false ] && [ "$CURRENT_BRANCH" = "main" ]; then
    if [[ "$INPUT" == *'git merge'* ]] \
    && [[ "$INPUT" != *'git merge --abort'* ]] && [[ "$INPUT" != *'git merge-base'* ]]; then
      _TG_MERGE_BLOCK=true
      _TG_MERGE_REASON="merge_on_main"
    fi
  fi
fi

# --- Combined pre-source fast-exit ---
# When no Gate 7 match AND no write patterns → exit 0 without sourcing.
# Saves ~14ms sourcing overhead for the majority of Bash calls (~56%).
if [ "$_TG_MERGE_BLOCK" = false ] \
&& [[ "$INPUT" != *'"file_path"'* ]] && [[ "$INPUT" != *'>'* ]] && [[ "$INPUT" != *'tee '* ]]; then
  exit 0
fi

# ============================================================
# Phase 2: Source libraries (single sourcing)
# ============================================================

source "$SCRIPT_DIR/_analytics-helper.sh"
source "$SCRIPT_DIR/_phase-helper.sh"
source "$SCRIPT_DIR/_mode-guard-helper.sh"
START_MS=$(now_ms)

# Prime _CACHED_BRANCH from pre-source git rev-parse result (I1 — avoids redundant git call)
_CACHED_BRANCH="$CURRENT_BRANCH"

REPO_ROOT="$_REPO_OS_ROOT"

# Log overrides that were detected pre-source
if [ "${REPO_OS_SKIP_STATE_GUARD:-0}" = "1" ]; then
  log_override "state-guard" "REPO_OS_SKIP_STATE_GUARD"
  log_hook_event "state-guard" "PreToolUse" "Bash" "allow" "$START_MS" "skip_override"
fi
if [ "${REPO_OS_RECOVER:-0}" = "1" ]; then
  log_override "state-guard" "REPO_OS_RECOVER"
  log_hook_event "state-guard" "PreToolUse" "Bash" "allow" "$START_MS" "recovery_bypass"
fi
if [ "$_RECOVER_VIA_SIGNAL" = true ]; then
  log_override "state-guard" "recover-signal-file"
  log_hook_event "state-guard" "PreToolUse" "Bash" "allow" "$START_MS" "recovery_signal_file"
  rm -f "$RECOVER_SIGNAL_FILE"
  echo "Recovery signal consumed — bypassing state-guard and bash-guard gates" >&2
fi
if [ "${REPO_OS_SKIP_MODE_GUARD:-0}" = "1" ]; then
  log_override "mode-guard" "REPO_OS_SKIP_MODE_GUARD"
  log_hook_event "mode-guard" "PreToolUse" "Bash" "allow" "$START_MS" "skip_override"
fi

# ============================================================
# Phase 3: Ephemeral session fast-exit (Phase 3b)
# ============================================================
# Ephemeral sessions skip mode-guard and all branch-guard gates.
# State-guard still runs (protect .claude/.state/ in all session types).
_EPHEMERAL_FAST_EXIT=false
_BG_SESSION_TYPE=$(get_session_type)
if [ "$_BG_SESSION_TYPE" = "ephemeral" ]; then
  _EPHEMERAL_FAST_EXIT=true
  SKIP_MODE_GUARD=true
fi

# ============================================================
# Phase 4: Gate 7 enforcement (uses sourced functions)
# ============================================================

if [ "$_TG_MERGE_BLOCK" = true ]; then
  _TG_PHASE=$(get_phase)
  _TG_SESSION_TYPE=$(get_session_type)
  if [ "$_TG_SESSION_TYPE" = "taskgroup" ] || [ "$_TG_SESSION_TYPE" = "taskgroup-merge" ]; then
    if [ "$_TG_PHASE" = "close" ]; then
      log_hook_event "branch-guard" "PreToolUse" "Bash" "allow" "$START_MS" "tg_merge_close_phase" "$_TG_MERGE_REASON"
    else
      log_hook_event "branch-guard" "PreToolUse" "Bash" "block" "$START_MS" "tg_merge_blocked" "$_TG_MERGE_REASON"
      echo "GATE-RECOVERABLE: Task group merge outside close phase. NEXT: Wait for close phase — merge happens automatically at session close. (override: REPO_OS_SKIP_MERGE_GUARD=1)" >&2
      exit 2
    fi
  fi
elif [ "${REPO_OS_SKIP_MERGE_GUARD:-0}" = "1" ]; then
  log_override "branch-guard" "REPO_OS_SKIP_MERGE_GUARD"
fi

# ============================================================
# Phase 5: Fast-exit for no-write-target Bash (post-sourcing)
# ============================================================
# Commands that triggered Gate 7 detection but weren't blocked land here.
if [[ "$INPUT" != *'"file_path"'* ]] && [[ "$INPUT" != *'>'* ]] && [[ "$INPUT" != *'tee '* ]]; then
  log_hook_event "bash-guard" "PreToolUse" "Bash" "allow" "$START_MS" "bash_no_write_target"
  exit 0
fi

# ============================================================
# Phase 6: JSON parse (single jq invocation)
# ============================================================

if [ "$_REPO_OS_HAS_JQ" = false ]; then
  echo "GATE-FINAL: jq is required for bash-guard but was not found." >&2
  echo "  Install jq (https://jqlang.github.io/jq/download/) and retry. (no override)" >&2
  exit 2
fi

# Single jq invocation for both fields (halves subprocess count)
_jq_out=$(echo "$INPUT" | jq -r '[.tool_input.file_path // "", .tool_input.command // ""] | join("\t")')
_TAB=$(printf '\t')
FILE_PATH="${_jq_out%%${_TAB}*}"
COMMAND="${_jq_out#*${_TAB}}"

# Cache extract_write_targets once (R11 — pure function, same input → same output)
WRITE_TARGETS=""
if [ -n "$COMMAND" ]; then
  WRITE_TARGETS=$(extract_write_targets "$COMMAND")
fi

# ============================================================
# Phase 7: Bash write-target scoping
# ============================================================
# For Bash calls: extract write targets, resolve paths, check if any are in-repo.
# If no in-repo write targets, exit 0 (no gates needed for state/mode/branch).
if [ -z "$FILE_PATH" ] && [ -n "$COMMAND" ]; then
  HAS_INREPO_WRITE=false
  while IFS= read -r WT; do
    [ -z "$WT" ] && continue
    _wt_abs=$(resolve_path "$WT")
    if is_in_repo "$_wt_abs" "$REPO_ROOT"; then
      HAS_INREPO_WRITE=true
      break
    fi
  done <<< "$WRITE_TARGETS"
  if [ "$HAS_INREPO_WRITE" = false ]; then
    log_hook_event "bash-guard" "PreToolUse" "Bash" "allow" "$START_MS" "bash_out_of_repo"
    exit 0
  fi
fi

# If neither file_path nor command, nothing to guard
if [ -z "$FILE_PATH" ] && [ -z "$COMMAND" ]; then
  exit 0
fi

# ============================================================
# Phase 8: State-Guard (blocks writes to .claude/.state/ and .claude/.session-id)
# ============================================================

if [ "$SKIP_STATE_GUARD" = false ]; then
  TARGETS_STATE=false
  STATE_TARGET_PATH=""

  if [ -n "$COMMAND" ]; then
    while IFS= read -r SG_WT; do
      [ -z "$SG_WT" ] && continue
      if [[ "$SG_WT" == *".claude/.state/"* ]] || [[ "$SG_WT" == *".claude/.session-id"* ]]; then
        _sg_abs=$(resolve_path "$SG_WT")
        if is_in_repo "$_sg_abs" "$REPO_ROOT"; then
          TARGETS_STATE=true
          STATE_TARGET_PATH="$SG_WT"
          break
        fi
      fi
    done <<< "$WRITE_TARGETS"
  fi

  # --- Indirect path construction hardening ---
  # Detect variable assignments that concatenate to form .state or .session-id paths.
  # Heuristic defense-in-depth — emits GATE-RECOVERABLE, not GATE-FINAL.
  if [ "$TARGETS_STATE" = false ] && [ -n "$COMMAND" ]; then
    if [[ "$COMMAND" =~ [A-Za-z_][A-Za-z0-9_]*=.*\.sta.*te.*\.claude ]] \
    || [[ "$COMMAND" =~ [A-Za-z_][A-Za-z0-9_]*=.*\.claude.*\.sta.*te ]] \
    || [[ "$COMMAND" =~ [A-Za-z_][A-Za-z0-9_]*=.*\.sess.*ion-id.*\.claude ]] \
    || [[ "$COMMAND" =~ [A-Za-z_][A-Za-z0-9_]*=.*\.claude.*\.sess.*ion-id ]]; then
      log_hook_event "state-guard" "PreToolUse" "Bash" "block" "$START_MS" "indirect_path_construction"
      echo "GATE-RECOVERABLE: Detected possible indirect path construction targeting .state/ or .session-id. NEXT: Use direct file paths instead of variable concatenation. (override: REPO_OS_SKIP_STATE_GUARD=1)" >&2
      exit 2
    fi
  fi

  if [ "$TARGETS_STATE" = true ]; then
    STATE_FILE_NAME="${STATE_TARGET_PATH##*.claude/.state/}"
    if [[ "$STATE_TARGET_PATH" == *".claude/.session-id"* ]]; then
      STATE_FILE_NAME=".session-id"
    fi
    log_hook_event "state-guard" "PreToolUse" "Bash" "block" "$START_MS" "state_path_protected" "" "$STATE_FILE_NAME"
    echo "GATE-FINAL: .claude/.state/ is write-protected — state files are managed by governance hooks only. (override: REPO_OS_RECOVER=1)" >&2
    exit 2
  fi
fi

# ============================================================
# Phase 9: Mode-Guard (enforces operating mode restrictions)
# ============================================================

if [ "$SKIP_MODE_GUARD" = false ]; then

  if [ -z "$COMMAND" ]; then
    # No command means nothing to check for mode-guard on Bash calls
    log_hook_event "mode-guard" "PreToolUse" "Bash" "allow" "$START_MS" "no_command"
  else
    # --- Resolve operating mode (via get_mode from _analytics-helper.sh) ---
    if [ -n "${REPO_OS_MODE:-}" ]; then
      log_override "mode-guard" "REPO_OS_MODE"
    fi
    MODE=$(get_mode)

    case "$MODE" in
      template|child|autonomous) ;;
      *)
        echo "WARNING: Unknown mode '$MODE' in .claude/repo-mode — defaulting to child" >&2
        MODE="child"
        ;;
    esac

    # --- Path helpers (make_relative, is_immune sourced from _mode-guard-helper.sh) ---

    # --- Fast-exit for non-template modes ---
    if [ "$MODE" != "template" ]; then
      # Immune path check on Bash write targets
      if [ -n "$COMMAND" ]; then
        while IFS= read -r MG_WT; do
          [ -z "$MG_WT" ] && continue
          MG_WT_ABS=$(resolve_path "$MG_WT")
          if is_in_repo "$MG_WT_ABS" "$REPO_ROOT"; then
            MG_WT_REL=$(make_relative "$MG_WT")
            if is_immune "$MG_WT_REL"; then
              log_hook_event "mode-guard" "PreToolUse" "Bash" "block" "$START_MS" "bash_immune_path" "" "$MG_WT_REL"
              echo "GATE-FINAL: $MG_WT_REL is an immune path — cannot be modified in any mode. (no override)" >&2
              exit 2
            fi
            # Template decision protection (Decision 0022)
            case "$MG_WT_REL" in
              docs/ai/decisions/t-*.md)
                log_hook_event "mode-guard" "PreToolUse" "Bash" "block" "$START_MS" "bash_template_decision" "" "$MG_WT_REL"
                echo "GATE-FINAL: $MG_WT_REL is a template decision (t-* prefix) — immutable in '$MODE' mode. (override: REPO_OS_UNLOCK_PATH=$MG_WT_REL or REPO_OS_SKIP_MODE_GUARD=1)" >&2
                exit 2
                ;;
            esac
          fi
        done <<< "$WRITE_TARGETS"
      fi
      log_hook_event "mode-guard" "PreToolUse" "Bash" "allow" "$START_MS" "fast_exit_${MODE}"
    else
      # Template mode — full path classification
      # (is_governance, is_carved_out sourced from _mode-guard-helper.sh)

      check_path() {
        local rel="$1" context="$2"
        if is_immune "$rel"; then
          log_hook_event "mode-guard" "PreToolUse" "Bash" "block" "$START_MS" "${context}_immune_path" "" "$rel"
          echo "GATE-FINAL: $rel is an immune path — cannot be modified in any mode. (no override)" >&2
          exit 2
        fi
        if [ -n "${REPO_OS_UNLOCK_PATH:-}" ]; then
          UNLOCK_REL=$(make_relative "$REPO_OS_UNLOCK_PATH")
          if [ "$rel" = "$UNLOCK_REL" ]; then
            log_override "mode-guard" "REPO_OS_UNLOCK_PATH"
            log_hook_event "mode-guard" "PreToolUse" "Bash" "allow" "$START_MS" "unlock_path" "" "$rel"
            return 0
          fi
        fi
        if is_governance "$rel"; then
          if ! is_carved_out "$MODE" "$rel"; then
            log_hook_event "mode-guard" "PreToolUse" "Bash" "block" "$START_MS" "${context}_governance_${MODE}" "" "$rel"
            echo "GATE-RECOVERABLE: $rel is a governance path — not editable in '$MODE' mode. NEXT: Switch to a mode that allows this path, or unlock it. (override: REPO_OS_UNLOCK_PATH=$rel or REPO_OS_SKIP_MODE_GUARD=1)" >&2
            exit 2
          fi
        else
          if [ "$MODE" = "template" ]; then
            log_hook_event "mode-guard" "PreToolUse" "Bash" "block" "$START_MS" "${context}_product_in_template" "" "$rel"
            echo "GATE-RECOVERABLE: $rel is a product path — not editable in 'template' mode. NEXT: Use child or autonomous mode for product code. (override: REPO_OS_SKIP_MODE_GUARD=1)" >&2
            exit 2
          fi
        fi
      }

      ALLOW_PATH=""
      if [ -n "$COMMAND" ]; then
        while IFS= read -r MG_WT; do
          [ -z "$MG_WT" ] && continue
          MG_WT_ABS=$(resolve_path "$MG_WT")
          if ! is_in_repo "$MG_WT_ABS" "$REPO_ROOT"; then
            continue
          fi
          MG_WT_REL=$(make_relative "$MG_WT")
          [ -z "$ALLOW_PATH" ] && ALLOW_PATH="$MG_WT_REL"
          check_path "$MG_WT_REL" "bash"
        done <<< "$WRITE_TARGETS"
      fi

      log_hook_event "mode-guard" "PreToolUse" "Bash" "allow" "$START_MS" "pass_${MODE}" "" "$ALLOW_PATH"
    fi
  fi
fi  # end SKIP_MODE_GUARD

# ============================================================
# Phase 10: Branch-Guard Gates
# ============================================================

# Ephemeral sessions skip all branch-guard gates (Phase 3b)
if [ "$_EPHEMERAL_FAST_EXIT" = true ]; then
  log_hook_event "bash-guard" "PreToolUse" "Bash" "allow" "$START_MS" "ephemeral_skip_branch_guard"
  exit 0
fi

# --- REPO_OS_RECOVER override (bypass all branch-guard gates) ---
if [ "${REPO_OS_RECOVER:-0}" = "1" ] || [ "$_RECOVER_VIA_SIGNAL" = true ]; then
  if [ "${REPO_OS_RECOVER:-0}" = "1" ]; then
    log_override "branch-guard" "REPO_OS_RECOVER"
  else
    log_override "branch-guard" "recover-signal-file"
  fi
  log_hook_event "branch-guard" "PreToolUse" "Bash" "allow" "$START_MS" "recovery_bypass"
  echo "Recovery mode — bypassing bash-guard gates" >&2
  exit 0
fi

# --- Gate 1: Main branch protection ---
ALLOW_REASON="pass"
if [ "$CURRENT_BRANCH" = "main" ] && [ "${REPO_OS_ALLOW_MAIN:-0}" != "1" ]; then
  log_hook_event "branch-guard" "PreToolUse" "Bash" "block" "$START_MS" "main_branch"
  echo "GATE-RECOVERABLE: On main branch. NEXT: Create a feature branch with git checkout -b feature/<description>. (override: REPO_OS_ALLOW_MAIN=1)" >&2
  exit 2
fi
if [ "$CURRENT_BRANCH" = "main" ] && [ "${REPO_OS_ALLOW_MAIN:-0}" = "1" ]; then
  log_override "branch-guard" "REPO_OS_ALLOW_MAIN"
  ALLOW_REASON="main_override"
fi

# --- Gate 2: Phase gate / plan approval (blocking) ---
if [ "$ALLOW_REASON" = "pass" ]; then
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
    CURRENT_PHASE=$(get_phase)
    if [ -n "$CURRENT_PHASE" ]; then
      SESSION_TYPE=$(get_session_type)
      if has_plan_gate "$SESSION_TYPE"; then
        if assert_phase "build"; then
          ALLOW_REASON="phase_gate_pass"
        else
          log_hook_event "branch-guard" "PreToolUse" "Bash" "block" "$START_MS" "phase_gate" "phase:$CURRENT_PHASE"
          # R13 diagnostic: distinguish "hook didn't fire" from "approval not given".
          # When phase is plan/approval but plan-approved file is absent, the
          # plan-approval.sh PostToolUse hook likely failed to fire after
          # AskUserQuestion (known VS Code extension issue — see R13).
          if [ ! -f "$(get_session_state_dir)/plan-approved" ] && \
             { [ "$CURRENT_PHASE" = "plan" ] || [ "$CURRENT_PHASE" = "approval" ]; }; then
            echo "GATE-RECOVERABLE: Session in '$CURRENT_PHASE' phase and plan-approved state file is missing — plan-approval.sh hook may not have fired after AskUserQuestion (see known-issues.md R13). NEXT: Create recovery signal (touch .claude/.state/.recover-signal) or set REPO_OS_SKIP_PLAN_GATE=1." >&2
          else
            echo "GATE-RECOVERABLE: Session in '$CURRENT_PHASE' phase — Bash writes blocked until plan approved. NEXT: Call AskUserQuestion with your plan summary. Include options: \"Auto — proceed autonomously\" and \"Review — pause for my review before commit\". Conversational confirmation does NOT trigger the approval hook. (override: REPO_OS_SKIP_PLAN_GATE=1)" >&2
          fi
          exit 2
        fi
      else
        ALLOW_REASON="session_type_no_plan_gate"
      fi
    else
      if [ -f "$REPO_ROOT/docs/ai/decisions/.fail-closed-enforced" ]; then
        log_hook_event "branch-guard" "PreToolUse" "Bash" "block" "$START_MS" "phase_gate_no_state"
        echo "GATE-RECOVERABLE: No phase-state — session not initialized. NEXT: Call init_phase() via the orchestrator to initialize the session. (override: REPO_OS_SKIP_PLAN_GATE=1)" >&2
        exit 2
      else
        log_hook_event "branch-guard" "PreToolUse" "Bash" "warn" "$START_MS" "phase_gate_no_state_advisory"
        echo "Advisory: No phase-state found — session may not be initialized. Consider calling init_phase() via the orchestrator." >&2
        ALLOW_REASON="no_phase_state"
      fi
    fi
  fi
fi

# --- Gate 2b: Taskgroup brief mismatch check (Decision 0026) ---
# Blocks if brief contains ### Task Group but session type is not taskgroup/taskgroup-merge.
check_taskgroup_brief_mismatch "$START_MS"

# --- Gate 6: Session overlap check (Decision 0013) ---
if ! check_session_overlap; then
  log_hook_event "branch-guard" "PreToolUse" "Bash" "block" "$START_MS" "session_overlap"
  exit 2
fi

# --- Gate 5: Session branch isolation (Decision 0013) ---
CLOSED_BRANCHES_FILE="$REPO_ROOT/.claude/local/closed-branches"
if [ -f "$CLOSED_BRANCHES_FILE" ] && grep -qxF "$CURRENT_BRANCH" "$CLOSED_BRANCHES_FILE" 2>/dev/null; then
  if [ "${REPO_OS_SKIP_BRANCH_REUSE:-0}" = "1" ]; then
    log_override "branch-guard" "REPO_OS_SKIP_BRANCH_REUSE"
  else
    log_hook_event "branch-guard" "PreToolUse" "Bash" "block" "$START_MS" "branch_reused"
    echo "GATE-RECOVERABLE: Branch '$CURRENT_BRANCH' sealed by a previous session. NEXT: Create a new branch with git checkout -b <category>/<description>. (override: REPO_OS_SKIP_BRANCH_REUSE=1)" >&2
    exit 2
  fi
fi

log_hook_event "bash-guard" "PreToolUse" "Bash" "allow" "$START_MS" "$ALLOW_REASON"
exit 0
