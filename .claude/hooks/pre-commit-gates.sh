#!/usr/bin/env bash
# Pre-commit gate verification — blocking enforcement.
# Runs automatically before git commit via .claude/settings.json hook.
# Exit non-zero to block the commit.
#
# Gates enforced:
#   Phase — assert_phase commit (blocking, primary check when phase-state active)
#   A4  Safety — secret scanning (always, blocking)
#   A3  Quality — design token enforcement (progressive; advisory when no tooling, blocking with ESLint)
#   A3.3 Build verification — tsc --noEmit --incremental (skips if no tsconfig.json; SKIP_BUILD_CHECK=1)
#   A3.4 Functional verification — build/pack/test scripts from package.json
#            (headless/auto: blocking; interactive: advisory; skips when no package.json;
#             SKIP_FUNC_CHECK=1 (interactive only); REPO_OS_RECOVER=1 (headless); per-command timeout: REPO_OS_FUNC_CHECK_TIMEOUT, default 120s)
#   State verification — plan-approved, cohesion-reviewed, diff-review-complete, qa-verified,
#                        pragmatist-signed (always blocking)
#   A5  Cohesion — cohesion-reviewed + diff-review-complete both APPROVED required (blocking);
#                  session-type-aware: only enforced for session types with a review phase;
#                  GATE_RESULT: BLOCKED in either file blocks commit
#   A2  Process — scope check >100 lines (blocking with large-scope override)
#   A6  Task Group — contract staging (blocking)
#   A6.3 Integration points — artifact existence check from contract integration_points (blocking)
#   High-risk — pattern detection + sign-off enforcement (blocking)
#   A1  Decision trigger parser (blocking — enforced by .a1-triggers-enforced sentinel)
#
# Overrides:
#   REPO_OS_RECOVER=1    — skip all state-dependent checks (emergency recovery)
#   SKIP_CONTRACT_CHECK=1 — skip A6 contract checks (existence, staging, A6.3 integration points)
#   SKIP_BUILD_CHECK=1    — skip A3.3 TypeScript type-check
#   SKIP_FUNC_CHECK=1     — skip A3.4 functional verification (interactive only — ignored in headless/auto; Decision t-0044 Amendment 1)
#   REPO_OS_FUNC_CHECK_TIMEOUT — per-command timeout in seconds for A3.4 (default: 120)
#
# Branch profiles:
#   experiment/*  — A4 only (all state checks skipped)
#   hotfix/*      — A2 scope relaxed, A5 cohesion skipped
#   editor-live   — per-loop: A4 only; close: full gates minus plan-approved

set -euo pipefail
# NOTE: errtrace (-E) is enabled conditionally, next to _gate_abort() below —
# it is only safe where $BASHPID exists to distinguish subshells. Do not add
# -E here.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_analytics-helper.sh"
source "$SCRIPT_DIR/_phase-helper.sh"
source "$SCRIPT_DIR/_secret-pattern.sh"
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
STATE_DIR="$(get_session_state_dir)"
DECISIONS_DIR="$REPO_ROOT/docs/ai/decisions"

# --- Fail-closed abort guard (blocking) ---
# Every gate below records failure in $FAILED and defers to the single `exit 2`
# at the end of this file. Under `set -euo pipefail`, any unhandled non-zero
# command aborts the script *before* that exit with status 1 — and the Claude
# Code hook protocol blocks on exit 2 ONLY, treating any other non-zero as a
# non-blocking error that lets the tool call proceed. A crash therefore became
# a silent, total bypass of every gate in this file.
#
# This trap converts that class of failure from fail-open to fail-closed: an
# unexpected abort now blocks the commit and says where it happened. It is a
# backstop, not a licence to leave real aborts unfixed — each one should be
# diagnosed and repaired at its source.
#
# errtrace (-E) widens the trap to shell functions, so an abort inside a
# sourced helper fails closed instead of exiting 1. It is enabled BELOW, and
# only when $BASHPID exists, for the reason that follows.
#
# errtrace also propagates into SUBSHELLS and COMMAND SUBSTITUTIONS, and
# there the trap is actively wrong. Gates deliberately capture failing exit
# codes, e.g.
#     A33_OUTPUT=$(cd "$REPO_ROOT" && npx tsc --noEmit) || A33_EXIT=$?
# The `||` protects the outer assignment from errexit, but the inner command's
# failure fires ERR *inside the substitution's subshell*. An unguarded trap
# exits that subshell with 2, so the gate reads the wrong status (a tsc/npm
# failure of 1 arrives as 2), prints a spurious "gate defect" message, and
# logs a false gate_script_abort. A plain type error or schema violation would
# tell the operator the gate itself is broken.
#
# So: fail closed in the main shell (top level AND functions, which share
# $BASHPID), and stay out of the way in subshells, where a non-zero status is
# the caller's to handle. errexit still terminates the subshell with its
# original status, which is exactly what the `||` capture expects.
_gate_abort() {
  local rc=$?
  local line="${1:-unknown}"
  if [ "${BASHPID:-$$}" != "$$" ]; then
    return "$rc"
  fi
  echo "GATE-FINAL: pre-commit gate aborted unexpectedly at line ${line} (exit ${rc}) — failing closed rather than letting the commit through. NEXT: this is a gate defect; re-run with 'bash -x .claude/hooks/pre-commit-gates.sh' to locate it, and verify with 'bash .claude/tools/gate-conformance.sh'. (no override)" >&2
  log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "gate_script_abort" "line:${line} rc:${rc}" 2>/dev/null || true
  exit 2
}
trap '_gate_abort "$LINENO"' ERR

# Enable errtrace ONLY where the subshell guard above can actually work.
# $BASHPID is a bash 4.0+ feature; macOS ships bash 3.2.57, where it is unset
# and `$$` reports the parent's PID even inside a subshell — leaving no way to
# tell a command substitution from the main shell. Enabling -E there would
# hijack every deliberately-captured failure (a tsc/npm exit of 1 arriving as
# 2, plus a false "gate defect" message).
#
# Without -E the trap still covers this script's top level, which is where the
# fail-open this decision exists to fix actually occurred. Aborts inside
# sourced helper functions remain exit-1 on bash 3.2 — a known, narrower gap,
# recorded in Decision t-0049 rather than papered over.
if [ -n "${BASHPID:-}" ]; then
  set -E
fi

FAILED=0
BLOCKED_REASONS=""
WARN_REASONS=""

# Helper: append to block/warn reason lists
block() { BLOCKED_REASONS="${BLOCKED_REASONS:+$BLOCKED_REASONS }$1"; FAILED=1; }
warn()  { WARN_REASONS="${WARN_REASONS:+$WARN_REASONS }$1"; }

# --- Read hook payload (PreToolUse JSON on stdin) ---
INPUT=$(cat)

# --- Harness session_id plumbing (must precede first get_session_id call) ---
export _REPO_OS_STDIN_SID
_REPO_OS_STDIN_SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"

COMMIT_CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)

# --- Self-filter: skip the full gate chain for non-commit commands ---
# The matcher is now "Bash" (fires on every Bash call); guard against running
# A1-A6 + secret scan on unrelated commands like 'ls' or 'echo'.
# Permissive match: cd ... && git commit, git -C . commit, etc. all pass.
# Edge case: 'git commit' in a -m message string is accepted as a false positive
# (cheap to re-run and full message parsing adds fragility).
case "$COMMIT_CMD" in
  *"git commit"*) ;;
  *) exit 0 ;;
esac

# --- REPO_OS_RECOVER override (env var or file-based signal) ---
RECOVER_SIGNAL_FILE="$REPO_ROOT/.claude/.state/.recover-signal"
if [ "${REPO_OS_RECOVER:-0}" = "1" ]; then
  log_override "pre-commit-gates" "REPO_OS_RECOVER"
  echo "REPO_OS_RECOVER=1 — skipping all state-dependent checks" >&2
  if [ "${CLAUDE_HEADLESS:-0}" = "1" ]; then
    _RECOVER_ESC_DIR="$REPO_ROOT/.claude/.automation/escalations"
    mkdir -p "$_RECOVER_ESC_DIR" 2>/dev/null || true
    printf 'type: governance-block\ngate: A3.4\nreason: REPO_OS_RECOVER_used_in_headless\nmessage: REPO_OS_RECOVER=1 bypass in headless mode -- A3.4 checks were skipped\ntimestamp: %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      > "$_RECOVER_ESC_DIR/recover-bypass-$(date -u +%Y%m%d-%H%M%S).yaml" 2>/dev/null || true
  fi
  SKIP_STATE=true
