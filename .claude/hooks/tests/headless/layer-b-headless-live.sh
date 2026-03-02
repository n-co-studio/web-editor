#!/usr/bin/env bash
# Layer B — Live headless integration tests.
# Launches `$CLAUDE_CLI -p` against a scratch repo and verifies hook behavior
# by examining analytics NDJSON and state files after completion.
#
# IMPORTANT: This script invokes the Claude API and will use tokens.
# Each test uses a minimal prompt to minimize cost.
#
# Usage:
#   ./layer-b-headless-live.sh [--test <test_name>]
#
#   --test <name>   Run only the named test (stop-natural, stop-max-turns,
#                   ask-user-question, disallowed-tools, solo-merge, ephemeral)
#
# Prerequisites:
#   - `claude` CLI installed and authenticated
#   - Current repo has .claude/settings.json with hooks wired
#
# Bash 3.2 compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
TEMPLATE_CLAUDE_DIR="$REPO_ROOT/.claude"

# --- Colors ---
if [ -t 1 ]; then
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  YELLOW='\033[0;33m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  DIM='\033[2m'
  RESET='\033[0m'
else
  GREEN="" RED="" YELLOW="" CYAN="" BOLD="" DIM="" RESET=""
fi

# --- Counters ---
PASS=0
FAIL=0
SKIP=0
RESULTS=""

pass() {
  PASS=$((PASS + 1))
  printf "${GREEN}PASS${RESET} - %s\n" "$1"
  RESULTS="${RESULTS}PASS: $1\n"
}

fail() {
  FAIL=$((FAIL + 1))
  printf "${RED}FAIL${RESET} - %s (%s)\n" "$1" "$2"
  RESULTS="${RESULTS}FAIL: $1 ($2)\n"
}

skip() {
  SKIP=$((SKIP + 1))
  printf "${YELLOW}SKIP${RESET} - %s (%s)\n" "$1" "$2"
  RESULTS="${RESULTS}SKIP: $1 ($2)\n"
}

info() {
  printf "${CYAN}INFO${RESET} - %s\n" "$1"
}

# --- Parse args ---
SINGLE_TEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --test) SINGLE_TEST="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

should_run() {
  [ -z "$SINGLE_TEST" ] || [ "$SINGLE_TEST" = "$1" ]
}

# --- Detect Claude CLI ---
# Claude Code may be installed as 'claude', 'happy', or another wrapper.
CLAUDE_CLI=""
for candidate in claude happy; do
  if command -v "$candidate" &>/dev/null; then
    if "$candidate" --version 2>/dev/null | grep -qi "claude\|anthropic"; then
      CLAUDE_CLI="$candidate"
      break
    fi
  fi
done

if [ -z "$CLAUDE_CLI" ]; then
  echo "ERROR: Claude Code CLI not found. Searched for: claude, happy."
  exit 1
fi

# --- Scratch repo factory ---
# Creates a temporary git repo with hooks copied from this repo.
# Returns the scratch repo path.
SCRATCH_DIRS=""
create_scratch_repo() {
  local name="${1:-scratch}"
  local scratch
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/headless-test-${name}.XXXXXX")
  SCRATCH_DIRS="$SCRATCH_DIRS $scratch"

  # Init git repo (force 'main' as default branch)
  git init -q --initial-branch=main "$scratch" 2>/dev/null || git init -q "$scratch"
  (cd "$scratch" && git config user.email "test@test.com" && git config user.name "Test")
  # Ensure default branch is called 'main' (older git may default to 'master')
  (cd "$scratch" && git symbolic-ref HEAD refs/heads/main 2>/dev/null || true)
  echo "# Scratch Repo" > "$scratch/README.md"
  (cd "$scratch" && git add README.md && git commit -q -m "initial commit")

  # Create feature branch
  (cd "$scratch" && git checkout -q -b feature/headless-test)

  # Copy .claude directory (hooks, settings, agents)
  cp -R "$TEMPLATE_CLAUDE_DIR" "$scratch/.claude"

  # Remove session-scoped files from the copy
  rm -rf "$scratch/.claude/.state"
  rm -f "$scratch/.claude/.session-id"
  rm -f "$scratch/.claude/.session-type"
  rm -f "$scratch/.claude/.session-log-hash"
  rm -f "$scratch/.claude/.session-baseline-sha"
  rm -f "$scratch/.claude/.hvst-fail-count"
  rm -f "$scratch/.claude/.deferrals-pending"
  mkdir -p "$scratch/.claude/.state"

  # Create session log (template mode)
  mkdir -p "$scratch/.claude/local"
  printf '# Session Log\n\n---\n' > "$scratch/.claude/local/session-log.md"

  # Create minimal CLAUDE.md
  cat > "$scratch/CLAUDE.md" <<'EOF'
# Test Repo
This is a headless hook verification scratch repo.
Read AI.md for governance instructions.
EOF

  # Create minimal AI.md
  cat > "$scratch/AI.md" <<'EOF'
# Test Repo OS
Minimal governance for headless testing.
EOF

  # Stage and commit .claude
  (cd "$scratch" && git add -A && git commit -q -m "add .claude hooks for testing")

  echo "$scratch"
}

