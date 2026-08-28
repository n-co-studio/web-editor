#!/usr/bin/env bash
# Write guard — unified state + mode enforcement for file modifications.
# Merges state-guard.sh and mode-guard.sh into a single hook to eliminate
# redundant shell forks, stdin reads, and JSON parsing.
#
# Wired to PreToolUse on Edit, Write, and Bash via .claude/settings.json.
#
# Logical ordering (Decision 0012 point 12): state-guard checks first,
# then mode-guard checks, then branch-guard gates. State-guard blocks
# writes to .claude/.state/ and .claude/.session-id. Mode-guard enforces
# operating mode restrictions.
# Section 3 (Edit/Write only): branch-guard gates. Main protection,
# phase gate, session overlap, branch isolation. Consolidated from
# branch-guard-edit.sh (Decision 0012 point 12).
#
# Overrides (state-guard scope):
#   REPO_OS_SKIP_STATE_GUARD=1  — skip state-guard checks
#   REPO_OS_RECOVER=1           — allow recovery writes to .state/
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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ============================================================
# Phase 1: Read stdin + Override pre-checks (builtins only)
# ============================================================

INPUT=$(cat)

# --- State-guard operator overrides (builtins only — no sourced functions) ---
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
  rm -f "$RECOVER_SIGNAL_FILE"
  echo "Recovery signal consumed — bypassing state-guard and mode-guard" >&2
  SKIP_STATE_GUARD=true
fi

# --- Mode-guard operator override (builtins only) ---
SKIP_MODE_GUARD=false
if [ "${REPO_OS_SKIP_MODE_GUARD:-0}" = "1" ]; then
  SKIP_MODE_GUARD=true
fi
if [ "$_RECOVER_VIA_SIGNAL" = true ]; then
  SKIP_MODE_GUARD=true
fi

# If both guards are skipped, fast-exit (no sourcing needed)
if [ "$SKIP_STATE_GUARD" = true ] && [ "$SKIP_MODE_GUARD" = true ]; then
  exit 0
fi

# ============================================================
# Phase 2: Source libraries (single sourcing)
# ============================================================

source "$SCRIPT_DIR/_analytics-helper.sh"
source "$SCRIPT_DIR/_phase-helper.sh"
source "$SCRIPT_DIR/_mode-guard-helper.sh"
START_MS=$(now_ms)

# Log overrides that were detected pre-source
if [ "${REPO_OS_SKIP_STATE_GUARD:-0}" = "1" ]; then
  log_override "state-guard" "REPO_OS_SKIP_STATE_GUARD"
  log_hook_event "state-guard" "PreToolUse" "" "allow" "$START_MS" "skip_override"
fi
if [ "${REPO_OS_RECOVER:-0}" = "1" ]; then
  log_override "state-guard" "REPO_OS_RECOVER"
  log_hook_event "state-guard" "PreToolUse" "" "allow" "$START_MS" "recovery_bypass"
fi
if [ "$_RECOVER_VIA_SIGNAL" = true ]; then
  log_override "state-guard" "recover-signal-file"
  log_hook_event "state-guard" "PreToolUse" "" "allow" "$START_MS" "recovery_signal_file"
fi
if [ "${REPO_OS_SKIP_MODE_GUARD:-0}" = "1" ]; then
  log_override "mode-guard" "REPO_OS_SKIP_MODE_GUARD"
  log_hook_event "mode-guard" "PreToolUse" "" "allow" "$START_MS" "skip_override"
fi

# ============================================================
# Shared: Parse tool call input (single stdin read, single parse)
# ============================================================

# --- jq presence guard (fail-closed) ---
if [ "$_REPO_OS_HAS_JQ" = false ]; then
  echo "GATE-FINAL: jq is required for write-guard but was not found. Install jq (https://jqlang.github.io/jq/download/) and retry. (no override)" >&2
  exit 2
fi

# Single jq invocation for both fields (halves subprocess count)
_jq_out=$(echo "$INPUT" | jq -r '[.tool_input.file_path // "", .tool_input.command // ""] | join("\t")')
_TAB=$(printf '\t')
FILE_PATH="${_jq_out%%${_TAB}*}"
COMMAND="${_jq_out#*${_TAB}}"

