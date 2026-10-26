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
test-work-preserver.sh
test-outcome-detector.sh
test-verify-pristine.sh
test-overlap-report.sh
test-reverify-merge.sh
test-operator-control.sh
test-operator-notes.sh
test-followups.sh
test-close-pipeline.sh
test-pr-manager.sh
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
  # Output is teed so the run still streams to the terminal AND can be checked
  # for the contradiction below. PIPESTATUS[0] is the suite's own status, not
  # tee's — `|| _rc=$?` on the pipeline would report tee under this file's
  # pipefail.
  #
  # errexit is suspended around the pipeline rather than absorbed with
  # `|| true`, and that detail is the whole correctness of this block. `|| true`
  # RUNS a command when the pipeline fails, and running any command resets
  # PIPESTATUS — so `${PIPESTATUS[0]}` read afterwards is `true`'s 0, never the
  # suite's. The first version of this change did exactly that, and the damage
  # was precisely: `_rc` was ALWAYS 0, so any suite exiting non-zero without a
  # `^not ok` line in its output was reported PASS — which is not only the
  # silent ones, but every suite that fails while printing a `Fail: N` summary
  # or a bare error message, including the six here that emit no TAP lines at
  # all. A suite exiting non-zero WITH a `not ok` line was reported
  # HARNESS "exited 0": still red, but with the wrong cause and an exit code
  # that never happened. A regression, in this very runner, of the same
  # blindness this check exists to remove. Nothing may execute between the
  # pipeline and the PIPESTATUS read.
  _out_file="$(mktemp "${TMPDIR:-/tmp}/auto-suite-XXXXXX")"
  set +e
  bash "$suite_path" 2>&1 | tee "$_out_file"
  _rc=${PIPESTATUS[0]}
  set -e
  printf "\n"

  # --- Harness integrity: a suite must not pass while printing a failure ---
  # This runner gates on exit code alone, which is why known-issue R38 stayed
  # invisible: test-eval-model-routing.sh re-tallied its subshell results through
  # a pipe, so the counters died, and it printed `not ok` and then reported
  # `Fail: 0` and exited 0. This runner duly called it PASS for as long as that
  # lasted. A suite's own report is not trusted over its own output.
  #
  # Deliberately NOT a `Fail:`-count comparison: six functional suites print TAP
  # lines with no reporter summary at all, so there is no count to compare. The
  # rule only needs the contradiction — exit 0 WITH a `not ok` line — and that
  # needs no agreement about output format.
  #
  # Measured before enabling: across all 16 suites, exactly one `^not ok` line
  # was emitted in a full run, and it was R38's. No suite trips this for a
  # legitimate reason today.
  _notok=0
  if [ -f "$_out_file" ]; then
    _notok=$(grep -c '^not ok' "$_out_file" 2>/dev/null || true)
  fi
  rm -f "$_out_file"

  if [ "$_rc" -eq 0 ] && [ "${_notok:-0}" -gt 0 ]; then
    printf "${RED}${BOLD}HARNESS: %s exited 0 while printing %d 'not ok' line(s) — its tally does not match its output.${RESET}\n" \
      "$suite" "$_notok"
    _results="${_results}HARNESS  ${suite} (exit 0 with ${_notok} 'not ok')
"
    _overall=1
  elif [ "$_rc" -eq 0 ]; then
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
