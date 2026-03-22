#!/usr/bin/env bash
# JSON payload generators for Claude Code hook stdin protocol.
# Each function outputs a JSON string to stdout matching the exact schema
# that the target hook parses with jq.
#
# Usage:
#   source "$(dirname "$0")/test-fixtures.sh"
#   fixture_pretooluse_edit "/repo/src/foo.ts" | bash "$HOOKS_DIR/write-guard.sh"
#
# Fragility note: These fixtures are reverse-engineered from each hook's jq
# expressions. If Claude Code changes the hook stdin protocol, fixtures will
# break silently. Each fixture documents which hook fields it satisfies.
#
# Bash 3.2 compatible. Requires: printf (no jq dependency).

# --- Escape a string for safe JSON interpolation ---
# Handles backslash and double-quote. Does NOT handle newlines in values
# (use fixture_subagentstop's multiline handling for that).
_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# --- PreToolUse: Edit ---
# Consumers: write-guard.sh
# Fields parsed:
#   .tool_input.file_path  (write-guard Section 3 path exemptions)
#   .tool_input.file_path  (write-guard .state/ detection + mode path classification)
fixture_pretooluse_edit() {
  local file_path="$1"
  local fp
  fp=$(_json_escape "$file_path")
  printf '{"tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"old","new_string":"new"}}' "$fp"
}

# --- PreToolUse: Write ---
# Consumers: write-guard.sh
# Same field set as Edit.
fixture_pretooluse_write() {
  local file_path="$1"
  local fp
  fp=$(_json_escape "$file_path")
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":"test content"}}' "$fp"
}

# --- PreToolUse: Bash ---
# Consumers: bash-guard.sh, write-guard.sh
# Fields parsed:
#   .tool_input.command    (bash-guard write-target extraction)
#   .tool_input.command    (write-guard write-target detection)
#   .tool_input.file_path  (absent — distinguishes Bash from Edit/Write)
fixture_pretooluse_bash() {
  local command="$1"
  local cmd
  cmd=$(_json_escape "$command")
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$cmd"
}

# --- PreToolUse: Bash (git commit) ---
# Consumer: pre-commit-gates.sh
# Fields parsed:
#   .tool_input.command    (commit message extraction for trailer checks)
fixture_pretooluse_commit() {
  local msg="${1:-test commit}"
  local cmd
  cmd=$(_json_escape "git commit -m \"$msg\"")
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$cmd"
}

