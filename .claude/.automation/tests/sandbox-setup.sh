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
