#!/usr/bin/env bash
# smoke-claude-continue-false.sh — does {"continue": false} from a PreToolUse
# hook really end a `claude -p` run? (known-issue R51(a))
#
# The question park (ask-user-deny.sh) and the operator STOP (operator-control.sh)
# both end a headless session that way, and no suite launches a real claude -p.
# An agent cannot run this: bash-guard refuses spawning claude, and the Bash
# sandbox (Decision t-0076) limits it. The OPERATOR runs it, from a terminal:
#
#   bash .claude/tools/smoke-claude-continue-false.sh
#
# Three short `claude -p` runs (a few cents of API use), each in a throwaway git
# repo under the system temp dir with its own .claude/settings.json, asked to make
# two separate Bash calls (touch step1.marker, then step2.marker):
#   1. control        — no hook: both markers must appear (proves the check can
#                       see a tool run at all)
#   2. operator-stop  — hook prints operator-control.sh's shape
#   3. question-park  — hook prints ask-user-deny.sh's shape (stop + deny)
# For 2 and 3 two things are checked separately, as t-0055 promises both:
#   - the run ended at the first tool call (no step2, hook fired exactly once)
#   - the stopped tool call did not run (no step1)
# Each case's claude output and stderr are kept in <result>.artifacts/.
#
# Output: TAP on stdout, and the same plus RESULT: PASS|FAIL in
# .claude/local/smoke-continue-false.log (SMOKE_OUT overrides). Exit 0 only when
# every case passes. CLAUDE_BIN overrides the binary (the suite uses fakes),
# SMOKE_TIMEOUT the per-case watchdog in seconds (default 120).
# --print-shapes prints the two hook outputs and exits.
#
# Bash 3.2 compatible.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
TIMEOUT="${SMOKE_TIMEOUT:-120}"
OUT="${SMOKE_OUT:-$REPO_ROOT/.claude/local/smoke-continue-false.log}"

# Both shapes are what the template's hooks print (the suite checks they do not
# drift). SMOKE_SHAPE_STOP overrides the first — the suite uses it to show the
# tool still catches the pre-t-0077 continue-only shape.
_DEFAULT_STOP='{"continue": false, "stopReason": "smoke: operator stop", "hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "smoke: operator stop"}}'
SHAPE_STOP="${SMOKE_SHAPE_STOP:-$_DEFAULT_STOP}"
SHAPE_PARK='{"continue": false, "stopReason": "smoke: question parked", "hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "smoke: parked"}}'

if [ "${1:-}" = "--print-shapes" ]; then
  printf 'operator-stop: %s\nquestion-park: %s\n' "$SHAPE_STOP" "$SHAPE_PARK"
  exit 0
fi

# Two separate tool calls, so "the run ended" (the second never happens) is told
# apart from "the run finished normally after one command".
PROMPT='Use the Bash tool twice, as two separate tool calls, one after the other. First call: touch step1.marker
Second call: touch step2.marker
Run nothing else. Then reply with the single word DONE.'

WORK=$(mktemp -d "${TMPDIR:-/tmp}/smoke-cf.XXXXXX") || { echo "cannot create a temp dir" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$(dirname "$OUT")"
: > "$OUT"
# Each case's claude output and stderr are kept beside the result file, so a
# surprising result can be read rather than guessed at.
ART="${OUT%.log}.artifacts"
rm -rf "$ART"; mkdir -p "$ART"
_say() { printf '%s\n' "$1"; printf '%s\n' "$1" >> "$OUT"; }

_say "# smoke-claude-continue-false — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
# The version line is informational; a claude that hangs here must not hang the run.
"$CLAUDE_BIN" --version > "$WORK/version" 2>/dev/null < /dev/null &
_vpid=$!
_vt=0; while kill -0 "$_vpid" 2>/dev/null && [ "$_vt" -lt 50 ]; do sleep 0.2; _vt=$((_vt + 1)); done
kill "$_vpid" 2>/dev/null; wait "$_vpid" 2>/dev/null
_say "# claude: $(head -1 "$WORK/version" 2>/dev/null | grep . || echo unknown)"

_make_case() {  # name shape  ('' = no hook)
  local d="$WORK/$1"
  mkdir -p "$d/.claude"
  git -C "$d" init -q 2>/dev/null || true
  if [ -n "$2" ]; then
    {
      printf '#!/bin/sh\n'
      printf 'cat > /dev/null\n'
      printf 'echo fired >> "%s/hook-fired"\n' "$d"
      printf "printf '%%s\\\\n' '%s'\n" "$2"
      printf 'exit 0\n'
    } > "$d/.claude/hook.sh"
    chmod +x "$d/.claude/hook.sh"
    printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"%s/.claude/hook.sh"}]}]}}\n' "$d" \
      > "$d/.claude/settings.json"
  else
    printf '{}\n' > "$d/.claude/settings.json"
  fi
}

