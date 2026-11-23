#!/usr/bin/env bash
# Spec review before compile — Decision t-0083 (Massimo R6)
#
# A spec session writes its draft to docs/spec/drafts/<version>/, reviews it,
# and only after "Spec complete" compiles it with .claude/tools/spec-compile.sh,
# which refuses anything unfinished and changes nothing when it refuses. Each
# case runs the real tool against a scratch repo.
#
# Run against the code before t-0083 (verify-pristine) every case fails: the
# tool does not exist and Prompt 0 still writes into docs/spec/compiled/.
# Bash 3.2 compatible.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_REPO="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TOOL="$REAL_REPO/.claude/tools/spec-compile.sh"
RF="$REAL_REPO/.claude/tools/review-findings.sh"

_TAP_NUM=0; _TAP_PASS=0; _TAP_FAIL=0; _TAP_FAILURES=""
_tap_pass() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_PASS=$((_TAP_PASS+1)); printf "ok %d - %s\n" "$_TAP_NUM" "$1"; }
_tap_fail() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_FAIL=$((_TAP_FAIL+1)); printf "not ok %d - %s\n" "$_TAP_NUM" "$1"; [ -n "${2:-}" ] && printf "  # %s\n" "$2"; _TAP_FAILURES="${_TAP_FAILURES}  FAIL: $1\n"; }
_tap_eq() { if [ "$1" = "$2" ]; then _tap_pass "$3"; else _tap_fail "$3" "expected '$2', got '$1'"; fi; }
_tap_contains() { case "$1" in *"$2"*) _tap_pass "$3" ;; *) _tap_fail "$3" "output did not contain '$2': $1" ;; esac; }
_tap_lacks() { case "$1" in *"$2"*) _tap_fail "$3" "output contained '$2': $1" ;; *) _tap_pass "$3" ;; esac; }
_tap_true() { if eval "$1"; then _tap_pass "$2"; else _tap_fail "$2" "false: $1"; fi; }

printf "# === Spec compile (Decision t-0083) ===\n"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sc-test.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
export REPO_ROOT="$WORK/repo"
M="$REPO_ROOT/docs/spec/compiled/manifest.json"

run() { OUT=$(bash "$TOOL" "$@" 2>&1); RC=$?; }
fresh_repo() {
  rm -rf "$REPO_ROOT"
  mkdir -p "$REPO_ROOT/docs/spec/compiled"
  printf '{\n  "active": null,\n  "versions": [],\n  "features": [],\n  "spec_digest_sha": ""\n}\n' > "$M"
}
# A complete draft: no [TBD] outside comments, an empty Assumptions section.
mkdraft() {  # <version>
  local d="$REPO_ROOT/docs/spec/drafts/$1"
  mkdir -p "$d/features"
  printf '# Product\n\n<!-- DRAFT: every [TBD] must be resolved -->\nA tool.\n' > "$d/product.md"
  printf '# Boundaries\n\n## Do not build\n- billing\n\n## Assumptions: NONE\n<!--\n  This section must remain empty. [TBD]\n-->\n\n## Protected areas\n- none\n' > "$d/boundaries.md"
  printf '# Feature 001\n\nDoes a thing.\n' > "$d/features/feature-001-a.md"
}
nofindings() { printf 'findings: []\n' | bash "$RF" write "$1" >/dev/null 2>&1; }

# --- check ---
fresh_repo
run check v1
_tap_eq "$RC" "1" "check without a draft exits 1"
_tap_contains "$OUT" "DRAFT_MISSING: no draft directory docs/spec/drafts/v1/" "...and names DRAFT_MISSING"

mkdraft v1
run check v1
_tap_eq "$RC" "1" "a draft with no findings file is not compilable (the review has not run)"
_tap_contains "$OUT" "FINDINGS_UNRESOLVED: " "...reported as FINDINGS_UNRESOLVED"

nofindings v1
run check v1
_tap_eq "$RC" "0" "a complete draft with an empty review passes check"
_tap_contains "$OUT" "OK: v1 is ready to compile" "...and says so"
_tap_lacks "$OUT" "TBD_UNRESOLVED" "a [TBD] inside an HTML comment (one line or several) does not block"

