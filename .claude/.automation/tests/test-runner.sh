#!/usr/bin/env bash
# Adversarial test runner — executes all attack suites and produces summary.
# Parses severity tags [CRITICAL], [HIGH], [MEDIUM], [LOW] from TAP output.
#
# Gating (Decision t-0061): exits non-zero on CRITICAL, HIGH, MEDIUM, or any
# failure whose severity cannot be determined. Only an explicitly [LOW]-tagged
# failure is advisory.
#
# Why an untagged failure gates: untagged failures used to fall to MEDIUM, and
# MEDIUM did not gate, so a failure the runner could not classify could not
# fail the run — fail-open on exactly the case it understands least. Measured,
# not theorised: the "SETUP: could not reach phase" failures that report an
# adversarial case never running are untagged, so forcing them produced
# 14 of them, printed "RESULT: 14 governance bypass(es) found", and exited 0.
#
# Usage: bash test-runner.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Suites to run ---
SUITES=(
  "test-phase-ordering.sh"
  "test-state-corruption.sh"
  "test-gate-bypass.sh"
  "test-queue-manipulation.sh"
  "test-escalation-suppression.sh"
)

# --- Counters ---
TOTAL_TESTS=0
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_CRITICAL=0
TOTAL_HIGH=0
TOTAL_MEDIUM=0
TOTAL_LOW=0

SUITE_RESULTS=""

# --- Run each suite ---
for suite in "${SUITES[@]}"; do
  suite_path="$SCRIPT_DIR/$suite"
  if [ ! -f "$suite_path" ]; then
    echo "WARNING: Suite not found: $suite" >&2
    continue
  fi

  echo "=== Running: $suite ==="
  suite_output=""
  suite_rc=0
  suite_output=$(bash "$suite_path" 2>&1) || suite_rc=$?

  # Parse TAP results
  s_pass=0
  s_fail=0
  s_critical=0
  s_high=0
  s_medium=0
  s_low=0

  while IFS= read -r line; do
    case "$line" in
      "ok "*)
        s_pass=$((s_pass + 1))
        ;;
      "not ok "*)
        s_fail=$((s_fail + 1))
        # Extract severity from description
        case "$line" in
          *"[CRITICAL]"*) s_critical=$((s_critical + 1)) ;;
          *"[HIGH]"*)     s_high=$((s_high + 1)) ;;
          *"[MEDIUM]"*)   s_medium=$((s_medium + 1)) ;;
          *"[LOW]"*)      s_low=$((s_low + 1)) ;;
          # Unclassifiable failure -> CRITICAL, not MEDIUM. Failing closed on
          # unknown severity (Decision t-0061). An untagged failure is the one
          # the runner understands least, so it must not be the one it ignores.
          *)              s_critical=$((s_critical + 1)) ;;
        esac
        ;;
    esac
  done <<< "$suite_output"

  s_total=$((s_pass + s_fail))

  # --- Harness integrity (R32) -------------------------------------------
  # `suite_rc` was captured above and never read. A suite that died under
  # `set -e` therefore contributed zero failures and passed silently: this is
  # how test-phase-ordering.sh ran 0 of 13 cases, and test-state-corruption.sh
  # 8 of 14, for an unknown length of time. Counting only emitted TAP lines
  # means "no output" is indistinguishable from "nothing wrong".
  #
  # A suite that reported every case AND exited non-zero is normal — that is
  # just a failing suite, already counted above. The two states worth
  # surfacing are a suite that produced no cases at all, and one that stopped
  # early (non-zero exit with no `not ok` to explain it).
  if [ "$s_total" -eq 0 ]; then
    echo "HARNESS ERROR: $suite emitted no TAP cases (exit $suite_rc) — it did not run" >&2
    s_fail=$((s_fail + 1))
    s_critical=$((s_critical + 1))
  elif [ "$suite_rc" -ne 0 ] && [ "$s_fail" -eq 0 ]; then
    echo "HARNESS ERROR: $suite exited $suite_rc with no reported failure — truncated before its last case" >&2
    s_fail=$((s_fail + 1))
    s_critical=$((s_critical + 1))
  fi
  s_total=$((s_pass + s_fail))

  # Print suite output
  echo "$suite_output"
  echo ""

  # Accumulate
  TOTAL_TESTS=$((TOTAL_TESTS + s_total))
  TOTAL_PASS=$((TOTAL_PASS + s_pass))
  TOTAL_FAIL=$((TOTAL_FAIL + s_fail))
  TOTAL_CRITICAL=$((TOTAL_CRITICAL + s_critical))
  TOTAL_HIGH=$((TOTAL_HIGH + s_high))
  TOTAL_MEDIUM=$((TOTAL_MEDIUM + s_medium))
  TOTAL_LOW=$((TOTAL_LOW + s_low))

  SUITE_RESULTS="${SUITE_RESULTS}$(printf '%-35s %4d  %4d  %4d  %4d  %4d  %4d' "$suite" "$s_total" "$s_pass" "$s_fail" "$s_critical" "$s_high" "$s_medium")\n"
done

# --- Summary ---
echo ""
echo "================================================================"
echo "        ADVERSARIAL TEST SUMMARY"
echo "================================================================"
printf "%-35s %4s  %4s  %4s  %4s  %4s  %4s\n" "Suite" "Tot" "Pass" "Fail" "Crit" "High" "Med"
echo "----------------------------------------------------------------"
printf '%b' "$SUITE_RESULTS"
echo "----------------------------------------------------------------"
printf "%-35s %4d  %4d  %4d  %4d  %4d  %4d\n" "TOTAL" "$TOTAL_TESTS" "$TOTAL_PASS" "$TOTAL_FAIL" "$TOTAL_CRITICAL" "$TOTAL_HIGH" "$TOTAL_MEDIUM"
echo "================================================================"
echo ""

if [ "$TOTAL_FAIL" -eq 0 ]; then
  echo "RESULT: ALL GOVERNANCE HELD — no bypasses found"
  exit 0
fi

echo "RESULT: $TOTAL_FAIL governance bypass(es) found"
echo "  CRITICAL: $TOTAL_CRITICAL  HIGH: $TOTAL_HIGH  MEDIUM: $TOTAL_MEDIUM  LOW: $TOTAL_LOW"

# Exit non-zero if critical or high severity bypasses
# Decision t-0061: MEDIUM gates too. Only an explicitly [LOW]-tagged failure
# is advisory. MEDIUM tags real correctness checks in these suites (queue lock
# starvation, transition without a lock, JSON injection into the queue index,
# YAML duplicate-field override), so treating them as non-blocking was never a
# considered policy — it was a side effect of the untagged default above.
if [ "$TOTAL_CRITICAL" -gt 0 ] || [ "$TOTAL_HIGH" -gt 0 ] || [ "$TOTAL_MEDIUM" -gt 0 ]; then
  exit 1
fi
exit 0