elif [ -f "$RECOVER_SIGNAL_FILE" ]; then
  log_override "pre-commit-gates" "recover-signal-file"
  rm -f "$RECOVER_SIGNAL_FILE"
  echo "Recovery signal consumed — skipping all state-dependent checks" >&2
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
if [ -n "$STAGED_FILES" ]; then
  # Scan added lines only (^+ prefix) from staged diff — catches what's being
  # committed, not pre-existing content. Uses _get_staged_diff lazy cache.
  A4_ADDED_LINES=$(_get_staged_diff | awk '
    /^\+\+\+ / { file=substr($0,5); next }
    /^\+/ && !/^\+\+\+/ && file !~ /_secret-pattern\.sh$/ { print file ": " substr($0,2) }
  ')
  A4_MATCHES=$(echo "$A4_ADDED_LINES" | grep -iE "$_REPO_OS_SECRET_PATTERN" 2>/dev/null || true)
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
    exit 2
  fi
  log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "allow" "$START_MS" "experiment_branch"
  exit 0
fi

# --- Editor-live session type detection (uses shared is_session_closing predicate) ---
# Per-loop commits (not closing): A4 only, skip state checks.
# Close commits (closing): full gates minus plan-approved.
# is_session_closing() (from _phase-helper.sh) provides the same predicate used
# by session-close-check.sh, ensuring consistent pause vs close classification.
IS_EDITOR_LIVE_LOOP=false
IS_EDITOR_LIVE_CLOSE=false
if [ "$SKIP_STATE" = false ]; then
  _EL_STYPE=$(get_session_type)
  if [ "$_EL_STYPE" = "editor-live" ]; then
    if is_session_closing 2>/dev/null; then
      IS_EDITOR_LIVE_CLOSE=true
    else
      # Not closing (or phase-state absent — safe default: A4 only)
      IS_EDITOR_LIVE_LOOP=true
    fi
  fi
fi

# Exit early for editor-live per-loop commits (A4 only — same as experiment)
if [ "$IS_EDITOR_LIVE_LOOP" = true ]; then
  if [ "$FAILED" -ne 0 ]; then
    log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "$BLOCKED_REASONS"
    echo "Commit blocked by pre-commit gate check." >&2
    exit 2
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
  # Decision 0042: prefer the cached phase verdict when fresh; falls through to
  # the canonical assert_phase / get_phase reads on cache miss.
  CURRENT_PHASE=""
  if read_phase_gates 2>/dev/null; then
    CURRENT_PHASE="$GATES_CURRENT_PHASE"
  fi
  [ -z "$CURRENT_PHASE" ] && CURRENT_PHASE=$(get_phase)
  if [ -n "$CURRENT_PHASE" ]; then
    # Phase-state active — use phase model as primary check
    if ! assert_phase "commit"; then
      echo "GATE-RECOVERABLE: Session in '$CURRENT_PHASE' phase — must reach 'commit' phase. NEXT: Complete QA verification (qa-verifier agent) to advance to commit phase." >&2
      block "phase_gate_not_commit"
      log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "phase_gate_not_commit" "phase:$CURRENT_PHASE"
    fi
  else
    # Phase-state absent — fail-closed on non-exempt session types.
    # Sessions that lack phase-state either never called init_phase (governance
    # bypass) or are exempt types that don't use the phase model.
    _FC_STYPE=$(get_session_type)
    _FC_EXEMPT=false
    case "$_FC_STYPE" in
      ephemeral|taskdef-query|taskdef-brief|audit|queue-triage) _FC_EXEMPT=true ;;
      prototype-*|advisory-*) _FC_EXEMPT=true ;;
      "")
        # Cannot determine session type — fail-closed unless experiment branch
        # (experiment branches already exit early, but belt-and-suspenders)
        if [[ "$CURRENT_BRANCH" == experiment/* ]]; then
          _FC_EXEMPT=true
        fi
        ;;
    esac
    if [ "$_FC_EXEMPT" = false ]; then
      echo "GATE-FINAL: Phase state not initialized — session must call init_phase before committing. Session type: ${_FC_STYPE:-unknown}. (no override)" >&2
      block "phase_state_missing"
      log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "phase_state_missing" "stype:${_FC_STYPE:-unknown}"
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

# --- No-review-backstop detection (A3.4 — Decision 0044) ---
# Tracks whether a human can catch missed build/test failures at op-review.
# True when: (1) running headless (no human in loop at all), OR
# (2) phase mode is 'auto' (operator has delegated review to automation).
IS_NO_REVIEW_BACKSTOP=false
[ "$IS_HEADLESS" = true ] && IS_NO_REVIEW_BACKSTOP=true
if [ "$IS_NO_REVIEW_BACKSTOP" = false ] && [ -f "$STATE_DIR/phase-state" ]; then
  _A34_MODE=$(grep '^mode: ' "$STATE_DIR/phase-state" 2>/dev/null | sed 's/^mode: *//' | tr -d '[:space:]' | head -1 || echo "")
  [ "$_A34_MODE" = "auto" ] && IS_NO_REVIEW_BACKSTOP=true
fi
_A34_APPLICABLE=false

# --- Session-id validation helper (adversarial C1/C4/H4) ---
# Returns 0 if state file contains matching session_id, 1 otherwise.
_validate_state_session_id() {
  local state_file="$1"
  [ -f "$state_file" ] || return 1
  local file_sid
  file_sid=$(grep '^session_id:' "$state_file" 2>/dev/null | sed 's/^session_id: *//' | tr -d '[:space:]' | head -1)
  local current_sid
  if [ -n "${REPO_OS_SESSION_ID:-}" ]; then
    current_sid="$REPO_OS_SESSION_ID"
  else
    current_sid=$(cat "$REPO_ROOT/.claude/.session-id" 2>/dev/null || echo "")
  fi
  # No current session → skip validation (pre-session context)
  [ -z "$current_sid" ] && return 0
  # State file missing session_id but session exists → forged/stale (reject)
  [ -z "$file_sid" ] && return 1
  [ "$file_sid" = "$current_sid" ]
}

# --- Plan content hash validation (compensating control for session-ID mismatch) ---
# Compares plan-approved.question_hash against session-resume.yaml plan_hash verdict
# to verify the approval matches the current plan (content-addressed confirmation).
# Returns 0 (valid) when:
#   - Both hashes present and match (content-addressed validation), OR
#   - Resume marker absent / no plan_hash entry (backward-compat: presence-check fallback)
# Returns 1 (invalid) when:
#   - Both hashes present but mismatch (plan changed or stale file)
#
# Backward-compatibility fallback: Sessions started before this change won't have a
# plan_hash in the resume marker. In that case, fall back to presence-check (return 0
# if question_hash is non-empty). This fallback can be removed once all active sessions
# have the resume marker with plan_hash support.
_validate_plan_content_hash() {
  local state_file="$1"
  [ -f "$state_file" ] || return 1

  # Read question_hash from plan-approved
  local file_hash
  file_hash=$(grep '^question_hash:' "$state_file" 2>/dev/null | sed 's/^question_hash: *//' | tr -d '[:space:]' | head -1)
  # Hash must be non-empty to serve as compensating control
  [ -n "$file_hash" ] || return 1

  # Read plan_hash from session-resume.yaml agent_verdicts section
  local state_dir
  state_dir="$(get_session_state_dir)"
  local resume_file="$state_dir/session-resume.yaml"
  local resume_hash=""

  if [ -f "$resume_file" ]; then
    resume_hash=$(grep '^ *plan_hash:' "$resume_file" 2>/dev/null | sed 's/^ *plan_hash: *//' | tr -d '[:space:]' | head -1)
  fi

  # If resume marker absent or no plan_hash entry: backward-compat presence-check
  if [ -z "$resume_hash" ]; then
    return 0
  fi

  # Both present: content-addressed comparison
  if [ "$file_hash" = "$resume_hash" ]; then
    return 0
  else
    return 1
  fi
}

if [ "$SKIP_STATE" = false ]; then
  # plan-approved: required on all non-experiment branches
  # Provenance (Decision 0038): file may be written by plan-approval.sh
  # (legacy AskUserQuestion path) or by drift_check from a valid handoff bundle.
  # Both write the same schema with a matching session_id; the existing
  # _validate_state_session_id check covers both provenances uniformly.
  # Override: REPO_OS_SKIP_PLAN_GATE=1 (parity with bash-guard plan gate)
  # editor-live: skip (never has plan gate — no approval phase)
  if [ "$IS_EDITOR_LIVE_CLOSE" = true ]; then
    : # editor-live never has plan-approved — skip silently
  elif [ "${REPO_OS_SKIP_PLAN_GATE:-0}" = "1" ]; then
    log_override "pre-commit-gates" "REPO_OS_SKIP_PLAN_GATE"
  elif [ ! -f "$STATE_DIR/plan-approved" ]; then
    # R13 diagnostic: distinguish "hook didn't fire" from "approval not given"
    _CURRENT_PHASE=$(get_phase)
    if [ "$_CURRENT_PHASE" = "build" ] || [ "$_CURRENT_PHASE" = "plan" ] || [ "$_CURRENT_PHASE" = "approval" ]; then
      echo "GATE-RECOVERABLE: Phase is '$_CURRENT_PHASE' but plan-approved state file is missing — plan-approval.sh hook may not have fired after AskUserQuestion (see known-issues.md R13). NEXT: Create recovery signal (touch .claude/.state/.recover-signal) or set REPO_OS_SKIP_PLAN_GATE=1." >&2
    elif [ "$IS_HEADLESS" = true ]; then
      echo "GATE-RECOVERABLE: plan-approved state file missing. NEXT: Write escalation file to .claude/.automation/escalations/ with type 'governance-block'. (override: REPO_OS_SKIP_PLAN_GATE=1)" >&2
    else
      echo "GATE-RECOVERABLE: plan-approved state file missing. NEXT: Use AskUserQuestion to present plan for operator approval (triggers plan-approval hook). (override: REPO_OS_SKIP_PLAN_GATE=1)" >&2
    fi
    block "state_plan_missing"
    log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "state_plan_missing"
  elif ! _validate_state_session_id "$STATE_DIR/plan-approved"; then
    # Session-ID mismatch — compare plan-approved.question_hash against resume marker plan_hash.
    # Content-addressed validation: if both hashes match, the approval is for the current plan.
    if _validate_plan_content_hash "$STATE_DIR/plan-approved"; then
      echo "Advisory: plan-approved session_id mismatch but plan content hash validated — approval matches current plan, downgrading to warning." >&2
      warn "hash_validated_sid_mismatch"
      log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "warn" "$START_MS" "hash_validated_sid_mismatch"
    else
      # Hash mismatch: plan-approved question_hash does not match resume marker plan_hash.
      # This means the plan changed after approval, or the plan-approved file is from a different session.
      echo "GATE-RECOVERABLE: plan-approved question_hash does not match session resume marker — plan may have changed or file is stale. NEXT: Re-approve plan in this session. (override: REPO_OS_SKIP_PLAN_GATE=1)" >&2
      block "hash_mismatch_sid_mismatch"
      log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "hash_mismatch_sid_mismatch"
    fi
  fi

  # A3.3: Build Verification — TypeScript type-check
  # Placed before A5 (cohesion gate) so build errors surface before review state checks.
  # Skips silently when tsconfig.json is absent (non-TypeScript projects).
  # Override: SKIP_BUILD_CHECK=1
  if [ -n "$STAGED_FILES" ]; then
    if [ "${SKIP_BUILD_CHECK:-0}" = "1" ]; then
      log_override "pre-commit-gates" "SKIP_BUILD_CHECK"
    elif [ -f "$REPO_ROOT/tsconfig.json" ]; then
      A33_OUTPUT=""
      A33_EXIT=0
      A33_OUTPUT=$(cd "$REPO_ROOT" && npx tsc --noEmit --incremental 2>&1) || A33_EXIT=$?
      if [ "$A33_EXIT" -ne 0 ]; then
        echo "GATE-RECOVERABLE: A3.3 build verification failed — TypeScript type errors detected. NEXT: Fix type errors shown below. (override: SKIP_BUILD_CHECK=1)" >&2
        printf '%s\n' "$A33_OUTPUT" >&2
        block "A3.3_type_error"
        log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "A3.3_type_error"
      else
        log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "allow" "$START_MS" "A3.3_pass"
      fi
    else
      # Make the skip VISIBLE. A gate that is documented as blocking but
      # silently no-ops is indistinguishable from a gate that ran and passed —
      # in the output and in telemetry. That ambiguity is how a dead gate stays
      # dead unnoticed. Not a warning: absence of tsconfig.json is a correct,
      # expected state for a non-TypeScript repo (the template itself).
      echo "A3.3 SKIPPED: no tsconfig.json at repo root — TypeScript build verification is inactive in this repo." >&2
      log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "allow" "$START_MS" "A3.3_skipped_no_tsconfig"
    fi
  fi

  # A3.4: Functional Verification Gate (blocking in headless/auto — advisory otherwise)
  # Replaces the human op-review checkpoint that is skipped in auto/solo mode (Decision 0017).
  # Reads package.json to infer build/pack/test commands; skips silently when no package.json.
  # Override: SKIP_FUNC_CHECK=1 (interactive only — ignored in headless/auto; Decision t-0044 Amendment 1)
  # Per-command timeout: REPO_OS_FUNC_CHECK_TIMEOUT (default 120s)
  if [ -n "$STAGED_FILES" ]; then
    _A34_SKIP_EFFECTIVE=false
    if [ "${SKIP_FUNC_CHECK:-0}" = "1" ]; then
      if [ "$IS_NO_REVIEW_BACKSTOP" = false ]; then
        log_override "pre-commit-gates" "SKIP_FUNC_CHECK"
        _A34_SKIP_EFFECTIVE=true
      else
        log_override "pre-commit-gates" "SKIP_FUNC_CHECK_IGNORED_HEADLESS"
        _A34_ESC_DIR_SKIP="$REPO_ROOT/.claude/.automation/escalations"
        mkdir -p "$_A34_ESC_DIR_SKIP" 2>/dev/null || true
        printf 'type: governance-block\ngate: A3.4\nreason: SKIP_FUNC_CHECK_ignored_in_headless\nmessage: SKIP_FUNC_CHECK=1 was set but is not honored in headless/auto mode (Decision t-0044 Amendment 1) -- A3.4 checks will run\ntimestamp: %s\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          > "$_A34_ESC_DIR_SKIP/a34-skip-ignored-$(date -u +%Y%m%d-%H%M%S).yaml" 2>/dev/null || true
      fi
    fi
    if [ "$_A34_SKIP_EFFECTIVE" = false ] && [ ! -f "$REPO_ROOT/package.json" ]; then
      # Make the skip VISIBLE — see the A3.3 note above. A3.4 is documented as
      # blocking in headless/auto; with no package.json it does nothing, and
      # silence made that identical to having run and passed.
      echo "A3.4 SKIPPED: no package.json at repo root — functional verification is inactive in this repo." >&2
      log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "allow" "$START_MS" "A3.4_skipped_no_package_json"
    fi
    if [ "$_A34_SKIP_EFFECTIVE" = false ] && [ -f "$REPO_ROOT/package.json" ]; then
      _A34_TIMEOUT="${REPO_OS_FUNC_CHECK_TIMEOUT:-120}"
      _A34_CMDS=()
      # Infer applicable scripts from package.json
      _A34_HAS_BUILD=$(jq -r '.scripts.build // empty' "$REPO_ROOT/package.json" 2>/dev/null || echo "")
      _A34_HAS_BUILD_PACK=$(jq -r '.scripts["build:pack"] // empty' "$REPO_ROOT/package.json" 2>/dev/null || echo "")
      _A34_HAS_TEST=$(jq -r '.scripts.test // empty' "$REPO_ROOT/package.json" 2>/dev/null || echo "")
      _A34_HAS_VERIFY=$(jq -r '.scripts.verify // empty' "$REPO_ROOT/package.json" 2>/dev/null || echo "")
      _A34_PKG_NAME=$(jq -r '.name // empty' "$REPO_ROOT/package.json" 2>/dev/null || echo "")
      [ -n "$_A34_HAS_BUILD" ] && _A34_CMDS+=("build")
      [ -n "$_A34_HAS_BUILD_PACK" ] && _A34_CMDS+=("build:pack")
      [ -n "$_A34_HAS_TEST" ] && _A34_CMDS+=("test")
      [ -n "$_A34_HAS_VERIFY" ] && _A34_CMDS+=("verify")
      if [ ${#_A34_CMDS[@]} -gt 0 ] || [ -n "$_A34_PKG_NAME" ]; then
        _A34_APPLICABLE=true
      fi
      if [ "$_A34_APPLICABLE" = true ]; then
        # npm presence guard (analogous to jq guard at top of file)
        if ! command -v npm &>/dev/null; then
          if [ "$IS_NO_REVIEW_BACKSTOP" = true ]; then
            echo "GATE-RECOVERABLE: A3.4 functional verification requires npm but npm was not found. NEXT: Install npm or set REPO_OS_RECOVER=1 to bypass in headless/auto mode." >&2
            block "A3.4_npm_missing"
            log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "A3.4_npm_missing"
          else
            echo "Advisory: A3.4 functional verification — npm not found; skipping script execution (human review backstop active)." >&2
            warn "A3.4_npm_missing_advisory"
          fi
        else
        _A34_FAIL=false
        _A34_FAIL_DETAIL=""
        for _A34_CMD in "${_A34_CMDS[@]}"; do
          _A34_OUT=""
          _A34_RC=0
          _A34_OUT=$(cd "$REPO_ROOT" && timeout "$_A34_TIMEOUT" npm run "$_A34_CMD" 2>&1) || _A34_RC=$?
          if [ "$_A34_RC" -ne 0 ]; then
            _A34_FAIL=true
            _A34_FAIL_DETAIL="${_A34_FAIL_DETAIL}[npm run ${_A34_CMD} exit=${_A34_RC}]\n${_A34_OUT}\n"
          fi
        done
        # npm pack --dry-run structural sanity check (when package has a name and no script failures yet)
        if [ -n "$_A34_PKG_NAME" ] && [ "$_A34_FAIL" = false ]; then
          _A34_PACK_OUT=""
          _A34_PACK_RC=0
          _A34_PACK_OUT=$(cd "$REPO_ROOT" && timeout "$_A34_TIMEOUT" npm pack --dry-run 2>&1) || _A34_PACK_RC=$?
          if [ "$_A34_PACK_RC" -ne 0 ]; then
            _A34_FAIL=true
            _A34_FAIL_DETAIL="${_A34_FAIL_DETAIL}[npm pack --dry-run exit=${_A34_PACK_RC}]\n${_A34_PACK_OUT}\n"
          fi
        fi
        if [ "$_A34_FAIL" = false ]; then
          # Write functional-verified state file on pass
          _A34_CURRENT_SID=""
          if [ -n "${REPO_OS_SESSION_ID:-}" ]; then
            _A34_CURRENT_SID="$REPO_OS_SESSION_ID"
          else
            _A34_CURRENT_SID=$(cat "$REPO_ROOT/.claude/.session-id" 2>/dev/null || echo "")
          fi
          printf 'timestamp: %s\nsession_id: %s\nresult: PASSED\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_A34_CURRENT_SID" \
            > "$STATE_DIR/functional-verified"
          refresh_manifest_entry "functional-verified" 2>/dev/null || true
        else
          # Blocking in headless/auto; advisory otherwise
          if [ "$IS_NO_REVIEW_BACKSTOP" = true ]; then
            echo "GATE-RECOVERABLE: A3.4 functional verification failed — build/pack/test scripts did not pass. NEXT: Fix failures below, or set REPO_OS_RECOVER=1 to bypass in headless/auto mode." >&2
            printf '%b' "$_A34_FAIL_DETAIL" >&2
            _A34_ESC_DIR="$REPO_ROOT/.claude/.automation/escalations"
            if [ -d "$_A34_ESC_DIR" ]; then
              printf 'type: gate-failure\ngate: A3.4\nreason: functional_verification_failed\ntimestamp: %s\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                > "$_A34_ESC_DIR/a34-func-fail-$(date -u +%Y%m%d-%H%M%S).yaml"
            fi
            block "A3.4_func_verification_failed"
            log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "A3.4_func_verification_failed"
          else
            echo "Advisory: A3.4 functional verification — build/pack/test scripts failed (human review backstop active; not blocking in interactive mode). Fix before merging to main." >&2
            printf '%b' "$_A34_FAIL_DETAIL" >&2
            warn "A3.4_func_verification_advisory"
            log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "warn" "$START_MS" "A3.4_func_verification_advisory"
          fi
        fi  # end: _A34_FAIL check
        fi  # end: npm present (else branch of npm guard)
      fi  # end: _A34_APPLICABLE
    fi  # end: package.json present
  fi  # end: STAGED_FILES

  # A5: Cohesion + Diff-Review Gate (blocking)
  # Session-type-aware: only enforce for session types whose phase sequence includes 'review'.
  # hotfix/* is always exempt (IS_HOTFIX). Other session types without review phase also exempt.
  # REPO_OS_RECOVER=1 bypasses all A5 checks via SKIP_STATE=true (already handled above).
  _A5_SKIP="$IS_HOTFIX"
  if [ "$_A5_SKIP" = false ]; then
    _A5_STYPE=$(get_session_type)
    _A5_PHASES=$(get_phases_for_type "$_A5_STYPE" 2>/dev/null || echo "")
    case " $_A5_PHASES " in
      *" review "*) ;; # has review phase — A5 applies
      *) _A5_SKIP=true ;; # no review phase — skip A5 silently
    esac
  fi

  # cohesion-reviewed: required when A5 applies
  if [ "$_A5_SKIP" = false ] && [ ! -f "$STATE_DIR/cohesion-reviewed" ]; then
    echo "GATE-RECOVERABLE: A5 cohesion review not passed — cohesion-reviewed state file missing. NEXT: Dispatch Critic agent in cohesion mode (after Builder completes, before QA). (override: REPO_OS_RECOVER=1)" >&2
    block "state_cohesion_missing"
    log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "state_cohesion_missing"
  elif [ "$_A5_SKIP" = false ] && [ -f "$STATE_DIR/cohesion-reviewed" ] && ! _validate_state_session_id "$STATE_DIR/cohesion-reviewed"; then
    echo "GATE-RECOVERABLE: A5 — cohesion-reviewed state file has stale session_id. NEXT: Re-run Critic cohesion review in this session. (override: REPO_OS_RECOVER=1)" >&2
    block "state_cohesion_stale_session"
    log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "state_cohesion_stale_session"
  elif [ "$_A5_SKIP" = false ] && [ -f "$STATE_DIR/cohesion-reviewed" ] && \
       _validate_state_session_id "$STATE_DIR/cohesion-reviewed"; then
    # Dispatch evidence check: reject verdict files lacking dispatch_phase field.
    _PCG_COHESION_DISPATCH_PHASE=$(grep '^dispatch_phase:' "$STATE_DIR/cohesion-reviewed" 2>/dev/null | sed 's/^dispatch_phase: *//' | head -1 || true)
    if [ -z "$_PCG_COHESION_DISPATCH_PHASE" ]; then
      echo "GATE-RECOVERABLE: A5 cohesion-reviewed lacks dispatch_phase — not produced by a real agent dispatch. NEXT: Re-dispatch Critic in cohesion mode. (override: REPO_OS_RECOVER=1)" >&2
      block "A5_cohesion_no_dispatch_evidence"
      log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "A5_cohesion_no_dispatch_evidence"
    fi
    # A5 hardening: block if cohesion-reviewed contains GATE_RESULT: BLOCKED
    # This enforces that critical cohesion findings were resolved before committing.
    _PCG_COHESION_RESULT=$(grep '^GATE_RESULT: ' "$STATE_DIR/cohesion-reviewed" 2>/dev/null | sed 's/^GATE_RESULT: *//' | awk '{print $1}' | head -1 || true)
    if [ "$_PCG_COHESION_RESULT" = "BLOCKED" ]; then
      echo "GATE-RECOVERABLE: A5 cohesion review blocked — Critic found critical findings that were not resolved. NEXT: Resolve all critical cohesion findings and re-run Critic in cohesion mode. (override: REPO_OS_RECOVER=1)" >&2
      block "A5_cohesion_blocked"
      log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "A5_cohesion_blocked"
    fi
    # A5 extension: completeness check — block if COMPLETENESS_GATE: NEEDS_WORK
    # Backward compat: absent COMPLETENESS_GATE field falls through silently.
    _PCG_COMPLETENESS_GATE=$(grep '^COMPLETENESS_GATE: ' "$STATE_DIR/cohesion-reviewed" 2>/dev/null | sed 's/^COMPLETENESS_GATE: *//' | head -1 || true)
    if [ "$_PCG_COMPLETENESS_GATE" = "NEEDS_WORK" ]; then
      _PCG_COMPLETENESS_SCORE=$(grep '^COMPLETENESS: ' "$STATE_DIR/cohesion-reviewed" 2>/dev/null | sed 's/^COMPLETENESS: *//' | head -1 || true)
      echo "GATE-RECOVERABLE: A5 completeness check failed — ${_PCG_COMPLETENESS_SCORE:-N/M criteria not met}. NEXT: Loop back to Builder to address incomplete criteria, then re-run Critic and QA. (override: REPO_OS_RECOVER=1)" >&2
      block "A5_completeness_needs_work"
      log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "A5_completeness_needs_work" "${_PCG_COMPLETENESS_SCORE:-unknown}"
    fi
  fi

  # diff-review-complete: required alongside cohesion-reviewed when A5 applies
  # New in Brief 3 — enforced for session types with a review phase (same as cohesion).
  if [ "$_A5_SKIP" = false ] && [ ! -f "$STATE_DIR/diff-review-complete" ]; then
    echo "GATE-RECOVERABLE: A5 diff-review not passed — diff-review-complete state file missing. NEXT: Dispatch Critic in diff-review mode (after cohesion review, before QA). (override: REPO_OS_RECOVER=1)" >&2
    block "state_diff_review_missing"
    log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "state_diff_review_missing"
  elif [ "$_A5_SKIP" = false ] && [ -f "$STATE_DIR/diff-review-complete" ] && ! _validate_state_session_id "$STATE_DIR/diff-review-complete"; then
    echo "GATE-RECOVERABLE: A5 — diff-review-complete state file has stale session_id. NEXT: Re-run Critic in diff-review mode in this session. (override: REPO_OS_RECOVER=1)" >&2
    block "state_diff_review_stale_session"
    log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "state_diff_review_stale_session"
  elif [ "$_A5_SKIP" = false ] && [ -f "$STATE_DIR/diff-review-complete" ] && \
       _validate_state_session_id "$STATE_DIR/diff-review-complete"; then
    # Dispatch evidence check: reject verdict files lacking dispatch_phase field.
    _PCG_DIFF_DISPATCH_PHASE=$(grep '^dispatch_phase:' "$STATE_DIR/diff-review-complete" 2>/dev/null | sed 's/^dispatch_phase: *//' | head -1 || true)
    if [ -z "$_PCG_DIFF_DISPATCH_PHASE" ]; then
      echo "GATE-RECOVERABLE: A5 diff-review-complete lacks dispatch_phase — not produced by a real agent dispatch. NEXT: Re-dispatch Critic in diff-review mode. (override: REPO_OS_RECOVER=1)" >&2
      block "A5_diff_no_dispatch_evidence"
      log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "A5_diff_no_dispatch_evidence"
    fi
    _PCG_DIFF_REVIEW_RESULT=$(grep '^GATE_RESULT: ' "$STATE_DIR/diff-review-complete" 2>/dev/null | sed 's/^GATE_RESULT: *//' | awk '{print $1}' | head -1 || true)
    if [ "$_PCG_DIFF_REVIEW_RESULT" = "BLOCKED" ]; then
      echo "GATE-RECOVERABLE: A5 diff-review blocked — Critic found critical mechanical bugs. NEXT: Resolve all critical diff-review findings and re-run Critic in diff-review mode. (override: REPO_OS_RECOVER=1)" >&2
      block "A5_diff_review_blocked"
      log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "A5_diff_review_blocked"
    fi
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
  elif [ -f "$STATE_DIR/qa-verified" ] && _validate_state_session_id "$STATE_DIR/qa-verified"; then
    # Dispatch evidence check: reject verdict files lacking dispatch_phase field.
    # Files written by state-writer.sh always contain this field (written since
    # this fix). Absence means the file was not produced via a real agent dispatch.
    _PCG_QA_DISPATCH_PHASE=$(grep '^dispatch_phase:' "$STATE_DIR/qa-verified" 2>/dev/null | sed 's/^dispatch_phase: *//' | head -1 || true)
    if [ -z "$_PCG_QA_DISPATCH_PHASE" ]; then
      echo "GATE-RECOVERABLE: qa-verified lacks dispatch_phase — not produced by a real agent dispatch. NEXT: Re-dispatch QA verification agent. (override: REPO_OS_RECOVER=1)" >&2
      block "state_qa_no_dispatch_evidence"
      log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "state_qa_no_dispatch_evidence"
    fi
  fi

  # A3.4 functional-verified binding gate (defense-in-depth for headless/auto)
  # Only fires when A3.4 found applicable scripts AND no earlier gate has already blocked.
  # Catches the edge case where functional-verified was not written (e.g., state was reset
  # between the A3.4 check and the qa-verified check in a crash-recovery scenario).
  if [ "$IS_NO_REVIEW_BACKSTOP" = true ] && [ "$_A34_APPLICABLE" = true ] && \
     [ "$FAILED" -eq 0 ]; then
    if [ ! -f "$STATE_DIR/functional-verified" ]; then
      echo "GATE-RECOVERABLE: A3.4 functional-verified state file missing in headless/auto mode — check for earlier A3.4 failure. (override: REPO_OS_RECOVER=1)" >&2
      block "state_func_verified_missing"
      log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "state_func_verified_missing"
    elif ! _validate_state_session_id "$STATE_DIR/functional-verified"; then
      echo "GATE-RECOVERABLE: functional-verified state file has stale session_id. NEXT: Re-run commit gate in this session (A3.4 re-runs automatically). (override: REPO_OS_RECOVER=1)" >&2
      block "state_func_verified_stale_session"
      log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "state_func_verified_stale_session"
    fi
  fi

  # pragmatist-signed: required on session types with an approval phase (Decision 0025)
  # Phase-state-aware: only enforce when phase-state exists (session initialized).
  # Sessions from before this gate was deployed won't have phase-state, providing
  # backward compatibility without a sentinel file.
  #
  # Provenance (Decision 0038 + this session): pragmatist-signed may be written by
  # three legitimate paths, each stamping a distinct marker:
  #   Writer 1 — state-writer.sh (Pragmatist Plan-Gating dispatch):
  #              field: dispatch_phase:
  #   Writer 2 — bundle_to_pragmatist_signed (Decision 0038 drift-check path):
  #              field: source: handoff-bundle
  #   Writer 3 — write_alignment_check_pragmatist_signed (Orchestrator deterministic
  #              alignment-check, Decision 0038 §7):
  #              field: source: alignment-check
  #
  # After session_id validation, at least one recognised provenance marker must be
  # present. A file carrying none is rejected as hand-written / forged.
  # Note: the marker is a provenance signal, not a cryptographic boundary — any
  # process that can write the state file can write the marker. This raises the bar
  # from "trivially forgeable" to "deliberately forgeable", which is the actual goal
  # (Decision t-0004: mechanical enforcement deters, does not cryptographically prevent).
  #
  # Backward compatibility: the provenance check lives inside the same
  # `has_plan_gate && [ -f phase-state ]` guard as the existing checks. Sessions
  # that pre-date the phase-state sentinel (before this gate was deployed) will
  # never enter this block, so pre-existing pragmatist-signed files are unaffected.
  if [ "$IS_EDITOR_LIVE_CLOSE" = true ]; then
    : # editor-live never has pragmatist-signed — skip silently
  elif [ "${REPO_OS_SKIP_PRAGMATIST_GATE:-0}" = "1" ]; then
    log_override "pre-commit-gates" "REPO_OS_SKIP_PRAGMATIST_GATE"
  else
    _PCG_STYPE=$(get_session_type)
    if has_plan_gate "$_PCG_STYPE" && [ -f "$STATE_DIR/phase-state" ]; then
      if [ ! -f "$STATE_DIR/pragmatist-signed" ]; then
        echo "GATE-RECOVERABLE: pragmatist-signed state file missing. NEXT: Dispatch Pragmatist agent in plan-gating mode before presenting plan to operator (Decision 0025). (override: REPO_OS_SKIP_PRAGMATIST_GATE=1)" >&2
        block "state_pragmatist_missing"
        log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "state_pragmatist_missing"
      elif ! _validate_state_session_id "$STATE_DIR/pragmatist-signed"; then
        echo "GATE-RECOVERABLE: pragmatist-signed state file has stale session_id. NEXT: Re-dispatch Pragmatist in this session. (override: REPO_OS_SKIP_PRAGMATIST_GATE=1)" >&2
        block "state_pragmatist_stale_session"
        log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "state_pragmatist_stale_session"
      else
        # Verdict check: block if Pragmatist verdict was BLOCKED (FUNDAMENTAL-MISMATCH).
        # This enforces that a blocking pragmatist finding was resolved or overridden
        # before committing, regardless of which writer produced the file.
        _PCG_PRAG_RESULT=$(grep '^GATE_RESULT: ' "$STATE_DIR/pragmatist-signed" 2>/dev/null | sed 's/^GATE_RESULT: *//' | awk '{print $1}' | head -1 || true)
        if [ "$_PCG_PRAG_RESULT" = "BLOCKED" ]; then
          echo "GATE-RECOVERABLE: pragmatist-signed verdict is BLOCKED — Pragmatist found a FUNDAMENTAL-MISMATCH that was not resolved. NEXT: Revise the plan to address the finding, re-dispatch Pragmatist, or override (Decision 0025 auto-mode: log advisory and proceed requires REPO_OS_SKIP_PRAGMATIST_GATE=1 at commit). (override: REPO_OS_SKIP_PRAGMATIST_GATE=1)" >&2
          block "state_pragmatist_blocked"
          log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "state_pragmatist_blocked"
        fi
        # Provenance check: require at least one recognised writer marker.
        # dispatch_phase: — Writer 1 (state-writer.sh / Pragmatist Plan-Gating dispatch)
        # source: handoff-bundle — Writer 2 (bundle_to_pragmatist_signed, Decision 0038)
        # source: alignment-check — Writer 3 (write_alignment_check_pragmatist_signed)
        _PCG_PRAG_DISPATCH=$(grep '^dispatch_phase:' "$STATE_DIR/pragmatist-signed" 2>/dev/null | head -1 || true)
        _PCG_PRAG_SOURCE=$(grep '^source:' "$STATE_DIR/pragmatist-signed" 2>/dev/null | sed 's/^source: *//' | head -1 || true)
        if [ -z "$_PCG_PRAG_DISPATCH" ] && \
           [ "$_PCG_PRAG_SOURCE" != "handoff-bundle" ] && \
           [ "$_PCG_PRAG_SOURCE" != "alignment-check" ]; then
          echo "GATE-RECOVERABLE: pragmatist-signed lacks a recognised provenance marker — not produced by a legitimate writer. Expected one of: dispatch_phase: (Pragmatist dispatch), source: handoff-bundle (bundle path), or source: alignment-check (deterministic alignment-check). NEXT: Dispatch Pragmatist in plan-gating mode (Decision 0025) or use write_alignment_check_pragmatist_signed / bundle_to_pragmatist_signed as appropriate. (override: REPO_OS_SKIP_PRAGMATIST_GATE=1)" >&2
          block "state_pragmatist_no_provenance"
          log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "state_pragmatist_no_provenance"
        fi
      fi
    fi
  fi
fi

# ============================================================
# Gate 3: Inter-session governance (advisory, first-fire, version-aware)
# Moved from former branch-guard Edit/Write to commit-time.
# Checks that Prompt 0 (spec-compiled) and Prompt A (advisory-reviewed)
# governance files exist AND that their embedded spec_version matches
# manifest.json `active` (Decision 0041). Non-blocking.
#
# Predicate per file:
#   match  := file exists AND spec_version == manifest.json.active
#             (null == null is treated as match — template/pre-spec state)
# On full match (both files match): write governance-checked, suppress
#   for rest of session.
# On any mismatch or missing: warn + DELETE governance-checked so the
#   warning re-fires on subsequent commit-gate runs.
# ============================================================
if [ "$SKIP_STATE" = false ]; then
  GOVERNANCE_CHECKED_FILE="$STATE_DIR/governance-checked"

  if [ ! -f "$GOVERNANCE_CHECKED_FILE" ]; then
    GOV_DIR="$REPO_ROOT/docs/ai/governance"
    MANIFEST_PATH="$REPO_ROOT/docs/spec/compiled/manifest.json"
    GOV_WARNINGS=""
    GOV_ANY_FAIL=false
    MISSING_FILES=""
    MISMATCH_FILES=""

    case "$CURRENT_BRANCH" in
      feature/*|fix/*|hotfix/*|release/*)
        # Read manifest active version (empty when null or manifest missing).
        ACTIVE_VERSION=""
        if [ -f "$MANIFEST_PATH" ]; then
          ACTIVE_VERSION=$(jq -r '.active // ""' "$MANIFEST_PATH" 2>/dev/null || echo "")
        fi

        for _ev in spec-compiled advisory-reviewed; do
          _evfile="$GOV_DIR/$_ev"
          if [ "$_ev" = "spec-compiled" ]; then
            _prompt_name="Prompt 0"
          else
            _prompt_name="Prompt A"
          fi
          if [ ! -f "$_evfile" ]; then
            GOV_WARNINGS="${GOV_WARNINGS}Advisory: docs/ai/governance/$_ev not found — $_prompt_name may not have completed governance write.\n"
            MISSING_FILES="${MISSING_FILES:+$MISSING_FILES,}$_ev"
            GOV_ANY_FAIL=true
            continue
          fi
          # Extract spec_version (inline awk — strips quotes and trailing whitespace;
          # null/~/missing/empty all normalised to "" so empty == empty matches in
          # template-mode / pre-spec repos).
          _ev_version=$(awk -F': *' '
            /^spec_version:[[:space:]]*/ {
              v=$2
              gsub(/^["'\'']|["'\'']$/, "", v)
              gsub(/[[:space:]]+$/, "", v)
              if (v == "null" || v == "~") v=""
              print v
              exit
            }
          ' "$_evfile")
          if [ "$_ev_version" != "$ACTIVE_VERSION" ]; then
            GOV_WARNINGS="${GOV_WARNINGS}Advisory: $_prompt_name not re-run since spec v${_ev_version:-<none>} → v${ACTIVE_VERSION:-<none>} — re-run to refresh docs/ai/governance/$_ev.\n"
            MISMATCH_FILES="${MISMATCH_FILES:+$MISMATCH_FILES,}$_ev"
            GOV_ANY_FAIL=true
          fi
        done
        ;;
    esac

    if [ -n "$GOV_WARNINGS" ]; then
      printf '%b' "$GOV_WARNINGS" >&2
      _warn_detail=""
      [ -n "$MISSING_FILES" ] && _warn_detail="missing:$MISSING_FILES"
      [ -n "$MISMATCH_FILES" ] && _warn_detail="${_warn_detail:+$_warn_detail;}mismatch:$MISMATCH_FILES"
      warn "gate3_gov_warning"
      log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "warn" "$START_MS" "gate3_gov_warning" "$_warn_detail"
    fi

    if [ "$GOV_ANY_FAIL" = true ]; then
      # Reset first-fire so warning re-surfaces on the next gate run.
      rm -f "$GOVERNANCE_CHECKED_FILE" 2>/dev/null || true
    else
      mkdir -p "$STATE_DIR" 2>/dev/null || true
      echo "checked" > "$GOVERNANCE_CHECKED_FILE" 2>/dev/null || true
    fi
  fi
fi

# ============================================================
# A2: Process — Scope Check (blocking with large-scope override)
# Any diff over 100 lines requires large-scope: true in plan-approved.
# Headless sessions: _headless-plan-approve.sh always writes large-scope: true.
# Hotfix sessions: approval phase exists; interactive sessions can obtain approval.
# ============================================================
if [ "$SKIP_STATE" = false ] && [ -n "$STAGED_FILES" ]; then
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
  # Also tracks the contract file path for A6.3 integration point verification.
  A6_SESSION_TYPE=$(get_session_type)
  A6_CONTRACT_PATH=""  # set when in_progress contract is found — used by A6.3
  if [ "$A6_SESSION_TYPE" = "taskgroup" ] || [ "$A6_SESSION_TYPE" = "taskgroup-merge" ]; then
    CONTRACT_FOUND=false
    if [ -d "$CONTRACT_DIR" ]; then
      for _a6_cf in "$CONTRACT_DIR"/*.yaml; do
        [ -f "$_a6_cf" ] || continue
        # Skip template files (prefixed with _)
        case "$(basename "$_a6_cf")" in _*) continue ;; esac
        if grep -q "status: in_progress" "$_a6_cf" 2>/dev/null; then
          CONTRACT_FOUND=true
          A6_CONTRACT_PATH="$_a6_cf"
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

  # A6.3: Integration point artifact verification (blocking)
  # When a task group contract exists with non-empty integration_points:,
  # verify each artifact path exists in the working tree.
  # Skip silently when: no contract found, no integration_points block, empty integration_points.
  # Override: SKIP_CONTRACT_CHECK=1 (already applies — outer guard handles this).
  if [ -n "$A6_CONTRACT_PATH" ]; then
    _A63_IN_IP=false
    _A63_ENTRY_STARTED=false
    _A63_NAME=""
    _A63_PRODUCER=""
    _A63_CONSUMER=""
    _A63_ARTIFACT=""

    _a63_check_artifact() {
      local _name="$1" _producer="$2" _consumer="$3" _artifact="$4"
      [ -z "$_artifact" ] && return  # empty artifact — skip silently
      local _found=false
      # Check for glob pattern vs specific file path
      case "$_artifact" in
        *\**|*\?*)
          # Glob pattern — check if any match exists
          set +e
          ls "$REPO_ROOT/$_artifact" > /dev/null 2>&1 && _found=true
          set -e
          ;;
        *)
          # Specific file path
          [ -f "$REPO_ROOT/$_artifact" ] && _found=true
          ;;
      esac
      if [ "$_found" = false ]; then
        echo "GATE-RECOVERABLE: A6.3 integration point artifact missing — $_artifact declared as produced by '${_producer:-unknown}' for '${_consumer:-unknown}' not found in working tree. NEXT: Ensure the producing brief has created this artifact. (override: SKIP_CONTRACT_CHECK=1)" >&2
        block "A6_3_artifact_missing"
        log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "A6_3_artifact_missing" "" "$_artifact"
      fi
    }

    while IFS= read -r _a63_line; do
      case "$_a63_line" in
        "integration_points:"*)
          _A63_IN_IP=true
          ;;
        "  - "*)
          # New list entry — check previous entry if we have one
          if [ "$_A63_ENTRY_STARTED" = true ] && [ -n "$_A63_ARTIFACT" ]; then
            _a63_check_artifact "$_A63_NAME" "$_A63_PRODUCER" "$_A63_CONSUMER" "$_A63_ARTIFACT"
          fi
          _A63_ENTRY_STARTED=true
          _A63_NAME=""
          _A63_PRODUCER=""
          _A63_CONSUMER=""
          _A63_ARTIFACT=""
          # Inline name: YAML format is "  - name: ..." (name on same line as list marker)
          if [ "$_A63_IN_IP" = true ]; then
            case "$_a63_line" in
              *"name: "*)
                _A63_NAME="${_a63_line#*name: }"
                _A63_NAME="${_A63_NAME#\"}"
                _A63_NAME="${_A63_NAME%\"}"
                # Strip inline YAML comment if present
                _A63_NAME="${_A63_NAME%%  #*}"
                _A63_NAME="${_A63_NAME% }"
                ;;
            esac
          fi
          ;;
        "    name: "*)
          # Separate-line name field (alternative YAML style)
          if [ "$_A63_IN_IP" = true ] && [ -z "$_A63_NAME" ]; then
            _A63_NAME="${_a63_line#*name: }"
            _A63_NAME="${_A63_NAME#\"}"
            _A63_NAME="${_A63_NAME%\"}"
          fi
          ;;
        "    producer: "*)
          if [ "$_A63_IN_IP" = true ]; then
            _A63_PRODUCER="${_a63_line#*producer: }"
            _A63_PRODUCER="${_A63_PRODUCER#\"}"
            _A63_PRODUCER="${_A63_PRODUCER%\"}"
          fi
          ;;
        "    consumer: "*)
          if [ "$_A63_IN_IP" = true ]; then
            _A63_CONSUMER="${_a63_line#*consumer: }"
            _A63_CONSUMER="${_A63_CONSUMER#\"}"
            _A63_CONSUMER="${_A63_CONSUMER%\"}"
          fi
          ;;
        "    artifact: "*)
          if [ "$_A63_IN_IP" = true ]; then
            _A63_ARTIFACT="${_a63_line#*artifact: }"
            _A63_ARTIFACT="${_A63_ARTIFACT#\"}"
            _A63_ARTIFACT="${_A63_ARTIFACT%\"}"
          fi
          ;;
        *)
          # Non-indented line after integration_points: ends the block
          if [ "$_A63_IN_IP" = true ]; then
            case "$_a63_line" in
              "  "*) ;; # still indented — inside integration_points
              *)
                # Check last entry before exiting block
                if [ "$_A63_ENTRY_STARTED" = true ] && [ -n "$_A63_ARTIFACT" ]; then
                  _a63_check_artifact "$_A63_NAME" "$_A63_PRODUCER" "$_A63_CONSUMER" "$_A63_ARTIFACT"
                  _A63_ENTRY_STARTED=false
                fi
                _A63_IN_IP=false
                ;;
            esac
          fi
          ;;
      esac
    done < "$A6_CONTRACT_PATH"

    # Check last entry if file ends while still in block
    if [ "$_A63_ENTRY_STARTED" = true ] && [ -n "$_A63_ARTIFACT" ]; then
      _a63_check_artifact "$_A63_NAME" "$_A63_PRODUCER" "$_A63_CONSUMER" "$_A63_ARTIFACT"
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

    # Staleness guard: two-tier content-digest check.
    # Tier 1 (cheap): mtime pre-filter. If no decision file is newer than the index,
    # the index is definitely current — stop here (common case after a real regenerate).
    # Tier 2 (only when Tier 1 fires): compare the digest stored in the index header
    # against a freshly-computed digest of all ## Triggers sections. Warn only when
    # digests differ — i.e. when triggers have genuinely changed, not merely when git
    # checkout shuffled mtimes (Decision t-0033: worktree is the default, making
    # mtime-shuffling on checkout the common case, not the edge case).
    _A1_MTIME_STALE=0
    for _A1_DF in "$DECISIONS_DIR"/t-*.md "$DECISIONS_DIR"/0*.md; do
      [ -f "$_A1_DF" ] || continue
      if [ "$_A1_DF" -nt "$A1_INDEX" ]; then
        _A1_MTIME_STALE=1
        break
      fi
    done

    if [ "$_A1_MTIME_STALE" = "1" ]; then
      # Tier 2: compare freshly-computed digest to the stored digest in the index header.
      _A1_STORED_DIGEST=$(grep '^# digest: ' "$A1_INDEX" 2>/dev/null | sed 's/^# digest: *//')
      if [ -n "$_A1_STORED_DIGEST" ]; then
        # Detect available sha256 tool (macOS: shasum; Linux/Docker: sha256sum).
        _A1_DIGEST_TOOL=""
        if command -v sha256sum >/dev/null 2>&1; then
          _A1_DIGEST_TOOL="sha256sum"
        elif command -v shasum >/dev/null 2>&1; then
          _A1_DIGEST_TOOL="shasum -a 256"
        fi

        if [ -n "$_A1_DIGEST_TOOL" ]; then
          # Locale-independent sort matches rebuild-trigger-index.sh exactly.
          # `ls` exits non-zero when EITHER glob matches nothing — and the real
          # decisions dir holds only t-*.md, so the 0*.md glob never matches.
          # Under `set -euo pipefail` that failure propagated out of the command
          # substitution and aborted the whole gate script. Tolerate it: the
          # byte stream is unchanged when files exist, empty when none do.
          # rebuild-trigger-index.sh computes this digest the same way and must
          # be kept byte-identical, or the digests can never agree.
          _A1_FRESH_DIGEST=$(
            { LC_ALL=C ls "$DECISIONS_DIR"/t-*.md "$DECISIONS_DIR"/0*.md 2>/dev/null || true; } \
              | LC_ALL=C sort \
              | while IFS= read -r _f; do
                  [ -f "$_f" ] || continue
                  grep -q '^## Triggers' "$_f" || continue
                  sed -n '/^## Triggers/,/^## /{ /^## Triggers/d; /^## /d; p; }' "$_f"
                done \
              | $_A1_DIGEST_TOOL \
              | awk '{print $1}'
          )
          if [ "$_A1_FRESH_DIGEST" != "$_A1_STORED_DIGEST" ]; then
            echo "A1 WARNING: .a1-trigger-index may be stale — regenerate: bash .claude/.automation/lib/rebuild-trigger-index.sh" >&2
            warn "A1_index_stale"
          fi
          # Digests match → mtimes were shuffled by checkout; index is current. No warning.
        else
          # No sha256 tool available — fall back to mtime-based warning.
          echo "A1 WARNING: .a1-trigger-index may be stale — regenerate: bash .claude/.automation/lib/rebuild-trigger-index.sh" >&2
          warn "A1_index_stale"
        fi
      else
        # No stored digest (old index format without header) — fall back to mtime warning.
        echo "A1 WARNING: .a1-trigger-index may be stale — regenerate: bash .claude/.automation/lib/rebuild-trigger-index.sh" >&2
        warn "A1_index_stale"
      fi
    fi

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
# Expected Changes trailer (advisory — NEVER blocks; Decision t-0050)
# ============================================================
# When the active brief declares expected_changes, nudge for a `Changes: EC-n`
# trailer so ec-report.sh can join intent to diffs.
#
# Deliberately advisory. Blocking would push people to staple an ID onto chore
# and session-log commits, and an unattributed commit is a RESULT here — it is
# reported as an "additional change", which is the most informative row in the
# report. Forcing attribution would destroy exactly the signal this exists for.
if [ "$SKIP_STATE" = false ] && [ -n "$STAGED_FILES" ]; then
  _EC_SRC=""
  for _ec_cand in "$REPO_ROOT"/.claude/local/handoff-bundles/*.yaml \
                  "$REPO_ROOT/.claude/local/task-contract.yaml"; do
    [ -f "$_ec_cand" ] || continue
    if grep -q '^[[:space:]]*expected_changes:[[:space:]]*$' "$_ec_cand" 2>/dev/null \
       && grep -qE '^[[:space:]]*-[[:space:]]*id:[[:space:]]*["'"'"']?EC-' "$_ec_cand" 2>/dev/null; then
      _EC_SRC="$_ec_cand"
      break
    fi
  done
  if [ -n "$_EC_SRC" ]; then
    if ! echo "$COMMIT_CMD" | grep -qiE 'Changes:[[:space:]]*EC-'; then
      echo "Advisory: brief declares expected_changes but this commit has no 'Changes: EC-n' trailer — it will be reported as an additional change. Add one if it delivers a declared outcome. (bash .claude/tools/ec-report.sh --text)" >&2
      warn "ec_trailer_absent"
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
# Project-Specific Checks (Gate A3 — Design Token Enforcement)
# ============================================================
# A3: Design Token Enforcement (Progressive)
# Activation: Install eslint-plugin-tailwindcss + custom design-token rules in child repo.
# Generate .tokens-manifest.json via `npm run tokens:build`.
# Gate is inert until tooling detected. Advisory when grep-only. Blocking when ESLint active.
# ============================================================
# Source helper (defines check_design_token_tooling, run_eslint_staged,
# run_grep_fallback, get_staged_frontend_files)
# shellcheck source=_a3-design-token-check.sh
source "$SCRIPT_DIR/_a3-design-token-check.sh"

# Only run when staged files exist and we are not in recovery mode
if [ "$SKIP_STATE" = false ] && [ -n "$STAGED_FILES" ]; then

  # --- Stage 1: Tooling detection ---
  A3_HAS_TOOLING=false
  check_design_token_tooling && A3_HAS_TOOLING=true

  if [ "$A3_HAS_TOOLING" = false ]; then
    # Neither ESLint token rules nor .tokens-manifest.json present — inert / advisory
    echo "A3 ADVISORY: Design token enforcement not configured — install ESLint token rules and generate token manifest to activate." >&2
    warn "A3_tooling_absent"
    log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "warn" "$START_MS" "A3_tooling_absent"
  else
    # --- Stage 2: ESLint on staged frontend files ---
    A3_ESLINT_OUTPUT=""
    A3_ESLINT_EXIT=0
    A3_ESLINT_OUTPUT=$(run_eslint_staged) || A3_ESLINT_EXIT=$?

    if [ "$A3_ESLINT_EXIT" -ne 0 ]; then
      echo "GATE-RECOVERABLE: A3 — ESLint design token violations in staged frontend files (see output above). NEXT: Fix token violations then re-stage. (override: REPO_OS_RECOVER=1)" >&2
      printf '%s\n' "$A3_ESLINT_OUTPUT" >&2
      block "A3_eslint_violation"
      log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "A3_eslint_violation"
    fi
  fi

  # --- Stage 3: Grep fallback (always runs when frontend files are staged) ---
  # Advisory when ESLint absent; redundant catch (still blocking) when ESLint present.
  A3_GREP_FINDINGS=""
  A3_GREP_EXIT=0
  A3_GREP_FINDINGS=$(run_grep_fallback 2>/dev/null) || A3_GREP_EXIT=$?

  if [ "$A3_GREP_EXIT" -ne 0 ] && [ -n "$A3_GREP_FINDINGS" ]; then
    if [ "$A3_HAS_TOOLING" = true ]; then
      # ESLint present — grep catch is redundant confirmation, still block
      echo "GATE-RECOVERABLE: A3 — Hardcoded design values detected in staged diff (grep fallback). NEXT: Replace hardcoded values with design tokens then re-stage. (override: REPO_OS_RECOVER=1)" >&2
      printf '%s\n' "$A3_GREP_FINDINGS" | head -5 >&2
      block "A3_grep_violation_with_eslint"
      log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "A3_grep_violation_with_eslint"
    else
      # No ESLint — advisory only
      echo "A3 ADVISORY: Possible hardcoded design values detected (grep fallback — install ESLint token rules to enforce blocking):" >&2
      printf '%s\n' "$A3_GREP_FINDINGS" | head -5 >&2
      warn "A3_grep_advisory"
      log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "warn" "$START_MS" "A3_grep_advisory"
    fi
  fi

fi

# ============================================================
# KG Update Gate (blocking — Decision 0034 Amendment 7)
# Two-half check on staged governance files:
#   COVERAGE  — a staged file has no node in the applicable graph (blocking).
#   FRESHNESS — a staged file HAS a node, but no graph file is staged AND no
#               session-scoped kg-updated marker is present (blocking).
# Six-branch exemption matrix downgrades to advisory (never blocks):
#   audit session | parallel tg-delta | experiment/* | graph not writable
#   in current mode | REPO_OS_RECOVER | REPO_OS_SKIP_KG_GATE
# FRESHNESS is a presence proxy: it verifies the graph was touched this
# session, not that the touch was semantically accurate (accepted limitation).
# ============================================================
if [ "$SKIP_STATE" = false ] && [ -n "$STAGED_FILES" ]; then
  KG_GRAPH="$REPO_ROOT/docs/ai/knowledge-graph/graph.yaml"
  KG_PRODUCT_GRAPH="$REPO_ROOT/docs/ai/knowledge-graph/product-graph.yaml"
  KG_COVER_TOOL="$REPO_ROOT/.claude/tools/kg-cover.sh"
  if [ -f "$KG_GRAPH" ]; then
    KG_GOV_PATHS='.claude/hooks/ .claude/tools/ docs/ai/decisions/ docs/ai/prompts/ .claude/agents/'

    # --- Build filtered list of staged governance files ---
    # Non-entity exclusions: the graph models governance *entities* (hooks, tools,
    # decisions, prompts, agents). Test artifacts, generated markers, and directory
    # placeholders are not entities — graphing them yields stub nodes that dilute
    # kg-relevance.sh scoring without adding signal. Note this forecloses populating
    # the taxonomy's `tests` relation (Decision 0034 §5) via this gate; test-to-hook
    # edges must be authored directly.
    _KG_GOV_STAGED=""
    while IFS= read -r _kg_file; do
      [ -z "$_kg_file" ] && continue
      case "$_kg_file" in
        *.lock|*.log) continue ;;  # generated artifacts
        */tests/*)    continue ;;  # test scripts and fixtures
        */.gitkeep)   continue ;;  # directory placeholders
        */.[!.]*)     continue ;;  # generated dotfile markers (.a1-trigger-index, etc.)
      esac
      _kg_in_gov=false
      for _kg_gov in $KG_GOV_PATHS; do
        case "$_kg_file" in "$_kg_gov"*) _kg_in_gov=true; break ;; esac
      done
      [ "$_kg_in_gov" = false ] && continue
      _KG_GOV_STAGED="${_KG_GOV_STAGED:+$_KG_GOV_STAGED }$_kg_file"
    done <<< "$STAGED_FILES"

    if [ -n "$_KG_GOV_STAGED" ]; then
      # --- Exemption matrix (any hit → advisory, never block) ---
      _KG_EXEMPT=false
      _KG_EXEMPT_REASON=""

      # Exemption 1: audit session (Prompt C read-only — Amendment 3 §3)
      # get_session_type() comes from _phase-helper.sh (sourced above).
      # Do NOT use infer_session_type() — it is defined only in
      # session-close-check.sh, so under `set -euo pipefail` it aborts this
      # hook with 127, which Claude Code treats as non-blocking. That silently
      # disabled this gate and every check below it.
      _KG_STYPE=$(get_session_type 2>/dev/null || echo "unknown")
      if [ "$_KG_STYPE" = "audit" ]; then
        _KG_EXEMPT=true; _KG_EXEMPT_REASON="audit_session"
      fi

      # Exemption 2: parallel task-group delta present (Amendment 5 — must not touch shared graph)
      if [ "$_KG_EXEMPT" = false ]; then
        for _kgd in "$REPO_ROOT/.claude/.state/tg-"*"-brief-"*".kg-delta.yaml"; do
          if [ -f "$_kgd" ]; then
            _KG_EXEMPT=true; _KG_EXEMPT_REASON="parallel_tg_delta"; break
          fi
        done
      fi

      # Exemption 3: experiment/* branch
      if [ "$_KG_EXEMPT" = false ] && [ "$IS_EXPERIMENT" = true ]; then
        _KG_EXEMPT=true; _KG_EXEMPT_REASON="experiment_branch"
      fi

      # Exemption 4: template graph not writable in current mode
      # Child mode cannot write graph.yaml (_mode-guard-helper.sh:130 carve-out absent).
      if [ "$_KG_EXEMPT" = false ]; then
        _KG_MODE="${REPO_OS_MODE:-}"
        if [ -z "$_KG_MODE" ] && [ -f "$REPO_ROOT/.claude/repo-mode" ]; then
          _KG_MODE=$(cat "$REPO_ROOT/.claude/repo-mode" 2>/dev/null | tr -d '[:space:]')
        fi
        _KG_MODE="${_KG_MODE:-child}"
        if [ "$_KG_MODE" != "template" ]; then
          _KG_EXEMPT=true; _KG_EXEMPT_REASON="graph_not_writable_mode:$_KG_MODE"
        fi
      fi

      # Exemption 5: REPO_OS_RECOVER=1 (belt-and-suspenders — SKIP_STATE already set above)
      if [ "$_KG_EXEMPT" = false ] && [ "${REPO_OS_RECOVER:-0}" = "1" ]; then
        _KG_EXEMPT=true; _KG_EXEMPT_REASON="repo_os_recover"
      fi

      # Exemption 6: REPO_OS_SKIP_KG_GATE=1 — interactive only; ignored in headless/auto
      # (precedent: SKIP_FUNC_CHECK in Decision t-0044 Amendment 1)
      if [ "$_KG_EXEMPT" = false ] && [ "${REPO_OS_SKIP_KG_GATE:-0}" = "1" ]; then
        if [ "$IS_NO_REVIEW_BACKSTOP" = false ]; then
          log_override "pre-commit-gates" "REPO_OS_SKIP_KG_GATE"
          _KG_EXEMPT=true; _KG_EXEMPT_REASON="skip_kg_gate_override"
        else
          log_override "pre-commit-gates" "REPO_OS_SKIP_KG_GATE_IGNORED_HEADLESS"
          echo "Advisory: REPO_OS_SKIP_KG_GATE=1 is ignored in headless/auto mode — KG gate still enforced." >&2
        fi
      fi

      if [ "$_KG_EXEMPT" = true ]; then
        warn "kg_update_advisory"
        log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "warn" "$START_MS" "kg_update_advisory_exempt" "$_KG_EXEMPT_REASON"
      else
        # --- COVERAGE half: staged gov file lacks a node in either graph ---
        _KG_MISSING_NODES=""
        _KG_HAS_NODES=""
        for _kg_file in $_KG_GOV_STAGED; do
          if grep -qF "path: \"$_kg_file\"" "$KG_GRAPH" 2>/dev/null           || { [ -f "$KG_PRODUCT_GRAPH" ] && grep -qF "path: \"$_kg_file\"" "$KG_PRODUCT_GRAPH" 2>/dev/null; }; then
            _KG_HAS_NODES="${_KG_HAS_NODES:+$_KG_HAS_NODES }$_kg_file"
          else
            _KG_MISSING_NODES="${_KG_MISSING_NODES:+$_KG_MISSING_NODES }$_kg_file"
          fi
        done

        # --- FRESHNESS half: graphed file staged, no graph staged, no session marker ---
        _KG_STALE=false
        if [ -n "$_KG_HAS_NODES" ]; then
          _KG_GRAPH_STAGED=false
          case "$STAGED_FILES" in
            *"docs/ai/knowledge-graph/graph.yaml"*)         _KG_GRAPH_STAGED=true ;;
          esac
          case "$STAGED_FILES" in
            *"docs/ai/knowledge-graph/product-graph.yaml"*) _KG_GRAPH_STAGED=true ;;
          esac
          if [ "$_KG_GRAPH_STAGED" = false ]; then
            if ! _validate_state_session_id "$STATE_DIR/kg-updated"; then
              _KG_STALE=true
            fi
          fi
        fi

        # --- Emit block or pass ---
        if [ -n "$_KG_MISSING_NODES" ] || [ "$_KG_STALE" = true ]; then
          if [ -n "$_KG_MISSING_NODES" ]; then
            _kg_count=$(echo "$_KG_MISSING_NODES" | wc -w | tr -d ' ')
            if [ -f "$KG_COVER_TOOL" ]; then
              echo "GATE-RECOVERABLE: KG update — $_kg_count governance file(s) staged without a graph node. NEXT: run .claude/tools/kg-cover.sh $_KG_MISSING_NODES then re-stage. (override: REPO_OS_SKIP_KG_GATE=1)" >&2
            else
              echo "GATE-RECOVERABLE: KG update — $_kg_count governance file(s) staged without a graph node. NEXT: add nodes to graph.yaml via shell I/O, then re-stage. (override: REPO_OS_SKIP_KG_GATE=1)" >&2
            fi
            log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "kg_update_coverage" "count:$_kg_count"
          fi
          if [ "$_KG_STALE" = true ]; then
            echo "GATE-RECOVERABLE: KG update — governance file(s) have graph nodes but no graph file is staged and no kg-updated marker found for this session. NEXT: update graph.yaml/product-graph.yaml and re-stage (or run .claude/tools/kg-cover.sh to refresh). (override: REPO_OS_SKIP_KG_GATE=1)" >&2
            log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "kg_update_freshness"
          fi
          # Headless/auto escalation (IS_NO_REVIEW_BACKSTOP pattern — A3.4 precedent ~lines 467-473)
          if [ "$IS_NO_REVIEW_BACKSTOP" = true ]; then
            _KG_ESC_DIR="$REPO_ROOT/.claude/.automation/escalations"
            if [ -d "$_KG_ESC_DIR" ]; then
              _KG_ESC_SID="${REPO_OS_SESSION_ID:-$(date -u +%Y%m%d-%H%M%S)}"
              _KG_ESC_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
              printf 'escalation:\n  id: "esc-%s-%s"\n  queue_entry_id: "%s"\n  type: "gate-failure"\n  severity: "blocking"\n  phase_at_exit: "commit"\n  tag_at_exit: "agent"\n  message: "KG Update Gate blocked — governance files staged without a corresponding graph update"\n  context: "missing_nodes: %s stale: %s"\n  created_at: "%s"\n  resolved: false\n  resolution: ""\n' \
                "$_KG_ESC_SID" "$(date -u +%Y%m%d-%H%M%S)" "$_KG_ESC_SID" \
                "${_KG_MISSING_NODES:-none}" "$_KG_STALE" "$_KG_ESC_TS" \
                > "$_KG_ESC_DIR/kg-update-fail-$(date -u +%Y%m%d-%H%M%S).yaml" 2>/dev/null || true
            fi
          fi
          block "kg_update_violation"
          log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "kg_update_violation"
        else
          # Both halves pass — write session-scoped kg-updated marker
          _KG_SID=""
          if [ -n "${REPO_OS_SESSION_ID:-}" ]; then
            _KG_SID="$REPO_OS_SESSION_ID"
          else
            _KG_SID=$(cat "$REPO_ROOT/.claude/.session-id" 2>/dev/null || echo "")
          fi
          printf 'timestamp: %s\nsession_id: %s\nresult: PASSED\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_KG_SID" \
            > "$STATE_DIR/kg-updated" 2>/dev/null || true
          log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "allow" "$START_MS" "kg_update_passed"
        fi
      fi
    fi
  fi