printf '# Product\n\nUsers: [TBD]\n' > "$REPO_ROOT/docs/spec/drafts/v1/product.md"
printf 'Limit [TBD] <!-- [TBD] in a comment --> ok\n' >> "$REPO_ROOT/docs/spec/drafts/v1/features/feature-001-a.md"
run check v1
_tap_eq "$RC" "1" "a [TBD] outside a comment blocks check"
_tap_contains "$OUT" "TBD_UNRESOLVED: docs/spec/drafts/v1/product.md:3" "...named as file:line"
_tap_contains "$OUT" "TBD_UNRESOLVED: docs/spec/drafts/v1/features/feature-001-a.md:4" "...in feature files too, even with a comment on the same line"

mkdraft v1
printf '# Boundaries\n\n## Assumptions: NONE\nUsers have accounts.\n\n## Protected\n' > "$REPO_ROOT/docs/spec/drafts/v1/boundaries.md"
run check v1
_tap_eq "$RC" "1" "text under Assumptions: NONE blocks check"
_tap_contains "$OUT" "ASSUMPTIONS_NOT_EMPTY: docs/spec/drafts/v1/boundaries.md has text" "...reported as ASSUMPTIONS_NOT_EMPTY"
printf '# Boundaries\n\n## Do not build\n' > "$REPO_ROOT/docs/spec/drafts/v1/boundaries.md"
run check v1
_tap_contains "$OUT" "ASSUMPTIONS_NOT_EMPTY: " "a boundaries.md with no Assumptions: NONE section blocks too"
rm "$REPO_ROOT/docs/spec/drafts/v1/boundaries.md"
run check v1
_tap_contains "$OUT" "ASSUMPTIONS_NOT_EMPTY: docs/spec/drafts/v1/boundaries.md is missing" "...and so does a missing boundaries.md"

mkdraft v1
printf 'findings:\n  - id: "F1"\n    kind: "critical"\n    agent: "critic"\n    spec_file: "docs/spec/drafts/v1/product.md"\n    section: "Users"\n    finding: "No user limit"\n    suggested_fix: "State the limit"\n' \
  | bash "$RF" write v1 --replace >/dev/null 2>&1
run check v1
_tap_eq "$RC" "1" "an open Blocking finding blocks check"
_tap_contains "$OUT" "FINDINGS_UNRESOLVED: " "...as FINDINGS_UNRESOLVED"
_tap_contains "$OUT" "F1: open" "...naming the finding"
bash "$RF" set v1 F1 applied >/dev/null 2>&1
run check v1
_tap_eq "$RC" "0" "once the finding is applied, check passes"

for bad in 1 v0 v01 "v1x" "../v1" ""; do
  run check "$bad"
  _tap_eq "$RC" "1" "check refuses the version '$bad'"
done
run check v1 extra
_tap_eq "$RC" "1" "check refuses an extra argument"

ln -s "$REPO_ROOT/docs/spec/drafts/v1" "$REPO_ROOT/docs/spec/drafts/v7"
run check v7
_tap_contains "$OUT" "DRAFT_MISSING" "a symlinked draft directory is not a draft"
rm "$REPO_ROOT/docs/spec/drafts/v7"

# --- compile refused: nothing changes ---
cp "$M" "$WORK/manifest.before"
printf 'Users: [TBD]\n' >> "$REPO_ROOT/docs/spec/drafts/v1/product.md"
run compile v1
_tap_eq "$RC" "1" "compile refuses a draft that fails check"
_tap_contains "$OUT" "nothing was changed" "...and says nothing changed"
_tap_true "[ ! -e '$REPO_ROOT/docs/spec/compiled/v1' ]" "...no compiled version is written"
_tap_true "cmp -s '$M' '$WORK/manifest.before'" "...manifest.json is unchanged"
_tap_true "[ -f '$REPO_ROOT/docs/spec/drafts/v1/product.md' ]" "...the draft is kept"
mkdraft v1

printf 'not json' > "$M"
run compile v1
_tap_eq "$RC" "1" "compile refuses an unreadable manifest.json"
_tap_true "[ ! -e '$REPO_ROOT/docs/spec/compiled/v1' ]" "...and writes no compiled version"
cp "$WORK/manifest.before" "$M"

