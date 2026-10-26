#!/usr/bin/env bash
# Phase Model Cohesion Tests — Main Runner
# Orchestrates Layer 1 (pure function) through Layer 8 (task group worktree
# lifetime) tests.
# Reports TAP output per layer with summary and phase matrix visualization.
#
# Usage: ./run-phase-tests.sh
# Exit:  0 if all tests pass, 1 if any fail.
#
# Bash 3.2 compatible. No external dependencies.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Colors (if terminal supports them) ---
if [ -t 1 ]; then
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  YELLOW='\033[0;33m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  DIM='\033[2m'
  RESET='\033[0m'
else
  GREEN=""
  RED=""
  YELLOW=""
  CYAN=""
  BOLD=""
  DIM=""
  RESET=""
fi

printf "${BOLD}Phase Model Cohesion Tests — L1 + L1b + L1c + L2 + L3${RESET}\n"
printf "==================================================\n\n"

# --- Self-test: verify assertion functions ---
printf "${CYAN}Self-test: verifying test infrastructure${RESET}\n"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/test-helpers.sh"
_self_test
printf "Self-test: ${GREEN}OK${RESET} (%d assertions verified)\n\n" "$_TAP_PASS"

# Reset counters (self-test uses the same globals)
_TAP_TEST_NUM=0
_TAP_PASS=0
_TAP_FAIL=0
_TAP_FAILURES=""

# --- Run Layer 1 ---
printf '%s\n' "${BOLD}Layer 1: Pure Function Tests${RESET}"
printf '%s\n' "----------------------------"

l1_exit=0
bash "$SCRIPT_DIR/layer1-phase-functions.sh" || l1_exit=$?

printf "\n"

# --- Run Layer 1b ---
printf '%s\n' "${BOLD}Layer 1b: Registry Function Tests${RESET}"
printf '%s\n' "-----------------------------------"

l1b_exit=0
bash "$SCRIPT_DIR/layer1b-registry-functions.sh" || l1b_exit=$?

printf "\n"

# --- Run Layer 1c ---
printf '%s\n' "${BOLD}Layer 1c: Worktree Function Tests${RESET}"
printf '%s\n' "-----------------------------------"

l1c_exit=0
bash "$SCRIPT_DIR/layer1c-worktree-functions.sh" || l1c_exit=$?

printf "\n"

# --- Run Layer 2 ---
printf '%s\n' "${BOLD}Layer 2: Lifecycle Walk Tests${RESET}"
printf '%s\n' "-----------------------------"

l2_exit=0
bash "$SCRIPT_DIR/layer2-phase-lifecycle.sh" || l2_exit=$?

printf "\n"

# --- Run Layer 3 ---
printf '%s\n' "${BOLD}Layer 3: Hook Integration Tests${RESET}"
printf '%s\n' "--------------------------------"

l3_exit=0
bash "$SCRIPT_DIR/layer3-hook-integration.sh" || l3_exit=$?

printf "\n"

# --- Run Layer 4 ---
printf '%s\n' "${BOLD}Layer 4: Session Identity + Bundle Carve-out Tests${RESET}"
printf '%s\n' "---------------------------------------------------"

l4_exit=0
bash "$SCRIPT_DIR/layer4-session-identity-bundle.sh" || l4_exit=$?

printf "\n"

# --- Run Layer 5 ---
printf '%s\n' "${BOLD}Layer 5: Editor-Live Durable Counter Tests${RESET}"
printf '%s\n' "------------------------------------------"

l5_exit=0
bash "$SCRIPT_DIR/layer5-live-editor-numbering.sh" || l5_exit=$?

printf "\n"
printf '%s\n' "${BOLD}Layer 6: Stop/SessionEnd Split Tests${RESET}"
printf '%s\n' "------------------------------------"

l6_exit=0
bash "$SCRIPT_DIR/layer6-stop-sessionend-split.sh" || l6_exit=$?

printf "\n"
printf '%s\n' "${BOLD}Layer 7: Per-Criterion Verdict Capture Tests${RESET}"
printf '%s\n' "-------------------------------------------"

l7_exit=0
bash "$SCRIPT_DIR/layer7-criteria-verdicts.sh" || l7_exit=$?

printf "\n"
printf '%s\n' "${BOLD}Layer 8: Task Group Worktree Lifetime Tests${RESET}"
printf '%s\n' "-------------------------------------------"

l8_exit=0
bash "$SCRIPT_DIR/layer8-group-worktree.sh" || l8_exit=$?

printf "\n"
printf '%s\n' "${BOLD}Layer 9: Mechanism-Change Classifier + Pristine Evidence${RESET}"
printf '%s\n' "--------------------------------------------------------"

l9_exit=0
bash "$SCRIPT_DIR/layer9-mechanism-change.sh" || l9_exit=$?

printf "\n"
printf '%s\n' "${BOLD}Standalone suites: KG gate/validator/tools, escalation root, finish-loop capture${RESET}"
printf '%s\n' "------------------------------------------------------------------------"

# Standalone suites rather than numbered layers: each builds its own /tmp repo.
kg_exit=0
for _kg_suite in test-kg-product-gate.sh test-kg-validate.sh test-kg-tools.sh \
                 test-escalation-root.sh test-finish-loop-capture.sh; do
  bash "$SCRIPT_DIR/$_kg_suite" || kg_exit=1
done

printf "\n"

# --- Phase matrix visualization ---
printf "${BOLD}Phase Matrix${RESET}\n"
printf "============\n\n"

# Source helpers again to get access to get_phases_for_type
# (re-source since layer tests ran in subshells)
# /tmp, not $TMPDIR: macOS TMPDIR is /var/folders/..., which the seam rejects
# and silently replaces with the real repo root (known-issue R41).
_SANDBOX_DIR_MATRIX=$(mktemp -d /tmp/phase-matrix.XXXXXX)
trap 'rm -rf "$_SANDBOX_DIR_MATRIX"' EXIT
mkdir -p "$_SANDBOX_DIR_MATRIX/.claude/.state"
mkdir -p "$_SANDBOX_DIR_MATRIX/.claude/hooks"
git init -q "$_SANDBOX_DIR_MATRIX" 2>/dev/null || true
echo "template" > "$_SANDBOX_DIR_MATRIX/.claude/repo-mode"
export REPO_OS_TEST_MODE=1
export _REPO_OS_TEST_ROOT="$_SANDBOX_DIR_MATRIX"

real_hooks_dir="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$real_hooks_dir/_analytics-helper.sh"
# shellcheck disable=SC1091
source "$real_hooks_dir/_phase-helper.sh"

SESSION_TYPES="standard taskgroup taskgroup-merge hotfix experiment editor-live spec-fresh spec-update prototype-napkin prototype-spike prototype-poc advisory-init advisory-reinit audit taskdef-query taskdef-brief queue-triage ephemeral"

# Collect all unique phases across all types
all_phases=""
for stype in $SESSION_TYPES; do
  phases=$(get_phases_for_type "$stype")
  for p in $phases; do
    # Bash 3.2 compatible: check if already in list
    case " $all_phases " in
      *" $p "*) ;;
      *) all_phases="$all_phases $p" ;;
    esac
  done
