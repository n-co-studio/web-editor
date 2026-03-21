#!/usr/bin/env bash
# Plan approval — captures operator plan approvals as state.
# Wired to PostToolUse on AskUserQuestion via .claude/settings.json.
# Writes .claude/.state/plan-approved when operator confirms a plan.
# Never blocks (PostToolUse always exit 0).
#
# Discrimination logic:
#   1. Question text contains "plan" (word boundary)
#   2. Question or option labels contain confirmation language
#   3. Operator's answer is affirmative
# All three must match for the state file to be written.
#
# Edge cases:
#   - Non-plan AskUserQuestion calls (e.g., "Which library?") → no match, exit 0
#   - Plan questions with negative answers (e.g., "No, revise") → no match, exit 0
#   - Conversational plan approval (without AskUserQuestion) → hook never fires;
#     branch-guard blocks Edit/Write until a proper AskUserQuestion approval occurs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_analytics-helper.sh"
source "$SCRIPT_DIR/_phase-helper.sh"
START_MS=$(now_ms)

# --- Read PostToolUse payload ---
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Only process AskUserQuestion
if [ "$TOOL_NAME" != "AskUserQuestion" ]; then
  exit 0
fi

# --- Extract question text ---
QUESTIONS_TEXT=$(echo "$INPUT" | jq -r '[.tool_input.questions[]?.question // empty] | join(" ")' 2>/dev/null)

# --- Universal AskUserQuestion tracking (item 14) ---
# Emit event for every AskUserQuestion call, regardless of plan relevance.
# Truncate question text to 64 chars for detail field (no PII risk for governance questions).
QUESTION_PREVIEW=$(printf '%.64s' "$QUESTIONS_TEXT")
log_hook_event "plan-approval" "PostToolUse" "AskUserQuestion" "allow" "$START_MS" "ask_user_question" "$QUESTION_PREVIEW"

# Gate 1: Question must mention "plan" — non-plan questions exit after universal event
if ! echo "$QUESTIONS_TEXT" | grep -iqE '\bplan\b'; then
  exit 0
fi

# Gate 2: Question or options must contain confirmation/approval language
OPTION_LABELS=$(echo "$INPUT" | jq -r '[.tool_input.questions[]?.options[]?.label // empty] | join(" ")' 2>/dev/null)
IS_CONFIRMATION=false

if echo "$QUESTIONS_TEXT" | grep -iqE '\b(approv|confirm|proceed|accept|ready)\b'; then
  IS_CONFIRMATION=true
elif echo "$OPTION_LABELS" | grep -iqE '\b(yes|approv|confirm|proceed|accept)\b'; then
  IS_CONFIRMATION=true
fi

if [ "$IS_CONFIRMATION" = false ]; then
  exit 0
fi

# --- Check if answer is affirmative ---
# PostToolUse provides answers in tool_response.answers (object: question->answer)
# Fallback to tool_output for CLI compatibility
TOOL_OUTPUT=$(echo "$INPUT" | jq -r '(.tool_response.answers // {}) | to_entries[].value' 2>/dev/null || true)
if [ -z "$TOOL_OUTPUT" ]; then
  TOOL_OUTPUT=$(echo "$INPUT" | jq -r '.tool_output // empty' 2>/dev/null)
fi
APPROVED=false

if echo "$TOOL_OUTPUT" | grep -iqE '\b(yes|approve[d]?|confirm(ed)?|proceed|go ahead|looks good|lgtm|accept(ed)?)\b'; then
  APPROVED=true
fi

if [ "$APPROVED" = false ]; then
  log_hook_event "plan-approval" "PostToolUse" "AskUserQuestion" "skip" "$START_MS" "not_approved"
  exit 0
fi

# --- Check for large-scope indicator ---
LARGE_SCOPE=false
if echo "$QUESTIONS_TEXT $TOOL_OUTPUT" | grep -iqE '\blarge[ -]?scope\b'; then
  LARGE_SCOPE=true
fi

# --- Detect auto/review mode from operator answer ---
# Scan only the operator's selected answer ($TOOL_OUTPUT) for mode keywords.
# $OPTION_LABELS always contains both "Auto" and "Review" labels, so scanning
# them would match both every time. Conservative default: review (Decision 0014).
DETECTED_MODE="review"
if echo "$TOOL_OUTPUT" | grep -iqE '\bauto\b'; then
  DETECTED_MODE="auto"
elif echo "$TOOL_OUTPUT" | grep -iqE '\breview\b'; then
  DETECTED_MODE="review"
fi

# --- Write plan-approved state file ---
REPO_ROOT="$(get_repo_root)"
STATE_DIR="$REPO_ROOT/.claude/.state"
mkdir -p "$STATE_DIR" 2>/dev/null || true

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
QUESTION_HASH=$(printf '%s' "$QUESTIONS_TEXT" | portable_hash | cut -c1-12)

{
  printf 'timestamp: %s\n' "$TIMESTAMP"
  printf 'question_hash: %s\n' "$QUESTION_HASH"
  printf 'large-scope: %s\n' "$LARGE_SCOPE"
  printf 'mode: %s\n' "$DETECTED_MODE"
} > "$STATE_DIR/plan-approved" 2>/dev/null || true

# --- Phase: set mode and advance through approval → next phase ---
# If phase-state active, set mode then advance through approval to the
# post-approval phase (queried dynamically from the phase sequence).
# standard/taskgroup/hotfix → build. spec-fresh/spec-update → governance.
# Fail-silent if no phase-state or if session type lacks these phases.
CURRENT_PHASE=$(get_phase)
SESSION_TYPE=$(get_session_type)
if [ -n "$CURRENT_PHASE" ]; then
  set_phase_mode "$DETECTED_MODE" 2>/dev/null || true
  # Audit 2.3: log errors instead of swallowing (fail-silent double advance)
  advance_phase "approval" 2>/dev/null || echo "WARNING: plan-approval — failed to advance to approval phase" >&2
  NEXT_PHASE=$(get_post_approval_phase "$SESSION_TYPE")
  if [ -n "$NEXT_PHASE" ]; then
    advance_phase "$NEXT_PHASE" 2>/dev/null || echo "WARNING: plan-approval — failed to advance to $NEXT_PHASE phase" >&2
  fi
fi

# --- Automation runner activation (taskgroup + auto mode) ---
# When auto mode is selected on a taskgroup session, queue remaining
# pending briefs from the contract and activate the runner daemon.
# Runs in background subshell to keep PostToolUse non-blocking.
# Decision 0017 — Operator Automation Layer.
if [ "$DETECTED_MODE" = "auto" ] && [ "$SESSION_TYPE" = "taskgroup" ]; then
  if [ -f "$REPO_ROOT/.claude/.automation/config.yaml" ]; then
    (
      source "$SCRIPT_DIR/_automation-bridge.sh" 2>/dev/null || exit 0
      automation_activate_taskgroup 2>/dev/null || true
    ) &
  fi
fi

log_hook_event "plan-approval" "PostToolUse" "AskUserQuestion" "write" "$START_MS" "plan_approved" "mode:$DETECTED_MODE"
exit 0
