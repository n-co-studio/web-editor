#!/usr/bin/env bash
# Layer 1c — Worktree session isolation function tests (Decision 0030).
# Tests: get_session_state_dir, is_full_worktree_session, get_session_id
# env var override, register_session worktree_path, session-scoped phase
# init/advance cycle with REPO_OS_SESSION_ID.
#
# Reuses sandbox infrastructure from test-helpers.sh.
# Bash 3.2 compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/test-helpers.sh"

setup_sandbox

SB="$(get_sandbox)"

# ============================================================
# L1c.1 — get_session_id prefers REPO_OS_SESSION_ID env var
# ============================================================
tap_section "L1c.1: get_session_id env var override"

# Without env var, reads file
_CACHED_SESSION_ID=""
_file_sid=$(get_session_id "$SB")
assert_eq "$_file_sid" "$(cat "$SB/.claude/.session-id")" "get_session_id returns file-based ID when env var unset"

# With env var, uses env var
_CACHED_SESSION_ID=""
export REPO_OS_SESSION_ID="wt-test-session-42-$$"
_env_sid=$(get_session_id "$SB")
assert_eq "$_env_sid" "wt-test-session-42-$$" "get_session_id returns env var value when REPO_OS_SESSION_ID set"

# Cache cleared
_CACHED_SESSION_ID=""
unset REPO_OS_SESSION_ID

# ============================================================
# L1c.2 — is_full_worktree_session discrimination
# ============================================================
tap_section "L1c.2: is_full_worktree_session discrimination"

# Not a worktree + no env var → false
_CACHED_IS_WORKTREE=""
unset REPO_OS_SESSION_ID 2>/dev/null || true
if is_full_worktree_session; then
  _tap_fail "is_full_worktree_session false when not in worktree and no env var"
else
  _tap_pass "is_full_worktree_session false when not in worktree and no env var"
fi

# Env var set but not in worktree → false (is_worktree returns false)
_CACHED_IS_WORKTREE=""
export REPO_OS_SESSION_ID="wt-test-42-$$"
if is_full_worktree_session; then
  _tap_fail "is_full_worktree_session false when env var set but not in worktree"
else
  _tap_pass "is_full_worktree_session false when env var set but not in worktree"
fi
unset REPO_OS_SESSION_ID

# Signal 2: phase-state present + simulated worktree → true (EnterWorktree path)
# Simulate is_worktree()=true via cache, create phase-state in resolved state dir.
_CACHED_IS_WORKTREE="true"
_CACHED_SESSION_ID=""
_CACHED_SESSION_STATE_DIR=""
unset REPO_OS_SESSION_ID 2>/dev/null || true
_fws_sid=$(get_session_id "$SB")
_fws_state_dir=$(get_session_state_dir)
mkdir -p "$_fws_state_dir" 2>/dev/null || true
printf 'session_id: %s\nsession_type: standard\n' "$_fws_sid" > "$_fws_state_dir/phase-state"
_CACHED_SESSION_STATE_DIR=""
if is_full_worktree_session; then
  _tap_pass "is_full_worktree_session true when is_worktree and phase-state exists (EnterWorktree path)"
else
  _tap_fail "is_full_worktree_session true when is_worktree and phase-state exists (EnterWorktree path)"
fi
rm -f "$_fws_state_dir/phase-state"
_CACHED_IS_WORKTREE=""
_CACHED_SESSION_STATE_DIR=""

# Signal 2: is_worktree but no phase-state → false (subagent worktree path)
_CACHED_IS_WORKTREE="true"
_CACHED_SESSION_ID=""
_CACHED_SESSION_STATE_DIR=""
unset REPO_OS_SESSION_ID 2>/dev/null || true
# Ensure phase-state does not exist (cleaned above)
if is_full_worktree_session; then
  _tap_fail "is_full_worktree_session false when is_worktree but no phase-state (subagent path)"
else
  _tap_pass "is_full_worktree_session false when is_worktree but no phase-state (subagent path)"
fi
_CACHED_IS_WORKTREE=""
_CACHED_SESSION_STATE_DIR=""

# ============================================================
# L1c.3 — get_session_state_dir routing
# ============================================================
tap_section "L1c.3: get_session_state_dir routing"

# Without env var → per-session dir (all sessions route to wt-sessions/{sid}/)
_CACHED_SESSION_STATE_DIR=""
_CACHED_IS_WORKTREE=""
unset REPO_OS_SESSION_ID 2>/dev/null || true
_per_session_dir=$(get_session_state_dir)
_expected_sid=$(cat "$SB/.claude/.session-id" 2>/dev/null)
_expected_sid="${_expected_sid//\//_}"
_expected_sid="${_expected_sid//\.\./_}"
assert_eq "$_per_session_dir" "$SB/.claude/.state/wt-sessions/$_expected_sid" \
  "get_session_state_dir returns per-session path for interactive sessions"

