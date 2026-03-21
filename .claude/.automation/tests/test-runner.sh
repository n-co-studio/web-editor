#!/usr/bin/env bash
# Adversarial test runner — executes all attack suites and produces summary.
# Parses severity tags [CRITICAL], [HIGH], [MEDIUM], [LOW] from TAP output.
# Exits non-zero if any CRITICAL or HIGH governance bypasses found.
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
          *)              s_medium=$((s_medium + 1)) ;; # default to medium
        esac
        ;;
    esac
  done <<< "$suite_output"

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
if [ "$TOTAL_CRITICAL" -gt 0 ] || [ "$TOTAL_HIGH" -gt 0 ]; then
  exit 1
fi
exit 0
