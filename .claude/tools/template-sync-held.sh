#!/usr/bin/env bash
# template-sync-held.sh — show or apply a template update the sync held back.
#
# A child whose .claude/template-sync-mode says hold gets template updates on
# the branch template-sync/held, one commit on top of main, instead of on main
# (Decision t-0084). This is how the operator reads and takes them.
#
# Usage:
#   template-sync-held.sh status   show the held update and its changed files
#   template-sync-held.sh apply    fast-forward main to the held update
#
# apply needs main checked out with a clean tree. It does not push: it prints
# the push command. It refuses when main has moved since the update was held;
# running the Template Sync workflow again rebuilds the held branch from the
# new main. After the push, the next sync finds nothing to hold and deletes the
# branch.
#
# Exit codes: 0 done (or nothing held), 1 refused or failed, 2 usage
set -uo pipefail

HELD_BRANCH="template-sync/held"

_usage() { sed -n '8,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
_die() { echo "template-sync-held: $*" >&2; exit 1; }

cmd="${1:-}"
case "$cmd" in status|apply) ;; *) _usage ;; esac
[ $# -eq 1 ] || _usage

root=$(git rev-parse --show-toplevel 2>/dev/null) || _die "not inside a git repository"
cd "$root" || _die "cannot enter $root"

# Fetch the held commit into FETCH_HEAD, leaving no ref behind. Sets $held, or
# leaves it empty when origin has no held branch.
held=""
_fetch_held() {
  local remote
  remote=$(git ls-remote origin "refs/heads/$HELD_BRANCH") || _die "could not read origin"
  [ -n "$remote" ] || return 0
  git fetch -q origin "refs/heads/$HELD_BRANCH" || _die "could not fetch $HELD_BRANCH from origin"
  held=$(git rev-parse FETCH_HEAD) || _die "could not read the fetched commit"
}

if [ "$cmd" = "apply" ]; then
  [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" = "main" ] || _die "check out main first; nothing was changed"
  [ -z "$(git status --porcelain)" ] || _die "main has uncommitted changes; commit or stash them first. Nothing was changed"
fi

_fetch_held
if [ -z "$held" ]; then
  echo "No held template update."
  exit 0
fi

if [ "$cmd" = "status" ]; then
  echo "Held template update $(git log -1 --format='%h, made %cd' --date=short "$held"):"
  git diff --name-status --no-renames "$held^" "$held" | tr '\t' ' '
  if git merge-base --is-ancestor main "$held" 2>/dev/null; then
    echo "Apply it with: bash .claude/tools/template-sync-held.sh apply"
  else
    echo "main has moved since this update was held. Run the Template Sync workflow again to rebuild it."
  fi
  exit 0
fi

git merge-base --is-ancestor HEAD "$held" \
  || _die "main has moved since this update was held. Run the Template Sync workflow again to rebuild it; nothing was changed"
git merge -q --ff-only "$held" || _die "the fast-forward failed; nothing was changed"
echo "main now has the template update ($(git rev-parse --short HEAD))."
echo "Push it with: git push origin main"