# Cache extract_write_targets result (called once, reused by state-guard + mode-guard + bash scanning)
if [ -n "$COMMAND" ]; then
  _CACHED_WRITE_TARGETS=$(extract_write_targets "$COMMAND")
else
  _CACHED_WRITE_TARGETS=""
fi

REPO_ROOT="$_REPO_OS_ROOT"

# ============================================================
# Section 1: State-Guard (blocks writes to .claude/.state/ and .claude/.session-id)
#             + Queue-Guard (blocks writes to .claude/.automation/queue/)
# ============================================================

if [ "$SKIP_STATE_GUARD" = false ]; then
  TARGETS_STATE=false
  STATE_TARGET_PATH=""
  TARGETS_QUEUE=false
  QUEUE_TARGET_PATH=""

  if [ -n "$FILE_PATH" ]; then
    if [[ "$FILE_PATH" == *".claude/.state/"* ]] || [[ "$FILE_PATH" == *".claude/.session-id"* ]]; then
      _fp_abs=$(resolve_path "$FILE_PATH")
      if is_in_repo "$_fp_abs" "$REPO_ROOT"; then
        TARGETS_STATE=true
        STATE_TARGET_PATH="$FILE_PATH"
      fi
    elif [[ "$FILE_PATH" == *".claude/.automation/queue/"* ]]; then
      _fp_abs=$(resolve_path "$FILE_PATH")
      if is_in_repo "$_fp_abs" "$REPO_ROOT"; then
        TARGETS_QUEUE=true
        QUEUE_TARGET_PATH="$FILE_PATH"
      fi
    fi
  fi

  if [ -n "$COMMAND" ]; then
    TARGETS="$_CACHED_WRITE_TARGETS"
    while IFS= read -r WT; do
      [ -z "$WT" ] && continue
      if [[ "$WT" == *".claude/.state/"* ]] || [[ "$WT" == *".claude/.session-id"* ]]; then
        _wt_abs=$(resolve_path "$WT")
        if is_in_repo "$_wt_abs" "$REPO_ROOT"; then
          TARGETS_STATE=true
          STATE_TARGET_PATH="$WT"
        fi
      elif [[ "$WT" == *".claude/.automation/queue/"* ]]; then
        _wt_abs=$(resolve_path "$WT")
        if is_in_repo "$_wt_abs" "$REPO_ROOT"; then
          TARGETS_QUEUE=true
          QUEUE_TARGET_PATH="$WT"
        fi
      fi
    done <<< "$TARGETS"
  fi

  if [ "$TARGETS_STATE" = true ]; then
    STATE_FILE_NAME="${STATE_TARGET_PATH##*.claude/.state/}"
    if [[ "$STATE_TARGET_PATH" == *".claude/.session-id"* ]]; then
      STATE_FILE_NAME=".session-id"
    fi
    log_hook_event "state-guard" "PreToolUse" "" "block" "$START_MS" "state_path_protected" "" "$STATE_FILE_NAME"
    echo "GATE-FINAL: .claude/.state/ is write-protected — state files are managed by governance hooks only. (override: REPO_OS_RECOVER=1)" >&2
    exit 2
  fi

  if [ "$TARGETS_QUEUE" = true ]; then
    QUEUE_FILE_NAME="${QUEUE_TARGET_PATH##*.claude/.automation/queue/}"
    log_hook_event "write-guard" "PreToolUse" "" "block" "$START_MS" "queue_path_protected" "" "$QUEUE_FILE_NAME"
    echo "GATE-FINAL: .claude/.automation/queue/ is write-protected — queue entries are managed by intake.sh and the runner only. (override: REPO_OS_RECOVER=1)" >&2
    exit 2
  fi
fi

# ============================================================
# Section 2: Mode-Guard (enforces operating mode restrictions)
# ============================================================

if [ "$SKIP_MODE_GUARD" = false ]; then

# If neither file_path nor command, nothing to check (Section 3 also needs targets)
if [ -z "$FILE_PATH" ] && [ -z "$COMMAND" ]; then
  exit 0
fi

# Defer .state/ paths to Section 1 — if we reach here, state-guard already
# decided (either allowed via override or the path isn't .state/).
# Mode-guard must not re-block .state/ paths that state-guard intentionally allowed.
if [ -n "$FILE_PATH" ]; then
  RESOLVED_FOR_STATE=$(resolve_path "$FILE_PATH")
  case "$RESOLVED_FOR_STATE" in
    "$REPO_ROOT/.claude/.state/"*|"$REPO_ROOT/.claude/.state")
      exit 0
      ;;
  esac
