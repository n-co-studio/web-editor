#!/usr/bin/env bash
# Plan approval — captures operator plan approvals as state.
# Wired to PostToolUse on AskUserQuestion via .claude/settings.json.
# Writes .claude/.state/plan-approved when operator confirms a plan.
# Never blocks (PostToolUse always exit 0).
#
# Discrimination logic:
#   1. Question text contains "plan", "brief", or "task" (word boundary)
#   2. Question or option labels contain confirmation language
#   3. Operator's answer is affirmative
# All three must match for the state file to be written.
#
# Edge cases:
#   - Non-plan AskUserQuestion calls (e.g., "Which library?") → no match, exit 0
#   - Plan questions with negative answers (e.g., "No, revise") → no match, exit 0
#   - Conversational plan approval (without AskUserQuestion) → hook never fires;
#     bash-guard/write-guard block Edit/Write until a proper AskUserQuestion approval occurs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_analytics-helper.sh"
source "$SCRIPT_DIR/_phase-helper.sh"
START_MS=$(now_ms)

# --- Read PostToolUse payload ---
INPUT=$(cat)

# --- Harness session_id plumbing (must precede first get_session_id call) ---
export _REPO_OS_STDIN_SID
_REPO_OS_STDIN_SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"

# --- Debug logging (R13 investigation) ---
# When REPO_OS_DEBUG=1, dump full payload to /tmp for diagnosing
# VS Code extension hook dispatch timing issues.
if [ "${REPO_OS_DEBUG:-0}" = "1" ]; then
  echo "$INPUT" > /tmp/plan-approval-debug.json 2>/dev/null || true
fi

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

# Gate 2: Question or options contain confirmation/approval language.
# Computed before Gate 1 so we can warn when Gate 2 passes but Gate 1 does not
# (Decision t-0058). A question with approval language but no plan/brief/task
# keyword is almost certainly a plan approval phrased differently; the operator
# is entitled to know the approval was not recorded.
OPTION_LABELS=$(echo "$INPUT" | jq -r '[.tool_input.questions[]?.options[]?.label // empty] | join(" ")' 2>/dev/null)
IS_CONFIRMATION=false

if echo "$QUESTIONS_TEXT" | grep -iqE '\b(approv[a-z]*|confirm|proceed|accept|ready)\b'; then
  IS_CONFIRMATION=true
elif echo "$OPTION_LABELS" | grep -iqE '\b(yes|approv[a-z]*|confirm|proceed|accept)\b'; then
  IS_CONFIRMATION=true
fi

# Gate 1: Question must mention "plan", "brief", or "task" — non-approval questions exit after universal event.
# If Gate 2 already passed (approval language present), warn before exiting: the
# operator phrased a genuine plan approval without a plan/brief/task keyword.
if ! echo "$QUESTIONS_TEXT" | grep -iqE '\b(plan|brief|task)\b'; then
  if [ "$IS_CONFIRMATION" = true ]; then
    echo "WARNING: plan-approval — question contains approval language but no plan/brief/task keyword. Approval NOT recorded. Add 'plan', 'brief', or 'task' to the question to register the approval." >&2
    log_hook_event "plan-approval" "PostToolUse" "AskUserQuestion" "skip" "$START_MS" "not_approved" "gate1_miss_with_approval_language"
  fi
  exit 0
fi

if [ "$IS_CONFIRMATION" = false ]; then
  exit 0
fi

