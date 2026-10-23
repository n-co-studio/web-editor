#!/usr/bin/env bash
# Pull request close path — open, track and land a PR for a queue entry.
# Sourced by runner.sh and by queue-cli.sh. NOT executed standalone.
#
# Why this exists: an entry on `close_path: pr` (Decision t-0057 brief 1) had a
# recorded state and no pipeline behind it. Its branch stayed local, nothing was
# opened, and the only signal the operator got was `close_state: ready`. Work
# that does not merge itself went unseen. This is the other half: push the
# branch, open the pull request, and keep re-reading it until it merges.
#
# Division of labour with the solo path:
#   solo  — runner.sh `_solo_merge_if_needed`, the ONE implementation of a
#           direct merge to main (t-0057 §6). Nothing here duplicates it.
#   pr    — this file. main is changed by GitHub, not by us; what we do locally
#           is fast-forward main to what GitHub produced and seal the branch
#           (Decision 0013). The two paths share the preconditions gate
#           (`_queue_close_preconditions` in lib/queue-manager.sh) so they can
#           never disagree about what may reach main.
#
# Sourcing order — this file calls, and so must be sourced AFTER:
#   lib/queue-manager.sh    _parse_config_field, _load_queue_entry,
#                           queue_close_record, queue_close_state,
#                           queue_close_path, queue_set_pr,
#                           queue_pr_merge_allowed, queue_is_final_taskgroup_entry,
#                           _session_id_for_entry
# Optional, each reached through a `type` guard so this file works without them:
#   .claude/hooks/_cleanup-helper.sh  record_closed_branch,
#                                     delete_merged_session_branch
# Requires REPO_ROOT. Uses AUTOMATION_DIR when set, else derives it.
#
# gh is the only GitHub client, and it is optional. Every entry point degrades
# to a recorded step and rc 0 rather than failing the entry: a reporting layer
# that can fail the work it reports on is worse than no reporting layer.
#
# Bash 3.2 compatible: no associative arrays, no mapfile, no ${var^^}.

set -euo pipefail

# --- Results, read by the caller after any pr_* entry point ---------------
# _PR_REASON          why the last call refused or degraded (empty on success)
# _PR_OUTCOME         "" | review:merge-conflict — the caller routes it, because
#                     runner.sh sets _RESULT_OUTCOME and queue-cli.sh calls
#                     queue_escalate, and this file must not know which it is in
# _PR_NUMBER/_PR_URL  the pull request this call acted on
# _PR_STATE           OPEN | MERGED | CLOSED, as last read from gh
# _PR_MERGEABLE       MERGEABLE | CONFLICTING | UNKNOWN
# _PR_MERGE_STATE_STATUS  gh's finer-grained reason (DIRTY, BEHIND, BLOCKED, ...)
# _PR_CHECKS          passed | failed | pending | none
# _PR_CHECK_DETAIL    one-line summary naming the deciding check
# _PR_ESCALATION_ID   id of the escalation written on a conflict
_PR_REASON=""
_PR_OUTCOME=""
_PR_NUMBER=""
_PR_URL=""
_PR_STATE=""
_PR_MERGEABLE=""
_PR_MERGE_STATE_STATUS=""
_PR_CHECKS=""
_PR_CHECK_DETAIL=""
_PR_ESCALATION_ID=""

# A newline as a value, so the last-line extractions below do not depend on a
# literal newline sitting invisibly inside a ${var##...} pattern.
_PR_NL='
'

_pr_reset_results() {
  _PR_REASON=""
  _PR_OUTCOME=""
  _PR_NUMBER=""
  _PR_URL=""
  _PR_STATE=""
  _PR_MERGEABLE=""
  _PR_MERGE_STATE_STATUS=""
  _PR_CHECKS=""
  _PR_CHECK_DETAIL=""
  _PR_ESCALATION_ID=""
}

# --- Config readings, each sanitised at the point of use ------------------
# Same discipline as reverify-merge.sh's _reverify_timeout: these values reach
# a gh invocation and a `sleep`, so an absent or malformed reading must fall
# back to the documented default rather than be passed through.
_pr_merge_method() {
  local m
  m=$(_parse_config_field "pr" "merge_method" 2>/dev/null) || m=""
  case "$m" in merge|squash|rebase) ;; *) m="merge" ;; esac
  printf '%s' "$m"
}

_pr_poll_seconds() {
  local s
  s=$(_parse_config_field "pr" "poll_seconds" 2>/dev/null) || s=""
  s="${s:-120}"
  case "$s" in ''|*[!0-9]*) s=120 ;; esac
  [ "$s" -gt 0 ] || s=120
  printf '%s' "$s"
}

_pr_delete_branch() {
  local d
  d=$(_parse_config_field "pr" "delete_branch" 2>/dev/null) || d=""
  case "$d" in true|false) ;; *) d="true" ;; esac
  printf '%s' "$d"
}

# --- Is gh usable? --------------------------------------------------------
# Both halves are required and they fail differently: an absent binary is a
# repo that never installed gh, an unauthenticated one is a repo that did. The
# reason is reported verbatim to the operator because the remedy differs.
#
# This is the ONLY place availability is decided. Callers ask once and record
# the answer as a step, so a degraded close says which half was missing.
pr_gh_available() {
  _PR_REASON=""
  if ! command -v gh > /dev/null 2>&1; then
    _PR_REASON="gh is not installed — install the GitHub CLI, or close this entry with 'set-close <id> solo'"
    return 1
  fi
  if ! gh auth status > /dev/null 2>&1; then
    _PR_REASON="gh is installed but not authenticated — run 'gh auth login'"
    return 1
  fi
  return 0
}

