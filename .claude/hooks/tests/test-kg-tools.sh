#!/usr/bin/env bash
# kg-seed.sh / kg-cover.sh after the template graph's retirement (t-0034
# Amendment 9): product graph only, node ids from the FULL path so monorepo
# files cannot collide, one id function in two tools that must agree, and a
# seeder that will not overwrite an existing graph.
# Bash 3.2 compatible.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

_N=0; _P=0; _F=0; _FAILS=""
ok()  { _N=$((_N+1)); _P=$((_P+1)); printf 'ok %d - %s\n' "$_N" "$1"; }
nok() { _N=$((_N+1)); _F=$((_F+1)); printf 'not ok %d - %s\n' "$_N" "$1"; [ -n "${2:-}" ] && printf '  # %s\n' "$2"; _FAILS="${_FAILS}  FAIL: $1\n"; }
eq()  { if [ "$1" = "$2" ]; then ok "$3"; else nok "$3" "expected '$2', got '$1'"; fi; }

T=$(mktemp -d /tmp/kg-tools-test.XXXXXX) || { echo "Bail out! mktemp failed"; exit 2; }
trap 'rm -rf "$T"' EXIT
R="$T/repo"
mkdir -p "$R/.claude/tools" "$R/docs/ai/knowledge-graph"
for t in kg-seed.sh kg-cover.sh kg-validate.sh; do cp "$REAL_ROOT/.claude/tools/$t" "$R/.claude/tools/"; done
cp "$REAL_ROOT/docs/ai/knowledge-graph/schema.yaml" "$R/docs/ai/knowledge-graph/"
echo child > "$R/.claude/repo-mode"
G="$R/docs/ai/knowledge-graph/product-graph.yaml"

# The id function, extracted from each tool and run on its own: two copies that
# must agree, so they are compared rather than trusted.
_fn() { awk '/^_kg_product_id\(\) \{/{f=1} f{print} f && /^}$/{exit}' "$R/.claude/tools/$1"; }
_id_with() { ( eval "$(_fn "$1")"; _kg_product_id "$2" ) 2>/dev/null; }

printf '# === kg-seed / kg-cover (t-0034 Amendment 9) ===\n'

for t in kg-seed.sh kg-cover.sh; do
  if [ -n "$(_fn "$t")" ]; then ok "$t defines _kg_product_id"; else nok "$t defines _kg_product_id"; fi
done
for p in src/app/Settings.tsx packages/a/src/tokens/store.ts .claude/hooks/_mechanism-helper.sh "src/My Component/x.y.ts"; do
  eq "$(_id_with kg-cover.sh "$p")" "$(_id_with kg-seed.sh "$p")" "both tools derive the same id for $p"
done
eq "$(_id_with kg-seed.sh src/app/Settings.tsx)" "product-src-app-settings-tsx" "id is the full path, lowercased, with the extension"
eq "$(_id_with kg-seed.sh .claude/hooks/_mechanism-helper.sh)" "product-claude-hooks-mechanism-helper-sh" "a leading underscore yields no doubled hyphen"

