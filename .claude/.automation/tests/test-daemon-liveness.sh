#!/usr/bin/env bash
# Daemon liveness — circuit breaker cooldown, FORCE-HALT in-session kill,
# and the `exec` that makes the tracked child pid the real process.
#
# Why this suite exists: three separate defects each left the daemon alive but
# unable to make progress, and none of them were covered by a test.
#
#   1. The circuit breaker had no exit. `_circuit_breaker_tripped` read only the
#      failure count — nothing ever read `last_failure_at`, there was no reset
#      command, and the only reset path (`_circuit_breaker_reset`) runs on a
#      SUCCESSFUL session, which the breaker itself prevents from starting. On
#      2026-10-20 the daemon sat wedged for hours until `.circuit-breaker` was
#      deleted by hand.
#   2. FORCE-HALT was only checked between entries, so it could not interrupt
#      the session it was raised against — the documented "immediate stop".
#   3. The launch subshell FORKED `claude`, so the tracked pid was a wrapper.
#      Every kill path (FORCE-HALT, the TTL watchdog, the operator stop watcher)
#      signalled the wrapper while the real process kept running.
#
# The cooldown's dangerous direction is expiring when it should not: a breaker
# that expires wrongly turns a hard stop into an unbounded retry loop against a
# broken repo. The malformed-input cases below therefore assert "still tripped".
#
# Bash 3.2 compatible.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/sandbox-setup.sh"

_TAP_NUM=0; _TAP_PASS=0; _TAP_FAIL=0; _TAP_FAILURES=""
_tap_pass() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_PASS=$((_TAP_PASS+1)); printf "ok %d - %s\n" "$_TAP_NUM" "$1"; }
_tap_fail() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_FAIL=$((_TAP_FAIL+1)); printf "not ok %d - %s\n" "$_TAP_NUM" "$1"; [ -n "${2:-}" ] && printf "  # %s\n" "$2"; _TAP_FAILURES="${_TAP_FAILURES}  FAIL: $1\n"; }
_tap_eq() {
  if [ "$1" = "$2" ]; then _tap_pass "$3"; else _tap_fail "$3" "expected '$2', got '$1'"; fi
}

printf "# === Daemon Liveness: breaker cooldown, FORCE-HALT, exec child pid ===\n"

setup_adversarial_sandbox
trap 'teardown_adversarial_sandbox' EXIT

REPO_ROOT="$ADV_SANDBOX"
export REPO_ROOT
AUTOMATION_DIR="$ADV_SANDBOX/.claude/.automation"
export AUTOMATION_DIR

# --- Extract the functions under test from runner.sh ---
# runner.sh parses argv and runs a daemon loop at load, so it cannot be sourced.
# Same technique as test-group-worktree-lifecycle.sh. Extracting keeps the test
# honest: it runs the real code rather than a restatement of it.
# REPO_OS_TEST_RUNNER_SRC overrides the file the functions are extracted from.
# It exists so the fail-first property stays reproducible: point it at a file
# carrying the pre-fix function bodies and the breaker and watcher cases must go
# red. Unset in every normal run, including CI — the default is the real runner.
_REAL_RUNNER_SRC="$_ADV_REAL_REPO/.claude/.automation/runner.sh"
_RUNNER_SRC="${REPO_OS_TEST_RUNNER_SRC:-$_REAL_RUNNER_SRC}"
# Announced, not silent. If the seam is ever left exported, the TAP output says
# which file the behavioural cases ran against instead of reporting a green
# suite for code that was never loaded. The static pins below deliberately read
# _REAL_RUNNER_SRC, so they always inspect the shipped runner regardless.
if [ "$_RUNNER_SRC" != "$_REAL_RUNNER_SRC" ]; then
  printf "# WARNING: REPO_OS_TEST_RUNNER_SRC override in effect — behavioural cases\n"
  printf "#          run against %s, NOT the shipped runner.sh\n" "$_RUNNER_SRC"
fi
_extract_runner_fn() {
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\) \\{" { inside=1 }
    inside { print }
    inside && /^}$/ { exit }
  ' "$_RUNNER_SRC"
}
_RUNNER_FNS="$ADV_SANDBOX/runner-liveness-fns.sh"
{
  _extract_runner_fn "_cb_file"
  _extract_runner_fn "_circuit_breaker_tripped"
  _extract_runner_fn "_circuit_breaker_increment"
  _extract_runner_fn "_circuit_breaker_reset"
  _extract_runner_fn "_start_force_halt_watcher"
} > "$_RUNNER_FNS"
# shellcheck disable=SC1090
source "$_RUNNER_FNS"

for _fn in _cb_file _circuit_breaker_tripped _circuit_breaker_increment \
           _circuit_breaker_reset _start_force_halt_watcher; do
  if type "$_fn" > /dev/null 2>&1; then
    _tap_pass "extracted $_fn from runner.sh"
  else
    _tap_fail "extracted $_fn from runner.sh" "function not found — did runner.sh change shape?"
  fi
done

# --- Seams the extracted functions depend on ---
QUEUE_DIR="$ADV_SANDBOX/.claude/.automation/queue"
mkdir -p "$QUEUE_DIR"
_queue_dir() { printf '%s' "$QUEUE_DIR"; }

# Config seam. The real _parse_config_field reads config.yaml; driving the
# cooldown from a variable lets one case assert the 0-disables path without
# rewriting the sandbox config between cases.
_CB_TEST_COOLDOWN="1800"
_parse_config_field() {
  if [ "${1:-}" = "runner" ] && [ "${2:-}" = "circuit_breaker_cooldown_seconds" ]; then
    printf '%s' "$_CB_TEST_COOLDOWN"
    return 0
  fi
  return 0
}

CB_FILE="$QUEUE_DIR/.circuit-breaker"

# `_cb_file` memoizes into `_CB_FILE`, which runner.sh initializes at top level
# — outside the extracted function. Without this declaration `set -u` aborts the
# whole suite on the first call, and the cases that expect "open" then pass for
# the wrong reason. Declared here rather than silently relying on the extraction.
_CB_FILE=""
_FORCE_HALT_WATCHER_PID=""

# _write_cb <count> <seconds-ago>
_write_cb() {
  local _now
  _now=$(date +%s)
  printf 'consecutive_failures: %s\nlast_failure_at: %s\nlast_failure_epoch: %s\n' \
    "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(( _now - $2 ))" > "$CB_FILE"
}
_cb_count() {
  grep '^consecutive_failures:' "$CB_FILE" 2>/dev/null | sed 's/.*: *//' | tr -d '[:space:]' | head -1
}
_cb_epoch() {
  grep '^last_failure_epoch:' "$CB_FILE" 2>/dev/null | sed 's/.*: *//' | tr -d '[:space:]' | head -1
}
# Reports "tripped" / "open" rather than an exit status so a wrong answer prints
# as a readable diff instead of "expected 0, got 1".
_tripped() {
  if _circuit_breaker_tripped 2>/dev/null; then printf 'tripped'; else printf 'open'; fi
}

printf "# --- Circuit breaker: baseline ---\n"

rm -f "$CB_FILE"
_tap_eq "$(_tripped)" "open" "no breaker file — not tripped"

_write_cb 1 10
_tap_eq "$(_tripped)" "open" "1 consecutive failure — not tripped"
_write_cb 2 10
_tap_eq "$(_tripped)" "open" "2 consecutive failures — not tripped"

