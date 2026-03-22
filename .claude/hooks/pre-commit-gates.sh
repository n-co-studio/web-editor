#!/usr/bin/env bash
# Pre-commit gate verification — blocking enforcement.
# Runs automatically before git commit via .claude/settings.json hook.
# Exit non-zero to block the commit.
#
# Gates enforced:
#   Phase — assert_phase commit (blocking, primary check when phase-state active)
#   A4  Safety — secret scanning (always, blocking)
#   State verification — plan-approved, cohesion-reviewed, qa-verified, pragmatist-signed (always blocking)
#   A2  Process — scope check >100 lines (blocking with large-scope override)
#   A6  Task Group — contract staging (blocking)
#   High-risk — pattern detection + sign-off enforcement (blocking)
#   A1  Decision trigger parser (blocking — enforced by .a1-triggers-enforced sentinel)
#
# Overrides:
#   REPO_OS_RECOVER=1    — skip all state-dependent checks (emergency recovery)
#   SKIP_CONTRACT_CHECK=1 — skip A6 contract checks (existence + staging)
#
# Branch profiles:
#   experiment/*  — A4 only (all state checks skipped)
#   hotfix/*      — A2 scope relaxed, A5 cohesion skipped
#   editor-live   — per-loop: A4 only; close: full gates minus plan-approved

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_analytics-helper.sh"
source "$SCRIPT_DIR/_phase-helper.sh"
START_MS=$(now_ms)

# --- jq presence guard (fail-closed) ---
# jq is required for parsing hook payloads. Without it, security gates (A4,
# A1, high-risk) cannot inspect the commit command, so we block rather than
# silently skipping checks. Install jq: https://jqlang.github.io/jq/download/
if ! command -v jq &>/dev/null; then
  echo "GATE-FINAL: jq is required for pre-commit gate checks but was not found." >&2
  echo "  Install jq (https://jqlang.github.io/jq/download/) and retry. (no override)" >&2
  exit 2
fi

REPO_ROOT="$(get_repo_root)"
STATE_DIR="$REPO_ROOT/.claude/.state"
DECISIONS_DIR="$REPO_ROOT/docs/ai/decisions"

FAILED=0
BLOCKED_REASONS=""
WARN_REASONS=""

# Helper: append to block/warn reason lists
block() { BLOCKED_REASONS="${BLOCKED_REASONS:+$BLOCKED_REASONS }$1"; FAILED=1; }
warn()  { WARN_REASONS="${WARN_REASONS:+$WARN_REASONS }$1"; }

# --- Read hook payload (PreToolUse JSON on stdin) ---
INPUT=$(cat)
COMMIT_CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)

# --- REPO_OS_RECOVER override ---
if [ "${REPO_OS_RECOVER:-0}" = "1" ]; then
  log_override "pre-commit-gates" "REPO_OS_RECOVER"
  echo "REPO_OS_RECOVER=1 — skipping all state-dependent checks" >&2
  SKIP_STATE=true
else
  SKIP_STATE=false
fi

# --- Branch detection ---
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
IS_EXPERIMENT=false
IS_HOTFIX=false
[[ "$CURRENT_BRANCH" == experiment/* ]] && IS_EXPERIMENT=true
[[ "$CURRENT_BRANCH" == hotfix/* ]]     && IS_HOTFIX=true

# Experiment branches skip all state checks (Decision 0006)
if [ "$IS_EXPERIMENT" = true ]; then
  SKIP_STATE=true
fi

# --- Staged files (used by multiple checks) ---
STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)

# --- Cached staged diff for content scanning (lazy-loaded, shared by A4 + high-risk + A1) ---
_CACHED_STAGED_DIFF=""
_CACHED_STAGED_DIFF_LOADED=false

_get_staged_diff() {
  if [ "$_CACHED_STAGED_DIFF_LOADED" = false ]; then
    _CACHED_STAGED_DIFF=$(git diff --cached -U0 2>/dev/null || true)
    _CACHED_STAGED_DIFF_LOADED=true
  fi
  printf '%s\n' "$_CACHED_STAGED_DIFF"
}

# ============================================================
# A4: Safety — Secret Scanning (always runs, blocking)
# Scans added lines in staged diff (not working-tree files) to catch
# only what's being committed. Pre-existing secrets are not flagged.
# ============================================================
SECRET_PATTERN='sk_live_|sk_test_|sk-ant-api[0-9]+-[A-Za-z0-9_-]+|ghp_[A-Za-z0-9]|github_pat_[A-Za-z0-9]|glpat-[A-Za-z0-9]|npm_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9]|sk-proj-[A-Za-z0-9]|pypi-[A-Za-z0-9]|AKIA[A-Z0-9]|AIza[A-Za-z0-9]|-----BEGIN.*PRIVATE KEY-----|://[^/:@[:space:]]+:[^/@[:space:]]+@[^[:space:]]+|password[[:space:]]*=[[:space:]]*["\x27][^"\x27]|secret[[:space:]]*=[[:space:]]*["\x27][^"\x27]|token[[:space:]]*=[[:space:]]*["\x27][^"\x27]'

if [ -n "$STAGED_FILES" ]; then
  # Scan added lines only (^+ prefix) from staged diff — catches what's being
  # committed, not pre-existing content. Uses _get_staged_diff lazy cache.
  A4_ADDED_LINES=$(_get_staged_diff | awk '
    /^\+\+\+ / { file=substr($0,5); next }
    /^\+/ && !/^\+\+\+/ { print file ": " substr($0,2) }
  ')
  A4_MATCHES=$(echo "$A4_ADDED_LINES" | grep -iE "$SECRET_PATTERN" 2>/dev/null || true)
  if [ -n "$A4_MATCHES" ]; then
    A4_FIRST_FILE=$(echo "$A4_MATCHES" | head -1 | sed 's/^b\///' | sed 's/: .*//')
    echo "GATE-RECOVERABLE: A4 — possible secret in staged diff: $A4_FIRST_FILE. NEXT: Remove the secret from staged files before committing." >&2
    block "A4_secret_detected"
    log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "A4_secret_detected" "" "$A4_FIRST_FILE"
  fi
fi

# --- Exit early for experiment branches (A4 only) ---
if [ "$IS_EXPERIMENT" = true ]; then
  if [ "$FAILED" -ne 0 ]; then
    log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "$BLOCKED_REASONS"
    echo "Commit blocked by pre-commit gate check." >&2
    exit 1
  fi
  log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "allow" "$START_MS" "experiment_branch"
  exit 0
fi

# --- Editor-live session type detection ---
# Per-loop commits (review NOT in phases_completed): A4 only, skip state checks.
# Close commits (review IS in phases_completed): full gates minus plan-approved.
IS_EDITOR_LIVE_LOOP=false
IS_EDITOR_LIVE_CLOSE=false
if [ "$SKIP_STATE" = false ]; then
  _EL_STYPE=$(get_session_type)
  if [ "$_EL_STYPE" = "editor-live" ]; then
    _EL_STATE_FILE="$REPO_ROOT/.claude/.state/phase-state"
    if [ -f "$_EL_STATE_FILE" ] && _validate_phase_session "$_EL_STATE_FILE"; then
      case ",$_PS_PHASES_COMPLETED," in
        *",review,"*) IS_EDITOR_LIVE_CLOSE=true ;;
        *)            IS_EDITOR_LIVE_LOOP=true ;;
      esac
    else
      # No phase-state or stale session — treat as per-loop (safe default: A4 only)
      IS_EDITOR_LIVE_LOOP=true
    fi
  fi
