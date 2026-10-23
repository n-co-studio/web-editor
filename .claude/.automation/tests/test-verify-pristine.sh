#!/usr/bin/env bash
# verify-pristine.sh — a change to the enforcement mechanism must be checked from
# outside itself (Decision t-0063).
#
# The defect this closes: a change to hooks / runner / queue libs / their tests was
# verified by the very harness it had just modified. A test helper edited to say
# "ok" turns every suite green, and the commit gate (which ran the same helper)
# agreed. verify-pristine.sh checks out the MERGE BASE in a throwaway clone, copies
# in only the change's test files (never the harness), runs the named suites there
# and reports the counts.
#
# Everything runs against fixture repos under /tmp. The real repo, its
# .claude/.state/ and its queue are never touched: each "real" directory the tool
# must leave alone is modelled inside the fixture and snapshotted before/after.
#
# Argument 1 (or VP_TOOL): tool under test; default ../../tools/verify-pristine.sh.
# Argument 2 (or VP_HELPER): _mechanism-helper.sh; default ../../hooks/_mechanism-helper.sh.
#
# Bash 3.2 compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VP_TOOL="${1:-${VP_TOOL:-$SCRIPT_DIR/../../tools/verify-pristine.sh}}"
VP_HELPER="${2:-${VP_HELPER:-$SCRIPT_DIR/../../hooks/_mechanism-helper.sh}}"

_TAP_NUM=0; _TAP_PASS=0; _TAP_FAIL=0; _TAP_FAILURES=""
_tap_pass() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_PASS=$((_TAP_PASS+1)); printf "ok %d - %s\n" "$_TAP_NUM" "$1"; }
_tap_fail() {
  _TAP_NUM=$((_TAP_NUM+1)); _TAP_FAIL=$((_TAP_FAIL+1))
  printf "not ok %d - %s\n" "$_TAP_NUM" "$1"
  if [ -n "${2:-}" ]; then printf "  # %s\n" "$2"; fi
  _TAP_FAILURES="${_TAP_FAILURES}  FAIL: $1\n"
}
eq()  { if [ "$1" = "$2" ]; then _tap_pass "$3"; else _tap_fail "$3" "expected '$2', got '$1'"; fi; }
ne()  { if [ "$1" != "$2" ]; then _tap_pass "$3"; else _tap_fail "$3" "did not expect '$2'"; fi; }
has() { case "$1" in *"$2"*) _tap_pass "$3" ;; *) _tap_fail "$3" "'$2' not in: $1" ;; esac; }
hasnt() { case "$1" in *"$2"*) _tap_fail "$3" "'$2' unexpectedly in: $1" ;; *) _tap_pass "$3" ;; esac; }

printf "# === verify-pristine (Decision t-0063) ===\n"

if [ ! -f "$VP_TOOL" ]; then
  _tap_fail "verify-pristine.sh exists" "missing: $VP_TOOL"
  printf "\n1..%d\n# Tests: %d  Pass: %d  Fail: %d\n" "$_TAP_NUM" "$_TAP_NUM" "$_TAP_PASS" "$_TAP_FAIL"
  exit 1
fi
_tap_pass "verify-pristine.sh exists"

T=$(mktemp -d /tmp/repo-os-vp-XXXXXX)
trap 'rm -rf "$T"' EXIT
R="$T/repo"
mkdir -p "$R"

# --- Fixture ---------------------------------------------------------------------
git -C "$R" init -q -b main
git -C "$R" config user.email t@t
git -C "$R" config user.name t
git -C "$R" config commit.gpgsign false
mkdir -p "$R/.claude/hooks/tests" "$R/.claude/.state" "$R/.claude/.automation/queue/pending"

