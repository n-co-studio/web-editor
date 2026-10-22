#!/usr/bin/env bash
# Outcome detector — classifies post-session outcomes for headless runner.
# Sourced by runner.sh. NOT executed standalone.
# Decision 0017 — Operator Automation Layer.
#
# Depends on (sourced by runner.sh before this file):
#   _phase-helper.sh — _load_phase_state, _PS_* cache variables
#   blocker-reporter.sh — write_blocker_report (optional, for enriched reports)
#
# Outcomes, in the order the exit-0 path tests them. This list is the only
# enumeration of them in the codebase, so keep it current — it had drifted four
# details behind by 2026-10-21.
#   review    — turn-budget-exhausted (exit 0 + "Reached max turns" in the last
#               runner.stderr_tail_lines lines of captured stderr OR stdout;
#               checked FIRST, ahead of every success branch)
#   review    — scope-deviation (exit 0 + scope-deviation escalation)
#   review    — escalation (exit 0 + escalation file or tag=operator)
#   review    — incomplete-deliverable (exit 0 + commits + COMPLETENESS_GATE: NEEDS_WORK)
#   review    — finish-incomplete (finish-loop sessions only)
#   completed — success (exit 0 + new commits)
#   completed — clean-noop (exit 0 + no commits + clean tree)
#   review    — dirty-noop (exit 0 + dirty tree + no commits — edge case)
#   completed — killed-after-complete (exit 143/SIGTERM + new commits — git is source of truth)
#   failed    — crash (non-zero + dirty tree)
#   failed    — clean-failure (non-zero + clean tree)
# Every review:* detail is cleared with `queue-cli.sh reopen-entry <id>`.

