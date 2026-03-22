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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Read SubagentStop payload (before sourcing — cat/jq need no libraries) ---
INPUT=$(cat)
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

# --- Worktree isolation guard (Decision 0028) ---
# Worktree-isolated subagents must not write governance state files.
# Their verdicts would reflect worktree content, not the main working tree.
if is_worktree; then
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
STATE_DIR="$REPO_ROOT/.claude/.state"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# --- Phase validation (adversarial C6/H3): verify current phase matches agent type ---
# Prevents spoofed agent_type from writing state files during wrong phase.
# Never blocks (exit 0) — enforcement at commit time via pre-commit-gates.sh.
CURRENT_PHASE=$(get_phase)
PHASE_OK=true
if [ -n "$CURRENT_PHASE" ]; then
  case "$AGENT_TYPE" in
    critic)
      # critic writes cohesion-reviewed during review phase
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
      # pragmatist writes during plan or review phase
      [ "$CURRENT_PHASE" != "plan" ] && [ "$CURRENT_PHASE" != "review" ] && PHASE_OK=false
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
STATE_SID=$(cat "$REPO_ROOT/.claude/.session-id" 2>/dev/null || echo "")
printf 'timestamp: %s\nagent: %s\nsession_id: %s\n%s\n' "$TIMESTAMP" "$AGENT_TYPE" "$STATE_SID" "$LAST_LINE" \
  > "$STATE_DIR/$STATE_FILE" 2>/dev/null || true

# --- Phase advancement based on agent verdict ---
# Only advance on APPROVED results (BLOCKED loops back to build via orchestrator).
# Fail-silent: if phase-state absent, skip advancement.
GATE_VALUE=$(echo "$LAST_LINE" | sed 's/^GATE_RESULT: *//' | awk '{print $1}')

if [ -n "$(get_phase)" ]; then
  case "$AGENT_TYPE" in
    critic)
      # critic (cohesion-reviewed): advance review → verify on APPROVED only
      if [ "$GATE_VALUE" = "APPROVED" ]; then
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
GATE_RESULT_DETAIL=$(printf '%.64s' "$LAST_LINE")
log_hook_event "state-writer" "SubagentStop" "$AGENT_TYPE" "write" "$START_MS" "$STATE_FILE" "$GATE_RESULT_DETAIL"
exit 0