#!/usr/bin/env bash
# install-hooks.sh — Installs git hooks from .claude/.automation/git-hooks/
# into .git/hooks/. Safe to re-run (overwrites existing hooks from this source).
#
# Usage: .claude/.automation/lib/install-hooks.sh
#
# Only runs in template mode (child repos don't need the pre-push sync hook).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SOURCE_DIR="$REPO_ROOT/.claude/.automation/git-hooks"
TARGET_DIR="$REPO_ROOT/.git/hooks"

# Verify template mode
MODE_FILE="$REPO_ROOT/.claude/repo-mode"
MODE="child"
[ -f "$MODE_FILE" ] && MODE=$(head -1 "$MODE_FILE" | tr -d '[:space:]')

if [ "$MODE" != "template" ]; then
  echo "Skipping hook install — only needed in template mode (current: $MODE)"
  exit 0
fi

# Install hooks
installed=0
for hook in "$SOURCE_DIR"/*; do
  [ -f "$hook" ] || continue
  name=$(basename "$hook")
  cp "$hook" "$TARGET_DIR/$name"
  chmod +x "$TARGET_DIR/$name"
  echo "Installed: .git/hooks/$name"
  installed=$((installed + 1))
done

echo "Done — $installed hook(s) installed"
