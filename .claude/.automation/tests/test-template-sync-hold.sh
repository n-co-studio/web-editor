#!/usr/bin/env bash
# Held template updates — Decision t-0084 (Massimo R7)
#
# A child whose .claude/template-sync-mode says hold gets the template update
# on template-sync/held, one commit on top of main with the change list,
# instead of on main. .claude/tools/template-sync-held.sh shows it and applies
# it. Like sync-conformance, this builds a real template, child and bare
# origin and runs the real engine and tool against them; no mocks.
#
# Run against the code before t-0084 (verify-pristine) the hold cases fail: the
# engine ignores the mode file and commits to main, and the tool does not exist.
# Bash 3.2 compatible.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_REPO="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ENGINE="$REAL_REPO/.claude/.automation/lib/template-sync-engine.sh"
TOOL="$REAL_REPO/.claude/tools/template-sync-held.sh"
HELD="refs/heads/template-sync/held"

_TAP_NUM=0; _TAP_PASS=0; _TAP_FAIL=0; _TAP_FAILURES=""
_tap_pass() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_PASS=$((_TAP_PASS+1)); printf "ok %d - %s\n" "$_TAP_NUM" "$1"; }
_tap_fail() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_FAIL=$((_TAP_FAIL+1)); printf "not ok %d - %s\n" "$_TAP_NUM" "$1"; [ -n "${2:-}" ] && printf "  # %s\n" "$2"; _TAP_FAILURES="${_TAP_FAILURES}  FAIL: $1\n"; }
_tap_eq() { if [ "$1" = "$2" ]; then _tap_pass "$3"; else _tap_fail "$3" "expected '$2', got '$1'"; fi; }
_tap_contains() { case "$1" in *"$2"*) _tap_pass "$3" ;; *) _tap_fail "$3" "output did not contain '$2': $1" ;; esac; }
_tap_lacks() { case "$1" in *"$2"*) _tap_fail "$3" "output contained '$2': $1" ;; *) _tap_pass "$3" ;; esac; }

printf "# === Held template updates (Decision t-0084) ===\n"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/tsh-test.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
TPL="$WORK/template"; CHILD="$WORK/child"; ORIGIN="$WORK/origin.git"

g() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}" >/dev/null 2>&1; }
manifest() {  # <files...>: the template's machinery manifest, so the sweep can delete
  { printf '# Template Machinery Manifest — GENERATED.\n'; for f in "$@"; do printf '%s\n' "$f"; done; } \
    > "$TPL/.claude/.automation/machinery-manifest.txt"
}
tpl_commit() { g "$TPL" add -A; g "$TPL" commit -m "$1"; }
run_engine() {  # sets OUT, RC; GITHUB_STEP_SUMMARY points at $WORK/summary.md
  OUT=$(cd "$CHILD" && GITHUB_STEP_SUMMARY="$WORK/summary.md" bash "$ENGINE" "file://$TPL" main 2>&1); RC=$?
}
run_tool() { OUT=$(cd "$CHILD" && bash "$TOOL" "$@" 2>&1); RC=$?; }
origin_main() { git -C "$ORIGIN" rev-parse refs/heads/main 2>/dev/null; }
origin_held() { git -C "$ORIGIN" rev-parse --verify -q "$HELD" 2>/dev/null; }
held_msg() { git -C "$ORIGIN" log -1 --format=%B "$HELD" 2>/dev/null; }

# --- template v1 and a child that has never synced ---------------------------
mkdir -p "$TPL/.claude/hooks" "$TPL/.claude/.automation"
g "$TPL" init; g "$TPL" checkout -b main
printf 'a v1\n' > "$TPL/.claude/hooks/a.sh"
printf 'withdrawn later\n' > "$TPL/.claude/hooks/gone.sh"
printf '.claude/template-sync-mode\n' > "$TPL/.templatesyncignore"
manifest .claude/.automation/machinery-manifest.txt .claude/hooks/a.sh .claude/hooks/gone.sh .templatesyncignore
tpl_commit "template v1"

git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$CHILD" 2>/dev/null
g "$CHILD" checkout -b main
git -C "$CHILD" config user.email t@t; git -C "$CHILD" config user.name t
mkdir -p "$CHILD/src"; printf 'product\n' > "$CHILD/src/app.txt"
g "$CHILD" add -A; g "$CHILD" commit -m "child v1"; g "$CHILD" push -u origin main

