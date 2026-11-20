#!/usr/bin/env bash
# smoke-claude-continue-false.sh can fail correctly (known-issue R51(a)).
#
# The tool is the operator's live check that {"continue": false} from a
# PreToolUse hook ends a real `claude -p`. A smoke test that passes whatever
# happens is worse than none, so this suite drives it with fake claude binaries
# (CLAUDE_BIN) and checks it judges each one right, and that the two stop shapes
# it emits are the ones the template's real hooks print.
#
# Bash 3.2 compatible. No network, no real claude.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TOOL="$REPO/.claude/tools/smoke-claude-continue-false.sh"

_TAP_NUM=0; _TAP_PASS=0; _TAP_FAIL=0
_ok()   { _TAP_NUM=$((_TAP_NUM+1)); _TAP_PASS=$((_TAP_PASS+1)); printf 'ok %d - %s\n' "$_TAP_NUM" "$1"; }
_nok()  { _TAP_NUM=$((_TAP_NUM+1)); _TAP_FAIL=$((_TAP_FAIL+1)); printf 'not ok %d - %s\n' "$_TAP_NUM" "$1"; [ -n "${2:-}" ] && printf '  # %s\n' "$2"; return 0; }
_eq()   { if [ "$1" = "$2" ]; then _ok "$3"; else _nok "$3" "expected '$2', got '$1'"; fi; }
_has()  { case "$1" in *"$2"*) _ok "$3" ;; *) _nok "$3" "'$2' not in output" ;; esac; }

printf '# === smoke-claude-continue-false (R51(a)) ===\n'
if [ ! -f "$TOOL" ]; then
  _nok "the smoke tool exists" "missing: $TOOL"
  printf '\n1..%d\n# pass %d fail %d\n' "$_TAP_NUM" "$_TAP_PASS" "$_TAP_FAIL"; exit 1
fi
_ok "the smoke tool exists"

T=$(mktemp -d "${TMPDIR:-/tmp}/smoke-cf-test.XXXXXX")
trap 'rm -rf "$T"' EXIT

# A fake claude: it makes the two Bash calls the prompt asks for (touch
# step1.marker, then step2.marker), running the case's hook before each, and
# reacts to the hook's output according to FAKE_MODE:
#   honour      — a continue:false stops before the call runs (t-0055's promise)
#   realistic   — what the live run showed: a deny blocks the call; continue:false
#                 alone lets the call run, then ends the session
#   runs-anyway — ignores the hook
#   no-control  — never runs a command
#   hang        — never returns
cat > "$T/fake-claude" <<'EOF'
#!/usr/bin/env bash
mode="${FAKE_MODE:-honour}"
[ "$mode" = hang ] && { sleep 600; exit 0; }
[ "${1:-}" = --version ] && { echo "fake-claude 0.0"; exit 0; }
[ "$mode" = no-control ] && { printf '{"result":"fake"}\n'; exit 0; }
hook=".claude/hook.sh"
why=completed
for step in step1 step2; do
  out=""
  [ -x "$hook" ] && out=$(printf '{"tool_name":"Bash","tool_input":{"command":"touch %s.marker"}}' "$step" | "$hook")
  stop=0; deny=0
  case "$out" in *'"continue": false'*) stop=1 ;; esac
  case "$out" in *'"permissionDecision": "deny"'*) deny=1 ;; esac
  case "$mode" in
    honour)      [ "$stop" = 1 ] && { why=hook_stopped; break; }; touch "$step.marker" ;;
    realistic)   [ "$deny" = 1 ] || touch "$step.marker"; [ "$stop" = 1 ] && { why=hook_stopped; break; } ;;
    runs-anyway) touch "$step.marker" ;;
  esac
done
# Real claude -p records why it ended (live run, claude 2.1.328).
printf '{"result":"fake","terminal_reason":"%s"}\n' "$why"
exit 0
EOF
chmod +x "$T/fake-claude"

_run() {  # mode -> sets OUT, RC
  RC=0
  OUT=$(FAKE_MODE="$1" CLAUDE_BIN="$T/fake-claude" SMOKE_TIMEOUT="${2:-20}" SMOKE_OUT="$T/result-$1.log" \
        bash "$TOOL" 2>&1) || RC=$?
}

# Report lines: 1 control; 2/3/4 operator-stop ended / did not run / claude says
# the hook ended it; 5/6/7 the same for question-park.

# 1. A claude that honours the stop: every check passes.
_run honour
_eq "$RC" "0" "honouring claude: the tool exits 0"
_has "$OUT" "ok 1 - control: both commands ran" "honouring claude: the control passes"
_has "$OUT" "ok 2 - operator-stop: the run ended" "honouring claude: operator-stop ended the run"
_has "$OUT" "ok 3 - operator-stop: the stopped tool call did not run" "honouring claude: operator-stop's call did not run"
_has "$OUT" "ok 4 - operator-stop: claude records the hook as what ended it (terminal_reason=hook_stopped)" "honouring claude: operator-stop's end is attributed to the hook"
_has "$OUT" "ok 5 - question-park: the run ended" "honouring claude: question-park ended the run"
_has "$OUT" "ok 6 - question-park: the stopped tool call did not run" "honouring claude: question-park's call did not run"
_has "$OUT" "ok 7 - question-park: claude records the hook" "honouring claude: question-park's end is attributed to the hook"
_has "$(cat "$T/result-honour.log" 2>/dev/null)" "RESULT: PASS" "honouring claude: the result file says PASS"