FAILED=0
N=0
_run_case() {  # name expect(ran|stopped)
  local name="$1" expect="$2" d="$WORK/$1" pid ticks=0 limit=$((TIMEOUT * 5)) timed_out=0 rc=0
  ( cd "$d" && exec "$CLAUDE_BIN" -p "$PROMPT" --allowedTools Bash --max-turns 6 --output-format json ) \
    > "$d/out.json" 2> "$d/err.log" < /dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$limit" ]; then timed_out=1; kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null; break; fi
    sleep 0.2; ticks=$((ticks + 1))
  done
  wait "$pid" 2>/dev/null || rc=$?
  local s1=no s2=no fired=0
  [ -f "$d/step1.marker" ] && s1=yes
  [ -f "$d/step2.marker" ] && s2=yes
  [ -f "$d/hook-fired" ] && fired=$(grep -c . "$d/hook-fired" 2>/dev/null || true)
  local detail="rc=$rc first-command-ran=$s1 second-command-ran=$s2 hook-fired=${fired}x"
  [ "$timed_out" = 1 ] && detail="timed out after ${TIMEOUT}s, $detail"
  cp "$d/out.json" "$ART/$name.out.json" 2>/dev/null; cp "$d/err.log" "$ART/$name.err.log" 2>/dev/null
  if [ "$expect" = ran ]; then
    # The control: both commands run, so the check can see a tool run at all.
    _check "$name: both commands ran (the check can see a tool run)" \
      "$timed_out" "$([ "$s1$s2" = yesyes ] && echo 1)" "$detail" "$d"
  else
    # t-0055's promise: the run ends at that tool boundary, and the stopped tool
    # call does not run ("no partial edit, no half-written file").
    _check "$name: the run ended at the first tool call" \
      "$timed_out" "$([ "$s2" = no ] && [ "$fired" = 1 ] && echo 1)" "$detail" "$d"
    _check "$name: the stopped tool call did not run" \
      "$timed_out" "$([ "$s1" = no ] && echo 1)" "$detail" "$d"
    # The markers infer "ended"; claude's own record says why it ended. Without
    # this, a deny followed by a model that simply gives up would look the same.
    local why
    why=$(grep -o '"terminal_reason" *: *"[a-z_]*"' "$d/out.json" 2>/dev/null | head -1 | sed 's/.*: *"//; s/"$//')
    _check "$name: claude records the hook as what ended it (terminal_reason=${why:-none})" \
      "$timed_out" "$([ "$why" = hook_stopped ] && echo 1)" "$detail" "$d"
  fi
}
_check() {  # label timed_out pass detail dir
  N=$((N + 1))
  if [ "$2" = 0 ] && [ "$3" = 1 ]; then
    _say "ok $N - $1 ($4)"
  else
    _say "not ok $N - $1 ($4)"
    _say "  # stderr: $(tr '\n' ' ' < "$5/err.log" | cut -c1-300)"
    FAILED=1
  fi
}

_make_case control ""
_make_case operator-stop "$SHAPE_STOP"
_make_case question-park "$SHAPE_PARK"
_run_case control ran
_run_case operator-stop stopped
_run_case question-park stopped

_say "1..$N"
if [ "$FAILED" = 0 ]; then _say "RESULT: PASS"; else _say "RESULT: FAIL"; fi
exit "$FAILED"
