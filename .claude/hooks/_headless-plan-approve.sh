#!/usr/bin/env bash
# Headless plan-approve helper — writes plan-approved state file for headless/automation sessions.
# Called via `source .claude/hooks/_headless-plan-approve.sh` in headless context.
# Requires _analytics-helper.sh and _phase-helper.sh to be sourced first.
#
# This exists because:
#   1. AskUserQuestion is blocked in headless mode (ask-user-deny.sh)
#   2. plan-approval.sh fires on AskUserQuestion PostToolUse (can't fire without it)
#   3. State files are write-protected from tool-level Bash (bash-guard blocks > to .state/)
#   4. Shell I/O from sourced functions bypasses bash-guard (established pattern per Decision 0014 §9)
#
# Usage: source this file after sourcing _analytics-helper.sh and _phase-helper.sh.
#        It writes plan-approved immediately and advances through approval to build.

_headless_plan_approve() {
  local state_dir
  state_dir="$(get_session_state_dir)"
  local sid
  sid="$(get_session_id "$_REPO_OS_ROOT")"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  mkdir -p "$state_dir" 2>/dev/null || true

  printf 'timestamp: %s\nquestion_hash: headless-runner\nlarge-scope: true\nmode: auto\nsession_id: %s\n' \
    "$ts" "$sid" > "$state_dir/plan-approved"
  refresh_manifest_entry "plan-approved" 2>/dev/null || true

  # Advance through approval to build
  advance_phase "approval" 2>/dev/null || true
  advance_phase "build" 2>/dev/null || true
}

_headless_plan_approve