# --- Find the turn-budget banner in the tail of the captured streams ---
# Arguments: any number of capture-file paths (empty or missing ones are skipped,
#   which is the mktemp-failure path: no detection, no crash).
# Output: the first path whose last N lines contain the banner, else nothing.
#   N is runner.stderr_tail_lines (default 50, also used when the config reader
#   is not loaded or returns something non-numeric).
_find_turn_banner() {
  local _tail_n=""
  if declare -f _parse_config_field > /dev/null 2>&1; then
    _tail_n=$(_parse_config_field "runner" "stderr_tail_lines" 2>/dev/null || true)
  fi
  case "$_tail_n" in ''|*[!0-9]*) _tail_n=50 ;; esac
  [ "$_tail_n" -gt 0 ] || _tail_n=50
  local _f
  for _f in "$@"; do
    [ -n "$_f" ] && [ -f "$_f" ] || continue
    if tail -n "$_tail_n" "$_f" 2>/dev/null | grep -qF 'Reached max turns'; then
      printf '%s' "$_f"
      return 0
    fi
  done
  return 0
}

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
#   $6 — stdout_file (optional; path to captured stdout; scanned for the
#        turn-budget banner alongside stderr)
# Output: "outcome:detail" on stdout (e.g., "completed:success", "failed:crash")
#   Caller parses with: OUTCOME="${result%%:*}" DETAIL="${result#*:}"
detect_outcome() {
  local exit_code="$1"
  local baseline_sha="$2"
  local repo_root="$3"
  local entry_id="${4:-}"
  local stderr_file="${5:-}"
  local stdout_file="${6:-}"

  local has_new_commits=false
  local has_dirty_tree=false
  local has_escalation=false
  local has_operator_tag=false

  # Defensive guard: fall back to CWD when repo_root is empty
  local _git_repo_root="${repo_root:-$(pwd)}"

  # Check for new commits since baseline
  local commit_count
  commit_count=$(git -C "$_git_repo_root" log --oneline "$baseline_sha..HEAD" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$commit_count" -gt 0 ]; then
    has_new_commits=true
  fi

  # Check for dirty working tree
  local uncommitted
  uncommitted=$(git -C "$_git_repo_root" diff --name-only 2>/dev/null || true)
  local staged
  staged=$(git -C "$_git_repo_root" diff --cached --name-only 2>/dev/null || true)
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
  local state_file="$(get_session_state_dir)/phase-state"
  if [ -f "$state_file" ]; then
    if _validate_phase_session "$state_file" 2>/dev/null; then
      if [ "$_PS_TAG" = "operator" ]; then
        has_operator_tag=true
      fi
    fi
  fi

  # Classification (priority order)
  if [ "$exit_code" -eq 0 ]; then
    # Turn-budget exhaustion. Checked FIRST, ahead of every success branch.
    #
    # A session that runs out of turns exits ZERO. On 2026-10-21 two briefs each
    # burned ~40 minutes, hit `Error: Reached max turns (200)`, committed
    # nothing, and left a clean tree — so one was recorded `completed:clean-noop`
    # and its queue entry left the queue as though the work were done. Silently
    # dropping approved work is the worst failure this detector can produce.
    #
    # Ahead of the has_new_commits branch, not merely ahead of clean-noop: a
    # session that committed partial work and THEN ran out of turns has not
    # completed its brief either, and its partial commits are exactly what makes
    # that case look like success.
    #
    # The signal has to be the captured output text, because the exit code is 0
    # and carries nothing. The capture files are empty only when mktemp failed at
    # launch (runner.sh blanks both together); that path is already degraded and
    # the check simply cannot fire there.
    #
    # Way out of this outcome (it must not become another guard with no exit):
    # raise `runner.session_max_turns` or split the brief, THEN
    # `queue-cli.sh reopen-entry <id>`.
    #
    # That command had to be added for this: `queue_approve` handles
    # pending-review only, `recover-entry` handles running only, and
    # `reopen-wo` resets blocked|failed siblings only — so before 2026-10-21
    # NO review:* outcome had a transition out of review/, and the first draft
    # of this comment confidently named two commands that cannot move the
    # entry. Review caught it. Documented in
    # .claude/.automation/docs/blocker-playbook.md section 14.
    # Both captured streams are scanned, because which one carries the banner
    # was never established (the CLI cannot be spawned from a governed session).
    # The match is NOT anchored to start-of-line: on 2026-10-21 the banner was
    # immediately followed by a hook WARNING with no newline, so output reaches
    # these files without line discipline and the banner need not start a line.
    # What keeps the match from misfiring is scope, not anchoring — only the last
    # `runner.stderr_tail_lines` lines are searched. The older unanchored form
    # matched the phrase ANYWHERE in the whole capture for all time, so any
    # wrapper, `set -x` trace or hook message quoting it would misclassify the
    # session, and misclassification is sticky (the entry then needs an
    # operator). Exhaustion is always the END of a session; a stray mention
    # earlier in a long one is not. Observed banner, 2026-10-21:
    #   Error: Reached max turns (200)
    local _banner_file
    _banner_file=$(_find_turn_banner "$stderr_file" "$stdout_file")
    if [ -n "$_banner_file" ]; then
      # Persist the evidence before returning. Every other review:* detail
      # leaves an artifact — an escalation YAML or an error_log — and this one
      # left only a line in daemon.log, with `runner.sh` deleting the temp
      # files straight after. For an outcome whose entire purpose is "do not
      # silently drop approved work", discarding the reason the work was
      # dropped is the wrong half to keep. The report tails the file the
      # banner was actually found in.
      _write_blocker_report "$exit_code" "$repo_root" "$entry_id" "$_banner_file" 2>/dev/null || true
      echo "review:turn-budget-exhausted"
      return
    fi
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
    # Completeness check: COMPLETENESS_GATE: NEEDS_WORK → review:incomplete-deliverable
    # Read cohesion-reviewed state file (backward compat: absent file falls through).
    if [ "$has_new_commits" = true ]; then
      local _cohesion_state
      _cohesion_state="$(get_session_state_dir)/cohesion-reviewed"
      if [ -f "$_cohesion_state" ] && \
         grep -q '^COMPLETENESS_GATE: NEEDS_WORK' "$_cohesion_state" 2>/dev/null; then
        echo "review:incomplete-deliverable"
        return
      fi
    fi

    # FINISH_LOOP sentinel parsing — scoped to finish-loop sessions only.
    # Regression sentinel takes priority over incomplete sentinel.
    local _fl_session_type
    _fl_session_type=$(get_session_type 2>/dev/null || echo "")
    if [ "$_fl_session_type" = "finish-loop" ] && [ "$has_new_commits" = true ]; then
      local _fl_cohesion_state
      _fl_cohesion_state="$(get_session_state_dir)/cohesion-reviewed"
      if [ -f "$_fl_cohesion_state" ]; then
        if grep -q '^FINISH_LOOP_REGRESSION:' "$_fl_cohesion_state" 2>/dev/null; then
          echo "review:scope-deviation"
          return
        fi
        if grep -q '^FINISH_LOOP_RESULT: INCOMPLETE' "$_fl_cohesion_state" 2>/dev/null; then
          echo "review:finish-incomplete"
          return
        fi
      fi
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

  # Non-zero exit — check for SIGTERM (exit code 143 = 128 + 15)
  # When a session completes its work (commits code, writes session log) and then
  # gets killed by SIGTERM during close-phase output, exit code is 143 but the
  # work is done. Git state is the source of truth, not exit code.
  if [ "$exit_code" -eq 143 ] && [ "$has_new_commits" = true ]; then
    echo "WARNING: Exit code 143 (SIGTERM) but session produced commits — classifying as completed" >&2
    # Still check for escalations (session may have written one before being killed)
    if [ "$has_escalation" = true ]; then
      if [ "$has_scope_deviation" = true ]; then
        echo "review:scope-deviation"
      else
        echo "review:escalation"
      fi
      return
    fi
    echo "completed:killed-after-complete"
    return
  fi

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
  local state_file="$(get_session_state_dir)/phase-state"
  if [ -f "$state_file" ]; then
    if _validate_phase_session "$state_file" 2>/dev/null; then
      phase_at_exit="${_PS_CURRENT_PHASE:-}"
      tag_at_exit="${_PS_TAG:-}"
    fi
  fi

  # Capture git status (single-line: replace newlines with literal \n for YAML)
  local _wr_git_root="${repo_root:-$(pwd)}"
  local git_status_raw
  git_status_raw=$(git -C "$_wr_git_root" status --short 2>/dev/null || echo "unavailable")
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
