#!/usr/bin/env bash
# Stale task group worktree sweep (Decision 0054).
#
# A sequential task group keeps ONE worktree for the whole life of its branch
# (`.worktrees/tg-<group>`), so the per-session removal that Decision 0033 does
# on every exit is deliberately suppressed for it. That makes a sweep necessary:
# the terminal removal paths (final brief sealed, work order failed/abandoned)
# cover the runner, but a group whose last brief ran interactively — or whose
# runner died before reaching a terminal path — would otherwise leave its
# worktree behind forever.
#
# A group worktree is stale when it is no longer in use AND one of:
#   - its branch is in the closed-branches ledger (the group finished and sealed)
#   - its branch no longer exists (deleted after merge, per Decision 0045)
#   - it has had no commit for longer than the stale threshold (7 days)
#
# "No longer in use" is two independent checks, both of which must pass:
#   - no live session in the registry is on that branch
#   - no live holder owns the group's occupancy lock
# The lock check is what makes the sweep safe to run from daemon startup while
# another session is mid-brief in the same worktree.
#
# Removal is destructive, unlike `_detect_orphan_branches()` which only
# escalates. The asymmetry is deliberate: a branch may hold unmerged commits an
# operator still needs, whereas a group worktree holds only a checkout plus
# gitignored build state, all of which is reproducible from the branch.
#
# Depends on (must be sourced before this file):
#   _analytics-helper.sh  — get_main_repo_root
#   _cleanup-helper.sh    — group_worktree_path, remove_group_worktree,
#                           _group_worktree_lock_dir, group_worktree_branch,
#                           is_registered_worktree
# Requires: REPO_ROOT

# --- Is a group's occupancy lock held by a live process? ---
# Arguments:
#   $1 — group name
# Returns: 0 when a live holder owns the lock, 1 otherwise
_group_worktree_lock_is_live() {
  local group="${1:-}"
  local lock_dir
  lock_dir=$(_group_worktree_lock_dir "$group" 2>/dev/null) || return 1
  [ -d "$lock_dir" ] || return 1
  local lock_pid
  lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
  [ -n "$lock_pid" ] || return 1
  kill -0 "$lock_pid" 2>/dev/null
}

# --- Is any live registered session on this branch? ---
# Arguments:
#   $1 — branch name
# Returns: 0 when a live session is on the branch, 1 otherwise
_branch_has_live_session() {
  local branch="${1:-}"
  [ -n "$branch" ] || return 1
  local sessions_dir="$REPO_ROOT/.claude/.state/sessions"
  [ -d "$sessions_dir" ] || return 1
  local _sf _spid _sbr
  for _sf in "$sessions_dir"/*.yaml; do
    [ -f "$_sf" ] || continue
    _sbr=$(grep '^branch: ' "$_sf" 2>/dev/null | sed 's/^branch: *//' || true)
    [ "$_sbr" = "$branch" ] || continue
    _spid=$(grep '^pid: ' "$_sf" 2>/dev/null | sed 's/^pid: *//' || true)
    if [ -n "$_spid" ] && kill -0 "$_spid" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# --- Sweep stale task group worktrees ---
# Output: count of removed worktrees on stdout
# Configurable: GROUP_WORKTREE_STALE_DAYS (default 7)
sweep_stale_group_worktrees() {
  local removed=0
  local wt_root="$REPO_ROOT/.worktrees"
  if [ ! -d "$wt_root" ]; then
    echo "0"
    return 0
  fi

  local closed_file="$REPO_ROOT/.claude/local/closed-branches"
  local stale_days="${GROUP_WORKTREE_STALE_DAYS:-7}"
  local stale_secs=$(( stale_days * 86400 ))
  local now_epoch
  now_epoch=$(date +%s)

  local entry base group wt_dir branch
  for entry in "$wt_root"/tg-*; do
    # Only directories named tg-* are group worktrees. Per-session worktrees
    # (Decision 0033) are named by session id and must never be touched here.
    [ -d "$entry" ] || continue
    base="${entry##*/}"
    group="${base#tg-}"
    [ -n "$group" ] || continue

    # Resolve through the helper rather than trusting the glob, so a path the
    # helper would not produce is never removed by this sweep.
    wt_dir=$(group_worktree_path "$group" 2>/dev/null) || continue
    [ "$wt_dir" = "$entry" ] || continue

    # In use → keep. Checked before any staleness reason so a mid-brief session
    # is never swept out from under itself.
    if _group_worktree_lock_is_live "$group"; then
      continue
    fi

    branch=$(group_worktree_branch "$wt_dir")
    if [ -n "$branch" ] && _branch_has_live_session "$branch"; then
      continue
    fi

    local reason=""

    # An unregistered directory at a group worktree path is debris from a hard
    # crash — nothing reproducible is lost by clearing it.
    if ! is_registered_worktree "$wt_dir"; then
      reason="not a registered worktree"
    elif [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
      reason="detached or missing branch"
    elif ! git -C "$REPO_ROOT" rev-parse --verify "$branch" > /dev/null 2>&1; then
      reason="branch '$branch' no longer exists"
    elif [ -f "$closed_file" ] && grep -qxF "$branch" "$closed_file" 2>/dev/null; then
      reason="branch '$branch' is sealed"
    else
      local last_commit_epoch age_secs
      last_commit_epoch=$(git -C "$REPO_ROOT" log -1 --format=%ct "$branch" 2>/dev/null || echo "0")
      age_secs=$(( now_epoch - last_commit_epoch ))
      if [ "$age_secs" -ge "$stale_secs" ]; then
        reason="no commit on '$branch' for $(( age_secs / 86400 )) days"
      fi
    fi

    [ -n "$reason" ] || continue

    if remove_group_worktree "$group" "$$" "" 2>/dev/null; then
      echo "cleanup: removed stale group worktree tg-$group ($reason)" >&2
      removed=$((removed + 1))
    fi
  done

  echo "$removed"
}
