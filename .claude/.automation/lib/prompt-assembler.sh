#!/usr/bin/env bash
# Prompt assembler — lazy prompt generation at dequeue time.
# Sourced by runner.sh. NOT executed standalone.
# Decision 0017 — prompt assembled at dequeue, not creation.
#
# Two assembly modes:
#   1. Template-based: reads .automation/templates/<type>-brief.md, performs
#      placeholder substitution. Used for standard, hotfix, taskgroup.
#   2. Inline fallback: builds prompt from governance context for session
#      types without templates (experiment, spec-*, audit, etc.).
#
# Reads current governance context (AI.md, spec manifest, decisions)
# and composes a prompt for claude -p. Always reads fresh files at
# dequeue time so specs/governance changes are reflected.
#
# Depends on (sourced by runner.sh before this file):
#   runner.sh sets REPO_ROOT, AUTOMATION_DIR
#   _phase-helper.sh — get_phases_for_type
#   queue-manager.sh — _load_queue_entry, _QE_*, _write_queue_entry

set -euo pipefail

# --- Template lookup for session type ---
# Returns path to template file if one exists for the session type.
# Returns empty string for types without templates (fallback to inline).
_get_template_for_type() {
  local stype="$1"
  local template_dir="${AUTOMATION_DIR:-$REPO_ROOT/.claude/.automation}/templates"
  local template_file=""
  case "$stype" in
    standard|hotfix)
      template_file="$template_dir/build-brief.md"
      ;;
    taskgroup)
      template_file="$template_dir/taskgroup-brief.md"
      ;;
    audit)
      template_file="$template_dir/dev-orchestrator-brief.md"
      ;;
  esac
  if [ -n "$template_file" ] && [ -f "$template_file" ]; then
    printf '%s' "$template_file"
  fi
}