# The harness: `chk` reports ok only if the two values are equal.
cat > "$R/.claude/hooks/tests/test-helpers.sh" <<'EOF'
chk() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1"; fi; }
EOF
cat > "$R/.claude/hooks/lib.sh" <<'EOF'
val() { echo 1; }
EOF
cat > "$R/.claude/hooks/tests/test-a.sh" <<'EOF'
. "$(dirname "$0")/test-helpers.sh"
chk one 1 1
chk two 1 2
EOF
git -C "$R" add -A -f
git -C "$R" commit -q -m base
MB=$(git -C "$R" rev-parse HEAD)

# Feature: (1) the harness is altered so every check passes, (2) a test is added that
# the original harness would fail, (3) the library changes, (4) env/isolation suite,
# (5) a slow suite for the watchdog.
git -C "$R" checkout -q -b feature/x
cat > "$R/.claude/hooks/tests/test-helpers.sh" <<'EOF'
chk() { echo "ok - $1"; }
EOF
cat > "$R/.claude/hooks/tests/test-a.sh" <<'EOF'
. "$(dirname "$0")/test-helpers.sh"
chk one 1 1
chk two 1 2
chk three 1 2
EOF
cat > "$R/.claude/hooks/lib.sh" <<'EOF'
val() { echo 2; }
EOF
cat > "$R/.claude/hooks/tests/test-env.sh" <<'EOF'
. "$(dirname "$0")/test-helpers.sh"
. ./.claude/hooks/lib.sh
chk no-origin-remote "$(git remote | wc -l | tr -d ' ')" 0
if git rev-parse --verify -q main >/dev/null 2>&1; then echo "ok - main-ref-exists"; else echo "not ok - main-ref-exists"; fi
chk own-git-dir "$(git rev-parse --git-dir)" .git
chk no-leaked-env "${VP_LEAK_PROBE:-unset}" unset
chk lib-is-base-version "$(val)" 1
EOF
cat > "$R/.claude/hooks/tests/test-slow.sh" <<'EOF'
echo "ok - started"
sleep 30
echo "ok - never reached"
EOF
git -C "$R" add -A -f
git -C "$R" commit -q -m feature

# State the tool must never write: snapshot-able stand-ins for the real
# .claude/.state/ and queue.
echo "live" > "$R/.claude/.state/phase-state"
echo "q" > "$R/.claude/.automation/queue/pending/e1.yaml"

snap() {
  ( cd "$R" && { find .claude/.state .claude/.automation/queue -type f 2>/dev/null | sort | while read -r f; do printf '%s %s\n' "$f" "$(cat "$f")"; done; git rev-parse HEAD; git rev-parse --abbrev-ref HEAD; git status --porcelain; git worktree list; ls .git/worktrees 2>/dev/null || true; } )
}
tmp_dirs() { ls -d /tmp/verify-pristine.* 2>/dev/null | sort || true; }
field() { printf '%s\n' "$1" | sed -n "s/^$2: *//p" | head -1; }

# Harness-altered working tree, as the author sees it.
WT_OUT=$( cd "$R" && bash .claude/hooks/tests/test-a.sh )
WT_PASS=$(printf '%s\n' "$WT_OUT" | grep -c '^ok ' || true)
WT_FAIL=$(printf '%s\n' "$WT_OUT" | grep -c '^not ok ' || true)
eq "$WT_PASS/$WT_FAIL" "3/0" "fixture: the altered harness makes the working-tree run all green (3/0)"

# --- 1. Different counts when the harness is altered -------------------------------
BEFORE=$(snap); TMP_BEFORE=$(tmp_dirs)
VP_LEAK_PROBE=leaked
export VP_LEAK_PROBE
RC=0
OUT=$( cd "$T" && bash "$VP_TOOL" --repo="$R" --base=main --suite=.claude/hooks/tests/test-a.sh 2>&1 ) || RC=$?
unset VP_LEAK_PROBE
eq "$RC" "0" "tool exits 0 when it ran (test failures are data, not tool errors)"
eq "$(field "$OUT" merge_base)" "$MB" "resolves the merge base against main"
eq "$(field "$OUT" total)" "pass=1 fail=2" "pristine counts (1/2) differ from the working-tree run (3/0)"
has "$(field "$OUT" copied)" ".claude/hooks/tests/test-a.sh" "the change's test file is copied in"
hasnt "$(field "$OUT" copied)" "test-helpers.sh" "the altered harness is NOT copied in"
has "$(field "$OUT" harness_changed)" ".claude/hooks/tests/test-helpers.sh" "the altered harness is reported, so a reviewer sees it"
eq "$(field "$OUT" outcome)" "ran" "outcome: ran"