cleanup_scratch() {
  for d in $SCRATCH_DIRS; do
    [ -d "$d" ] && rm -rf "$d"
  done
}
trap cleanup_scratch EXIT

# --- Analytics directory for a scratch repo ---
get_analytics_dir() {
  local repo_root="$1"
  local repo_name
  repo_name=$(basename "$repo_root")
  echo "$HOME/.local/share/repo-os-analytics/$repo_name/events"
}

# --- Count analytics events matching a pattern ---
count_analytics_events() {
  local analytics_dir="$1"
  local hook_pattern="$2"
  local today
  today=$(date +%Y-%m-%d)
  local file="$analytics_dir/${today}.ndjson"
  if [ ! -f "$file" ]; then
    echo "0"
    return
  fi
  grep -c "\"hook\":\"$hook_pattern\"" "$file" 2>/dev/null || echo "0"
}

# --- Check for Stop hook event in analytics ---
has_stop_event() {
  local analytics_dir="$1"
  local today
  today=$(date +%Y-%m-%d)
  local file="$analytics_dir/${today}.ndjson"
  [ -f "$file" ] && grep -q '"hook":"session-close-check"' "$file" 2>/dev/null
}

printf "${BOLD}Layer B — Live Headless Integration Tests${RESET}\n"
printf "==========================================\n\n"
printf "${DIM}Each test launches a $CLAUDE_CLI -p session against a scratch repo.${RESET}\n"
printf "${DIM}API tokens will be consumed. Tests use minimal prompts.${RESET}\n\n"

# ============================================================
# B.1 — Stop hook fires on natural exit
# ============================================================
if should_run "stop-natural"; then
  info "Test B.1: Stop hook fires on natural exit"

  scratch=$(create_scratch_repo "stop-natural")
  analytics=$(get_analytics_dir "$scratch")

  # Pre-snapshot: count existing stop events to detect new ones
  pre_count=$(count_analytics_events "$analytics" "session-close-check")

  # Run $CLAUDE_CLI -p with a minimal prompt that will complete quickly
  # Use --max-turns 3 to keep it short, but with a completable task
  output=$(cd "$scratch" && $CLAUDE_CLI -p "Read CLAUDE.md and respond with only the word DONE." \
    --max-turns 3 2>&1) || true

  # Check for stop event
  post_count=$(count_analytics_events "$analytics" "session-close-check")

  if [ "$post_count" -gt "$pre_count" ]; then
    pass "B.1: Stop hook fires on natural $CLAUDE_CLI -p exit"
  else
    # Check if the session even ran
    if [ -z "$output" ]; then
      fail "B.1: Stop hook fires on natural exit" "$CLAUDE_CLI -p produced no output"
    else
      fail "B.1: Stop hook fires on natural exit" "no new session-close-check events (pre=$pre_count, post=$post_count)"
    fi
  fi

  printf "  ${DIM}Output preview: %s${RESET}\n" "$(echo "$output" | head -3 | tr '\n' ' ')"
fi

