#!/usr/bin/env bash
# Close-time re-verification — rebase and re-verify before merging to main.
# Sourced by runner.sh. NOT executed standalone.
#
# Why this exists: a brief is verified on its own branch against main as it was
# when the branch started. `_solo_merge_if_needed()` then merges at close and
# re-verifies nothing, so if main moved under the branch the merge produces a
# combination neither side was ever verified for. A clean textual merge is not
# evidence that the result works — git only checks that the hunks do not
# collide, and brief 1's overlap report made the collisions visible without
# acting on them. This is the acting half.
#
# Trigger, and only this trigger: main changed at least one file this branch
# also changed, since their merge-base. A branch that can fast-forward is
# strictly a sub-case — if main IS the merge-base then `merge-base..main` is
# empty and the intersection is empty — so there is deliberately no separate
# fast-forward probe. A second trigger that can only ever agree with the first
# is a second thing to keep in step.
#
# With no overlap, nothing here runs and the merge path is byte-for-byte the
# one that shipped before. Overlap alone is a SIGNAL, not a status (brief 1's
# contract): the queue entry's status changes only on a rebase conflict or a
# failed re-verification.
#
# The caller holds the merge lock across rebase -> re-verify -> merge. The gate
# is pointless otherwise: another close could land on main between the verdict
# and the merge, and the thing that was verified would not be the thing merged.
#
# Sourcing order — this file calls, and so must be sourced AFTER:
#   lib/overlap-report.sh    overlap_report_main_changed / _main_commit
#   lib/queue-manager.sh     _parse_config_field
#   lib/permission-profiles.sh  get_disallowed_tools
# `_resolve_model_for_session` lives in runner.sh and is optional: it is called
# through a `type` guard, and without it the re-verify session simply runs on
# the CLI's default model.
#
# Bash 3.2 compatible: no associative arrays, no mapfile, no ${var^^}.

set -euo pipefail

# --- Verdict sentinels ----------------------------------------------------
# The re-verification session communicates exactly one of these, as a whole
# line. Fail-closed: PASS requires the PASS line present AND the FAIL line
# absent. Everything else — no sentinel, both sentinels, a crash, a timeout —
# is a failure. A verification gate that passes on "no answer" is not a gate.
_REVERIFY_PASS_SENTINEL="REVERIFY-RESULT: PASS"
_REVERIFY_FAIL_SENTINEL="REVERIFY-RESULT: FAIL"

# --- Results, read by the caller after _reverify_before_merge -------------
# _REVERIFY_CONFLICT_FILES  paths that conflicted during the rebase (return 1)
# _REVERIFY_FAIL_REASON     human-readable cause of a failure (return 2)
# _REVERIFY_ESCALATION_ID   id of the escalation written on return 2
_REVERIFY_CONFLICT_FILES=""
_REVERIFY_FAIL_REASON=""
_REVERIFY_ESCALATION_ID=""

# --- Wall-clock cap for the re-verification session, in seconds ----------
# Sanitised the same way as runner.sh sanitises session_max_turns: the value
# reaches a CLI invocation and a `sleep`, so an absent or non-numeric reading
# must fall back rather than produce `sleep ''`.
_reverify_timeout() {
  local t
  t=$(_parse_config_field "runner" "reverify_timeout_seconds" 2>/dev/null || echo "900")
  t="${t:-900}"
  case "$t" in ''|*[!0-9]*) t=900 ;; esac
  [ "$t" -gt 0 ] || t=900
  printf '%s' "$t"
}

# --- Turn budget for the re-verification session -------------------------
# Shares runner.sh's session_max_turns rather than adding a knob. The time cap
# is the binding limit here; this exists so a looping session ends by itself
# instead of being SIGTERMed, which runner.sh's header records as a defect
# worth not repeating.
_reverify_max_turns() {
  local t
  t=$(_parse_config_field "runner" "session_max_turns" 2>/dev/null || echo "400")
  t="${t:-400}"
  case "$t" in ''|*[!0-9]*) t=400 ;; esac
  [ "$t" -gt 0 ] || t=400
  printf '%s' "$t"
}