fi

# Exit early for editor-live per-loop commits (A4 only — same as experiment)
if [ "$IS_EDITOR_LIVE_LOOP" = true ]; then
  if [ "$FAILED" -ne 0 ]; then
    log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "$BLOCKED_REASONS"
    echo "Commit blocked by pre-commit gate check." >&2
    exit 1
  fi
  log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "allow" "$START_MS" "editor_live_loop"
  exit 0
fi

# ============================================================
# Phase Gate: assert_phase commit (blocking — skipped by REPO_OS_RECOVER)
# Primary check: session must have reached commit phase.
# Falls back to individual state files if phase-state absent/stale.
# ============================================================
if [ "$SKIP_STATE" = false ]; then
  CURRENT_PHASE=$(get_phase)
  if [ -n "$CURRENT_PHASE" ]; then
    # Phase-state active — use phase model as primary check
    if ! assert_phase "commit"; then
      echo "GATE-RECOVERABLE: Session in '$CURRENT_PHASE' phase — must reach 'commit' phase. NEXT: Complete QA verification (qa-verifier agent) to advance to commit phase." >&2
      block "phase_gate_not_commit"
      log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "phase_gate_not_commit" "phase:$CURRENT_PHASE"
    fi
  fi
fi

# ============================================================
# State File Verification (always blocking — defense-in-depth)
# Individual state files are checked regardless of phase gate status.
# Defense-in-depth: even if phase gate passes, missing state files block.
# Session-binding (adversarial C1/C4/H4): state files must contain a
# session_id that matches the current .session-id — rejects forged/stale files.
# ============================================================

# --- Headless mode detection (adversarial 4.2) ---
IS_HEADLESS=false
[ "${CLAUDE_HEADLESS:-0}" = "1" ] && IS_HEADLESS=true

# --- Session-id validation helper (adversarial C1/C4/H4) ---
# Returns 0 if state file contains matching session_id, 1 otherwise.
_validate_state_session_id() {
  local state_file="$1"
  [ -f "$state_file" ] || return 1
  local file_sid
  file_sid=$(grep '^session_id:' "$state_file" 2>/dev/null | sed 's/^session_id: *//' | tr -d '[:space:]' | head -1)
  local current_sid
  current_sid=$(cat "$REPO_ROOT/.claude/.session-id" 2>/dev/null || echo "")
  # No current session → skip validation (pre-session context)
  [ -z "$current_sid" ] && return 0
  # State file missing session_id but session exists → forged/stale (reject)
  [ -z "$file_sid" ] && return 1
  [ "$file_sid" = "$current_sid" ]
}