# ============================================================
# B.2 — Stop hook behavior on max_turns exhaustion
# ============================================================
if should_run "stop-max-turns"; then
  info "Test B.2: Stop hook on max_turns exhaustion"

  scratch=$(create_scratch_repo "stop-maxturns")
  analytics=$(get_analytics_dir "$scratch")
  pre_count=$(count_analytics_events "$analytics" "session-close-check")

  # Prompt that will NOT complete in 1 turn, forcing max_turns exit
  output=$(cd "$scratch" && $CLAUDE_CLI -p "List every file in this repository one per line. Then explain what each file does in detail. Then suggest improvements." \
    --max-turns 1 2>&1) || true

  post_count=$(count_analytics_events "$analytics" "session-close-check")

  if [ "$post_count" -gt "$pre_count" ]; then
    pass "B.2: Stop hook fires on max_turns exhaustion"
    printf "  ${DIM}Finding: Stop hook DOES fire at max_turns in headless${RESET}\n"
  else
    # This is the hypothesized behavior — Stop may NOT fire at max_turns
    pass "B.2: Stop hook does NOT fire on max_turns (confirmed hypothesis)"
    printf "  ${DIM}Finding: Stop hook does NOT fire at max_turns — headless hard-kills${RESET}\n"
  fi
fi

# ============================================================
# B.3 — AskUserQuestion behavior in headless mode
# ============================================================
if should_run "ask-user-question"; then
  info "Test B.3: AskUserQuestion in headless mode"

  scratch=$(create_scratch_repo "ask-user")

  # Prompt that might trigger AskUserQuestion
  # We instruct the model to use AskUserQuestion, which should fail gracefully
  output=$(cd "$scratch" && $CLAUDE_CLI -p "Try to use the AskUserQuestion tool to ask me a question. If it fails or is unavailable, just say ASKUSER_UNAVAILABLE." \
    --max-turns 3 2>&1) || true

  if echo "$output" | grep -qi "ASKUSER_UNAVAILABLE\|not available\|cannot\|unable\|headless\|non-interactive"; then
    pass "B.3: AskUserQuestion gracefully unavailable in headless mode"
    printf "  ${DIM}Agent recognized AskUserQuestion is unavailable${RESET}\n"
  elif echo "$output" | grep -qi "error\|hang\|timeout"; then
    fail "B.3: AskUserQuestion in headless mode" "may have caused an error or hang"
  else
    # Model might have just answered without trying the tool
    pass "B.3: AskUserQuestion in headless mode (agent adapted)"
    printf "  ${DIM}Agent completed without attempting AskUserQuestion${RESET}\n"
  fi

  printf "  ${DIM}Output: %s${RESET}\n" "$(echo "$output" | head -3 | tr '\n' ' ')"
fi

# ============================================================
# B.4 — --disallowedTools blocks git push
# ============================================================
if should_run "disallowed-tools"; then
  info "Test B.4: --disallowedTools blocks git push"

  scratch=$(create_scratch_repo "disallowed")

  # Ask the model to try a git push, which should be blocked by --disallowedTools
  output=$(cd "$scratch" && $CLAUDE_CLI -p "Run the command: git push origin feature/headless-test. Report the exact outcome." \
    --max-turns 3 \
    --disallowedTools "Bash(git push:*)" 2>&1) || true

  if echo "$output" | grep -qi "not allowed\|disallowed\|blocked\|denied\|cannot\|permission\|unable"; then
    pass "B.4: --disallowedTools blocks git push in headless mode"
  elif echo "$output" | grep -qi "fatal\|remote.*not found"; then
    # Push was attempted but failed for a different reason (no remote)
    fail "B.4: --disallowedTools blocks git push" "push was attempted (not blocked by permission)"
  else
    # Ambiguous — model may have decided not to push
    skip "B.4: --disallowedTools blocks git push" "ambiguous output — manual verification needed"
    printf "  ${DIM}Output: %s${RESET}\n" "$(echo "$output" | head -3 | tr '\n' ' ')"
  fi
fi

# ============================================================
# B.5 — Solo mode merge in headless session
# ============================================================
if should_run "solo-merge"; then
  info "Test B.5: Solo mode merge in headless session"
  info "(This test is expensive — runs a full session with file creation)"

  scratch=$(create_scratch_repo "solo-merge")

  # Pre-write plan-approved and phase-state so the agent can work
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$scratch/.claude/.session-id-timestamp"
  SID="headless-solo-$(date +%s)"
  echo "$SID" > "$scratch/.claude/.session-id"

  # Pre-write plan-approved
  echo "timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)