# Backward compat: flat state with matching SID → returns flat path
_CACHED_SESSION_STATE_DIR=""
_compat_sid=$(cat "$SB/.claude/.session-id" 2>/dev/null)
printf 'session_id: %s\nsession_type: standard\n' "$_compat_sid" > "$SB/.claude/.state/phase-state"
# Ensure per-session dir does not exist so backward compat triggers
rmdir "$SB/.claude/.state/wt-sessions/$_expected_sid" 2>/dev/null || true
_compat_dir=$(get_session_state_dir)
assert_eq "$_compat_dir" "$SB/.claude/.state" \
  "get_session_state_dir returns flat path for pre-migration session (backward compat)"
# Clean up
rm -f "$SB/.claude/.state/phase-state"
_CACHED_SESSION_STATE_DIR=""

# ============================================================
# L1c.4 — Phase init/advance with env var session ID
# ============================================================
tap_section "L1c.4: Phase lifecycle with REPO_OS_SESSION_ID"

# Reset caches
_CACHED_SESSION_ID=""
_CACHED_SESSION_STATE_DIR=""
_PS_VALIDATED=false
_CACHED_CURRENT_SID=""

# Use env var for session identity (simulating non-worktree with env var for testing)
export REPO_OS_SESSION_ID="wt-lifecycle-test-$$"

# Write .session-id to match (init_phase reads it for the double-init guard)
echo "$REPO_OS_SESSION_ID" > "$SB/.claude/.session-id"

# Init should work with env var
init_phase "standard" 2>/dev/null
_init_phase=$(get_phase)
assert_eq "$_init_phase" "init" "init_phase sets phase to init with env var session ID"

# Advance through drift-check (Decision 0038) then to plan
advance_phase "drift-check" 2>/dev/null
advance_phase "plan" 2>/dev/null
_plan_phase=$(get_phase)
assert_eq "$_plan_phase" "plan" "advance_phase to plan works with env var session ID"

# Advance to approval (Decision 0025 substance gate: pragmatist-signed required)
printf 'GATE_RESULT: APPROVED\nsession_id: %s\n' "$REPO_OS_SESSION_ID" > "$(get_session_state_dir)/pragmatist-signed"
advance_phase "approval" 2>/dev/null
_approval_phase=$(get_phase)
assert_eq "$_approval_phase" "approval" "advance_phase to approval works with env var session ID"

# Check session type via get_session_type (uses env var for comparison)
_stype=$(get_session_type)
assert_eq "$_stype" "standard" "get_session_type returns correct type with env var session ID"

# Check solo mode
_solo=$(get_solo)
assert_eq "$_solo" "false" "get_solo returns false (default)"

# Set and check solo
set_solo "true" 2>/dev/null
_solo2=$(get_solo)
assert_eq "$_solo2" "true" "set_solo/get_solo roundtrip works with env var session ID"

# ============================================================
# L1c.5 — register_session without worktree_path (no worktree)
# ============================================================
tap_section "L1c.5: register_session without worktree"

_CACHED_SESSION_ID=""
_CACHED_IS_WORKTREE=""
_reg_sid="$REPO_OS_SESSION_ID"
# Session was already registered by init_phase. Check the file.
_reg_file="$SB/.claude/.state/sessions/${_reg_sid}.yaml"
if [ -f "$_reg_file" ]; then
  _tap_pass "session registry file exists"
else
  _tap_fail "session registry file exists" "file not found: $_reg_file"
fi

# Verify no worktree_path in registry (we're not in a worktree)
if grep -q "worktree_path:" "$_reg_file" 2>/dev/null; then
  _tap_fail "no worktree_path in registry when not in worktree"
else
  _tap_pass "no worktree_path in registry when not in worktree"
fi

# ============================================================
# L1c.6 — Backward compat: normal sessions unaffected
# ============================================================
tap_section "L1c.6: Backward compatibility"

# Clean up and init a new session without env var
unset REPO_OS_SESSION_ID
_CACHED_SESSION_ID=""
_CACHED_SESSION_STATE_DIR=""
_PS_VALIDATED=false
_CACHED_CURRENT_SID=""

# New session ID (reset cache and file)
echo "compat-test-$(date +%s)-$$" > "$SB/.claude/.session-id"
_CACHED_SESSION_ID=""
rm -f "$SB/.claude/.state/phase-state"

init_phase "hotfix" 2>/dev/null
_compat_phase=$(get_phase)
assert_eq "$_compat_phase" "init" "backward compat: init_phase works without env var"

_compat_stype=$(get_session_type)
assert_eq "$_compat_stype" "hotfix" "backward compat: get_session_type works without env var"

