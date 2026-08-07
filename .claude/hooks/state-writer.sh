#!/usr/bin/env bash
# State writer — captures governance agent verdicts as state files.
# Wired to SubagentStop (all agents) via .claude/settings.json.
# Only processes governance agents: critic, qa-verifier, reviewer, security-privacy, pragmatist.
# Extracts GATE_RESULT: sentinel from last non-empty line of agent output.
# Writes state files via shell I/O — never the Write tool.
# Never blocks (always exit 0) — enforcement happens at commit time.
# Phase advancement: advances phase on APPROVED results for critic and qa-verifier.
# critic APPROVED: advance review → verify. qa-verifier APPROVED: advance verify → commit.
# BLOCKED results: no phase advance (orchestrator handles loop-back).
#
# Critic routing:
#   - Combined output (both '## Cohesion Brief' and '## Diff-Review Brief' headers):
#     parse both sections, write cohesion-reviewed AND diff-review-complete from
#     one SubagentStop event. Phase advance follows the cohesion GATE_RESULT.
#   - Single cohesion mode (no diff-review header): write cohesion-reviewed.
#   - Single diff-review mode ('MODE: diff-review' sentinel): write diff-review-complete.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Read SubagentStop payload (before sourcing — cat/jq need no libraries) ---
INPUT=$(cat)

# --- Harness session_id plumbing (must precede first get_session_id call) ---
export _REPO_OS_STDIN_SID
_REPO_OS_STDIN_SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"

AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')

# --- Non-governance agent fast exit (Phase 2c — no sourcing needed) ---
# 96% of fires are non-governance agents. Exit immediately without sourcing
# libraries (~14ms saved per fire). No analytics for this path (unchanged).
case "$AGENT_TYPE" in
  critic|qa-verifier|reviewer|security-privacy|pragmatist) ;; # governance — continue below
  *) exit 0 ;;
esac

# --- Source libraries (only governance agent paths reach here) ---
source "$SCRIPT_DIR/_analytics-helper.sh"
source "$SCRIPT_DIR/_phase-helper.sh"
START_MS=$(now_ms)

# --- Worktree isolation guard (Decision 0028, updated by Decision 0030) ---
# Subagent worktrees: skip (verdicts reflect worktree content, not main working tree).
# Full worktree sessions (REPO_OS_SESSION_ID set): allow (independent governance lifecycle).
if is_worktree && ! is_full_worktree_session; then
  log_hook_event "state-writer" "SubagentStop" "$AGENT_TYPE" "skip" "$START_MS" "worktree_blocked"
  exit 0
fi

# --- Map agent type to state file (Bash 3 compatible) ---
STATE_FILE=""
case "$AGENT_TYPE" in
  critic)           STATE_FILE="cohesion-reviewed" ;;
  qa-verifier)      STATE_FILE="qa-verified" ;;
  reviewer)         STATE_FILE="reviewer-signed" ;;
  security-privacy) STATE_FILE="security-signed" ;;
  pragmatist)       STATE_FILE="pragmatist-signed" ;;
esac

# --- Extract last assistant message ---
LAST_MESSAGE=$(echo "$INPUT" | jq -r '.last_assistant_message // empty')

if [ -z "$LAST_MESSAGE" ]; then
  echo "WARNING: $AGENT_TYPE completed with empty output — state file not written" >&2
  log_hook_event "state-writer" "SubagentStop" "$AGENT_TYPE" "skip" "$START_MS" "no_message"
  exit 0
fi

# --- Critic routing (single-mode legacy + combined dual-section) ---
# Combined output has BOTH '## Cohesion Brief' and '## Diff-Review Brief' headers
# at column 0. When detected, both state files are written from one SubagentStop
# event (see "Combined output write" block below). Single-mode dispatches remain
# valid: cohesion-only → cohesion-reviewed; 'MODE: diff-review' → diff-review-complete.
CRITIC_COMBINED=false
if [ "$AGENT_TYPE" = "critic" ]; then
  if echo "$LAST_MESSAGE" | grep -q '^## Cohesion Brief' && \
     echo "$LAST_MESSAGE" | grep -q '^## Diff-Review Brief'; then
    CRITIC_COMBINED=true
  elif echo "$LAST_MESSAGE" | grep -q '^MODE: diff-review'; then
    STATE_FILE="diff-review-complete"
  fi
fi

# --- Extract last non-empty line ---
LAST_LINE=$(echo "$LAST_MESSAGE" | awk 'NF{line=$0} END{print line}')

# --- Check for GATE_RESULT: sentinel ---
if [[ "$LAST_LINE" != GATE_RESULT:* ]]; then
  echo "WARNING: $AGENT_TYPE completed without GATE_RESULT sentinel — state file not written" >&2
  log_hook_event "state-writer" "SubagentStop" "$AGENT_TYPE" "skip" "$START_MS" "no_sentinel"
  exit 0
