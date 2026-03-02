#!/usr/bin/env bash
# Branch guard (Edit/Write) — slim gate for file modifications.
# Wired to PreToolUse on Edit and Write via .claude/settings.json.
#
# Gate 1: Main branch protection — blocks edits on main.
# Gate 2: Phase gate (blocking) — blocks edits in init/plan phase.
#          Exempt: .claude/.state/, .claude/local/, governance evidence,
#          session types without plan phase. Fail-closed when sentinel
#          present and no phase-state (Decision 0019). Advisory when absent.
# Gate 6: Session overlap check (Decision 0013) — blocks concurrent
#          non-task-group sessions on the same branch. Advisory for task
#          groups. Exempt: taskdef-query, taskdef-brief (Prompt T).
# Gate 5: Session branch isolation (Decision 0013) — blocks edits on
#          branches closed by a previous session. Task group non-final
#          briefs never seal the branch, so no exemption logic needed.
#
# Override: REPO_OS_ALLOW_MAIN=1 (Gate 1), REPO_OS_SKIP_PLAN_GATE=1 (Gate 2),
#           REPO_OS_SKIP_OVERLAP_CHECK=1 (Gate 6), REPO_OS_SKIP_BRANCH_REUSE=1 (Gate 5)
#           REPO_OS_RECOVER=1 (bypass all gates — emergency recovery)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_analytics-helper.sh"
source "$SCRIPT_DIR/_phase-helper.sh"
START_MS=$(now_ms)

# --- Read PreToolUse payload (needed for phase gate path exemptions) ---
INPUT=$(cat)

REPO_ROOT="$(get_repo_root)"
CURRENT_BRANCH=$(get_branch)

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

# --- Gate 2: Phase gate (blocking) — must be past plan to edit ---
# Blocks Edit/Write in init/plan phase (plan not yet approved).
# Exempt: experiment/* branches (Decision 0006), .claude/.state/ (bootstrap),
#         .claude/local/ (session-scoped), governance evidence paths,
#         session types without plan phase.
# Fail-closed when sentinel present, advisory when absent (Decision 0019).
if [ "$ALLOW_REASON" = "pass" ] && [[ "$CURRENT_BRANCH" != experiment/* ]]; then
  CURRENT_PHASE=$(get_phase)
  if [ -n "$CURRENT_PHASE" ]; then
    case "$CURRENT_PHASE" in
      init|plan)
        # Check session type exemptions (cheap — no jq)
        PHASE_EXEMPT=false
        SESSION_TYPE=$(get_session_type)
        case "$SESSION_TYPE" in
          experiment|prototype-napkin|prototype-spike|prototype-poc)
            PHASE_EXEMPT=true
            ;;
        esac

        if [ "$PHASE_EXEMPT" = false ]; then
          # Parse file path for path-based exemptions (jq cost only on block path)
          FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)

          if [ -n "$FILE_PATH" ]; then
            case "$FILE_PATH" in
              "$REPO_ROOT/.claude/.state/"*)
                PHASE_EXEMPT=true ;;
              "$REPO_ROOT/.claude/local/"*)
                PHASE_EXEMPT=true ;;
              "$REPO_ROOT/docs/ai/governance/"*)
                PHASE_EXEMPT=true ;;
              "$REPO_ROOT/docs/ai/task-groups/"*)
                PHASE_EXEMPT=true ;;
            esac
          fi
        fi

        if [ "$PHASE_EXEMPT" = true ]; then
          ALLOW_REASON="phase_exempt"
        else
          log_hook_event "branch-guard-edit" "PreToolUse" "" "block" "$START_MS" "phase_gate" "phase:$CURRENT_PHASE"
          echo "BLOCKED: Session is in '$CURRENT_PHASE' phase — get plan approval before editing files." >&2
          exit 2
        fi
        ;;
    esac
  else
    # Phase-state absent/stale — sentinel controls fail-closed vs advisory (Decision 0019).
    # Check path exemptions before blocking (same paths as init|plan exemptions above).
    _FC_EXEMPT=false
    _FC_FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
    if [ -n "$_FC_FILE_PATH" ]; then
      case "$_FC_FILE_PATH" in
        "$REPO_ROOT/.claude/.state/"*)    _FC_EXEMPT=true ;;
        "$REPO_ROOT/.claude/local/"*)     _FC_EXEMPT=true ;;
        "$REPO_ROOT/docs/ai/governance/"*) _FC_EXEMPT=true ;;
        "$REPO_ROOT/docs/ai/task-groups/"*) _FC_EXEMPT=true ;;
      esac
    fi

    if [ "$_FC_EXEMPT" = true ]; then
      ALLOW_REASON="phase_exempt"
    elif [ "${REPO_OS_SKIP_PLAN_GATE:-0}" = "1" ]; then
      log_override "branch-guard-edit" "REPO_OS_SKIP_PLAN_GATE"
      ALLOW_REASON="plan_gate_override"
    elif [ -f "$REPO_ROOT/docs/ai/decisions/.fail-closed-enforced" ]; then
      log_hook_event "branch-guard-edit" "PreToolUse" "" "block" "$START_MS" "phase_gate_no_state"
      echo "BLOCKED: No phase-state — session not initialized. Call init_phase() via the orchestrator before editing files. (override: REPO_OS_SKIP_PLAN_GATE=1)" >&2
      exit 2
    else
      log_hook_event "branch-guard-edit" "PreToolUse" "" "warn" "$START_MS" "phase_gate_no_state_advisory"
      echo "Advisory: No phase-state found — session may not be initialized. Consider calling init_phase() via the orchestrator." >&2
    fi
  fi
fi

# --- Gate 6: Session overlap check (Decision 0013 concurrent awareness) ---
# Checks for same-branch overlap with another active session.
# Advisory for task groups; blocking for all other types.
# Override: REPO_OS_SKIP_OVERLAP_CHECK=1
if ! check_session_overlap; then
  log_hook_event "branch-guard-edit" "PreToolUse" "" "block" "$START_MS" "session_overlap"
  exit 2
fi

# --- Gate 5: Session branch isolation (blocking, Decision 0013) ---
# Task group non-final briefs no longer seal the branch at close, so
# active task group branches will not appear in closed-branches. No
# contract scanning needed — if the branch is sealed, it's sealed.
CLOSED_BRANCHES_FILE="$REPO_ROOT/.claude/local/closed-branches"

if [ -f "$CLOSED_BRANCHES_FILE" ] && grep -qxF "$CURRENT_BRANCH" "$CLOSED_BRANCHES_FILE" 2>/dev/null; then
  if [ "${REPO_OS_SKIP_BRANCH_REUSE:-0}" = "1" ]; then
    log_override "branch-guard-edit" "REPO_OS_SKIP_BRANCH_REUSE"
    ALLOW_REASON="branch_reuse_override"
  else
    log_hook_event "branch-guard-edit" "PreToolUse" "" "block" "$START_MS" "branch_reused"
    echo "BLOCKED: Branch '$CURRENT_BRANCH' was used by a previous session — create a new branch: git checkout -b <category>/<description> (override: REPO_OS_SKIP_BRANCH_REUSE=1)" >&2
    exit 2
  fi
fi

log_hook_event "branch-guard-edit" "PreToolUse" "" "allow" "$START_MS" "$ALLOW_REASON"
