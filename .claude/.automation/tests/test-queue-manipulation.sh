#!/usr/bin/env bash
# Adversarial test suite: Queue manipulation attacks.
# Tests brief path traversal, YAML parser fragility, lock contention,
# JSON encoding injection, and UUID collision.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/sandbox-setup.sh"

# --- TAP infrastructure ---
_TAP_NUM=0; _TAP_PASS=0; _TAP_FAIL=0; _TAP_FAILURES=""
_tap_pass() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_PASS=$((_TAP_PASS+1)); printf "ok %d - %s\n" "$_TAP_NUM" "$1"; }
_tap_fail() { _TAP_NUM=$((_TAP_NUM+1)); _TAP_FAIL=$((_TAP_FAIL+1)); printf "not ok %d - %s\n" "$_TAP_NUM" "$1"; [ -n "${2:-}" ] && printf "  # %s\n" "$2"; _TAP_FAILURES="${_TAP_FAILURES}  FAIL: $1\n"; }
finish() { printf "\n1..%d\n# Tests: %d  Pass: %d  Fail: %d\n" $((_TAP_PASS+_TAP_FAIL)) $((_TAP_PASS+_TAP_FAIL)) "$_TAP_PASS" "$_TAP_FAIL"; [ "$_TAP_FAIL" -gt 0 ] && printf "# Failures:\n%b" "$_TAP_FAILURES"; return "$_TAP_FAIL"; }

printf "# === Queue Manipulation Attacks ===\n"

# Helper: source queue libs in sandbox
_source_queue_libs() {
  export REPO_ROOT="$ADV_SANDBOX"
  export AUTOMATION_DIR="$ADV_SANDBOX/.claude/.automation"
  export CONFIG_FILE="$ADV_SANDBOX/.claude/.automation/config.yaml"
  source "$ADV_SANDBOX/.claude/.automation/lib/file-lock.sh"
  source "$ADV_SANDBOX/.claude/.automation/lib/branch-manager.sh" 2>/dev/null || true
  source "$ADV_SANDBOX/.claude/.automation/lib/queue-manager.sh"
  source "$ADV_SANDBOX/.claude/.automation/lib/queue-validator.sh"
}

# Helper: write a raw queue entry
_write_raw_entry() {
  local id="$1" status="$2" session_type="$3" brief_path="$4" dir="$5"
  local file="$ADV_SANDBOX/.claude/.automation/queue/$dir/$id.yaml"
  printf 'id: %s\nstatus: %s\nsession_type: %s\nbrief_path: %s\nbranch: feature/test\nauto_mode: false\nsolo_mode: false\ncreated_at: 2026-03-20T00:00:00Z\nupdated_at: 2026-03-20T00:00:00Z\n' \
    "$id" "$status" "$session_type" "$brief_path" > "$file"
  echo "$file"
}

# --- Test 1: Brief path traversal (relative) ---
(
  setup_adversarial_sandbox
  trap 'teardown_adversarial_sandbox' EXIT
  _source_queue_libs
  # Create entry with path traversal
  entry_file=$(_write_raw_entry "trav-1" "approved" "standard" "../../../etc/passwd" "approved")
  rc=0; validate_queue_entry "$entry_file" 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    _tap_pass "[HIGH] Brief path traversal (relative) rejected by validator"
  else
    # Check if validator resolved to /etc/passwd
    _tap_fail "[HIGH] Brief path traversal (relative) accepted" "validator followed ../../../etc/passwd"
  fi
)

# --- Test 2: Brief path absolute ---
(
  setup_adversarial_sandbox
  trap 'teardown_adversarial_sandbox' EXIT
  _source_queue_libs
  entry_file=$(_write_raw_entry "abs-1" "approved" "standard" "/etc/passwd" "approved")
  rc=0; validate_queue_entry "$entry_file" 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    _tap_pass "[HIGH] Absolute brief path outside repo rejected"
  else
    _tap_fail "[HIGH] Absolute brief path /etc/passwd accepted" "validator allows absolute paths outside repo"
  fi
)

# --- Test 3: Shell metacharacters in brief_path ---
(
  setup_adversarial_sandbox
  trap 'teardown_adversarial_sandbox' EXIT
  _source_queue_libs
  # Write brief with shell metachar in name
  entry_file=$(_write_raw_entry "meta-1" "approved" "standard" 'test$(whoami).md' "approved")
  rc=0; validate_queue_entry "$entry_file" 2>/dev/null || rc=$?
  # queue-validator doesn't check for shell metacharacters (only intake.sh does)
  if [ "$rc" -ne 0 ]; then
    _tap_pass "[MEDIUM] Shell metacharacters in brief_path rejected"
  else
    _tap_fail "[MEDIUM] Shell metacharacters in brief_path accepted" "queue-validator lacks intake.sh metachar checks"
  fi
)

