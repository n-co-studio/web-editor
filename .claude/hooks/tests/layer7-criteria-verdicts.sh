#!/usr/bin/env bash
# Layer 7 — Per-criterion verdict capture regression tests (Decision t-0048).
#
# Validates _capture_criteria_verdicts() in state-writer.sh, which parses the
# cohesion brief's two per-criterion tables into a session sidecar and a durable
# per-session record:
#
#   L7.1  Both tables captured, kept as SEPARATE verdicts per criterion.
#   L7.2  All verdict tokens parse; INCOMPLETE is not mis-split as COMPLETE.
#   L7.3  Criterion text containing dashes survives the verdict split intact.
#   L7.4  Emitted YAML is machine-parseable (indentation + quoting hold).
#   L7.5  Quotes and backslashes in agent text are escaped, not YAML-breaking.
#   L7.6  A second dispatch APPENDS round 2 rather than overwriting round 1.
#   L7.7  Sidecar session_id is unquoted, so _delete_if_owned actually matches it.
#   L7.8  Advisory contract: a brief with neither section is a silent no-op, and
#         a malformed brief never returns non-zero (would abort the hook under
#         `set -euo pipefail` and cost the session its real verdict files).
#
# The function is extracted from the shipped hook rather than copied, so these
# tests exercise the real code path.
#
# Bash 3.2 compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/test-helpers.sh"

HOOK="$SCRIPT_DIR/../state-writer.sh"

setup_sandbox

CV_DIR="$_SANDBOX_DIR/state"
CV_REPO="$_SANDBOX_DIR/repo"
mkdir -p "$CV_DIR" "$CV_REPO/docs/ai/governance" "$CV_REPO/.claude/.state"

# --- Extract the function under test from the shipped hook ---
awk '/^_capture_criteria_verdicts\(\) \{/,/^\}$/' "$HOOK" > "$_SANDBOX_DIR/fn.sh"
assert_file_exists "$_SANDBOX_DIR/fn.sh" "L7.0 _capture_criteria_verdicts extracted from state-writer.sh"

# --- Stub the hook globals the function reads ---
STATE_DIR="$CV_DIR"
TIMESTAMP="2026-09-15T21:00:00Z"
STATE_SID="layer7-session"
DISPATCH_PHASE="review"
DISPATCH_CYCLE=1
CURRENT_PHASE="review"
get_main_repo_root() { echo "$CV_REPO"; }

# shellcheck disable=SC1091
source "$_SANDBOX_DIR/fn.sh"

SIDECAR="$CV_DIR/criteria-verdicts.yaml"
DURABLE="$CV_REPO/docs/ai/governance/criteria-verdicts/layer7-session.yaml"

# --- Fixture: exercises every verdict token, an embedded dash, and a quote ---
read -r -d '' BRIEF <<'FIXTURE' || true
## Cohesion Brief

### Contract Verification
1. nomenclature + 3 schemas validate to repo style — VERIFIED
   - Evidence: docs/ai/eval/_nomenclature.md:1
2. cell records round-trip through the suite runner — UNVERIFIED
   - Evidence: none found
3. pre-commit gates fire on the "staged" diff — INCONCLUSIVE
   - Evidence: requires runtime verification
4. deferred criterion — INCONCLUSIVE
   - Evidence: annotated [deferred]

### Completeness
1. nomenclature + 3 schemas validate to repo style — COMPLETE
   - Evidence: all three schema files parse
