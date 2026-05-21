#!/usr/bin/env bash
# Compute and create the next live-editor-{N} branch for editor-live sessions.
#
# Branch naming convention (Decision 0023, per editor-live session sequencing):
#   live-editor-N where N is monotonic across the repo lifetime.
#
# Behavior:
#   1. Fetches from all remotes (best-effort; warns and continues on failure)
#   2. Re-init guard: if the current branch already matches ^live-editor-[0-9]+$,
#      prints the current name and exits 0 (no new branch created)
#   3. Scans local and remote refs for the highest existing live-editor-N
#   4. Creates live-editor-$((max+1)) via git checkout -b
#   5. On checkout collision (race), retries once with N+2 then fails
#
# Output: branch name on stdout, advisory messages on stderr.
# Exit codes: 0 = success, 1 = unrecoverable.

set -euo pipefail

# --- Re-init guard ---
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [[ "$CURRENT_BRANCH" =~ ^live-editor-[0-9]+$ ]]; then
  printf '%s\n' "$CURRENT_BRANCH"
  exit 0
fi

# --- Fetch remotes (best-effort) ---
if ! git fetch --all --quiet 2>/dev/null; then
  echo "Advisory: git fetch --all failed — scanning local refs only. Fresh-clone collision risk." >&2
fi

# --- Scan for max N across local + remote branches ---
# `grep` exits 1 when no matches — guard the pipeline so set -e/pipefail
# do not abort. Empty result is the legitimate "start at 1" case.
MAX_N=$(git branch -a 2>/dev/null | grep -oE 'live-editor-[0-9]+' || true)
MAX_N=$(printf '%s\n' "$MAX_N" | sed 's/live-editor-//' | sort -n | tail -1)
: "${MAX_N:=0}"

# Guard against non-numeric residue from parse failure
case "$MAX_N" in
  ''|*[!0-9]*) MAX_N=0 ;;
esac

NEXT_N=$((MAX_N + 1))
TARGET="live-editor-$NEXT_N"

# --- Create branch (with one retry on collision) ---
if git checkout -b "$TARGET" 2>/dev/null; then
  printf '%s\n' "$TARGET"
  exit 0
fi

# Collision (race or stale ref): retry once with N+2
RETRY_N=$((MAX_N + 2))
RETRY_TARGET="live-editor-$RETRY_N"
if git checkout -b "$RETRY_TARGET"; then
  printf '%s\n' "$RETRY_TARGET"
  exit 0
fi

exit 1
