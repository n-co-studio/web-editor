#!/usr/bin/env bash
# KG product-graph gate (Decision t-0034 Amendment 9) — runs the REAL
# pre-commit-gates.sh in a child-mode /tmp sandbox with every other gate's
# evidence present, so the product gate alone decides the exit code.
#
# The rules under test are the operator's:
#   scope     = declared roots × declared extensions − exclusions, staged only
#   rule 1    = a NODE is required, never an edge
#   rule 2    = the node's description is not the seeder default and is >= 20 chars
#   rule 3    = staged files only, never the whole repo
#   R         = the node's path is updated (old path left only if stale)
#   D         = the node is removed or marked stale
#   FRESHNESS = product-graph.yaml staged, or this session's kg-updated marker
#
# Bash 3.2 compatible.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_HOOKS="$(cd "$SCRIPT_DIR/.." && pwd)"
REAL_TOOLS="$(cd "$SCRIPT_DIR/../../tools" && pwd)"

_N=0; _P=0; _F=0; _FAILS=""
ok()   { _N=$((_N+1)); _P=$((_P+1)); printf 'ok %d - %s\n' "$_N" "$1"; }
nok()  { _N=$((_N+1)); _F=$((_F+1)); printf 'not ok %d - %s\n' "$_N" "$1"; [ -n "${2:-}" ] && printf '  # %s\n' "$2"; _FAILS="${_FAILS}  FAIL: $1\n"; }
eq()   { if [ "$1" = "$2" ]; then ok "$3"; else nok "$3" "expected '$2', got '$1' | $(tr '\n' ' ' < "$OUT" | cut -c1-400)"; fi; }
has()  { if grep -qF -- "$1" "$OUT"; then ok "$2"; else nok "$2" "no '$1' in: $(tr '\n' ' ' < "$OUT" | cut -c1-400)"; fi; }
hasnt(){ if grep -qF -- "$1" "$OUT"; then nok "$2" "unexpected '$1'"; else ok "$2"; fi; }

SB=$(mktemp -d /tmp/kg-product-gate.XXXXXX) || { echo "Bail out! mktemp failed"; exit 2; }
SB=$(cd "$SB" && pwd)
trap '[ -n "${KEEP_SB:-}" ] || rm -rf "$SB"' EXIT   # KEEP_SB=1 retains it for debugging
SID="kgpg-session-$$"
OUT="$SB/.out"
G=docs/ai/knowledge-graph/product-graph.yaml
C=docs/ai/knowledge-graph/coverage.yaml

mkdir -p "$SB/.claude/.state/wt-sessions/$SID" "$SB/.claude/.state/sessions/$SID" \
         "$SB/.claude/tools" "$SB/docs/ai/decisions" "$SB/docs/ai/knowledge-graph" "$SB/docs/spec/compiled"
cp "$REAL_TOOLS/kg-validate.sh" "$SB/.claude/tools/"
cp "$REAL_HOOKS/../../docs/ai/knowledge-graph/schema.yaml" "$SB/docs/ai/knowledge-graph/" 2>/dev/null || true
echo "child" > "$SB/.claude/repo-mode"
echo "$SID" > "$SB/.claude/.session-id"
printf '{\n  "active": null,\n  "versions": [],\n  "features": [],\n  "spec_digest_sha": ""\n}\n' > "$SB/docs/spec/compiled/manifest.json"
: > "$SB/docs/ai/decisions/.a1-triggers-enforced"
printf '# A1 trigger index — generated artifact. Do not hand-edit.\n# digest: 0\n' > "$SB/docs/ai/decisions/.a1-trigger-index"
(
  cd "$SB" && git init -q . && git symbolic-ref HEAD refs/heads/main
  git config user.email t@t; git config user.name t; git config commit.gpgsign false
  # Governance state and this harness's output are not part of any fixture commit.
  printf '.claude/.state/\n.out\n' > .gitignore
  echo init > README.md; git add -A; git commit -q -m init
  git checkout -q -b feature/kgpg
)
export REPO_OS_TEST_MODE=1 _REPO_OS_TEST_ROOT="$SB" REPO_OS_SESSION_ID="$SID"
unset CLAUDE_HEADLESS REPO_OS_SKIP_KG_GATE REPO_OS_RECOVER 2>/dev/null || true