if [ "$SKIP_STATE" = false ]; then
  # plan-approved: required on all non-experiment branches
  # Override: REPO_OS_SKIP_PLAN_GATE=1 (parity with bash-guard plan gate)
  # editor-live: skip (never has plan gate — no approval phase)
  if [ "$IS_EDITOR_LIVE_CLOSE" = true ]; then
    : # editor-live never has plan-approved — skip silently
  elif [ "${REPO_OS_SKIP_PLAN_GATE:-0}" = "1" ]; then
    log_override "pre-commit-gates" "REPO_OS_SKIP_PLAN_GATE"
  elif [ ! -f "$STATE_DIR/plan-approved" ]; then
    if [ "$IS_HEADLESS" = true ]; then
      echo "GATE-RECOVERABLE: plan-approved state file missing. NEXT: Write escalation file to .claude/.automation/escalations/ with type 'governance-block'. (override: REPO_OS_SKIP_PLAN_GATE=1)" >&2
    else
      echo "GATE-RECOVERABLE: plan-approved state file missing. NEXT: Use AskUserQuestion to present plan for operator approval (triggers plan-approval hook). (override: REPO_OS_SKIP_PLAN_GATE=1)" >&2
    fi
    block "state_plan_missing"
    log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "state_plan_missing"
  elif ! _validate_state_session_id "$STATE_DIR/plan-approved"; then
    echo "GATE-RECOVERABLE: plan-approved state file has stale session_id (from a different session). NEXT: Re-approve plan in this session. (override: REPO_OS_SKIP_PLAN_GATE=1)" >&2
    block "state_plan_stale_session"
    log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "state_plan_stale_session"
  fi

  # cohesion-reviewed: required except on hotfix/* (A5 skipped per gate profile)
  if [ "$IS_HOTFIX" = false ] && [ ! -f "$STATE_DIR/cohesion-reviewed" ]; then
    echo "GATE-RECOVERABLE: cohesion-reviewed state file missing. NEXT: Dispatch Critic agent in cohesion mode (after Builder completes, before QA). (override: REPO_OS_RECOVER=1)" >&2
    block "state_cohesion_missing"
    log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "state_cohesion_missing"
  elif [ "$IS_HOTFIX" = false ] && [ -f "$STATE_DIR/cohesion-reviewed" ] && ! _validate_state_session_id "$STATE_DIR/cohesion-reviewed"; then
    echo "GATE-RECOVERABLE: cohesion-reviewed state file has stale session_id. NEXT: Re-run Critic cohesion review in this session. (override: REPO_OS_RECOVER=1)" >&2
    block "state_cohesion_stale_session"
    log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "state_cohesion_stale_session"
  fi

  # qa-verified: required on all non-experiment branches
  if [ ! -f "$STATE_DIR/qa-verified" ]; then
    echo "GATE-RECOVERABLE: qa-verified state file missing. NEXT: Dispatch QA verification agent (after Critic cohesion review passes). (override: REPO_OS_RECOVER=1)" >&2
    block "state_qa_missing"
    log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "state_qa_missing"
  elif [ -f "$STATE_DIR/qa-verified" ] && ! _validate_state_session_id "$STATE_DIR/qa-verified"; then
    echo "GATE-RECOVERABLE: qa-verified state file has stale session_id. NEXT: Re-run QA verification in this session. (override: REPO_OS_RECOVER=1)" >&2
    block "state_qa_stale_session"
    log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "state_qa_stale_session"
  fi

  # pragmatist-signed: required on session types with an approval phase (Decision 0025)
  # Sentinel: .pragmatist-enforced — persistent marker (lives in .claude/local/, not
  # .claude/.state/) indicating the gate has been deployed. Sessions started before
  # this gate was deployed will not have a pragmatist-signed state file. The sentinel
  # is written on first enforcement, preventing false positives on legacy sessions.
  # Lifecycle: persistent across sessions (not cleaned by session cleanup).
  # editor-live: skip (no approval phase)
  PRAGMATIST_SENTINEL="$REPO_ROOT/.claude/local/.pragmatist-enforced"
  if [ "$IS_EDITOR_LIVE_CLOSE" = true ]; then
    : # editor-live never has pragmatist-signed — skip silently
  elif [ "${REPO_OS_SKIP_PRAGMATIST_GATE:-0}" = "1" ]; then
    log_override "pre-commit-gates" "REPO_OS_SKIP_PRAGMATIST_GATE"
  else
    # Only enforce on session types that have an approval phase
    _PCG_STYPE=$(get_session_type)
    if has_plan_gate "$_PCG_STYPE"; then
      if [ ! -f "$PRAGMATIST_SENTINEL" ]; then
        # First enforcement: write sentinel and skip check (backward compat)
        printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$PRAGMATIST_SENTINEL" 2>/dev/null || true
        log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "allow" "$START_MS" "pragmatist_sentinel_created"
      elif [ ! -f "$STATE_DIR/pragmatist-signed" ]; then
        echo "GATE-RECOVERABLE: pragmatist-signed state file missing. NEXT: Dispatch Pragmatist agent in plan-gating mode before presenting plan to operator (Decision 0025). (override: REPO_OS_SKIP_PRAGMATIST_GATE=1)" >&2
        block "state_pragmatist_missing"
        log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "state_pragmatist_missing"
      elif ! _validate_state_session_id "$STATE_DIR/pragmatist-signed"; then
        echo "GATE-RECOVERABLE: pragmatist-signed state file has stale session_id. NEXT: Re-dispatch Pragmatist in this session. (override: REPO_OS_SKIP_PRAGMATIST_GATE=1)" >&2
        block "state_pragmatist_stale_session"
        log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "state_pragmatist_stale_session"
      fi
    fi
  fi
fi

# ============================================================
# Gate 3: Inter-session governance (advisory, first-fire)
# Moved from former branch-guard Edit/Write to commit-time.
# Checks that Prompt 0 (spec-compiled) and Prompt A (advisory-reviewed)
# governance files exist before committing Prompt B work.
# Non-blocking: prints warnings, does not block commit.
# ============================================================
if [ "$SKIP_STATE" = false ]; then
  GOVERNANCE_CHECKED_FILE="$STATE_DIR/governance-checked"

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
      MISSING_FILES=""
      [ ! -f "$GOV_DIR/spec-compiled" ] && MISSING_FILES="spec-compiled"
      [ ! -f "$GOV_DIR/advisory-reviewed" ] && MISSING_FILES="${MISSING_FILES:+$MISSING_FILES,}advisory-reviewed"
      warn "gate3_gov_warning"
      log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "warn" "$START_MS" "gate3_gov_warning" "$MISSING_FILES"
    fi

    mkdir -p "$STATE_DIR" 2>/dev/null || true
    echo "checked" > "$GOVERNANCE_CHECKED_FILE" 2>/dev/null || true
  fi
fi

# ============================================================
# A2: Process — Scope Check (blocking with large-scope override)
# Hotfix branches: A2 scope relaxed (skip check entirely)
# ============================================================
if [ "$SKIP_STATE" = false ] && [ "$IS_HOTFIX" = false ] && [ -n "$STAGED_FILES" ]; then
  LINES_CHANGED=$(git diff --cached --numstat | awk '{s+=$1+$2} END {print s+0}')
  # Emit scope metric event for trend analysis (even for passing commits)
  log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "allow" "$START_MS" "A2_scope_check" "lines:$LINES_CHANGED"
  if [ "$LINES_CHANGED" -gt 100 ]; then
    # Check large-scope flag in plan-approved state file
    LARGE_SCOPE=false
    if [ -f "$STATE_DIR/plan-approved" ] && grep -q 'large-scope: true' "$STATE_DIR/plan-approved"; then
      LARGE_SCOPE=true
    fi
    if [ "$LARGE_SCOPE" = false ]; then
      echo "GATE-RECOVERABLE: A2 — $LINES_CHANGED lines changed, exceeds 100-line threshold. NEXT: Get large-scope approval (include 'large-scope: true' in plan-approved state file via AskUserQuestion)." >&2
      block "A2_scope_exceeded"
      log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "A2_scope_exceeded" "lines:$LINES_CHANGED"
    fi
  fi
