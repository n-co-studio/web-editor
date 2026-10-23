#!/usr/bin/env bash
# Layer 9 — Mechanism-change classifier + pristine-evidence freshness (Decision t-0063).
#
# Covers .claude/hooks/_mechanism-helper.sh, the library the commit gate and
# .claude/tools/verify-pristine.sh share so they cannot disagree about what "the
# enforcement mechanism" is or what "fresh evidence" means:
#
#   L9.1  mech_is_path: hooks, tools, automation scripts and settings.json are the
#         mechanism; specs, decision records, agent prose and product code are not.
#   L9.2  mech_is_test_path: only copy-in-able test files; harness files
#         (test-helpers.sh, test-fixtures.sh, run-*.sh) are NOT test files, because
#         copying them in would let a change carry its own altered harness into the
#         "pristine" checkout.
#   L9.3  mech_filter keeps order and drops non-mechanism paths.
#   L9.4  mech_change_hash is deterministic, order-insensitive and content-bound.
#   L9.5  mech_evidence_status: none / stale / fresh, read from the INDEX (an
#         evidence file that is only in the working tree does not count), bound to
#         the hash AND to merge_base being an ancestor of HEAD.
#   L9.6  The idempotent marker is cleaned up at session close.
#
# Bash 3.2 compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/test-helpers.sh"

HELPER="$SCRIPT_DIR/../_mechanism-helper.sh"
CLEANUP="$SCRIPT_DIR/../_cleanup-helper.sh"

setup_sandbox

assert_file_exists "$HELPER" "L9.0 _mechanism-helper.sh exists"
if [ ! -f "$HELPER" ]; then
  finish_tests || true
  exit 1
fi
# shellcheck disable=SC1090
source "$HELPER"

_yes() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }

# --- L9.1 mechanism paths ---------------------------------------------------
tap_section "L9.1: mech_is_path"
for p in \
  .claude/hooks/pre-commit-gates.sh \
  .claude/hooks/_cleanup-helper.sh \
  .claude/hooks/tests/layer3-hook-integration.sh \
  .claude/hooks/tests/test-helpers.sh \
  .claude/tools/gate-conformance.sh \
  .claude/.automation/runner.sh \
  .claude/.automation/lib/work-preserver.sh \
  .claude/.automation/tests/test-work-preserver.sh \
  .claude/settings.json; do
  assert_eq "$(_yes mech_is_path "$p")" "0" "L9.1 mechanism: $p"
done
for p in \
  docs/spec/compiled/manifest.json \
  docs/ai/decisions/t-0062-preserve-uncommitted-work.md \
  docs/ai/logs/sessions/session-x.md \
  AI.md \
  .claude/agents/critic.md \
  .claude/hooks/README.md \
  .claude/.automation/RUNNER-PARITY.md \
  src/auth/login.ts \
  src/tests/auth.test.ts; do
  assert_neq "$(_yes mech_is_path "$p")" "0" "L9.1 not mechanism: $p"
done

# --- L9.2 test files vs harness ---------------------------------------------
tap_section "L9.2: mech_is_test_path"
for p in \
  .claude/hooks/tests/layer9-mechanism-change.sh \
  .claude/hooks/tests/layer3-hook-integration.sh \
  .claude/.automation/tests/test-work-preserver.sh \
  .claude/.automation/tests/test-verify-pristine.sh; do
  assert_eq "$(_yes mech_is_test_path "$p")" "0" "L9.2 test file: $p"
done
for p in \
  .claude/hooks/tests/test-helpers.sh \
  .claude/hooks/tests/test-fixtures.sh \
  .claude/hooks/tests/run-phase-tests.sh \
  .claude/.automation/tests/run-automation-tests.sh \
  .claude/hooks/pre-commit-gates.sh \
  .claude/tools/gate-conformance.sh \
  docs/ai/tests/test-notes.sh; do
  assert_neq "$(_yes mech_is_test_path "$p")" "0" "L9.2 harness / non-test: $p"
done

# --- L9.3 filter -------------------------------------------------------------
tap_section "L9.3: mech_filter"
_in=$'docs/spec/a.md\n.claude/hooks/x.sh\nsrc/y.ts\n.claude/tools/z.sh'
assert_eq "$(mech_filter "$_in")" $'.claude/hooks/x.sh\n.claude/tools/z.sh' "L9.3 keeps only mechanism paths, in order"
assert_eq "$(mech_filter $'docs/spec/a.md\nsrc/y.ts')" "" "L9.3 no mechanism paths -> empty"
assert_eq "$(mech_filter "")" "" "L9.3 empty input -> empty"