# --- 2. Isolation inside the throwaway checkout --------------------------------------
RC=0
OUT2=$( cd "$T" && VP_LEAK_PROBE=leaked bash "$VP_TOOL" --repo="$R" --base=main --suite=.claude/hooks/tests/test-env.sh 2>&1 ) || RC=$?
eq "$(field "$OUT2" total)" "pass=5 fail=0" "isolation: no origin, main ref present, own .git dir, scrubbed env, merge-base code (5/0)"

# --- 3. No trace in real state / queue; main checkout untouched ----------------------
AFTER=$(snap)
eq "$AFTER" "$BEFORE" "no change to state dir, queue, HEAD, branch, index or worktree list"
eq "$(tmp_dirs)" "$TMP_BEFORE" "throwaway checkout removed"

# --- 4. Works when --repo is a LINKED WORKTREE (the daemon's shape) -------------------
WT="$T/wt"
git -C "$R" worktree add -q -b feature/y "$WT" feature/x
WL_BEFORE=$(git -C "$R" worktree list; ls "$R/.git/worktrees")
RC=0
OUT3=$( cd "$WT" && bash "$VP_TOOL" --base=main --suite=.claude/hooks/tests/test-a.sh 2>&1 ) || RC=$?
eq "$(field "$OUT3" total)" "pass=1 fail=2" "linked worktree as the repo: same pristine counts"
eq "$(git -C "$R" worktree list; ls "$R/.git/worktrees")" "$WL_BEFORE" "no worktree added or removed in the main repo"
eq "$(tmp_dirs)" "$TMP_BEFORE" "throwaway checkout removed (worktree run)"

# --- 5. Watchdog + missing suite -> tool_error, never a hang ---------------------------
START=$(date +%s)
RC=0
OUT4=$( cd "$T" && bash "$VP_TOOL" --repo="$R" --base=main --timeout=2 --suite=.claude/hooks/tests/test-slow.sh 2>&1 ) || RC=$?
ELAPSED=$(( $(date +%s) - START ))
if [ "$ELAPSED" -lt 20 ]; then _tap_pass "watchdog kills a hung suite (${ELAPSED}s)"; else _tap_fail "watchdog kills a hung suite" "took ${ELAPSED}s"; fi
eq "$(field "$OUT4" outcome)" "tool_error" "a timed-out suite is reported as tool_error"
has "$OUT4" "timed_out" "the timeout is named in the report"
eq "$RC" "1" "tool_error exits 1"
eq "$(ls /tmp | grep -c '^verify-pristine\.' || true)" "$(printf '%s' "$TMP_BEFORE" | grep -c . || true)" "throwaway checkout removed after a timeout"

RC=0
OUT5=$( cd "$T" && bash "$VP_TOOL" --repo="$R" --base=main --suite=.claude/hooks/tests/test-nope.sh 2>&1 ) || RC=$?
eq "$(field "$OUT5" outcome)" "tool_error" "a suite that does not exist is tool_error"

RC=0
OUT6=$( cd "$T" && bash "$VP_TOOL" --repo="$R" --base=no-such-ref --suite=.claude/hooks/tests/test-a.sh 2>&1 ) || RC=$?
eq "$(field "$OUT6" outcome)" "tool_error" "an unresolvable base is tool_error"

