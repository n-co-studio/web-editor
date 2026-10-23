#!/usr/bin/env bash
# Cohesion trigger — post-completion trigger evaluation for cohesion reviews.
# Sourced by runner.sh. NOT executed standalone.
# Decision 0017 — Operator Automation Layer.
#
# Two trigger conditions:
#   1. Task group all content briefs complete → enqueue taskgroup-merge session
#   2. Cumulative lines changed exceeds threshold → enqueue standalone audit
#
# Depends on (sourced by runner.sh before this file):
#   runner.sh sets REPO_ROOT, AUTOMATION_DIR, CONFIG_FILE
#   queue-manager.sh — queue_enqueue, _parse_config_field, _queue_dir

set -euo pipefail

# --- Cumulative line counter file ---
_COHESION_COUNTER_FILE=""
_cohesion_counter_file() {
  if [ -z "$_COHESION_COUNTER_FILE" ]; then
    _COHESION_COUNTER_FILE="$(_queue_dir)/.cohesion-line-counter"
  fi
  printf '%s' "$_COHESION_COUNTER_FILE"
}

# --- Read cumulative line counter ---
_read_line_counter() {
  local cf
  cf=$(_cohesion_counter_file)
  if [ -f "$cf" ]; then
    cat "$cf" 2>/dev/null | tr -d '[:space:]' | head -1
  else
    echo "0"
  fi
}

# --- Write cumulative line counter (atomic) ---
_write_line_counter() {
  local count="$1"
  local cf
  cf=$(_cohesion_counter_file)
  printf '%s\n' "$count" > "${cf}.tmp"
  mv "${cf}.tmp" "$cf"
}