# 2. A claude that ignores the hook: every stop check fails.
_run runs-anyway
_eq "$RC" "1" "hook-ignoring claude: the tool exits 1"
_has "$OUT" "not ok 2 - operator-stop: the run ended" "hook-ignoring claude: operator-stop not ended is reported"
_has "$OUT" "not ok 4 - operator-stop: claude records the hook as what ended it (terminal_reason=completed)" "hook-ignoring claude: a run that completed is not taken for a hook stop"
_has "$OUT" "not ok 6 - question-park: the stopped tool call did not run" "hook-ignoring claude: question-park's call running is reported"
_has "$OUT" "second-command-ran=yes" "hook-ignoring claude: the failure shows the second command ran"

# 3. What the live run showed: continue:false alone lets the call run, then ends;
#    a deny blocks it. The tool must tell those two properties apart — so the
#    operator-stop case is fed the pre-t-0077 continue-only shape here.
SMOKE_SHAPE_STOP='{"continue": false, "stopReason": "smoke: operator stop"}'
export SMOKE_SHAPE_STOP
_run realistic
unset SMOKE_SHAPE_STOP
_eq "$RC" "1" "realistic claude, pre-t-0077 STOP shape: the tool exits 1"
_has "$OUT" "ok 2 - operator-stop: the run ended" "realistic claude: operator-stop did end the run"
_has "$OUT" "not ok 3 - operator-stop: the stopped tool call did not run" "realistic claude: ...but its stopped call ran, and that is reported"
_has "$OUT" "ok 5 - question-park: the run ended" "realistic claude: question-park ended the run"
_has "$OUT" "ok 6 - question-park: the stopped tool call did not run" "realistic claude: ...and the deny kept its call from running"

# 3b. The same claude with the t-0077 STOP shape (continue:false + deny): every
#     check passes — the fix, modelled.
_run realistic
_eq "$RC" "0" "realistic claude, t-0077 STOP shape: the tool exits 0"
_has "$OUT" "ok 3 - operator-stop: the stopped tool call did not run" "realistic claude, t-0077 STOP shape: the deny keeps the call from running"

# 3. A claude that hangs: the watchdog ends it, within its bound, and that is a FAIL.
START=$(date +%s)
_run hang 3
ELAPSED=$(( $(date +%s) - START ))
_eq "$RC" "1" "hanging claude: the tool exits 1"
_has "$OUT" "timed out" "hanging claude: the failure says it timed out"
if [ "$ELAPSED" -lt 40 ]; then _ok "hanging claude: three 3s cases finish in ${ELAPSED}s"; else _nok "hanging claude: bounded time" "took ${ELAPSED}s"; fi

# 4. A control that does not run the tool: the check cannot see a tool run, so FAIL.
_run no-control
_eq "$RC" "1" "control that never runs the tool: the tool exits 1"
_has "$OUT" "not ok 1 - control: both commands ran" "control that never runs the tool: the control case is reported FAIL"

# 5. The stop shapes are the template's own (no drift from the real emitters).
SHAPES=$(bash "$TOOL" --print-shapes 2>/dev/null)
_stop_fmt=$(grep -o "printf '{\"continue\": false, \"stopReason\": \"%s\", \"hookSpecificOutput\": {[^']*}}" "$REPO/.claude/hooks/operator-control.sh" | head -1 | sed "s/^printf '//")
_park_fmt=$(grep -o "printf '{\"continue\": false, \"stopReason\": \"%s\", \"hookSpecificOutput\": {[^']*}}" "$REPO/.claude/hooks/ask-user-deny.sh" | head -1 | sed "s/^printf '//")
_stop_line=$(printf '%s\n' "$SHAPES" | sed -n 's/^operator-stop: //p')
_park_line=$(printf '%s\n' "$SHAPES" | sed -n 's/^question-park: //p')
# Fill the real format's %s with the tool's reason strings and compare.
# shellcheck disable=SC2059
_eq "$(printf "$_stop_fmt" "smoke: operator stop" "smoke: operator stop")" "$_stop_line" "the operator-STOP shape matches operator-control.sh"
# shellcheck disable=SC2059
_eq "$(printf "$_park_fmt" "smoke: question parked" "smoke: parked")" "$_park_line" "the question-park shape matches ask-user-deny.sh"

printf '\n1..%d\n# pass %d fail %d\n' "$_TAP_NUM" "$_TAP_PASS" "$_TAP_FAIL"
[ "$_TAP_FAIL" -eq 0 ]
