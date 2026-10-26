#!/usr/bin/env bash
# kg-validate.sh after the template graph's retirement (t-0034 Amendment 9).
# Product graph only; validates an arbitrary file via --file (the commit gate
# hands it the INDEX copy); blocks on malformed ids and on unterminated quoted
# scalars — the 5d878c2 defect that left the template graph unparseable while
# this validator reported CLEAN.
# Bash 3.2 compatible.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

_N=0; _P=0; _F=0; _FAILS=""
ok()  { _N=$((_N+1)); _P=$((_P+1)); printf 'ok %d - %s\n' "$_N" "$1"; }
nok() { _N=$((_N+1)); _F=$((_F+1)); printf 'not ok %d - %s\n' "$_N" "$1"; [ -n "${2:-}" ] && printf '  # %s\n' "$2"; _FAILS="${_FAILS}  FAIL: $1\n"; }
eq()  { if [ "$1" = "$2" ]; then ok "$3"; else nok "$3" "expected '$2', got '$1' | $(tr '\n' ' ' < "$T/out" | cut -c1-300)"; fi; }
has() { if grep -qF -- "$1" "$T/out"; then ok "$2"; else nok "$2" "no '$1' in: $(tr '\n' ' ' < "$T/out" | cut -c1-300)"; fi; }

T=$(mktemp -d /tmp/kg-validate-test.XXXXXX) || { echo "Bail out! mktemp failed"; exit 2; }
trap 'rm -rf "$T"' EXIT
# A copy of the validator in a scratch repo layout, so a default run reads the
# scratch product graph and never the real repository.
mkdir -p "$T/repo/.claude/tools" "$T/repo/docs/ai/knowledge-graph"
cp "$REAL_ROOT/.claude/tools/kg-validate.sh" "$T/repo/.claude/tools/"
cp "$REAL_ROOT/docs/ai/knowledge-graph/schema.yaml" "$T/repo/docs/ai/knowledge-graph/"
V="$T/repo/.claude/tools/kg-validate.sh"
PG="$T/repo/docs/ai/knowledge-graph/product-graph.yaml"

_node() { printf '  - id: "%s"\n    type: "file"\n    path: "%s"\n    description: "%s"\n    last_verified: "%s"\n    status: "active"\n    layer: "product"\n' "$1" "$2" "${3:-Renders the settings panel for the user}" "${4:-2026-10-25}"; }
_edge() { printf '  - source: "%s"\n    target: "%s"\n    relation: "depends-on"\n    context: "x"\n    source_type: "agent-inferred"\n    last_verified: "2026-10-25"\n    status: "active"\n' "$1" "$2"; }
_graph() { { printf 'schema_version: 1\nlast_updated: "2026-10-25T00:00:00Z"\n\nnodes:\n'; printf '%s\n' "$1"; printf 'edges:\n'; [ -n "${2:-}" ] && printf '%s\n' "$2"; } > "$3"; }
run() { local rc=0; bash "$V" "$@" > "$T/out" 2>&1 || rc=$?; echo "$rc"; }

printf '# === kg-validate (t-0034 Amendment 9) ===\n'

_graph "$(_node product-app-a src/app/a.ts)" "" "$PG"
eq "$(run --strict)" "0" "a valid product graph passes"

_graph "$(_node product-app-a src/app/a.ts)" "" "$T/elsewhere.yaml"
_graph "$(_node 'Bad_ID' src/app/a.ts)" "" "$PG"
eq "$(run --strict --file "$T/elsewhere.yaml")" "0" "--file validates the named file, not the default graph"

_graph "$(_node 'hook--mechanism-helper' src/app/a.ts)" "" "$T/g.yaml"
eq "$(run --strict --file "$T/g.yaml")" "1" "an id with a doubled hyphen blocks under --strict"
has "malformed node id \"hook--mechanism-helper\"" "...naming the id as malformed"

for bad in 'Product-App' 'product_app' '-product-app' 'product-app-' 'product app'; do
  _graph "$(_node "$bad" src/app/a.ts)" "" "$T/g.yaml"
  eq "$(run --strict --file "$T/g.yaml")" "1" "id '$bad' is rejected"
  # The exit code alone would also be 1 for a usage error — assert the finding.
  has "malformed node id" "...as a malformed id, not for some other reason"
done

_graph "$(_node product-app-a src/app/a.ts "Renders things" '2026-08-072026-10-25')" "" "$T/g.yaml"
# Drop the closing quote. awk + mv, not `sed -i`, whose in-place syntax differs
# between BSD and GNU sed.
awk '{ if ($0 == "    last_verified: \"2026-08-072026-10-25\"") print "    last_verified: \"2026-08-072026-10-25"; else print }' \
  "$T/g.yaml" > "$T/g.tmp" && mv "$T/g.tmp" "$T/g.yaml"
grep -q '^    last_verified: "2026-08-072026-10-25$' "$T/g.yaml" && ok "setup: fixture reproduces the 5d878c2 line" || nok "setup: fixture reproduces the 5d878c2 line"
eq "$(run --strict --file "$T/g.yaml")" "1" "an unterminated quoted scalar blocks (the 5d878c2 defect)"
has "unterminated" "...reported as unterminated"

_graph "$(_node product-app-a src/app/a.ts 'Says \"hello\" to the user nicely')" "" "$T/g.yaml"
eq "$(run --strict --file "$T/g.yaml")" "0" "escaped quotes inside a scalar are not a false positive"

_graph "$(_node product-app-a src/app/a.ts)" "$(_edge product-app-a hook-phase-helper)" "$T/g.yaml"
eq "$(run --strict --file "$T/g.yaml")" "0" "an edge to a retired template node is advisory, not a block"
has "dangling edge reference" "...and is reported"

_edges=""; i=0; while [ $i -lt 25 ]; do _edges="${_edges}$(_edge product-app-a "gone-$i")
"; i=$((i+1)); done
_graph "$(_node product-app-a src/app/a.ts)" "$_edges" "$T/g.yaml"
run --strict --file "$T/g.yaml" > /dev/null
_lines=$(grep -c 'resolves to no node' "$T/out")
if [ "$_lines" -le 10 ]; then ok "a long dangling list is summarised (printed $_lines of 25)"; else nok "a long dangling list is summarised" "printed $_lines"; fi
has "25 dangling" "...with the full count"

eq "$(run --strict --target template)" "0" "--target template exits 0 (retired; nothing to validate)"
has "retired" "...saying so"
_graph "$(_node product-app-a src/app/a.ts)" "" "$PG"   # case 2 left a bad id in the default graph
eq "$(run --strict --target both)" "0" "--target both is accepted as product (old callers mid-sync)"
_graph "$(_node 'Bad_ID' src/app/a.ts)" "" "$PG"
eq "$(run --strict --target both)" "1" "...and still validates it (a bad default graph fails)"

printf '\n1..%d\n# pass %d / fail %d\n' "$_N" "$_P" "$_F"
if [ "$_F" -gt 0 ]; then printf '%b' "$_FAILS"; exit 1; fi
exit 0