# --- A real repo for the hash / evidence cases --------------------------------
R="$_SANDBOX_DIR/r9"
mkdir -p "$R/.claude/hooks" "$R/.claude/tools" "$R/docs/ai/governance/pristine-evidence"
(
  cd "$R"
  git init -q .
  git config user.email t@t.local
  git config user.name T
  git config commit.gpgsign false
  echo base > README.md
  git add README.md
  git commit -q -m base
  git checkout -q -b feature/x
) >/dev/null 2>&1
BASE_SHA=$(git -C "$R" rev-parse HEAD)

_stage() { mkdir -p "$(dirname "$R/$1")"; printf '%s\n' "$2" > "$R/$1"; git -C "$R" add -f "$1"; }
_hash() { (cd "$R" && mech_change_hash "$1"); }

# --- L9.4 hash ----------------------------------------------------------------
tap_section "L9.4: mech_change_hash"
_stage .claude/hooks/a.sh "echo a"
_stage .claude/tools/b.sh "echo b"
H1=$(_hash $'.claude/hooks/a.sh\n.claude/tools/b.sh')
H2=$(_hash $'.claude/tools/b.sh\n.claude/hooks/a.sh')
assert_neq "$H1" "" "L9.4 non-empty hash for a non-empty set"
assert_eq "$H1" "$H2" "L9.4 order-insensitive"
_stage .claude/hooks/a.sh "echo a changed"
H3=$(_hash $'.claude/hooks/a.sh\n.claude/tools/b.sh')
assert_neq "$H1" "$H3" "L9.4 content change changes the hash"
assert_eq "$(_hash "")" "" "L9.4 empty set -> empty hash"
# Hash is of the INDEX blob, not the working tree: an unstaged edit must not move it.
printf 'unstaged edit\n' >> "$R/.claude/hooks/a.sh"
H4=$(_hash $'.claude/hooks/a.sh\n.claude/tools/b.sh')
assert_eq "$H3" "$H4" "L9.4 hash reads the index, ignores unstaged working-tree edits"
git -C "$R" checkout -q -- .claude/hooks/a.sh 2>/dev/null || true

# --- L9.5 evidence status ------------------------------------------------------
tap_section "L9.5: mech_evidence_status"
SET=$'.claude/hooks/a.sh\n.claude/tools/b.sh'
_status() { (cd "$R" && mech_evidence_status "$1"); }
EV="docs/ai/governance/pristine-evidence/e.yaml"
CUR=$(_hash "$SET")

assert_eq "$(_status "$SET")" "none" "L9.5 no evidence staged -> none"

# Evidence on disk but NOT in the index must not count.
printf 'merge_base: %s\nchange_hash: %s\noutcome: ran\npass: 4\nfail: 0\n' "$BASE_SHA" "$CUR" > "$R/$EV"
assert_eq "$(_status "$SET")" "none" "L9.5 evidence only in the working tree -> none"

git -C "$R" add -f "$EV"
assert_contains "$(_status "$SET")" "fresh" "L9.5 staged evidence with matching hash + ancestor merge_base -> fresh"
assert_contains "$(_status "$SET")" "pass=4" "L9.5 fresh status carries the pass count"
assert_contains "$(_status "$SET")" "fail=0" "L9.5 fresh status carries the fail count"

# A favourable-looking number is not evidence if the code moved afterwards.
_stage .claude/tools/b.sh "echo b edited after the run"
assert_eq "$(_status "$SET")" "stale" "L9.5 change after the run -> stale"
_stage .claude/tools/b.sh "echo b"

# merge_base must be an ancestor of HEAD.
printf 'merge_base: %s\nchange_hash: %s\noutcome: ran\npass: 4\nfail: 0\n' "0000000000000000000000000000000000000001" "$CUR" > "$R/$EV"
git -C "$R" add -f "$EV"
assert_eq "$(_status "$SET")" "stale" "L9.5 merge_base not an ancestor of HEAD -> stale"

# A failing run is still evidence (the gate demands a run, not a green one).
printf 'merge_base: %s\nchange_hash: %s\noutcome: ran\npass: 2\nfail: 3\n' "$BASE_SHA" "$CUR" > "$R/$EV"
git -C "$R" add -f "$EV"
assert_contains "$(_status "$SET")" "fresh" "L9.5 a run with failures is still fresh evidence"
assert_contains "$(_status "$SET")" "fail=3" "L9.5 ...and reports the failures"