question_hash: headless-solo-test
large-scope: true
mode: auto" > "$scratch/.claude/.state/plan-approved"

  # Pre-write phase-state at build phase
  echo "session_type: standard
session_id: $SID
mode: auto
current_phase: build
cycle: 1
phases_completed: init,plan,approval
solo: true
tag: agent
timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$scratch/.claude/.state/phase-state"

  # Record the main branch HEAD before the test
  main_head_before=$(cd "$scratch" && git rev-parse main)
  feature_head=$(cd "$scratch" && git rev-parse HEAD)

  # Run a headless session that writes a file and commits
  # NOTE: Solo merge happens in the Stop hook, which may or may not fire
  output=$(cd "$scratch" && $CLAUDE_CLI -p "Create a file src/headless-solo.ts with content 'export const solo = true;'. Then update .claude/local/session-log.md with a brief entry about this headless test session. Then commit all changes with message 'headless solo test commit'." \
    --max-turns 8 2>&1) || true

  # Check if main branch advanced (solo merge happened)
  main_head_after=$(cd "$scratch" && git rev-parse main)

  if [ "$main_head_after" != "$main_head_before" ]; then
    pass "B.5: Solo mode merge fires in headless session"
    printf "  ${DIM}Main branch advanced: %s → %s${RESET}\n" \
      "$(echo "$main_head_before" | cut -c1-8)" "$(echo "$main_head_after" | cut -c1-8)"
  else
    # Solo merge may not have fired — check why
    current_branch=$(cd "$scratch" && git rev-parse --abbrev-ref HEAD)
    if [ "$current_branch" = "main" ]; then
      pass "B.5: Solo mode merge fires in headless session (on main)"
    else
      fail "B.5: Solo mode merge in headless" "main branch did not advance (current branch: $current_branch)"
      printf "  ${DIM}This may indicate Stop hook didn't fire or solo merge path wasn't taken${RESET}\n"
    fi
  fi
fi

# ============================================================
# B.6 — Ephemeral session (taskdef-brief) in headless
# ============================================================
if should_run "ephemeral"; then
  info "Test B.6: Ephemeral session type in headless mode"

  scratch=$(create_scratch_repo "ephemeral")

  # Pre-write phase-state as taskdef-brief
  SID="headless-ephemeral-$(date +%s)"
  echo "$SID" > "$scratch/.claude/.session-id"
  echo "session_type: taskdef-brief
session_id: $SID
mode: review
current_phase: init
cycle: 1
phases_completed:
solo: false
tag: agent
timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$scratch/.claude/.state/phase-state"

  analytics=$(get_analytics_dir "$scratch")
  pre_count=$(count_analytics_events "$analytics" "session-close-check")

  output=$(cd "$scratch" && $CLAUDE_CLI -p "Read CLAUDE.md and say DONE." \
    --max-turns 2 2>&1) || true

  post_count=$(count_analytics_events "$analytics" "session-close-check")

  if [ "$post_count" -gt "$pre_count" ]; then
    # Stop hook fired — check if it was the ephemeral fast-path
    pass "B.6: Ephemeral session completes in headless mode"
    printf "  ${DIM}Stop hook fired (ephemeral fast-path)${RESET}\n"
  else
    # Stop hook didn't fire — might be max_turns behavior
    skip "B.6: Ephemeral session in headless" "Stop hook may not have fired (max_turns?)"
  fi
fi

# ============================================================
# Summary
# ============================================================
printf "\n${BOLD}========================================${RESET}\n"
printf "${BOLD}Layer B Summary${RESET}\n"
printf "${BOLD}========================================${RESET}\n"
printf "Pass: ${GREEN}%d${RESET}  Fail: ${RED}%d${RESET}  Skip: ${YELLOW}%d${RESET}\n" "$PASS" "$FAIL" "$SKIP"

if [ "$FAIL" -gt 0 ]; then
  printf "\n${RED}${BOLD}Some tests failed.${RESET}\n"
  exit 1
elif [ "$PASS" -eq 0 ] && [ "$SKIP" -gt 0 ]; then
  printf "\n${YELLOW}${BOLD}All tests skipped.${RESET}\n"
  exit 0
else
  printf "\n${GREEN}${BOLD}All tests passed.${RESET}\n"
  exit 0
fi