_evidence() {
  local d ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  for d in "$SB/.claude/.state" "$SB/.claude/.state/sessions/$SID" "$SB/.claude/.state/wt-sessions/$SID"; do
    mkdir -p "$d"
    printf 'session_type: %s\nsession_id: %s\nsession_log_id: %s\nmode: review\ncurrent_phase: commit\ncycle: 1\nphases_completed: init,plan,approval,build,review,verify\nsolo: false\ntag: agent\ntimestamp: %s\n' "${STYPE:-standard}" "$SID" "$SID" "$ts" > "$d/phase-state"
    printf 'timestamp: %s\nquestion_hash: h\nlarge-scope: true\nmode: review\nsession_id: %s\n' "$ts" "$SID" > "$d/plan-approved"
    for v in cohesion-reviewed:review diff-review-complete:review qa-verified:verify pragmatist-signed:plan; do
      printf 'timestamp: %s\nsession_id: %s\ndispatch_phase: %s\nGATE_RESULT: APPROVED\n' "$ts" "$SID" "${v#*:}" > "$d/${v%%:*}"
    done
  done
}
_marker_clear() { rm -f "$SB"/.claude/.state/kg-updated "$SB"/.claude/.state/*/"$SID"/kg-updated; }
# Any one candidate is enough (`ls a b` fails if either is missing, so not ls).
_marker_present() { [ -n "$(find "$SB/.claude/.state" -name kg-updated 2>/dev/null | head -1)" ]; }

# Fresh tree per case: back to the branch tip, nothing staged, no marker.
_reset() {
  ( cd "$SB" && git reset -q --hard && git clean -qfd -e .out ) 2>/dev/null
  _marker_clear; _evidence
}
_write() { mkdir -p "$(dirname "$SB/$1")"; printf '%s\n' "$2" > "$SB/$1"; }
_stage() { ( cd "$SB" && git add -A -- "$@" ); }
_commit_base() { ( cd "$SB" && git add -A && git commit -q -m "fixture" ) >/dev/null 2>&1; }

GOOD="Renders the settings panel and persists user choices"
_node() { # id path description [status]
  printf '  - id: "%s"\n    type: "file"\n    path: "%s"\n    description: "%s"\n    last_verified: "2026-10-25"\n    status: "%s"\n    layer: "product"\n' "$1" "$2" "$3" "${4:-active}"
}
_graph() { # node blocks on stdin
  { printf 'schema_version: 1\nlast_updated: "2026-10-25T00:00:00Z"\n\nnodes:\n'; cat; printf 'edges:\n'; } > "$SB/$G"
}
_coverage() {
  _write "$C" 'roots:
  - src/app
  - packages/*/src/content
extensions:
  - ts
  - tsx
  - css
exclude:
  - "*.stories.*"'
}

run_gate() {
  local rc=0 payload
  payload=$(printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"git commit -m kgpg-%s"}}' "$SID" "$_N")
  (cd "$SB" && printf '%s' "$payload" | bash "$REAL_HOOKS/pre-commit-gates.sh" > "$OUT" 2>&1) || rc=$?
  echo "$rc"
}

printf '# === KG product-graph gate (t-0034 Amendment 9) ===\n'

# --- Baseline: graph + coverage committed, one well-described node -----------
_reset; _coverage
printf '%s\n' "$(_node product-app-settings src/app/settings.ts "$GOOD")" | _graph
_write src/app/settings.ts "export const s = 1"
_commit_base

printf '# --- control and scope ---\n'
_reset; _write docs/notes.md "a note"; _stage docs/notes.md
eq "$(run_gate)" "0" "control: a file outside every root commits"
[ -n "${KEEP_SB:-}" ] && cp "$OUT" "$SB/.git/control-out"
hasnt "KG product-graph" "...with no product-gate output"

# The session marker is planted so FRESHNESS is satisfied: otherwise it blocks
# these commits by itself and the node rule could be deleted with every case
# here still green (it was, until a deliberate removal showed it).
_mark() { printf 'timestamp: x\nsession_id: %s\nresult: PASSED\n' "$SID" > "$SB/.claude/.state/wt-sessions/$SID/kg-updated"; }

_reset; _mark; _write src/app/new.ts "export const n = 1"; _stage src/app/new.ts
eq "$(run_gate)" "2" "rule 1: an in-scope file with no node blocks"
has "src/app/new.ts has no node" "...naming the file as having no node"
has "git add docs/ai/knowledge-graph/product-graph.yaml" "...and telling the agent to stage the graph"

_reset; _write lib/util.ts "export const u = 1"; _stage lib/util.ts
eq "$(run_gate)" "0" "a .ts file outside the declared roots passes"

