#!/usr/bin/env bash
# Cross-platform file watcher wrapper for editor-live sessions.
# Watches a status file for changes using fswatch (preferred) or inotifywait (fallback).
#
# Usage: editor-watch.sh <status-file-path>
# Output (stdout): "event" | "timeout" | "no_watcher"
# Timeout: 300 seconds (5 minutes)
#
# Decision 0023 — Editor-Live Session Type

set -euo pipefail

STATUS_FILE="${1:-}"
if [ -z "$STATUS_FILE" ]; then
  echo "no_watcher"
  exit 0
fi

TIMEOUT=300

# Exclude patterns for editor temp files
EXCLUDES_FSWATCH=(
  --exclude '\.swp$'
  --exclude '~$'
  --exclude '\.DS_Store$'
  --exclude '___jb_tmp___'
  --exclude '\.git/'
  --exclude '4913$'
)

EXCLUDES_INOTIFY='\.swp$|~$|\.DS_Store$|___jb_tmp___|\.git/|4913$'

# --- fswatch (preferred — macOS + Linux) ---
if command -v fswatch >/dev/null 2>&1; then
  # Prefer watching the status file directly when it exists — avoids noisy
  # events from unrelated files (builds, installs) in the parent directory.
  # Fall back to the parent dir only if the status file isn't on disk yet.
  if [ -e "$STATUS_FILE" ]; then
    WATCH_TARGET="$STATUS_FILE"
  else
    WATCH_TARGET="$(dirname "$STATUS_FILE")"
  fi

  # fswatch with one-event flag exits after first event
  # Use timeout to enforce the 5-minute limit
  if timeout "$TIMEOUT" fswatch --one-event \
    "${EXCLUDES_FSWATCH[@]}" \
    --event Created --event Updated --event Renamed --event Removed \
    "$WATCH_TARGET" >/dev/null 2>&1; then
    echo "event"
    exit 0
  else
    EXIT_CODE=$?
    # timeout returns 124 on timeout
    if [ "$EXIT_CODE" -eq 124 ]; then
      echo "timeout"
      exit 0
    fi
    # Other error — treat as event (conservative: let the agent check)
    echo "event"
    exit 0
  fi
fi

# --- inotifywait fallback (Linux) ---
if command -v inotifywait >/dev/null 2>&1; then
  if [ -e "$STATUS_FILE" ]; then
    WATCH_TARGET="$STATUS_FILE"
  else
    WATCH_TARGET="$(dirname "$STATUS_FILE")"
  fi

  if inotifywait -q -t "$TIMEOUT" \
    --exclude "$EXCLUDES_INOTIFY" \
    -e modify -e create -e moved_to \
    "$WATCH_TARGET" >/dev/null 2>&1; then
    echo "event"
    exit 0
  else
    EXIT_CODE=$?
    # inotifywait returns 2 on timeout
    if [ "$EXIT_CODE" -eq 2 ]; then
      echo "timeout"
      exit 0
    fi
    # Other error — treat as event (conservative)
    echo "event"
    exit 0
  fi
fi

# --- No watcher available ---
echo "no_watcher"
exit 0