# --- 6. Evidence file: hash-bound, consumable by the helper ----------------------------
# shellcheck disable=SC1090
source "$VP_HELPER"
EV_REL="docs/ai/governance/pristine-evidence/e.yaml"
mkdir -p "$R/docs/ai/governance/pristine-evidence"
git -C "$R" checkout -q feature/x
printf '# touched\n' >> "$R/.claude/hooks/lib.sh"
git -C "$R" add -f .claude/hooks/lib.sh .claude/hooks/tests/test-a.sh
RC=0
OUT7=$( cd "$R" && bash "$VP_TOOL" --repo="$R" --base=main --suite=.claude/hooks/tests/test-a.sh --out="$EV_REL" 2>&1 ) || RC=$?
eq "$RC" "0" "--out run succeeds"
if [ -f "$R/$EV_REL" ]; then _tap_pass "--out writes the evidence file"; else _tap_fail "--out writes the evidence file"; fi
EV=$(cat "$R/$EV_REL" 2>/dev/null || true)
eq "$(field "$EV" merge_base)" "$MB" "evidence records the merge base"
eq "$(field "$EV" outcome)" "ran" "evidence records the outcome"
eq "$(field "$EV" pass)" "1" "evidence records pass count"
eq "$(field "$EV" fail)" "2" "evidence records fail count"
git -C "$R" add -f "$EV_REL"
SET=$( cd "$R" && mech_filter "$(git diff --cached --name-only --diff-filter=ACM)" )
ST=$( cd "$R" && mech_evidence_status "$SET" )
has "$ST" "fresh" "the tool's evidence is judged fresh by the gate's own helper"
printf '# changed after the run\n' >> "$R/.claude/hooks/lib.sh"
git -C "$R" add -f .claude/hooks/lib.sh
SET=$( cd "$R" && mech_filter "$(git diff --cached --name-only --diff-filter=ACM)" )
ST=$( cd "$R" && mech_evidence_status "$SET" )
eq "$ST" "stale" "...and stale once the change moves after the run"

# --- 7. --classify ------------------------------------------------------------------------
CL=$( cd "$R" && bash "$VP_TOOL" --repo="$R" --base=main --classify 2>&1 || true )
eq "$(field "$CL" mechanism-change)" "yes" "--classify: hooks changed since the merge base -> yes"
git -C "$R" reset -q --hard HEAD
CL2=$( cd "$R" && bash "$VP_TOOL" --repo="$R" --base=feature/x --classify 2>&1 || true )
eq "$(field "$CL2" mechanism-change)" "no" "--classify: nothing changed since the merge base -> no"
mkdir -p "$R/docs/spec"; echo x > "$R/docs/spec/a.md"
CL3=$( cd "$R" && bash "$VP_TOOL" --repo="$R" --base=feature/x --classify 2>&1 || true )
eq "$(field "$CL3" mechanism-change)" "no" "--classify: an untracked docs/spec file is not mechanism"
echo 'echo hi' > "$R/.claude/hooks/new-hook.sh"
CL4=$( cd "$R" && bash "$VP_TOOL" --repo="$R" --base=feature/x --classify 2>&1 || true )
eq "$(field "$CL4" mechanism-change)" "yes" "--classify: an untracked hook script counts"

# --- 9. Critic cycle 1: deletions, crashes, empty runs, staged-vs-worktree, bad timeout ------
rm -f "$R/docs/spec/a.md" "$R/.claude/hooks/new-hook.sh"
git -C "$R" reset -q --hard HEAD

# 9a. --timeout=0 used to arm the watchdog at once (every suite "timed out"); it is refused.
RC=0
OUT8=$( cd "$T" && bash "$VP_TOOL" --repo="$R" --base=main --timeout=0 --suite=.claude/hooks/tests/test-a.sh 2>&1 ) || RC=$?
eq "$RC" "64" "--timeout=0 is rejected as a usage error"

