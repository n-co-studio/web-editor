#!/usr/bin/env bash
# Adversarial test sandbox — creates an isolated disposable environment.
# Copies actual hook and automation scripts (not symlinks) for full isolation.
# All paths are under /tmp/ to satisfy the test seam guard.
#
# Usage:
#   source sandbox-setup.sh
#   setup_adversarial_sandbox    # sets ADV_SANDBOX, exports test seam vars
#   # ... run tests ...
#   teardown_adversarial_sandbox

set -euo pipefail

# --- Locate the real repo ---
_ADV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ADV_REAL_REPO="$(cd "$_ADV_SCRIPT_DIR/../../.." && pwd)"

ADV_SANDBOX=""

setup_adversarial_sandbox() {
  # Force /tmp/ prefix — macOS TMPDIR resolves to /var/folders/ which
  # fails the test seam guard (/tmp/ or /private/tmp/ required).
  ADV_SANDBOX=$(mktemp -d "/tmp/repo-os-adv-XXXXXX")
  # Normalize (resolve symlinks — /tmp → /private/tmp on macOS)
  ADV_SANDBOX=$(cd "$ADV_SANDBOX" && pwd)

  # --- Scaffold directory tree ---
  mkdir -p "$ADV_SANDBOX/.claude/.state"
  mkdir -p "$ADV_SANDBOX/.claude/.state/sessions"
  mkdir -p "$ADV_SANDBOX/.claude/hooks"
  mkdir -p "$ADV_SANDBOX/.claude/.automation/lib"
  mkdir -p "$ADV_SANDBOX/.claude/.automation/schemas"
  mkdir -p "$ADV_SANDBOX/.claude/.automation/queue/pending-review"
  mkdir -p "$ADV_SANDBOX/.claude/.automation/queue/approved"
  mkdir -p "$ADV_SANDBOX/.claude/.automation/queue/running"
  mkdir -p "$ADV_SANDBOX/.claude/.automation/queue/completed"
  mkdir -p "$ADV_SANDBOX/.claude/.automation/queue/failed"
  mkdir -p "$ADV_SANDBOX/.claude/.automation/queue/review"
  mkdir -p "$ADV_SANDBOX/.claude/.automation/queue/blocked"
  mkdir -p "$ADV_SANDBOX/.claude/.automation/queue/work-orders"
  mkdir -p "$ADV_SANDBOX/.claude/.automation/escalations"
  mkdir -p "$ADV_SANDBOX/.claude/.automation/reports"
  mkdir -p "$ADV_SANDBOX/.claude/.automation/logs"
  mkdir -p "$ADV_SANDBOX/.claude/.automation/briefs"

  # --- Copy hook scripts ---
  local src_hooks="$_ADV_REAL_REPO/.claude/hooks"
  for f in "$src_hooks"/*.sh; do
    [ -f "$f" ] && cp "$f" "$ADV_SANDBOX/.claude/hooks/"
  done

  # --- Copy automation libs ---
  local src_lib="$_ADV_REAL_REPO/.claude/.automation/lib"
  for f in "$src_lib"/*.sh; do
    [ -f "$f" ] && cp "$f" "$ADV_SANDBOX/.claude/.automation/lib/"
  done

  # --- Copy schemas ---
  local src_schemas="$_ADV_REAL_REPO/.claude/.automation/schemas"
  for f in "$src_schemas"/*.yaml; do
    [ -f "$f" ] && cp "$f" "$ADV_SANDBOX/.claude/.automation/schemas/"
  done

  # --- Copy config ---
  cp "$_ADV_REAL_REPO/.claude/.automation/config.yaml" "$ADV_SANDBOX/.claude/.automation/"

  # --- Repo mode ---
  echo "template" > "$ADV_SANDBOX/.claude/repo-mode"

  # --- Git init with initial commit ---
  (
    cd "$ADV_SANDBOX"
    git init -q 2>/dev/null
    git config user.email "adversarial-test@test.com"
    git config user.name "Adversarial Test"
    echo "# Adversarial test sandbox" > README.md
    git add README.md
    git commit -q -m "initial commit" 2>/dev/null
    git checkout -q -b feature/test 2>/dev/null
  )

  # --- Session ID ---
  echo "adv-test-$(date +%s)-$$" > "$ADV_SANDBOX/.claude/.session-id"

  # --- Export test seam ---
  export REPO_OS_TEST_MODE=1
  export _REPO_OS_TEST_ROOT="$ADV_SANDBOX"

  # --- Source helpers from the SANDBOX copies ---
  # shellcheck disable=SC1091
  source "$ADV_SANDBOX/.claude/hooks/_analytics-helper.sh"
  # shellcheck disable=SC1091
  source "$ADV_SANDBOX/.claude/hooks/_phase-helper.sh"
}

teardown_adversarial_sandbox() {
  if [ -n "$ADV_SANDBOX" ] && [ -d "$ADV_SANDBOX" ]; then
    # Safety: only delete under /tmp/ or /private/tmp/
    case "$ADV_SANDBOX" in
      /tmp/*|/private/tmp/*) rm -rf "$ADV_SANDBOX" ;;
      *) echo "WARNING: Refusing to delete non-tmp sandbox: $ADV_SANDBOX" >&2 ;;
    esac
  fi
  ADV_SANDBOX=""
  unset REPO_OS_TEST_MODE _REPO_OS_TEST_ROOT 2>/dev/null || true
}

# Run hook in sandbox, capturing exit code
# Usage: output=$(run_adv_hook "pre-commit-gates.sh" "$json_input"); echo "$ADV_LAST_RC"
ADV_LAST_RC=0
run_adv_hook() {
  local hook="$1"
  local input="${2:-\{\}}"
  ADV_LAST_RC=0
  (cd "$ADV_SANDBOX" && printf '%s' "$input" | bash "$ADV_SANDBOX/.claude/hooks/$hook" 2>&1) || ADV_LAST_RC=$?
}

# --- Reaching a phase legitimately (R32) ------------------------------------
# Adversarial cases must START from a properly-governed state, or a block
# cannot be attributed to the thing under test.
#
# What this replaces: cases wrote `init_phase X; advance_phase "plan" && ...`.
# Two problems. `drift-check` sits between init and plan and is not skippable
# (Decision 0038), so the walk fails; and because the failure happens in the
# left operand of an `&&` list, `set -e` does NOT fire — so it failed SILENTLY
# and the case ran its attack from `init` instead of the phase it meant. That
# is why suites could report a wall of passes while testing almost nothing.
# `advance_phase` also enforces substance gates (approval needs a
# pragmatist-signed verdict, Decision 0025), so a correct walk still needs the
# verdict files a governed session would have.
#
# _reach seeds ONLY what the SETUP transitions require, never what the attack
# targets: seeding stops at the target phase, so an attacked transition's own
# substance file is absent and cannot make the attack pass for the wrong
# reason. Every attack must still call bare `advance_phase`.
_adv_seed_verdict() {
  # $1 file, $2 agent, $3 dispatch_phase
  local sd sid
  sd=$(get_session_state_dir) || return 1
  sid=$(cat "$ADV_SANDBOX/.claude/.session-id") || return 1
  printf 'timestamp: test\nagent: %s\nsession_id: %s\ndispatch_phase: %s\nGATE_RESULT: APPROVED\n' \
    "$2" "$sid" "$3" > "$sd/$1"
}

_REACH_FAILED_AT=""
_REACH_ERR=""
_reach() {
  local target="$1"
  local sd sid phases p
  _REACH_FAILED_AT=""; _REACH_ERR=""
  sd=$(get_session_state_dir) || return 1
  sid=$(cat "$ADV_SANDBOX/.claude/.session-id") || return 1
  phases=$(get_phases_for_type "$(get_session_type)") || return 1
  for p in $phases; do
    [ "$p" = "init" ] && continue
    case "$p" in
      approval)
        _adv_seed_verdict pragmatist-signed pragmatist plan || return 1
        printf 'timestamp: test\nsession_id: %s\nmode: auto\nlarge-scope: true\n' "$sid" \
          > "$sd/plan-approved"
        ;;
      verify)
        # Critic combined mode writes both; A5 requires both (Decision 0039).
        _adv_seed_verdict cohesion-reviewed critic review || return 1
        _adv_seed_verdict diff-review-complete critic review || return 1
        ;;
      commit)
        _adv_seed_verdict qa-verified qa-verifier verify || return 1
        ;;
    esac
    _REACH_ERR=$(advance_phase "$p" 2>&1) || { _REACH_FAILED_AT="$p"; return 1; }
    [ "$p" = "$target" ] && return 0
  done
  _REACH_FAILED_AT="(target '$target' not in sequence)"
  return 1
}

# init + walk to $2 (default "plan") for session type $1 (default "standard").
# Records a visible failing case when the phase cannot be reached: a case that
# never ran must not look like a case that passed.
_setup_at() {
  local stype="standard" target
  if [ $# -ge 2 ]; then stype="$1"; target="$2"; else target="$1"; fi
  init_phase "$stype" >/dev/null 2>&1 || true
  if ! _reach "$target"; then
    _tap_fail "SETUP: could not reach phase '$target'" \
      "precondition unmet at '${_REACH_FAILED_AT}' — case NOT exercised: $(printf '%s' "${_REACH_ERR}" | head -1 | cut -c1-140)"
    return 1
  fi
  return 0
}
