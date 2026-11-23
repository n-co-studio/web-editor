#!/usr/bin/env bash
# spec-compile.sh — compile an approved spec draft (Decision t-0083).
#
# A spec session writes its draft to docs/spec/drafts/<version>/, runs the
# advisory review on it, and asks the operator for "Spec complete". Compile is
# the step after: the draft becomes docs/spec/compiled/<version>/ and the
# manifest's active version. Compiled versions are never changed afterwards, so
# compile refuses anything that is not finished. A front end (Massimo's Specs
# page) runs `check` to show why a draft cannot be approved yet.
#
# Usage:
#   spec-compile.sh check <version>
#   spec-compile.sh compile <version>
#
# check prints one line per problem, each starting with a code:
#   DRAFT_MISSING          no docs/spec/drafts/<version>/
#   VERSION_EXISTS         <version> is already compiled or in manifest.json
#   TBD_UNRESOLVED         a [TBD] outside an HTML comment (file:line)
#   ASSUMPTIONS_NOT_EMPTY  boundaries.md's "Assumptions: NONE" section has text, or is missing
#   FINDINGS_UNRESOLVED    review-findings.sh check <version> does not pass
# Exit: 0 ok; 1 not compilable, or compile failed (nothing changed).
# Bash 3.2 compatible.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
DRAFTS="$REPO_ROOT/docs/spec/drafts"
COMPILED="$REPO_ROOT/docs/spec/compiled"
MANIFEST="$COMPILED/manifest.json"

_sc_die() { echo "ERROR: $*" >&2; exit 1; }

# Prompt 0 numbers versions v1, v2, ...
_sc_valid_version() {
  case "$1" in v[1-9]|v[1-9]*[0-9]) ;; *) return 1 ;; esac
  case "${1#v}" in *[!0-9]*) return 1 ;; esac
}

# Print each line of a file that has [TBD] outside <!-- --> comments, as
# <label>:<line>. Comments may span lines.
_sc_tbd_lines() {  # <file> <label>
  awk -v F="$2" '
    {
      line = $0; out = ""
      while (length(line) > 0) {
        if (inc) {
          p = index(line, "-->")
          if (p == 0) { line = ""; break }
          line = substr(line, p + 3); inc = 0
        } else {
          p = index(line, "<!--")
          if (p == 0) { out = out line; line = ""; break }
          out = out substr(line, 1, p - 1); line = substr(line, p + 4); inc = 1
        }
      }
      if (index(out, "[TBD]") > 0) print F ":" FNR
    }' "$1"
}

# 0 when boundaries.md has an "Assumptions: NONE" heading whose section holds
# nothing but comments and whitespace.
_sc_assumptions_empty() {  # <boundaries.md>
  awk '
    /^##[[:space:]]+Assumptions:[[:space:]]*NONE/ { found = 1; ins = 1; next }
    ins && /^#/ { ins = 0 }
    ins {
      line = $0; out = ""
      while (length(line) > 0) {
        if (inc) {
          p = index(line, "-->")
          if (p == 0) { line = ""; break }
          line = substr(line, p + 3); inc = 0
        } else {
          p = index(line, "<!--")
          if (p == 0) { out = out line; line = ""; break }
          out = out substr(line, 1, p - 1); line = substr(line, p + 4); inc = 1
        }
      }
      if (out ~ /[^[:space:]]/) text = 1
    }
    END { exit (found && !text) ? 0 : 1 }' "$1"
}

# Print every problem with <version>; return 1 if there is any.
_sc_check() {
  local v="$1" d="$DRAFTS/$1" problems="" f rel out
  if [ -L "$d" ] || [ ! -d "$d" ]; then
    printf 'DRAFT_MISSING: no draft directory docs/spec/drafts/%s/\n' "$v"
    return 1
  fi
  if [ -e "$COMPILED/$v" ]; then
    problems="${problems}VERSION_EXISTS: docs/spec/compiled/$v/ already exists; compiled versions are never changed"$'\n'
  elif [ -f "$MANIFEST" ] && command -v jq >/dev/null 2>&1 \
       && jq -e --arg v "$v" '(.versions // []) | map(.version) | index($v)' "$MANIFEST" >/dev/null 2>&1; then
    problems="${problems}VERSION_EXISTS: manifest.json already lists $v"$'\n'
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#$REPO_ROOT/}"
    out=$(_sc_tbd_lines "$f" "$rel")
    [ -n "$out" ] && problems="${problems}$(printf '%s\n' "$out" | sed 's/^/TBD_UNRESOLVED: /')"$'\n'
  done <<EOF
$(find "$d" -type f -name '*.md' | LC_ALL=C sort)
EOF
  if [ ! -f "$d/boundaries.md" ]; then
    problems="${problems}ASSUMPTIONS_NOT_EMPTY: docs/spec/drafts/$v/boundaries.md is missing"$'\n'
  elif ! _sc_assumptions_empty "$d/boundaries.md"; then
    problems="${problems}ASSUMPTIONS_NOT_EMPTY: docs/spec/drafts/$v/boundaries.md has text under 'Assumptions: NONE', or no such section"$'\n'
  fi
  if ! out=$(REPO_ROOT="$REPO_ROOT" bash "$SCRIPT_DIR/review-findings.sh" check "$v" 2>&1); then
    problems="${problems}$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d; s/^/FINDINGS_UNRESOLVED: /')"$'\n'
  fi
  if [ -n "$problems" ]; then
    printf '%s' "$problems"
    return 1
  fi
  return 0
}