fi

# --- Resolve operating mode (via get_mode from _analytics-helper.sh) ---
if [ -n "${REPO_OS_MODE:-}" ]; then
  log_override "mode-guard" "REPO_OS_MODE"
fi
MODE=$(get_mode)

# Validate mode
case "$MODE" in
  template|child|autonomous) ;;
  *)
    echo "WARNING: Unknown mode '$MODE' in .claude/repo-mode — defaulting to child" >&2
    MODE="child"
    ;;
esac


# --- Child/autonomous mode checks ---
# In child/autonomous modes, product code always passes. Immune paths, template
# decisions, and non-carved-out governance paths are blocked. Carved-out
# governance paths fall through to Section 3. Template mode uses check_path()
# below for full edit-time enforcement.
if [ "$MODE" != "template" ]; then
  # Immune path check on Edit/Write file_path
  if [ -n "$FILE_PATH" ]; then
    ABS_PATH_FE=$(resolve_path "$FILE_PATH")
    if is_in_repo "$ABS_PATH_FE" "$REPO_ROOT"; then
      REL_PATH_FE=$(make_relative "$FILE_PATH")
      if is_immune "$REL_PATH_FE"; then
        log_hook_event "mode-guard" "PreToolUse" "" "block" "$START_MS" "file_immune_path" "" "$REL_PATH_FE"
        echo "GATE-FINAL: $REL_PATH_FE is an immune path — cannot be modified in any mode. (no override)" >&2
        exit 2
      fi
      # Template decision protection — t-*.md files are immutable in child/autonomous modes (Decision 0022)
      case "$REL_PATH_FE" in
        docs/ai/decisions/t-*.md)
          # Check REPO_OS_UNLOCK_PATH override before blocking
          if [ -n "${REPO_OS_UNLOCK_PATH:-}" ]; then
            _UNLOCK_REL_FE=$(make_relative "$REPO_OS_UNLOCK_PATH")
            if [ "$REL_PATH_FE" = "$_UNLOCK_REL_FE" ]; then
              log_override "mode-guard" "REPO_OS_UNLOCK_PATH"
              log_hook_event "mode-guard" "PreToolUse" "" "allow" "$START_MS" "unlock_path" "" "$REL_PATH_FE"
              exit 0
            fi
          fi
          log_hook_event "mode-guard" "PreToolUse" "" "block" "$START_MS" "file_template_decision" "" "$REL_PATH_FE"
          echo "GATE-FINAL: $REL_PATH_FE is a template decision (t-* prefix) — immutable in '$MODE' mode (override: REPO_OS_UNLOCK_PATH=$REL_PATH_FE or REPO_OS_SKIP_MODE_GUARD=1)" >&2
          exit 2
          ;;
      esac
      # Governance path check for child/autonomous modes (edit-time enforcement)
      if is_governance "$REL_PATH_FE"; then
        if ! is_carved_out "$MODE" "$REL_PATH_FE"; then
          # Check REPO_OS_UNLOCK_PATH override before blocking
          if [ -n "${REPO_OS_UNLOCK_PATH:-}" ]; then
            _UNLOCK_REL_FE=$(make_relative "$REPO_OS_UNLOCK_PATH")
            if [ "$REL_PATH_FE" = "$_UNLOCK_REL_FE" ]; then
              log_override "mode-guard" "REPO_OS_UNLOCK_PATH"
              log_hook_event "mode-guard" "PreToolUse" "" "allow" "$START_MS" "unlock_path" "" "$REL_PATH_FE"
              exit 0
            fi
          fi
          log_hook_event "mode-guard" "PreToolUse" "" "block" "$START_MS" "file_governance_${MODE}" "" "$REL_PATH_FE"
          echo "GATE-FINAL: $REL_PATH_FE is a governance path — not editable in '$MODE' mode (override: REPO_OS_UNLOCK_PATH=$REL_PATH_FE or REPO_OS_SKIP_MODE_GUARD=1)" >&2
          exit 2
        fi
        # Governance AND carved out — fall through to Section 3
      fi
    fi
  fi
  # Immune path check on Bash write targets (redirect/tee)
  if [ -n "$COMMAND" ] && [ -z "$FILE_PATH" ]; then
    FE_TARGETS="$_CACHED_WRITE_TARGETS"
    while IFS= read -r FE_WT; do
      [ -z "$FE_WT" ] && continue
      FE_WT_ABS=$(resolve_path "$FE_WT")
      if is_in_repo "$FE_WT_ABS" "$REPO_ROOT"; then
        FE_WT_REL=$(make_relative "$FE_WT")
        if is_immune "$FE_WT_REL"; then
          log_hook_event "mode-guard" "PreToolUse" "" "block" "$START_MS" "bash_immune_path" "" "$FE_WT_REL"
          echo "GATE-FINAL: $FE_WT_REL is an immune path — cannot be modified in any mode. (no override)" >&2
          exit 2
        fi
        # Template decision protection — t-*.md files are immutable in child/autonomous modes (Decision 0022)
        case "$FE_WT_REL" in
          docs/ai/decisions/t-*.md)
            log_hook_event "mode-guard" "PreToolUse" "" "block" "$START_MS" "bash_template_decision" "" "$FE_WT_REL"
            echo "GATE-FINAL: $FE_WT_REL is a template decision (t-* prefix) — immutable in '$MODE' mode (override: REPO_OS_UNLOCK_PATH=$FE_WT_REL or REPO_OS_SKIP_MODE_GUARD=1)" >&2
            exit 2
            ;;
        esac
        # Governance path check for child/autonomous modes (edit-time enforcement)
        if is_governance "$FE_WT_REL"; then
          if ! is_carved_out "$MODE" "$FE_WT_REL"; then
            # Check REPO_OS_UNLOCK_PATH override before blocking
            if [ -n "${REPO_OS_UNLOCK_PATH:-}" ]; then
              _UNLOCK_REL_WT=$(make_relative "$REPO_OS_UNLOCK_PATH")
              if [ "$FE_WT_REL" = "$_UNLOCK_REL_WT" ]; then
                log_override "mode-guard" "REPO_OS_UNLOCK_PATH"
                log_hook_event "mode-guard" "PreToolUse" "" "allow" "$START_MS" "unlock_path" "" "$FE_WT_REL"
                exit 0
              fi
            fi
            log_hook_event "mode-guard" "PreToolUse" "" "block" "$START_MS" "bash_governance_${MODE}" "" "$FE_WT_REL"
            echo "GATE-FINAL: $FE_WT_REL is a governance path — not editable in '$MODE' mode (override: REPO_OS_UNLOCK_PATH=$FE_WT_REL or REPO_OS_SKIP_MODE_GUARD=1)" >&2
            exit 2
          fi
          # Governance AND carved out — fall through
        fi
      fi
    done <<< "$FE_TARGETS"
  fi
  log_hook_event "mode-guard" "PreToolUse" "" "allow" "$START_MS" "fast_exit_${MODE}"
  # Fall through to Section 3