fi

# ============================================================
# A6: Task Group — Contract Checks (blocking)
# Override: SKIP_CONTRACT_CHECK=1
# A6.1: Contract existence — task group sessions must have an active contract.
# A6.2: Contract staging — modified contracts must be staged.
# Note: Template-mode contracts live in .claude/local/task-groups/ (gitignored),
# so git diff won't detect them — A6.2 staging check is inherently N/A for those.
# A6.1 uses filesystem check (not git diff), so it works in both modes.
# ============================================================
if [ "${SKIP_CONTRACT_CHECK:-0}" = "1" ]; then
  log_override "pre-commit-gates" "SKIP_CONTRACT_CHECK"
fi
if [ "$SKIP_STATE" = false ] && [ "${SKIP_CONTRACT_CHECK:-0}" != "1" ]; then
  # Three-tier resolution: REPO_OS_MODE env var > .claude/repo-mode file > default "child"
  if [ "$(get_mode)" = "template" ]; then
    CONTRACT_DIR="$REPO_ROOT/.claude/local/task-groups"
  else
    CONTRACT_DIR="$REPO_ROOT/docs/ai/task-groups"
  fi

  # A6.1: Contract existence (blocking for task group sessions, Decision 0018)
  # Task group sessions must have a contract with status: in_progress before
  # committing. Prevents the failure where an agent commits without ever
  # creating the contract during contract-init phase.
  A6_SESSION_TYPE=$(get_session_type)
  if [ "$A6_SESSION_TYPE" = "taskgroup" ] || [ "$A6_SESSION_TYPE" = "taskgroup-merge" ]; then
    CONTRACT_FOUND=false
    if [ -d "$CONTRACT_DIR" ]; then
      for _a6_cf in "$CONTRACT_DIR"/*.yaml; do
        [ -f "$_a6_cf" ] || continue
        # Skip template files (prefixed with _)
        case "$(basename "$_a6_cf")" in _*) continue ;; esac
        if grep -q "status: in_progress" "$_a6_cf" 2>/dev/null; then
          CONTRACT_FOUND=true
          break
        fi
      done
    fi
    if [ "$CONTRACT_FOUND" = false ]; then
      echo "GATE-RECOVERABLE: A6 — task group session ($A6_SESSION_TYPE) but no contract with 'status: in_progress'. NEXT: Create the contract during contract-init phase. (override: SKIP_CONTRACT_CHECK=1)" >&2
      block "A6_contract_missing"
      log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "A6_contract_missing" "session_type:$A6_SESSION_TYPE"
    fi
  fi

  # A6.2: Contract staging (blocking for all sessions with modified contracts)
  if [ -d "$CONTRACT_DIR" ]; then
    UNSTAGED_CONTRACTS=$(git diff --name-only -- "$CONTRACT_DIR"/*.yaml 2>/dev/null || true)
    if [ -n "$UNSTAGED_CONTRACTS" ]; then
      NOT_STAGED=""
      while IFS= read -r CF; do
        [ -z "$CF" ] && continue
        if ! echo "$STAGED_FILES" | grep -qxF "$CF"; then
          NOT_STAGED="${NOT_STAGED:+$NOT_STAGED, }$CF"
        fi
      done <<< "$UNSTAGED_CONTRACTS"
      if [ -n "$NOT_STAGED" ]; then
        echo "GATE-RECOVERABLE: A6 — task group contract modified but not staged: $NOT_STAGED. NEXT: Stage the contract with git add." >&2
        block "A6_contract_unstaged"
        log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "A6_contract_unstaged" "" "$NOT_STAGED"
      fi
    fi
  fi
fi

# ============================================================
# Scope Classification Gate (blocking for out-of-scope, advisory for unbriefed)
# Compares staged files against task contract scope_files list.
# Skip: no contract, no scope_files, experiment, REPO_OS_RECOVER.
# ============================================================
if [ "$SKIP_STATE" = false ] && [ -n "$STAGED_FILES" ]; then
  CONTRACT_FILE="$REPO_ROOT/.claude/local/task-contract.yaml"
  if [ -f "$CONTRACT_FILE" ]; then
    # Extract scope_files list from contract (YAML list items after scope_files:)
    SCOPE_FILES=""
    _IN_SCOPE=false
    while IFS= read -r _sc_line; do
      case "$_sc_line" in
        "scope_files:"*) _IN_SCOPE=true; continue ;;
        "  - "*)
          if [ "$_IN_SCOPE" = true ]; then
            _sf_val="${_sc_line#  - }"
            # Strip surrounding quotes if present
            _sf_val="${_sf_val#\"}"
            _sf_val="${_sf_val%\"}"
            SCOPE_FILES="${SCOPE_FILES:+$SCOPE_FILES
}$_sf_val"
          fi
          ;;
        *)
          # Non-list-item line after scope_files: ends the block
          if [ "$_IN_SCOPE" = true ]; then
            _IN_SCOPE=false
          fi
          ;;
      esac
    done < "$CONTRACT_FILE"

    if [ -n "$SCOPE_FILES" ]; then
      # Collect parent directories of scope files for unbriefed-in-scope classification
      SCOPE_PARENTS=""
      while IFS= read -r _sp_file; do
        [ -z "$_sp_file" ] && continue
        _sp_parent=$(dirname "$_sp_file")
        [ "$_sp_parent" = "." ] && continue
        # Deduplicate (pure Bash, avoid forks)
        case "
$SCOPE_PARENTS
" in
          *"
$_sp_parent
"*) ;;
          *) SCOPE_PARENTS="${SCOPE_PARENTS:+$SCOPE_PARENTS
}$_sp_parent" ;;
        esac
      done <<< "$SCOPE_FILES"

      OUT_OF_SCOPE_FILES=""
      UNBRIEFED_IN_SCOPE_FILES=""

      while IFS= read -r _staged; do
        [ -z "$_staged" ] && continue
        _classified=false

        # Check exact match against scope_files
        while IFS= read -r _sf; do
          [ -z "$_sf" ] && continue
          if [ "$_staged" = "$_sf" ]; then
            _classified=true
            break
          fi
        done <<< "$SCOPE_FILES"

        if [ "$_classified" = true ]; then
          continue  # briefed — no action needed
        fi

        # Check if parent directory matches any scope file parent (unbriefed-in-scope)
        _staged_parent=$(dirname "$_staged")
        _parent_match=false
        while IFS= read -r _sp; do
          [ -z "$_sp" ] && continue
          if [ "$_staged_parent" = "$_sp" ]; then
            _parent_match=true
            break
          fi
        done <<< "$SCOPE_PARENTS"

        if [ "$_parent_match" = true ]; then
          UNBRIEFED_IN_SCOPE_FILES="${UNBRIEFED_IN_SCOPE_FILES:+$UNBRIEFED_IN_SCOPE_FILES
}$_staged"
        else
          OUT_OF_SCOPE_FILES="${OUT_OF_SCOPE_FILES:+$OUT_OF_SCOPE_FILES
}$_staged"
        fi
      done <<< "$STAGED_FILES"

      # Out-of-scope files: block commit and write escalation
      if [ -n "$OUT_OF_SCOPE_FILES" ]; then
        _oos_first=$(echo "$OUT_OF_SCOPE_FILES" | head -1)
        _oos_count=$(echo "$OUT_OF_SCOPE_FILES" | wc -l | tr -d ' ')
        echo "GATE-RECOVERABLE: Scope — $_oos_count file(s) out of scope: $_oos_first. NEXT: Add files to task contract scope_files or remove from staging." >&2
        block "scope_out_of_scope"
        log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "scope_out_of_scope" "count:$_oos_count" "$_oos_first"

        # Write escalation file for runner integration
        ESC_DIR="$REPO_ROOT/.claude/.automation/escalations"
        mkdir -p "$ESC_DIR" 2>/dev/null || true
        _esc_id="esc-scope-$(date +%Y%m%d-%H%M%S)"
        {
          printf 'escalation:\n'
          printf '  id: "%s"\n' "$_esc_id"
          printf '  queue_entry_id: ""\n'
          printf '  type: "scope-deviation"\n'
          printf '  severity: "blocking"\n'
          printf '  phase_at_exit: "commit"\n'
          printf '  tag_at_exit: "agent"\n'
          printf '  message: "%s file(s) out of scope"\n' "$_oos_count"
          printf '  context: "%s"\n' "$_oos_first"
          printf '  scope_classification: "out-of-scope"\n'
          printf '  risk_gain:\n'
          printf '    risk: ""\n'
          printf '    gain: ""\n'
          printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          printf '  resolved: false\n'
          printf '  resolution: ""\n'
        } > "$ESC_DIR/${_esc_id}.yaml" 2>/dev/null || true
      fi

      # Unbriefed-in-scope files: advisory escalation
      if [ -n "$UNBRIEFED_IN_SCOPE_FILES" ]; then
        _uis_first=$(echo "$UNBRIEFED_IN_SCOPE_FILES" | head -1)
        _uis_count=$(echo "$UNBRIEFED_IN_SCOPE_FILES" | wc -l | tr -d ' ')
        echo "Advisory: $_uis_count file(s) unbriefed-in-scope — in related directories but not in task contract scope_files: $_uis_first" >&2
        warn "scope_unbriefed_in_scope"
        log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "warn" "$START_MS" "scope_unbriefed_in_scope" "count:$_uis_count" "$_uis_first"

        # Write advisory escalation with risk/gain (from state file if populated by agent)
        ESC_DIR="$REPO_ROOT/.claude/.automation/escalations"
        mkdir -p "$ESC_DIR" 2>/dev/null || true
        _esc_id="esc-scope-$(date +%Y%m%d-%H%M%S)-adv"
        _rg_risk=""
        _rg_gain=""
        if [ -f "$STATE_DIR/scope-risk-gain" ]; then
          _rg_risk=$(grep '^risk:' "$STATE_DIR/scope-risk-gain" 2>/dev/null | sed 's/^risk: *//' || true)
          _rg_gain=$(grep '^gain:' "$STATE_DIR/scope-risk-gain" 2>/dev/null | sed 's/^gain: *//' || true)
          # Sanitize for safe YAML embedding (escape backslashes, double quotes)
          _rg_risk="${_rg_risk//\\/\\\\}"; _rg_risk="${_rg_risk//\"/\\\"}"
          _rg_gain="${_rg_gain//\\/\\\\}"; _rg_gain="${_rg_gain//\"/\\\"}"
        fi
        {
          printf 'escalation:\n'
          printf '  id: "%s"\n' "$_esc_id"
          printf '  queue_entry_id: ""\n'
          printf '  type: "scope-deviation"\n'
          printf '  severity: "advisory"\n'
          printf '  phase_at_exit: "commit"\n'
          printf '  tag_at_exit: "agent"\n'
          printf '  message: "%s file(s) unbriefed-in-scope"\n' "$_uis_count"
          printf '  context: "%s"\n' "$_uis_first"
          printf '  scope_classification: "unbriefed-in-scope"\n'
          printf '  risk_gain:\n'
          printf '    risk: "%s"\n' "$_rg_risk"
          printf '    gain: "%s"\n' "$_rg_gain"
          printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          printf '  resolved: false\n'
          printf '  resolution: ""\n'
        } > "$ESC_DIR/${_esc_id}.yaml" 2>/dev/null || true
      fi
    fi
  fi