# Basenames of the *.md files directly in <dir>, as a JSON array.
_sc_md_json() {
  find "$1" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sed 's|.*/||' | LC_ALL=C sort \
    | jq -R -s 'split("\n") | map(select(length > 0))'
}

cmd="${1:-}"
version="${2:-}"
case "$cmd" in
  check|compile)
    [ $# -eq 2 ] || _sc_die "$cmd requires exactly <version>"
    _sc_valid_version "$version" || _sc_die "version must look like v1, v2, ..."
    ;;
  *)
    sed -n '11,21p' "$0" >&2
    exit 1 ;;
esac

if [ "$cmd" = check ]; then
  _sc_check "$version" || exit 1
  printf 'OK: %s is ready to compile\n' "$version"
  exit 0
fi

# --- compile ---
command -v jq >/dev/null 2>&1 || _sc_die "jq is required to update manifest.json"
[ -f "$MANIFEST" ] || _sc_die "no docs/spec/compiled/manifest.json"
jq -e . "$MANIFEST" >/dev/null 2>&1 || _sc_die "manifest.json is not valid JSON; nothing was changed"
if ! _sc_check "$version"; then
  echo "Not compiled: fix the problems above; nothing was changed." >&2
  exit 1
fi

target="$COMPILED/$version"
stage=$(mktemp -d "$COMPILED/.compile-$version.XXXXXX") || _sc_die "could not stage the compile"
# mktemp -d makes the directory 0700; a compiled version is as readable as the rest.
if ! chmod 755 "$stage" || ! cp -R "$DRAFTS/$version/." "$stage/" || ! mv "$stage" "$target"; then
  rm -rf "$stage"
  _sc_die "could not copy the draft; nothing was changed"
fi

created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
commit=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
spec_files=$(_sc_md_json "$target")
feature_files=$(_sc_md_json "$target/features")
mtmp=$(mktemp "$COMPILED/.manifest.XXXXXX") || { rm -rf "$target"; _sc_die "could not update manifest.json; nothing was changed"; }
if ! jq --arg v "$version" --arg c "$created" --arg t "$commit" \
        --argjson sf "${spec_files:-[]}" --argjson ff "${feature_files:-[]}" \
        '.active = $v | .versions = ((.versions // []) + [{version: $v, created: $c, templateCommit: $t, specFiles: $sf, featureFiles: $ff}])' \
        "$MANIFEST" > "$mtmp" \
   || ! chmod 644 "$mtmp" || ! mv "$mtmp" "$MANIFEST"; then
  rm -f "$mtmp"
  rm -rf "$target"
  _sc_die "could not update manifest.json; nothing was changed"
fi

# Digest generation is advisory (Decision 0035): a failure is reported, not fatal.
# spec-digest.sh works on the repo it lives in, so it runs only when that is the
# repo being compiled.
if [ "$(cd "$SCRIPT_DIR/../.." && pwd -P)" != "$(cd "$REPO_ROOT" && pwd -P)" ]; then
  echo "WARNING: spec-digest.sh not run: it belongs to another repo; run it in $REPO_ROOT before committing (Decision 0035)" >&2
elif ! bash "$SCRIPT_DIR/spec-digest.sh" >/dev/null 2>&1; then
  echo "WARNING: spec-digest.sh failed; run it again before committing (Decision 0035)" >&2
fi

rm -rf "$DRAFTS/$version"
rmdir "$DRAFTS" 2>/dev/null || true
printf 'Compiled %s: %s spec file(s), %s feature file(s); manifest.json active is %s\n' \
  "$version" "$(printf '%s' "$spec_files" | jq 'length')" "$(printf '%s' "$feature_files" | jq 'length')" "$version"
