#!/usr/bin/env bash
# Outcome detector — classifies post-session outcomes for headless runner.
# Sourced by runner.sh. NOT executed standalone.
# Decision 0017 — Operator Automation Layer.
#
# Depends on (sourced by runner.sh before this file):
#   _phase-helper.sh — _load_phase_state, _PS_* cache variables
#   blocker-reporter.sh — write_blocker_report (optional, for enriched reports)
#
# 5 outcome types (+ 1 edge case):
#   completed — success (exit 0 + new commits)
#   completed — clean-noop (exit 0 + no commits + clean tree)
#   review    — escalation (exit 0 + escalation file or tag=operator)
#   review    — dirty-noop (exit 0 + dirty tree + no commits — edge case)
#   failed    — crash (non-zero + dirty tree)
#   failed    — clean-failure (non-zero + clean tree)

# Audit C6: guard against missing _phase-helper.sh dependency
if ! declare -f _validate_phase_session > /dev/null 2>&1; then
  echo "ERROR: _phase-helper.sh must be sourced before $(basename "${BASH_SOURCE[0]}")" >&2
  return 1 2>/dev/null || exit 1
fi

# --- Classify post-session outcome ---
# Arguments:
#   $1 — exit_code from claude -p
#   $2 — baseline_sha (git rev-parse HEAD captured before launch)
#   $3 — repo_root (absolute path)
#   $4 — entry_id (optional; queue entry ID for enriched blocker reports)
#   $5 — stderr_file (optional; path to captured stderr for blocker reports)
# Output: "outcome:detail" on stdout (e.g., "completed:success", "failed:crash")
#   Caller parses with: OUTCOME="${result%%:*}" DETAIL="${result#*:}"
detect_outcome() {
  local exit_code="$1"
  local baseline_sha="$2"
  local repo_root="$3"
  local entry_id="${4:-}"
  local stderr_file="${5:-}"

  local has_new_commits=false
  local has_dirty_tree=false
  local has_escalation=false
  local has_operator_tag=false

  # Check for new commits since baseline
  local commit_count
  commit_count=$(git log --oneline "$baseline_sha..HEAD" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$commit_count" -gt 0 ]; then
    has_new_commits=true
  fi

  # Check for dirty working tree
  local uncommitted
  uncommitted=$(git diff --name-only 2>/dev/null || true)
  local staged
  staged=$(git diff --cached --name-only 2>/dev/null || true)
  if [ -n "$uncommitted" ] || [ -n "$staged" ]; then
    has_dirty_tree=true
  fi

  # Check for escalation files (includes scope-deviation escalations from
  # pre-commit-gates.sh scope classification gate).
  # Adversarial H5/M3: log warning if escalation dir exists but is empty
  # (possible deletion to suppress escalation detection).
  local escalation_dir="$repo_root/.claude/.automation/escalations"
  local has_scope_deviation=false
  local _esc_count=0
  if [ -d "$escalation_dir" ]; then
    local esc_file
    for esc_file in "$escalation_dir"/*.yaml; do
      if [ -f "$esc_file" ]; then
        # Filter by entry ID: only count escalation files belonging to the
        # current queue entry (P1 — prevents false positive classification
        # from stale escalation files left by other entries).
        if [ -n "$entry_id" ]; then
          if ! grep -q "queue_entry_id: \"$entry_id\"" "$esc_file" 2>/dev/null && \
             ! grep -q "queue_entry_id: $entry_id" "$esc_file" 2>/dev/null; then
            continue
          fi
        fi
        _esc_count=$((_esc_count + 1))
        has_escalation=true
        # Detect scope-deviation type for enriched outcome detail
        if grep -q 'type: "scope-deviation"' "$esc_file" 2>/dev/null || \
           grep -q "type: scope-deviation" "$esc_file" 2>/dev/null; then
          has_scope_deviation=true
        fi
      fi
    done
    # Integrity check: dir exists but no files — possible deletion suppression
    if [ "$_esc_count" -eq 0 ] && [ -d "$escalation_dir" ]; then
      local _dir_mtime
      _dir_mtime=$(stat -f %m "$escalation_dir" 2>/dev/null || stat -c %Y "$escalation_dir" 2>/dev/null || echo "0")
      local _now
      _now=$(date +%s)
      # If dir was modified recently (within 5 min), suspicious
      if [ $((_now - _dir_mtime)) -lt 300 ] 2>/dev/null; then
        echo "WARNING: Escalation directory exists but is empty (recently modified) — possible deletion" >&2
      fi
    fi
  fi

  # Check phase-state for operator tag (with session ID validation)
  local state_file="$repo_root/.claude/.state/phase-state"
  if [ -f "$state_file" ]; then
    if _validate_phase_session "$state_file" 2>/dev/null; then
      if [ "$_PS_TAG" = "operator" ]; then
        has_operator_tag=true
      fi
    fi
  fi

  # Classification (priority order)
  if [ "$exit_code" -eq 0 ]; then
    # Escalation check (exit 0 but needs operator review)
    if [ "$has_escalation" = true ] || [ "$has_operator_tag" = true ]; then
      # Enrich detail when scope-deviation escalation is present
      if [ "$has_scope_deviation" = true ]; then
        echo "review:scope-deviation"
      else
        echo "review:escalation"
      fi
      return
    fi
    # Success (exit 0 + new commits)
    if [ "$has_new_commits" = true ]; then
      echo "completed:success"
      return
    fi
    # Clean no-op (exit 0 + no commits + clean tree)
    if [ "$has_dirty_tree" = false ]; then
      echo "completed:clean-noop"
      return
    fi
    # Edge case: exit 0 but dirty tree and no commits — escalate for review
    echo "review:dirty-noop"
    return
  fi

  # Non-zero exit
  if [ "$has_dirty_tree" = true ]; then
    # Crash (non-zero + dirty tree)
    _write_blocker_report "$exit_code" "$repo_root" "$entry_id" "$stderr_file"
    echo "failed:crash"
    return
  fi

  # Clean failure (non-zero + clean tree)
  _write_blocker_report "$exit_code" "$repo_root" "$entry_id" "$stderr_file"
  echo "failed:clean-failure"
}

# --- Write blocker report on failure ---
# Delegates to blocker-reporter.sh's write_blocker_report when available
# (enriched reports with stderr capture, analytics events, type classification).
# Falls back to inline basic report if blocker-reporter.sh not sourced.
# Arguments:
#   $1 — exit_code
#   $2 — repo_root
#   $3 — entry_id (optional; queue entry that failed)
#   $4 — stderr_file (optional; path to captured stderr)
_write_blocker_report() {
  local exit_code="$1"
  local repo_root="$2"
  local entry_id="${3:-}"
  local stderr_file="${4:-}"

  # Delegate to blocker-reporter if available (enriched reports)
  if type write_blocker_report > /dev/null 2>&1; then
    # Pass last prompt from queue entry globals (still loaded at this point)
    write_blocker_report "$exit_code" "$repo_root" "$entry_id" "$stderr_file" "${_QE_PROMPT:-}"
    return
  fi

  # Fallback: inline basic report (backward compatible with Brief 2)
  local reports_dir="$repo_root/.claude/.automation/reports"
  mkdir -p "$reports_dir" 2>/dev/null || true

  local report_id
  report_id="report-$(date +%Y%m%d-%H%M%S)"
  local report_file="$reports_dir/${report_id}.yaml"

  # Read phase-state if available (with session ID validation)
  local phase_at_exit=""
  local tag_at_exit=""
  local state_file="$repo_root/.claude/.state/phase-state"
  if [ -f "$state_file" ]; then
    if _validate_phase_session "$state_file" 2>/dev/null; then
      phase_at_exit="${_PS_CURRENT_PHASE:-}"
      tag_at_exit="${_PS_TAG:-}"
    fi
  fi

  # Capture git status (single-line: replace newlines with literal \n for YAML)
  local git_status_raw
  git_status_raw=$(git status --short 2>/dev/null || echo "unavailable")
  local git_status_output=""
  local _gs_line
  local _gs_first=true
  while IFS= read -r _gs_line; do
    _gs_line="${_gs_line//\"/\\\"}"
    if [ "$_gs_first" = true ]; then
      git_status_output="$_gs_line"
      _gs_first=false
    else
      git_status_output="${git_status_output}\\n${_gs_line}"
    fi
  done <<< "$git_status_raw"

  # Write report (YAML format per blocker-report schema)
  {
    printf 'report:\n'
    printf '  id: "%s"\n' "$report_id"
    printf '  queue_entry_id: "%s"\n' "$entry_id"
    printf '  exit_code: %s\n' "$exit_code"
    printf '  phase_at_exit: "%s"\n' "$phase_at_exit"
    printf '  tag_at_exit: "%s"\n' "$tag_at_exit"
    printf '  stderr_tail: ""\n'
    printf '  git_status: "%s"\n' "$git_status_output"
    printf '  analytics_events: []\n'
    printf '  resolution:\n'
    printf '    status: "unresolved"\n'
    printf '    notes: ""\n'
    printf '    resolved_at: ""\n'
  } > "$report_file" 2>/dev/null || true
}