# 9b. A deleted mechanism file is a mechanism change and is reported, not silently dropped.
git -C "$R" rm -q -- .claude/hooks/lib.sh
CLD=$( cd "$R" && bash "$VP_TOOL" --repo="$R" --base=main --classify 2>&1 || true )
eq "$(field "$CLD" mechanism-change)" "yes" "--classify: a staged deletion of a hook counts"
has "$CLD" "file: .claude/hooks/lib.sh" "--classify: the deleted file is listed"
OUT9=$( cd "$T" && bash "$VP_TOOL" --repo="$R" --base=main --suite=.claude/hooks/tests/test-a.sh 2>&1 || true )
has "$(field "$OUT9" deleted)" ".claude/hooks/lib.sh" "the run reports the deleted file on its own line"
hasnt "$(field "$OUT9" code_changed)" "lib.sh" "...and does not call it changed code"
git -C "$R" reset -q --hard HEAD

# 9c. A suite that crashes (exit != 0, no TAP) is a failure, never silence.
printf 'echo boom >&2\nexit 3\n' > "$R/.claude/hooks/tests/test-crash.sh"
RC=0
OUT10=$( cd "$T" && bash "$VP_TOOL" --repo="$R" --base=main --suite=.claude/hooks/tests/test-crash.sh 2>&1 ) || RC=$?
has "$OUT10" "rc=3 pass=0 fail=1" "a crashing suite is counted as one failure"
has "$OUT10" "exit_nonzero_counted_as_fail" "...and the report says why"
eq "$(field "$OUT10" total)" "pass=0 fail=1" "...so the total is not zero"
rm -f "$R/.claude/hooks/tests/test-crash.sh"

# 9d. No test files and no --suite: nothing ran, and the report says the gate will call it empty.
printf '# edit\n' >> "$R/.claude/hooks/lib.sh"
RC=0
OUT11=$( cd "$T" && bash "$VP_TOOL" --repo="$R" --base=feature/x 2>&1 ) || RC=$?
eq "$(field "$OUT11" total)" "pass=0 fail=0" "no suite -> nothing counted"
has "$OUT11" "treat this evidence as 'empty'" "...and the report warns that the gate will reject it"
git -C "$R" checkout -q -- .claude/hooks/lib.sh

# 9e. A test that is staged AND edited afterwards is copied from the INDEX (what the
#     evidence is bound to), not from the working tree.
printf '. "$(dirname "$0")/test-helpers.sh"\nchk staged 1 1\n' > "$R/.claude/hooks/tests/test-a.sh"
git -C "$R" add -f .claude/hooks/tests/test-a.sh
printf 'chk worktree-only 1 2\n' >> "$R/.claude/hooks/tests/test-a.sh"
OUT12=$( cd "$T" && bash "$VP_TOOL" --repo="$R" --base=main --suite=.claude/hooks/tests/test-a.sh 2>&1 || true )
eq "$(field "$OUT12" total)" "pass=1 fail=0" "the staged version of a test is what runs"
has "$OUT12" "unstaged edits" "...and the unstaged edit is flagged"
git -C "$R" reset -q --hard HEAD
eq "$(tmp_dirs)" "$TMP_BEFORE" "no throwaway checkout left behind by these runs"

# --- 8. Static: the tool cannot reach the real state by construction ------------------------
CODE=$(grep -v '^[[:space:]]*#' "$VP_TOOL" || true)
hasnt "$CODE" "git worktree" "tool never uses git worktree (shares the common dir -> real-repo-root hazard)"
hasnt "$CODE" ".claude/.state" "tool never names the real .state directory"
hasnt "$CODE" "automation/queue" "tool never names the queue directory"
has "$CODE" "env -i" "suites run under a scrubbed environment"

printf "\n1..%d\n# Tests: %d  Pass: %d  Fail: %d\n" "$_TAP_NUM" "$_TAP_NUM" "$_TAP_PASS" "$_TAP_FAIL"
if [ "$_TAP_FAIL" -gt 0 ]; then printf "\n# Failures:\n%b" "$_TAP_FAILURES"; exit 1; fi
exit 0