_reset; _write src/app/logo.svg "<svg/>"; _stage src/app/logo.svg
eq "$(run_gate)" "0" "an unknown extension inside a root passes (include-list)"

_reset; _write src/app/new.test.ts "test"; _stage src/app/new.test.ts
eq "$(run_gate)" "0" "built-in exclusion *.test.* passes"

_reset; _write src/app/__tests__/x.ts "test"; _stage src/app/__tests__/x.ts
eq "$(run_gate)" "0" "built-in exclusion __tests__/ passes"

_reset; _write src/app/types.d.ts "declare const x: 1"; _stage src/app/types.d.ts
eq "$(run_gate)" "0" "built-in exclusion *.d.ts passes"

_reset; _write src/app/card.stories.tsx "story"; _stage src/app/card.stories.tsx
eq "$(run_gate)" "0" "a declared extra exclusion passes"

_reset; _mark; _write packages/editor/src/content/panel.ts "x"; _stage packages/editor/src/content/panel.ts
eq "$(run_gate)" "2" "a monorepo glob root (packages/*/src/content) is in scope"
has "packages/editor/src/content/panel.ts has no node" "...by the node rule"

_reset; _mark; _write src/app/theme.css "a{}"; _stage src/app/theme.css
eq "$(run_gate)" "2" ".css in the extension set is in scope"
has "src/app/theme.css has no node" "...by the node rule"

printf '# --- rule 2: a node must say something ---\n'
_reset; _write src/app/new.ts "x"
printf '%s\n%s\n' "$(_node product-app-settings src/app/settings.ts "$GOOD")" \
  "$(_node product-app-new src/app/new.ts "Product source file")" | _graph
_stage src/app/new.ts "$G"
eq "$(run_gate)" "2" "a node with the seeder default description blocks"
# The default is 19 characters, so the length rule would catch it too; assert
# the default rule's own message so deleting that rule turns this red.
has "seeder default" "...as the seeder default specifically"

_reset; _write src/app/new.ts "x"
printf '%s\n%s\n' "$(_node product-app-settings src/app/settings.ts "$GOOD")" \
  "$(_node product-app-new src/app/new.ts "Short text")" | _graph
_stage src/app/new.ts "$G"
eq "$(run_gate)" "2" "a node whose description is under 20 characters blocks"

_reset; _write src/app/new.ts "x"
printf '%s\n%s\n' "$(_node product-app-settings src/app/settings.ts "$GOOD")" \
  "$(_node product-app-new src/app/new.ts "Formats currency for the checkout summary")" | _graph
_stage src/app/new.ts "$G"
eq "$(run_gate)" "0" "a described node with the graph staged passes"
if _marker_present; then ok "...and writes this session's kg-updated marker"; else nok "...and writes this session's kg-updated marker"; fi

printf '# --- freshness ---\n'
_reset; printf 'export const s = 2\n' > "$SB/src/app/settings.ts"; _stage src/app/settings.ts
eq "$(run_gate)" "2" "a covered file staged without the graph and without a marker blocks"
has "git add docs/ai/knowledge-graph/product-graph.yaml" "...with the explicit git add"

_reset; printf 'export const s = 2\n' > "$SB/src/app/settings.ts"; _stage src/app/settings.ts
printf 'timestamp: x\nsession_id: %s\nresult: PASSED\n' "$SID" > "$SB/.claude/.state/wt-sessions/$SID/kg-updated"
eq "$(run_gate)" "0" "...but passes once this session's kg-updated marker exists"

printf '# --- rule 3: staged files only ---\n'
# An un-noded in-scope file that is committed but NOT staged must not block.
_reset; _write src/app/orphan.ts "x"; _commit_base
_reset; _write docs/notes.md "note"; _stage docs/notes.md
eq "$(run_gate)" "0" "an un-noded in-scope file elsewhere in the repo does not block an unrelated commit"

printf '# --- renames ---\n'
_reset; ( cd "$SB" && git mv src/app/settings.ts src/app/preferences.ts )
eq "$(run_gate)" "2" "a rename whose node still points at the old path blocks"
has "src/app/settings.ts" "...naming the old path"

_reset; ( cd "$SB" && git mv src/app/settings.ts src/app/preferences.ts )
printf '%s\n' "$(_node product-app-settings src/app/preferences.ts "$GOOD")" | _graph
_stage "$G"
eq "$(run_gate)" "0" "a rename with the node's path updated passes"