# tool_error is surfaced distinctly so the gate can warn + escalate instead of deadlocking.
printf 'merge_base: %s\nchange_hash: %s\noutcome: tool_error\npass: 0\nfail: 0\n' "$BASE_SHA" "$CUR" > "$R/$EV"
git -C "$R" add -f "$EV"
assert_contains "$(_status "$SET")" "outcome=tool_error" "L9.5 tool_error outcome is reported"

# A run that executed nothing verified nothing: 'empty', not fresh.
printf 'merge_base: %s\nchange_hash: %s\noutcome: ran\npass: 0\nfail: 0\n' "$BASE_SHA" "$CUR" > "$R/$EV"
git -C "$R" add -f "$EV"
assert_eq "$(_status "$SET")" "empty" "L9.5 matching evidence with pass=0 fail=0 -> empty"
printf 'merge_base: %s\nchange_hash: %s\noutcome: ran\npass: lots\nfail: none\n' "$BASE_SHA" "$CUR" > "$R/$EV"
git -C "$R" add -f "$EV"
assert_eq "$(_status "$SET")" "empty" "L9.5 non-numeric counts are not trusted -> empty"
printf 'merge_base: %s\nchange_hash: %s\noutcome: tool_error\npass: 0\nfail: 0\n' "$BASE_SHA" "$CUR" > "$R/$EV"
git -C "$R" add -f "$EV"
assert_contains "$(_status "$SET")" "outcome=tool_error" "L9.5 tool_error with zero counts is still reported as tool_error, not empty"

# --- L9.4b deletions, mode flips and cwd (Critic cycle 1) ------------------------
# A deleted guard is the sharpest mechanism change there is, and the hash used to be
# computed from the index-or-nothing so a deletion hashed like "no change".
tap_section "L9.4b: deletion / mode / cwd"
R2="$_SANDBOX_DIR/r9b"
mkdir -p "$R2/.claude/hooks" "$R2/sub/dir"
(
  cd "$R2"
  git init -q .
  git config user.email t@t.local
  git config user.name T
  git config commit.gpgsign false
  echo 'echo guard' > .claude/hooks/g.sh
  echo 'echo other' > .claude/hooks/o.sh
  git add .claude/hooks/g.sh .claude/hooks/o.sh
  git commit -q -m base
) >/dev/null 2>&1
_hash2() { (cd "$R2" && mech_change_hash "$1"); }
SET2=$'.claude/hooks/g.sh'
HU=$(_hash2 "$SET2")
git -C "$R2" rm -q -- .claude/hooks/g.sh
HD=$(_hash2 "$SET2")
assert_neq "$HD" "" "L9.4b deleting a mechanism file still yields a hash"
assert_neq "$HU" "$HD" "L9.4b a staged deletion changes the hash"
git -C "$R2" reset -q HEAD -- .claude/hooks/g.sh
git -C "$R2" checkout -q -- .claude/hooks/g.sh
git -C "$R2" update-index --chmod=+x .claude/hooks/g.sh
HM=$(_hash2 "$SET2")
assert_neq "$HU" "$HM" "L9.4b a mode flip with identical content changes the hash"
HS=$(cd "$R2/sub/dir" && mech_change_hash "$SET2")
assert_eq "$HM" "$HS" "L9.4b the hash is the same from a subdirectory cwd"
git -C "$R2" rm -q -f -- .claude/hooks/g.sh
HD2=$(_hash2 "$SET2")
mkdir -p "$R2/docs/ai/governance/pristine-evidence"
printf 'merge_base: %s\nchange_hash: %s\noutcome: ran\npass: 2\nfail: 1\n' "$(git -C "$R2" rev-parse HEAD)" "$HD2" \
  > "$R2/docs/ai/governance/pristine-evidence/e.yaml"
git -C "$R2" add -f docs/ai/governance/pristine-evidence/e.yaml
ST=$(cd "$R2/sub/dir" && mech_evidence_status "$SET2")
assert_contains "$ST" "fresh" "L9.4b evidence is found and matched from a subdirectory cwd (deletion bound)"

# --- L9.6 cleanup ---------------------------------------------------------------
tap_section "L9.6: marker cleanup"
assert_eq "$(grep -v '^[[:space:]]*#' "$CLEANUP" | grep -c 'mechanism-change-detected' || true)" "1" \
  "L9.6 _cleanup-helper.sh removes mechanism-change-detected at session close"

finish_tests