# --- Prompt for the re-verification session ------------------------------
# Arguments: $1 — branch; $2 — newline list of overlapping files
_reverify_prompt() {
  cat <<REVERIFY_PROMPT
# Headless Re-verification — rebased branch

Read and follow AI.md.

Branch \`$1\` has been rebased onto \`main\` in this working tree, because main
changed files this branch also changed. NOTHING has been merged yet, and
whether it is merged depends on your verdict.

Files changed on both sides since the branch point:
$2

Do this and nothing else:

1. Run the repository's verification suites against the rebased tree:
     bash .claude/hooks/tests/run-phase-tests.sh
     bash .claude/.automation/tests/run-automation-tests.sh
   Some suites may already have been failing on this branch before the rebase.
   Those are pre-existing and are NOT your verdict. Establish that by reading
   the failure, not by assuming it.

2. Dispatch the qa-verifier subagent over the rebased tree.

3. Print, as the last line of your output, exactly one of:
     $_REVERIFY_PASS_SENTINEL
     $_REVERIFY_FAIL_SENTINEL
   Print only one. When it is a failure, print a line
     REVERIFY-FAILED-CHECKS: <comma-separated names of what failed>
   immediately before it.

Constraints:
- Read-only session. Do not edit, write, commit, push or merge anything.
- Do not rebase, reset, or otherwise move any ref.
- If you cannot finish the verification for any reason at all, print
  $_REVERIFY_FAIL_SENTINEL. Silence and ambiguity are both read as failure.
REVERIFY_PROMPT
}

# --- Run the re-verification session -------------------------------------
# Arguments: $1 — worktree dir holding the rebased branch; $2 — branch;
#            $3 — newline list of overlapping files
# Returns:   0 only when the session printed the PASS sentinel and not the FAIL
#            sentinel; 1 otherwise.
# Sets:      _REVERIFY_FAIL_REASON on a non-zero return.
_run_reverify_session() {
  local dir="$1" branch="$2" files="$3"
  local timeout max_turns disallowed model_flag="" prompt
  local out_file err_file fired_file child watchdog
  local rc=0 verdict=1 checks resolved_model

  _REVERIFY_FAIL_REASON=""
  timeout=$(_reverify_timeout)
  max_turns=$(_reverify_max_turns)

  if ! command -v claude > /dev/null 2>&1; then
    _REVERIFY_FAIL_REASON="claude CLI not available — re-verification could not run"
    return 1
  fi

  # The `audit` profile: read-only, no Edit/Write/commit/push. The session's
  # only product is the sentinel, so it needs nothing it would be denied.
  disallowed=$(get_disallowed_tools "audit")

  # Optional — runner.sh owns this resolver, and the lib is sourceable without
  # it. `taskgroup-merge` is the routing key because that is the existing
  # session type for "decide whether this merge is safe"; Decision 0014's enum
  # is fixed, so no new type is invented for it.
  if type _resolve_model_for_session > /dev/null 2>&1; then
    resolved_model=$(_resolve_model_for_session "taskgroup-merge" 2>/dev/null || printf '')
    [ -z "$resolved_model" ] || model_flag="--model $resolved_model"
  fi

  out_file=$(mktemp "${TMPDIR:-/tmp}/repo-os-reverify-out-XXXXXX" 2>/dev/null) || {
    _REVERIFY_FAIL_REASON="could not create a capture file for the re-verification session"
    return 1
  }
  err_file=$(mktemp "${TMPDIR:-/tmp}/repo-os-reverify-err-XXXXXX" 2>/dev/null) || {
    rm -f "$out_file" 2>/dev/null || true
    _REVERIFY_FAIL_REASON="could not create a capture file for the re-verification session"
    return 1
  }

  # The watchdog's own record that it fired. Elapsed wall time cannot stand in
  # for it: a session that finishes one second shy of the cap, or one that is
  # killed by something else after the cap has passed, both read as "timed out"
  # on a clock comparison. The brief requires the escalation to say it timed
  # out only when it actually did.
  fired_file="${out_file}.timedout"

  prompt=$(_reverify_prompt "$branch" "$files")

  # `exec`, direct redirects, no process substitution — the same three
  # properties runner.sh's launch sites document at length. Without `exec` the
  # tracked pid is a wrapper and the timeout watchdog signals the wrapper while
  # the session runs on; with a `tee` in the way the verdict line can still be
  # in the pipe when it is read.
  # shellcheck disable=SC2086 — $model_flag must word-split (empty = no flag)
  (cd "$dir" && exec claude -p \
    --permission-mode bypassPermissions \
    --disallowedTools "$disallowed" \
    --max-turns "$max_turns" \
    $model_flag \
    <<< "$prompt" \
    >"$out_file" 2>"$err_file") &
  child=$!

  ( sleep "$timeout"
    if kill -0 "$child" 2>/dev/null; then
      # Flag first, signal second: if the flag were written after the kill the
      # parent's `wait` could return and read the flag before it exists.
      : > "$fired_file" 2>/dev/null || true
      echo "Re-verification exceeded ${timeout}s — sending SIGTERM to pid $child" >&2
      kill -TERM "$child" 2>/dev/null || true
    fi ) &
  watchdog=$!

  wait "$child" || rc=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true

  if [ "$rc" -eq 0 ] \
     && grep -qxF "$_REVERIFY_PASS_SENTINEL" "$out_file" 2>/dev/null \
     && ! grep -qxF "$_REVERIFY_FAIL_SENTINEL" "$out_file" 2>/dev/null; then
    verdict=0
  fi

  if [ "$verdict" -ne 0 ]; then
    if [ -f "$fired_file" ]; then
      # Named explicitly so the escalation can say it timed out rather than
      # reporting an empty verdict, which looks like a broken session.
      _REVERIFY_FAIL_REASON="re-verification timed out after ${timeout}s"
    else
      checks=$(grep -m1 '^REVERIFY-FAILED-CHECKS: ' "$out_file" 2>/dev/null || printf '')
      checks="${checks#REVERIFY-FAILED-CHECKS: }"
      if [ -n "$checks" ]; then
        _REVERIFY_FAIL_REASON="$checks"
      elif [ "$rc" -ne 0 ]; then
        _REVERIFY_FAIL_REASON="re-verification session exited $rc without a verdict"
      else
        _REVERIFY_FAIL_REASON="re-verification session printed no verdict"
      fi
    fi
  fi

  rm -f "$out_file" "$err_file" "$fired_file" 2>/dev/null || true
  return "$verdict"
}

# --- Write the esc-reverify escalation -----------------------------------
# Arguments: $1 — repo dir; $2 — branch; $3 — queue entry id;
#            $4 — newline list of overlapping files; $5 — main commit;
#            $6 — failure reason; $7 — pre-rebase branch SHA
# Sets _REVERIFY_ESCALATION_ID.
_reverify_write_escalation() {
  local repo="$1" branch="$2" brief_id="$3" files="$4"
  local main_commit="$5" reason="$6" pre_sha="${7:-}"
  local dir="$repo/.claude/.automation/escalations"
  local id flat safe_reason

  id="esc-reverify-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dir" 2>/dev/null || true

  flat=$(printf '%s' "$files" | tr '\n' ',' | sed 's/,$//')
  # The reason is model-authored text landing inside a double-quoted YAML
  # scalar, so its own double quotes are folded to single ones rather than
  # escaped — this field is read by humans, not parsed back.
  safe_reason=$(printf '%s' "$reason" | tr '"\n' "' ")

  {
    printf 'escalation:\n'
    printf '  id: "%s"\n' "$id"
    printf '  queue_entry_id: "%s"\n' "$brief_id"
    printf '  type: "gate-failure"\n'
    printf '  severity: "blocking"\n'
    printf '  phase_at_exit: "close"\n'
    printf '  tag_at_exit: "close"\n'
    printf '  message: "Re-verification of %s against main did not pass — branch NOT merged"\n' "$branch"
    printf '  context: "failing_checks: %s | overlap_files: %s | main_commit: %s | pre_rebase_sha: %s"\n' \
      "${safe_reason:-unknown}" "${flat:-none}" "${main_commit:-unknown}" "${pre_sha:-unknown}"
    printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  resolved: false\n'
    printf '  resolution: ""\n'
  } > "$dir/${id}.yaml" 2>/dev/null || true

  _REVERIFY_ESCALATION_ID="$id"
}

# --- Drop a scratch worktree, if this run created one --------------------
_reverify_release_worktree() {
  local repo="$1" wt="$2" scratch="$3" owns="$4"
  [ "$owns" = true ] || return 0
  git -C "$repo" worktree remove --force "$wt" > /dev/null 2>&1 || true
  if [ -n "$scratch" ]; then
    rm -rf "$scratch" 2>/dev/null || true
  fi
  return 0
}

# --- Gate the merge: rebase and re-verify when main moved under us -------
# Arguments: $1 — main repo dir; $2 — branch; $3 — queue entry id
# Returns:   0  merge as today (no overlap, or the rebase re-verified clean)
#            1  the rebase conflicted — caller takes the existing conflict path
#            2  re-verification did not pass — caller must NOT merge
# Sets:      _RESULT_REVERIFIED, _RESULT_OVERLAP_FILES (both read back onto the
#            queue entry), plus _REVERIFY_CONFLICT_FILES / _REVERIFY_FAIL_REASON
#            / _REVERIFY_ESCALATION_ID as documented above.
_reverify_before_merge() {
  local repo="$1" branch="$2" brief_id="${3:-}"
  local overlap="" main_commit="" pre_rebase_sha=""
  local wt="" scratch="" owns_worktree=false conflicted=""

  _RESULT_REVERIFIED=""
  _RESULT_OVERLAP_FILES=""
  _REVERIFY_CONFLICT_FILES=""
  _REVERIFY_FAIL_REASON=""
  _REVERIFY_ESCALATION_ID=""

  # --- Trigger ---
  if ! overlap=$(overlap_report_main_changed "$repo" "main" "$branch"); then
    # No merge-base: a missing ref or unrelated histories. That is "cannot
    # tell", not "no overlap", and this gate fails closed on it.
    _RESULT_REVERIFIED="false"
    _REVERIFY_FAIL_REASON="could not compute the merge-base of '$branch' with main"
    _reverify_write_escalation "$repo" "$branch" "$brief_id" "" "" "$_REVERIFY_FAIL_REASON" ""
    return 2
  fi

  if [ -z "$overlap" ]; then
    # Main changed nothing this branch changed. Unchanged path: no rebase, no
    # re-verification, _RESULT_REVERIFIED stays "" so the entry records that it
    # did not run rather than that it passed.
    return 0
  fi

  _RESULT_OVERLAP_FILES="$overlap"
  main_commit=$(overlap_report_main_commit "$repo" "main" "$branch" "$overlap")
  pre_rebase_sha=$(git -C "$repo" rev-parse "$branch" 2>/dev/null || printf '')

  # --- Where to rebase ---
  if [ "${_CURRENT_WORKTREE_IS_GROUP:-false}" = true ] \
     && [ -n "${_CURRENT_WORKTREE_DIR:-}" ] && [ -d "${_CURRENT_WORKTREE_DIR}" ]; then
    # Decision 0054: the task group's worktree already has the group branch
    # checked out and outlives this brief, so the rebase happens there. It is
    # NOT removed afterwards — the remaining briefs still need it.
    wt="$_CURRENT_WORKTREE_DIR"
  else
    # A standalone entry's session worktree is removed before the merge step
    # runs, so the branch is checked out nowhere and a scratch worktree can
    # take it. Same shape as overlap-report.sh's trial-merge worktree: a
    # directory under $TMPDIR that is thrown away, so no working tree that
    # anything else can see is touched.
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/repo-os-reverify-XXXXXX" 2>/dev/null) || {
      _RESULT_REVERIFIED="false"
      _REVERIFY_FAIL_REASON="could not create a scratch directory for the rebase"
      _reverify_write_escalation "$repo" "$branch" "$brief_id" "$overlap" "$main_commit" \
        "$_REVERIFY_FAIL_REASON" "$pre_rebase_sha"
      return 2
    }
    wt="$scratch/wt"
    if ! git -C "$repo" worktree add "$wt" "$branch" > /dev/null 2>&1; then
      rm -rf "$scratch" 2>/dev/null || true
      _RESULT_REVERIFIED="false"
      _REVERIFY_FAIL_REASON="could not check out '$branch' into a scratch worktree (already checked out elsewhere?)"
      _reverify_write_escalation "$repo" "$branch" "$brief_id" "$overlap" "$main_commit" \
        "$_REVERIFY_FAIL_REASON" "$pre_rebase_sha"
      return 2
    fi
    owns_worktree=true
  fi

  # A dirty tree makes `git rebase` refuse before it ever looks at the commits,
  # and that refusal leaves no unmerged paths — so without this check it would
  # be misreported as a merge conflict with an invented file list.
  if ! git -C "$wt" diff --quiet HEAD 2>/dev/null; then
    _RESULT_REVERIFIED="false"
    _REVERIFY_FAIL_REASON="working tree at $wt has uncommitted changes — cannot rebase"
    _reverify_write_escalation "$repo" "$branch" "$brief_id" "$overlap" "$main_commit" \
      "$_REVERIFY_FAIL_REASON" "$pre_rebase_sha"
    _reverify_release_worktree "$repo" "$wt" "$scratch" "$owns_worktree"
    return 2
  fi

  # --- Rebase ---
  if ! git -C "$wt" rebase main > /dev/null 2>&1; then
    conflicted=$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null || printf '')
    git -C "$wt" rebase --abort > /dev/null 2>&1 || true
    # Fall back to the overlap set rather than reporting "unknown": those are
    # the files that could have conflicted, and an empty list in the
    # escalation is the thing an operator cannot act on.
    [ -n "$conflicted" ] || conflicted="$overlap"
    _REVERIFY_CONFLICT_FILES="$conflicted"
    _RESULT_REVERIFIED="false"
    _reverify_release_worktree "$repo" "$wt" "$scratch" "$owns_worktree"
    return 1
  fi

  # --- Re-verify ---
  if _run_reverify_session "$wt" "$branch" "$overlap"; then
    _RESULT_REVERIFIED="true"
    _reverify_release_worktree "$repo" "$wt" "$scratch" "$owns_worktree"
    return 0
  fi

  # The branch is deliberately LEFT rebased. The thing that failed is the
  # rebased code, so that is what an operator has to be able to reproduce;
  # resetting the ref back would hide it and would be a destructive ref move
  # besides. The pre-rebase SHA goes in the escalation so the old position is
  # still recoverable.
  _RESULT_REVERIFIED="false"
  _reverify_write_escalation "$repo" "$branch" "$brief_id" "$overlap" "$main_commit" \
    "$_REVERIFY_FAIL_REASON" "$pre_rebase_sha"
  _reverify_release_worktree "$repo" "$wt" "$scratch" "$owns_worktree"
  return 2
}