# Monorepo: same file name under two packages.
mkdir -p "$R/packages/a/src/tokens" "$R/packages/b/src/tokens"
echo x > "$R/packages/a/src/tokens/store.ts"; echo x > "$R/packages/b/src/tokens/store.ts"
rc=0; (cd "$R" && bash .claude/tools/kg-seed.sh --file-pattern 'packages/**/*.ts' > "$T/seed.out" 2>&1) || rc=$?
eq "$rc" "0" "kg-seed seeds a monorepo layout"
eq "$(grep -c '^  - id: ' "$G" 2>/dev/null)" "2" "...one node per file"
eq "$(grep -oE '^  - id: "[^"]+"' "$G" 2>/dev/null | sort -u | wc -l | tr -d ' ')" "2" "...with two DISTINCT ids for packages/a and packages/b store.ts"
rc=0; bash "$R/.claude/tools/kg-validate.sh" --strict --file "$G" > /dev/null 2>&1 || rc=$?
eq "$rc" "0" "...and the seeded graph validates"
eq "$(grep -c '^    description: "Product source file"$' "$G")" "2" "seeded nodes carry the default the gate rejects"

# Several patterns in one run: the seeder refuses an existing graph, so a repo
# with .ts and .css in scope must be able to seed both at once.
R2="$T/repo2"; mkdir -p "$R2/.claude/tools" "$R2/docs/ai/knowledge-graph" "$R2/src/app"
cp "$R/.claude/tools/kg-seed.sh" "$R/.claude/tools/kg-validate.sh" "$R2/.claude/tools/"
cp "$R/docs/ai/knowledge-graph/schema.yaml" "$R2/docs/ai/knowledge-graph/"
echo x > "$R2/src/app/a.ts"; echo x > "$R2/src/app/theme.css"
rc=0; (cd "$R2" && bash .claude/tools/kg-seed.sh --file-pattern 'src/**/*.ts' --file-pattern 'src/**/*.css' > "$T/seed3.out" 2>&1) || rc=$?
eq "$rc" "0" "kg-seed accepts repeated --file-pattern"
eq "$(grep -c '^  - id: ' "$R2/docs/ai/knowledge-graph/product-graph.yaml" 2>/dev/null)" "2" "...and seeds every pattern (.ts and .css)"

cp "$G" "$T/before.yaml"
rc=0; (cd "$R" && bash .claude/tools/kg-seed.sh --file-pattern 'packages/**/*.ts' > "$T/seed2.out" 2>&1) || rc=$?
eq "$rc" "1" "kg-seed refuses to run when the graph exists"
if cmp -s "$G" "$T/before.yaml"; then ok "...and leaves it untouched"; else nok "...and leaves it untouched"; fi

rc=0; (cd "$R" && bash .claude/tools/kg-seed.sh --target template > "$T/st.out" 2>&1) || rc=$?
eq "$rc" "1" "kg-seed --target template exits 1"
if grep -q "retired" "$T/st.out"; then ok "...because the template graph is retired"; else nok "...because the template graph is retired" "$(cat "$T/st.out")"; fi

mkdir -p "$R/src/app"; echo x > "$R/src/app/Panel.tsx"
rc=0; (cd "$R" && bash .claude/tools/kg-cover.sh --target product src/app/Panel.tsx > "$T/cover.out" 2>&1) || rc=$?
eq "$rc" "0" "kg-cover adds a node to the product graph"
_cid=$(_id_with kg-seed.sh src/app/Panel.tsx)
if grep -q "^  - id: \"$_cid\"$" "$G"; then ok "...under the shared id ($_cid)"; else nok "...under the shared id ($_cid)" "$(grep 'Panel' "$G")"; fi
if awk -v id="$_cid" '$0 ~ "id: \""id"\"" {f=1} f && /description:/ {print; exit}' "$G" | grep -q '"Product source file"'; then
  ok "...with the default description, so the gate asks for a real one"
else
  nok "...with the default description, so the gate asks for a real one"
fi
if awk -v id="$_cid" '$0 ~ "id: \""id"\"" {f=1} f && /layer:/ {print; exit}' "$G" | grep -q '"product"'; then ok "...and layer product"; else nok "...and layer product"; fi
_n_before=$(grep -c '^  - id: ' "$G")
(cd "$R" && bash .claude/tools/kg-cover.sh --target product src/app/Panel.tsx > /dev/null 2>&1) || true
eq "$(grep -c '^  - id: ' "$G")" "$_n_before" "kg-cover skips a path that already has a node"
rc=0; (cd "$R" && bash .claude/tools/kg-cover.sh --target template src/app/Panel.tsx > "$T/ct.out" 2>&1) || rc=$?
eq "$rc" "1" "kg-cover --target template exits 1"
# Exit 1 alone is also what the pre-Amendment-9 tool gave in child mode, for a
# mode reason — assert the retirement is the reason.
if grep -q "retired" "$T/ct.out"; then ok "...because the template graph is retired"; else nok "...because the template graph is retired" "$(cat "$T/ct.out")"; fi
rc=0; bash "$R/.claude/tools/kg-validate.sh" --strict --file "$G" > /dev/null 2>&1 || rc=$?
eq "$rc" "0" "the graph still validates after kg-cover"

# A path whose only node is stale has no coverage (the gate counts live nodes
# only), so kg-cover — the gate's named remedy — must scaffold a live node for it
# rather than report "exists" and do nothing.
echo x > "$R/src/app/Old.tsx"
cat > "$T/stale-node.yaml" <<'EOF'
  - id: "product-src-app-old-tsx"
    type: "file"
    path: "src/app/Old.tsx"
    description: "Retired panel kept for history"
    last_verified: "2026-10-25"
    status: "stale"
    layer: "product"
EOF
awk -v f="$T/stale-node.yaml" '/^edges:/ { while ((getline l < f) > 0) print l } { print }' "$G" > "$T/g.tmp" && mv "$T/g.tmp" "$G"
(cd "$R" && bash .claude/tools/kg-cover.sh --target product src/app/Old.tsx > /dev/null 2>&1) || true
_live=$(awk '/^  - id: /{p="";s=""} /^    path: "src\/app\/Old.tsx"$/{p=1} /^    status: /{s=$2} p && s != "" && s != "\"stale\"" {print; p=""}' "$G" | wc -l | tr -d ' ')
eq "$_live" "1" "kg-cover scaffolds a live node for a path whose only node is stale"
rc=0; bash "$R/.claude/tools/kg-validate.sh" --strict --file "$G" > /dev/null 2>&1 || rc=$?
eq "$rc" "0" "...under a distinct id, so the graph still validates"

# Two paths that sanitise to the same id must not collide.
echo x > "$R/src/app/a_b.ts"; echo x > "$R/src/app/a-b.ts"
(cd "$R" && bash .claude/tools/kg-cover.sh --target product src/app/a_b.ts src/app/a-b.ts > /dev/null 2>&1) || true
eq "$(grep -c '^    path: "src/app/a[-_]b.ts"$' "$G")" "2" "kg-cover adds both a_b.ts and a-b.ts"
rc=0; bash "$R/.claude/tools/kg-validate.sh" --strict --file "$G" > "$T/v.out" 2>&1 || rc=$?
eq "$rc" "0" "...under distinct ids (no duplicate-id violation)"

# Readers must tolerate edges to nodes that no longer exist: every edge a child
# drew to a template node (hook-phase-helper, ...) dangles once graph.yaml goes.
for t in kg-relevance.sh kg-query.sh kg-merge-deltas.sh; do cp "$REAL_ROOT/.claude/tools/$t" "$R/.claude/tools/"; done
cat >> "$G" <<'EOF'
  - source: "product-src-app-panel-tsx"
    target: "hook-phase-helper"
    relation: "depends-on"
    context: "drawn to a template node before Amendment 9"
    source_type: "agent-inferred"
    last_verified: "2026-10-25"
    status: "active"
EOF
rc=0; (cd "$R" && bash .claude/tools/kg-relevance.sh src/app/Panel.tsx > "$T/rel.out" 2>&1) || rc=$?
eq "$rc" "0" "kg-relevance runs over an edge to a retired template node"
if command -v python3 > /dev/null 2>&1 || command -v yq > /dev/null 2>&1; then
  rc=0; (cd "$R" && bash .claude/tools/kg-query.sh stats > "$T/q.out" 2>&1) || rc=$?
  eq "$rc" "0" "kg-query stats runs over the same graph"
else
  ok "kg-query stats skipped — neither python3 nor yq is installed"
fi

# A task-group delta still aimed at the retired template graph is dropped, loudly,
# and writes nothing; a product delta in the same run still applies.
mkdir -p "$R/.claude/.state"
printf 'target: "template"\nauthored_at: "2026-10-25T00:00:00Z"\nbrief_seq: 1\nnodes:\n  - id: "hook-x"\n    type: "hook"\n    path: ".claude/hooks/x.sh"\n    description: "an old template node"\n    last_verified: "2026-10-25"\n    status: "active"\n    layer: "template"\nedges:\n' \
  > "$R/.claude/.state/tg-demo-brief-1.kg-delta.yaml"
printf 'target: "product"\nauthored_at: "2026-10-25T00:00:00Z"\nbrief_seq: 2\nnodes:\n  - id: "product-src-app-new-ts"\n    type: "file"\n    path: "src/app/new.ts"\n    description: "Computes the totals shown at checkout"\n    last_verified: "2026-10-25"\n    status: "active"\n    layer: "product"\nedges:\n' \
  > "$R/.claude/.state/tg-demo-brief-2.kg-delta.yaml"
rc=0; (cd "$R" && bash .claude/tools/kg-merge-deltas.sh demo > "$T/merge.out" 2>&1) || rc=$?
if grep -q "retired" "$T/merge.out"; then ok "kg-merge-deltas drops a template-target delta, saying why"; else nok "kg-merge-deltas drops a template-target delta, saying why" "$(cat "$T/merge.out")"; fi
if [ -f "$R/docs/ai/knowledge-graph/graph.yaml" ]; then nok "...and does not recreate graph.yaml"; else ok "...and does not recreate graph.yaml"; fi
if grep -q '"src/app/new.ts"' "$G"; then ok "...while the product delta in the same run is applied"; else nok "...while the product delta in the same run is applied" "rc=$rc $(tail -3 "$T/merge.out")"; fi

# Mode guard: a child must be able to write the two files it owns. coverage.yaml
# is the per-repo scope the product-graph gate reads; without a carve-out a
# child session could not create it at all (it fell to the default `return 1`).
# graph.yaml is gone and nothing else under knowledge-graph/ is child-writable.
_carved() { ( source "$REAL_ROOT/.claude/hooks/_mode-guard-helper.sh" && is_carved_out child "$1" ) > /dev/null 2>&1; }
for p in docs/ai/knowledge-graph/product-graph.yaml docs/ai/knowledge-graph/coverage.yaml; do
  if _carved "$p"; then ok "child mode may write $p"; else nok "child mode may write $p"; fi
done
for p in docs/ai/knowledge-graph/schema.yaml docs/ai/knowledge-graph/README.md docs/ai/knowledge-graph/graph.yaml; do
  if _carved "$p"; then nok "child mode may NOT write $p"; else ok "child mode may NOT write $p"; fi
done

printf '\n1..%d\n# pass %d / fail %d\n' "$_N" "$_P" "$_F"
if [ "$_F" -gt 0 ]; then printf '%b' "$_FAILS"; exit 1; fi
exit 0
