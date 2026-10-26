#!/usr/bin/env bash
# A finish-loop session can earn the evidence its commit gate requires
# (known-issue R43). Its phases are init assess fix reassess commit close — no
# review, no verify — so state-writer.sh rejected every critic and qa-verifier
# verdict a finish loop dispatched (phase_mismatch), and an interactive finish
# loop had no legitimate path to a commit. The fix: those verdicts are accepted
# when dispatched in `reassess`, and ONLY in a finish-loop session.
# Runs the real state-writer.sh and plan-approval.sh in the adversarial sandbox.
# Bash 3.2 compatible.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../.automation/tests/sandbox-setup.sh"

_N=0; _P=0; _F=0; _FAILS=""
ok()  { _N=$((_N+1)); _P=$((_P+1)); printf 'ok %d - %s\n' "$_N" "$1"; }
nok() { _N=$((_N+1)); _F=$((_F+1)); printf 'not ok %d - %s\n' "$_N" "$1"; [ -n "${2:-}" ] && printf '  # %s\n' "$2"; _FAILS="${_FAILS}  FAIL: $1\n"; }

# One fresh session of type $1 walked to phase $2; then $3 runs inside it.
_case() {
  (
    setup_adversarial_sandbox > /dev/null 2>&1
    trap 'teardown_adversarial_sandbox' EXIT
    init_phase "$1" > /dev/null 2>&1 || { echo "SETUP-FAILED init $1"; exit 0; }
    _reach "$2" > /dev/null 2>&1 || { echo "SETUP-FAILED reach $2 ($_REACH_FAILED_AT: $_REACH_ERR)"; exit 0; }
    eval "$3"
  )
}
_verdict() { # agent file — run state-writer with an APPROVED hand-back, report whether FILE landed
  run_adv_hook "state-writer.sh" "{\"agent_type\":\"$1\",\"last_assistant_message\":\"Checked.\\nGATE_RESULT: APPROVED\"}" > /dev/null 2>&1
  if grep -q '^GATE_RESULT: APPROVED' "$(get_session_state_dir)/$2" 2>/dev/null; then echo CAPTURED; else echo REJECTED; fi
}

printf '# === finish-loop verdict capture (R43) ===\n'

r=$(_case finish-loop reassess '_verdict qa-verifier qa-verified')
[ "$r" = CAPTURED ] && ok "finish-loop reassess: a qa-verifier verdict is captured" || nok "finish-loop reassess: a qa-verifier verdict is captured" "$r"

r=$(_case finish-loop reassess '_verdict critic cohesion-reviewed')
[ "$r" = CAPTURED ] && ok "finish-loop reassess: a critic verdict is captured" || nok "finish-loop reassess: a critic verdict is captured" "$r"

# Only reassess — the phase that judges the fix. assess and fix are the loop's
# own working phases; a verdict there would precede the work it signs off.
r=$(_case finish-loop fix '_verdict qa-verifier qa-verified')
[ "$r" = REJECTED ] && ok "finish-loop fix: a qa-verifier verdict is still rejected" || nok "finish-loop fix: a qa-verifier verdict is still rejected" "$r"

r=$(_case finish-loop assess '_verdict critic cohesion-reviewed')
[ "$r" = REJECTED ] && ok "finish-loop assess: a critic verdict is still rejected" || nok "finish-loop assess: a critic verdict is still rejected" "$r"

# The relaxation is bound to the session TYPE, not to a phase name another type
# could reach: a standard session in build must still reject qa-verifier.
r=$(_case standard build '_verdict qa-verifier qa-verified')
[ "$r" = REJECTED ] && ok "standard build: a qa-verifier verdict is still rejected" || nok "standard build: a qa-verifier verdict is still rejected" "$r"

# The other half of R43: an approval given AFTER init_phase is recorded. The one
# given before it is swept by the first-init evidence clear (R40), so Prompt F
# says to ask after init. Characterization — this already held.
r=$(_case finish-loop assess '
  run_adv_hook "plan-approval.sh" "{\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"questions\":[{\"question\":\"Approve this plan (large-scope: true)?\",\"options\":[{\"label\":\"Approve plan, large-scope\"}]}]},\"tool_response\":{\"answers\":{\"q\":\"Approve plan, large-scope\"}}}" > /dev/null 2>&1
  if grep -q "^large-scope: true" "$(get_session_state_dir)/plan-approved" 2>/dev/null; then echo RECORDED; else echo MISSING; fi')
[ "$r" = RECORDED ] && ok "finish-loop assess: a plan approval (large-scope) is recorded" || nok "finish-loop assess: a plan approval (large-scope) is recorded" "$r"

printf '\n1..%d\n# pass %d / fail %d\n' "$_N" "$_P" "$_F"
if [ "$_F" -gt 0 ]; then printf '%b' "$_FAILS"; exit 1; fi
exit 0
