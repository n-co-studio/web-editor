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