# --- PostToolUse: AskUserQuestion ---
# Consumer: plan-approval.sh
# Fields parsed:
#   .tool_name                                          (must be "AskUserQuestion")
#   .tool_input.questions[].question                    (plan keyword detection)
#   .tool_input.questions[].options[].label              (confirmation language)
#   .tool_input.answers | to_entries[].value             (primary: affirmative detection)
#   .tool_response.answers | to_entries[].value          (legacy fallback)
#   .tool_output                                         (CLI fallback)
fixture_posttooluse_ask() {
  local question="$1"
  local option_labels_csv="$2"   # comma-separated: "Yes approve,No revise"
  local answer="$3"

  local q
  q=$(_json_escape "$question")
  local a
  a=$(_json_escape "$answer")

  # Build options array from CSV
  local options_json=""
  local IFS_OLD="$IFS"
  IFS=','
  local first=true
  for label in $option_labels_csv; do
    # Trim leading/trailing whitespace
    label=$(echo "$label" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    local l
    l=$(_json_escape "$label")
    if [ "$first" = true ]; then
      options_json="[{\"label\":\"$l\",\"description\":\"option\"}"
      first=false
    else
      options_json="$options_json,{\"label\":\"$l\",\"description\":\"option\"}"
    fi
  done
  IFS="$IFS_OLD"
  options_json="${options_json}]"

  printf '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"%s","options":%s}],"answers":{"%s":"%s"}},"tool_output":"%s"}' \
    "$q" "$options_json" "$q" "$a" "$a"
}

# --- SubagentStop ---
# Consumer: state-writer.sh
# Fields parsed:
#   .agent_type                  (governance agent routing)
#   .last_assistant_message      (GATE_RESULT sentinel extraction)
fixture_subagentstop() {
  local agent_type="$1"
  local last_message="$2"

  local at
  at=$(_json_escape "$agent_type")
  # For last_message, also escape newlines for JSON
  local lm
  lm=$(_json_escape "$last_message")
  lm="${lm//$'\n'/\\n}"

  printf '{"agent_type":"%s","last_assistant_message":"%s"}' "$at" "$lm"
}

# --- Stop ---
# Consumer: session-close-check.sh
# Hook reads stdin (INPUT=$(cat)) but does not parse it with jq.
fixture_stop() {
  printf '{}'
}

# --- HVST event (PostToolUse / PostToolUseFailure) ---
# Consumer: hvst-failure-tracker.sh
# Fields parsed:
#   .hook_event_name   (event routing: "PostToolUse" or "PostToolUseFailure")
fixture_hvst_event() {
  local event_name="$1"  # "PostToolUse" or "PostToolUseFailure"
  local en
  en=$(_json_escape "$event_name")
  printf '{"hook_event_name":"%s","tool_name":"Bash","tool_input":{"command":"npm test"}}' "$en"
}

# --- Self-test ---
# Validates that fixtures produce valid JSON (requires jq).
_fixtures_self_test() {
  if ! command -v jq &>/dev/null; then
    echo "# Fixture self-test skipped (jq not available)"
    return 0
  fi

  local failures=0

  # Test each fixture produces valid JSON
  local json

  json=$(fixture_pretooluse_edit "/repo/src/foo.ts")
  echo "$json" | jq -e '.tool_input.file_path == "/repo/src/foo.ts"' >/dev/null 2>&1 || { echo "FAIL: fixture_pretooluse_edit"; failures=$((failures + 1)); }

  json=$(fixture_pretooluse_write "/repo/src/bar.ts")
  echo "$json" | jq -e '.tool_input.file_path == "/repo/src/bar.ts"' >/dev/null 2>&1 || { echo "FAIL: fixture_pretooluse_write"; failures=$((failures + 1)); }

  json=$(fixture_pretooluse_bash "echo hello > /repo/out.txt")
  echo "$json" | jq -e '.tool_input.command' >/dev/null 2>&1 || { echo "FAIL: fixture_pretooluse_bash"; failures=$((failures + 1)); }

  json=$(fixture_pretooluse_commit "test message")
  echo "$json" | jq -e '.tool_input.command | startswith("git commit")' >/dev/null 2>&1 || { echo "FAIL: fixture_pretooluse_commit"; failures=$((failures + 1)); }

  json=$(fixture_posttooluse_ask "Do you approve this plan?" "Yes approve,No revise" "Yes approve")
  echo "$json" | jq -e '.tool_name == "AskUserQuestion"' >/dev/null 2>&1 || { echo "FAIL: fixture_posttooluse_ask tool_name"; failures=$((failures + 1)); }
  echo "$json" | jq -e '.tool_input.questions[0].question | contains("plan")' >/dev/null 2>&1 || { echo "FAIL: fixture_posttooluse_ask question"; failures=$((failures + 1)); }
  echo "$json" | jq -e '(.tool_input.answers // {}) | to_entries[0].value == "Yes approve"' >/dev/null 2>&1 || { echo "FAIL: fixture_posttooluse_ask answers in tool_input"; failures=$((failures + 1)); }

  json=$(fixture_subagentstop "critic" "Review complete.\nGATE_RESULT: APPROVED")
  echo "$json" | jq -e '.agent_type == "critic"' >/dev/null 2>&1 || { echo "FAIL: fixture_subagentstop"; failures=$((failures + 1)); }

  json=$(fixture_stop)
  echo "$json" | jq -e '.' >/dev/null 2>&1 || { echo "FAIL: fixture_stop"; failures=$((failures + 1)); }

  json=$(fixture_hvst_event "PostToolUseFailure")
  echo "$json" | jq -e '.hook_event_name == "PostToolUseFailure"' >/dev/null 2>&1 || { echo "FAIL: fixture_hvst_event"; failures=$((failures + 1)); }

  if [ "$failures" -eq 0 ]; then
    echo "# Fixture self-test: all fixtures produce valid JSON"
  else
    echo "# Fixture self-test: $failures failure(s)"
    return 1
  fi
}