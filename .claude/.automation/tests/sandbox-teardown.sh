#!/usr/bin/env bash
# Adversarial sandbox teardown — standalone cleanup for orphaned sandboxes.
# Usage: bash sandbox-teardown.sh [/tmp/repo-os-adv-XXXXXX]
# Without arguments, cleans all /tmp/repo-os-adv-* directories.

set -euo pipefail

cleanup_path() {
  local path="$1"
  case "$path" in
    /tmp/repo-os-adv-*|/private/tmp/repo-os-adv-*)
      if [ -d "$path" ]; then
        rm -rf "$path"
        echo "Cleaned: $path"
      fi
      ;;
    *)
      echo "SKIP: Not a valid sandbox path: $path" >&2
      ;;
  esac
}

if [ $# -gt 0 ]; then
  cleanup_path "$1"
else
  # Clean all orphaned sandboxes (always /tmp/, not TMPDIR)
  found=0
  for d in /tmp/repo-os-adv-*; do
    [ -d "$d" ] || continue
    cleanup_path "$d"
    found=1
  done
  if [ "$found" -eq 0 ]; then
    echo "No orphaned sandboxes found."
  fi
fi
