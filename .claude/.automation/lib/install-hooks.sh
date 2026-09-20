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

# Install hooks.
#
# Mode policy: the blanket "template mode only" gate that used to sit here was
# correct when git-hooks/ held nothing but pre-push (the template→child sync
# trigger, which is meaningless in a child repo). It is wrong for safety hooks:
# the pre-commit secret scan protects every committer in every repo, and child
# repos need it at least as much as the template does. Gate per-hook instead.
# Resolve the real hooks directory before copying anything.
# .git is a FILE (a gitdir: pointer) in worktrees and submodules, so
# "$REPO_ROOT/.git/hooks" does not exist there — a blind cp would abort this
# script under `set -e`. And when core.hooksPath is configured, git ignores
# .git/hooks entirely, so installing there would report success for a hook
# that can never run.
# --path-format=absolute needs git 2.31+; this repo runs 2.19, where the flag
# is echoed back as output instead of parsed. Use --git-path (git 2.5+) and
# make it absolute by hand.
TARGET_DIR="$(git -C "$REPO_ROOT" rev-parse --git-path hooks 2>/dev/null || echo ".git/hooks")"
case "$TARGET_DIR" in
  /*) ;;
  *)  TARGET_DIR="$REPO_ROOT/$TARGET_DIR" ;;
esac

_CONFIGURED_HOOKS_PATH="$(git -C "$REPO_ROOT" config --get core.hooksPath 2>/dev/null || true)"
if [ -n "$_CONFIGURED_HOOKS_PATH" ]; then
  case "$_CONFIGURED_HOOKS_PATH" in
    /*) TARGET_DIR="$_CONFIGURED_HOOKS_PATH" ;;
    *)  TARGET_DIR="$REPO_ROOT/$_CONFIGURED_HOOKS_PATH" ;;
  esac
  echo "Note: core.hooksPath is set — installing into $TARGET_DIR"
fi

if ! mkdir -p "$TARGET_DIR" 2>/dev/null; then
  echo "ERROR: cannot create hooks directory at $TARGET_DIR" >&2
  exit 1
fi

installed=0
skipped=0
for hook in "$SOURCE_DIR"/*; do
  [ -f "$hook" ] || continue
  name=$(basename "$hook")

  # pre-push spawns the child-sync pipeline — template mode only.
  if [ "$name" = "pre-push" ] && [ "$MODE" != "template" ]; then
    echo "Skipped:   .git/hooks/pre-push (template mode only; current: $MODE)"
    skipped=$((skipped + 1))
    continue
  fi

  cp "$hook" "$TARGET_DIR/$name"
  chmod +x "$TARGET_DIR/$name"
  echo "Installed: .git/hooks/$name"
  installed=$((installed + 1))
done

echo "Done — $installed hook(s) installed, $skipped skipped"
