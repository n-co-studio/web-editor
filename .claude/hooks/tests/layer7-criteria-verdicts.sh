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

finish_tests