# --- Check if answer is affirmative ---
# AskUserQuestion schema: answers are in tool_input.answers (object: question->answer),
# populated by the permission component. Fallback chain for compatibility:
#   1. tool_input.answers (primary — matches AskUserQuestion tool schema)
#   2. tool_response.answers (legacy — kept for backward compatibility)
#   3. tool_output (CLI fallback)
#
# The canonical plan-approval template (Prompt B, orchestrator.md) offers the
# options "Auto" and "Review" — BOTH are approvals (the operator chooses how to
# proceed, not whether). So "auto"/"review" answers count as affirmative here.
# This is safe: Gates 1+2 above have already scoped this to a plan-confirmation
# question, so a bare "Auto"/"Review" answer in this context can only mean
# approval. The DETECTED_MODE block below distinguishes which mode was chosen.
TOOL_OUTPUT=$(echo "$INPUT" | jq -r '(.tool_input.answers // {}) | to_entries[].value' 2>/dev/null || true)
if [ -z "$TOOL_OUTPUT" ]; then
  TOOL_OUTPUT=$(echo "$INPUT" | jq -r '(.tool_response.answers // {}) | to_entries[].value' 2>/dev/null || true)
fi
if [ -z "$TOOL_OUTPUT" ]; then
  TOOL_OUTPUT=$(echo "$INPUT" | jq -r '.tool_output // empty' 2>/dev/null)
fi
if [ -z "$TOOL_OUTPUT" ]; then
  echo "WARNING: plan-approval — could not extract answer from AskUserQuestion payload" >&2
fi
APPROVED=false

if echo "$TOOL_OUTPUT" | grep -iqE '\b(yes|approv[a-z]*|confirm(ed)?|proceed|go ahead|looks good|lgtm|accept(ed)?|auto|review)\b'; then
  APPROVED=true
fi

if [ "$APPROVED" = false ]; then
  # Gates 1 and 2 passed — this looks like a plan approval question — but the
  # selected answer contains no affirmative keyword. The operator is entitled to
  # know. The previous plan-approved marker (if any) remains on disk and looks
  # current; without this warning there is no trace except a not_approved line
  # in the hook event log. The hook still exits 0: PostToolUse must never block.
  echo "WARNING: plan-approval — plan question answered but approval NOT recorded. Answer '$TOOL_OUTPUT' contains no affirmative keyword (yes, approve, confirm, proceed, accept, auto, review). Re-approve with an affirmative option to register the plan." >&2
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
SID=$(get_session_id "$REPO_ROOT")
STATE_DIR="$(get_session_state_dir)"
mkdir -p "$STATE_DIR" 2>/dev/null || true

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
QUESTION_HASH=$(printf '%s' "$QUESTIONS_TEXT" | portable_hash | cut -c1-12)

{
  printf 'timestamp: %s\n' "$TIMESTAMP"
  printf 'question_hash: %s\n' "$QUESTION_HASH"
  printf 'large-scope: %s\n' "$LARGE_SCOPE"
  printf 'mode: %s\n' "$DETECTED_MODE"
  printf 'session_id: %s\n' "$SID"
  # Staleness hint: compare timestamp above against the phase-state mtime to
  # detect an approval that predates a plan revision. A new plan generates a
  # different question_hash; if the hash here no longer matches the current plan
  # question, this marker covers a different plan. pre-commit-gates.sh checks
  # the hash via session-resume.yaml.plan_hash when a resume marker exists.
  printf 'stale_check: compare timestamp with phase-state mtime; question_hash identifies the plan text\n'
} > "$STATE_DIR/plan-approved" 2>/dev/null || true
refresh_manifest_entry "plan-approved" 2>/dev/null || true

# Store plan hash in resume marker for content-addressed comparison at commit time.
# At commit, pre-commit-gates.sh compares plan-approved.question_hash against
# session-resume.yaml.plan_hash to verify the approval matches the current plan.
# Backward compat: sessions without a resume marker skip this check (presence-only).
record_agent_verdict "plan_hash" "$QUESTION_HASH" 2>/dev/null || true

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
      source "$SCRIPT_DIR/_automation-bridge.sh" 2>/dev/null || { echo "WARNING: _automation-bridge.sh failed to load — automation features disabled" >&2; exit 0; }
      automation_activate_taskgroup 2>/dev/null || true
    ) &
  fi
fi

log_hook_event "plan-approval" "PostToolUse" "AskUserQuestion" "write" "$START_MS" "plan_approved" "mode:$DETECTED_MODE"
exit 0