# --- compile ---
run compile v1
_tap_eq "$RC" "0" "compile succeeds on a draft that passes check"
_tap_contains "$OUT" "Compiled v1: 2 spec file(s), 1 feature file(s); manifest.json active is v1" "...and reports what it compiled"
_tap_true "[ -f '$REPO_ROOT/docs/spec/compiled/v1/product.md' ] && [ -f '$REPO_ROOT/docs/spec/compiled/v1/features/feature-001-a.md' ]" "the draft's files are now the compiled version"
_tap_eq "$(jq -r '.active' "$M")" "v1" "manifest.json active is the compiled version"
_tap_eq "$(jq -r '.versions | length' "$M")" "1" "manifest.json lists one version"
_tap_eq "$(jq -r '.versions[0].specFiles | join(",")' "$M")" "boundaries.md,product.md" "the entry lists the spec files"
_tap_eq "$(jq -r '.versions[0].featureFiles | join(",")' "$M")" "feature-001-a.md" "...and the feature files"
_tap_true "jq -e '.versions[0].created and .versions[0].templateCommit' '$M' >/dev/null" "...with created and templateCommit"
_tap_eq "$(jq -r '.spec_digest_sha' "$M")" "" "other manifest fields are kept"
_tap_true "[ ! -e '$REPO_ROOT/docs/spec/drafts' ]" "the draft is removed"
_tap_contains "$OUT" "spec-digest.sh not run" "the digest is not run against another repo, and that is said"
_tap_eq "$(ls -A "$REPO_ROOT/docs/spec/compiled" | LC_ALL=C sort | tr '\n' ' ')" "manifest.json v1 " "no staging files are left behind"
_tap_eq "$(ls -ld "$REPO_ROOT/docs/spec/compiled/v1" | cut -c1-10)" "drwxr-xr-x" "the compiled version is readable like the rest (not mktemp's 0700)"

run check v1
_tap_contains "$OUT" "DRAFT_MISSING" "a compiled version has no draft left to check"
mkdraft v1; nofindings v1 2>/dev/null
run compile v1
_tap_eq "$RC" "1" "a version cannot be compiled twice"
_tap_contains "$OUT" "VERSION_EXISTS: docs/spec/compiled/v1/ already exists" "...reported as VERSION_EXISTS"
rm -rf "$REPO_ROOT/docs/spec/drafts/v1"

# --- update: a second version keeps the first ---
mkdraft v2
printf 'findings: []\n' | bash "$RF" write v2 >/dev/null 2>&1
run compile v2
_tap_eq "$RC" "0" "an update compile of v2 succeeds"
_tap_eq "$(jq -r '.active' "$M")" "v2" "...active moves to v2"
_tap_eq "$(jq -r '[.versions[].version] | join(",")' "$M")" "v1,v2" "...and v1 stays listed"
_tap_true "[ -f '$REPO_ROOT/docs/spec/compiled/v1/product.md' ]" "...and its files stay"

jq '.versions += [{"version": "v3"}]' "$M" > "$WORK/m" && cp "$WORK/m" "$M"
mkdraft v3; printf 'findings: []\n' | bash "$RF" write v3 >/dev/null 2>&1
run check v3
_tap_contains "$OUT" "VERSION_EXISTS: manifest.json already lists v3" "a version listed in manifest.json without a directory also exists"

# --- a symbolic link in a draft (t-0083 amendment) ---
fresh_repo
mkdraft v1; nofindings v1
printf 'outside\n' > "$WORK/outside.md"
ln -s "$WORK/outside.md" "$REPO_ROOT/docs/spec/drafts/v1/features/feature-002-link.md"
cp "$M" "$WORK/manifest.before"
run check v1
_tap_eq "$RC" "1" "a draft holding a symbolic link fails check"
_tap_contains "$OUT" "SYMLINK_IN_DRAFT: docs/spec/drafts/v1/features/feature-002-link.md" "...named with SYMLINK_IN_DRAFT"
run compile v1
_tap_eq "$RC" "1" "compile refuses it"
_tap_true "[ ! -e '$REPO_ROOT/docs/spec/compiled/v1' ] && cmp -s '$M' '$WORK/manifest.before'" "...and changes nothing"
rm "$REPO_ROOT/docs/spec/drafts/v1/features/feature-002-link.md"

