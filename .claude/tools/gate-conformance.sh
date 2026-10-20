#!/usr/bin/env bash
# gate-conformance.sh — independent conformance harness for the gate chain.
#
# WHY THIS EXISTS (read before editing)
# ------------------------------------
# This harness is deliberately NOT part of .claude/hooks/tests/. It shares no
# assertion code, no fixtures and no helpers with that suite, because that suite
# failed to detect a total fail-open of the commit gate. It failed for two
# independent reasons, both of which this file is built to avoid:
#
#   1. Wrong contract. tests/test-helpers.sh assert_fail() and assert_blocked()
#      pass on ANY non-zero exit. The Claude Code hook protocol blocks on exit 2
#      ONLY; any other non-zero is surfaced as a non-blocking error and the tool
#      call PROCEEDS. So a gate script that CRASHED with exit 1 scored green as
#      "blocks the commit". Here, every assertion states an exact exit code.
#
#   2. Wrong shape. The tests/ sandbox never creates docs/ai/decisions/, so the
#      entire A1 block -- guarded by `[ -d "$DECISIONS_DIR" ]` -- never executed
#      under test. The crash lived inside that block. Here the sandbox mirrors
#      the real repo: t-*.md decision records, NO 0*.md files, and a populated
#      trigger index whose mtime is older than the decisions (the normal state
#      after any decision edit or any git checkout).
#
# INVARIANT: nothing may be its own witness. This harness must never be invoked
# by a hook, and must never source _analytics-helper.sh, _phase-helper.sh or
# tests/test-helpers.sh for its ASSERTIONS. It uses the REPO_OS_TEST_MODE seam
# only to point the real hook scripts at a scratch repo.
#
# It lives in .claude/tools/ rather than a dedicated directory because template
# mode's carve-out list (_mode-guard-helper.sh) admits .claude/tools/* and not
# an arbitrary new path. Independence here is about not sharing assertion code,
# fixtures or an invocation path with the system under test -- not about which
# directory the file sits in.
#
# Usage:
#   bash .claude/tools/gate-conformance.sh        # run all cases
#   bash .claude/tools/gate-conformance.sh -v     # keep sandbox, print output
#
# Exit: 0 if every case matches its expected exit code, 1 otherwise.

set -uo pipefail   # deliberately NOT -e: a failing case must not abort the run

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

REAL_HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"

PASS=0
FAIL=0
FAILED_CASES=""

# Test fixture for the A4 secret gate, assembled from fragments at runtime.
# Written literally, this file would trip the very scan it exists to test —
# A4 excludes only _secret-pattern.sh — and could not be committed. Splitting
# the string keeps the gate's scan surface intact rather than widening the
# exclusion list to accommodate a test. (Verified: A4 blocked this commit until
# the literal was removed, which is itself evidence the gate works.)
_FAKE_AWS_KEY="AKIA""IOSFODNN7EXAMPLE"

# --- Independent assertion: exact exit code. ---
# Never "non-zero means blocked" -- that is the defect being corrected for.
# Presence/absence assertion sharing expect_exit's counters, for the cases that
# check a side effect on disk rather than an exit code.
expect_file() {
  local mode="$1" path="$2" desc="$3"   # mode: present | absent
  local okflag=1
  case "$mode" in
    present) [ -f "$path" ] && okflag=0 ;;
    absent)  [ -f "$path" ] || okflag=0 ;;
  esac
  if [ "$okflag" -eq 0 ]; then
    PASS=$((PASS + 1))
    printf 'ok   %-58s [%s]\n' "$desc" "$mode"
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES="${FAILED_CASES}    - ${desc} (expected ${mode}: ${path})"$'\n'
    printf 'FAIL %-58s [expected %s]\n' "$desc" "$mode"
  fi
}

expect_exit() {
  local expected="$1" actual="$2" desc="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1))
    printf 'ok   %-58s [exit %s]\n' "$desc" "$actual"
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES="${FAILED_CASES}    - ${desc} (expected ${expected}, got ${actual})"$'\n'
    printf 'FAIL %-58s [expected %s, got %s]\n' "$desc" "$expected" "$actual"
    if [ "$VERBOSE" = "1" ] && [ -n "${_OUT_FILE:-}" ] && [ -s "$_OUT_FILE" ]; then
      sed 's/^/       | /' "$_OUT_FILE"
    fi
  fi
}

# ============================================================
# Sandbox: a production-SHAPED scratch repo
# ============================================================
SB=""
SID="conformance-session-0001"

teardown() {
  if [ "$VERBOSE" = "1" ]; then
    printf '\nsandbox retained: %s\n' "$SB"
  elif [ -n "$SB" ] && [ -d "$SB" ]; then
    rm -rf "$SB"
  fi
}
trap teardown EXIT

