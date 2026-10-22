#!/usr/bin/env bash
# Functional automation test runner — executes the non-adversarial automation
# suites and fails loudly if any of them fails.
#
# Usage: bash .claude/.automation/tests/run-automation-tests.sh
# Exit:  0 if every suite passes, 1 otherwise.
#
# Why this exists (known-issue R7): `test-runner.sh` is the ADVERSARIAL runner —
# it parses [CRITICAL]/[HIGH] severity tags and exits non-zero on governance
# bypasses. The functional suites carry no severity tags and their failures are
# plain regressions, not bypasses, so they never belonged in that runner and
# were therefore in no aggregate runner at all. Combined with a counter bug that
# made `test-branch-manager.sh` always exit 0, that suite sat fully red for
# months with nothing reporting it. One runner that simply fails on failure
# closes that hole.
#
# Companion to `.claude/hooks/tests/run-phase-tests.sh`, which plays the same
# role for the hook layers.
#
# Bash 3.2 compatible. No external dependencies.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Colors (if terminal supports them) ---
if [ -t 1 ]; then
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  GREEN=""
  RED=""
  BOLD=""
  RESET=""
fi

# --- Functional suites (NOT the adversarial ones — see header) ---
SUITES="
test-branch-manager.sh
test-group-worktree-lifecycle.sh
test-prompt-assembler.sh
test-daemon-liveness.sh
test-eval-model-routing.sh
test-queue-manipulation.sh
test-daemon-recovery-paths.sh
"
# Note: test-queue-manipulation.sh uses adversarial severity labels ([HIGH]/[MEDIUM]/[LOW])
# in its test names, but its cases gate on exit code — not on the tags. This runner only
# checks exit code, so it is the right home. test-runner.sh (the tag-parsing aggregate)
# would ignore these cases because they carry no [CRITICAL] prefix. (R22)

printf "${BOLD}Functional Automation Tests${RESET}\n"
printf "===========================\n\n"

_overall=0
_results=""

for suite in $SUITES; do
  suite_path="$SCRIPT_DIR/$suite"
  if [ ! -f "$suite_path" ]; then
    printf "${RED}MISSING${RESET}  %s\n" "$suite"
    _results="${_results}MISSING  ${suite}
"
    _overall=1
    continue
  fi

  printf "${BOLD}=== %s ===${RESET}\n" "$suite"
  _rc=0
  bash "$suite_path" || _rc=$?
  printf "\n"

  if [ "$_rc" -eq 0 ]; then
    _results="${_results}PASS     ${suite}
"
  else
    _results="${_results}FAIL     ${suite} (exit ${_rc})
"
    _overall=1
  fi
done

printf "${BOLD}========================================${RESET}\n"
printf "${BOLD}Summary${RESET}\n"
printf "${BOLD}========================================${RESET}\n"
printf '%s' "$_results"
printf "\n"

if [ "$_overall" -eq 0 ]; then
  printf "${GREEN}${BOLD}All functional automation suites passed.${RESET}\n"
else
  printf "${RED}${BOLD}Some functional automation suites failed.${RESET}\n"
fi

exit "$_overall"