printf "# --- Circuit breaker: cooldown window ---\n"

_CB_TEST_COOLDOWN="1800"
_write_cb 3 60
_tap_eq "$(_tripped)" "tripped" "3 failures 60s ago (inside 1800s window) — tripped"

# 1700, not 1799. The epoch is read in _write_cb and `elapsed` is computed from
# a second `date +%s` inside the function, so one second of wall clock between
# them flips a 1799s fixture to 1800 and the case fails spuriously on a loaded
# machine. 100s of slack still keeps it inside the window.
_write_cb 3 1700
_tap_eq "$(_tripped)" "tripped" "3 failures 1700s ago (inside the window) — tripped"

_write_cb 3 1800
_tap_eq "$(_tripped)" "open" "3 failures exactly 1800s ago — window elapsed, one probe allowed"

_write_cb 3 99999
_tap_eq "$(_tripped)" "open" "3 failures long past the window — probe allowed"

# The counter must survive the expiry check. If the check cleared it, the probe
# would start from zero and three fresh failures would be needed to re-trip —
# i.e. the breaker would degrade into a retry loop.
_write_cb 3 99999
# `|| true` is required, not decorative: sandbox-setup.sh turns on errexit, and
# an expired breaker legitimately returns 1 — a bare call ends the suite here.
_circuit_breaker_tripped 2>/dev/null || true
_tap_eq "$(_cb_count)" "3" "expiry check does NOT reset the failure count"

printf "# --- Circuit breaker: a failed probe re-trips ---\n"

_write_cb 3 99999
_tap_eq "$(_tripped)" "open" "probe allowed after the window"
_circuit_breaker_increment            # the probe fails
_tap_eq "$(_cb_count)" "4" "failed probe increments the count to 4"
_tap_eq "$(_tripped)" "tripped" "failed probe re-trips for another full window"

printf "# --- Circuit breaker: fails closed on bad timestamps ---\n"

# A breaker file written by a runner that predates the epoch field.
printf 'consecutive_failures: 3\nlast_failure_at: 2020-01-01T00:00:00Z\n' > "$CB_FILE"
_tap_eq "$(_tripped)" "tripped" "missing last_failure_epoch — stays tripped (fails closed)"

printf 'consecutive_failures: 3\nlast_failure_epoch: not-a-number\n' > "$CB_FILE"
_tap_eq "$(_tripped)" "tripped" "unparseable epoch — stays tripped (fails closed)"

printf 'consecutive_failures: 3\nlast_failure_epoch:\n' > "$CB_FILE"
_tap_eq "$(_tripped)" "tripped" "empty epoch — stays tripped (fails closed)"

# The COUNT must fail closed in the same direction as the epoch. It did not:
# `[ xyz -ge 3 ]` exits 2, so a corrupt breaker file reported "not tripped" and
# the daemon carried on — the one direction this suite's header says must never
# happen. A file that exists but cannot be read is not evidence of health.
printf 'consecutive_failures: xyz\nlast_failure_epoch: 1\n' > "$CB_FILE"
_tap_eq "$(_tripped)" "tripped" "unparseable failure count — stays tripped (fails closed)"
printf 'consecutive_failures: 3x\n' > "$CB_FILE"
_tap_eq "$(_tripped)" "tripped" "part-numeric failure count — stays tripped (fails closed)"
# A file with no count line at all is a different case: there is no failure
# record to honour, so it must NOT trip. Otherwise any stray file in the queue
# directory named .circuit-breaker would wedge the daemon permanently.
printf 'garbage: yes\n' > "$CB_FILE"
_tap_eq "$(_tripped)" "open" "breaker file with no count line — not tripped"

printf "# --- Circuit breaker: cooldown disabled ---\n"

_CB_TEST_COOLDOWN="0"
_write_cb 3 99999
_tap_eq "$(_tripped)" "tripped" "cooldown 0 — never expires, manual reset only"

# An unset / unparseable config value must fall back to the default, not to 0
# (stay-tripped-forever) and not to an empty string (arithmetic error).
_CB_TEST_COOLDOWN=""
_write_cb 3 99999
_tap_eq "$(_tripped)" "open" "empty cooldown config — falls back to the 1800s default"
# Age 99999, not 60. At 60 the case passes under EVERY candidate behaviour —
# fallback 1800, fallback 0, and the numeric guard deleted outright (a
# non-numeric cooldown makes `[ banana -gt 0 ]` return 2, so `|| return 0`
# reports tripped). That is a case that cannot fail. At 99999 only the intended
# 1800 fallback reports "open", so the assertion discriminates.
_CB_TEST_COOLDOWN="banana"
_write_cb 3 99999
_tap_eq "$(_tripped)" "open" "garbage cooldown config — falls back to the default window"
_CB_TEST_COOLDOWN="1800"

printf "# --- Config field actually reaches the breaker ---\n"

# Everything above drives the cooldown through a stub. That stub is what let the
# first version of this change ship with the field unreadable: the value carried
# an inline comment, `_parse_config_field` takes everything after `<field>: ` as
# the value, the comment's parentheses tripped the metacharacter sanitiser, and
# the field came back EMPTY — so every operator edit was silently ignored and a
# warning fired on every poll. The defect was invisible because the hardcoded
# fallback equalled the shipped number. These cases drive the REAL parser
# against the REAL config instead.
(
  # Subshell: sourcing queue-manager.sh here would collide with the seams above.
  set +e
  CONFIG_FILE="$_ADV_REAL_REPO/.claude/.automation/config.yaml"
  CONFIG_LOCAL_FILE=""
  # shellcheck disable=SC1091
  . "$ADV_SANDBOX/.claude/.automation/lib/queue-manager.sh" > /dev/null 2>&1
  _pcf_out=$(_parse_config_field "runner" "circuit_breaker_cooldown_seconds" 2>/dev/null)
  printf '%s' "$_pcf_out" > "$ADV_SANDBOX/pcf-cooldown"
  _pcf_err=$(_parse_config_field "runner" "circuit_breaker_cooldown_seconds" 2>&1 >/dev/null)
  printf '%s' "$_pcf_err" > "$ADV_SANDBOX/pcf-cooldown-err"
  _pcf_ttl=$(_parse_config_field "runner" "session_max_ttl_seconds" 2>/dev/null)
  printf '%s' "$_pcf_ttl" > "$ADV_SANDBOX/pcf-ttl"
) || true

_PCF=$(cat "$ADV_SANDBOX/pcf-cooldown" 2>/dev/null || printf '')
case "$_PCF" in
  ''|*[!0-9]*) _tap_fail "circuit_breaker_cooldown_seconds parses to a bare number" "got '$_PCF' — inline comment on the value line?" ;;
  *) _tap_pass "circuit_breaker_cooldown_seconds parses to a bare number ($_PCF)" ;;
esac
_PCF_ERR=$(cat "$ADV_SANDBOX/pcf-cooldown-err" 2>/dev/null || printf '')
if [ -z "$_PCF_ERR" ]; then
  _tap_pass "reading the cooldown emits no sanitiser warning"
else
  _tap_fail "reading the cooldown emits no sanitiser warning" "stderr: $_PCF_ERR"
fi
# Same defect, same block, one line up — the field this one was copied from.
_PCF_TTL=$(cat "$ADV_SANDBOX/pcf-ttl" 2>/dev/null || printf '')
case "$_PCF_TTL" in
  ''|*[!0-9]*) _tap_fail "session_max_ttl_seconds parses to a bare number" "got '$_PCF_TTL'" ;;
  *) _tap_pass "session_max_ttl_seconds parses to a bare number ($_PCF_TTL)" ;;
