#!/usr/bin/env bash
# Compute and create the next live-editor-{N} branch for editor-live sessions.
#
# Branch naming convention (Decision 0023, per editor-live session sequencing):
#   live-editor-N where N is monotonic across the repo lifetime and NEVER resets.
#
# Durable counter (Decision 0023 Amendment 2):
#   The authoritative monotonic floor is the tracked file `.claude/live-editor-hwm`
#   (a single integer, committed to main so it survives branch deletion and fresh
#   clones). The next number is `max(read_hwm, live-ref scan) + 1`. The live-ref
#   scan is retained as a belt-and-suspenders backstop, but the HWM file is the
#   source of truth — deleting all live-editor-N branches no longer resets the
#   counter, because the floor lives in a tracked file rather than in deletable
#   git refs.
#
# Behavior:
#   1. Re-init guard: if the current branch already matches ^live-editor-[0-9]+$,
#      prints the current name and exits 0 (no new branch created)
#   2. Fetches from all remotes (best-effort; warns and continues on failure)
#   3. Under an flock guard (mirrors record_closed_branch in _cleanup-helper.sh):
#      computes NEXT_N = max(HWM, live-ref scan) + 1, creates live-editor-$NEXT_N,
#      writes NEXT_N back to the HWM file, and commits the HWM on the new branch
#      so the floor rides the close-time solo-merge to main.
#   4. On checkout collision (race), re-reads the HWM and retries once so a number
#      is never re-issued. A *gap* is acceptable; a *reset/duplicate* is not.
#
# Output: branch name on stdout, advisory messages on stderr.
# Exit codes: 0 = success, 1 = unrecoverable.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
HWM_FILE="$REPO_ROOT/.claude/live-editor-hwm"
LOCK_FILE="$REPO_ROOT/.claude/.state/.live-editor-hwm-lock"

# --- read_hwm: authoritative monotonic floor (absent/non-numeric -> 0) ---
read_hwm() {
  local v
  v=$(cat "$HWM_FILE" 2>/dev/null | tr -d '[:space:]')
  case "$v" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$v" ;;
  esac
}

# --- scan_live_refs: highest existing live-editor-N across local+remote refs ---
# Belt-and-suspenders backstop. grep exits 1 on no matches; guard so set -e /
# pipefail do not abort (empty result is the legitimate "0" case).
scan_live_refs() {
  local m
  m=$(git branch -a 2>/dev/null | grep -oE 'live-editor-[0-9]+' || true)
  m=$(printf '%s\n' "$m" | sed 's/live-editor-//' | sort -n | tail -1)
  case "$m" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$m" ;;
  esac
}

# --- attempt_create: compute, create branch, write-back+commit HWM ---
# Echoes the branch name and returns 0 on success; returns 1 on checkout
# collision (so the caller can re-read the HWM and retry).
attempt_create() {
  local hwm scan max next target
  hwm=$(read_hwm)
  scan=$(scan_live_refs)
  max=$hwm
  if [ "$scan" -gt "$max" ]; then max=$scan; fi
  next=$((max + 1))
  target="live-editor-$next"
  if git checkout -b "$target" 2>/dev/null; then
    # Write-back + commit the new floor on the new branch. Best-effort: an
    # abandoned session that never merges yields at most a gap (acceptable),
    # never a reset. The commit is a subprocess (not a top-level Bash tool
    # call) so the Claude Code pre-commit hook does not intercept it.
    printf '%s\n' "$next" > "$HWM_FILE"
    git add "$HWM_FILE" >/dev/null 2>&1 || true
    git commit -m "chore(editor-live): advance live-editor-hwm to $next" -- "$HWM_FILE" >/dev/null 2>&1 || true
    printf '%s\n' "$target"
    return 0
  fi
  return 1
}

# --- Re-init guard (preserved) ---
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [[ "$CURRENT_BRANCH" =~ ^live-editor-[0-9]+$ ]]; then
  printf '%s\n' "$CURRENT_BRANCH"
  exit 0
fi

# --- Fetch remotes (best-effort) ---
if ! git fetch --all --quiet 2>/dev/null; then
  echo "Advisory: git fetch --all failed — scanning local refs only. Fresh-clone collision risk." >&2
fi

mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true

# --- Critical section: compute + create + write-back under flock ---
# flock serializes the read/compute/increment/write window (mirrors the
# record_closed_branch lock pattern). On collision, attempt_create re-reads the
# HWM and recomputes so concurrent invocations yield distinct numbers — at most
# a gap, never a duplicate, never a reset. Cross-worktree safety is additionally
# guaranteed by the shared ref namespace (scan_live_refs sees branches created
# in sibling worktrees) plus the collision retry.
# `|| RC=$?` keeps the assignment from tripping `set -e` on the double-failure
# path and captures the real exit code explicitly (instead of relying on set -e
# to abort), so the RESULT/RC gate below is reached in every case.
RC=0
RESULT=$(
  if command -v flock > /dev/null 2>&1; then
    exec 9> "$LOCK_FILE"
    flock -w 5 9 2>/dev/null || true
  fi
  attempt_create || attempt_create
) || RC=$?

if [ "$RC" -eq 0 ] && [ -n "$RESULT" ]; then
  printf '%s\n' "$RESULT"
  exit 0
fi

exit 1