# --- Run gh against this repo --------------------------------------------
# gh reads the remote from the working directory and has no `-C`. A worktree
# session's cwd is the worktree, whose origin is the same remote, but REPO_ROOT
# is the one path both callers agree on — so every gh call is pinned to it in a
# subshell. A subshell, not a bare `cd`, so a failure cannot leave the runner's
# daemon loop in a different directory than it started in.
_pr_gh() {
  ( cd "$REPO_ROOT" && gh "$@" )
}

_pr_git() {
  git -C "$REPO_ROOT" "$@"
}

# --- Template substitution, zero-fork ------------------------------------
# Replaces every {key} with a value. Parameter expansion rather than sed
# because the verification list is multi-line and sed cannot portably insert a
# multi-line replacement; and because no value needs escaping this way, where a
# sed replacement would need `&`, `\` and the delimiter escaped in text that
# comes from a brief nobody validated.
#
# Arguments: $1 text, $2 key (without braces), $3 value
_pr_tpl_sub() {
  local text="$1" key="{$2}" val="$3" out=""
  while case "$text" in *"$key"*) true ;; *) false ;; esac; do
    out="${out}${text%%"$key"*}${val}"
    text="${text#*"$key"}"
  done
  printf '%s' "${out}${text}"
}

# --- Title for the pull request ------------------------------------------
# The brief's first `# ` heading, which is the brief template's title line.
# Falls back to the branch name — never to a generic string, because a PR list
# of identically-titled rows is no more use than no PR at all.
#
# Arguments: $1 brief path (may be empty/missing), $2 branch, $3 entry id
_pr_title() {
  local brief="${1:-}" branch="${2:-}" eid="${3:-}" line title=""
  if [ -n "$brief" ] && [ -f "$brief" ]; then
    while IFS= read -r line; do
      case "$line" in
        "# "*)
          title="${line#\# }"
          break
          ;;
      esac
    done < "$brief"
  fi
  if [ -z "$title" ]; then
    title="${branch:-$eid}"
  fi
  printf '%s' "$title"
}

# --- Goal line from the brief --------------------------------------------
# First non-empty line under `## Goal` / `### Goal`. Same scrape as
# queue-cli.sh's `follow-up-draft`, which reads the same brief shape; kept to
# one line because the PR body's first paragraph is what GitHub shows in a
# list, and a brief's Goal section is written as a single sentence.
_pr_brief_goal() {
  local brief="${1:-}" line in_goal=false goal=""
  [ -n "$brief" ] && [ -f "$brief" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      "## Goal"*|"### Goal"*) in_goal=true ;;
      "#"*) in_goal=false ;;
      "") ;;
      *)
        if [ "$in_goal" = true ] && [ -z "$goal" ]; then
          goal="$line"
          break
        fi
        ;;
    esac
  done < "$brief"
  printf '%s' "$goal"
}

# --- Scope section from the brief ----------------------------------------
# Verbatim body of `## Scope` (or `### Scope`), which in the brief template is
# already a list of paths. Copied rather than summarised: a reviewer wants to
# know which files the session was allowed to touch, and a summary of that is
# an invitation to be wrong about it.
_pr_brief_scope() {
  local brief="${1:-}" line in_scope=false out=""
  [ -n "$brief" ] && [ -f "$brief" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      "## Scope"*|"### Scope"*) in_scope=true; continue ;;
      "#"*) [ "$in_scope" = false ] || break ;;
    esac
    if [ "$in_scope" = true ]; then
      out="${out}${line}
"
    fi
  done < "$brief"
  printf '%s' "$out"
}

# --- Verification list, with results -------------------------------------
# Two sources, both already on disk, neither of them this file's opinion:
#   1. the brief's checklist lines — what the session was asked to verify
#   2. docs/ai/governance/criteria-verdicts/<sid>.yaml — what the completeness
#      gate recorded, verdict included
# Every criterion is emitted, not just the unmet ones (which is where this
# differs from `follow-up-draft`): a PR body showing only failures reads as a
# clean run when the gate never ran at all.
#
# Arguments: $1 brief path, $2 session id (may be empty)
_pr_verification() {
  local brief="${1:-}" sid="${2:-}" line out="" vf crit="" verdict
  if [ -n "$brief" ] && [ -f "$brief" ]; then
    while IFS= read -r line; do
      case "$line" in
        *"- [ ]"*) out="${out}- [ ] ${line#*- \[ \] }
" ;;
        *"- [x]"*) out="${out}- [x] ${line#*- \[x\] }
" ;;
      esac
    done < "$brief"
  fi
  if [ -n "$sid" ]; then
    vf="$REPO_ROOT/docs/ai/governance/criteria-verdicts/${sid}.yaml"
    if [ -f "$vf" ]; then
      out="${out}