fi

# --- Write state file ---
REPO_ROOT="$(get_repo_root)"
STATE_DIR="$(get_session_state_dir)"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# --- Phase validation (adversarial C6/H3): verify current phase matches agent type ---
# Prevents spoofed agent_type from writing state files during wrong phase.
# Never blocks (exit 0) — enforcement at commit time via pre-commit-gates.sh.
CURRENT_PHASE=$(get_phase)
PHASE_OK=true
if [ -n "$CURRENT_PHASE" ]; then
  case "$AGENT_TYPE" in
    critic)
      # critic writes cohesion-reviewed (cohesion mode) or diff-review-complete (diff-review mode)
      # both during the review phase — STATE_FILE is already routed correctly above
      [ "$CURRENT_PHASE" != "review" ] && PHASE_OK=false
      ;;
    qa-verifier)
      # qa-verifier writes qa-verified during verify phase
      [ "$CURRENT_PHASE" != "verify" ] && PHASE_OK=false
      ;;
    reviewer|security-privacy)
      # reviewer/security-privacy write during verify phase
      [ "$CURRENT_PHASE" != "verify" ] && PHASE_OK=false
      ;;
    pragmatist)
      # pragmatist writes during plan, review, or build phase (background dispatch from plan may complete during build).
      # Also allowed in synthesize phase: taskdef-brief dispatches pragmatist during synthesize for the
      # approval gate — without this, the gate is unsatisfiable in that session type.
      # plan/review/build covers Prompt B (product build); synthesize covers taskdef-brief only.
      [ "$CURRENT_PHASE" != "plan" ] && [ "$CURRENT_PHASE" != "review" ] && [ "$CURRENT_PHASE" != "build" ] && [ "$CURRENT_PHASE" != "synthesize" ] && PHASE_OK=false
      ;;
  esac
fi
if [ "$PHASE_OK" = false ]; then
  echo "WARNING: $AGENT_TYPE fired during '$CURRENT_PHASE' phase (expected different phase) — state file not written" >&2
  log_hook_event "state-writer" "SubagentStop" "$AGENT_TYPE" "skip" "$START_MS" "phase_mismatch:$CURRENT_PHASE"
  exit 0
fi

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# Session-bind state file (adversarial C1/C4/H4): embed session_id so
# pre-commit-gates.sh can reject forged/stale files from other sessions.
if [ -n "${REPO_OS_SESSION_ID:-}" ]; then
  STATE_SID="$REPO_OS_SESSION_ID"
else
  STATE_SID=$(cat "$REPO_ROOT/.claude/.session-id" 2>/dev/null || echo "")
fi

# --- Combined output write (critic dual-section) ---
# When CRITIC_COMBINED=true, split LAST_MESSAGE at the '## Diff-Review Brief'
# header, validate each section ends with GATE_RESULT, and write both
# cohesion-reviewed and diff-review-complete from this single SubagentStop
# event. Single-mode output falls through to the standard single-file write below.
if [ "$CRITIC_COMBINED" = true ]; then
  COHESION_PART=$(echo "$LAST_MESSAGE" | awk '/^## Diff-Review Brief/{exit} {print}')
  DIFF_REVIEW_PART=$(echo "$LAST_MESSAGE" | awk '/^## Diff-Review Brief/{found=1} found{print}')
  COHESION_LAST=$(echo "$COHESION_PART" | awk 'NF{line=$0} END{print line}')
  DIFF_REVIEW_LAST=$(echo "$DIFF_REVIEW_PART" | awk 'NF{line=$0} END{print line}')

  if [[ "$COHESION_LAST" != GATE_RESULT:* ]] || [[ "$DIFF_REVIEW_LAST" != GATE_RESULT:* ]]; then
    echo "WARNING: critic combined output missing GATE_RESULT in one or both sections — state files not written" >&2
    log_hook_event "state-writer" "SubagentStop" "$AGENT_TYPE" "skip" "$START_MS" "combined_no_sentinel"
    exit 0
  fi

  printf 'timestamp: %s\nagent: %s\nsession_id: %s\n%s\n' \
    "$TIMESTAMP" "$AGENT_TYPE" "$STATE_SID" "$COHESION_LAST" \
    > "$STATE_DIR/cohesion-reviewed" 2>/dev/null || true

  COMBINED_COMPLETENESS_LINE=$(echo "$COHESION_PART" | grep -E '^COMPLETENESS: ' | tail -1 || true)
  COMBINED_COMPLETENESS_GATE_LINE=$(echo "$COHESION_PART" | grep -E '^COMPLETENESS_GATE: ' | tail -1 || true)
  if [ -n "$COMBINED_COMPLETENESS_LINE" ]; then
    printf '%s\n' "$COMBINED_COMPLETENESS_LINE" >> "$STATE_DIR/cohesion-reviewed" 2>/dev/null || true
  fi
  if [ -n "$COMBINED_COMPLETENESS_GATE_LINE" ]; then
    printf '%s\n' "$COMBINED_COMPLETENESS_GATE_LINE" >> "$STATE_DIR/cohesion-reviewed" 2>/dev/null || true
  fi

  printf 'timestamp: %s\nagent: %s\nsession_id: %s\n%s\n' \
    "$TIMESTAMP" "$AGENT_TYPE" "$STATE_SID" "$DIFF_REVIEW_LAST" \
    > "$STATE_DIR/diff-review-complete" 2>/dev/null || true

  COHESION_GATE_VALUE=$(echo "$COHESION_LAST" | sed 's/^GATE_RESULT: *//' | awk '{print $1}')
  if [ -n "$(get_phase)" ] && [ "$COHESION_GATE_VALUE" = "APPROVED" ]; then
    advance_phase "verify" 2>/dev/null || true
  fi

  refresh_manifest_entry "cohesion-reviewed" 2>/dev/null || true
  refresh_manifest_entry "diff-review-complete" 2>/dev/null || true
  COMBINED_DETAIL=$(printf 'cohesion=%.20s diff=%.20s' "$COHESION_LAST" "$DIFF_REVIEW_LAST" | tr -d '\n' | cut -c1-64)
  log_hook_event "state-writer" "SubagentStop" "$AGENT_TYPE" "write" "$START_MS" "cohesion-reviewed+diff-review-complete" "$COMBINED_DETAIL"
  exit 0