# --- direct: no mode file, behaviour unchanged --------------------------------
printf "\n# direct mode (no mode file)\n"
before=$(origin_main)
run_engine
_tap_eq "$RC" "0" "direct: the sync succeeds"
_tap_eq "$(git -C "$ORIGIN" show refs/heads/main:.claude/hooks/a.sh 2>/dev/null)" "a v1" "direct: the update is committed and pushed to main"
[ "$(origin_main)" != "$before" ] && _tap_pass "direct: origin main advanced" || _tap_fail "direct: origin main advanced"
_tap_eq "$(origin_held)" "" "direct: no held branch is made"

# --- hold ----------------------------------------------------------------------
printf "\n# hold mode\n"
printf '# how template updates arrive\nhold\n' > "$CHILD/.claude/template-sync-mode"
g "$CHILD" add -A; g "$CHILD" commit -m "hold template updates"; g "$CHILD" push origin main
printf 'a v2\n' > "$TPL/.claude/hooks/a.sh"
printf 'new\n' > "$TPL/.claude/hooks/c.sh"
rm -f "$TPL/.claude/hooks/gone.sh"
manifest .claude/.automation/machinery-manifest.txt .claude/hooks/a.sh .claude/hooks/c.sh .templatesyncignore
tpl_commit "template v2"
main_before=$(origin_main); rm -f "$WORK/summary.md"
run_engine
_tap_eq "$RC" "0" "hold: the sync succeeds"
_tap_eq "$(origin_main)" "$main_before" "hold: origin main is unchanged"
h1=$(origin_held)
[ -n "$h1" ] && _tap_pass "hold: origin has template-sync/held" || _tap_fail "hold: origin has template-sync/held" "$OUT"
_tap_eq "$(git -C "$ORIGIN" rev-parse "$HELD^" 2>/dev/null)" "$main_before" "hold: the held branch is one commit on top of main"
msg=$(held_msg)
_tap_contains "$msg" "M .claude/hooks/a.sh" "hold: the message lists the modified file"
_tap_contains "$msg" "A .claude/hooks/c.sh" "hold: the message lists the added file"
_tap_contains "$msg" "D .claude/hooks/gone.sh" "hold: the message lists the withdrawn file"
_tap_contains "$msg" "t-0084" "hold: the message cites Decision t-0084"
_tap_eq "$(git -C "$CHILD" rev-parse --abbrev-ref HEAD)" "main" "hold: the child is left on main"
_tap_eq "$(git -C "$CHILD" status --porcelain)" "" "hold: the child's tree is clean"
_tap_eq "$(cat "$CHILD/.claude/hooks/a.sh")" "a v1" "hold: the child's main still has the old file"
_tap_contains "$(cat "$WORK/summary.md" 2>/dev/null)" "A .claude/hooks/c.sh" "hold: the change list is in the GitHub step summary"

printf "\n# hold again: the held branch is rebuilt\n"
printf 'later\n' > "$TPL/.claude/hooks/d.sh"
manifest .claude/.automation/machinery-manifest.txt .claude/hooks/a.sh .claude/hooks/c.sh .claude/hooks/d.sh .templatesyncignore
tpl_commit "template v3"
run_engine
_tap_eq "$RC" "0" "rebuild: the sync succeeds"
h2=$(origin_held)
[ -n "$h2" ] && [ "$h2" != "$h1" ] && _tap_pass "rebuild: the held branch was replaced" || _tap_fail "rebuild: the held branch was replaced" "$OUT"
_tap_eq "$(git -C "$ORIGIN" rev-parse "$HELD^" 2>/dev/null)" "$main_before" "rebuild: still one commit on top of main"
msg=$(held_msg)
_tap_contains "$msg" "A .claude/hooks/d.sh" "rebuild: the new change is listed"
_tap_contains "$msg" "A .claude/hooks/c.sh" "rebuild: the earlier change is still listed"