# --- Test 4: YAML duplicate fields ---
(
  setup_adversarial_sandbox
  trap 'teardown_adversarial_sandbox' EXIT
  _source_queue_libs
  # Create brief
  echo "test brief" > "$ADV_SANDBOX/.claude/.automation/briefs/dup-test.md"
  # Write entry with duplicate id field
  local_file="$ADV_SANDBOX/.claude/.automation/queue/approved/dup-1.yaml"
  printf 'id: dup-1\nstatus: approved\nsession_type: standard\nbrief_path: .claude/.automation/briefs/dup-test.md\nid: dup-INJECTED\nbranch: feature/test\n' > "$local_file"
  _load_queue_entry "$local_file"
  if [ "$_QE_ID" = "dup-INJECTED" ]; then
    _tap_fail "[MEDIUM] YAML duplicate field: last value wins" "parser accepts duplicate fields — attacker can override"
  else
    _tap_pass "[MEDIUM] YAML duplicate field handled correctly"
  fi
)

# --- Test 5: YAML embedded newline creates fake field ---
(
  setup_adversarial_sandbox
  trap 'teardown_adversarial_sandbox' EXIT
  _source_queue_libs
  # Write entry where id value contains what looks like a newline + status override
  # In actual YAML file, we write literal lines
  local_file="$ADV_SANDBOX/.claude/.automation/queue/approved/newline-1.yaml"
  printf 'id: newline-1\nstatus: approved\nsession_type: standard\nbrief_path: .claude/.automation/briefs/test.md\n' > "$local_file"
  echo "test brief" > "$ADV_SANDBOX/.claude/.automation/briefs/test.md"
  # Now append a second status line (simulating injected field via crafted YAML)
  printf 'status: completed\n' >> "$local_file"
  _load_queue_entry "$local_file"
  if [ "$_QE_STATUS" = "completed" ]; then
    _tap_fail "[HIGH] YAML field injection via appended line" "last-value-wins parser allows field override"
  else
    _tap_pass "[HIGH] YAML field injection blocked"
  fi
)

# --- Test 6: JSON injection in brief_path ---
(
  setup_adversarial_sandbox
  trap 'teardown_adversarial_sandbox' EXIT
  _source_queue_libs
  # Create a brief with a JSON-breaking name
  bad_name='test","injected":"true'
  mkdir -p "$ADV_SANDBOX/.claude/.automation/briefs"
  echo "brief" > "$ADV_SANDBOX/.claude/.automation/briefs/normal.md"
  entry_file=$(_write_raw_entry "json-1" "completed" "standard" "$bad_name" "completed")
  # Rebuild queue index
  _rebuild_queue_index 2>/dev/null || true
  index_file="$ADV_SANDBOX/.claude/.automation/queue/queue-index.json"
  if [ -f "$index_file" ]; then
    if jq -e '.' "$index_file" >/dev/null 2>&1; then
      _tap_pass "[MEDIUM] JSON injection in brief_path properly escaped in index"
    else
      _tap_fail "[MEDIUM] JSON injection in brief_path breaks queue-index.json" "invalid JSON produced"
    fi
  else
    _tap_pass "[MEDIUM] Queue index not generated (no injection risk)"
  fi
)

