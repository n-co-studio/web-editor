#!/usr/bin/env bash
# Pre-commit gate verification — blocking enforcement.
# Runs automatically before git commit via .claude/settings.json hook.
# Exit non-zero to block the commit.
#
# Gates enforced:
#   A4  Safety — secret scanning (always, blocking)
#   State verification — plan-approved, cohesion-reviewed, qa-verified (blocking)
#   A2  Process — scope check >100 lines (blocking with large-scope override)
#   A6  Task Group — contract staging (blocking)
#   High-risk — pattern detection + sign-off enforcement (blocking)
#   A1  Decision trigger parser (blocking — enforced by .a1-triggers-enforced sentinel)
#
# Overrides:
#   REPO_OS_RECOVER=1    — skip all state-dependent checks (emergency recovery)
#   SKIP_CONTRACT_CHECK=1 — skip A6 contract staging check
#
# Branch profiles:
#   experiment/*  — A4 only (all state checks skipped)
#   hotfix/*      — A2 scope relaxed, A5 cohesion skipped

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_analytics-helper.sh"
START_MS=$(now_ms)

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

# ============================================================
# A4: Safety — Secret Scanning (always runs, blocking)
# ============================================================
SECRET_PATTERN='sk_live_|sk_test_|ghp_[A-Za-z0-9]|AKIA[A-Z0-9]|AIza[A-Za-z0-9]|-----BEGIN.*PRIVATE KEY-----|password\s*=\s*["\x27][^"\x27]|secret\s*=\s*["\x27][^"\x27]|token\s*=\s*["\x27][^"\x27]'

if [ -n "$STAGED_FILES" ]; then
  MATCHES=$(echo "$STAGED_FILES" | xargs grep -lE "$SECRET_PATTERN" 2>/dev/null || true)
  if [ -n "$MATCHES" ]; then
    echo "GATE A4 FAILED: Possible secret in: $MATCHES" >&2
    block "A4_secret_detected"
    log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "A4_secret_detected" "" "$(echo "$MATCHES" | head -1)"
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

# ============================================================
# State File Verification (blocking — skipped by REPO_OS_RECOVER)
# ============================================================
if [ "$SKIP_STATE" = false ]; then
  # plan-approved: required on all non-experiment branches
  # Override: REPO_OS_SKIP_PLAN_GATE=1 (parity with branch-guard plan gate)
  if [ "${REPO_OS_SKIP_PLAN_GATE:-0}" = "1" ]; then
    log_override "pre-commit-gates" "REPO_OS_SKIP_PLAN_GATE"
  elif [ ! -f "$STATE_DIR/plan-approved" ]; then
    echo "GATE STATE FAILED: .claude/.state/plan-approved not found — run plan approval first (override: REPO_OS_SKIP_PLAN_GATE=1)" >&2
    block "state_plan_missing"
    log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "state_plan_missing"
  fi

  # cohesion-reviewed: required except on hotfix/* (A5 skipped per gate profile)
  if [ "$IS_HOTFIX" = false ] && [ ! -f "$STATE_DIR/cohesion-reviewed" ]; then
    echo "GATE STATE FAILED: .claude/.state/cohesion-reviewed not found — run Critic cohesion review first" >&2
    block "state_cohesion_missing"
    log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "state_cohesion_missing"
  fi

  # qa-verified: required on all non-experiment branches
  if [ ! -f "$STATE_DIR/qa-verified" ]; then
    echo "GATE STATE FAILED: .claude/.state/qa-verified not found — run QA verification first" >&2
    block "state_qa_missing"
    log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "state_qa_missing"
  fi
fi

# ============================================================
# Gate 3: Inter-session governance (advisory, first-fire)
# Moved from branch-guard Edit/Write to commit-time.
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
# Gate 4: Phase chain verification (advisory, first-fire)
# Moved from branch-guard Edit/Write to commit-time.
# For task group sessions: verifies the previous brief completed with
# governance evidence in the contract.
# Non-blocking: prints warning if prior brief lacks governance entry.
# ============================================================
if [ "$SKIP_STATE" = false ]; then
  PHASE_CHECKED_FILE="$STATE_DIR/phase-chain-checked"

  if [ ! -f "$PHASE_CHECKED_FILE" ]; then
    REPO_MODE_FILE_G4="$REPO_ROOT/.claude/repo-mode"
    if [ -f "$REPO_MODE_FILE_G4" ] && grep -q "template" "$REPO_MODE_FILE_G4" 2>/dev/null; then
      CONTRACT_DIR_G4="$REPO_ROOT/.claude/local/task-groups"
    else
      CONTRACT_DIR_G4="$REPO_ROOT/docs/ai/task-groups"
    fi

    if [ -d "$CONTRACT_DIR_G4" ]; then
      for CONTRACT_G4 in "$CONTRACT_DIR_G4"/*.yaml; do
        [ -f "$CONTRACT_G4" ] || continue
        [ "$(basename "$CONTRACT_G4")" = "_contract-template.yaml" ] && continue

        PENDING_SEQ_G4=$(grep -B1 "status: pending" "$CONTRACT_G4" 2>/dev/null \
          | grep "sequence:" | sed 's/.*sequence: *//' | head -1 || true)

        if [ -n "$PENDING_SEQ_G4" ] && [ "$PENDING_SEQ_G4" -gt 1 ] 2>/dev/null; then
          PREV_SEQ_G4=$((PENDING_SEQ_G4 - 1))
          if ! grep -q "brief_sequence: $PREV_SEQ_G4" "$CONTRACT_G4" 2>/dev/null; then
            GROUP_NAME_G4=$(basename "$CONTRACT_G4" .yaml)
            echo "Advisory: Task group '$GROUP_NAME_G4' — prior brief (sequence $PREV_SEQ_G4) has no governance evidence in contract." >&2
            warn "gate4_chain_warning"
            log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "warn" "$START_MS" "gate4_chain_warning" "$GROUP_NAME_G4:seq$PREV_SEQ_G4"
          fi
        fi
      done
    fi

    mkdir -p "$STATE_DIR" 2>/dev/null || true
    echo "checked" > "$PHASE_CHECKED_FILE" 2>/dev/null || true
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
      echo "GATE A2 FAILED: $LINES_CHANGED lines changed — exceeds 100-line threshold without large-scope approval" >&2
      block "A2_scope_exceeded"
      log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "A2_scope_exceeded" "lines:$LINES_CHANGED"
    fi
  fi