esac

printf "# --- Circuit breaker: increment and reset ---\n"

rm -f "$CB_FILE"
_circuit_breaker_increment
_tap_eq "$(_cb_count)" "1" "increment on a missing file starts at 1"
case "$(_cb_epoch)" in
  ''|*[!0-9]*) _tap_fail "increment writes a numeric last_failure_epoch" "got '$(_cb_epoch)'" ;;
  *) _tap_pass "increment writes a numeric last_failure_epoch" ;;
esac
if grep -q '^last_failure_at:' "$CB_FILE"; then
  _tap_pass "increment keeps the human-readable last_failure_at"
else
  _tap_fail "increment keeps the human-readable last_failure_at"
fi

# A corrupt count must not abort the daemon through arithmetic on a string.
printf 'consecutive_failures: xyz\n' > "$CB_FILE"
_circuit_breaker_increment
_tap_eq "$(_cb_count)" "1" "increment treats a corrupt count as 0"

_circuit_breaker_reset
if [ -f "$CB_FILE" ]; then
  _tap_fail "reset removes the breaker file"
else
  _tap_pass "reset removes the breaker file"
fi

printf "# --- queue-cli.sh reset-breaker ---\n"

# The sanctioned recovery path. Run the real CLI against the sandbox so the
# command is proven to exist and to clear the file the runner reads.
#
# The CLI is COPIED into the sandbox and run from there. queue-cli.sh derives
# REPO_ROOT from its own location, so no environment variable can redirect it:
# running the real script reached into the real repo's queue and deleted the
# live breaker file — which is exactly what happened the first time this case
# ran. Running the copy makes self-location land inside the sandbox.
cp "$_ADV_REAL_REPO/.claude/.automation/queue-cli.sh" "$AUTOMATION_DIR/queue-cli.sh"
_CLI="$AUTOMATION_DIR/queue-cli.sh"
_write_cb 3 60
_RB_OUT=$(bash "$_CLI" reset-breaker 2>&1) || true
if [ -f "$CB_FILE" ]; then
  _tap_fail "reset-breaker clears the breaker file" "file still present; output: $_RB_OUT"
else
  _tap_pass "reset-breaker clears the breaker file"
fi
case "$_RB_OUT" in
  *"3 consecutive failures"*) _tap_pass "reset-breaker reports what it cleared" ;;
  *) _tap_fail "reset-breaker reports what it cleared" "output: $_RB_OUT" ;;
esac
# The timestamp must survive field extraction whole. A greedy `s/.*: *//` eats
# up to the last colon of an ISO stamp and prints "52Z" — which reads as
# plausible output while telling the operator nothing.
case "$_RB_OUT" in
  *T??:??:??Z*) _tap_pass "reset-breaker prints the full ISO timestamp" ;;
  *) _tap_fail "reset-breaker prints the full ISO timestamp" "output: $_RB_OUT" ;;
esac
# A breaker file with no recognisable fields must still be cleared. Under
# errexit+pipefail an unguarded grep miss ends the script before the `rm -f`,
# so the command prints nothing and leaves the breaker set — the hand-deletion
# state it exists to remove. Only well-formed files were covered before.
printf 'garbage: yes\n' > "$CB_FILE"
_RB_OUT3=$(bash "$_CLI" reset-breaker 2>&1) || true
if [ -f "$CB_FILE" ]; then
  _tap_fail "reset-breaker clears a malformed breaker file" "file still present; output: $_RB_OUT3"
else
  _tap_pass "reset-breaker clears a malformed breaker file"
fi
case "$_RB_OUT3" in
  *"cleared"*) _tap_pass "reset-breaker reports clearing a malformed file" ;;
  *) _tap_fail "reset-breaker reports clearing a malformed file" "output: '$_RB_OUT3'" ;;
esac

# `status` must surface a tripped breaker. The playbook sends operators to
# `status` to diagnose a stalled queue, and a tripped breaker is the one state
# that stops the queue without any individual entry looking wrong — it was
# previously visible only by reading the file by hand.
_write_cb 4 60
_ST_OUT=$(bash "$_CLI" status 2>&1) || true
case "$_ST_OUT" in
  *TRIPPED*) _tap_pass "status reports a tripped circuit breaker" ;;
  *) _tap_fail "status reports a tripped circuit breaker" "output: $_ST_OUT" ;;
esac
_ST_JSON=$(bash "$_CLI" --json status 2>&1) || true
case "$_ST_JSON" in
  *'"circuit_breaker_failures":4'*) _tap_pass "status --json carries the failure count" ;;
  *) _tap_fail "status --json carries the failure count" "output: $_ST_JSON" ;;
esac
case "$_ST_JSON" in
  *'"circuit_breaker_tripped":true'*) _tap_pass "status --json carries the tripped verdict, not just the count" ;;
  *) _tap_fail "status --json carries the tripped verdict, not just the count" "output: $_ST_JSON" ;;
esac

# The unreadable state must still produce valid JSON. Interpolating the raw
# value with %s emitted `"circuit_breaker_failures":abc` — non-JSON, in exactly
# the state the breaker's fail-closed handling exists for, and --json is the
# form Prompt Q parses. Only the numeric case was covered when that shipped.
printf 'consecutive_failures: abc\n' > "$CB_FILE"
_ST_JSON2=$(bash "$_CLI" --json status 2>&1) || true
if printf '%s' "$_ST_JSON2" | jq -e . > /dev/null 2>&1; then
  _tap_pass "status --json stays valid JSON on an unreadable breaker count"
else
  _tap_fail "status --json stays valid JSON on an unreadable breaker count" "output: $_ST_JSON2"
fi
case "$_ST_JSON2" in
  *'"circuit_breaker_state":"unreadable"'*'"circuit_breaker_tripped":true'*)
    _tap_pass "status --json reports an unreadable breaker as tripped (fails closed)" ;;
  *) _tap_fail "status --json reports an unreadable breaker as tripped (fails closed)" "output: $_ST_JSON2" ;;
esac
# And the whole document must still parse as the object the callers expect.
_ST_PARSED=$(printf '%s' "$_ST_JSON2" | jq -r '.circuit_breaker_failures' 2>/dev/null || printf 'PARSE-FAIL')
_tap_eq "$_ST_PARSED" "null" "an unreadable count serialises as JSON null"
# Below the trip threshold the count is reported but not called tripped.
_write_cb 1 60
_ST_OUT2=$(bash "$_CLI" status 2>&1) || true
case "$_ST_OUT2" in
  *TRIPPED*) _tap_fail "status does not call 1 failure tripped" "output: $_ST_OUT2" ;;
  *"1 consecutive failure"*) _tap_pass "status reports an untripped count without calling it tripped" ;;
  *) _tap_fail "status reports an untripped count without calling it tripped" "output: $_ST_OUT2" ;;
esac
rm -f "$CB_FILE"

_RB_OUT2=$(bash "$_CLI" reset-breaker 2>&1) || true
case "$_RB_OUT2" in
  *"not set"*) _tap_pass "reset-breaker on an untripped breaker is a clean no-op" ;;
  *) _tap_fail "reset-breaker on an untripped breaker is a clean no-op" "output: $_RB_OUT2" ;;