2. cell records round-trip through the suite runner — INCOMPLETE
   - Evidence: suite runner does not read cells/*.yaml
3. pre-commit gates fire on the "staged" diff — PARTIAL
   - Evidence: no fixture run performed
4. deferred criterion — N/A
   - Evidence: excluded from count

### Summary
Mixed.

COMPLETENESS: 1/3 criteria met
COMPLETENESS_GATE: NEEDS_WORK

GATE_RESULT: APPROVED
FIXTURE

_capture_criteria_verdicts "$BRIEF"

# --- L7.1 both tables captured as separate verdicts ---
assert_file_exists "$SIDECAR" "L7.1 sidecar written"
assert_file_contains "$SIDECAR" "contract_verification:" "L7.1 contract_verification key present"
assert_file_contains "$SIDECAR" "completeness:" "L7.1 completeness key present"
# Criterion 2 diverges across the two tables — the divergence must survive.
assert_eq "$(grep -A3 'cell records' "$SIDECAR" | grep -c 'verdict: UNVERIFIED')" "1" \
  "L7.1 criterion 2 keeps its UNVERIFIED diff verdict"
assert_file_contains "$SIDECAR" "verdict: INCOMPLETE" "L7.1 criterion 2 keeps its INCOMPLETE completeness verdict"

# --- L7.2 every token parses; INCOMPLETE not mis-split as COMPLETE ---
for tok in VERIFIED UNVERIFIED INCONCLUSIVE COMPLETE INCOMPLETE PARTIAL N/A; do
  assert_file_contains "$SIDECAR" "verdict: $tok" "L7.2 verdict token $tok parsed"
done
assert_eq "$(grep -c 'verdict: ABSENT' "$SIDECAR" || true)" "0" \
  "L7.2 no criterion degraded to ABSENT"

# --- L7.3 criterion text with an embedded dash is not truncated ---
assert_file_contains "$SIDECAR" "nomenclature + 3 schemas validate to repo style" \
  "L7.3 criterion text preserved in full"
assert_eq "$(grep -c 'criterion: .*— VERIFIED' "$SIDECAR" || true)" "0" \
  "L7.3 verdict token stripped from criterion text"

# --- L7.4 / L7.5 emitted YAML parses, embedded quotes escaped ---
assert_file_contains "$SIDECAR" '\\"staged\\"' \
  "L7.5 embedded double quotes escaped for YAML"
if command -v python3 > /dev/null 2>&1 && python3 -c "import yaml" 2>/dev/null; then
  for f in "$SIDECAR" "$DURABLE"; do
    _rc=0
    python3 -c "import yaml; yaml.safe_load(open('$f'))" 2>/dev/null || _rc=$?
    assert_ok "$_rc" "L7.4 $(basename "$f") parses as YAML"
  done
else
  printf "# L7.4 YAML parse check skipped: python3 + pyyaml unavailable\n"
fi

# --- L7.6 second dispatch appends a round rather than overwriting ---
assert_file_exists "$DURABLE" "L7.6 durable record written"
assert_eq "$(grep -c '^  - round: ' "$DURABLE")" "1" "L7.6 first dispatch writes round 1"
DISPATCH_CYCLE=2
_capture_criteria_verdicts "$BRIEF"
assert_eq "$(grep -c '^  - round: ' "$DURABLE")" "2" "L7.6 second dispatch appends round 2"
assert_file_contains "$DURABLE" "  - round: 1" "L7.6 round 1 retained after append"
assert_file_contains "$DURABLE" "  - round: 2" "L7.6 round 2 numbered from existing count"
assert_eq "$(grep -c '^schema: ' "$DURABLE")" "1" "L7.6 header written once, not per round"

# --- L7.7 sidecar session_id unquoted so _delete_if_owned matches it ---
assert_file_contains "$SIDECAR" "session_id: layer7-session" \
  "L7.7 sidecar session_id is unquoted"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../_cleanup-helper.sh"
_delete_if_owned "$SIDECAR" "some-other-session"
assert_file_exists "$SIDECAR" "L7.7 sidecar retained for a foreign session id"
_delete_if_owned "$SIDECAR" "layer7-session"
assert_file_not_exists "$SIDECAR" "L7.7 sidecar deleted for the owning session id"

# --- L7.8 advisory contract: no sections, and malformed input, both benign ---
_rc=0; _capture_criteria_verdicts 'no tables here at all' || _rc=$?
assert_ok "$_rc" "L7.8 brief with neither section returns 0"
assert_file_not_exists "$SIDECAR" "L7.8 no sidecar written when sections absent"

MALFORMED='### Completeness
1. truncated row with no verdict
   - Evidence:
### Contract Verification
not-a-numbered-row — COMPLETE'
_rc=0; _capture_criteria_verdicts "$MALFORMED" || _rc=$?
assert_ok "$_rc" "L7.8 malformed brief returns 0 (never aborts the hook)"


# --- L7.9 GATE_RESULT sentinel tolerates content-free separators ---
# state-writer.sh requires each section's last MEANINGFUL line to be the
# GATE_RESULT: sentinel (Decision t-0039). It previously used the last
# NON-EMPTY line, so a markdown horizontal rule after the verdict discarded it.
# On 2026-10-12 a critic emitted a trailing '---' after its cohesion verdict and
# BOTH verdicts were thrown away — including a correctly terminated diff-review
# section — twice in a row, looping the brief until it was force-stopped. Seven
# such rejections exist across critic, qa-verifier and security-privacy.
# Punctuation is skipped; prose is not, so the contract itself still holds.
tap_section "L7.9: sentinel tolerates separators, never prose"

eval "$(awk '/^_last_meaningful_line\(\) \{/,/^\}/' "$(cd "$SCRIPT_DIR/.." && pwd)/state-writer.sh")"

if type _last_meaningful_line > /dev/null 2>&1; then
  _tap_pass "L7.9 _last_meaningful_line extracted from state-writer.sh"
else
  _tap_fail "L7.9 _last_meaningful_line extracted from state-writer.sh" "function not found"
fi

_lml() { printf '%b' "$1" | _last_meaningful_line; }

assert_eq "$(_lml 'GATE_RESULT: APPROVED\n')" "GATE_RESULT: APPROVED" \
  "L7.9 plain terminal sentinel"
assert_eq "$(_lml 'GATE_RESULT: APPROVED\n\n')" "GATE_RESULT: APPROVED" \
  "L7.9 trailing blank lines skipped"
assert_eq "$(_lml 'GATE_RESULT: APPROVED\n\n---\n')" "GATE_RESULT: APPROVED" \
  "L7.9 trailing --- skipped (the 2026-10-12 failure)"
assert_eq "$(_lml 'GATE_RESULT: APPROVED\n***\n')" "GATE_RESULT: APPROVED" \
  "L7.9 trailing *** skipped"
assert_eq "$(_lml 'GATE_RESULT: APPROVED\n___\n')" "GATE_RESULT: APPROVED" \
  "L7.9 trailing ___ skipped"
assert_eq "$(_lml 'GATE_RESULT: APPROVED\n- - -\n')" "GATE_RESULT: APPROVED" \
  "L7.9 spaced rule - - - skipped"

# The contract must still bite: anything with content after the sentinel fails.
assert_eq "$(_lml 'GATE_RESULT: APPROVED\nOne more thought.\n')" "One more thought." \
  "L7.9 trailing PROSE still wins (sentinel contract intact)"
assert_eq "$(_lml 'GATE_RESULT: APPROVED\n## Another Section\n')" "## Another Section" \
  "L7.9 trailing heading still wins"
assert_eq "$(_lml 'GATE_RESULT: APPROVED\n--\n')" "--" \
  "L7.9 two dashes are not a horizontal rule"

# --- L7.10 Handback transcript recovery ---
# The harness ends a subagent with a SubagentHandback tool call carrying the
# report in .input.message, and emits no final assistant text block. state-writer
# read .last_assistant_message, which is then empty, so on 2026-10-13 NO verdict
# of any kind could be captured — four consecutive Pragmatist APPROVED verdicts
# were lost and the session deadlocked. These tests pin the recovery filter:
# the right transcript field, the last handback when several exist, and survival
# of a malformed line (a torn trailing write while the transcript is flushing).
tap_section "L7.10: handback transcript recovery"

_L710_DIR="${TMPDIR:-/tmp}/l710-$$"
mkdir -p "$_L710_DIR"

# The extraction as state-writer.sh runs it: per-line fromjson?, compact string
# output so one handback is one line, last wins, then decode.
_recover_handback() {
  local _f="$1" _hb
  _hb=$(jq -R -c '
    fromjson?
    | (.message?.content? // [])
    | .[]?
    | select(type == "object")
    | select(.type == "tool_use" and .name == "SubagentHandback")
    | .input?.message? // empty
  ' "$_f" 2>/dev/null | tail -1 || true)
  [ -n "$_hb" ] || return 0
  printf '%s' "$_hb" | jq -r '.' 2>/dev/null || true
}

_mk_handback_line() {
  # $1 — message text (literal \n sequences are expanded)
  printf '%b' "$1" | jq -Rs '{message: {content: [{type: "tool_use", name: "SubagentHandback", input: {message: .}}]}}' -c
}

# One handback, multi-line report — the sentinel must survive intact.
_mk_handback_line 'Review body here.\n\nGATE_RESULT: APPROVED' > "$_L710_DIR/one.jsonl"
assert_eq "$(_recover_handback "$_L710_DIR/one.jsonl" | _last_meaningful_line)" \
  "GATE_RESULT: APPROVED" \
  "L7.10 single handback: multi-line report recovered, sentinel terminal"

# Several handbacks (a resumed agent): the LAST one is the verdict that counts.
{
  _mk_handback_line 'First pass.\n\nGATE_RESULT: BLOCKED'
  _mk_handback_line 'Second pass.\n\nGATE_RESULT: APPROVED'
} > "$_L710_DIR/two.jsonl"
assert_eq "$(_recover_handback "$_L710_DIR/two.jsonl" | _last_meaningful_line)" \
  "GATE_RESULT: APPROVED" \
  "L7.10 multiple handbacks: last verdict wins"

# A torn trailing write must not cost the verdict. `jq -rs` slurps and exits
# non-zero on the whole file here, which is the total-loss failure this guards.
{
  cat "$_L710_DIR/one.jsonl"
  printf '{"partial":"tr'
} > "$_L710_DIR/torn.jsonl"
assert_eq "$(_recover_handback "$_L710_DIR/torn.jsonl" | _last_meaningful_line)" \
  "GATE_RESULT: APPROVED" \
  "L7.10 malformed trailing line skipped, verdict still recovered"

# Non-object and shapeless content lines must be skipped, not crash the filter.
{
  printf '"just a string"\n'
  printf '42\n'
  printf '{"message":null}\n'
  printf '{"message":{"content":"not an array"}}\n'
  printf '{"message":{"content":[{"type":"text","text":"no handback here"}]}}\n'
  cat "$_L710_DIR/one.jsonl"
} > "$_L710_DIR/noise.jsonl"
assert_eq "$(_recover_handback "$_L710_DIR/noise.jsonl" | _last_meaningful_line)" \
  "GATE_RESULT: APPROVED" \
  "L7.10 valid-but-wrong-shape lines skipped"

# No handback at all — empty, so the caller falls through to the diagnostic path
# rather than writing a verdict from nothing.
printf '{"message":{"content":[{"type":"text","text":"hello"}]}}\n' > "$_L710_DIR/none.jsonl"
assert_eq "$(_recover_handback "$_L710_DIR/none.jsonl")" "" \
  "L7.10 transcript with no handback yields empty, not a false verdict"

# Field precedence: agent_transcript_path is the SUBAGENT's transcript;
# transcript_path is the parent session's and holds no handbacks. Reading the
# parent first is what made the first version of this fix look like an absent
# verdict rather than a wrong field.
_PAYLOAD=$(printf '{"agent_transcript_path":"%s","transcript_path":"%s"}' \
  "$_L710_DIR/one.jsonl" "$_L710_DIR/none.jsonl")
assert_eq "$(printf '%s' "$_PAYLOAD" | jq -r '.agent_transcript_path // .transcript_path // empty')" \
  "$_L710_DIR/one.jsonl" \
  "L7.10 agent_transcript_path takes precedence over transcript_path"
_PAYLOAD_PARENT=$(printf '{"transcript_path":"%s"}' "$_L710_DIR/one.jsonl")
assert_eq "$(printf '%s' "$_PAYLOAD_PARENT" | jq -r '.agent_transcript_path // .transcript_path // empty')" \
  "$_L710_DIR/one.jsonl" \
  "L7.10 transcript_path used when agent_transcript_path is absent"

rm -rf "$_L710_DIR" 2>/dev/null || true

finish_tests