fi

# --- Check a single path against mode restrictions ---
check_path() {
  local rel="$1"
  local context="$2"  # "file" or "bash"

  # Immune paths — block unconditionally, no override (structural anchor)
  if is_immune "$rel"; then
    log_hook_event "mode-guard" "PreToolUse" "" "block" "$START_MS" "${context}_immune_path" "" "$rel"
    echo "GATE-FINAL: $rel is an immune path — cannot be modified in any mode. (no override)" >&2
    exit 2
  fi

  # Belt-and-suspenders: unresolved shell variable — cannot classify, fail-closed.
  # The caller loop catches this first; this handles any path that slips through.
  if has_unresolved_var "$rel"; then
    log_hook_event "mode-guard" "PreToolUse" "" "block" "$START_MS" "${context}_unresolved_var" "" "$rel"
    echo "GATE-RECOVERABLE: write target '$rel' contains an unresolved shell variable — the mode guard cannot determine the target location. Use a literal path instead. (override: REPO_OS_SKIP_MODE_GUARD=1)" >&2
    exit 2
  fi

  # Belt-and-suspenders: absolute path outside repo — no mode-guard jurisdiction.
  if is_out_of_repo "$rel"; then
    log_hook_event "mode-guard" "PreToolUse" "" "allow" "$START_MS" "${context}_out_of_repo_bs" "" "$rel"
    return 0
  fi

  # REPO_OS_UNLOCK_PATH — single-file governance unlock
  if [ -n "${REPO_OS_UNLOCK_PATH:-}" ]; then
    UNLOCK_REL=$(make_relative "$REPO_OS_UNLOCK_PATH")
    if [ "$rel" = "$UNLOCK_REL" ]; then
      log_override "mode-guard" "REPO_OS_UNLOCK_PATH"
      log_hook_event "mode-guard" "PreToolUse" "" "allow" "$START_MS" "unlock_path" "" "$rel"
      exit 0
    fi
  fi

  # Governance vs product
  if is_governance "$rel"; then
    if ! is_carved_out "$MODE" "$rel"; then
      log_hook_event "mode-guard" "PreToolUse" "" "block" "$START_MS" "${context}_governance_${MODE}" "" "$rel"
      echo "GATE-RECOVERABLE: $rel is a governance path — not editable in '$MODE' mode (override: REPO_OS_UNLOCK_PATH=$rel or REPO_OS_SKIP_MODE_GUARD=1)" >&2
      exit 2
    fi
  else
    # Product code
    if [ "$MODE" = "template" ]; then
      log_hook_event "mode-guard" "PreToolUse" "" "block" "$START_MS" "${context}_product_in_template" "" "$rel"
      echo "GATE-RECOVERABLE: $rel is a product path — not editable in 'template' mode. NEXT: Use child or autonomous mode for product code. (override: REPO_OS_SKIP_MODE_GUARD=1)" >&2
      exit 2
    fi
  fi
}