esac

printf "# --- FORCE-HALT watcher ---\n"

rm -f "$AUTOMATION_DIR/FORCE-HALT" "$AUTOMATION_DIR/HALT"

# A stand-in for the claude child: sleeps long enough that the only way it can
# die inside the test is the watcher killing it.
#
# `exec sleep`, for the same reason the runner now execs `claude`: without it
# the subshell forks, SIGTERM reaps the wrapper and the inner `sleep` is
# orphaned for two minutes after the suite ends. With exec the tracked pid IS
# the sleep, so the kill is complete.
( exec sleep 120 ) &
_CHILD=$!
_start_force_halt_watcher "$_CHILD"
if [ -n "${_FORCE_HALT_WATCHER_PID:-}" ]; then
  _tap_pass "watcher starts and records its pid"
else
  _tap_fail "watcher starts and records its pid"
fi

touch "$AUTOMATION_DIR/FORCE-HALT"
# Budget covers the watcher's full worst case with margin: up to 5s to the next
# poll, then a 10s SIGTERM grace before SIGKILL. A 15s budget equals that worst
# case exactly and would go red on a loaded machine with no defect present.
_waited=0
while [ "$_waited" -lt 25 ] && kill -0 "$_CHILD" 2>/dev/null; do
  sleep 1
  _waited=$(( _waited + 1 ))
done
if kill -0 "$_CHILD" 2>/dev/null; then
  _tap_fail "FORCE-HALT kills the running child" "child $_CHILD still alive after ${_waited}s"
  kill -KILL "$_CHILD" 2>/dev/null || true
else
  _tap_pass "FORCE-HALT kills the running child (${_waited}s)"
fi
wait "$_CHILD" 2>/dev/null || true

# The flag is deliberately left in place: the daemon loop must still see it and
# run its own worktree/entry cleanup. A watcher that cleared the flag would make
# force-halt kill the session and then carry on with the next entry.
if [ -f "$AUTOMATION_DIR/FORCE-HALT" ]; then
  _tap_pass "watcher leaves the FORCE-HALT flag for the daemon loop"
else
  _tap_fail "watcher leaves the FORCE-HALT flag for the daemon loop"
fi
rm -f "$AUTOMATION_DIR/FORCE-HALT"
wait "${_FORCE_HALT_WATCHER_PID:-}" 2>/dev/null || true

# No flag: the watcher must exit on its own when the child finishes, or every
# entry would leak a polling subshell for the life of the daemon.
# The child outlives the watcher's first poll on purpose. With a 1s child the
# watcher could exit before ever reaching the `sleep 5`, so the case would pass
# without exercising the loop it names.
( sleep 7 ) &
_CHILD2=$!
_start_force_halt_watcher "$_CHILD2"
_W2="${_FORCE_HALT_WATCHER_PID:-}"
# Without this, an unstarted watcher makes `kill -0 ""` fail, the loop below
# never runs and the case passes for the wrong reason.
if [ -n "$_W2" ]; then
  _tap_pass "watcher started for the no-flag case"
else
  _tap_fail "watcher started for the no-flag case" "no pid recorded"
fi
wait "$_CHILD2" 2>/dev/null || true
_waited=0
while [ "$_waited" -lt 12 ] && kill -0 "$_W2" 2>/dev/null; do
  sleep 1
  _waited=$(( _waited + 1 ))
done
if kill -0 "$_W2" 2>/dev/null; then
  _tap_fail "watcher exits when the child exits without FORCE-HALT" "watcher $_W2 still alive"
  kill -KILL "$_W2" 2>/dev/null || true
else
  _tap_pass "watcher exits when the child exits without FORCE-HALT"
fi

_start_force_halt_watcher ""
# `${x-...}`, not `${x:-...}`: the correct value here IS the empty string, and
# the colon form would substitute the fallback and report a false failure.
_tap_eq "${_FORCE_HALT_WATCHER_PID-unset}" "" "watcher is a no-op with an empty child pid"

printf "# --- Tracked child pid is the real process (exec) ---\n"

# Behavioural proof of the construct, against a stub that reports its own pid.
# The real launch sites are large inline blocks inside _run_single_entry and
# cannot be extracted as functions, so the construct is exercised on a replica
# here and both real sites are pinned by the static assertions below.
_STUB_DIR="$ADV_SANDBOX/stub-bin"
mkdir -p "$_STUB_DIR"
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "%%s" "$$" > "%s/claude.pid"\n' "$ADV_SANDBOX"
  printf 'sleep 3\n'
} > "$_STUB_DIR/claude"
chmod +x "$_STUB_DIR/claude"

_run_launch() {
  # $1 — "exec" or "fork"
  rm -f "$ADV_SANDBOX/claude.pid"
  local _tracked
  if [ "$1" = "exec" ]; then
    (cd "$ADV_SANDBOX" && PATH="$_STUB_DIR:$PATH" exec claude -p <<< "prompt") &
  else
    (cd "$ADV_SANDBOX" && PATH="$_STUB_DIR:$PATH" claude -p <<< "prompt") &
  fi
  _tracked=$!
  local _w=0
  while [ "$_w" -lt 10 ] && [ ! -s "$ADV_SANDBOX/claude.pid" ]; do
    sleep 1
    _w=$(( _w + 1 ))
  done
  local _real
  _real=$(cat "$ADV_SANDBOX/claude.pid" 2>/dev/null || printf 'none')
  kill -KILL "$_tracked" 2>/dev/null || true
  kill -KILL "$_real" 2>/dev/null || true
  wait "$_tracked" 2>/dev/null || true
  if [ "$_tracked" = "$_real" ]; then printf 'same'; else printf 'different'; fi
}

_tap_eq "$(_run_launch exec)" "same" "with exec, \$! is the real child process"
# The control case. If this ever reports "same" the construct no longer
# distinguishes the two forms and the assertion above proves nothing.
_tap_eq "$(_run_launch fork)" "different" "without exec, \$! is a subshell wrapper (the old defect)"

# Static: both real launch sites must use exec. Comments are stripped first —
# the launch sites carry a comment explaining `exec`, and a grep that a comment
# can satisfy is a test that passes on prose.
_LAUNCH_CODE=$(grep -v '^[[:space:]]*#' "$_REAL_RUNNER_SRC")
_EXEC_LAUNCHES=$(printf '%s\n' "$_LAUNCH_CODE" | grep -cF 'exec claude -p' || true)
_tap_eq "${_EXEC_LAUNCHES:-0}" "2" "both launch sites use 'exec claude -p'"
# Any `claude -p` launch that is not an exec launch is a regression of the
# forked-wrapper defect.
_ALL_LAUNCHES=$(printf '%s\n' "$_LAUNCH_CODE" | grep -cF 'claude -p' || true)
_tap_eq "${_ALL_LAUNCHES:-0}" "2" "no non-exec 'claude -p' launch remains"

printf "# --- Turn budget: exhaustion must never read as success ---\n"