# --- Assemble prompt for a queue entry ---
# Reads the brief, governance context, and spec manifest.
# Outputs the assembled prompt to stdout.
# Also writes the prompt back to the queue entry file (atomic).
# Arguments:
#   $1 — entry_file_path (path to the running queue entry YAML)
# Output: assembled prompt on stdout
assemble_prompt() {
  local entry_file="$1"

  _load_queue_entry "$entry_file"

  local brief_content=""
  local brief_path="$_QE_BRIEF_PATH"
  local session_type="$_QE_SESSION_TYPE"

  # --- Read brief content ---
  if [ -n "$brief_path" ] && [ -f "$REPO_ROOT/$brief_path" ]; then
    brief_content=$(cat "$REPO_ROOT/$brief_path" 2>/dev/null || true)
  elif [ -n "$brief_path" ] && [ -f "$brief_path" ]; then
    brief_content=$(cat "$brief_path" 2>/dev/null || true)
  fi

  # --- Read AI.md (governance context) ---
  local ai_md=""
  if [ -f "$REPO_ROOT/AI.md" ]; then
    ai_md=$(cat "$REPO_ROOT/AI.md" 2>/dev/null || true)
  fi

  # --- Read spec manifest ---
  local spec_summary=""
  local manifest_file="$REPO_ROOT/docs/spec/compiled/manifest.json"
  if [ -f "$manifest_file" ]; then
    local active
    active=$(grep '"active"' "$manifest_file" 2>/dev/null \
      | sed 's/.*"active": *"//' | sed 's/".*//' | tr -d '[:space:]' | head -1)
    if [ -n "$active" ] && [ "$active" != "null" ]; then
      local spec_dir="$REPO_ROOT/docs/spec/compiled/$active"
      if [ -d "$spec_dir" ]; then
        spec_summary="Active spec version: $active"
        local spec_file
        for spec_file in "$spec_dir"/*.md; do
          [ -f "$spec_file" ] || continue
          spec_summary="${spec_summary}
- $(basename "$spec_file")"
        done
        # Include feature briefs if present
        if [ -d "$spec_dir/features" ]; then
          local feat_file
          for feat_file in "$spec_dir/features"/*.md; do
            [ -f "$feat_file" ] || continue
            spec_summary="${spec_summary}
- features/$(basename "$feat_file")"
          done
        fi
      fi
    else
      spec_summary="No active spec version (manifest.json active: null)."
    fi
  fi

  # --- Parse decision references from brief ---
  local decisions=""
  if [ -n "$brief_content" ]; then
    decisions=$(printf '%s' "$brief_content" \
      | grep -oE 'Decision [0-9]{4}' 2>/dev/null \
      | sort -u \
      | tr '\n' ', ' \
      | sed 's/, $//' || true)
  fi

  # --- Get phase sequence for session type ---
  local phases=""
  if [ -n "$session_type" ]; then
    phases=$(get_phases_for_type "$session_type" 2>/dev/null || true)
  fi

  # --- Build assembled prompt ---
  local prompt=""

  # --- Check for template-based assembly ---
  local template_file
  template_file=$(_get_template_for_type "$session_type")

  if [ -n "$template_file" ]; then
    # Template-based assembly: read template and substitute placeholders
    local template_content
    template_content=$(cat "$template_file")

    # Single-line placeholder substitutions (sed with | delimiter)
    template_content=$(printf '%s' "$template_content" | sed "s|{session_type}|${session_type}|g")
    template_content=$(printf '%s' "$template_content" | sed "s|{entry_id}|${_QE_ID}|g")
    template_content=$(printf '%s' "$template_content" | sed "s|{branch_name}|${_QE_BRANCH}|g")
    template_content=$(printf '%s' "$template_content" | sed "s|{auto_mode}|${_QE_AUTO_MODE:-false}|g")
    template_content=$(printf '%s' "$template_content" | sed "s|{solo_mode}|${_QE_SOLO_MODE:-false}|g")
    template_content=$(printf '%s' "$template_content" | sed "s|{decision_list}|${decisions}|g")

    # Task group placeholders (empty for non-taskgroup types)
    local group_name="" brief_seq="" is_final=""
    if [ -n "$brief_content" ]; then
      group_name=$(printf '%s' "$brief_content" | grep -oE 'Group:\s*\S+' | head -1 | sed 's/Group:[[:space:]]*//' || true)
      brief_seq=$(printf '%s' "$brief_content" | grep -oE 'Brief:\s*[0-9]+' | head -1 | sed 's/Brief:[[:space:]]*//' || true)
      # is_final: check if brief mentions "final" or if brief_seq matches total
      local total_briefs
      total_briefs=$(printf '%s' "$brief_content" | grep -oE 'of [0-9]+' | head -1 | sed 's/of //' || true)
      if [ -n "$brief_seq" ] && [ -n "$total_briefs" ] && [ "$brief_seq" = "$total_briefs" ]; then
        is_final="true"
      else
        is_final="false"
      fi
    fi
    template_content=$(printf '%s' "$template_content" | sed "s|{group_name}|${group_name}|g")
    template_content=$(printf '%s' "$template_content" | sed "s|{brief_seq}|${brief_seq}|g")
    template_content=$(printf '%s' "$template_content" | sed "s|{is_final}|${is_final}|g")

    # Multi-line {brief_text} substitution: split template at marker and concatenate
    # This avoids sed escaping issues with complex brief content
    local before_brief after_brief
    before_brief=$(printf '%s\n' "$template_content" | sed '/{brief_text}/,$d')
    after_brief=$(printf '%s\n' "$template_content" | sed '1,/{brief_text}/d')

    if [ -n "$brief_content" ]; then
      prompt="${before_brief}
${brief_content}
${after_brief}"
    else
      prompt="${before_brief}
No brief content available. Brief path: ${brief_path}
${after_brief}"
    fi

  else
    # --- Fallback: inline prompt assembly (no template for this session type) ---

    # Governance context
    prompt="Read and follow AI.md. Read all files referenced in AI.md's source-of-truth sections.

## Governance Context
${ai_md}
"

    # Spec context
    if [ -n "$spec_summary" ]; then
      prompt="${prompt}
## Active Spec
${spec_summary}
"
    fi

    # Decision references
    if [ -n "$decisions" ]; then
      prompt="${prompt}
## Applicable Decisions
Referenced in task brief: ${decisions}
Read the full decision records in docs/ai/decisions/ before planning.
"
    fi

    # Phase model instructions
    if [ -n "$phases" ]; then
      prompt="${prompt}
## Phase Model
Session type: ${session_type}
Phase sequence: ${phases}
The phase model is enforced by hooks — follow the standard phase progression.
"
    fi

    # Plan-approval bypass
    prompt="${prompt}
## Automation Context
This is a headless automation session (runner-invoked via claude -p).
- plan-approved state has been pre-written by the runner (no operator approval prompt needed)
- Auto mode: ${_QE_AUTO_MODE:-false} (if true, skip op-review phase)
- Solo mode: ${_QE_SOLO_MODE:-false} (if true, merge to main at close)
- Do NOT use AskUserQuestion — there is no interactive operator in headless mode
- Follow the full phase model and gate requirements
"

    # Task brief
    if [ -n "$brief_content" ]; then
      prompt="${prompt}
## Task Brief
${brief_content}
"
    else
      prompt="${prompt}
## Task Brief
No brief content available. Brief path: ${brief_path}
"
    fi
  fi

  # Prepend decision cache entries (if any) per Decision 0017
  local cache_lines=""
  cache_lines=$(build_decision_cache 2>/dev/null || true)
  if [ -n "$cache_lines" ]; then
    prompt="## Decision Cache (binding)
${cache_lines}

${prompt}"
  fi

  # Write assembled prompt back to queue entry
  _QE_PROMPT="$prompt"
  _write_queue_entry "$entry_file"

  # Output to stdout for runner consumption
  printf '%s' "$prompt"
}