printf "\n# an unknown mode\n"
printf 'holdd\n' > "$CHILD/.claude/template-sync-mode"
printf 'v4\n' > "$TPL/.claude/hooks/e.sh"; tpl_commit "template v4"
st_before=$(git -C "$CHILD" status --porcelain); head_before=$(git -C "$CHILD" rev-parse HEAD)
run_engine
_tap_eq "$RC" "1" "unknown mode: the sync exits 1"
_tap_contains "$OUT" "'holdd'" "unknown mode: the error names the value"
_tap_eq "$(git -C "$CHILD" status --porcelain)" "$st_before" "unknown mode: the child's tree is untouched"
_tap_eq "$(git -C "$CHILD" rev-parse HEAD)" "$head_before" "unknown mode: no commit"
_tap_eq "$(origin_main)" "$main_before" "unknown mode: origin main untouched"
_tap_eq "$(origin_held)" "$h2" "unknown mode: the held branch untouched"
g "$CHILD" checkout -- .claude/template-sync-mode
g "$TPL" reset --hard HEAD~1

# --- the tool -------------------------------------------------------------------
printf "\n# template-sync-held.sh\n"
run_tool status
_tap_eq "$RC" "0" "status: exit 0"
_tap_contains "$OUT" "A .claude/hooks/d.sh" "status: shows the held change list"
_tap_contains "$OUT" "template-sync-held.sh apply" "status: says how to apply it"
run_tool bogus; _tap_eq "$RC" "2" "usage: an unknown command exits 2"

g "$CHILD" checkout -b elsewhere
run_tool apply
_tap_eq "$RC" "1" "apply off main: refused"
_tap_eq "$(git -C "$CHILD" rev-parse HEAD)" "$main_before" "apply off main: nothing changed"
g "$CHILD" checkout main; g "$CHILD" branch -D elsewhere

printf 'scratch\n' > "$CHILD/untracked.txt"
run_tool apply
_tap_eq "$RC" "1" "apply with a dirty tree: refused"
_tap_eq "$(git -C "$CHILD" rev-parse HEAD)" "$main_before" "apply with a dirty tree: nothing changed"
rm -f "$CHILD/untracked.txt"

printf 'moved\n' > "$CHILD/src/moved.txt"; g "$CHILD" add -A; g "$CHILD" commit -m "main moves on"
moved=$(git -C "$CHILD" rev-parse HEAD)
run_tool apply
_tap_eq "$RC" "1" "apply after main moved: refused"
_tap_contains "$OUT" "Run the Template Sync workflow again" "apply after main moved: says to rebuild the held update"
_tap_eq "$(git -C "$CHILD" rev-parse HEAD)" "$moved" "apply after main moved: nothing changed"
g "$CHILD" reset --hard "$main_before"

run_tool apply
_tap_eq "$RC" "0" "apply: succeeds"
_tap_eq "$(git -C "$CHILD" rev-parse HEAD)" "$h2" "apply: main is fast-forwarded to the held commit"
_tap_eq "$(cat "$CHILD/.claude/hooks/d.sh" 2>/dev/null)" "later" "apply: the update is in the child's tree"
_tap_contains "$OUT" "git push origin main" "apply: prints the push command"
_tap_eq "$(origin_main)" "$main_before" "apply: does not push"

printf "\n# after the push, the next sync deletes the held branch\n"
g "$CHILD" push origin main
run_engine
_tap_eq "$RC" "0" "cleanup: the sync succeeds"
_tap_lacks "$OUT" "Committing" "cleanup: nothing to commit"
_tap_eq "$(origin_held)" "" "cleanup: the held branch is deleted from origin"
run_tool status
_tap_contains "$OUT" "No held template update." "status: says when nothing is held"

printf "\n# the real template\n"
if grep -qx '.claude/template-sync-mode' "$REAL_REPO/.templatesyncignore"; then
  _tap_pass "the mode file is owned by the child, not synced"
else
  _tap_fail "the mode file is owned by the child, not synced"
fi
[ -x "$TOOL" ] && _tap_pass "the tool is executable" || _tap_fail "the tool is executable"

printf "\n# %d passed, %d failed\n" "$_TAP_PASS" "$_TAP_FAIL"
if [ "$_TAP_FAIL" -gt 0 ]; then printf "%b" "$_TAP_FAILURES"; exit 1; fi
exit 0