# A session that runs out of turns exits ZERO. On 2026-10-21 two briefs burned
# ~40 minutes each, hit "Reached max turns (200)", committed nothing, and left a
# clean tree — so one was recorded `completed:clean-noop` and its queue entry
# left the queue as though the work were done. These cases pin the routing.
(
  set +e
  # shellcheck disable=SC1091
  . "$ADV_SANDBOX/.claude/.automation/lib/outcome-detector.sh" > /dev/null 2>&1
  _TB_ERR="$ADV_SANDBOX/stderr-maxturns.txt"
  printf 'some earlier output\nError: Reached max turns (200)\n' > "$_TB_ERR"
  _TB_CLEAN="$ADV_SANDBOX/stderr-clean.txt"
  printf 'ordinary session output\n' > "$_TB_CLEAN"
  # exit 0 + the max-turns banner, from a tree with no commits.
  printf '%s' "$(detect_outcome 0 "" "$ADV_SANDBOX" "" "$_TB_ERR" 2>/dev/null)" \
    > "$ADV_SANDBOX/tb-noop.out"
  # Same, but with stderr that does NOT carry the banner — must fall through to
  # the pre-existing behaviour rather than being swept up by the new branch.
  printf '%s' "$(detect_outcome 0 "" "$ADV_SANDBOX" "" "$_TB_CLEAN" 2>/dev/null)" \
    > "$ADV_SANDBOX/tb-clean.out"
  # No stderr file at all — the mktemp-failure path. Must not crash or fire.
  printf '%s' "$(detect_outcome 0 "" "$ADV_SANDBOX" "" "" 2>/dev/null)" \
    > "$ADV_SANDBOX/tb-nostderr.out"
  # The banner without the `Error: ` prefix — a reworded CLI must still match.
  _TB_BARE="$ADV_SANDBOX/stderr-bare.txt"
  printf 'Reached max turns (400)\n' > "$_TB_BARE"
  printf '%s' "$(detect_outcome 0 "" "$ADV_SANDBOX" "" "$_TB_BARE" 2>/dev/null)" \
    > "$ADV_SANDBOX/tb-bare.out"
  # The same phrase MID-LINE must not match. This is what the anchor buys: the
  # previous unanchored form matched the phrase anywhere in the whole captured
  # stderr, so a trace or a quoted log line would have misclassified a session.
  _TB_MID="$ADV_SANDBOX/stderr-midline.txt"
  printf 'INFO: the detector greps for Reached max turns in stderr\n' > "$_TB_MID"
  printf '%s' "$(detect_outcome 0 "" "$ADV_SANDBOX" "" "$_TB_MID" 2>/dev/null)" \
    > "$ADV_SANDBOX/tb-midline.out"
) || true

_TB_OUT=$(cat "$ADV_SANDBOX/tb-noop.out" 2>/dev/null || printf 'MISSING')
_tap_eq "$_TB_OUT" "review:turn-budget-exhausted" "max-turns exhaustion routes to review, not completed"
_TB_CLEAN_OUT=$(cat "$ADV_SANDBOX/tb-clean.out" 2>/dev/null || printf 'MISSING')
case "$_TB_CLEAN_OUT" in
  review:turn-budget-exhausted)
    _tap_fail "stderr without the banner is unaffected" "got '$_TB_CLEAN_OUT' — the new branch is matching too broadly" ;;
  '' |MISSING)
    _tap_fail "stderr without the banner is unaffected" "detector produced nothing" ;;
  *)
    _tap_pass "stderr without the banner is unaffected ($_TB_CLEAN_OUT)" ;;
esac
_TB_BARE_OUT=$(cat "$ADV_SANDBOX/tb-bare.out" 2>/dev/null || printf 'MISSING')
_tap_eq "$_TB_BARE_OUT" "review:turn-budget-exhausted" "banner without the 'Error: ' prefix still matches"
_TB_MID_OUT=$(cat "$ADV_SANDBOX/tb-midline.out" 2>/dev/null || printf 'MISSING')
case "$_TB_MID_OUT" in
  review:turn-budget-exhausted)
    _tap_fail "the phrase mid-line does NOT match (anchor holds)" "unanchored match — a log line or trace containing the phrase would misclassify the session" ;;
  ''|MISSING)
    _tap_fail "the phrase mid-line does NOT match (anchor holds)" "detector produced nothing" ;;
  *)
    _tap_pass "the phrase mid-line does NOT match (anchor holds) ($_TB_MID_OUT)" ;;
esac
_TB_NONE_OUT=$(cat "$ADV_SANDBOX/tb-nostderr.out" 2>/dev/null || printf 'MISSING')
case "$_TB_NONE_OUT" in
  review:turn-budget-exhausted|''|MISSING)
    _tap_fail "absent stderr neither fires nor crashes the detector" "got '$_TB_NONE_OUT'" ;;
  *)
    _tap_pass "absent stderr neither fires nor crashes the detector ($_TB_NONE_OUT)" ;;
esac

# The banner check must sit ahead of the has_new_commits success branch: partial
# commits followed by exhaustion is the case that most looks like success.
_TB_ORDER=$(grep -v '^[[:space:]]*#' "$_ADV_REAL_REPO/.claude/.automation/lib/outcome-detector.sh" \
  | grep -nE 'Reached max turns|has_new_commits" = true' | head -2)
_TB_FIRST=$(printf '%s\n' "$_TB_ORDER" | head -1)
case "$_TB_FIRST" in
  *"Reached max turns"*) _tap_pass "the exhaustion check precedes the first has_new_commits branch" ;;
  *) _tap_fail "the exhaustion check precedes the first has_new_commits branch" "first match was: $_TB_FIRST" ;;
esac

printf "# --- Turn budget: the limit is configurable ---\n"

# Hardcoded `--max-turns 200` is what the two briefs hit. Comments are stripped
# before these greps: the launch sites carry a comment quoting the old literal,
# and a grep a comment can satisfy is a test that passes on prose.
_MT_CODE=$(grep -v '^[[:space:]]*#' "$_REAL_RUNNER_SRC")
_MT_HARDCODED=$(printf '%s\n' "$_MT_CODE" | grep -cE '\-\-max-turns[[:space:]]+[0-9]+' || true)
_tap_eq "${_MT_HARDCODED:-0}" "0" "no launch site hardcodes a turn budget"
_MT_WIRED=$(printf '%s\n' "$_MT_CODE" | grep -cF -- '--max-turns "$_session_max_turns"' || true)
_tap_eq "${_MT_WIRED:-0}" "2" "both launch sites read the configured turn budget"

(
  set +e
  CONFIG_FILE="$_ADV_REAL_REPO/.claude/.automation/config.yaml"
  CONFIG_LOCAL_FILE=""
  # shellcheck disable=SC1091
  . "$ADV_SANDBOX/.claude/.automation/lib/queue-manager.sh" > /dev/null 2>&1
  printf '%s' "$(_parse_config_field "runner" "session_max_turns" 2>/dev/null)" \
    > "$ADV_SANDBOX/mt-config"
  printf '%s' "$(_parse_config_field "runner" "session_max_turns" 2>&1 >/dev/null)" \
    > "$ADV_SANDBOX/mt-config-err"
) || true
_MT_VAL=$(cat "$ADV_SANDBOX/mt-config" 2>/dev/null || printf '')
case "$_MT_VAL" in
  ''|*[!0-9]*) _tap_fail "session_max_turns parses to a bare number" "got '$_MT_VAL' — inline comment on the value line?" ;;
  *) _tap_pass "session_max_turns parses to a bare number ($_MT_VAL)" ;;
esac
_MT_ERR=$(cat "$ADV_SANDBOX/mt-config-err" 2>/dev/null || printf '')
if [ -z "$_MT_ERR" ]; then
  _tap_pass "reading session_max_turns emits no sanitiser warning"