# --- Resolve path for allow event (best-effort) ---
ALLOW_PATH=""

# --- File path check (Edit/Write) ---
if [ -n "$FILE_PATH" ]; then
  ABS_PATH=$(resolve_path "$FILE_PATH")
  if ! is_in_repo "$ABS_PATH" "$REPO_ROOT"; then
    log_hook_event "mode-guard" "PreToolUse" "" "allow" "$START_MS" "out_of_repo" "" "$FILE_PATH"
    exit 0
  fi
  REL_PATH=$(make_relative "$FILE_PATH")
  ALLOW_PATH="$REL_PATH"
  check_path "$REL_PATH" "file"
fi

# --- Bash command scanning for write patterns ---
if [ -n "$COMMAND" ] && [ -z "$FILE_PATH" ]; then
  # Extract write targets via shared helper
  TARGETS="$_CACHED_WRITE_TARGETS"
  while IFS= read -r WT; do
    [ -z "$WT" ] && continue
    # Sub-case 2: unresolved shell variable — cannot classify, fail-closed.
    # Must check before resolve_path, which would misinterpret $VAR as relative.
    if has_unresolved_var "$WT"; then
      log_hook_event "mode-guard" "PreToolUse" "" "block" "$START_MS" "bash_unresolved_var" "" "$WT"
      echo "GATE-RECOVERABLE: write target '$WT' contains an unresolved shell variable — the mode guard cannot determine the target location. Use a literal path instead. (override: REPO_OS_SKIP_MODE_GUARD=1)" >&2
      exit 2
    fi
    WT_ABS=$(resolve_path "$WT")
    # Sub-case 1: path outside repo — no mode-guard jurisdiction; log and skip.
    if ! is_in_repo "$WT_ABS" "$REPO_ROOT"; then
      log_hook_event "mode-guard" "PreToolUse" "" "allow" "$START_MS" "bash_out_of_repo_skip" "" "$WT"
      continue
    fi
    WT_REL=$(make_relative "$WT")
    [ -z "$ALLOW_PATH" ] && ALLOW_PATH="$WT_REL"
    check_path "$WT_REL" "bash"
  done <<< "$TARGETS"
fi

# --- Mode-guard allow (Section 2 complete) ---
log_hook_event "mode-guard" "PreToolUse" "" "allow" "$START_MS" "pass_${MODE}" "" "$ALLOW_PATH"

fi  # end if [ "$SKIP_MODE_GUARD" = false ]

# ============================================================
# Section 3: Branch-Guard Gates (Edit/Write only)
# Consolidated from branch-guard-edit.sh (Decision 0012 point 12):
#   Gate 1: Main branch protection
#   Gate 2: Phase gate (init/plan blocking)
#   Gate 6: Session overlap (Decision 0013)
#   Gate 5: Session branch isolation (Decision 0013)
#
# Bash calls are handled by bash-guard.sh separately.
# Override: REPO_OS_RECOVER=1 or .recover-signal (bypass all gates)
# ============================================================

