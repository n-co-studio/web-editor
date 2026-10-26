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
#   make_relative     — normalize path relative to repo root
#   is_out_of_repo    — returns 0 if path is definitively outside REPO_ROOT
#   has_unresolved_var — returns 0 if path contains a literal '$' (unresolved variable)
#   is_immune         — check if path is never-modifiable (no override)
#   is_governance     — check if path falls under governance prefixes
#   is_carved_out     — check per-mode governance carve-outs

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

# --- Out-of-repo predicate ---
# Returns 0 (true — outside) if the path is definitively outside REPO_ROOT.
# Returns 1 (false — inside or undecidable) otherwise.
#
# Handles:
#   • Absolute paths: checked against REPO_ROOT prefix (lexical, no symlink
#     resolution — consistent with normalize_path/is_in_repo in _analytics-helper.sh).
#   • Relative paths with ../ traversal: resolved against REPO_ROOT lexically,
#     then checked. Uses normalize_path (python3-backed when .. present).
#   • Clean relative paths: assumed in-repo by convention.
#
# Do NOT call with paths containing unresolved shell variables ($VAR / ${VAR}).
# Call has_unresolved_var() first; bail if it returns 0.
is_out_of_repo() {
  local p="$1"
  local abs_p
  if [[ "$p" == /* ]]; then
    # Absolute path — compare directly against REPO_ROOT
    abs_p="$p"
  elif [[ "$p" == *".."* ]]; then
    # Relative with traversal — resolve against REPO_ROOT lexically
    abs_p=$(normalize_path "$REPO_ROOT/$p") || abs_p="$REPO_ROOT/$p"
  else
    # Clean relative path — treat as in-repo
    return 1
  fi
  # is_in_repo returns 0 (in repo) → NOT out; 1 (outside) → IS out
  is_in_repo "$abs_p" "$REPO_ROOT" && return 1 || return 0
}

# --- Unresolved shell variable predicate ---
# Returns 0 (true) if the path string contains a literal '$', indicating an
# unresolved shell variable reference ($VAR or ${VAR}).
# The mode guard cannot classify such targets and must block fail-closed.
has_unresolved_var() {
  [[ "$1" == *'$'* ]]
}

# --- Immune paths (never modifiable, no override) ---
# Settings files are structural enforcement anchors: if either can be
# modified by an agent, the hook chain can be dismantled via env var overrides.
# Immune in ALL modes — REPO_OS_UNLOCK_PATH does not apply.
is_immune() {
  local p="$1"
  case "$p" in
    .claude/hooks/write-guard.sh) return 0 ;;
    .claude/repo-mode) return 0 ;;
    .claude/.session-id) return 0 ;;
    .claude/settings.json) return 0 ;;
    .claude/settings.local.json) return 0 ;;
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
    .templatesyncignore) return 0 ;;
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
        # .claude/settings.json and .claude/settings.local.json are immune — not reachable here
        .claude/local/sessions/*) return 0 ;;
        .claude/local/known-issues.md) return 0 ;;
        .claude/local/task-groups/*) return 0 ;;
        .claude/local/task-contract.yaml) return 0 ;;
        # Handoff bundle paths (Decision t-0043: per-brief; legacy deprecated fallback).
        # Scoped to the dedicated handoff-bundles/ directory (the * matches the
        # per-brief <brief_id>.yaml files, same directory-scoped pattern as the
        # sessions/* and task-groups/* carve-outs above) plus the single legacy
        # fixed path — not a broad .claude/local/* opening (Decision 0012 discipline).
        .claude/local/handoff-bundles/*) return 0 ;;
        .claude/local/handoff-bundle.yaml) return 0 ;;
        .gitignore) return 0 ;;
        docs/ai/prompts/*) return 0 ;;
        docs/ai/decisions/*) return 0 ;;
        docs/ai/eval/*) return 0 ;;
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
        .templatesyncignore) return 0 ;;
        .github/*) return 0 ;;
        .claude/.automation/*) return 0 ;;
         *) return 1 ;;
      esac
      ;;
    child)
      case "$p" in
        docs/ai/eval/*) return 0 ;;
        docs/ai/governance/*) return 0 ;;
        docs/ai/logs/*) return 0 ;;
        docs/ai/task-groups/_*) return 1 ;;
        docs/ai/task-groups/*.yaml) return 0 ;;
        docs/ai/decisions/t-*.md) return 1 ;;  # template decisions — blocked in child mode (Decision 0022)
        docs/ai/decisions/0[1-9][0-9][0-9]-*.md) return 0 ;;  # child decisions (0100+) — allowed
        docs/spec/compiled/*) return 0 ;;
        docs/spec/prototypes/*) return 0 ;;
        # Narrowed from .automation/* — only reports/ is writable in child mode.
        # Dev Orchestrator writes health reports here via Bash redirect (Decision t-0017 §10, t-0012 §3).
        # config.yaml, schemas/, queue/, decision-cache/, lib/ remain template-only.
        .claude/.automation/reports/*) return 0 ;;
        # product-graph.yaml is child-owned — child Prompt B sessions must write it at close
        # to fulfil the Decision t-0034 Amendment 3 REQUIRE-attempt obligation. coverage.yaml
        # is child-owned too: it declares what product-graph.yaml must cover, and the commit
        # gate reads it (Amendment 9). The rest of knowledge-graph/ (schema.yaml, README.md)
        # stays template-owned; the template graph itself was retired in Amendment 9.
        docs/ai/knowledge-graph/product-graph.yaml) return 0 ;;
        docs/ai/knowledge-graph/coverage.yaml) return 0 ;;
        .claude/agents/custom/*) return 0 ;;  # custom agent namespace — operator-writable in child mode
        *) return 1 ;;
      esac
      ;;
    autonomous)
      case "$p" in
        docs/ai/eval/*) return 0 ;;
        docs/ai/logs/*) return 0 ;;
        docs/ai/task-groups/_*) return 1 ;;
        docs/ai/task-groups/*.yaml) return 0 ;;
        *) return 1 ;;
      esac
      ;;
  esac
  return 1
}