else
  _tap_fail "reading session_max_turns emits no sanitiser warning" "stderr: $_MT_ERR"
fi

printf "# --- Startup recovery must not close a live session ---\n"

# Startup recovery step 4 used to call runner_external_cleanup whenever
# .claude/.session-id existed — no liveness predicate at all, on a file the
# glossary documents as persistent. runner_external_cleanup is a session CLOSE
# routine: it unregisters, deletes the state directory, and writes escalations.
# So starting the daemon closed whichever session was current. On 2026-10-21
# that deleted a live interactive session's state and registry entry, and
# write-guard then refused every edit with "No phase-state".
#
# The fix is the ABSENCE of that call, so this is a static assertion — with
# comments stripped, because the replacement comment names the function it
# removed and would otherwise satisfy the grep on prose alone.
_SR_CODE=$(grep -v '^[[:space:]]*#' "$_REAL_RUNNER_SRC")
# Pins the PROPERTY, not the old literal. An earlier version of this assertion
# required the exact argument list `"$REPO_ROOT" "" "startup-recovery"`, so
# reintroducing the bug with any other arguments or spacing would have passed.
# What must hold is that `_startup_crash_recovery` contains no call at all.
_SR_FN=$(printf '%s\n' "$_SR_CODE" | awk '/^_startup_crash_recovery\(\) \{/{inside=1} inside{print} inside && /^}$/{exit}')
if [ -z "$_SR_FN" ]; then
  _tap_fail "startup recovery no longer runs a session close" "could not extract _startup_crash_recovery — did runner.sh change shape?"
else
  _SR_CALLS=$(printf '%s\n' "$_SR_FN" | grep -cE '(^|[^_[:alnum:]])runner_external_cleanup[[:space:]]' || true)
  _tap_eq "${_SR_CALLS:-0}" "0" "startup recovery no longer runs a session close"
fi
# The legitimate orphan cleanup must still be invoked — deleting step 4 is only
# correct because step 5 owns it.
_SR_SWEEP=$(printf '%s\n' "$_SR_CODE" | grep -cF 'sweep_stale_sessions' || true)
case "${_SR_SWEEP:-0}" in
  0) _tap_fail "the liveness-gated stale-session sweep is still invoked" "no call found" ;;
  *) _tap_pass "the liveness-gated stale-session sweep is still invoked" ;;
esac
# And runner_external_cleanup must survive as the close-path routine it is.
_SR_DEFINED=$(grep -cE '^runner_external_cleanup\(\)' "$_ADV_REAL_REPO/.claude/.automation/lib/state-manager.sh" || true)
_tap_eq "${_SR_DEFINED:-0}" "1" "runner_external_cleanup still exists for the close path"

printf "# --- The sweep must not evict a LIVE session ---\n"

# This is the defect that actually destroyed a session's state on 2026-10-21.
# The dead-pid arm was correct, but the 24h and TTL arms removed the registry
# entry "regardless of PID" — and the orphaned-state-dir loop then removed the
# state directory, because it keys on a missing registry entry. A ~16h-old LIVE
# interactive session lost its plan approval and every verdict, after which
# write-guard refused all of its edits.
(
  set +e
  # shellcheck disable=SC1091
  . "$ADV_SANDBOX/.claude/hooks/_analytics-helper.sh" > /dev/null 2>&1
  _SW_SESS="$ADV_SANDBOX/.claude/.state/sessions"
  _SW_WT="$ADV_SANDBOX/.claude/.state/wt-sessions"
  mkdir -p "$_SW_SESS" "$_SW_WT/live-old" "$_SW_WT/dead-old"
  # A live session, far older than any TTL: this process, which is definitionally
  # alive. Using $$ rather than a made-up pid is the point — a fabricated pid
  # could be dead and the case would pass for the wrong reason.
  printf 'session_id: live-old\nsession_type: standard\nbranch: main\npid: %s\nstarted_at: 2020-01-01T00:00:00Z\n' "$$" \
    > "$_SW_SESS/live-old.yaml"
  printf 'marker\n' > "$_SW_WT/live-old/plan-approved"
  # A genuinely dead session of the same age — pid 1 is init-owned and not ours,
  # so pick an unused high pid and confirm it is dead before relying on it.
  _SW_DEAD=99999
  while kill -0 "$_SW_DEAD" 2>/dev/null; do _SW_DEAD=$(( _SW_DEAD - 1 )); done
  printf 'session_id: dead-old\nsession_type: standard\nbranch: main\npid: %s\nstarted_at: 2020-01-01T00:00:00Z\n' "$_SW_DEAD" \
    > "$_SW_SESS/dead-old.yaml"
  printf 'marker\n' > "$_SW_WT/dead-old/plan-approved"
  REPO_ROOT="$ADV_SANDBOX" _REPO_OS_ROOT="$ADV_SANDBOX" sweep_stale_sessions > /dev/null 2>&1
  # Report presence as words so a failure prints readably.
  { [ -f "$_SW_SESS/live-old.yaml" ] && printf 'kept' || printf 'evicted'; } > "$ADV_SANDBOX/sw-live-reg"
  { [ -f "$_SW_WT/live-old/plan-approved" ] && printf 'kept' || printf 'evicted'; } > "$ADV_SANDBOX/sw-live-state"
  { [ -f "$_SW_SESS/dead-old.yaml" ] && printf 'kept' || printf 'evicted'; } > "$ADV_SANDBOX/sw-dead-reg"
) || true

_tap_eq "$(cat "$ADV_SANDBOX/sw-live-reg" 2>/dev/null || printf MISSING)" "kept" \
  "a live session's registry entry survives the sweep however old it is"
_tap_eq "$(cat "$ADV_SANDBOX/sw-live-state" 2>/dev/null || printf MISSING)" "kept" \
  "a live session's state directory survives the sweep"
# The control: the sweep must still do its job. If this reports "kept" the fix
# has disabled the sweep rather than scoped it, and the two cases above prove
# nothing.
_tap_eq "$(cat "$ADV_SANDBOX/sw-dead-reg" 2>/dev/null || printf MISSING)" "evicted" \
  "a dead session's registry entry is still reaped (fix scopes, does not disable)"

# The orphan-state-dir loop, pinned on its own. The case above reaches it only
# via the registry arms, so it could not tell whether the loop itself is gated —
# and that loop is where state is actually destroyed. A live session whose
# registry entry is already missing (the state this defect produced) must keep
# its state directory.
(
  set +e
  # shellcheck disable=SC1091
  . "$ADV_SANDBOX/.claude/hooks/_analytics-helper.sh" > /dev/null 2>&1
  _OS_WT="$ADV_SANDBOX/.claude/.state/wt-sessions"
  mkdir -p "$_OS_WT/live-unregistered" "$_OS_WT/dead-unregistered"
  printf 'marker\n' > "$_OS_WT/live-unregistered/plan-approved"
  printf 'marker\n' > "$_OS_WT/dead-unregistered/plan-approved"
  # The decisive liveness signal is the per-process sidecar: a file named
  # .session-id.<pid> whose contents are the session id.
  printf 'live-unregistered\n' > "$ADV_SANDBOX/.claude/.session-id.$$"
  _OS_DEAD=99998
  while kill -0 "$_OS_DEAD" 2>/dev/null; do _OS_DEAD=$(( _OS_DEAD - 1 )); done
  printf 'dead-unregistered\n' > "$ADV_SANDBOX/.claude/.session-id.$_OS_DEAD"
  REPO_ROOT="$ADV_SANDBOX" _REPO_OS_ROOT="$ADV_SANDBOX" sweep_stale_sessions > /dev/null 2>&1
  { [ -d "$_OS_WT/live-unregistered" ] && printf 'kept' || printf 'evicted'; } > "$ADV_SANDBOX/os-live"
  { [ -d "$_OS_WT/dead-unregistered" ] && printf 'kept' || printf 'evicted'; } > "$ADV_SANDBOX/os-dead"
) || true