fi

# ============================================================
# KG Schema Gate (blocking — Decision 0034 Amendment 4)
# Triggered only when graph YAML files are staged.
# Calls kg-validate.sh --strict to enforce enum constraints.
# ============================================================
if [ -n "$STAGED_FILES" ]; then
  KG_TEMPLATE_STAGED=false
  KG_PRODUCT_STAGED=false
  case "$STAGED_FILES" in
    *"docs/ai/knowledge-graph/graph.yaml"*)         KG_TEMPLATE_STAGED=true ;;
  esac
  case "$STAGED_FILES" in
    *"docs/ai/knowledge-graph/product-graph.yaml"*) KG_PRODUCT_STAGED=true ;;
  esac

  if [ "$KG_TEMPLATE_STAGED" = true ] || [ "$KG_PRODUCT_STAGED" = true ]; then
    KG_VALIDATOR="$REPO_ROOT/.claude/tools/kg-validate.sh"
    if [ ! -f "$KG_VALIDATOR" ]; then
      echo "Advisory: kg-validate.sh not found at $KG_VALIDATOR — KG schema gate skipped" >&2
      warn "kg_schema_validator_missing"
    else
      # Determine which target(s) to validate
      KG_VALIDATE_TARGET="both"
      if [ "$KG_TEMPLATE_STAGED" = true ] && [ "$KG_PRODUCT_STAGED" = false ]; then
        KG_VALIDATE_TARGET="template"
      elif [ "$KG_TEMPLATE_STAGED" = false ] && [ "$KG_PRODUCT_STAGED" = true ]; then
        KG_VALIDATE_TARGET="product"
      fi

      KG_VALIDATE_OUTPUT=$(bash "$KG_VALIDATOR" --strict --target "$KG_VALIDATE_TARGET" 2>&1) || KG_VALIDATE_EXIT=$?
      KG_VALIDATE_EXIT=${KG_VALIDATE_EXIT:-0}

      if [ "$KG_VALIDATE_EXIT" -ne 0 ]; then
        echo "GATE-RECOVERABLE: KG schema — invalid graph data in staged file(s). NEXT: Fix the violations listed below and re-stage." >&2
        printf '%s\n' "$KG_VALIDATE_OUTPUT" >&2
        block "kg_schema_violation"
        log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "kg_schema_violation" "target:$KG_VALIDATE_TARGET"
      else
        log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "allow" "$START_MS" "kg_schema_pass" "target:$KG_VALIDATE_TARGET"
      fi
    fi
  fi
fi

# ============================================================
# Evidence Manifest Integrity Check (advisory — never blocks)
# Runs after all gates so functional-verified is already written (A3.4).
# Gated on SKIP_STATE to mirror the state-check block above.
# ============================================================
if [ "$SKIP_STATE" = false ]; then
  compare_manifest 2>&1 | grep -v '^$' >&2 || true
fi

# ============================================================
# Final exit
# ============================================================
if [ "$FAILED" -ne 0 ]; then
  log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "$BLOCKED_REASONS"
  echo "Commit blocked by pre-commit gate check." >&2
  exit 2
fi

REASON="pass"
[ "${REPO_OS_RECOVER:-0}" = "1" ] && REASON="recover_override"
[ -n "$WARN_REASONS" ] && REASON="${REASON:+$REASON }$WARN_REASONS"
log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "allow" "$START_MS" "$REASON"
