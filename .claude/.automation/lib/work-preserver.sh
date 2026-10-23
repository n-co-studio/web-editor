#!/usr/bin/env bash
# Work preserver — keep a dying session's uncommitted work before its worktree
# is removed. Sourced by runner.sh. NOT executed standalone. Decision t-0062.
#
# Why this exists: on 2026-10-21 a brief ran 80 minutes, ended
# `review:dirty-noop` (the outcome that exists to say "there is uncommitted
# work, send it to an operator"), and the runner then `git worktree remove
# --force`d the tree. Four modified files were gone; the entry sat in review/
# inviting an operator to inspect something that no longer existed.
#
# The shape: CAPTURE, then REMOVE. The worktree is never kept (keeping it is
# what wedged the task-details-header group); the patch is the artifact.
#
# Design points, each of which has a failure behind it:
#   - The patch is built from a THROWAWAY index (`read-tree HEAD` + `add -A`),
#     not `git diff HEAD`. `diff HEAD` omits untracked files, and a session's new
#     test file is exactly the untracked file. A throwaway index also leaves the
#     worktree's real index untouched, and honours .gitignore.
#   - Capture happens only when BOTH hold: no commits since the baseline, and
#     the tree is dirty. A session that committed keeps its work on its branch;
#     a clean tree has nothing to keep. That is what stops this being a blanket
#     snapshot of every exit — no outcome-string gate is needed, and none is used
#     because one would silently drop untracked-only work (outcome-detector's
#     dirty check ignores untracked files, so such a session classifies as
#     `completed:clean-noop`).
#   - Nothing here may fail the close. Every step is guarded; a failed write
#     warns and returns 0, so a full disk degrades a reviewable failure into a
#     warning rather than into a crash. Removal proceeds regardless.
#   - Written under $AUTOMATION_DIR/reports/ (gitignored, swept by
#     cleanup.sh `report_days`), NEVER inside the worktree being removed — a
#     patch stored in the worktree would be destroyed with it.
#
# Depends on: git. Reads AUTOMATION_DIR (falls back to REPO_ROOT/.claude/.automation).
#
# Bash 3.2 compatible.

# Set by preserve_uncommitted_work: absolute path of the patch just written, or ""
# when nothing was captured. Callers read it from the main shell — do NOT call
# the function inside $(...), the assignment would die with the subshell.
_PRESERVED_PATCH_PATH=""

