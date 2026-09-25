#!/usr/bin/env bash
# sync-conformance — behavioural tests for template-sync-engine.sh.
#
# Builds a real template repo, a real child repo and a bare origin in a
# sandbox, then runs the actual engine against them and asserts on the result.
# No mocks: the engine is exercised exactly as it runs in a child's CI.
#
# The load-bearing case is SAFETY: a child's own hooks and agents must survive
# a sync that removes template files. The withdrawn-file sweep deletes on a
# manifest diff precisely so that it cannot touch child-authored files, and
# test 5 is what holds that guarantee in place.
#
# Deliberately independent of .claude/hooks/tests/ — do not merge the two.
#
# Usage: bash .claude/tools/sync-conformance.sh
# Decision t-0051

set -uo pipefail

TEMPLATE_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$TEMPLATE_ROOT/.claude/.automation/lib/template-sync-engine.sh"
SANDBOX=""
PASS=0
FAIL=0

# KEEP_SANDBOX=1 leaves the sandbox in place for inspection after a failure.
cleanup() {
  if [ "${KEEP_SANDBOX:-0}" = "1" ] && [ -n "$SANDBOX" ]; then
    printf '\nsandbox kept: %s\n' "$SANDBOX"
    return
  fi
  [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
}
trap cleanup EXIT

ok()   { printf 'ok   %s\n' "$1"; PASS=$((PASS+1)); }
nok()  { printf 'NOT OK %s\n     %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }

assert_file()     { if [ -e "$1" ]; then ok "$2"; else nok "$2" "expected present: $1"; fi; }
assert_no_file()  { if [ ! -e "$1" ]; then ok "$2"; else nok "$2" "expected absent: $1"; fi; }
assert_grep()     { if grep -q "$1" "$2" 2>/dev/null; then ok "$3"; else nok "$3" "pattern '$1' not in $2"; fi; }
assert_no_grep()  { if grep -q "$1" "$2" 2>/dev/null; then nok "$3" "pattern '$1' unexpectedly in $2"; else ok "$3"; fi; }

git_q() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Sandbox construction
# ---------------------------------------------------------------------------
build_sandbox() {
  SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/sync-conformance.XXXXXX")
  TPL="$SANDBOX/template"
  CHILD="$SANDBOX/child"
  ORIGIN="$SANDBOX/origin.git"

  # --- template repo -------------------------------------------------------
  mkdir -p "$TPL/.claude/hooks" "$TPL/.claude/agents" "$TPL/.claude/.automation/lib" \
           "$TPL/docs/ai/decisions" "$TPL/docs/ai/logs"
  git_q "$TPL" init
  git_q "$TPL" checkout -b main

  # the real helpers under test, so the child gets working copies
  cp "$TEMPLATE_ROOT/.claude/.automation/lib/rebuild-trigger-index.sh" "$TPL/.claude/.automation/lib/"
  cp "$TEMPLATE_ROOT/.claude/.automation/lib/child-sync-decisions.sh"  "$TPL/.claude/.automation/lib/"

  printf 'shipped hook v1\n'  > "$TPL/.claude/hooks/kept-hook.sh"
  printf 'withdrawn later\n'  > "$TPL/.claude/hooks/doomed-hook.sh"
  printf 'agent\n'            > "$TPL/.claude/agents/critic.md"
  printf '# ignored by sync\n' > "$TPL/docs/ai/logs/session-log.md"

  cat > "$TPL/docs/ai/decisions/t-0001-template-decision.md" <<'EOF'
# t-0001
## Triggers
- type: file
- path: `\.claude/hooks/`
- keywords: `hooks`
EOF
  printf 't-0001-template-decision.md\n' > "$TPL/docs/ai/decisions/t-manifest.txt"

  cat > "$TPL/.gitignore" <<'EOF'
# BEGIN REPO-OS MANAGED — template-sync, see AI.md
node_modules/
.claude/.state/
# END REPO-OS MANAGED
EOF

  cat > "$TPL/.templatesyncignore" <<'EOF'
docs/ai/logs/
docs/ai/decisions/.a1-trigger-index
.gitignore
EOF

  # manifest listing exactly what sync delivers
  write_manifest "$TPL" \
    ".claude/.automation/lib/child-sync-decisions.sh" \
    ".claude/.automation/lib/rebuild-trigger-index.sh" \
    ".claude/.automation/machinery-manifest.txt" \
    ".claude/agents/critic.md" \
    ".claude/hooks/doomed-hook.sh" \
    ".claude/hooks/kept-hook.sh" \
    ".templatesyncignore" \
    "docs/ai/decisions/t-0001-template-decision.md" \
    "docs/ai/decisions/t-manifest.txt"

  git_q "$TPL" add -A
  git_q "$TPL" commit -m "template v1"

  # --- child repo ----------------------------------------------------------
  git init --bare "$ORIGIN" >/dev/null 2>&1
  git clone "$ORIGIN" "$CHILD" >/dev/null 2>&1
  git_q "$CHILD" checkout -b main
  mkdir -p "$CHILD/.claude/hooks" "$CHILD/.claude/agents" "$CHILD/.claude/.automation/lib" \
           "$CHILD/docs/ai/decisions" "$CHILD/src"

  # child's OWN files — these must survive every sync
  printf 'child hook\n'  > "$CHILD/.claude/hooks/child-only-hook.sh"
  printf 'child agent\n' > "$CHILD/.claude/agents/child-only-agent.md"
  printf 'product\n'     > "$CHILD/src/app.ts"

  # the child's own decision — its triggers must end up in the rebuilt index
  cat > "$CHILD/docs/ai/decisions/0100-child-decision.md" <<'EOF'
# 0100
## Triggers
- type: file
- path: `src/`
- keywords: `childtrigger`
EOF

  cat > "$CHILD/.gitignore" <<'EOF'
# BEGIN REPO-OS MANAGED — template-sync, see AI.md
stale-entry/
# END REPO-OS MANAGED

# child's own entries — must be preserved
dist/
.env.local
EOF

  git_q "$CHILD" add -A
  git_q "$CHILD" commit -m "child v1"
  git_q "$CHILD" push -u origin main
}

write_manifest() {
  local root="$1"; shift
  mkdir -p "$root/.claude/.automation"
  {
    printf '# Template Machinery Manifest — GENERATED. Do not hand-edit.\n'
    for f in "$@"; do printf '%s\n' "$f"; done
  } > "$root/.claude/.automation/machinery-manifest.txt"
}

run_engine() {
  ( cd "$CHILD" && bash "$ENGINE" "file://$TPL" main ) > "$SANDBOX/engine.log" 2>&1
  printf '%s' "$?" > "$SANDBOX/engine.rc"
}

# ---------------------------------------------------------------------------
printf '# sync-conformance — real engine, real repos\n'
printf '# safety invariant: child-authored files survive every sync\n\n'

build_sandbox

# === Sync 1: child has no previous manifest (first sync after t-0051) =======
printf '## sync 1 — first sync, no previous manifest\n'
# simulate pre-t-0051 child: no manifest present
rm -f "$CHILD/.claude/.automation/machinery-manifest.txt"
run_engine

assert_file    "$CHILD/.claude/hooks/kept-hook.sh"        "delivers template files"
assert_file    "$CHILD/.claude/hooks/doomed-hook.sh"      "delivers a file that will later be withdrawn"
assert_no_file "$CHILD/docs/ai/logs/session-log.md"       "honours .templatesyncignore (docs/ai/logs/)"
assert_file    "$CHILD/.claude/hooks/child-only-hook.sh"  "child's own hook survives"
if grep -qi "skipping withdrawn-file sweep" "$SANDBOX/engine.log"; then
  ok "skips sweep when no previous manifest (fail-safe)"
else
  nok "skips sweep when no previous manifest (fail-safe)" "$(grep -i manifest "$SANDBOX/engine.log" | head -2)"
fi

# .gitignore merge — the BSD awk regression
assert_grep    "node_modules/"  "$CHILD/.gitignore" "gitignore: managed block updated from template"
assert_no_grep "stale-entry/"   "$CHILD/.gitignore" "gitignore: superseded managed entry removed"
assert_grep    "dist/"          "$CHILD/.gitignore" "gitignore: child's own entries preserved"
assert_grep    "\.env\.local"   "$CHILD/.gitignore" "gitignore: all child entries preserved"
if [ -s "$CHILD/.gitignore" ]; then ok "gitignore: file is non-empty (BSD awk regression)"
else nok "gitignore: file is non-empty (BSD awk regression)" "file was emptied"; fi

# A1 index rebuilt locally, and covers the CHILD's decision
assert_file "$CHILD/docs/ai/decisions/.a1-trigger-index" "A1 index created in the child"
assert_grep "childtrigger" "$CHILD/docs/ai/decisions/.a1-trigger-index" \
            "A1 index indexes the CHILD's own decision (the enforcement gap)"
assert_grep "hooks" "$CHILD/docs/ai/decisions/.a1-trigger-index" \
            "A1 index also indexes template decisions"

# === Sync 2: template withdraws a file =====================================
printf '\n## sync 2 — template withdraws doomed-hook.sh\n'
rm -f "$TPL/.claude/hooks/doomed-hook.sh"
write_manifest "$TPL" \
  ".claude/.automation/lib/child-sync-decisions.sh" \
  ".claude/.automation/lib/rebuild-trigger-index.sh" \
  ".claude/.automation/machinery-manifest.txt" \
  ".claude/agents/critic.md" \
  ".claude/hooks/kept-hook.sh" \
  ".templatesyncignore" \
  "docs/ai/decisions/t-0001-template-decision.md" \
  "docs/ai/decisions/t-manifest.txt"
git_q "$TPL" add -A
git_q "$TPL" commit -m "template v2 — withdraw doomed-hook"
run_engine

assert_no_file "$CHILD/.claude/hooks/doomed-hook.sh"     "withdrawn template file is removed"
assert_file    "$CHILD/.claude/hooks/kept-hook.sh"       "still-shipped template file is kept"
assert_file    "$CHILD/.claude/hooks/child-only-hook.sh" "SAFETY: child's own hook survives the sweep"
assert_file    "$CHILD/.claude/agents/child-only-agent.md" "SAFETY: child's own agent survives the sweep"
assert_file    "$CHILD/src/app.ts"                       "SAFETY: product code untouched"
assert_file    "$CHILD/docs/ai/decisions/0100-child-decision.md" "SAFETY: child's own decision survives"

# === Sync 3: malformed incoming manifest must not delete anything ==========
printf '\n## sync 3 — empty incoming manifest (corruption guard)\n'
printf '# header only, no entries\n' > "$TPL/.claude/.automation/machinery-manifest.txt"
git_q "$TPL" add -A
git_q "$TPL" commit -m "template v3 — corrupt manifest"
run_engine

assert_grep "refusing to sweep" "$SANDBOX/engine.log" "refuses to sweep on an empty manifest"
assert_file "$CHILD/.claude/hooks/kept-hook.sh"       "no files deleted when manifest is empty"
assert_file "$CHILD/.claude/agents/critic.md"         "no agents deleted when manifest is empty"

# === Branch guard ==========================================================
printf '\n## branch guard\n'
git_q "$CHILD" checkout -b not-main
( cd "$CHILD" && bash "$ENGINE" "file://$TPL" main ) > "$SANDBOX/engine-branch.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -q "Must be on 'main'" "$SANDBOX/engine-branch.log"; then
  ok "refuses to run off main (git 2.19-safe branch detection)"
else
  nok "refuses to run off main (git 2.19-safe branch detection)" "rc=$rc $(head -3 "$SANDBOX/engine-branch.log")"
fi
git_q "$CHILD" checkout main

printf '\n------------------------------------------------------------\n'
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
printf -- '------------------------------------------------------------\n'
[ "$FAIL" -eq 0 ]