# Branch-guard only applies to Edit/Write (file_path present)
if [ -n "$FILE_PATH" ]; then

  if [ "${REPO_OS_RECOVER:-0}" != "1" ] && [ "$_RECOVER_VIA_SIGNAL" != true ]; then

    CURRENT_BRANCH=$(get_branch)
    BG_ALLOW_REASON="pass"

    # --- Taskdef/queue-triage session-type gate (before Gate 1) ---
    # taskdef-query, taskdef-brief, and queue-triage operate on main by design.
    # They bypass the main-branch gate but are subject to their own write restrictions.
    # taskdef-query, queue-triage: fully read-only — block all writes.
    # taskdef-brief: queue intake only — allow .automation/briefs/, block all else.
    _WG_SESSION_TYPE=$(get_session_type)
    if [ "$_WG_SESSION_TYPE" = "taskdef-query" ] || [ "$_WG_SESSION_TYPE" = "taskdef-brief" ] || [ "$_WG_SESSION_TYPE" = "queue-triage" ]; then
      if [ "$_WG_SESSION_TYPE" = "taskdef-query" ] || [ "$_WG_SESSION_TYPE" = "queue-triage" ]; then
        log_hook_event "write-guard" "PreToolUse" "" "block" "$START_MS" "taskdef_query_no_write"
        echo "GATE-FINAL: ${_WG_SESSION_TYPE} sessions are read-only." >&2
        exit 2
      fi
      # taskdef-brief: allow only .automation/briefs/ writes, skip main-branch gate
      if [[ "$FILE_PATH" == *".claude/.automation/briefs/"* ]]; then
        log_hook_event "write-guard" "PreToolUse" "" "allow" "$START_MS" "taskdef_brief_queue_intake"
        exit 0
      fi
      # taskdef-brief writing anywhere else is blocked
      log_hook_event "write-guard" "PreToolUse" "" "block" "$START_MS" "taskdef_brief_non_intake_write"
      echo "GATE-FINAL: taskdef-brief sessions may only write to .claude/.automation/briefs/ (queue intake)." >&2
      exit 2
    fi

    # --- Gate 1: Main branch protection ---
    if [ "$CURRENT_BRANCH" = "main" ] && [ "${REPO_OS_ALLOW_MAIN:-0}" != "1" ]; then
      log_hook_event "write-guard" "PreToolUse" "" "block" "$START_MS" "main_branch"
      echo "GATE-RECOVERABLE: On main branch. NEXT: git checkout -b feature/<description>. (override: REPO_OS_ALLOW_MAIN=1)" >&2
      exit 2
    fi
    if [ "$CURRENT_BRANCH" = "main" ] && [ "${REPO_OS_ALLOW_MAIN:-0}" = "1" ]; then
      log_override "write-guard" "REPO_OS_ALLOW_MAIN"
      BG_ALLOW_REASON="main_override"
    fi

    # --- Gate 2: Phase gate (blocking) — must be past plan to edit ---
    if [ "$BG_ALLOW_REASON" = "pass" ] && [[ "$CURRENT_BRANCH" != experiment/* ]]; then
      CURRENT_PHASE=$(get_phase)
      if [ -n "$CURRENT_PHASE" ]; then
        case "$CURRENT_PHASE" in
          init|plan)
            PHASE_EXEMPT=false
            SESSION_TYPE=$(get_session_type)
            case "$SESSION_TYPE" in
              experiment|prototype-napkin|prototype-spike|prototype-poc|editor-live)
                PHASE_EXEMPT=true
                ;;
            esac

            if [ "$PHASE_EXEMPT" = false ]; then
              # Path-based exemptions (reuse FILE_PATH already parsed above)
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
              BG_ALLOW_REASON="phase_exempt"
            else
              log_hook_event "write-guard" "PreToolUse" "" "block" "$START_MS" "phase_gate" "phase:$CURRENT_PHASE"
              echo "GATE-RECOVERABLE: Session in '$CURRENT_PHASE' phase — Edit/Write blocked until plan approved. NEXT: Call AskUserQuestion with your plan summary. Include options: \"Auto — proceed autonomously\" and \"Review — pause for my review before commit\". Conversational confirmation does NOT trigger the approval hook. (override: REPO_OS_SKIP_PLAN_GATE=1)" >&2
              exit 2
            fi
            ;;
        esac

        # --- Gate 2 (phase-type): Session-type-specific write-phase enforcement ---
        # Extends the init|plan gate above to enforce write-allowed phases per session type.
        # Example: finish-loop sessions may only write during fix and commit phases.
        # Runs for all non-init|plan phases when BG_ALLOW_REASON is still "pass".
        # Override: REPO_OS_SKIP_PLAN_GATE=1
        if [ "$BG_ALLOW_REASON" = "pass" ]; then
          _WG2T_STYPE=$(get_session_type)
          _WG2T_ALLOWED=$(get_write_phases_for_type "$_WG2T_STYPE")
          # "all" means the session type is fully exempt from write-phase restrictions
          if [ "$_WG2T_ALLOWED" != "all" ] && [ -n "$_WG2T_STYPE" ]; then
            _WG2T_OK=false
            # Path-based exemptions (same set as init|plan gate above)
            if [ -n "$FILE_PATH" ]; then
              case "$FILE_PATH" in
                "$REPO_ROOT/.claude/.state/"*|\
                "$REPO_ROOT/.claude/local/"*|\
                "$REPO_ROOT/docs/ai/governance/"*|\
                "$REPO_ROOT/docs/ai/task-groups/"*)
                  _WG2T_OK=true ;;
              esac
            fi
            # Phase membership check
            if [ "$_WG2T_OK" = false ]; then
              for _wg2t_p in $_WG2T_ALLOWED; do
                if [ "$_wg2t_p" = "$CURRENT_PHASE" ]; then
                  _WG2T_OK=true
                  break
                fi
              done
            fi
            if [ "$_WG2T_OK" = false ]; then
              if [ "${REPO_OS_SKIP_PLAN_GATE:-0}" = "1" ]; then
                log_override "write-guard" "REPO_OS_SKIP_PLAN_GATE"
              else
                log_hook_event "write-guard" "PreToolUse" "" "block" "$START_MS" "phase_gate_type" "type:$_WG2T_STYPE,phase:$CURRENT_PHASE"
                echo "GATE-RECOVERABLE: Session type '$_WG2T_STYPE' in '$CURRENT_PHASE' phase — Edit/Write only permitted during: ${_WG2T_ALLOWED:-none}. NEXT: Advance to the correct write phase before editing. (override: REPO_OS_SKIP_PLAN_GATE=1)" >&2
                exit 2
              fi
            fi
          fi
        fi
      else
        # Phase-state absent/stale — sentinel controls fail-closed vs advisory (Decision 0019)
        _FC_EXEMPT=false
        if [ -n "$FILE_PATH" ]; then
          case "$FILE_PATH" in
            "$REPO_ROOT/.claude/.state/"*)    _FC_EXEMPT=true ;;
            "$REPO_ROOT/.claude/local/"*)     _FC_EXEMPT=true ;;
            "$REPO_ROOT/docs/ai/governance/"*) _FC_EXEMPT=true ;;
            "$REPO_ROOT/docs/ai/task-groups/"*) _FC_EXEMPT=true ;;
          esac
        fi

        if [ "$_FC_EXEMPT" = true ]; then
          BG_ALLOW_REASON="phase_exempt"
        elif [ "${REPO_OS_SKIP_PLAN_GATE:-0}" = "1" ]; then
          log_override "write-guard" "REPO_OS_SKIP_PLAN_GATE"
          BG_ALLOW_REASON="plan_gate_override"
        elif [ -f "$REPO_ROOT/docs/ai/decisions/.fail-closed-enforced" ]; then
          log_hook_event "write-guard" "PreToolUse" "" "block" "$START_MS" "phase_gate_no_state"
          echo "GATE-RECOVERABLE: No phase-state — session not initialized. NEXT: Call init_phase() via the orchestrator. (override: REPO_OS_SKIP_PLAN_GATE=1)" >&2
          exit 2
        else
          log_hook_event "write-guard" "PreToolUse" "" "warn" "$START_MS" "phase_gate_no_state_advisory"
          echo "Advisory: No phase-state found — session may not be initialized. Consider calling init_phase() via the orchestrator." >&2
        fi
      fi
    fi

    # --- Gate 2b: Taskgroup brief mismatch check (Decision 0026) ---
    # Blocks if brief contains ### Task Group but session type is not taskgroup/taskgroup-merge.
    check_taskgroup_brief_mismatch "$START_MS"

    # --- Gates 5 + 6: Session overlap + branch isolation (Decision 0013) ---
    # Decision 0042: read pre-computed verdicts from <state_dir>/phase-state.gates
    # when the cache is fresh. Cache miss falls through to the inline checks below.
    # Override env vars are checked first in each branch.
    _GATES_CACHE_HIT=0
    if [ "${REPO_OS_SKIP_OVERLAP_CHECK:-0}" != "1" ] || [ "${REPO_OS_SKIP_BRANCH_REUSE:-0}" != "1" ]; then
      if read_phase_gates; then
        _GATES_CACHE_HIT=1
      fi
    fi

    # --- Gate 6: Session overlap check (Decision 0013) ---
    if [ "$_GATES_CACHE_HIT" = "1" ]; then
      if [ "${REPO_OS_SKIP_OVERLAP_CHECK:-0}" = "1" ]; then
        log_override "write-guard" "REPO_OS_SKIP_OVERLAP_CHECK"
      elif [ "$GATES_SESSION_OVERLAP" = "blocked" ]; then
        [ -n "$GATES_SESSION_OVERLAP_DETAIL" ] && echo "$GATES_SESSION_OVERLAP_DETAIL" >&2
        log_hook_event "write-guard" "PreToolUse" "" "block" "$START_MS" "session_overlap" "cache:hit"
        exit 2
      elif [ "$GATES_SESSION_OVERLAP" = "advisory" ] && [ -n "$GATES_SESSION_OVERLAP_DETAIL" ]; then
        # Surface advisory message — parity with check_session_overlap inline path.
        echo "$GATES_SESSION_OVERLAP_DETAIL" >&2
      fi
    else
      if ! check_session_overlap; then
        log_hook_event "write-guard" "PreToolUse" "" "block" "$START_MS" "session_overlap"
        exit 2
      fi
    fi

    # --- Gate 5: Session branch isolation (Decision 0013) ---
    if [ "$_GATES_CACHE_HIT" = "1" ]; then
      if [ "$GATES_BRANCH_ISOLATION" = "blocked" ]; then
        if [ "${REPO_OS_SKIP_BRANCH_REUSE:-0}" = "1" ]; then
          log_override "write-guard" "REPO_OS_SKIP_BRANCH_REUSE"
          BG_ALLOW_REASON="branch_reuse_override"
        else
          log_hook_event "write-guard" "PreToolUse" "" "block" "$START_MS" "branch_reused" "cache:hit"
          echo "GATE-RECOVERABLE: Branch '$CURRENT_BRANCH' was sealed by a previous session. NEXT: git checkout -b <category>/<description>. (override: REPO_OS_SKIP_BRANCH_REUSE=1)" >&2
          exit 2
        fi
      fi
    else
      CLOSED_BRANCHES_FILE="$REPO_ROOT/.claude/local/closed-branches"
      if [ -f "$CLOSED_BRANCHES_FILE" ] && grep -qxF "$CURRENT_BRANCH" "$CLOSED_BRANCHES_FILE" 2>/dev/null; then
        if [ "${REPO_OS_SKIP_BRANCH_REUSE:-0}" = "1" ]; then
          log_override "write-guard" "REPO_OS_SKIP_BRANCH_REUSE"
          BG_ALLOW_REASON="branch_reuse_override"
        else
          log_hook_event "write-guard" "PreToolUse" "" "block" "$START_MS" "branch_reused"
          echo "GATE-RECOVERABLE: Branch '$CURRENT_BRANCH' was sealed by a previous session. NEXT: git checkout -b <category>/<description>. (override: REPO_OS_SKIP_BRANCH_REUSE=1)" >&2
          exit 2
        fi
      fi
    fi

    log_hook_event "write-guard" "PreToolUse" "" "allow" "$START_MS" "$BG_ALLOW_REASON"

  fi  # end REPO_OS_RECOVER guard

fi  # end FILE_PATH guard (Section 3)

exit 0