# --- Capture uncommitted work from a worktree ---
# Arguments:
#   $1 — worktree directory
#   $2 — baseline sha (HEAD when the session launched; empty → capture if dirty)
#   $3 — queue entry id (names the patch; "unknown" if empty)
#   $4 — outcome string, e.g. "review:dirty-noop" (recorded in the header)
# Sets _PRESERVED_PATCH_PATH. Always returns 0.
preserve_uncommitted_work() {
  local wt="${1:-}" baseline="${2:-}" entry_id="${3:-}" outcome="${4:-unknown}"
  _PRESERVED_PATCH_PATH=""

  [ -n "$wt" ] && [ -d "$wt" ] || return 0

  # A session that committed keeps its work on its branch. If the commit count
  # cannot be determined (missing/bad baseline), fall through and capture:
  # preserving something redundant is cheaper than losing something.
  if [ -n "$baseline" ]; then
    local _n=""
    _n=$(git -C "$wt" rev-list --count "$baseline..HEAD" 2>/dev/null) || _n=""
    case "$_n" in
      ''|*[!0-9]*) ;;
      *) [ "$_n" -eq 0 ] || return 0 ;;
    esac
  fi

  # Dirty = anything `status` reports, untracked non-ignored included.
  local _status=""
  _status=$(git -C "$wt" status --short 2>/dev/null) || _status=""
  [ -n "$_status" ] || return 0

  local _auto="${AUTOMATION_DIR:-${REPO_ROOT:-}/.claude/.automation}"
  local _dir="$_auto/reports"
  if ! mkdir -p "$_dir" 2>/dev/null; then
    echo "WARNING: work-preserver: cannot create $_dir — uncommitted work in $wt NOT preserved" >&2
    return 0
  fi

  local _safe_id
  _safe_id=$(printf '%s' "${entry_id:-unknown}" | tr -c 'A-Za-z0-9._-' '_')
  [ -n "$_safe_id" ] || _safe_id="unknown"
  # Timestamped: a retried entry must not overwrite the previous attempt's patch.
  local _stamp
  _stamp=$(date +%Y%m%d-%H%M%S 2>/dev/null) || _stamp="0"
  local _final="$_dir/preserved-work-${_safe_id}-${_stamp}.patch"
  local _tmp="${_final}.tmp.$$"
  local _tmpidx
  _tmpidx=$(mktemp "${TMPDIR:-/tmp}/work-preserver-idx.XXXXXX" 2>/dev/null) || _tmpidx=""
  if [ -z "$_tmpidx" ]; then
    echo "WARNING: work-preserver: mktemp failed — uncommitted work in $wt NOT preserved" >&2
    return 0
  fi
  # git must create the index itself; an existing zero-byte file is not one.
  rm -f "$_tmpidx" 2>/dev/null || true

  local _branch
  _branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null) || _branch="unknown"
  local _head
  _head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || _head="unknown"

  # Header first, as '#' lines. `git apply` ignores text before the first
  # `diff --git`, so the file is both a record and a usable patch.
  local _ok=true
  {
    printf '# PRESERVED UNCOMMITTED WORK — NOT REVIEWED, NOT GATE-CHECKED\n'
    printf '# The session ended without committing. This is a raw snapshot of its\n'
    printf '# working tree, taken by the runner before the worktree was removed.\n'
    printf '# entry:       %s\n' "${entry_id:-unknown}"
    printf '# outcome:     %s\n' "$outcome"
    printf '# branch:      %s\n' "$_branch"
    printf '# base (HEAD): %s\n' "$_head"
    printf '# captured_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    printf '# git status --short at capture:\n'
    printf '%s\n' "$_status" | while IFS= read -r _l; do printf '#   %s\n' "$_l"; done
    printf '# To inspect: git apply --stat <this file>\n'
    printf '# To use:     git checkout %s && git apply <this file>\n' "$_head"
    printf '#\n'
  } > "$_tmp" 2>/dev/null || _ok=false

  if [ "$_ok" = true ]; then
    # Subshell so GIT_INDEX_FILE cannot leak into the runner's own git calls.
    (
      export GIT_INDEX_FILE="$_tmpidx"
      git -C "$wt" read-tree HEAD >/dev/null 2>&1 || exit 1
      git -C "$wt" add -A >/dev/null 2>&1 || exit 1
      git -C "$wt" diff --cached --binary HEAD
    ) >> "$_tmp" 2>/dev/null || _ok=false
  fi
  rm -f "$_tmpidx" 2>/dev/null || true

  # No diff body (e.g. status noise `add -A` normalises away) → nothing to keep.
  if [ "$_ok" = true ] && ! grep -q '^diff --git ' "$_tmp" 2>/dev/null; then
    rm -f "$_tmp" 2>/dev/null || true
    return 0
  fi

  if [ "$_ok" = true ] && mv "$_tmp" "$_final" 2>/dev/null; then
    _PRESERVED_PATCH_PATH="$_final"
    echo "Preserved uncommitted work for entry ${entry_id:-unknown} ($outcome): $_final" >&2
  else
    rm -f "$_tmp" 2>/dev/null || true
    echo "WARNING: work-preserver: could not write patch for entry ${entry_id:-unknown} — uncommitted work in $wt NOT preserved" >&2
  fi
  return 0
}

# --- Capture (when warranted), then remove a per-session worktree ---
# The single removal path for per-session worktrees: a bare `git worktree
# remove --force` of the session worktree elsewhere in runner.sh is a regression
# (test-work-preserver.sh greps for it). Removal always proceeds, whatever the
# capture did.
# Arguments:
#   $1 — worktree directory
#   $2 — baseline sha
#   $3 — queue entry id
#   $4 — outcome string (recorded in the patch header)
# Sets _PRESERVED_PATCH_PATH. Always returns 0.
remove_session_worktree() {
  local wt="${1:-}" baseline="${2:-}" entry_id="${3:-}" outcome="${4:-unknown}"
  _PRESERVED_PATCH_PATH=""
  [ -n "$wt" ] || return 0
  preserve_uncommitted_work "$wt" "$baseline" "$entry_id" "$outcome" || true
  git worktree remove --force "$wt" 2>/dev/null || true
  git worktree prune 2>/dev/null || true
  return 0
}

# --- The sentence recorded where the operator will look ---
# Arguments:
#   $1 — patch path ("" → prints nothing)
#   $2 — repo root (to make the path relative; queue entries are read from it)
# Output: a sentence for a queue entry's error_log / an escalation context. It
# carries no leading separator, so callers join it ("<outcome>; <note>"). It must
# never contain '|': queue-reporter.sh's review_items emits pipe-delimited rows
# that queue-cli.sh splits with IFS='|', and an extra '|' shifts every later field.
preserved_work_note() {
  local patch="${1:-}" root="${2:-}"
  [ -n "$patch" ] || return 0
  local rel="$patch"
  if [ -n "$root" ]; then rel="${patch#"$root"/}"; fi
  printf 'uncommitted work preserved as a patch (NOT reviewed, NOT gate-checked; worktree removed): %s -- see blocker-playbook.md section 5' "$rel"
}