# --- an interrupted compile changes nothing (t-0083 amendment) ---
# A jq stand-in signals the tool while it writes the manifest; every other jq
# call goes to the real one.
REAL_JQ=$(command -v jq)
mkdir -p "$WORK/fakebin"
printf '#!/bin/bash\nfor a in "$@"; do case "$a" in *templateCommit*) kill -TERM "$PPID"; sleep 1; exit 1 ;; esac; done\nexec "%s" "$@"\n' "$REAL_JQ" > "$WORK/fakebin/jq"
chmod +x "$WORK/fakebin/jq"
OUT=$(PATH="$WORK/fakebin:$PATH" bash "$TOOL" compile v1 2>&1); RC=$?
_tap_eq "$RC" "1" "a compile interrupted while writing the manifest exits 1"
_tap_contains "$OUT" "Interrupted: nothing was changed." "...and says nothing was changed"
_tap_true "[ ! -e '$REPO_ROOT/docs/spec/compiled/v1' ]" "...no compiled version is left"
_tap_eq "$(ls -A "$REPO_ROOT/docs/spec/compiled" | tr '\n' ' ')" "manifest.json " "...nor any .compile-* or .manifest.* file"
_tap_true "cmp -s '$M' '$WORK/manifest.before'" "...manifest.json is unchanged"
_tap_true "[ -f '$REPO_ROOT/docs/spec/drafts/v1/product.md' ]" "...and the draft is intact"
run compile v1
_tap_eq "$RC" "0" "the same compile then succeeds"

# --- the digest runs when the tool lives in the repo it compiles ---
REPO_ROOT="$WORK/own"; export REPO_ROOT; M="$REPO_ROOT/docs/spec/compiled/manifest.json"
fresh_repo
mkdir -p "$REPO_ROOT/.claude/tools"
cp "$TOOL" "$RF" "$REAL_REPO/.claude/tools/spec-digest.sh" "$REPO_ROOT/.claude/tools/" 2>/dev/null
mkdraft v1; printf 'findings: []\n' | bash "$REPO_ROOT/.claude/tools/review-findings.sh" write v1 >/dev/null 2>&1
OUT=$(bash "$REPO_ROOT/.claude/tools/spec-compile.sh" compile v1 2>&1); RC=$?
_tap_eq "$RC" "0" "compile inside its own repo succeeds"
_tap_true "[ -f '$REPO_ROOT/docs/spec/compiled/v1/DIGEST.md' ]" "...and writes DIGEST.md"
_tap_lacks "$OUT" "WARNING" "...with no digest warning"

# --- the prompt and the phase model ---
P0="$REAL_REPO/docs/ai/prompts/prompt-0-spec-builder.md"
for want in "docs/spec/drafts/v1/" "spec-compile.sh check v{n}" "spec-compile.sh compile v{n}" "review-findings.sh write v{n}" \
            "mode: spec-review" "advisory-review[both] → approval[operator] → compile[agent]" "Prompt T"; do
  _tap_true "grep -qF '$want' '$P0'" "Prompt 0 says: $want"
done
_tap_true "! grep -q 'Set .active. to the new version' '$P0'" "Prompt 0 no longer sets the manifest by hand"
_tap_eq "$(bash -c "source '$REAL_REPO/.claude/hooks/_analytics-helper.sh' >/dev/null 2>&1; source '$REAL_REPO/.claude/hooks/_phase-helper.sh' >/dev/null 2>&1; get_phases_for_type spec-update")" \
  "init interview write advisory-review approval compile governance close" "the spec-update phase sequence has advisory-review before approval and compile after"
_tap_true "grep -qx 'docs/spec/drafts/' '$REAL_REPO/.templatesyncignore'" "the drafts directory is owned by the repo, not synced"
# A child may write the draft: the mode guard restricts governance paths only,
# and docs/spec/ outside _templates/ is not one (as for docs/spec/compiled/).
_mg_gov() { bash -c "source '$REAL_REPO/.claude/hooks/_mode-guard-helper.sh' 2>/dev/null && is_governance '$1'"; }
_tap_true "! _mg_gov docs/spec/drafts/v1/product.md" "a draft is not a governance path, so child mode may write it"
_tap_true "_mg_gov docs/spec/_templates/product.md" "...while the spec templates still are"

printf "\n# %d passed, %d failed\n" "$_TAP_PASS" "$_TAP_FAIL"
if [ "$_TAP_FAIL" -gt 0 ]; then printf "%b" "$_TAP_FAILURES"; exit 1; fi
exit 0