_tap_eq "$(cat "$ADV_SANDBOX/os-live" 2>/dev/null || printf MISSING)" "kept" \
  "the orphan-state-dir loop spares a live session with no registry entry"
_tap_eq "$(cat "$ADV_SANDBOX/os-dead" 2>/dev/null || printf MISSING)" "evicted" \
  "the orphan-state-dir loop still reaps a dead session's state"

printf "# --- review/ has an exit ---\n"

# Before 2026-10-21 nothing could move an entry out of review/: approve handles
# pending-review, recover-entry handles running, reopen-wo resets blocked|failed.
# So every review:* outcome — including the new turn-budget one — was a one-way
# door, and the first draft of that outcome's own comment named two commands
# that cannot move the entry.
_RE_Q="$ADV_SANDBOX/.claude/.automation/queue"
mkdir -p "$_RE_Q/review" "$_RE_Q/approved"
{
  printf 'entry:\n'
  printf '  id: "re-probe-1"\n'
  printf '  status: "review"\n'
  printf '  priority: "0"\n'
  printf '  session_type: "standard"\n'
  printf '  branch: ""\n'
  printf '  brief_path: ".claude/.automation/briefs/re-probe.md"\n'
  printf '  prompt: ""\n'
  printf '  last_prompt: ""\n'
  printf '  auto_mode: "false"\n'
  printf '  solo_mode: "false"\n'
  printf '  push_on_complete: "false"\n'
  printf '  retry_count: "3"\n'
  printf '  max_retries: "3"\n'
  printf '  error_log: "review:turn-budget-exhausted"\n'
  printf '  created_at: "2026-10-21T00:00:00Z"\n'
  printf '  updated_at: "2026-10-21T00:00:00Z"\n'
} > "$_RE_Q/review/re-probe-1.yaml"
_RE_OUT=$(bash "$_CLI" reopen-entry re-probe-1 2>&1) || true
if [ -f "$_RE_Q/approved/re-probe-1.yaml" ]; then
  _tap_pass "reopen-entry moves a reviewed entry back to approved"
else
  _tap_fail "reopen-entry moves a reviewed entry back to approved" "output: $_RE_OUT"
fi
# Seeded at the exhausted value on purpose, so a no-op cannot pass this.
_RE_RETRY=$(grep '^  retry_count:' "$_RE_Q/approved/re-probe-1.yaml" 2>/dev/null \
  | sed 's/^[^:]*: *//' | tr -d '"[:space:]' | head -1) || _RE_RETRY=""
_tap_eq "${_RE_RETRY:-unset}" "0" "reopen-entry restores the retry budget"
# And it must refuse an entry that is not in review/, rather than inventing one.
_RE_OUT2=$(bash "$_CLI" reopen-entry no-such-entry 2>&1) || true
case "$_RE_OUT2" in
  *"not in review"*) _tap_pass "reopen-entry refuses an entry that is not in review/" ;;
  *) _tap_fail "reopen-entry refuses an entry that is not in review/" "output: $_RE_OUT2" ;;
esac

# THE case that matters, and the one the first fixture omitted. Every entry gets
# a work order — `single` for a standalone entry — and a child in review makes
# the work order `escalated`. The runner's post-dequeue guard then defers the
# entry and, after max_deferral_cycles, transitions it to `blocked/`. So an
# entry reopened without clearing its work order is walked straight into
# `blocked/`, and the advertised exit merely relocates the failure. The first
# version of this suite tested only the no-work-order path, which is exactly
# why that defect reached review rather than being caught here.
mkdir -p "$_RE_Q/work-orders"
{
  printf 'entry:\n'
  printf '  id: "re-probe-2"\n'
  printf '  status: "review"\n'
  printf '  priority: "0"\n'
  printf '  session_type: "standard"\n'
  printf '  branch: ""\n'
  printf '  brief_path: ".claude/.automation/briefs/re-probe.md"\n'
  printf '  prompt: "the prompt the exhausted session ran"\n'
  printf '  last_prompt: ""\n'
  printf '  auto_mode: "false"\n'
  printf '  solo_mode: "false"\n'
  printf '  push_on_complete: "false"\n'
  printf '  retry_count: "3"\n'
  printf '  max_retries: "3"\n'
  printf '  error_log: "review:turn-budget-exhausted"\n'
  printf '  work_order_id: "re-wo-2"\n'
  printf '  created_at: "2026-10-21T00:00:00Z"\n'
  printf '  updated_at: "2026-10-21T00:00:00Z"\n'
} > "$_RE_Q/review/re-probe-2.yaml"
{
  printf 'work_order:\n'
  printf '  id: re-wo-2\n'
  printf '  type: single\n'
  printf '  label: re-probe-2\n'
  printf '  entry_ids:\n'
  printf '  - re-probe-2\n'
  printf '  status: escalated\n'
  printf '  created_at: 2026-10-21T00:00:00Z\n'
  printf '  updated_at: 2026-10-21T00:00:00Z\n'
  printf '  completed_at: \n'
} > "$_RE_Q/work-orders/re-wo-2.yaml"
# A part-spent deferral counter, as a previously-deferred entry would carry.
printf '2\n' > "$_RE_Q/.defer-count-re-probe-2"
_RE_OUT3=$(bash "$_CLI" reopen-entry re-probe-2 2>&1) || true
_RE_WO_STATUS=$(grep '^  status:' "$_RE_Q/work-orders/re-wo-2.yaml" 2>/dev/null \
  | sed 's/^[^:]*: *//' | tr -d '"[:space:]' | head -1) || _RE_WO_STATUS=""
case "${_RE_WO_STATUS:-unset}" in
  escalated|failed)
    _tap_fail "reopen-entry clears the parent work order's escalation" \
      "work order is still '$_RE_WO_STATUS' — the entry will be deferred into blocked/; output: $_RE_OUT3" ;;
  unset|'')
    _tap_fail "reopen-entry clears the parent work order's escalation" "could not read work order status" ;;
  *)
    _tap_pass "reopen-entry clears the parent work order's escalation ($_RE_WO_STATUS)" ;;
esac
if [ -f "$_RE_Q/.defer-count-re-probe-2" ]; then
  _tap_fail "reopen-entry clears a part-spent deferral counter" "counter file still present"
else
  _tap_pass "reopen-entry clears a part-spent deferral counter"
fi
# The prompt that ran must survive as last_prompt rather than being destroyed.
_RE_LAST=$(grep '^  last_prompt:' "$_RE_Q/approved/re-probe-2.yaml" 2>/dev/null \
  | sed 's/^[^:]*: *//' | head -1) || _RE_LAST=""
case "$_RE_LAST" in
  *"the prompt the exhausted session ran"*) _tap_pass "reopen-entry preserves the prompt as last_prompt" ;;
  *) _tap_fail "reopen-entry preserves the prompt as last_prompt" "last_prompt is '$_RE_LAST'" ;;