# State dir is per-session (all sessions route to wt-sessions/{sid}/)
_CACHED_SESSION_STATE_DIR=""
_compat_dir=$(get_session_state_dir)
_compat_expected_sid=$(cat "$SB/.claude/.session-id" 2>/dev/null)
_compat_expected_sid="${_compat_expected_sid//\//_}"
_compat_expected_sid="${_compat_expected_sid//\.\./_}"
assert_eq "$_compat_dir" "$SB/.claude/.state/wt-sessions/$_compat_expected_sid" \
  "interactive session: state dir is per-session without env var"

# ============================================================
# L1c.7 — A task group contract resolves from the MAIN repo inside a worktree
# ============================================================
# A contract belongs to the GROUP, not to one brief. Resolvers used to search
# only $REPO_ROOT, which inside a worktree session IS the worktree, so each
# brief read a private copy — and because `.claude/local/` is gitignored, a
# fresh worktree has none at all. On 2026-10-19 `git worktree remove` destroyed
# task-details-header's contract, A6.1 then found no `status: in_progress`
# anywhere, and every later brief was unable to commit even a record of being
# blocked. The resolvers now search the main repo root first, then the session
# root.
tap_section "L1c.7: contract resolves from the main repo inside a worktree"

_L1C7_MAIN="$SB"
_L1C7_WT="$SB/.worktrees/l1c7-probe"

mkdir -p "$_L1C7_MAIN/.claude/local/task-groups"
printf 'identity:\n  group_name: "l1c7-group"\n  execution: sequential\nbriefs:\n  - title: "only"\n    sequence: 1\n    status: in_progress\n' \
  > "$_L1C7_MAIN/.claude/local/task-groups/l1c7-group.yaml"

# setup_sandbox runs `git init` but makes NO commit, so `worktree add ... HEAD`
# has no commit to detach from. Without this the whole block skipped and the
# section passed while asserting nothing.
( cd "$_L1C7_MAIN" \
  && git config user.email "l1c7@test" \
  && git config user.name "L1c7 Test" \
  && printf 'probe\n' > .l1c7-seed \
  && git add .l1c7-seed \
  && git commit -q -m "l1c.7 seed" ) > /dev/null 2>&1 || true

if ( cd "$_L1C7_MAIN" && git worktree add --detach "$_L1C7_WT" HEAD > /dev/null 2>&1 ); then
  # Copy the libraries under test into the probe: a worktree is checked out at a
  # COMMIT, so it would otherwise hold the committed version of these files and
  # the test would silently exercise old code. This is the real repo's copy,
  # which is what we want to exercise.
  _L1C7_SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
  mkdir -p "$_L1C7_WT/.claude/.automation/lib" "$_L1C7_WT/.claude/hooks"
  cp "$_L1C7_SRC/../.automation/lib/cohesion-trigger.sh" "$_L1C7_WT/.claude/.automation/lib/" 2>/dev/null || true
  cp "$_L1C7_SRC/../.automation/lib/drift-detector.sh" "$_L1C7_WT/.claude/.automation/lib/" 2>/dev/null || true
  cp "$_L1C7_SRC/_analytics-helper.sh" "$_L1C7_WT/.claude/hooks/" 2>/dev/null || true

  assert_file_not_exists "$_L1C7_WT/.claude/local/task-groups/l1c7-group.yaml" \
    "L1c.7 the worktree has no contract of its own (.claude/local is gitignored)"

  _L1C7_OUT=$(
    cd "$_L1C7_WT" || exit 1
    export _REPO_OS_ROOT="$_L1C7_WT"
    export REPO_ROOT="$_L1C7_WT"
    _CACHED_MAIN_REPO_ROOT=""
    # shellcheck disable=SC1091
    source "$_L1C7_WT/.claude/hooks/_analytics-helper.sh" 2>/dev/null
    # shellcheck disable=SC1091
    source "$_L1C7_WT/.claude/.automation/lib/cohesion-trigger.sh" 2>/dev/null
    _resolve_contract_path "l1c7-group" 2>/dev/null
  )
  # Compared as real paths (known-issue R42): the resolver returns git's realpath
  # (/private/tmp/...) while $SB is logical (/tmp/... when TMPDIR is under /tmp,
  # as verify-pristine.sh sets it), so a plain string compare failed on the
  # symlink alone and read as fail-first evidence in every pristine run.
  _l1c7_real() { (cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")"); }
  assert_eq "$(_l1c7_real "$_L1C7_OUT")" "$(_l1c7_real "$_L1C7_MAIN/.claude/local/task-groups/l1c7-group.yaml")" \
    "L1c.7 resolver finds the MAIN repo contract from inside the worktree"

  # And it must still survive the removal that caused the original loss.
  ( cd "$_L1C7_MAIN" && git worktree remove --force "$_L1C7_WT" > /dev/null 2>&1 ) || true
  assert_file_exists "$_L1C7_MAIN/.claude/local/task-groups/l1c7-group.yaml" \
    "L1c.7 contract outlives the worktree it was read from"
else
  _tap_pass "L1c.7 skipped — git worktree add unavailable in sandbox"
fi

# ============================================================
# Finish
# ============================================================
finish_tests