done
all_phases=$(echo "$all_phases" | sed 's/^ //')

# Print header row
printf "%-18s" "Type"
for p in $all_phases; do
  # Abbreviate long phase names to fit
  abbr="$p"
  if [ ${#abbr} -gt 6 ]; then
    abbr=$(echo "$p" | cut -c1-6)
  fi
  printf " %-6s" "$abbr"
done
printf "\n"

# Separator
printf "%-18s" "---"
for p in $all_phases; do
  printf " %-6s" "------"
done
printf "\n"

# Print each type's phases
for stype in $SESSION_TYPES; do
  phases=$(get_phases_for_type "$stype")
  printf "%-18s" "$stype"
  for p in $all_phases; do
    # Check if this type has this phase
    has_it=false
    for tp in $phases; do
      if [ "$tp" = "$p" ]; then
        has_it=true
        break
      fi
    done
    if [ "$has_it" = true ]; then
      tag=$(get_tag_for_phase "$stype" "$p")
      case "$tag" in
        agent)    printf " ${GREEN}%-6s${RESET}" "A" ;;
        operator) printf " ${YELLOW}%-6s${RESET}" "O" ;;
        both)     printf " ${CYAN}%-6s${RESET}" "B" ;;
      esac
    else
      printf " ${DIM}%-6s${RESET}" "."
    fi
  done
  printf "\n"
done

printf "\n${DIM}Legend: A=agent  O=operator  B=both  .=n/a${RESET}\n"

# --- Loop matrix ---
printf "\n${BOLD}Loop Matrix${RESET}\n"
printf "===========\n\n"
printf "%-18s %s\n" "Type" "Loops"
printf "%-18s %s\n" "---" "---"
for stype in $SESSION_TYPES; do
  loops=$(get_loops_for_type "$stype")
  if [ -n "$loops" ]; then
    printf "%-18s %s\n" "$stype" "$loops"
  else
    printf "%-18s ${DIM}(none)${RESET}\n" "$stype"
  fi
