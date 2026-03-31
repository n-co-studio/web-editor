#!/usr/bin/env bash
# Mode-guard helper — shared mode-guard policy functions.
# Sourced (not standalone). Must not be executed directly.
#
# Consumers: write-guard.sh, bash-guard.sh
#
# Dependency: normalize_path() from _analytics-helper.sh must be available
# in the sourcing script's scope. Both consumers already source
# _analytics-helper.sh before this file — do NOT re-source it here.
#
# Functions provided:
#   make_relative  — normalize path relative to repo root
#   is_immune      — check if path is never-modifiable (no override)
#   is_governance  — check if path falls under governance prefixes
#   is_carved_out  — check per-mode governance carve-outs

# Guard against direct execution
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "Error: _mode-guard-helper.sh must be sourced, not executed directly." >&2
  exit 1
fi

# --- Path helpers (normalize_path, resolve_path sourced from _analytics-helper.sh) ---
# Make path relative to repo root for prefix matching
make_relative() {
  local p="$1"
  p=$(normalize_path "$p")
  # Strip repo root prefix if present
  p="${p#$REPO_ROOT/}"
  # Strip leading ./ if present
  p="${p#./}"
  echo "$p"
}

# --- Immune paths (never modifiable, no override) ---
is_immune() {
  local p="$1"
  case "$p" in
    .claude/hooks/write-guard.sh) return 0 ;;
    .claude/repo-mode) return 0 ;;
    .claude/.session-id) return 0 ;;
    *) return 1 ;;
  esac
}

# --- Governance prefix check ---
is_governance() {
  local p="$1"
  case "$p" in
    .claude/*) return 0 ;;
    docs/ai/*) return 0 ;;
    docs/spec/_templates/*) return 0 ;;
    .github/*) return 0 ;;
    AI.md) return 0 ;;
    CLAUDE.md) return 0 ;;
    .gitignore) return 0 ;;
    repo-os-explainer.html) return 0 ;;
    *) return 1 ;;
  esac
}

# --- Per-mode carve-outs (governance paths allowed in each mode) ---
is_carved_out() {
  local mode="$1"
  local p="$2"

  case "$mode" in
    template)
      case "$p" in
        .claude/agents/*) return 0 ;;
        .claude/hooks/*) return 0 ;;
        .claude/tools/*) return 0 ;;
        .claude/settings.json) return 0 ;;
        .claude/settings.local.json) return 0 ;;
        .claude/local/session-log.md) return 0 ;;
        .claude/local/known-issues.md) return 0 ;;
        .claude/local/task-groups/*) return 0 ;;
        .claude/local/task-contract.yaml) return 0 ;;
        .gitignore) return 0 ;;
        docs/ai/prompts/*) return 0 ;;
        docs/ai/decisions/*) return 0 ;;
        docs/ai/logs/*) return 0 ;;
        docs/ai/workflow.md) return 0 ;;
        docs/ai/quality-gates.md|docs/ai/hook-rules-summary.md|docs/ai/quality-gates-summary.md|docs/ai/workflow-summary.md) return 0 ;;
        docs/ai/workflow-appendix/*) return 0 ;;
        docs/ai/governance/*) return 0 ;;
        docs/ai/knowledge-graph/*) return 0 ;;
        docs/ai/task-groups/_contract-template.yaml) return 0 ;;
        docs/spec/_templates/*) return 0 ;;
        AI.md) return 0 ;;
        CLAUDE.md) return 0 ;;
        repo-os-explainer.html) return 0 ;;
        .github/*) return 0 ;;
        .claude/.automation/*) return 0 ;;
         *) return 1 ;;
      esac
      ;;
    child)
      case "$p" in
        .claude/settings.local.json) return 0 ;;
        docs/ai/governance/*) return 0 ;;
        docs/ai/logs/*) return 0 ;;
        docs/ai/task-groups/_*) return 1 ;;
        docs/ai/task-groups/*.yaml) return 0 ;;
        docs/ai/decisions/t-*.md) return 1 ;;  # template decisions — blocked in child mode (Decision 0022)
        docs/ai/decisions/0[1-9][0-9][0-9]-*.md) return 0 ;;  # child decisions (0100+) — allowed
        docs/spec/compiled/*) return 0 ;;
        docs/spec/prototypes/*) return 0 ;;
        .claude/.automation/*) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    autonomous)
      case "$p" in
        docs/ai/logs/*) return 0 ;;
        docs/ai/task-groups/_*) return 1 ;;
        docs/ai/task-groups/*.yaml) return 0 ;;
        *) return 1 ;;
      esac
      ;;
  esac
  return 1
}