fi

# ============================================================
# A6: Task Group — Contract Staging Check (blocking)
# Override: SKIP_CONTRACT_CHECK=1
# Note: Template-mode contracts live in .claude/local/task-groups/ (gitignored),
# so git diff won't detect them — staging check is inherently N/A for those.
# The mode-routing is kept for consistency with session-close-check.sh.
# ============================================================
if [ "${SKIP_CONTRACT_CHECK:-0}" = "1" ]; then
  log_override "pre-commit-gates" "SKIP_CONTRACT_CHECK"
fi
if [ "${SKIP_CONTRACT_CHECK:-0}" != "1" ]; then
  REPO_MODE_FILE="$REPO_ROOT/.claude/repo-mode"
  if [ -f "$REPO_MODE_FILE" ] && grep -q "template" "$REPO_MODE_FILE" 2>/dev/null; then
    CONTRACT_DIR="$REPO_ROOT/.claude/local/task-groups"
  else
    CONTRACT_DIR="$REPO_ROOT/docs/ai/task-groups"
  fi
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
        echo "GATE A6 FAILED: Task group contract modified but not staged: $NOT_STAGED" >&2
        block "A6_contract_unstaged"
        log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "A6_contract_unstaged" "" "$NOT_STAGED"
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
  NON_TEST_FILES=$(echo "$NON_TEST_FILES" | grep -vE '^(docs/ai/|\.claude/|AI\.md$|CLAUDE\.md$)' || true)

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
    RISK_CONTENT_MATCHES=$(git diff --cached -U0 -- $NON_TEST_FILES 2>/dev/null \
      | grep '^+' | grep -v '^+++' \
      | grep -iE "$RISK_CONTENT_PATTERN" || true)
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
      echo "GATE HIGH-RISK FAILED: High-risk patterns detected — missing sign-offs: $MISSING_SIGNOFFS" >&2
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

# ============================================================
# A1: Decision Trigger Parser (blocking — enforced by .a1-triggers-enforced sentinel)
# ============================================================
if [ -n "$STAGED_FILES" ] && [ -d "$DECISIONS_DIR" ]; then
  A1_BLOCKING=false
  [ -f "$DECISIONS_DIR/.a1-triggers-enforced" ] && A1_BLOCKING=true

  if [ "$A1_BLOCKING" = false ]; then
    warn "A1_advisory_mode"
    echo "Advisory: docs/ai/decisions/.a1-triggers-enforced not found — A1 decision triggers running in advisory mode (not blocking)" >&2
  fi

  TRIGGERED_DECISIONS=""
  MISSING_TRIGGERS=0
  TOTAL_DECISIONS=0

  for DECISION_FILE in "$DECISIONS_DIR"/0*.md; do
    [ -f "$DECISION_FILE" ] || continue
    TOTAL_DECISIONS=$((TOTAL_DECISIONS + 1))

    DECISION_ID=$(basename "$DECISION_FILE" | grep -oE '^[0-9]+')

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
        # Match staged files against glob
        MATCHING_FILES=$(echo "$STAGED_FILES" | grep -E "$GLOB_PATTERN" || true)
        if [ -n "$MATCHING_FILES" ]; then
          if [ -n "$TRIGGER_KEYWORDS" ]; then
            # If keywords defined, also check content
            KW_PATTERN=$(echo "$TRIGGER_KEYWORDS" | sed 's/`//g' | sed 's/[[:space:]]*,[[:space:]]*/|/g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            KW_MATCHES=$(git diff --cached -U0 -- $MATCHING_FILES 2>/dev/null \
              | grep '^+' | grep -v '^+++' \
              | grep -iE "$KW_PATTERN" || true)
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

  # Check Decisions: trailer in commit message
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
        echo "GATE A1 FAILED: Decisions triggered but not declared in trailer: $MISSING_DECISION_IDS" >&2
        block "A1_decisions_missing"
        log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "block" "$START_MS" "A1_decisions_missing" "$A1_DETAIL"
      else
        echo "GATE A1 WARNING: Decisions triggered but not declared in trailer: $MISSING_DECISION_IDS — include in Decisions: trailer" >&2
        warn "A1_decisions_advisory"
        log_hook_event "pre-commit-gates" "PreToolUse" "Bash" "warn" "$START_MS" "A1_decisions_advisory" "$A1_DETAIL"
      fi
    fi
  fi

  # --- A1 structural check ---
  if [ "$MISSING_TRIGGERS" -gt 0 ]; then
    if [ "$A1_BLOCKING" = true ]; then
      echo "GATE A1 FAILED: $MISSING_TRIGGERS of $TOTAL_DECISIONS decision files lack ## Triggers section" >&2
      block "A1_missing_triggers"
    else
      echo "GATE A1 WARNING: $MISSING_TRIGGERS of $TOTAL_DECISIONS decision files lack ## Triggers section" >&2
      warn "A1_structural_advisory"
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