fi

printf 'timestamp: %s\nagent: %s\nsession_id: %s\n%s\n' "$TIMESTAMP" "$AGENT_TYPE" "$STATE_SID" "$LAST_LINE" \
  > "$STATE_DIR/$STATE_FILE" 2>/dev/null || true

# --- Completeness capture (critic cohesion mode only) ---
# Appends COMPLETENESS: score and COMPLETENESS_GATE: verdict to cohesion-reviewed state file.
# COMPLETENESS_GATE: APPROVED|NEEDS_WORK is the downstream blocking signal read by
# outcome-detector.sh, pre-commit-gates.sh, and session-close-check.sh.
# Distinct from GATE_RESULT (cohesion verdict — always the last non-empty line).
# Skip for diff-review mode: diff-review-complete does not use completeness scoring.
if [ "$AGENT_TYPE" = "critic" ] && [ "$STATE_FILE" = "cohesion-reviewed" ]; then
  COMPLETENESS_LINE=$(echo "$LAST_MESSAGE" | grep -E '^COMPLETENESS: ' | tail -1 || true)
  COMPLETENESS_GATE_LINE=$(echo "$LAST_MESSAGE" | grep -E '^COMPLETENESS_GATE: ' | tail -1 || true)
  if [ -n "$COMPLETENESS_LINE" ]; then
    printf '%s\n' "$COMPLETENESS_LINE" >> "$STATE_DIR/$STATE_FILE" 2>/dev/null || true
  fi
  if [ -n "$COMPLETENESS_GATE_LINE" ]; then
    printf '%s\n' "$COMPLETENESS_GATE_LINE" >> "$STATE_DIR/$STATE_FILE" 2>/dev/null || true
  fi
fi

# --- Phase advancement based on agent verdict ---
# Only advance on APPROVED results (BLOCKED loops back to build via orchestrator).
# Fail-silent: if phase-state absent, skip advancement.
GATE_VALUE=$(echo "$LAST_LINE" | sed 's/^GATE_RESULT: *//' | awk '{print $1}')

if [ -n "$(get_phase)" ]; then
  case "$AGENT_TYPE" in
    critic)
      # critic cohesion mode (cohesion-reviewed): advance review → verify on APPROVED only
      # critic diff-review mode (diff-review-complete): no phase advancement
      # (cohesion-reviewed is the primary phase gate; diff-review is a parallel check)
      if [ "$STATE_FILE" = "cohesion-reviewed" ] && [ "$GATE_VALUE" = "APPROVED" ]; then
        advance_phase "verify" 2>/dev/null || true
      fi
      ;;
    qa-verifier)
      # qa-verifier (qa-verified): advance verify → commit on APPROVED only
      if [ "$GATE_VALUE" = "APPROVED" ]; then
        advance_phase "commit" 2>/dev/null || true
      fi
      ;;
    # reviewer, security-privacy: no phase advancement (sub-steps within verify)
  esac
fi

# Capture GATE_RESULT value for analytics (truncate to 64 chars)
refresh_manifest_entry "$STATE_FILE" 2>/dev/null || true
GATE_RESULT_DETAIL=$(printf '%.64s' "$LAST_LINE")
log_hook_event "state-writer" "SubagentStop" "$AGENT_TYPE" "write" "$START_MS" "$STATE_FILE" "$GATE_RESULT_DETAIL"
exit 0