_reset; ( cd "$SB" && git mv src/app/settings.ts src/app/preferences.ts )
printf '%s\n%s\n' "$(_node product-app-settings src/app/settings.ts "$GOOD")" \
  "$(_node product-app-preferences src/app/preferences.ts "$GOOD")" | _graph
_stage "$G"
eq "$(run_gate)" "2" "a rename that adds a new node but leaves the old one active blocks"

printf '# --- deletions (a delete-only commit has no ACMR files) ---\n'
_reset; ( cd "$SB" && git rm -q src/app/settings.ts )
eq "$(run_gate)" "2" "deleting an in-scope file whose node stays active blocks"
has "src/app/settings.ts" "...naming it"

_reset; ( cd "$SB" && git rm -q src/app/settings.ts )
printf '%s\n' "$(_node product-app-settings src/app/settings.ts "$GOOD" stale)" | _graph
_stage "$G"
eq "$(run_gate)" "0" "...passes with the node marked stale"

_reset; ( cd "$SB" && git rm -q src/app/settings.ts )
: | _graph; _stage "$G"
eq "$(run_gate)" "0" "...passes with the node removed"

printf '# --- an invalid staged graph is reported once, as invalid ---\n'
_reset; _write src/app/new.ts "x"
printf '%s\n%s\n' "$(_node product-app-settings src/app/settings.ts "$GOOD")" \
  "$(_node product-app-settings src/app/new.ts "$GOOD")" | _graph
_stage src/app/new.ts "$G"
eq "$(run_gate)" "2" "a staged graph with a duplicate id blocks"
has "duplicate node id" "...on the validator's finding"
hasnt "has no node" "...not on misleading coverage messages"

_reset; _write src/app/new.ts "x"
printf '%s\n%s\n' "$(_node product-app-settings src/app/settings.ts "$GOOD")" \
  "$(_node product-app-new src/app/new.ts "Formats currency for the checkout summary")" | _graph
_stage src/app/new.ts
( cd "$SB" && git add "$G" )
printf '%s\n' "$(_node product-app-settings src/app/settings.ts "$GOOD")" | _graph   # working tree drops the node again
eq "$(run_gate)" "0" "the INDEX copy of the graph is judged, not the working tree"

printf '# --- a stale node is not coverage ---\n'
# status: stale exempts a path from the RENAME/DELETE rules only. A live file
# whose only node is stale has no node; marking a node stale must not be a way
# to satisfy the gate.
_reset; _mark; printf 'export const s = 2\n' > "$SB/src/app/settings.ts"
printf '%s\n' "$(_node product-app-settings src/app/settings.ts "$GOOD" stale)" | _graph
_stage src/app/settings.ts "$G"
eq "$(run_gate)" "2" "a modified file whose only node is stale blocks"
has "src/app/settings.ts has no node" "...as having no live node"

# A stale row ahead of a live one must not be the description that is judged.
_reset; _mark; printf 'export const s = 2\n' > "$SB/src/app/settings.ts"
printf '%s\n%s\n' "$(_node product-app-settings-old src/app/settings.ts "$GOOD" stale)" \
  "$(_node product-app-settings src/app/settings.ts "Product source file")" | _graph
_stage src/app/settings.ts "$G"
eq "$(run_gate)" "2" "a live default-description node behind a stale row still blocks"
has "seeder default" "...on the LIVE node's description"

printf '# --- description boundary ---\n'
_reset; _write src/app/new.ts "x"
printf '%s\n%s\n' "$(_node product-app-settings src/app/settings.ts "$GOOD")" \
  "$(_node product-app-new src/app/new.ts "Nineteen chars here")" | _graph
_stage src/app/new.ts "$G"
eq "$(run_gate)" "2" "a 19-character description blocks"
_reset; _write src/app/new.ts "x"
printf '%s\n%s\n' "$(_node product-app-settings src/app/settings.ts "$GOOD")" \
  "$(_node product-app-new src/app/new.ts "Twenty chars exactly")" | _graph
_stage src/app/new.ts "$G"
eq "$(run_gate)" "0" "a 20-character description passes"

printf '# --- hand-edited YAML forms the validator accepts ---\n'
_reset; _write src/app/new.ts "x"
{ printf 'schema_version: 1\nlast_updated: "2026-10-25T00:00:00Z"\n\nnodes:\n'
  _node product-app-settings src/app/settings.ts "$GOOD"
  printf "  - id: \"product-app-new\"\n    type: \"file\"\n    path: 'src/app/new.ts'\n    description: >-\n      Formats currency for the checkout summary\n      and the order receipt\n    last_verified: \"2026-10-25\"\n    status: active # reviewed\n    layer: \"product\"\n"
  printf 'edges:\n'; } > "$SB/$G"