fi

# ============================================================
# High-Risk Pattern Detection (blocking)
# Requires reviewer-signed + security-signed state files
# ============================================================
if [ "$SKIP_STATE" = false ] && [ -n "$STAGED_FILES" ]; then
  HIGH_RISK=false

  # --- Path-based risk patterns ---
  RISK_PATH_PATTERN='(auth|login|session|payment|billing|crypto|migration|schema)'

  # Filter out test/fixture paths and governance docs before scanning
  NON_TEST_FILES=$(echo "$STAGED_FILES" | grep -vE '(test|fixture|__mocks__)/' || true)
  # Exclude governance docs from risk scanning (false positives on descriptive text)
  NON_TEST_FILES=$(echo "$NON_TEST_FILES" | grep -vE '^(docs/ai/|\.claude/|AI\.md$|CLAUDE\.md$|repo-os-explainer\.html$)' || true)

  if [ -n "$NON_TEST_FILES" ]; then
    RISK_PATH_MATCHES=$(echo "$NON_TEST_FILES" | grep -iE "$RISK_PATH_PATTERN" || true)
    if [ -n "$RISK_PATH_MATCHES" ]; then
      HIGH_RISK=true
    fi
  fi

  # --- Content-based risk patterns (on non-test staged + lines) ---
  if [ "$HIGH_RISK" = false ] && [ -n "$NON_TEST_FILES" ]; then
    RISK_CONTENT_PATTERN='(password|secret|token)'
    # Scan added lines in non-test files only
    _HR_FILE_LIST=$(echo "$NON_TEST_FILES" | tr '\n' '|' | sed 's/|$//')
    RISK_CONTENT_MATCHES=$(_get_staged_diff | awk -v files="$_HR_FILE_LIST" '
      BEGIN { n=split(files, fa, "|"); for(i=1;i<=n;i++) wanted["b/"fa[i]]=1 }
      /^\+\+\+ / { f=substr($0,5); active=(f in wanted) ? 1 : 0; next }
      active && /^\+/ && !/^\+\+\+/ { print }
    ' | grep -iE "$RISK_CONTENT_PATTERN" || true)
    if [ -n "$RISK_CONTENT_MATCHES" ]; then
      HIGH_RISK=true
    fi
  fi

  if [ "$HIGH_RISK" = true ]; then
    # Write audit trail (shell I/O — not blocked by state-guard)
    TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    printf 'timestamp: %s\nreason: high-risk patterns detected in staged files\n' "$TIMESTAMP" \
      > "$STATE_DIR/high-risk-detected" 2>/dev/null || true

    # Check for required sign-offs
    MISSING_SIGNOFFS=""
    if [ ! -f "$STATE_DIR/reviewer-signed" ]; then
      MISSING_SIGNOFFS="reviewer-signed"
    fi
    if [ ! -f "$STATE_DIR/security-signed" ]; then
      MISSING_SIGNOFFS="${MISSING_SIGNOFFS:+$MISSING_SIGNOFFS, }security-signed"
    fi

    if [ -n "$MISSING_SIGNOFFS" ]; then
      echo "GATE-RECOVERABLE: High-risk patterns detected — missing sign-offs: $MISSING_SIGNOFFS. NEXT: Dispatch Reviewer and Security agents for sign-off." >&2
      # Build detail with risk source (path or content match)
      RISK_DETAIL=""
      if [ -n "$RISK_PATH_MATCHES" ]; then
        echo "  Risk paths: $RISK_PATH_MATCHES" >&2
        # Truncate to first match for detail field
        RISK_FIRST=$(echo "$RISK_PATH_MATCHES" | head -1)
        RISK_DETAIL="path:$RISK_FIRST"
      elif [ -n "$RISK_CONTENT_MATCHES" ]; then
        RISK_DETAIL="content:pattern_match"
      fi
      block "high_risk_no_signoff"
      log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "high_risk_no_signoff" "$RISK_DETAIL"
    fi
  fi
fi

# --- Platform guard: timeout command availability ---
# timeout is needed for ReDoS protection on user-supplied regex patterns.
# GNU coreutils provides it on Linux; macOS may lack it (Homebrew: `brew install coreutils`).
_REPO_OS_HAS_TIMEOUT=false
command -v timeout &>/dev/null && _REPO_OS_HAS_TIMEOUT=true
if [ "$_REPO_OS_HAS_TIMEOUT" = false ]; then
  echo "Advisory: 'timeout' command not found — A1 regex matching runs without ReDoS protection. Install coreutils for hardened matching." >&2
fi

# Helper: run grep with optional timeout guard for ReDoS protection.
# Usage: _guarded_grep -E "$pattern" (or -iE, etc.)
_guarded_grep() {
  if [ "$_REPO_OS_HAS_TIMEOUT" = true ]; then
    timeout 2 grep "$@"
  else
    grep "$@"
  fi
}

# ============================================================
# A1: Decision Trigger Parser (blocking — enforced by .a1-triggers-enforced sentinel)
# Uses compiled index (.a1-trigger-index) when present for fast matching.
# Falls back to file-by-file parsing when index is absent.
# ============================================================
if [ -n "$STAGED_FILES" ] && [ -d "$DECISIONS_DIR" ]; then
  A1_BLOCKING=false
  [ -f "$DECISIONS_DIR/.a1-triggers-enforced" ] && A1_BLOCKING=true

  if [ "$A1_BLOCKING" = false ]; then
    warn "A1_advisory_mode"
    echo "Advisory: docs/ai/decisions/.a1-triggers-enforced not found — A1 decision triggers running in advisory mode (not blocking)" >&2
    # In headless mode, stderr advisories are invisible to operators.
    # Write escalation file for visibility (audit 4.3).
    if [ "$IS_HEADLESS" = true ]; then
      _A1_ESC_DIR="$REPO_ROOT/.claude/.automation/escalations"
      mkdir -p "$_A1_ESC_DIR" 2>/dev/null || true
      {
        printf 'escalation:\n'
        printf '  type: "governance-block"\n'
        printf '  severity: "advisory"\n'
        printf '  message: "A1 triggers running in advisory mode — .a1-triggers-enforced sentinel absent"\n'
        printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '  resolved: false\n'
      } > "$_A1_ESC_DIR/esc-a1-advisory-$(date +%Y%m%d-%H%M%S).yaml" 2>/dev/null || true
    fi
  fi

  TRIGGERED_DECISIONS=""
  A1_INDEX="$DECISIONS_DIR/.a1-trigger-index"

  if [ -f "$A1_INDEX" ]; then
    # --- Fast path: compiled trigger index ---
    # Index format: decision_id|path_regex|keywords (pipe-delimited)
    # Eliminates per-file grep/sed expansion (~80 forks → ~5-10 typical)

    # Staleness guard: warn if any decision file is newer than the index
    # Check both t-*.md (template decisions, Decision 0022) and 0*.md (child decisions)
    for _A1_DF in "$DECISIONS_DIR"/t-*.md "$DECISIONS_DIR"/0*.md; do
      [ -f "$_A1_DF" ] || continue
      if [ "$_A1_DF" -nt "$A1_INDEX" ]; then
        echo "A1 WARNING: .a1-trigger-index may be stale — regenerate (see index file header for command)" >&2
        warn "A1_index_stale"
        break
      fi
    done

    while IFS='|' read -r _A1_DID _A1_PATH _A1_KW; do
      # Skip comments and blank lines
      case "$_A1_DID" in '#'*|'') continue ;; esac
      [ -z "$_A1_PATH" ] && continue

      # Match staged files against path pattern (guarded against ReDoS)
      _A1_MATCHING=$(echo "$STAGED_FILES" | _guarded_grep -E "$_A1_PATH" || true)
      [ -z "$_A1_MATCHING" ] && continue

      # If keywords defined, check diff content in matching files
      if [ -n "$_A1_KW" ]; then
        _A1_KW_PAT=$(echo "$_A1_KW" | sed 's/[[:space:]]*,[[:space:]]*/|/g')
        _A1_FLIST=$(echo "$_A1_MATCHING" | tr '\n' '|' | sed 's/|$//')
        _A1_KW_HIT=$(_get_staged_diff | awk -v files="$_A1_FLIST" '
          BEGIN { n=split(files, fa, "|"); for(i=1;i<=n;i++) wanted["b/"fa[i]]=1 }
          /^\+\+\+ / { f=substr($0,5); active=(f in wanted) ? 1 : 0; next }
          active && /^\+/ && !/^\+\+\+/ { print }
        ' | _guarded_grep -iE "$_A1_KW_PAT" || true)
        [ -z "$_A1_KW_HIT" ] && continue
      fi

      # Decision triggered — deduplicate (pure Bash, no forks)
      case ",$TRIGGERED_DECISIONS," in
        *",$_A1_DID,"*) ;;
        *) TRIGGERED_DECISIONS="${TRIGGERED_DECISIONS:+$TRIGGERED_DECISIONS, }$_A1_DID" ;;
      esac
    done < "$A1_INDEX"

  else
    # --- Fallback: parse decision files directly (no index) ---
    MISSING_TRIGGERS=0
    TOTAL_DECISIONS=0

    # Iterate both t-*.md (template decisions, Decision 0022) and 0*.md (child decisions)
    for DECISION_FILE in "$DECISIONS_DIR"/t-*.md "$DECISIONS_DIR"/0*.md; do
      [ -f "$DECISION_FILE" ] || continue
      TOTAL_DECISIONS=$((TOTAL_DECISIONS + 1))

      DECISION_ID=$(basename "$DECISION_FILE" | sed -E 's/^(t-)?([0-9]+)-.*/\2/')

      # Check if ## Triggers section exists
      if ! grep -q '^## Triggers' "$DECISION_FILE"; then
        MISSING_TRIGGERS=$((MISSING_TRIGGERS + 1))
        continue
      fi

      # Extract trigger block (from ## Triggers to next ## or EOF)
      TRIGGER_BLOCK=$(sed -n '/^## Triggers/,/^## /{ /^## Triggers/d; /^## /d; p; }' "$DECISION_FILE")
      [ -z "$TRIGGER_BLOCK" ] && continue

      # Extract paths (lines starting with - path: or - paths:)
      TRIGGER_PATHS=$(echo "$TRIGGER_BLOCK" | grep -oE 'paths?:\s*.*' | sed -E 's/^paths?:[[:space:]]*//' || true)
      # Extract keywords
      TRIGGER_KEYWORDS=$(echo "$TRIGGER_BLOCK" | grep -oE 'keywords?:\s*.*' | sed -E 's/^keywords?:[[:space:]]*//' || true)

      # Match staged files against trigger paths
      DECISION_TRIGGERED=false
      if [ -n "$TRIGGER_PATHS" ]; then
        while IFS= read -r GLOB_PATTERN; do
          GLOB_PATTERN=$(echo "$GLOB_PATTERN" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | sed 's/^`//' | sed 's/`$//')
          [ -z "$GLOB_PATTERN" ] && continue
          # Validate pattern is a safe regex (guarded against catastrophic backtracking)
          if ! _guarded_grep -qE "$GLOB_PATTERN" /dev/null 2>/dev/null; then
            echo "A1 WARNING: Skipping invalid path pattern in decision $DECISION_ID: $GLOB_PATTERN" >&2
            continue
          fi
          # Match staged files against glob (guarded against ReDoS)
          MATCHING_FILES=$(echo "$STAGED_FILES" | _guarded_grep -E "$GLOB_PATTERN" || true)
          if [ -n "$MATCHING_FILES" ]; then
            if [ -n "$TRIGGER_KEYWORDS" ]; then
              # If keywords defined, also check content
              KW_PATTERN=$(echo "$TRIGGER_KEYWORDS" | sed 's/`//g' | sed 's/[[:space:]]*,[[:space:]]*/|/g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
              # Validate keyword pattern before use (guarded against ReDoS)
              if ! _guarded_grep -qiE "$KW_PATTERN" /dev/null 2>/dev/null; then
                echo "A1 WARNING: Skipping invalid keyword pattern in decision $DECISION_ID: $KW_PATTERN" >&2
                continue
              fi
              _A1_FILE_LIST=$(echo "$MATCHING_FILES" | tr '\n' '|' | sed 's/|$//')
              KW_MATCHES=$(_get_staged_diff | awk -v files="$_A1_FILE_LIST" '
                BEGIN { n=split(files, fa, "|"); for(i=1;i<=n;i++) wanted["b/"fa[i]]=1 }
                /^\+\+\+ / { f=substr($0,5); active=(f in wanted) ? 1 : 0; next }
                active && /^\+/ && !/^\+\+\+/ { print }
              ' | _guarded_grep -iE "$KW_PATTERN" || true)
              [ -n "$KW_MATCHES" ] && DECISION_TRIGGERED=true
            else
              DECISION_TRIGGERED=true
            fi
          fi
        done <<< "$TRIGGER_PATHS"
      fi

      if [ "$DECISION_TRIGGERED" = true ]; then
        TRIGGERED_DECISIONS="${TRIGGERED_DECISIONS:+$TRIGGERED_DECISIONS, }$DECISION_ID"
      fi
    done

    # --- A1 structural check (fallback path only) ---
    if [ "$MISSING_TRIGGERS" -gt 0 ]; then
      if [ "$A1_BLOCKING" = true ]; then
        echo "GATE-RECOVERABLE: A1 — $MISSING_TRIGGERS of $TOTAL_DECISIONS decision files lack ## Triggers section. NEXT: Add ## Triggers section to decision files." >&2
        block "A1_missing_triggers"
      else
        echo "GATE A1 WARNING: $MISSING_TRIGGERS of $TOTAL_DECISIONS decision files lack ## Triggers section" >&2
        warn "A1_structural_advisory"
      fi
    fi
  fi

  # --- Trailer check (shared by both paths) ---
  if [ -n "$TRIGGERED_DECISIONS" ]; then
    DECISIONS_TRAILER=$(echo "$COMMIT_CMD" | grep -oE 'Decisions:[^\n]+' || true)
    MISSING_DECISION_IDS=""

    IFS=', ' read -ra TRIGGERED_ARRAY <<< "$TRIGGERED_DECISIONS"
    for DID in "${TRIGGERED_ARRAY[@]}"; do
      DID=$(echo "$DID" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
      [ -z "$DID" ] && continue
      if [ -z "$DECISIONS_TRAILER" ] || ! echo "$DECISIONS_TRAILER" | grep -q "$DID"; then
        MISSING_DECISION_IDS="${MISSING_DECISION_IDS:+$MISSING_DECISION_IDS, }$DID"
      fi
    done

    if [ -n "$MISSING_DECISION_IDS" ]; then
      A1_DETAIL="triggered:${TRIGGERED_DECISIONS// /} missing:${MISSING_DECISION_IDS// /}"
      if [ "$A1_BLOCKING" = true ]; then
        echo "GATE-RECOVERABLE: A1 — decisions triggered but not in trailer: $MISSING_DECISION_IDS. NEXT: Add Decisions: trailer to commit message." >&2
        block "A1_decisions_missing"
        log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "A1_decisions_missing" "$A1_DETAIL"
      else
        echo "GATE A1 WARNING: Decisions triggered but not declared in trailer: $MISSING_DECISION_IDS — include in Decisions: trailer" >&2
        warn "A1_decisions_advisory"
        log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "warn" "$START_MS" "A1_decisions_advisory" "$A1_DETAIL"
      fi
    fi
  fi
fi

# ============================================================
# Override Trailer Check (advisory — mode-guard overrides)
# ============================================================
# When mode-guard overrides were used this session, advise including
# an Overrides: trailer in the commit message for persistent audit.
if [ "$SKIP_STATE" = false ] && [ -f "$STATE_DIR/overrides.log" ]; then
  MODE_GUARD_OVERRIDES=$(grep "mode-guard" "$STATE_DIR/overrides.log" 2>/dev/null || true)
  if [ -n "$MODE_GUARD_OVERRIDES" ]; then
    OVERRIDES_TRAILER=$(echo "$COMMIT_CMD" | grep -oE 'Overrides:[^\n]+' || true)
    if [ -z "$OVERRIDES_TRAILER" ]; then
      echo "Advisory: mode-guard overrides used this session — consider adding Overrides: trailer (e.g., Overrides: mode-guard/REPO_OS_UNLOCK_PATH)" >&2
      warn "override_trailer_advisory"
    fi
  fi
fi

# ============================================================
# Project-Specific Checks
# ============================================================
# Add project-specific gate checks below. Examples:
#
# # A3: Quality — Lint
# if command -v npx &>/dev/null && [ -f package.json ]; then
#   npx eslint --quiet . || { echo "GATE A3 FAILED: Lint errors"; FAILED=1; }
# fi
#
# # A3: Quality — Format
# if command -v npx &>/dev/null && [ -f package.json ]; then
#   npx prettier --check . || { echo "GATE A3 FAILED: Formatting errors"; FAILED=1; }
# fi

# ============================================================
# Final exit
# ============================================================
if [ "$FAILED" -ne 0 ]; then
  log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "$BLOCKED_REASONS"
  echo "Commit blocked by pre-commit gate check." >&2
  exit 1
fi

REASON="pass"
[ "${REPO_OS_RECOVER:-0}" = "1" ] && REASON="recover_override"
[ -n "$WARN_REASONS" ] && REASON="${REASON:+$REASON }$WARN_REASONS"
log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "allow" "$START_MS" "$REASON"