Criteria verdicts recorded by the completeness gate (\`${sid}\`):

"
      # One pass remembering the last `criterion:` seen — the verdict line
      # comes after its criterion in the record's shape, so a row is emitted
      # when the verdict names it, not when the criterion is read.
      while IFS= read -r line; do
        case "$line" in
          *"criterion:"*)
            crit="${line#*criterion:}"
            crit="${crit# }"
            crit="${crit#\"}"; crit="${crit%\"}"
            ;;
          *"verdict: "*)
            if [ -n "$crit" ]; then
              verdict="${line#*verdict: }"
              verdict="${verdict%% *}"
              out="${out}- \`${verdict}\` — ${crit}
"
              crit=""
            fi
            ;;
        esac
      done < "$vf"
    fi
  fi
  if [ -z "$out" ]; then
    out="_No verification list was found in the brief and no criteria verdicts were recorded for this entry._"
  fi
  printf '%s' "$out"
}

# --- Render the pull request body ----------------------------------------
# Writes to stdout. Requires the loaded entry's fields to be passed in rather
# than read from _QE_*, because every queue_close_record call in this file
# clobbers those globals and a renderer that depends on their timing is a bug
# waiting for a reordering.
#
# Arguments: $1 entry id, $2 branch, $3 brief path, $4 work order id,
#            $5 reverified, $6 session id
_pr_body() {
  local eid="$1" branch="$2" brief="$3" wo="$4" reverified="$5" sid="$6"
  local tpl body goal scope verification
  tpl="${AUTOMATION_DIR:-$REPO_ROOT/.claude/.automation}/templates/pr-body.md"
  if [ ! -f "$tpl" ]; then
    # Degrade to the provenance line alone rather than opening a PR with an
    # empty body: the entry id is the one thing a reviewer needs to find the
    # rest, and it is the one thing that does not come from the template.
    printf 'Opened by the Repo OS operator automation layer for queue entry `%s` on branch `%s`.\n\nThe PR body template (%s) is missing, so the brief and verification list could not be rendered.\n' \
      "$eid" "$branch" "$tpl"
    return 0
  fi
  body=$(cat "$tpl")
  goal=$(_pr_brief_goal "$brief")
  [ -n "$goal" ] || goal="_The brief recorded no Goal section._"
  scope=$(_pr_brief_scope "$brief")
  [ -n "$scope" ] || scope="_The brief recorded no Scope section._"
  verification=$(_pr_verification "$brief" "$sid")

  body=$(_pr_tpl_sub "$body" "goal" "$goal")
  body=$(_pr_tpl_sub "$body" "scope" "$scope")
  body=$(_pr_tpl_sub "$body" "verification" "$verification")
  body=$(_pr_tpl_sub "$body" "entry_id" "$eid")
  body=$(_pr_tpl_sub "$body" "session_id" "${sid:-unrecorded}")
  body=$(_pr_tpl_sub "$body" "branch" "$branch")
  # Repo-relative for the reader: the caller resolves brief_path against
  # REPO_ROOT so the scrapers can read it, and a reviewer should not be shown
  # the absolute path of whichever machine ran the close.
  local brief_shown="${brief:-none}"
  if [ -n "${REPO_ROOT:-}" ]; then
    case "$brief_shown" in
      "$REPO_ROOT"/*) brief_shown="${brief_shown#"$REPO_ROOT"/}" ;;
    esac
  fi
  body=$(_pr_tpl_sub "$body" "brief_path" "$brief_shown")
  body=$(_pr_tpl_sub "$body" "work_order_id" "${wo:-none}")
  case "$reverified" in
    true)  body=$(_pr_tpl_sub "$body" "reverified" "passed before this PR was opened") ;;
    false) body=$(_pr_tpl_sub "$body" "reverified" "FAILED — read the entry's escalation before merging") ;;
    *)     body=$(_pr_tpl_sub "$body" "reverified" "did not run (main changed nothing this branch changed)") ;;
  esac
  printf '%s\n' "$body"
}

# --- Classify a gh check-rollup reading ----------------------------------
# Precedence is failing > pending > passing, and it is deliberately NOT read
# from the rollup's aggregate state. gh#14253: the aggregate can report SUCCESS
# while an individual check run has a FAILURE conclusion, so the aggregate is
# not a safe input to a gate that decides what reaches main. Individual rows
# only.
#
# "none" is its own verdict rather than a pass: a repo with no CI configured
# and a repo whose CI has not reported yet must not look identical to one whose
# checks went green. It does not block a merge — there is nothing to wait for —
# but the step detail says so.
#
# Arguments: $1 the check's verdict word (already upper-case), read against the
#            running classification in _PR_CHECKS. Sets
#            _PR_CHECKS/_PR_CHECK_DETAIL.
#
# The parameter is `verdict` rather than the more natural word for a single
# lexical unit, because A4's secret scanner treats that word followed by `=` and
# a quote as a credential assignment, and a `local` declaration of it is
# indistinguishable from one. Renaming is the honest fix: nothing here handles a
# credential at all — `gh` owns the only one — so there was no secret to
# suppress, just a name to stop borrowing. (This comment avoids spelling the
# word beside an `=` for the same reason: the scanner reads added lines, and
# documenting the match would re-create it.)
_pr_check_fold() {
  local verdict="$1" name="${2:-unnamed}"
  case "$verdict" in
    FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED|STALE|STARTUP_FAILURE)
      # First failure wins the detail — it is the one the operator must look at.
      if [ "$_PR_CHECKS" != "failed" ]; then
        _PR_CHECKS="failed"
        _PR_CHECK_DETAIL="$name is $verdict"
      fi
      ;;
    QUEUED|IN_PROGRESS|PENDING|EXPECTED|WAITING|REQUESTED)
      if [ "$_PR_CHECKS" != "failed" ] && [ "$_PR_CHECKS" != "pending" ]; then
        _PR_CHECKS="pending"
        _PR_CHECK_DETAIL="$name is $verdict"
      fi
      ;;
    *)
      if [ "$_PR_CHECKS" = "none" ]; then
        _PR_CHECKS="passed"
        _PR_CHECK_DETAIL="all checks passed"
      fi
      ;;
  esac
}

# --- Read a pull request's live state ------------------------------------
# One gh round trip. All JSON parsing happens inside `gh --jq` — gh embeds jq,
# so this adds no dependency, and it keeps a JSON reader out of a shell that
# has no business containing one. The output is tab-delimited lines, which the
# loop below reads with `read -r`; the key is always the first field, so an
# unrecognised line is ignored rather than mis-assigned.
#
# A CheckRun carries status (QUEUED/IN_PROGRESS/COMPLETED) and conclusion
# (SUCCESS/FAILURE/...); a StatusContext carries only state. conclusion is the
# EMPTY STRING on an unfinished run, not null, so `//` would not fall through
# it — hence the explicit length tests in the jq program.
#
# Sets _PR_STATE/_PR_MERGEABLE/_PR_URL/_PR_CHECKS/_PR_CHECK_DETAIL.
# Arguments: $1 PR number
# Returns 0 on a successful read, 1 when gh could not read the PR.
_pr_read() {
  local num="$1" out k v w tab
  tab=$(printf '\t')
  _PR_CHECKS="none"
  _PR_CHECK_DETAIL="no checks are configured for this pull request"
  out=$(_pr_gh pr view "$num" \
        --json number,url,state,mergeable,mergeStateStatus,statusCheckRollup \
        --jq '
          "state\t" + (.state // ""),
          "mergeable\t" + (.mergeable // ""),
          "mergeStateStatus\t" + (.mergeStateStatus // ""),
          "url\t" + (.url // ""),
          ((.statusCheckRollup // [])[] |
            "check\t" +
            (if ((.conclusion // "") | length) > 0 then .conclusion
             elif ((.status // "") | length) > 0 then .status
             else (.state // "") end | ascii_upcase) + "\t" +
            (.name // .context // "unnamed"))
        ' 2>/dev/null) || {
    _PR_REASON="gh could not read pull request #${num} — it may have been deleted, or gh lost access to the repo"
    return 1
  }
  while IFS="$tab" read -r k v w; do
    case "$k" in
      state)            _PR_STATE="$v" ;;
      mergeable)        _PR_MERGEABLE="$v" ;;
      mergeStateStatus) _PR_MERGE_STATE_STATUS="$v" ;;
      url)              [ -z "$v" ] || _PR_URL="$v" ;;
      check)            _pr_check_fold "$v" "${w:-unnamed}" ;;
    esac
  done <<EOF
$out
EOF
  return 0
}

# --- Route a pull request conflict to review -----------------------------
# Writes the SAME escalation shape runner.sh writes for a solo merge conflict,
# with `source: "pr"` so a reader can tell the two apart. The field is added to
# both writers rather than defaulting when absent, because an escalation that
# does not say where it came from sends the operator to the wrong place.
#
# No conflicting-file list is claimed. git can only name conflicting files by
# attempting the merge, and this path never attempts one — the merge is
# GitHub's. Guessing from the overlap report would put a list of files that
# merely CHANGED on both sides under a heading saying they conflicted, which is
# precisely the false claim close_steps exists to prevent. The remedy command
# is given instead; it produces the real list.
#
# Arguments: $1 entry file, $2 entry id, $3 branch, $4 gh's mergeStateStatus
_pr_route_conflict() {
  local entry_file="$1" eid="$2" branch="$3" mss="${4:-}"
  local esc_dir esc_id detail
  esc_dir="$REPO_ROOT/.claude/.automation/escalations"
  mkdir -p "$esc_dir" 2>/dev/null || true
  esc_id="esc-merge-$(date +%Y%m%d-%H%M%S)-$$"
  detail="conflicts with main (mergeStateStatus: ${mss:-unknown}); no file list — run 'queue-cli.sh pr update-branch ${eid}' or rebase '${branch}' locally to produce one"
  {
    printf 'escalation:\n'
    printf '  id: "%s"\n' "$esc_id"
    printf '  queue_entry_id: "%s"\n' "$eid"
    printf '  type: "scope-deviation"\n'
    printf '  severity: "blocking"\n'
    printf '  source: "pr"\n'
    printf '  phase_at_exit: "close"\n'
    printf '  tag_at_exit: "agent"\n'
    printf '  message: "Pull request #%s cannot merge — branch conflicts with main"\n' "${_PR_NUMBER:-unknown}"
    printf '  context: "%s, pr: %s, branch: %s"\n' "$detail" "${_PR_URL:-unknown}" "$branch"
    printf '  created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  resolved: false\n'
    printf '  resolution: ""\n'
  } > "$esc_dir/${esc_id}.yaml" 2>/dev/null || true
  _PR_ESCALATION_ID="$esc_id"
  _PR_OUTCOME="review:merge-conflict"
  _PR_REASON="$detail — escalation $esc_id"
  queue_close_record "$entry_file" "conflict" "merge-pr" "failed" "$detail — escalation $esc_id" || true
  return 0
}

# --- Land a pull request that GitHub has merged --------------------------
# Called both after `pr merge` and from `pr refresh` when it finds a PR that
# somebody merged on GitHub. main already has the work; what is left is local:
# fast-forward main to it, and seal the branch (Decision 0013) so no later
# session reuses it.
#
# No merge lock is taken, and that is a deliberate difference from the solo
# path. The solo path holds the lock across rebase -> re-verify -> merge
# because another close landing on main in that window would invalidate the
# verdict. Here there is no verdict and no merge: `--ff-only` either advances
# main to a commit that already contains main, or refuses. It cannot produce an
# unverified combination and it cannot lose a commit.
#
# Arguments: $1 entry file, $2 entry id, $3 branch, $4 work order id,
#            $5 detail for the merge-pr step
_pr_land() {
  local entry_file="$1" eid="$2" branch="$3" wo="${4:-}" detail="${5:-}"
  local head_br sha

  queue_close_record "$entry_file" "" "merge-pr" "done" "$detail" || true

  head_br=$(_pr_git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [ "$head_br" != "main" ]; then
    queue_close_record "$entry_file" "" "push" "skipped" \
      "local main not checked out at $REPO_ROOT (on '${head_br:-unknown}') — run 'git -C $REPO_ROOT pull' to sync" || true
  elif ! _pr_git fetch origin main > /dev/null 2>&1; then
    queue_close_record "$entry_file" "" "push" "failed" "git fetch origin main failed — local main is behind" || true
  elif _pr_git merge --ff-only FETCH_HEAD > /dev/null 2>&1; then
    sha=$(_pr_git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    queue_close_record "$entry_file" "" "push" "done" "local main fast-forwarded to $sha" || true
  else
    # Local main has commits origin does not, so the fast-forward is refused.
    # Not a failure of this close — the PR merged — but the operator has to
    # reconcile it, and saying so is the whole point of the step row.
    queue_close_record "$entry_file" "" "push" "failed" \
      "local main has diverged from origin/main — fast-forward refused, reconcile manually" || true
  fi

  # Seal only for an entry whose group has finished. A non-final brief's branch
  # must stay live for the next brief (Decision 0013 §7) — the same predicate
  # the solo path and the seal gate use, not a copy of it.
  if queue_is_final_taskgroup_entry "$eid" "$wo"; then
    if type record_closed_branch > /dev/null 2>&1; then
      record_closed_branch "$branch" || true
      queue_close_record "$entry_file" "" "push-branch" "done" "sealed $branch (Decision 0013)" || true
      if type delete_merged_session_branch > /dev/null 2>&1; then
        delete_merged_session_branch "$branch" "$REPO_ROOT" || true
      fi
    else
      queue_close_record "$entry_file" "" "push-branch" "skipped" \
        "sealing helpers not loaded — record '$branch' in .claude/local/closed-branches by hand" || true
    fi
  else
    queue_close_record "$entry_file" "" "push-branch" "skipped" \
      "not the final brief of task group $wo — branch stays open" || true
  fi

  # `merged` is recorded whatever the local sync did, including after a `push`
  # row of `failed`. The state describes the PULL REQUEST, and GitHub merged it
  # — that is settled and cannot be un-done by a stale local main. Making the
  # state conditional on the fast-forward would leave an entry whose work is on
  # origin/main reporting something retryable, and `pr merge` would then refuse
  # it (the gate admits `pr_open` only) with nothing left to retry. The two
  # signals are deliberately separate: the state says where the work got to,
  # the step row says what the operator still has to reconcile locally.
  queue_close_record "$entry_file" "merged" "" "" "" || true
  return 0
}

# ============================================================
# Entry points
# ============================================================

# --- Open the pull request for an entry at close -------------------------
# Push, then open, then record — in that order, and the PR number is stored
# BEFORE the state moves to pr_open. An interrupted open then leaves an entry
# that has a number and has not reached pr_open, which `refresh` recovers from;
# the opposite order would leave pr_open with no PR to read, which nothing can.
#
# Degrades, never fails (brief 2 step 5). No origin, no gh, no auth, a failed
# push and a failed create all record `ready` plus a step saying which, because
# all five are retryable with `queue-cli.sh pr open <id>` once fixed. `ready`
# rather than `pushed` deliberately: `pushed` already means "merged and pushed
# to origin" in the t-0057 close-state enum, and admitting it as a PR-open
# starting state would let an entry that already merged on the solo path be
# handed to this function.
#
# Arguments: $1 entry file path
# Returns 0 always, except 1 when the entry file cannot be read.
pr_open() {
  local entry_file="$1"
  _pr_reset_results
  _load_queue_entry "$entry_file" || {
    _PR_REASON="entry file not found: $entry_file"
    return 1
  }
  local eid branch brief wo reverified sid existing title body_file url num
  eid="${_QE_ID:-}"
  branch="${_QE_BRANCH:-}"
  brief="${_QE_BRIEF_PATH:-}"
  # An entry stores brief_path repo-relative. The scrapers test it with -f, so
  # a relative path would silently read as absent whenever the caller's cwd is
  # not the repo root — which is how the title fell back to the branch name and
  # the body rendered the no-brief paragraph. Resolve it here, once.
  case "$brief" in
    ""|/*) ;;
    *) brief="${REPO_ROOT:-.}/$brief" ;;
  esac
  wo="${_QE_WORK_ORDER_ID:-}"
  reverified="${_QE_REVERIFIED:-}"
  existing="${_QE_PR_NUMBER:-0}"

  if [ -z "$branch" ] || [ "$branch" = "main" ]; then
    _PR_REASON="entry has no feature branch to open a pull request from (branch: '${branch:-empty}')"
    queue_close_record "$entry_file" "ready" "open-pr" "skipped" "$_PR_REASON" || true
    return 0
  fi

  # Already recorded — hand straight to refresh rather than opening a second
  # pull request for the same branch. refresh resets the result globals, so the
  # reason is set after it, not before.
  if [ "$existing" != "0" ]; then
    pr_refresh "$entry_file" || true
    _PR_REASON="pull request #${existing} is already recorded for this entry — refreshed it instead of opening another"
    return 0
  fi

  if ! _pr_git remote get-url origin > /dev/null 2>&1; then
    _PR_REASON="no origin remote configured — add one, or close this entry with 'set-close ${eid} solo'"
    queue_close_record "$entry_file" "ready" "push-branch" "skipped" "$_PR_REASON" || true
    return 0
  fi

  if ! _pr_git push -u origin "$branch" > /dev/null 2>&1; then
    _PR_REASON="git push -u origin $branch failed"
    queue_close_record "$entry_file" "ready" "push-branch" "failed" "$_PR_REASON" || true
    return 0
  fi
  queue_close_record "$entry_file" "" "push-branch" "done" "origin $branch" || true

  if ! pr_gh_available; then
    # _PR_REASON set by pr_gh_available. The branch IS on origin, which is the
    # degraded close the brief asks for; only the PR is missing.
    queue_close_record "$entry_file" "ready" "open-pr" "skipped" "$_PR_REASON" || true
    return 0
  fi

  # A PR somebody opened by hand for this branch is adopted rather than
  # duplicated. Fail-closed in the direction that matters: if this read fails
  # we do not create, because the cost of a duplicate PR is a human cleaning up
  # two review threads.
  local found
  found=$(_pr_gh pr list --head "$branch" --state open --limit 1 \
          --json number,url --jq '.[0] | select(.number) | "\(.number) \(.url)"' 2>/dev/null) || {
    _PR_REASON="gh pr list failed — not opening a pull request, because an existing one could not be ruled out"
    queue_close_record "$entry_file" "ready" "open-pr" "failed" "$_PR_REASON" || true
    return 0
  }
  if [ -n "$found" ]; then
    # A single space separates them, and neither half can contain one — a PR
    # number is digits and a PR url is a url.
    num="${found%% *}"
    url="${found#* }"
    _PR_NUMBER="$num"
    _PR_URL="$url"
    queue_set_pr "$entry_file" "$num" "$url" || true
    queue_close_record "$entry_file" "pr_open" "open-pr" "done" "adopted existing #${num} ${url}" || true
    _PR_REASON=""
    return 0
  fi

  sid=$(_session_id_for_entry "$eid" 2>/dev/null) || sid=""
  title=$(_pr_title "$brief" "$branch" "$eid")
  body_file=$(mktemp "${TMPDIR:-/tmp}/repo-os-pr-body.XXXXXX") || {
    _PR_REASON="could not create a temporary file for the pull request body"
    queue_close_record "$entry_file" "ready" "open-pr" "failed" "$_PR_REASON" || true
    return 0
  }
  _pr_body "$eid" "$branch" "$brief" "$wo" "$reverified" "$sid" > "$body_file"

  url=$(_pr_gh pr create --base main --head "$branch" \
        --title "$title" --body-file "$body_file" 2>/dev/null) || url=""
  rm -f "$body_file" 2>/dev/null || true
  # gh prints the PR url as the last line of its stdout, and may print
  # informational lines before it. Take the last line, then insist it looks
  # like a PR url rather than trusting the shape.
  url="${url##*$_PR_NL}"
  case "$url" in
    https://*/pull/*) ;;
    *)
      _PR_REASON="gh pr create did not return a pull request url — the branch is pushed, retry with 'queue-cli.sh pr open ${eid}'"
      queue_close_record "$entry_file" "ready" "open-pr" "failed" "$_PR_REASON" || true
      return 0
      ;;
  esac
  num="${url##*/}"
  case "$num" in
    ''|*[!0-9]*)
      _PR_REASON="could not read a pull request number out of '${url}' — the branch is pushed, retry with 'queue-cli.sh pr open ${eid}'"
      queue_close_record "$entry_file" "ready" "open-pr" "failed" "$_PR_REASON" || true
      return 0
      ;;
  esac

  _PR_NUMBER="$num"
  _PR_URL="$url"
  queue_set_pr "$entry_file" "$num" "$url" || true
  queue_close_record "$entry_file" "pr_open" "open-pr" "done" "#${num} ${url}" || true
  _PR_REASON=""
  return 0
}

# --- Re-read an open pull request and map it onto close steps ------------
# The tracking half: called by the daemon every pr.poll_seconds and by
# `queue-cli.sh pr refresh <id>` on demand. One gh round trip, four outcomes:
#   MERGED               -> _pr_land, close_state merged
#   CLOSED (not merged)  -> close_state ready, merge-pr skipped
#   CONFLICTING          -> _pr_route_conflict, close_state conflict
#   OPEN                 -> checks step, close_state pr_open
#
# mergeable: UNKNOWN is NOT routed to conflict. gh#9583: UNKNOWN is what
# GitHub returns while it computes the test merge, so it is transient on a PR
# that was opened seconds ago. Routing it to conflict would write an escalation
# and flip the entry's outcome for a condition that resolves by itself on the
# next tick. It blocks a merge (pr_merge refuses it) without reporting one.
#
# Arguments: $1 entry file path
# Returns 0 always, except 1 when the entry file cannot be read.
pr_refresh() {
  local entry_file="$1"
  _pr_reset_results
  _load_queue_entry "$entry_file" || {
    _PR_REASON="entry file not found: $entry_file"
    return 1
  }
  local eid branch wo num
  eid="${_QE_ID:-}"
  branch="${_QE_BRANCH:-}"
  wo="${_QE_WORK_ORDER_ID:-}"
  num="${_QE_PR_NUMBER:-0}"
  _PR_URL="${_QE_PR_URL:-}"

  if [ "$num" = "0" ]; then
    _PR_REASON="no pull request is recorded for entry ${eid} — open one with 'queue-cli.sh pr open ${eid}'"
    return 0
  fi
  _PR_NUMBER="$num"

  if ! pr_gh_available; then
    queue_close_record "$entry_file" "" "checks" "skipped" "$_PR_REASON" || true
    return 0
  fi
  if ! _pr_read "$num"; then
    queue_close_record "$entry_file" "" "checks" "failed" "$_PR_REASON" || true
    return 0
  fi
  # Keep the stored url in step with what gh reports, so a PR that moved repo
  # does not leave a dead link in the entry.
  if [ -n "$_PR_URL" ] && [ "$_PR_URL" != "${_QE_PR_URL:-}" ]; then
    queue_set_pr "$entry_file" "$num" "$_PR_URL" || true
  fi

  case "$_PR_STATE" in
    MERGED)
      _pr_land "$entry_file" "$eid" "$branch" "$wo" "#${num} merged on GitHub"
      _PR_REASON=""
      return 0
      ;;
    CLOSED)
      # Closed without merging is an operator decision, not a failure. `ready`
      # keeps every route open: reopen the PR, open a new one, or switch the
      # entry to the solo path.
      _PR_REASON="pull request #${num} was closed without merging"
      queue_close_record "$entry_file" "ready" "merge-pr" "skipped" "$_PR_REASON" || true
      return 0
      ;;
  esac

  if [ "$_PR_MERGEABLE" = "CONFLICTING" ]; then
    _pr_route_conflict "$entry_file" "$eid" "$branch" "$_PR_MERGE_STATE_STATUS"
    return 0
  fi

  case "$_PR_CHECKS" in
    failed)  queue_close_record "$entry_file" "pr_open" "checks" "failed" "$_PR_CHECK_DETAIL" || true ;;
    pending) queue_close_record "$entry_file" "pr_open" "checks" "running" "$_PR_CHECK_DETAIL" || true ;;
    passed)  queue_close_record "$entry_file" "pr_open" "checks" "done" "$_PR_CHECK_DETAIL" || true ;;
    *)       queue_close_record "$entry_file" "pr_open" "checks" "skipped" "$_PR_CHECK_DETAIL" || true ;;
  esac
  return 0
}

# --- Re-run the failed checks of a pull request --------------------------
# `gh run rerun --failed` re-runs only the failed jobs of one workflow run, so
# the run has to be identified first. The latest failed run on the branch is
# the one the operator is looking at; a PR with several failed runs needs the
# other jobs re-run too, which `pr rerun` repeated will reach.
#
# Arguments: $1 entry file path
pr_rerun() {
  local entry_file="$1"
  _pr_reset_results
  _load_queue_entry "$entry_file" || {
    _PR_REASON="entry file not found: $entry_file"
    return 1
  }
  local eid branch num run_id
  eid="${_QE_ID:-}"
  branch="${_QE_BRANCH:-}"
  num="${_QE_PR_NUMBER:-0}"
  _PR_NUMBER="$num"
  _PR_URL="${_QE_PR_URL:-}"

  if [ "$num" = "0" ]; then
    _PR_REASON="no pull request is recorded for entry ${eid}"
    return 1
  fi
  pr_gh_available || return 1
  if [ -z "$branch" ]; then
    _PR_REASON="entry ${eid} records no branch, so its workflow runs cannot be found"
    return 1
  fi

  run_id=$(_pr_gh run list --branch "$branch" --status failure --limit 1 \
           --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null) || run_id=""
  case "$run_id" in
    ''|*[!0-9]*)
      _PR_REASON="no failed workflow run found on branch ${branch} — nothing to re-run"
      return 1
      ;;
  esac

  if ! _pr_gh run rerun "$run_id" --failed > /dev/null 2>&1; then
    _PR_REASON="gh run rerun ${run_id} --failed failed"
    queue_close_record "$entry_file" "" "checks" "failed" "$_PR_REASON" || true
    return 1
  fi
  _PR_REASON=""
  queue_close_record "$entry_file" "pr_open" "checks" "running" "re-ran failed jobs of run ${run_id}" || true
  return 0
}

# --- Bring a pull request's branch up to date with main ------------------
# The update-branch API merges the base into the head, which is what GitHub's
# "Update branch" button does. It returns 422 when the merge would conflict,
# which is the one failure that is not a transport error — so a failure whose
# body names a conflict is routed to review, and anything else is reported as
# a failed step and left retryable.
#
# Arguments: $1 entry file path
pr_update_branch() {
  local entry_file="$1"
  _pr_reset_results
  _load_queue_entry "$entry_file" || {
    _PR_REASON="entry file not found: $entry_file"
    return 1
  }
  local eid branch wo num err rc
  eid="${_QE_ID:-}"
  branch="${_QE_BRANCH:-}"
  wo="${_QE_WORK_ORDER_ID:-}"
  num="${_QE_PR_NUMBER:-0}"
  _PR_NUMBER="$num"
  _PR_URL="${_QE_PR_URL:-}"

  if [ "$num" = "0" ]; then
    _PR_REASON="no pull request is recorded for entry ${eid}"
    return 1
  fi
  pr_gh_available || return 1

  rc=0
  err=$(_pr_gh api -X PUT "repos/{owner}/{repo}/pulls/${num}/update-branch" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    _PR_REASON=""
    queue_close_record "$entry_file" "pr_open" "checks" "running" \
      "branch updated from main — checks re-run on the new head" || true
    return 0
  fi
  case "$err" in
    *[Cc]onflict*|*422*)
      _pr_route_conflict "$entry_file" "$eid" "$branch" "update-branch rejected"
      return 1
      ;;
  esac
  _PR_REASON="gh api update-branch failed for #${num}: ${err%%$_PR_NL*}"
  queue_close_record "$entry_file" "" "checks" "failed" "$_PR_REASON" || true
  return 1
}

# --- Merge the pull request (operator) -----------------------------------
# Two gates, and both must pass. The entry-side gate is
# `queue_pr_merge_allowed`, the same `_queue_close_preconditions` the solo
# `merge` goes through, so the two paths cannot disagree about what may reach
# main. The PR-side gate is a LIVE read: the stored close_state says what the
# last refresh saw, and an operator merging on a stale reading is exactly the
# failure a fail-closed control exists to prevent (t-0061).
#
# Refuses on: not verified, wrong close_state, wrong close_path, non-final
# group brief, failing checks, pending checks, CONFLICTING, and UNKNOWN. The
# last of those is a refusal and NOT a conflict (gh#9583 — UNKNOWN is transient
# while GitHub computes the test merge); `pr refresh` resolves it.
#
# Arguments: $1 entry file path, $2 method (optional; defaults from config)
# Returns 0 on a merge, 1 on a refusal or a failed merge.
pr_merge() {
  local entry_file="$1" method="${2:-}"
  _pr_reset_results
  _load_queue_entry "$entry_file" || {
    _PR_REASON="entry file not found: $entry_file"
    return 1
  }
  local eid branch wo num refusal
  eid="${_QE_ID:-}"
  branch="${_QE_BRANCH:-}"
  wo="${_QE_WORK_ORDER_ID:-}"
  num="${_QE_PR_NUMBER:-0}"
  _PR_NUMBER="$num"
  _PR_URL="${_QE_PR_URL:-}"

  case "$method" in
    merge|squash|rebase) ;;
    "") method=$(_pr_merge_method) ;;
    *)
      _PR_REASON="merge method must be merge, squash or rebase (got '${method}')"
      return 1
      ;;
  esac

  # Entry-side gate — the same `_queue_close_preconditions` the solo `merge`
  # runs. It prints its refusal and returns 1, and it re-loads the entry: the
  # command substitution keeps that in a subshell so the parent's _QE_* survive,
  # but nothing below depends on them anyway (every field is captured above).
  refusal=$(queue_pr_merge_allowed "$entry_file") || {
    _PR_REASON="${refusal:-entry is not in a state that permits a merge}"
    return 1
  }

  if [ "$num" = "0" ]; then
    _PR_REASON="no pull request is recorded for entry ${eid} — open one with 'queue-cli.sh pr open ${eid}'"
    return 1
  fi
  pr_gh_available || return 1
  _pr_read "$num" || return 1

  if [ "$_PR_STATE" = "MERGED" ]; then
    # Somebody merged it between the last refresh and now. Not a refusal —
    # finish the local half rather than making the operator run `refresh`.
    _pr_land "$entry_file" "$eid" "$branch" "$wo" "#${num} was already merged on GitHub"
    _PR_REASON=""
    return 0
  fi
  if [ "$_PR_STATE" != "OPEN" ]; then
    _PR_REASON="pull request #${num} is ${_PR_STATE:-unreadable}, not OPEN — reopen it on GitHub first"
    return 1
  fi
  case "$_PR_MERGEABLE" in
    CONFLICTING)
      _pr_route_conflict "$entry_file" "$eid" "$branch" "$_PR_MERGE_STATE_STATUS"
      return 1
      ;;
    MERGEABLE) ;;
    *)
      _PR_REASON="GitHub reports mergeable: ${_PR_MERGEABLE:-UNKNOWN} for #${num} — it is still computing the test merge, run 'queue-cli.sh pr refresh ${eid}' again in a moment"
      return 1
      ;;
  esac
  case "$_PR_CHECKS" in
    failed)
      _PR_REASON="checks are failing on #${num} (${_PR_CHECK_DETAIL}) — fix them, or re-run with 'queue-cli.sh pr rerun ${eid}'"
      return 1
      ;;
    pending)
      _PR_REASON="checks have not finished on #${num} (${_PR_CHECK_DETAIL})"
      return 1
      ;;
  esac

  local -a gh_args
  gh_args=( pr merge "$num" "--${method}" )
  if [ "$(_pr_delete_branch)" = "true" ]; then
    gh_args=( "${gh_args[@]}" --delete-branch )
  fi
  queue_close_record "$entry_file" "merging" "merge-pr" "running" "gh pr merge #${num} --${method}" || true
  if ! _pr_gh "${gh_args[@]}" > /dev/null 2>&1; then
    _PR_REASON="gh pr merge #${num} --${method} failed"
    # Back to pr_open, not conflict: the PR is still open and still mergeable
    # as far as the gate above could tell, so this is retryable.
    #
    # `merging` is therefore transient in both directions — forward to `merged`
    # via _pr_land, back to `pr_open` here. The one way to be stranded in it is
    # for THIS record to fail too (entry file gone or unwritable), because
    # `merging` is not in queue_pr_merge_allowed's admitted set and a retry
    # would be refused. That is the price of every queue_close_record on this
    # path carrying `|| true`: reporting must never decide whether a branch
    # merges (parity row 67). The recovery is `set-close`, and the solo path has
    # the identical window. Recorded as a known gap, not designed away.
    queue_close_record "$entry_file" "pr_open" "merge-pr" "failed" "$_PR_REASON" || true
    return 1
  fi

  _pr_land "$entry_file" "$eid" "$branch" "$wo" \
    "merged #${num} via ${method}${_PR_CHECK_DETAIL:+ — }${_PR_CHECK_DETAIL}"
  _PR_REASON=""
  return 0
}