_stage src/app/new.ts "$G"
eq "$(run_gate)" "0" "single-quoted path, folded description and a trailing comment are read correctly"

printf '# --- paths git quotes ---\n'
_reset; _mark; _write "src/app/café.ts" "x"; _stage "src/app/café.ts"
eq "$(run_gate)" "2" "a non-ASCII in-scope path is judged, not silently skipped"
has "café.ts has no node" "...under its real name"

printf '# --- deleting the graph or its scope in the same commit ---\n'
_reset; _write src/app/new.ts "x"; ( cd "$SB" && git rm -q "$G" ); _stage src/app/new.ts
eq "$(run_gate)" "2" "deleting product-graph.yaml alongside in-scope changes blocks"
# Assert the reason: without its own branch, the deleted graph would still block
# (an empty index copy fails validation), so the exit code alone proves nothing.
has "deletes docs/ai/knowledge-graph/product-graph.yaml" "...because the commit deletes the graph"
_reset; _write src/app/new.ts "x"; ( cd "$SB" && git rm -q "$C" ); _stage src/app/new.ts
eq "$(run_gate)" "2" "deleting coverage.yaml alongside in-scope changes blocks"
has "deletes docs/ai/knowledge-graph/coverage.yaml" "...because the commit deletes coverage.yaml"

printf '# --- a broken graph that is committed but not staged ---\n'
# The schema gate only runs when the graph is staged. A committed graph that no
# longer validates must still stop coverage from being judged against it, and
# must not earn this session a kg-updated marker.
_reset; _mark
printf '%s\n%s\n' "$(_node product-app-settings src/app/settings.ts "$GOOD")" \
  "$(_node product-app-settings src/app/dup.ts "$GOOD")" | _graph
( cd "$SB" && git add "$G" && git commit -q -m "broken graph" )
rm -f "$SB/.claude/.state/wt-sessions/$SID/kg-updated"
printf 'export const s = 3\n' > "$SB/src/app/settings.ts"; _stage src/app/settings.ts
eq "$(run_gate)" "2" "an invalid committed graph blocks the coverage check"
has "(as committed) fails kg-validate.sh" "...as an invalid graph, not a coverage message"
if _marker_present; then nok "...and writes no kg-updated marker"; else ok "...and writes no kg-updated marker"; fi
( cd "$SB" && git reset -q --hard HEAD~1 )

printf '# --- coverage.yaml is read from the INDEX, like the graph ---\n'
_reset; _mark; _write src/app/new.ts "x"; _stage src/app/new.ts
printf 'roots:\n  - nowhere\nextensions:\n  - ts\n' > "$SB/$C"   # unstaged: shrinks scope to nothing
eq "$(run_gate)" "2" "an unstaged edit to coverage.yaml does not change what is judged"

printf '# --- coverage.yaml syntax ---\n'
_reset; _mark
printf 'roots: [src/app, "packages/*/src/content"]\nextensions: [ts, tsx, css]\n' > "$SB/$C"
_write src/app/new.ts "x"; _stage "$C" src/app/new.ts
eq "$(run_gate)" "2" "inline [a, b] lists are understood (the advisory's own example form)"
has "src/app/new.ts has no node" "...and put the file in scope"

_reset; _mark
printf 'roots:\r\n  - ./src/app/\r\nextensions:\r\n  - .ts\r\n' > "$SB/$C"
_write src/app/new.ts "x"; _stage "$C" src/app/new.ts
eq "$(run_gate)" "2" "CRLF, a ./ root and a .ts extension are normalised"

_reset
printf 'roots: []\nextensions:\n  - ts\n' > "$SB/$C"
_write src/app/new.ts "x"; _stage "$C" src/app/new.ts
eq "$(run_gate)" "0" "a coverage.yaml with no roots does not block"
has "no roots" "...but says the gate is inert instead of staying silent"

_reset; _mark
printf 'roots:\n  - src/app\nextensions:\n  - ts\nexclude:\n  - storybook/\n' > "$SB/$C"
_write src/app/storybook/card.ts "x"; _stage "$C" src/app/storybook/card.ts
eq "$(run_gate)" "0" "a directory exclude written with a trailing slash excludes that directory"