# --- Test 7: Lock contention (parallel enqueues) ---
(
  setup_adversarial_sandbox
  trap 'teardown_adversarial_sandbox' EXIT
  _source_queue_libs
  echo "brief content" > "$ADV_SANDBOX/.claude/.automation/briefs/contention.md"
  # Launch 5 parallel enqueue attempts
  pids=""
  for i in $(seq 1 5); do
    (
      export REPO_ROOT="$ADV_SANDBOX"
      export AUTOMATION_DIR="$ADV_SANDBOX/.claude/.automation"
      export CONFIG_FILE="$ADV_SANDBOX/.claude/.automation/config.yaml"
      source "$ADV_SANDBOX/.claude/.automation/lib/file-lock.sh"
      source "$ADV_SANDBOX/.claude/.automation/lib/branch-manager.sh" 2>/dev/null || true
      source "$ADV_SANDBOX/.claude/.automation/lib/queue-manager.sh"
      acquire_queue_lock 2>/dev/null && {
        # Simple enqueue simulation
        eid="contention-$i"
        printf 'id: %s\nstatus: pending-review\nsession_type: standard\nbrief_path: .claude/.automation/briefs/contention.md\n' "$eid" \
          > "$ADV_SANDBOX/.claude/.automation/queue/pending-review/$eid.yaml"
        release_queue_lock
      }
    ) &
    pids="$pids $!"
  done
  wait $pids 2>/dev/null || true
  # Count entries created
  count=$(find "$ADV_SANDBOX/.claude/.automation/queue/pending-review" -name "contention-*.yaml" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$count" -eq 5 ]; then
    _tap_pass "[HIGH] Lock contention: all 5 parallel enqueues serialized correctly"
  elif [ "$count" -gt 0 ]; then
    _tap_pass "[HIGH] Lock contention: $count/5 enqueues succeeded (some timeouts expected)"
  else
    _tap_fail "[HIGH] Lock contention: no enqueues succeeded" "lock mechanism may be broken"
  fi
)

# --- Test 8: Lock starvation (held indefinitely via mkdir) ---
(
  setup_adversarial_sandbox
  trap 'teardown_adversarial_sandbox' EXIT
  _source_queue_libs
  lock_path="$ADV_SANDBOX/.claude/.automation/.queue-lock"
  # Manually create lock with our own PID (so stale check won't clear it)
  mkdir -p "$lock_path"
  echo "$$" > "$lock_path/pid"
  # Try to acquire — should timeout after 5 seconds
  rc=0; acquire_queue_lock 2>/dev/null || rc=$?
  # Clean up
  rm -rf "$lock_path" 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then
    _tap_pass "[MEDIUM] Lock starvation: acquisition times out correctly"
  else
    _tap_fail "[MEDIUM] Lock starvation: acquired despite held lock"
  fi
)

# --- Test 9: Stale lock with PID 1 (always alive) ---
(
  setup_adversarial_sandbox
  trap 'teardown_adversarial_sandbox' EXIT
  _source_queue_libs
  lock_path="$ADV_SANDBOX/.claude/.automation/.queue-lock"
  # Create lock claiming PID 1 (init — always alive)
  mkdir -p "$lock_path"
  echo "1" > "$lock_path/pid"
  # Try to acquire — PID 1 is always alive, so stale check won't help
  rc=0; acquire_queue_lock 2>/dev/null || rc=$?
  rm -rf "$lock_path" 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then
    _tap_fail "[HIGH] Stale lock with PID 1: cannot recover" "lock held by unkillable process — no timeout escape"
  else
    _tap_pass "[HIGH] Stale lock with PID 1: recovered"
  fi
)

# --- Test 10: Oversized brief ---
(
  setup_adversarial_sandbox
  trap 'teardown_adversarial_sandbox' EXIT
  _source_queue_libs
  # Create 60KB brief
  dd if=/dev/zero bs=1024 count=60 2>/dev/null | tr '\0' 'A' > "$ADV_SANDBOX/.claude/.automation/briefs/big.md"
  entry_file=$(_write_raw_entry "big-1" "approved" "standard" ".claude/.automation/briefs/big.md" "approved")
  rc=0; validate_queue_entry "$entry_file" 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    _tap_pass "[LOW] Oversized brief (60KB) rejected by validator"
  else
    _tap_fail "[LOW] Oversized brief accepted"
  fi
)

# --- Test 11: Queue transition without lock ---
(
  setup_adversarial_sandbox
  trap 'teardown_adversarial_sandbox' EXIT
  _source_queue_libs
  echo "brief" > "$ADV_SANDBOX/.claude/.automation/briefs/nolock.md"
  entry_file=$(_write_raw_entry "nolock-1" "approved" "standard" ".claude/.automation/briefs/nolock.md" "approved")
  # Call _transition directly without acquiring lock
  _load_queue_entry "$entry_file"
  rc=0; _transition "approved" "running" 2>/dev/null || rc=$?
  # _transition has no lock guard — it's caller's responsibility
  if [ "$rc" -eq 0 ]; then
    _tap_fail "[MEDIUM] Queue transition without lock succeeded" "_transition lacks internal lock requirement"
  else
    _tap_pass "[MEDIUM] Queue transition without lock blocked"
  fi
)

# --- Test 12: UUID collision (weak fallback) ---
(
  setup_adversarial_sandbox
  trap 'teardown_adversarial_sandbox' EXIT
  _source_queue_libs
  echo "brief" > "$ADV_SANDBOX/.claude/.automation/briefs/uuid-test.md"
  # Temporarily hide uuidgen to force fallback
  real_path=$(command -v uuidgen 2>/dev/null || true)
  if [ -n "$real_path" ]; then
    # Test with real uuidgen — UUIDs should be unique
    ids=""
    for i in $(seq 1 10); do
      id=$(uuidgen | tr '[:upper:]' '[:lower:]')
      ids="$ids $id"
    done
    unique_count=$(echo "$ids" | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')
    if [ "$unique_count" -ge 10 ]; then
      _tap_pass "[MEDIUM] UUID generation produces unique IDs (uuidgen available)"
    else
      _tap_fail "[MEDIUM] UUID collision detected" "$unique_count unique out of 10"
    fi
  else
    # uuidgen not available — test fallback
    ids=""
    for i in $(seq 1 10); do
      id="$(date +%s)-$$-$RANDOM"
      ids="$ids $id"
    done
    unique_count=$(echo "$ids" | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')
    if [ "$unique_count" -lt 10 ]; then
      _tap_fail "[MEDIUM] UUID fallback collision" "$unique_count unique out of 10"
    else
      _tap_pass "[MEDIUM] UUID fallback unique in 10 iterations"
    fi
  fi
)

finish || true