done

# --- Plan gate summary ---
printf "\n${BOLD}Plan Gate Summary${RESET}\n"
printf "=================\n\n"
printf "%-18s %-10s %s\n" "Type" "Gate?" "Post-Approval"
printf "%-18s %-10s %s\n" "---" "---" "---"
for stype in $SESSION_TYPES; do
  if has_plan_gate "$stype"; then
    post=$(get_post_approval_phase "$stype")
    printf "%-18s %-10s %s\n" "$stype" "yes" "$post"
  else
    printf "%-18s ${DIM}%-10s${RESET} ${DIM}%s${RESET}\n" "$stype" "no" "-"
  fi
done

# --- Final summary ---
printf "\n${BOLD}========================================${RESET}\n"
printf "${BOLD}Summary${RESET}\n"
printf "${BOLD}========================================${RESET}\n"

overall=0
if [ "$l1_exit" -eq 0 ]; then
  printf "Layer 1 (Pure Functions):    ${GREEN}PASS${RESET}\n"
else
  printf "Layer 1 (Pure Functions):    ${RED}FAIL${RESET}\n"
  overall=1
fi

if [ "$l1b_exit" -eq 0 ]; then
  printf "Layer 1b (Registry Functions): ${GREEN}PASS${RESET}\n"
else
  printf "Layer 1b (Registry Functions): ${RED}FAIL${RESET}\n"
  overall=1
fi

if [ "$l1c_exit" -eq 0 ]; then
  printf "Layer 1c (Worktree Functions): ${GREEN}PASS${RESET}\n"
else
  printf "Layer 1c (Worktree Functions): ${RED}FAIL${RESET}\n"
  overall=1
fi

if [ "$l2_exit" -eq 0 ]; then
  printf "Layer 2 (Lifecycle Walk):    ${GREEN}PASS${RESET}\n"
else
  printf "Layer 2 (Lifecycle Walk):    ${RED}FAIL${RESET}\n"
  overall=1
fi

if [ "$l3_exit" -eq 0 ]; then
  printf "Layer 3 (Hook Integration):  ${GREEN}PASS${RESET}\n"
else
  printf "Layer 3 (Hook Integration):  ${RED}FAIL${RESET}\n"
  overall=1
fi

if [ "$l4_exit" -eq 0 ]; then
  printf "Layer 4 (Identity + Bundle): ${GREEN}PASS${RESET}\n"
else
  printf "Layer 4 (Identity + Bundle): ${RED}FAIL${RESET}\n"
  overall=1
fi

if [ "$l5_exit" -eq 0 ]; then
  printf "Layer 5 (Editor-Live Counter): ${GREEN}PASS${RESET}\n"
else
  printf "Layer 5 (Editor-Live Counter): ${RED}FAIL${RESET}\n"
  overall=1
fi

if [ "$l6_exit" -eq 0 ]; then
  printf "Layer 6 (Stop/SessionEnd Split): ${GREEN}PASS${RESET}\n"
else
  printf "Layer 6 (Stop/SessionEnd Split): ${RED}FAIL${RESET}\n"
  overall=1
fi

if [ "$l7_exit" -eq 0 ]; then
  printf "Layer 7 (Criteria Verdict Capture): ${GREEN}PASS${RESET}\n"
else
  printf "Layer 7 (Criteria Verdict Capture): ${RED}FAIL${RESET}\n"
  overall=1
fi

if [ "$l8_exit" -eq 0 ]; then
  printf "Layer 8 (Group Worktree Lifetime): ${GREEN}PASS${RESET}\n"
else
  printf "Layer 8 (Group Worktree Lifetime): ${RED}FAIL${RESET}\n"
  overall=1
fi

if [ "$l9_exit" -eq 0 ]; then
  printf "Layer 9 (Mechanism Change): ${GREEN}PASS${RESET}\n"
else
  printf "Layer 9 (Mechanism Change): ${RED}FAIL${RESET}\n"
  overall=1
fi
if [ "$kg_exit" -eq 0 ]; then
  printf "Standalone suites:           ${GREEN}PASS${RESET}\n"
else
  printf "Standalone suites:           ${RED}FAIL${RESET}\n"
  overall=1
fi

printf "\n"
if [ "$overall" -eq 0 ]; then
  printf "${GREEN}${BOLD}All tests passed.${RESET}\n"
else
  printf "${RED}${BOLD}Some tests failed.${RESET}\n"
fi

exit "$overall"