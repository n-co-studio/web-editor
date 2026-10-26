#!/usr/bin/env bash
# Escalation files land in the MAIN repo, whichever tree the session runs in
# (known-issue R44). Most hook writers used $REPO_ROOT, which in a worktree
# session is the worktree — deleted by the runner right after the session, and
# never read by the daemon, which lives in the main checkout. Runs the real
# pre-commit-gates.sh from inside a real linked worktree of a /tmp repo.
# Bash 3.2 compatible.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_HOOKS="$(cd "$SCRIPT_DIR/.." && pwd)"

_N=0; _P=0; _F=0; _FAILS=""
ok()  { _N=$((_N+1)); _P=$((_P+1)); printf 'ok %d - %s\n' "$_N" "$1"; }
nok() { _N=$((_N+1)); _F=$((_F+1)); printf 'not ok %d - %s\n' "$_N" "$1"; [ -n "${2:-}" ] && printf '  # %s\n' "$2"; _FAILS="${_FAILS}  FAIL: $1\n"; }

T=$(mktemp -d /tmp/esc-root-test.XXXXXX) || { echo "Bail out! mktemp failed"; exit 2; }
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
MAIN="$T/main"; WT="$T/wt"; SID="esc-root-$$"

git init -q "$MAIN" && git -C "$MAIN" symbolic-ref HEAD refs/heads/main
git -C "$MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$MAIN" worktree add -q -b feature/esc "$WT" 2>/dev/null
for d in "$MAIN" "$WT"; do
  mkdir -p "$d/.claude/.state/wt-sessions/$SID" "$d/.claude/.automation/escalations" "$d/docs/ai/decisions"
  echo child > "$d/.claude/repo-mode"
done

_escs() { find "$1/.claude/.automation/escalations" -name '*.yaml' -type f 2>/dev/null | wc -l | tr -d ' '; }

printf '# === escalations are rooted in the main repo (R44) ===\n'

# REPO_OS_RECOVER in headless mode writes a governance-block escalation —
# the simplest writer to trigger. The seam root is the WORKTREE, as it is for a
# real worktree session (hooks resolve _REPO_OS_ROOT from their launch CWD).
rc=0
(cd "$WT" && printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' "$SID" \
  | REPO_OS_TEST_MODE=1 _REPO_OS_TEST_ROOT="$WT" REPO_OS_SESSION_ID="$SID" CLAUDE_HEADLESS=1 REPO_OS_RECOVER=1 \
    bash "$REAL_HOOKS/pre-commit-gates.sh" > "$T/out" 2>&1) || rc=$?
if [ "$(_escs "$MAIN")" -ge 1 ]; then
  ok "a worktree session's escalation is written to the MAIN repo"
else
  nok "a worktree session's escalation is written to the MAIN repo" "main=$(_escs "$MAIN") worktree=$(_escs "$WT") rc=$rc"
fi
if [ "$(_escs "$WT")" -eq 0 ]; then
  ok "...and not into the worktree, which is deleted after the session"
else
  nok "...and not into the worktree, which is deleted after the session"
fi

# From the main checkout itself the directory is unchanged.
rm -f "$MAIN"/.claude/.automation/escalations/*.yaml
rc=0
(cd "$MAIN" && printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' "$SID" \
  | REPO_OS_TEST_MODE=1 _REPO_OS_TEST_ROOT="$MAIN" REPO_OS_SESSION_ID="$SID" CLAUDE_HEADLESS=1 REPO_OS_RECOVER=1 \
    bash "$REAL_HOOKS/pre-commit-gates.sh" > "$T/out" 2>&1) || rc=$?
if [ "$(_escs "$MAIN")" -ge 1 ]; then ok "a main-checkout session still writes to its own escalations dir"; else nok "a main-checkout session still writes to its own escalations dir" "rc=$rc"; fi

# The helper every writer now uses.
_dir=$(cd "$WT" && REPO_OS_TEST_MODE=1 _REPO_OS_TEST_ROOT="$WT" bash -c 'source "$1/_analytics-helper.sh" && get_escalations_dir' _ "$REAL_HOOKS" 2>/dev/null)
if [ "$_dir" = "$MAIN/.claude/.automation/escalations" ]; then
  ok "get_escalations_dir names the main repo's dir from a worktree"
else
  nok "get_escalations_dir names the main repo's dir from a worktree" "got '$_dir'"
fi

# Every escalations path a hook builds goes through get_escalations_dir or
# get_main_repo_root — whatever the variable spelling ($REPO_ROOT, ${REPO_ROOT},
# $_REPO_OS_ROOT, a ${x:-...} fallback). Comments and the echo/printf messages
# that only NAME the path are not writers. Top-level hooks only: tests/ build
# sandbox paths of their own.
_left=$(grep -n '\.claude/\.automation/escalations' "$REAL_HOOKS"/*.sh 2>/dev/null \
  | grep -v 'get_escalations_dir\|get_main_repo_root' \
  | grep -vE ':[[:space:]]*#|echo "|printf .%s' || true)
if [ -z "$_left" ]; then
  ok "every hook builds its escalations path from the main repo"
else
  nok "every hook builds its escalations path from the main repo" "$(printf '%s' "$_left" | head -3 | tr '\n' ' ')"
fi

printf '\n1..%d\n# pass %d / fail %d\n' "$_N" "$_P" "$_F"
if [ "$_F" -gt 0 ]; then printf '%b' "$_FAILS"; exit 1; fi
exit 0