printf '# --- exemptions and configuration ---\n'
# experiment/* never reaches this gate: pre-commit-gates exits early on those
# branches (A4 only), so the commit passes without the gate running at all.
_reset; _write src/app/new.ts "x"; _stage src/app/new.ts
( cd "$SB" && git checkout -q -b experiment/kgpg )
eq "$(run_gate)" "0" "experiment branch: the hook's early exit, not a block"
( cd "$SB" && git checkout -q feature/kgpg )

# The audit-session exemption is not probed here: an audit session has no commit
# phase, so pre-commit-gates refuses its commit before this gate is reached.

_reset; _write src/app/new.ts "x"; _stage src/app/new.ts
rc=0; (cd "$SB" && printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' "$SID" | REPO_OS_SKIP_KG_GATE=1 bash "$REAL_HOOKS/pre-commit-gates.sh" > "$OUT" 2>&1) || rc=$?
eq "$rc" "0" "REPO_OS_SKIP_KG_GATE=1 (interactive): advisory"

_reset; _write src/app/new.ts "x"; _stage src/app/new.ts
mkdir -p "$SB/.claude/.automation/escalations"
rc=0; (cd "$SB" && printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' "$SID" | CLAUDE_HEADLESS=1 REPO_OS_SKIP_KG_GATE=1 bash "$REAL_HOOKS/pre-commit-gates.sh" > "$OUT" 2>&1) || rc=$?
eq "$rc" "2" "REPO_OS_SKIP_KG_GATE=1 is ignored in headless mode"
has "ignored in headless" "...and says so"
if ls "$SB"/.claude/.automation/escalations/kg-product-fail-*.yaml > /dev/null 2>&1; then
  ok "...and writes a gate-failure escalation"
else
  nok "...and writes a gate-failure escalation"
fi

# A parallel content brief writes a KG delta instead of the graph; the merge
# brief aggregates and commits it. Only that content brief is exempt — a
# leftover delta must not switch the gate off for anyone else.
_reset; _write src/app/new.ts "x"; _stage src/app/new.ts
( cd "$SB" && mkdir -p .claude/.state && printf 'x\n' > ".claude/.state/tg-demo-brief-1.kg-delta.yaml" )
# A task-group session also needs an A6 contract, which this sandbox does not
# build — so this case reads the gate's OWN verdict, not the hook's exit code.
STYPE=taskgroup _evidence
run_gate > /dev/null
has "exempt (parallel_tg_delta)" "a task-group content brief with a delta pending: the gate exempts it"
hasnt "product-graph.yaml disagree" "...and does not block on coverage"
_evidence
eq "$(run_gate)" "2" "the same leftover delta does NOT exempt a standard session"
has "product-graph.yaml disagree" "...the gate itself blocks"
rm -f "$SB/.claude/.state/tg-demo-brief-1.kg-delta.yaml"

# "No graph" means none at HEAD either: absent before this commit, not deleted by it.
_reset; ( cd "$SB" && git rm -q "$G" && git commit -q -m "no graph" )
_write src/app/new.ts "x"; _stage src/app/new.ts
eq "$(run_gate)" "0" "coverage declared but no product graph: advisory, not a block"
has "kg-seed.sh --target product" "...pointing at kg-seed --target product"
if grep -q 'kg-product-graph-absent' "$SB"/.claude/.state/wt-sessions/"$SID"/overrides.log "$SB"/.claude/.state/overrides.log 2>/dev/null; then
  ok "...and logged as an override (it is a bypass)"
else
  nok "...and logged as an override (it is a bypass)"
fi
( cd "$SB" && git reset -q --hard HEAD~1 )

_reset; ( cd "$SB" && git rm -q "$C" && git commit -q -m "no coverage" )
_write src/app/new.ts "x"; _stage src/app/new.ts
eq "$(run_gate)" "0" "no coverage.yaml (child): not configured, nothing is in scope"
has "coverage.yaml" "...with an advisory naming the file to create"

# repo-mode is committed, so switch it AFTER _reset (whose reset --hard restores it).
_reset; echo template > "$SB/.claude/repo-mode"
_write src/app/new.ts "x"; _stage src/app/new.ts
eq "$(run_gate)" "0" "template mode with no coverage.yaml passes"
[ -n "${KEEP_SB:-}" ] && cp "$OUT" "$SB/.git/template-out"
hasnt "KG product-graph" "...silently"
echo child > "$SB/.claude/repo-mode"
( cd "$SB" && git reset -q --hard HEAD~1 )

printf '\n1..%d\n# pass %d / fail %d\n' "$_N" "$_P" "$_F"
if [ "$_F" -gt 0 ]; then printf '%b' "$_FAILS"; exit 1; fi
exit 0