# --- Count lines changed in the most recent session's commits ---
# Uses git diff --stat between baseline and HEAD.
# Arguments:
#   $1 — baseline_sha (captured before the session ran)
# Output: integer line count on stdout
_count_session_lines() {
  local baseline_sha="${1:-}"
  if [ -z "$baseline_sha" ]; then
    echo "0"
    return
  fi

  # Verify baseline SHA is valid
  if ! git cat-file -t "$baseline_sha" > /dev/null 2>&1; then
    echo "0"
    return
  fi

  local stat_output
  stat_output=$(git diff --stat "$baseline_sha"..HEAD 2>/dev/null | tail -1 || true)

  # Parse "N files changed, X insertions(+), Y deletions(-)"
  local insertions=0 deletions=0
  insertions=$(printf '%s' "$stat_output" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
  deletions=$(printf '%s' "$stat_output" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo "0")
  insertions="${insertions:-0}"
  deletions="${deletions:-0}"

  echo $((insertions + deletions))
}

# --- Resolve task group contract path ---
# Template mode: .claude/local/task-groups/{group}.yaml
# Product mode: docs/ai/task-groups/{group}.yaml
# Arguments:
#   $1 — group_name
# Output: absolute path on stdout (empty if not found)
_resolve_contract_path() {
  local group_name="$1"
  local contract=""

  # Rooted at the MAIN repo, not $REPO_ROOT. A contract belongs to the GROUP,
  # not to one brief: inside a worktree session $REPO_ROOT is the worktree root,
  # so each brief read and wrote its own private copy and `git worktree remove`
  # destroyed the group's definition of done (2026-10-19, task-details-header).
  # Recorded as R16 in docs/ai/logs/known-issues.md, which records the defect;
  # Decision t-0055 clause 4 states the rule (shared per-group and per-entry
  # state resolves through get_main_repo_root(), never the session's own root).
  # Search THIS SESSION's root first, then the MAIN repo root.
  #
  # A contract belongs to the GROUP, not to one brief, but the prompts instruct
  # agents to write it at a session-relative path, and write-guard/bash-guard are
  # immune paths that cannot be taught a new exemption — so the writer cannot be
  # moved without a larger redesign (known-issue R17). Searching both roots is
  # coherent with either location: the session copy is the LIVE one while a brief
  # is running, and the main-repo copy is the one that survives
  # `git worktree remove` — which destroyed task-details-header's contract on
  # 2026-10-19 and left every later brief unable to commit, because A6.1 requires
  # one.
  #
  # Session-first, not main-first: because briefs write the session copy, a
  # main-first order would silently serve a STALE copy to the consumers that read
  # contract CONTENT (A6.3's integration-point checks, the bridge's active-group
  # lookup) whenever both exist. A fresh worktree has no session copy at all —
  # `.claude/local/` is gitignored — so the main fallback still covers the case
  # that caused the loss.
  local _ct_main_root
  _ct_main_root="$(get_main_repo_root 2>/dev/null)" || _ct_main_root=""
  [ -n "$_ct_main_root" ] || _ct_main_root="$REPO_ROOT"

  local _ct_root
  for _ct_root in "$REPO_ROOT" "$_ct_main_root"; do
    [ -n "$_ct_root" ] || continue
    # Template mode first
    contract="$_ct_root/.claude/local/task-groups/${group_name}.yaml"
    if [ -f "$contract" ]; then
      printf '%s' "$contract"
      return
    fi
    # Product mode
    contract="$_ct_root/docs/ai/task-groups/${group_name}.yaml"
    if [ -f "$contract" ]; then
      printf '%s' "$contract"
      return
    fi
  done
}

# --- Parse total brief count from contract ---
# Counts `  - title:` lines under `briefs:` section.
# Arguments:
#   $1 — contract_file path
# Output: integer count on stdout
_parse_brief_count() {
  local contract_file="$1"
  if [ ! -f "$contract_file" ]; then
    echo "0"
    return
  fi

  local count
  count=$(sed -n '/^briefs:/,/^[a-z]/{ /  - title:/p; }' "$contract_file" \
    | wc -l | tr -d '[:space:]')
  echo "${count:-0}"
}

# --- Extract group name from queue entry brief content ---
# Looks for "Group: <name>" pattern in brief text.
# Arguments:
#   $1 — brief_text or brief_path
# Output: group name on stdout (empty if not found)
# Two formats, in priority order:
#
#   1. Canonical (what the templates emit and what
#      _parse_brief_taskgroup_metadata in queue-manager.sh requires):
#          ### Task Group
#          - **Group:** my-group
#   2. Legacy bare form, anchored at line start:
#          Group: my-group
#
# The previous implementation was `grep -oE 'Group:\s*\S+'` with the "Group:"
# prefix stripped. Against the canonical form that matched `Group:**` and
# returned the literal `**`, because `\S+` consumed the closing bold markers.
# `_sanitize_group_name("**")` then reduced to the empty string, so every
# consumer silently treated a well-formed task group brief as having no group:
# the Decision 0054 group worktree never activated, cohesion triggers logged
# "no contract found for group '**'", and drift detection lost its group scope.
# The t-0054 tests missed it because their fixtures used the bare form.
#
# The canonical match is scoped to the `### Task Group` section so a stray
# "Group:" elsewhere in a brief cannot win, and the legacy pattern is anchored
# so it can never again match the middle of a bold marker.
_extract_group_name() {
  local text="$1"
  local group="" file=""

  if [ -f "$REPO_ROOT/$text" ]; then
    file="$REPO_ROOT/$text"
  elif [ -f "$text" ]; then
    file="$text"
  else
    printf ''
    return
  fi

  # Format 1 — canonical, scoped to the ### Task Group section.
  group=$(sed -n '/^### Task Group$/,/^###/{ /^- \*\*Group:\*\*/p; }' "$file" 2>/dev/null \
    | head -1 \
    | sed 's/^- \*\*Group:\*\*[[:space:]]*//; s/[[:space:]]*$//' || true)

  # Format 2 — legacy bare form, anchored at line start.
  if [ -z "$group" ]; then
    group=$(grep -oE '^[[:space:]]*Group:[[:space:]]*[^[:space:]]+' "$file" 2>/dev/null \
      | head -1 \
      | sed 's/^[[:space:]]*Group:[[:space:]]*//' || true)
  fi

  printf '%s' "$group"
}

# --- Check for duplicate merge entry in queue ---
# Returns 0 if a taskgroup-merge entry for this group already exists.
# Arguments:
#   $1 — group_name
_has_pending_merge_entry() {
  local group_name="$1"
  local qdir
  qdir=$(_queue_dir)

  # Search pending-review, approved, and running directories
  local status
  for status in pending-review approved running; do
    local dir="$qdir/$status"
    [ -d "$dir" ] || continue
    local f
    for f in "$dir"/*.yaml; do
      [ -f "$f" ] || continue
      # Quick grep for taskgroup-merge session type and group name
      if grep -q 'session_type: taskgroup-merge' "$f" 2>/dev/null; then
        if grep -q "$group_name" "$f" 2>/dev/null; then
          return 0
        fi
      fi
    done
  done

  return 1
}

# ============================================================
# Trigger 1 — Task group all content briefs complete
# ============================================================

# Check if all content briefs for a task group have completion markers.
# If so, enqueue a taskgroup-merge session (with dedupe).
# Arguments:
#   $1 — group_name
#   $2 — branch (the task group's shared branch)
#   $3 — work_order_id (optional, associates merge entry with same work order)
_check_taskgroup_completion() {
  local group_name="$1"
  local branch="$2"
  local work_order_id="${3:-}"

  if [ -z "$group_name" ]; then
    return
  fi

  # Count completion markers for this group (cross-session scan)
  local marker_count
  marker_count=$(count_cross_session_markers "tg-${group_name}-brief-*.complete")

  if [ "$marker_count" -eq 0 ]; then
    return
  fi

  # Parse total content brief count from contract (exclude merge brief = total - 1)
  local contract_path
  contract_path=$(_resolve_contract_path "$group_name")
  if [ -z "$contract_path" ]; then
    echo "WARNING: cohesion-trigger: no contract found for group '$group_name'" >&2
    return
  fi

  local total_briefs
  total_briefs=$(_parse_brief_count "$contract_path")
  # Content briefs = total - 1 (last brief is merge brief)
  local content_briefs=$((total_briefs - 1))

  if [ "$content_briefs" -le 0 ]; then
    return
  fi

  if [ "$marker_count" -ge "$content_briefs" ]; then
    # All content briefs complete — check for dedupe
    if _has_pending_merge_entry "$group_name"; then
      echo "cohesion-trigger: merge entry already queued for group '$group_name'" >&2
      return
    fi

    echo "cohesion-trigger: all $content_briefs content briefs complete for group '$group_name' — enqueueing merge" >&2
    # Acquire lock before enqueue (audit 6.1: race with concurrent daemon dequeue)
    if acquire_queue_lock; then
      queue_enqueue "" "taskgroup-merge" "" "" "$branch" "$work_order_id" > /dev/null
      release_queue_lock
    else
      echo "cohesion-trigger: WARNING — failed to acquire queue lock for merge enqueue" >&2
    fi
  fi
}

# ============================================================
# Trigger 2 — Cumulative line threshold
# ============================================================

# Check if cumulative lines changed exceeds cohesion trigger threshold.
# Arguments:
#   $1 — baseline_sha (from the just-completed entry)
#   $2 — brief_path (optional, for loop guard checks)
_check_line_threshold() {
  local baseline_sha="$1"
  local brief_path="${2:-}"

  # Loop guard: skip line-threshold increment for remediation sessions
  # to prevent remediation → audit → remediation cycles
  if [ -n "$brief_path" ]; then
    local abs_brief=""
    if [ -f "$brief_path" ]; then
      abs_brief="$brief_path"
    elif [ -f "$REPO_ROOT/$brief_path" ]; then
      abs_brief="$REPO_ROOT/$brief_path"
    fi
    if [ -n "$abs_brief" ] && grep -q '\[remediation-source:' "$abs_brief" 2>/dev/null; then
      echo "cohesion-trigger: skipping line-threshold for remediation session" >&2
      return
    fi
  fi

  # Read threshold from config — early return when disabled (0 or unset)
  local threshold
  threshold=$(_parse_config_field "runner" "cohesion_trigger" 2>/dev/null || true)
  threshold="${threshold:-0}"
  if [ "$threshold" -eq 0 ] 2>/dev/null; then
    return
  fi

  # Count lines from this session
  local session_lines
  session_lines=$(_count_session_lines "$baseline_sha")

  # Add to cumulative counter
  local current_count
  current_count=$(_read_line_counter)
  local new_count=$((current_count + session_lines))

  if [ "$new_count" -ge "$threshold" ]; then
    echo "cohesion-trigger: cumulative lines ($new_count) >= threshold ($threshold) — enqueueing audit" >&2
    # Acquire lock before enqueue (audit 6.1: race with concurrent daemon dequeue)
    if acquire_queue_lock; then
      queue_enqueue "" "audit" > /dev/null
      release_queue_lock
    else
      echo "cohesion-trigger: WARNING — failed to acquire queue lock for audit enqueue" >&2
    fi
    # Reset counter
    _write_line_counter "0"
  else
    _write_line_counter "$new_count"
  fi
}

# ============================================================
# Public API
# ============================================================

# --- Check all cohesion triggers after entry completion ---
# Arguments:
#   $1 — entry_id (completed entry)
#   $2 — session_type of the completed entry
#   $3 — baseline_sha (git SHA before the session ran)
#   $4 — brief_path (path to the entry's brief, for group name extraction)
#   $5 — branch (the entry's branch name)
#   $6 — work_order_id (optional, forwarded to auto-enqueued entries)
check_cohesion_triggers() {
  local entry_id="$1"
  local session_type="$2"
  local baseline_sha="${3:-}"
  local brief_path="${4:-}"
  local branch="${5:-}"
  local work_order_id="${6:-}"

  # Trigger 1: task group completion markers (only for taskgroup sessions)
  if [ "$session_type" = "taskgroup" ]; then
    local group_name=""
    if [ -n "$brief_path" ]; then
      group_name=$(_extract_group_name "$brief_path")
    fi
    if [ -n "$group_name" ] && [ -n "$branch" ]; then
      _check_taskgroup_completion "$group_name" "$branch" "$work_order_id"
    fi
  fi

  # Trigger 2: cumulative line threshold (all session types)
  if [ -n "$baseline_sha" ]; then
    _check_line_threshold "$baseline_sha" "$brief_path"
  fi
}
