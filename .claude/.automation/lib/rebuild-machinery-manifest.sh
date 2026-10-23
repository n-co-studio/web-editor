#!/usr/bin/env bash
# rebuild-machinery-manifest.sh — regenerate the template machinery manifest.
#
# The manifest is the authoritative list of every file template-sync delivers
# to a child repo: all tracked template files minus everything matched by
# .templatesyncignore. Children receive it on each sync and keep the previous
# copy long enough for the sync engine to diff old against new.
#
# WHY A MANIFEST AND NOT "absent from the template"
# -------------------------------------------------
# The sync engine is add/update-only, so a file deleted from the template
# lingers in every child forever (branch-guard.sh survived in markpreston for
# seven months after deletion). The obvious repair — delete anything the
# template does not ship — is wrong: it would also delete a child's OWN hooks
# and agents, which the template has no business touching.
#
# Diffing consecutive manifests separates the two cases exactly. A file in the
# old manifest but not the new one is provably template-owned and provably
# withdrawn, so it is safe to remove. A child-authored file has never appeared
# in any manifest and is therefore never a candidate. This mirrors the
# t-manifest.txt mechanism for decisions (Decision 0022), generalized to
# machinery, which has no ownership-marking naming convention to lean on.
#
# Usage:
#   bash .claude/.automation/lib/rebuild-machinery-manifest.sh [--check | --help]
#
#   (no args) regenerate the manifest in place.
#   --check   exit 1 if the manifest is out of date; write nothing.
#             Run by gate-conformance.sh in a template checkout and by its own
#             step in gate-conformance.yml (CI), which is what makes drift loud:
#             a file added to or removed from the template without regenerating
#             fails one of them.
#   --help, -h  print this usage; write nothing.
#
# Any other argument is a usage error (exit 2, nothing written). The script
# used to treat every argument other than --check as "rebuild", so --help and
# typos silently rewrote the tracked manifest.
#
# Run in the TEMPLATE repo. Regenerate whenever a synced file is added or
# removed. Decision t-0051.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bash .claude/.automation/lib/rebuild-machinery-manifest.sh [--check | --help]

  (no args)  regenerate .claude/.automation/machinery-manifest.txt from the git index
  --check    exit 1 if the tracked manifest differs from a fresh rebuild; writes nothing
  --help, -h print this usage; writes nothing

Any other argument is a usage error (exit 2) and writes nothing.
USAGE
}

# Parsed before anything touches the filesystem, so no argument can reach the
# write at the bottom of the file by accident.
CHECK_ONLY=false
if [ "$#" -gt 1 ]; then
  echo "rebuild-machinery-manifest.sh: too many arguments" >&2
  usage >&2; exit 2
fi
# Rebuild only when there is NO argument. Testing "${1:-}" for emptiness would
# also treat an explicit empty string as "no argument" and rewrite the manifest.
if [ "$#" -eq 1 ]; then
  case "$1" in
    --check)     CHECK_ONLY=true ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "rebuild-machinery-manifest.sh: unknown argument '$1'" >&2
                 usage >&2; exit 2 ;;
  esac
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MANIFEST="$REPO_ROOT/.claude/.automation/machinery-manifest.txt"
SYNCIGNORE="$REPO_ROOT/.templatesyncignore"

# Patterns are loaded ONCE into an array. Re-reading them per file via a
# process substitution inside the generate loop crashes bash 3.2 (SIGBUS, exit
# 138) once the loop is itself inside a command substitution — macOS ships
# 3.2.57, so this is not hypothetical.
_SYNCIGNORE_PATTERNS=()
if [ -f "$SYNCIGNORE" ]; then
  while IFS= read -r _p; do
    _p="$(printf '%s' "$_p" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$_p" in '#'*|'') continue ;; esac
    _SYNCIGNORE_PATTERNS[${#_SYNCIGNORE_PATTERNS[@]}]="$_p"
  done < "$SYNCIGNORE"
fi

# Mirrors is_excluded() in template-sync-engine.sh. The two must agree, or the
# manifest would claim files the engine never delivers (spurious orphans) or
# omit files it does (missed cleanups). The conformance tests assert agreement.
is_excluded() {
  local file_path="$1" pattern dir_prefix
  for pattern in ${_SYNCIGNORE_PATTERNS[@]+"${_SYNCIGNORE_PATTERNS[@]}"}; do
    if [ "${pattern%/}" != "$pattern" ]; then
      dir_prefix="${pattern%/}"
      case "$file_path" in
        "$dir_prefix"/*) return 0 ;;
        "$dir_prefix")   return 0 ;;
      esac
    else
      [ "$file_path" = "$pattern" ] && return 0
    fi
  done
  return 1
}

generate() {
  cat <<'HEADER'
# Template Machinery Manifest — GENERATED. Do not hand-edit.
#
# Every file template-sync delivers to a child repo (tracked template files
# minus .templatesyncignore). The sync engine diffs the child's previous copy
# of this manifest against the incoming one; entries that disappear are
# template files the template has withdrawn, and are removed from the child.
# Files a child authored itself never appear here and are never touched.
#
# Regenerate: bash .claude/.automation/lib/rebuild-machinery-manifest.sh
# Decision t-0051
HEADER
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    is_excluded "$f" && continue
    printf '%s\n' "$f"
  # ls-files (the index), not ls-tree HEAD. The engine reads ls-tree on the
  # fetched template ref, which equals the index at the moment of commit — so
  # reading the index here lets a commit that ADDS a synced file carry a
  # manifest that already lists it. Reading HEAD would always lag by one commit.
  done < <(git -C "$REPO_ROOT" ls-files | LC_ALL=C sort)
}

NEW_CONTENT="$(generate)"

if [ "$CHECK_ONLY" = true ]; then
  if [ ! -f "$MANIFEST" ]; then
    echo "machinery-manifest.txt is missing — regenerate it." >&2
    exit 1
  fi
  if printf '%s\n' "$NEW_CONTENT" | cmp -s - "$MANIFEST"; then
    echo "machinery manifest is current ($(printf '%s\n' "$NEW_CONTENT" | grep -vc '^#') entries)"
    exit 0
  fi
  echo "machinery-manifest.txt is STALE — regenerate: bash .claude/.automation/lib/rebuild-machinery-manifest.sh, then git add it. Difference:" >&2
  printf '%s\n' "$NEW_CONTENT" | diff "$MANIFEST" - | head -20 >&2
  exit 1
fi

printf '%s\n' "$NEW_CONTENT" > "$MANIFEST"
echo "Rebuilt machinery manifest: $(grep -vc '^#' "$MANIFEST") entries"
