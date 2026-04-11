#!/usr/bin/env bash
# Cross-session context assembler — sourced by _phase-helper.sh at build phase entry.
# Provides _assemble_cross_session_context() which combines recent git log and
# the last session log tail into a structured context block for build agents.
# Decision 0014: injected at phase transition (build entry).
# Decision 0034: follows same injection pattern as _inject_kg_context().
#
# Usage (from _phase-helper.sh _inject_cross_session_context()):
#   source "$SCRIPT_DIR/_cross-session-context.sh"
#   context=$(_assemble_cross_session_context)
#
# ## Consumers (auto-generated — run .claude/tools/hook-dep-map.sh for live data)
#   Hooks: _phase-helper.sh

# Token budget: ~1,500 tokens ≈ 6,000 characters.
# Prioritizes git log (more recent = more relevant) over session log tail.
# Conditional initialization: preserve any overrides set before sourcing.
: "${_CROSS_SESSION_BUDGET_CHARS:=6000}"
: "${_CROSS_SESSION_GIT_LOG_LINES:=20}"
: "${_CROSS_SESSION_SESSION_TAIL_LINES:=30}"

# --- Assemble cross-session context block ---
# Combines:
#   1. Recent git log (commits on this branch, up to _CROSS_SESSION_GIT_LOG_LINES lines)
#   2. Last session log tail (last _CROSS_SESSION_SESSION_TAIL_LINES lines)
# Output is truncated to _CROSS_SESSION_BUDGET_CHARS characters.
# Returns 0 always — advisory only, failures silently produce empty output.
_assemble_cross_session_context() {
  local repo_root="${_REPO_OS_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
  [ -z "$repo_root" ] && return 0

  # --- Part 1: Recent git log on this branch ---
  local git_log_output=""
  git_log_output=$(
    git -C "$repo_root" log --oneline -${_CROSS_SESSION_GIT_LOG_LINES} \
      origin/main..HEAD 2>/dev/null \
    || git -C "$repo_root" log --oneline -${_CROSS_SESSION_GIT_LOG_LINES} \
      HEAD~${_CROSS_SESSION_GIT_LOG_LINES}..HEAD 2>/dev/null \
    || true
  )
  if [ -z "$git_log_output" ]; then
    git_log_output="No recent commits on this branch"
  fi

  # --- Part 2: Last session log tail ---
  local session_log_tail=""
  local last_log=""

  # Product mode: docs/ai/logs/sessions/session-*.md (worktrees and child repos)
  # Template mode: .claude/local/sessions/session-*.md (gitignored, local only)
  # Check product mode first (worktrees default to child/product mode), then template.
  local product_logs="$repo_root/docs/ai/logs/sessions"
  local template_logs="$repo_root/.claude/local/sessions"

  if [ -d "$product_logs" ]; then
    last_log=$(ls -t "$product_logs"/session-*.md 2>/dev/null | head -1 || true)
  fi
  if [ -z "$last_log" ] && [ -d "$template_logs" ]; then
    last_log=$(ls -t "$template_logs"/session-*.md 2>/dev/null | head -1 || true)
  fi

  if [ -n "$last_log" ] && [ -f "$last_log" ]; then
    session_log_tail=$(tail -n ${_CROSS_SESSION_SESSION_TAIL_LINES} "$last_log" 2>/dev/null || true)
    local log_basename
    log_basename=$(basename "$last_log")
    session_log_tail="[${log_basename}]
${session_log_tail}"
  else
    session_log_tail="No session logs found"
  fi

  # --- Assemble structured block ---
  local block
  block="=== CROSS-SESSION CONTEXT (recent activity — verify before assuming) ===
## Recent Commits (this branch)
${git_log_output}
## Last Session Summary
${session_log_tail}
=== END CROSS-SESSION CONTEXT ==="

  # --- Enforce token budget (prioritize git log over session tail) ---
  local block_len="${#block}"
  if [ "$block_len" -gt "$_CROSS_SESSION_BUDGET_CHARS" ]; then
    # Rebuild with truncated session tail to fit budget.
    # Git log section is preserved; session tail is truncated at budget boundary.
    local header="=== CROSS-SESSION CONTEXT (recent activity — verify before assuming) ===
## Recent Commits (this branch)
${git_log_output}
## Last Session Summary
"
    local footer="
[... truncated to stay within token budget ...]
=== END CROSS-SESSION CONTEXT ==="
    local header_len="${#header}"
    local footer_len="${#footer}"
    local tail_budget=$(( _CROSS_SESSION_BUDGET_CHARS - header_len - footer_len ))
    if [ "$tail_budget" -gt 0 ]; then
      local truncated_tail="${session_log_tail:0:$tail_budget}"
      block="${header}${truncated_tail}${footer}"
    else
      # Git log alone exceeds budget — truncate the whole block
      block="${block:0:$_CROSS_SESSION_BUDGET_CHARS}
[... truncated to stay within token budget ...]"
    fi
  fi

  printf '%s\n' "$block"
}