build_sandbox() {
  # Hooks reject sandbox paths outside /tmp or /private/tmp; macOS TMPDIR is
  # /var/folders/... which would be rejected.
  case "${TMPDIR:-/tmp}" in
    /tmp/*|/private/tmp/*|/tmp|/private/tmp) ;;
    *) export TMPDIR=/private/tmp ;;
  esac
  SB=$(mktemp -d "${TMPDIR:-/tmp}/gate-conformance.XXXXXX")
  SB=$(cd "$SB" && pwd)   # canonicalise: hook prefix checks compare literally
  # Must be set HERE, in the parent shell. run_gate is always called as
  # `rc=$(run_gate ...)`, so the assignment inside it lands in a command
  # substitution subshell and never propagates — which left $_OUT_FILE empty in
  # every caller and silently disabled the VERBOSE=1 output dump for all cases.
  _OUT_FILE="$SB/.last-gate-output"

  mkdir -p "$SB/.claude/.state/sessions/$SID"
  mkdir -p "$SB/.claude/.state/wt-sessions/$SID"
  mkdir -p "$SB/docs/ai/decisions"
  mkdir -p "$SB/docs/ai/governance"
  mkdir -p "$SB/docs/ai/logs"
  mkdir -p "$SB/docs/spec/compiled"
  mkdir -p "$SB/src"

  echo "template" > "$SB/.claude/repo-mode"
  echo "$SID"     > "$SB/.claude/.session-id"

  printf '{\n  "active": null,\n  "versions": [],\n  "features": [],\n  "spec_digest_sha": ""\n}\n' \
    > "$SB/docs/spec/compiled/manifest.json"

  # --- Decision records: t-*.md ONLY, mirroring the real repo. ---
  # The real docs/ai/decisions/ holds 47 t-*.md files and ZERO 0*.md files.
  # That asymmetry is load-bearing: it is exactly what makes A1's digest
  # pipeline `ls "$DECISIONS_DIR"/t-*.md "$DECISIONS_DIR"/0*.md` return
  # non-zero. Omitting it is why the incumbent suite could not see the bug.
  _mk_decision() {
    local id="$1" slug="$2" path_re="$3" kw="$4"
    cat > "$SB/docs/ai/decisions/t-${id}-${slug}.md" <<EOF
# Decision ${id} — ${slug}

## Status
Accepted

## Triggers

- type: file
- path: \`${path_re}\`
- keywords: \`${kw}\`

## Decision

Conformance fixture decision record.
EOF
  }
  _mk_decision "0001" "baseline"        'AI\.md'                   'prompt system, verification gate'
  _mk_decision "0004" "mechanical"      '\.claude/hooks/.*\.sh'    'PreToolUse, PostToolUse, phase-state'
  _mk_decision "0012" "file-edits"      '\.claude/repo-mode'       'write-guard, mode-guard'
  _mk_decision "0034" "knowledge-graph" 'docs/ai/knowledge-graph/' 'graph, kg'
  _mk_decision "0035" "spec-loading"    'docs/spec/compiled/'      'spec digest, DIGEST.md'

  # A1 blocking sentinel (present in the real repo, 0 bytes).
  : > "$SB/docs/ai/decisions/.a1-triggers-enforced"

  # Compiled trigger index carrying a digest header that will NOT match a
  # freshly computed digest -- the real repo's current state.
  cat > "$SB/docs/ai/decisions/.a1-trigger-index" <<'IDX'
# A1 trigger index — generated artifact. Do not hand-edit.
# digest: 0000000000000000000000000000000000000000000000000000000000000000
0001|AI\.md|prompt system, verification gate
0004|\.claude/hooks/.*\.sh|PreToolUse, PostToolUse, phase-state
0012|\.claude/repo-mode|write-guard, mode-guard
0034|docs/ai/knowledge-graph/|graph, kg
0035|docs/spec/compiled/|spec digest, DIGEST.md
IDX

  # Make the index OLDER than the decision files so the staleness pre-filter
  # fires and the digest-recompute path is entered. Normal state after editing
  # any decision record, or after any git checkout.
  touch -t 202001010000 "$SB/docs/ai/decisions/.a1-trigger-index"

  echo "module.exports = {}" > "$SB/src/foo.ts"

  (
    cd "$SB"
    git init -q . 2>/dev/null
    git config user.email "conformance@test.local"
    git config user.name  "Conformance"
    git config commit.gpgsign false
    echo "init" > README.md
    git add -A
    git commit -q -m "initial commit"
    git checkout -q -b feature/conformance
  )

  export REPO_OS_TEST_MODE=1
  export _REPO_OS_TEST_ROOT="$SB"
}

# --- Evidence / phase state -------------------------------------------------
# Written to every candidate state dir so this harness does not depend on
# _phase-helper.sh's directory-resolution logic (which is itself under test).
_state_dirs() {
  echo "$SB/.claude/.state"
  echo "$SB/.claude/.state/sessions/$SID"
  echo "$SB/.claude/.state/wt-sessions/$SID"
}

write_phase_state() {
  local phase="$1" stype="${2:-standard}" mode="${3:-review}" d
  for d in $(_state_dirs); do
    mkdir -p "$d"
    cat > "$d/phase-state" <<EOF
session_type: $stype
session_id: $SID
session_log_id: $SID
mode: $mode
current_phase: $phase
cycle: 1
phases_completed: init,plan,approval,build,review,verify
solo: false
tag: agent
timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  done
}

write_full_evidence() {
  local large_scope="${1:-true}" ts d
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  for d in $(_state_dirs); do
    mkdir -p "$d"
    printf 'timestamp: %s\nquestion_hash: conformancehash\nlarge-scope: %s\nmode: review\nsession_id: %s\n' \
      "$ts" "$large_scope" "$SID" > "$d/plan-approved"
    printf 'timestamp: %s\nagent: critic\nsession_id: %s\ndispatch_phase: review\nGATE_RESULT: APPROVED\n' \
      "$ts" "$SID" > "$d/cohesion-reviewed"
    printf 'timestamp: %s\nagent: critic\nsession_id: %s\ndispatch_phase: review\nGATE_RESULT: APPROVED\n' \
      "$ts" "$SID" > "$d/diff-review-complete"
    printf 'timestamp: %s\nagent: qa-verifier\nsession_id: %s\ndispatch_phase: verify\nGATE_RESULT: APPROVED\n' \
      "$ts" "$SID" > "$d/qa-verified"
    printf 'timestamp: %s\nagent: pragmatist\nsession_id: %s\ndispatch_phase: plan\nGATE_RESULT: APPROVED\n' \
      "$ts" "$SID" > "$d/pragmatist-signed"
  done
}

clear_state() {
  rm -rf "$SB/.claude/.state"
  mkdir -p "$SB/.claude/.state/sessions/$SID" "$SB/.claude/.state/wt-sessions/$SID"
}

reset_worktree() {
  ( cd "$SB" && git reset -q HEAD . 2>/dev/null; git checkout -q -- . 2>/dev/null; git clean -qfd 2>/dev/null )
  ( cd "$SB" && git checkout -q feature/conformance 2>/dev/null )
}

stage() {
  local rel="$1" content="$2"
  mkdir -p "$(dirname "$SB/$rel")"
  printf '%s\n' "$content" > "$SB/$rel"
  ( cd "$SB" && git add -f "$rel" )
}

# --- Run a hook with a PreToolUse payload, return its exit code -------------
# run_gate is called as `rc=$(run_gate ...)`, which runs it in a subshell — so
# a plain global assignment to LAST_OUTPUT would not survive back to the
# caller, and `-v` would print nothing on failure. Stash the hook output in a
# temp file (which does outlive the subshell) and have expect_exit read it.
LAST_OUTPUT=""
_OUT_FILE=""
run_gate() {
  local hook="$1" cmd="$2" rc=0 payload
  payload=$(printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$SID" "$cmd")
  [ -n "$_OUT_FILE" ] || _OUT_FILE="$SB/.last-gate-output"
  (cd "$SB" && printf '%s' "$payload" | bash "$REAL_HOOKS/$hook" > "$_OUT_FILE" 2>&1) || rc=$?
  echo "$rc"
}

# ============================================================
# Cases
# ============================================================
printf '# gate conformance — real hooks, production-shaped sandbox\n'
printf '# contract: exit 2 blocks the tool call; exit 0 allows. Nothing else blocks.\n\n'

build_sandbox

printf '## pre-commit-gates.sh\n'

# C1 — the allow path must be a clean 0, not merely "not 2".
reset_worktree; clear_state; write_phase_state "commit"; write_full_evidence
stage "docs/ai/logs/note.md" "a benign note"
rc=$(run_gate "pre-commit-gates.sh" "git commit -m chore-benign")
expect_exit 0 "$rc" "allows a clean commit at commit phase with full evidence"

# C2 — A4 is documented as always-on and blocking. This is the case that
#      exposed the fail-open: the gate PRINTS the finding and exits 1.
reset_worktree; clear_state; write_phase_state "commit"; write_full_evidence
stage "docs/ai/logs/leak.md" "$_FAKE_AWS_KEY"
rc=$(run_gate "pre-commit-gates.sh" "git commit -m chore-leak")
expect_exit 2 "$rc" "A4 blocks a staged AWS access key"

# C3 — phase gate
reset_worktree; clear_state; write_phase_state "build"; write_full_evidence
stage "docs/ai/logs/note.md" "work in progress"
rc=$(run_gate "pre-commit-gates.sh" "git commit -m chore-early")
expect_exit 2 "$rc" "phase gate blocks a commit while phase is build"

# C4 — fail-closed when the session never called init_phase
reset_worktree; clear_state
stage "docs/ai/logs/note.md" "no phase state"
rc=$(run_gate "pre-commit-gates.sh" "git commit -m chore-nostate")
expect_exit 2 "$rc" "blocks when phase-state is absent (fail-closed)"

# C5 — A5 cohesion evidence missing
reset_worktree; clear_state; write_phase_state "commit"; write_full_evidence
for _d in $(_state_dirs); do rm -f "$_d/cohesion-reviewed"; done
stage "docs/ai/logs/note.md" "unreviewed"
rc=$(run_gate "pre-commit-gates.sh" "git commit -m chore-unreviewed")
expect_exit 2 "$rc" "A5 blocks when cohesion-reviewed is missing"

# C6 — A2 scope ceiling without large-scope approval
reset_worktree; clear_state; write_phase_state "commit"; write_full_evidence "false"
_big=$(awk 'BEGIN{for(i=0;i<150;i++) print "line " i}')
stage "docs/ai/logs/big.md" "$_big"
rc=$(run_gate "pre-commit-gates.sh" "git commit -m chore-big")
expect_exit 2 "$rc" "A2 blocks a 150-line diff without large-scope approval"

# C7 — A1 trailer. Touching .claude/hooks/*.sh with a decision keyword in the
#      added lines must require a Decisions: trailer naming 0004.
reset_worktree; clear_state; write_phase_state "commit"; write_full_evidence
stage ".claude/hooks/probe-hook.sh" "# PreToolUse handler added here"
rc=$(run_gate "pre-commit-gates.sh" "git commit -m chore-hookchange")
expect_exit 2 "$rc" "A1 blocks a triggered decision with no Decisions: trailer"

# C8 — the same change WITH the trailer must pass.
reset_worktree; clear_state; write_phase_state "commit"; write_full_evidence
stage ".claude/hooks/probe-hook.sh" "# PreToolUse handler added here"
rc=$(run_gate "pre-commit-gates.sh" "git commit -m chore-hookchange -m Decisions: 0004")
expect_exit 0 "$rc" "A1 allows a triggered decision when the trailer names it"

# C8a — the SAME change, trailer delivered via `git commit -F <file>`.
#       This is the regression that mattered: C7/C8 only ever exercised -m, so
#       a trailer in a -F file was invisible to the gate and A1 blocked a
#       correct commit. Nothing in the prompts prescribes an invocation form,
#       and a multi-line message naturally wants -F.
reset_worktree; clear_state; write_phase_state "commit"; write_full_evidence
stage ".claude/hooks/probe-hook.sh" "# PreToolUse handler added here"
printf 'chore: hook change\n\nDecisions: 0004\n' > "$SB/.git/COMMIT_MSG_PROBE"
rc=$(run_gate "pre-commit-gates.sh" "git commit -F $SB/.git/COMMIT_MSG_PROBE")
expect_exit 0 "$rc" "A1 allows a triggered decision when the trailer is in a -F file"

# C8b — -F file WITHOUT the trailer must still block. Proves the fix reads the
#       file's content rather than merely detecting that -F was used.
reset_worktree; clear_state; write_phase_state "commit"; write_full_evidence
stage ".claude/hooks/probe-hook.sh" "# PreToolUse handler added here"
printf 'chore: hook change\n\nno trailer here\n' > "$SB/.git/COMMIT_MSG_PROBE"
rc=$(run_gate "pre-commit-gates.sh" "git commit -F $SB/.git/COMMIT_MSG_PROBE")
expect_exit 2 "$rc" "A1 still blocks when the -F file carries no trailer"

# C8c — the documented residual. PreToolUse fires before the command runs, so a
#       -F file built by that same command line does not exist yet. Behaviour
#       must fall back to today's: command string only, so A1 blocks. Asserted
#       so the limit is a known property, not a surprise. See t-0053.
reset_worktree; clear_state; write_phase_state "commit"; write_full_evidence
stage ".claude/hooks/probe-hook.sh" "# PreToolUse handler added here"
rc=$(run_gate "pre-commit-gates.sh" "git commit -F $SB/.git/DOES_NOT_EXIST_YET")
expect_exit 2 "$rc" "A1 blocks when the -F file is not yet written (documented limit)"

# C8d — the recovery signal must SURVIVE a commit it did not unblock. It covers
#       state-dependent gates only; A1 can still block afterwards, and deleting
#       the token on sight spent it on a commit that never happened.
reset_worktree; clear_state; write_phase_state "commit"; write_full_evidence
stage ".claude/hooks/probe-hook.sh" "# PreToolUse handler added here"
mkdir -p "$SB/.claude/.state"; : > "$SB/.claude/.state/.recover-signal"
rc=$(run_gate "pre-commit-gates.sh" "git commit -m chore-hookchange")
expect_exit 2 "$rc" "blocked by A1 even with the recovery signal armed"
expect_file present "$SB/.claude/.state/.recover-signal" \
            "recovery signal survives a commit it did not unblock"

# C8e — and it IS consumed when the commit actually proceeds.
reset_worktree; clear_state; write_phase_state "commit"; write_full_evidence
stage ".claude/hooks/probe-hook.sh" "# PreToolUse handler added here"
mkdir -p "$SB/.claude/.state"; : > "$SB/.claude/.state/.recover-signal"
rc=$(run_gate "pre-commit-gates.sh" "git commit -m chore-hookchange -m Decisions: 0004")
expect_exit 0 "$rc" "commit proceeds with the trailer present"
expect_file absent "$SB/.claude/.state/.recover-signal" \
            "recovery signal is consumed when the commit proceeds"

# C9 — experiment branches are exempt from state checks by design, but A4 is
#      documented as running on every branch.
reset_worktree; clear_state
( cd "$SB" && git checkout -q -b experiment/conformance 2>/dev/null || git checkout -q experiment/conformance )
stage "docs/ai/logs/leak.md" "$_FAKE_AWS_KEY"
rc=$(run_gate "pre-commit-gates.sh" "git commit -m chore-expleak")
expect_exit 2 "$rc" "A4 blocks a secret even on an experiment branch"

# C10 — a clean experiment commit is allowed
reset_worktree; clear_state
( cd "$SB" && git checkout -q experiment/conformance 2>/dev/null || git checkout -q -b experiment/conformance )
stage "docs/ai/logs/note.md" "experiment note"
rc=$(run_gate "pre-commit-gates.sh" "git commit -m chore-expclean")
expect_exit 0 "$rc" "allows a clean commit on an experiment branch"

# C11/C12 — provenance markers. The gate requires a dispatch_phase / source
# marker on governance evidence so a hand-written state file is rejected. That
# requirement shipped with NO test coverage anywhere, and silently invalidated
# the fixtures in tests/layer3-hook-integration.sh for months without anyone
# seeing it, because the suite was not run automatically. Cover it here.
reset_worktree; clear_state; write_phase_state "commit"; write_full_evidence
for _d in $(_state_dirs); do
  printf 'timestamp: t\nagent: critic\nsession_id: %s\nGATE_RESULT: APPROVED\n' "$SID" > "$_d/cohesion-reviewed"
done
stage "docs/ai/logs/note.md" "hand-written cohesion evidence"
rc=$(run_gate "pre-commit-gates.sh" "git commit -m chore-noprov")
expect_exit 2 "$rc" "A5 blocks cohesion-reviewed with no dispatch_phase marker"

reset_worktree; clear_state; write_phase_state "commit"; write_full_evidence
for _d in $(_state_dirs); do
  printf 'timestamp: t\nagent: pragmatist\nsession_id: %s\nGATE_RESULT: APPROVED\n' "$SID" > "$_d/pragmatist-signed"
done
stage "docs/ai/logs/note.md" "hand-written pragmatist evidence"
rc=$(run_gate "pre-commit-gates.sh" "git commit -m chore-noprov2")
expect_exit 2 "$rc" "blocks pragmatist-signed with no provenance marker"

printf '\n## pre-push-gates.sh\n'

# C11/C12 — B1 branch naming
reset_worktree; clear_state; write_phase_state "commit"; write_full_evidence
( cd "$SB" && git checkout -q -b nonconforming-branch-name 2>/dev/null || git checkout -q nonconforming-branch-name )
rc=$(run_gate "pre-push-gates.sh" "git push origin HEAD")
expect_exit 2 "$rc" "B1 blocks a push from a non-conforming branch name"

( cd "$SB" && git checkout -q feature/conformance )
rc=$(run_gate "pre-push-gates.sh" "git push origin HEAD")
expect_exit 0 "$rc" "B1 allows a push from feature/*"

# ============================================================
printf '\n## uninitialized session must block, not crash\n'

# An absent session state dir is a governance condition the gate must REPORT.
# Before 2026-10-15 the A3.4 functional-verified write was the only one of the
# three $STATE_DIR writes without a guard, so under `set -euo pipefail` it fired
# the ERR trap and the whole chain died as "GATE-FINAL ... aborted unexpectedly
# ... this is a gate defect (no override)" — a condition with no override and no
# correct next step. Found in the child repo n-co-studio/web-editor, where it
# blocked a documentation commit across three sessions.
#
# The verdict must not change: an uninitialized session still cannot commit.
# What must change is the failure MODE.
expect_output_lacks() {
  local pattern="$1" desc="$2"
  if [ -s "${_OUT_FILE:-}" ] && grep -qF "$pattern" "$_OUT_FILE"; then
    FAIL=$((FAIL + 1))
    FAILED_CASES="${FAILED_CASES}    - ${desc} (output contained '${pattern}')"$'\n'
    printf 'FAIL %-58s [found "%s"]\n' "$desc" "$pattern"
    [ "$VERBOSE" = "1" ] && sed 's/^/       | /' "$_OUT_FILE"
  else
    PASS=$((PASS + 1))
    printf 'ok   %-58s [absent]\n' "$desc"
  fi
}
expect_output_has() {
  local pattern="$1" desc="$2"
  if [ -s "${_OUT_FILE:-}" ] && grep -qF "$pattern" "$_OUT_FILE"; then
    PASS=$((PASS + 1))
    printf 'ok   %-58s [present]\n' "$desc"
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES="${FAILED_CASES}    - ${desc} (output lacked '${pattern}')"$'\n'
    printf 'FAIL %-58s [missing "%s"]\n' "$desc" "$pattern"
    [ "$VERBOSE" = "1" ] && [ -s "${_OUT_FILE:-}" ] && sed 's/^/       | /' "$_OUT_FILE"
  fi
}

reset_worktree; clear_state
rm -rf "$SB/.claude/.state/wt-sessions"
# A package.json is REQUIRED for this case to exercise anything: without one,
# A3.4 skips before reaching the write, so the case passes whether the write is
# guarded or not — a test that cannot fail. The child repo where this was found
# had a package.json, which is why it ran the write and crashed. No scripts are
# declared, so A3.4 finds nothing to run, passes, and reaches the write.
printf '{\n  "name": "conformance-fixture",\n  "version": "0.0.0",\n  "private": true\n}\n' > "$SB/package.json"
( cd "$SB" && git add -f package.json )
stage "docs/ai/logs/uninit.md" "a benign note committed from an uninitialized session"
rc=$(run_gate "pre-commit-gates.sh" "git commit -m chore-uninitialized")
expect_exit 2 "$rc" "scriptless package.json still BLOCKS (no fail-open to exit 1)"
expect_output_has "Phase state not initialized" "scriptless package.json names the real condition"

# Second fixture: a package.json that declares a PASSING script. Without one,
# A3.4 collects no commands and the empty-array expansion killed the script
# before execution ever reached the functional-verified write — so the case
# above cannot exercise the unguarded write, only the fail-open. This one runs
# a trivially-passing `test`, reaches the write with $STATE_DIR absent, and is
# the case that reproduces the GATE-FINAL abort seen in the child repo.
# Skipped when npm is unavailable: A3.4 then takes its npm-missing branch and
# never reaches the write, which would make the assertions vacuous.
if command -v npm > /dev/null 2>&1; then
  reset_worktree; clear_state
  rm -rf "$SB/.claude/.state/wt-sessions"
  printf '{\n  "name": "conformance-fixture",\n  "version": "0.0.0",\n  "private": true,\n  "scripts": { "test": "true" }\n}\n' > "$SB/package.json"
  ( cd "$SB" && git add -f package.json )
  stage "docs/ai/logs/uninit2.md" "a benign note"
  rc=$(run_gate "pre-commit-gates.sh" "git commit -m chore-uninitialized-with-scripts")
  expect_exit 2 "$rc" "absent state dir blocks when A3.4 reaches the write"
  expect_output_lacks "aborted unexpectedly" "the A3.4 write does not abort the gate chain"
  expect_output_lacks "this is a gate defect" "the A3.4 write is not reported as a gate defect"
  expect_output_has "Phase state not initialized" "the real condition is still named"
else
  printf 'skip %-58s [npm unavailable]\n' "A3.4 write reached with absent state dir"
fi

# Remove the fixture explicitly. reset_worktree's `git clean -fd` does NOT remove
# ignored files, so if a future sandbox ever gitignores package.json this would
# leak into whatever case runs next and silently change its A3.4 applicability.
rm -f "$SB/package.json"
( cd "$SB" && git rm -q --cached --ignore-unmatch package.json > /dev/null 2>&1 || true )

# --- Task group contracts must be resolvable from the MAIN repo ------------
# A contract belongs to the GROUP, not to one brief. Inside a worktree session
# $REPO_ROOT is the worktree root, so a consumer that resolves contracts ONLY
# from $REPO_ROOT reads a per-brief private copy — and `git worktree remove`
# then destroys the group's definition of done. That happened to
# task-details-header on 2026-10-19 and left every later brief unable to commit
# anything, because A6.1 requires a contract with `status: in_progress`.
#
# The invariant: any file that resolves a task-group contract directory must
# ALSO resolve the main repo root, so it can search there too. Two files are
# exempt because they are immune paths whose patterns deliberately match what an
# agent writes (session-relative): write-guard.sh and bash-guard.sh.
#
# This check exists because a hand survey of the consumers MISSED three of them
# — including A6.1 itself, the gate that made the failure unrecoverable.
#
# WHAT IT DOES NOT CATCH, stated plainly so it is not mistaken for more than it
# is. It asserts that a consumer file resolves the main root AT ALL; it cannot
# assert that every individual use inside that file is correctly rooted. The
# 2026-10-20 review found a live instance: A6.2's `git diff` pathspec was left
# pointing at the main root, which is outside the worktree repo, so git fatalled
# and `|| true` swallowed it — a fail-open in a file this check reports as
# compliant. It also misses a path assembled in two steps, a subpath held in a
# variable, or a root reached through `$(...)` or an array element, because the
# signature below requires `$VAR/` adjacent to the literal subpath.
printf '\n## task group contract rooting\n'

_CONTRACT_EXEMPT="write-guard.sh bash-guard.sh"
_contract_rooting_fail=0
for _cf in $(grep -rl 'task-groups' --include='*.sh' \
               "$REAL_HOOKS" \
               "$REAL_HOOKS/../.automation" \
               "$REAL_HOOKS/../tools" 2>/dev/null | sort -u); do
  _cbase="$(basename "$_cf")"
  # Tests build sandbox paths deliberately; they are fixtures, not consumers.
  case "$_cf" in */tests/*) continue ;; esac
  case " $_CONTRACT_EXEMPT " in *" $_cbase "*) continue ;; esac
  # A consumer builds an ABSOLUTE contract path from a root variable. Files that
  # only pattern-match RELATIVE paths are classifiers, not readers — that is why
  # _mode-guard-helper.sh is not listed as exempt: its `case` patterns are
  # relative and resolve no root, so this signature correctly skips it.
  grep -qE '\$\{?[A-Za-z_][A-Za-z_0-9]*\}?/(\.claude/local|docs/ai)/task-groups' "$_cf" 2>/dev/null || continue
  # Comment lines stripped, and the CALL form required — not the bare name.
  # A file-level `grep -q get_main_repo_root` was satisfied by a COMMENT: QA
  # regressed the real call in session-close-check.sh (which mentions the name in
  # prose at line ~186) and this check still passed. That is the same
  # prose-satisfies-grep trap already fixed for the $STATE_DIR guard checks lower
  # down in this file, repeated here.
  # `grep -c` and a count, NOT `grep -q` in the pipeline: this file sets
  # pipefail, and `grep -q` exits on first match while `grep -v` is still
  # writing, so grep -v takes SIGPIPE and the pipeline reports 141 on a
  # SUCCESSFUL match. That is the same trap already documented for the
  # $STATE_DIR guard checks below — and I walked into it again here, which is
  # why the note is repeated rather than cross-referenced.
  _root_hits=$(grep -v '^[[:space:]]*#' "$_cf" 2>/dev/null | grep -cF '$(get_main_repo_root')
  if [ "${_root_hits:-0}" -gt 0 ]; then
    PASS=$((PASS + 1))
    printf 'ok   %-58s [main-rooted]\n' "$_cbase resolves contracts from the main repo"
  else
    FAIL=$((FAIL + 1))
    _contract_rooting_fail=1
    FAILED_CASES="${FAILED_CASES}    - ${_cbase} resolves task-group contracts without get_main_repo_root"$'\n'
    printf 'FAIL %-58s [session-rooted only]\n' "$_cbase resolves contracts from the main repo"
  fi
done
if [ "$_contract_rooting_fail" -eq 0 ]; then
  printf '#      (exempt, immune paths matching agent-written session-relative paths: %s)\n' "$_CONTRACT_EXEMPT"
fi

# --- A6.2's pathspec must stay SESSION-rooted -------------------------------
# A6.2 asks a question about THIS repository's index ("is the modified contract
# staged?"), and `git diff -- <absolute path outside the work tree>` fatals with
# "outside repository" — which `2>/dev/null || true` then swallows. The
# main-rooting change above pointed it at the main root and so silently disabled
# it inside every worktree session: a fail-open, caught in review on 2026-10-20.
#
# Checked statically and deliberately so. The fault only manifests where the
# session root and the main root differ, and a behavioural fixture for that
# needs a worktree running the real hook with copied state; my first attempt at
# one never reached A6 and reported a failure for an unrelated reason, which is
# worse than no test (see known-issue R7 on suites that cannot fail). This
# instead pins the one property that was wrong: the directory A6.2 diffs is
# built from $REPO_ROOT, and A6.2 does not use the main-rooted variable.
_A62_PCG="$REAL_HOOKS/pre-commit-gates.sh"
if grep -qE '_A62_DIR="\$REPO_ROOT/' "$_A62_PCG" 2>/dev/null \
   && grep -qE 'git diff --name-only -- "\$_A62_DIR"' "$_A62_PCG" 2>/dev/null; then
  PASS=$((PASS + 1))
  printf 'ok   %-58s [session-rooted]\n' "A6.2 diffs a path inside this repository"
else
  FAIL=$((FAIL + 1))
  FAILED_CASES="${FAILED_CASES}    - A6.2's git diff pathspec is not built from \$REPO_ROOT (fails open inside a worktree)"$'\n'
  printf 'FAIL %-58s [not session-rooted]\n' "A6.2 diffs a path inside this repository"
fi

# The premise the static check above rests on: git really does refuse a pathspec
# outside the work tree, and the refusal is a non-zero exit that `|| true` hides.
# Asserted directly, because "the pathspec is session-rooted" only matters if an
# out-of-tree pathspec actually fails. Needs no hook run and no session state.
_A62_PROBE_WT="$SB/.worktrees/a62-pathspec-probe"
if ( cd "$SB" && git worktree add --detach "$_A62_PROBE_WT" HEAD > /dev/null 2>&1 ); then
  _A62_PROBE_RC=0
  ( cd "$_A62_PROBE_WT" && git diff --name-only -- "$SB/docs"/*.yaml ) > /dev/null 2>&1 || _A62_PROBE_RC=$?
  if [ "$_A62_PROBE_RC" -ne 0 ]; then
    PASS=$((PASS + 1))
    printf 'ok   %-58s [exit %s]\n' "git refuses a pathspec outside the work tree" "$_A62_PROBE_RC"
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES="${FAILED_CASES}    - git accepted an out-of-work-tree pathspec, so the A6.2 rooting rationale no longer holds"$'\n'
    printf 'FAIL %-58s [accepted]\n' "git refuses a pathspec outside the work tree"
  fi
  ( cd "$SB" && git worktree remove --force "$_A62_PROBE_WT" > /dev/null 2>&1 ) || true
else
  printf 'skip %-58s [worktree add unavailable]\n' "git refuses a pathspec outside the work tree"
fi

# --- `local` outside a function aborts the CLI mid-recovery ----------------
# bash errors with "local: can only be used in a function". In queue-cli.sh's
# top-level `case` dispatch that aborts the arm partway: `reopen-wo` set the work
# order back to open and then DIED before resetting any blocked or failed
# sibling, so its advertised second step never ran. It shipped that way because
# nothing exercised the path — a recovery command is only reached once something
# has already gone wrong, and on 2026-10-20 a six-brief task group with one
# failed brief could not be resumed by its own documented recovery.
#
# Checked here rather than left to the behavioural case in
# test-queue-manipulation.sh, because that suite is adversarial, is not in
# run-automation-tests.sh's list, and reports `# Tests: 0` regardless of outcome
# (each case runs in a subshell, so the TAP counters never reach `finish`). A
# case there cannot fail a run; this can.
printf '\n## shell scoping in the queue CLI\n'

_QC_FILE="$REAL_HOOKS/../.automation/queue-cli.sh"
# The opener pattern accepts `name() {`, `function name {` and `function name() {`,
# with uppercase and digits in the name. A narrower `^[a-z_]+\(\) \{` would
# FALSE-POSITIVE on any of those styles — and a false positive here blocks every
# commit, which is worse than the defect it guards. A one-line function that
# opens and closes on the same line is excluded, so it cannot leave the scanner
# wrongly "inside" a function.
_QC_BAD=$(awk '
  /^(function[[:space:]]+)?[A-Za-z_][A-Za-z_0-9]*[[:space:]]*(\(\))?[[:space:]]*\{/ {
    if ($0 !~ /\}[[:space:]]*$/) { fn_start = NR }
    next
  }
  /^\}/ { fn_start = 0 }
  /^[[:space:]]*local / {
    # A `local` with no open function above it is outside any function, which
    # bash rejects at runtime.
    if (fn_start == 0) print NR
  }
' "$_QC_FILE" 2>/dev/null | head -5)
if [ -z "$_QC_BAD" ]; then
  PASS=$((PASS + 1))
  printf 'ok   %-58s [none]\n' "queue-cli.sh uses no 'local' outside a function"
else
  FAIL=$((FAIL + 1))
  FAILED_CASES="${FAILED_CASES}    - queue-cli.sh has 'local' outside a function at line(s): $(printf '%s' "$_QC_BAD" | tr '\n' ' ')"$'\n'
  printf 'FAIL %-58s [line(s): %s]\n' "queue-cli.sh uses no 'local' outside a function" "$(printf '%s' "$_QC_BAD" | tr '\n' ' ')"
fi

# Static guard symmetry: every $STATE_DIR write in the gate must survive a
# missing directory. This is the asymmetry that shipped — two guarded, one not.
_PCG="$REAL_HOOKS/pre-commit-gates.sh"
for _sf in functional-verified high-risk-detected kg-updated; do
  # Comment lines are stripped first: the pattern is literal text, and the
  # commentary around these writes quotes the guard idiom, so a grep over the
  # raw file could be satisfied by prose describing the fix rather than by the
  # fix. Only real code counts.
  #
  # `grep -c` and a count comparison, NOT `grep -q` in the pipeline. This file
  # sets `pipefail`, and `grep -q` exits on its first match while `grep -v` is
  # still writing ~90KB into a 64KB pipe buffer — so grep -v takes SIGPIPE, the
  # pipeline reports 141, and the `if` reads FALSE even though the pattern
  # matched. That is not hypothetical: it failed exactly two of these three
  # assertions, and only two, because kg-updated's match sits near the end of
  # the file where grep -v has already finished writing. `grep -c` consumes all
  # input, so there is no early exit to signal.
  _guard_hits=$(grep -v '^[[:space:]]*#' "$_PCG" | grep -cF "> \"\$STATE_DIR/${_sf}\" 2>/dev/null || true")
  if [ "${_guard_hits:-0}" -gt 0 ]; then
    PASS=$((PASS + 1))
    printf 'ok   %-58s [guarded]\n' "$_sf write cannot abort the chain"
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES="${FAILED_CASES}    - ${_sf} write is missing '2>/dev/null || true'"$'\n'
    printf 'FAIL %-58s [unguarded]\n' "$_sf write cannot abort the chain"
  fi
done

# ============================================================
printf '\n# ------------------------------------------------------------\n'
printf '# passed: %d   failed: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  printf '# failing cases:\n'
  printf '%s' "$FAILED_CASES"
  printf '# ------------------------------------------------------------\n'
  exit 1
fi
printf '# ------------------------------------------------------------\n'
exit 0