esac

# A GROUP work order with another child still failed. Reopening the group here
# would un-gate siblings the deferral guard is deliberately holding AND erase
# failure_entry_id while that sibling sits in failed/, so the command must
# decline and say so. The first version called wo_reopen unconditionally and no
# fixture used a group, which is why that over-reach reached review.
_RG_ID="rg-child-1"
_RG_SIB="rg-child-2"
{
  printf 'entry:\n'
  printf '  id: "%s"\n' "$_RG_ID"
  printf '  status: "review"\n'
  printf '  priority: "0"\n'
  printf '  session_type: "taskgroup"\n'
  printf '  branch: "feature/rg-probe"\n'
  printf '  brief_path: ".claude/.automation/briefs/rg-probe.md"\n'
  printf '  prompt: ""\n'
  printf '  last_prompt: ""\n'
  printf '  auto_mode: "false"\n'
  printf '  solo_mode: "false"\n'
  printf '  push_on_complete: "false"\n'
  printf '  retry_count: "1"\n'
  printf '  max_retries: "3"\n'
  printf '  error_log: "review:incomplete-deliverable"\n'
  printf '  work_order_id: "rg-wo-1"\n'
  printf '  created_at: "2026-10-21T00:00:00Z"\n'
  printf '  updated_at: "2026-10-21T00:00:00Z"\n'
} > "$_RE_Q/review/${_RG_ID}.yaml"
mkdir -p "$_RE_Q/failed"
{
  printf 'entry:\n'
  printf '  id: "%s"\n' "$_RG_SIB"
  printf '  status: "failed"\n'
  printf '  priority: "1"\n'
  printf '  session_type: "taskgroup"\n'
  printf '  branch: "feature/rg-probe"\n'
  printf '  brief_path: ".claude/.automation/briefs/rg-probe-2.md"\n'
  printf '  prompt: ""\n'
  printf '  last_prompt: ""\n'
  printf '  auto_mode: "false"\n'
  printf '  solo_mode: "false"\n'
  printf '  push_on_complete: "false"\n'
  printf '  retry_count: "3"\n'
  printf '  max_retries: "3"\n'
  printf '  error_log: "failed:crash"\n'
  printf '  work_order_id: "rg-wo-1"\n'
  printf '  created_at: "2026-10-21T00:00:00Z"\n'
  printf '  updated_at: "2026-10-21T00:00:00Z"\n'
} > "$_RE_Q/failed/${_RG_SIB}.yaml"
{
  printf 'work_order:\n'
  printf '  id: rg-wo-1\n'
  printf '  type: group\n'
  printf '  label: feature/rg-probe\n'
  printf '  entry_ids:\n'
  printf '  - %s\n' "$_RG_ID"
  printf '  - %s\n' "$_RG_SIB"
  printf '  status: failed\n'
  printf '  created_at: 2026-10-21T00:00:00Z\n'
  printf '  updated_at: 2026-10-21T00:00:00Z\n'
  printf '  completed_at: \n'
  printf '  failure_entry_id: %s\n' "$_RG_SIB"
} > "$_RE_Q/work-orders/rg-wo-1.yaml"
_RG_OUT=$(bash "$_CLI" reopen-entry "$_RG_ID" 2>&1) || true
# The entry itself still moves — the operator asked for that and it is harmless.
if [ -f "$_RE_Q/approved/${_RG_ID}.yaml" ]; then
  _tap_pass "reopen-entry still moves a group entry out of review"
else
  _tap_fail "reopen-entry still moves a group entry out of review" "output: $_RG_OUT"
fi
# But the group work order must be left alone.
_RG_WO_STATUS=$(grep '^  status:' "$_RE_Q/work-orders/rg-wo-1.yaml" 2>/dev/null \
  | sed 's/^[^:]*: *//' | tr -d '"[:space:]' | head -1) || _RG_WO_STATUS=""
_tap_eq "${_RG_WO_STATUS:-unset}" "failed" \
  "a group work order with a failed sibling is NOT reopened"
# And the pointer to the brief that actually broke must survive.
_RG_FAIL_ID=$(grep '^  failure_entry_id:' "$_RE_Q/work-orders/rg-wo-1.yaml" 2>/dev/null \
  | sed 's/^[^:]*: *//' | tr -d '"[:space:]' | head -1) || _RG_FAIL_ID=""
_tap_eq "${_RG_FAIL_ID:-unset}" "$_RG_SIB" "the group's failure pointer is not erased"
# And the operator must be told what to do instead.
case "$_RG_OUT" in
  *"reopen-wo rg-wo-1"*) _tap_pass "the operator is pointed at reopen-wo for the group" ;;
  *) _tap_fail "the operator is pointed at reopen-wo for the group" "output: $_RG_OUT" ;;
esac
# The declined case must be distinguishable on STDOUT, not only on stderr — both
# output forms used to be byte-identical whether the work order was cleared or
# left failed, so neither a human nor a script could tell a full recovery from a
# half one.
case "$_RG_OUT" in
  *"NOT fully recovered"*) _tap_pass "a declined group reopen says so on stdout" ;;
  *) _tap_fail "a declined group reopen says so on stdout" "output: $_RG_OUT" ;;
esac
# And in JSON, which is what Prompt Q parses. Re-stage the fixture, since the
# run above moved the entry.
{
  printf 'entry:\n'
  printf '  id: "rg-child-3"\n'
  printf '  status: "review"\n'
  printf '  priority: "0"\n'
  printf '  session_type: "taskgroup"\n'
  printf '  branch: "feature/rg-probe"\n'
  printf '  brief_path: ".claude/.automation/briefs/rg-probe.md"\n'
  printf '  prompt: ""\n'
  printf '  last_prompt: ""\n'
  printf '  auto_mode: "false"\n'
  printf '  solo_mode: "false"\n'
  printf '  push_on_complete: "false"\n'
  printf '  retry_count: "1"\n'
  printf '  max_retries: "3"\n'
  printf '  error_log: "review:incomplete-deliverable"\n'
  printf '  work_order_id: "rg-wo-1"\n'
  printf '  created_at: "2026-10-21T00:00:00Z"\n'
  printf '  updated_at: "2026-10-21T00:00:00Z"\n'
} > "$_RE_Q/review/rg-child-3.yaml"
perl -i -pe 's/^  entry_ids:$/  entry_ids:\n  - rg-child-3/' "$_RE_Q/work-orders/rg-wo-1.yaml"
_RG_JSON=$(bash "$_CLI" --json reopen-entry rg-child-3 2>/dev/null) || true
if printf '%s' "$_RG_JSON" | jq -e . > /dev/null 2>&1; then
  _tap_pass "reopen-entry --json emits valid JSON"
else
  _tap_fail "reopen-entry --json emits valid JSON" "output: $_RG_JSON"
fi
_RG_WOR=$(printf '%s' "$_RG_JSON" | jq -r '.work_order_reopened' 2>/dev/null || printf 'PARSE-FAIL')
_tap_eq "$_RG_WOR" "false" "reopen-entry --json reports that the work order was not reopened"

printf "\n# === Summary ===\n"
printf "1..%d\n" "$_TAP_NUM"
printf "# pass %d / fail %d\n" "$_TAP_PASS" "$_TAP_FAIL"
if [ "$_TAP_FAIL" -gt 0 ]; then
  printf "%b" "$_TAP_FAILURES"
  exit 1
fi
exit 0
