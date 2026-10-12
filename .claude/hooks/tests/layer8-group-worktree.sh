#!/usr/bin/env bash
# Layer 8 — Task group worktree lifetime tests (Decision 0054).
# Tests the helpers in _cleanup-helper.sh that let a sequential task group keep
# ONE worktree for the whole life of its branch: path/name sanitisation, the
# single-occupancy lock (acquire / re-entrant / blocked / stale-break / release
# by pid or session id), the clean-start check (tracked + untracked dirt blocks,
# gitignored files do not), worktree removal, and the stale sweep predicate.
#
# Uses real git worktrees inside the sandbox — the helpers are thin wrappers
# over git plumbing, so mocking git would test nothing.
#
# Reuses sandbox infrastructure from test-helpers.sh.
# Bash 3.2 compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/test-helpers.sh"

setup_sandbox

SB="$(get_sandbox)"

# _cleanup-helper.sh is not sourced by setup_sandbox (it is only needed by the
# close paths). Source it after the sandbox seam is set so _REPO_OS_ROOT and
# get_main_repo_root resolve to the sandbox.
# shellcheck disable=SC1091
source "$(cd "$SCRIPT_DIR/.." && pwd)/_cleanup-helper.sh"

# --- Sandbox git fixture: one commit on main plus a group branch ---
# setup_sandbox() git-inits but leaves the repo empty; worktrees need a commit.
git -C "$SB" config user.email "test@example.com" 2>/dev/null || true
git -C "$SB" config user.name "Test" 2>/dev/null || true
printf 'seed\n' > "$SB/seed.txt"
printf 'ignored-dir/\n' > "$SB/.gitignore"
git -C "$SB" add -A > /dev/null 2>&1 || true
git -C "$SB" commit -qm "seed" > /dev/null 2>&1 || true
# Normalise the initial branch name across git versions (init.defaultBranch).
_sb_head=$(git -C "$SB" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [ "$_sb_head" != "main" ]; then
  git -C "$SB" branch -m "$_sb_head" main > /dev/null 2>&1 || true
fi
git -C "$SB" branch "feature/tg-demo" main > /dev/null 2>&1 || true

# ============================================================
# L8.1 — group name sanitisation and path resolution
# ============================================================
tap_section "L8.1: group name sanitisation and path resolution"

assert_eq "$(_sanitize_group_name "eval-study-infra")" "eval-study-infra" \
  "_sanitize_group_name passes an already-safe name through"

assert_eq "$(_sanitize_group_name "my group/weird!!name")" "my-group-weird-name" \
  "_sanitize_group_name collapses unsafe chars and consecutive dashes"

assert_eq "$(_sanitize_group_name "--lead-and-trail--")" "lead-and-trail" \
  "_sanitize_group_name strips leading and trailing dashes"

assert_eq "$(_sanitize_group_name "!!!")" "" \
  "_sanitize_group_name returns empty when nothing survives"

# Slashes must NOT survive: a nested path would put the worktree one level
# deeper than every lookup expects.
case "$(_sanitize_group_name "a/b")" in
  */*) _tap_fail "_sanitize_group_name strips path separators" ;;
  *)   _tap_pass "_sanitize_group_name strips path separators" ;;
esac

assert_eq "$(group_worktree_path "demo")" "$SB/.worktrees/tg-demo" \
  "group_worktree_path resolves under the main repo's .worktrees/"

if group_worktree_path "" > /dev/null 2>&1; then
  _tap_fail "group_worktree_path fails on an empty group name"
else
  _tap_pass "group_worktree_path fails on an empty group name"
fi

# Distinct groups must never collide on one worktree.
if [ "$(group_worktree_path "alpha")" = "$(group_worktree_path "beta")" ]; then
  _tap_fail "group_worktree_path gives distinct groups distinct paths"
else
  _tap_pass "group_worktree_path gives distinct groups distinct paths"
fi

# ============================================================
# L8.2 — single-occupancy lock
# ============================================================
tap_section "L8.2: single-occupancy lock"

# A pid that is guaranteed not to be live, for the stale-break test. PID 1 is
# always alive, so use a high pid and verify it is dead before relying on it.
_DEAD_PID=999991
while kill -0 "$_DEAD_PID" 2>/dev/null; do
  _DEAD_PID=$((_DEAD_PID + 1))
done

if acquire_group_worktree_lock "demo" "$$" "sid-a"; then
  _tap_pass "acquire_group_worktree_lock acquires a free lock"
else
  _tap_fail "acquire_group_worktree_lock acquires a free lock"
fi

assert_file_exists "$(_group_worktree_lock_dir "demo")/pid" \
  "lock records the holder pid"

assert_eq "$(cat "$(_group_worktree_lock_dir "demo")/session_id")" "sid-a" \
  "lock records the holder session id"

if acquire_group_worktree_lock "demo" "$$" "sid-a"; then
  _tap_pass "acquire_group_worktree_lock is re-entrant for the same holder"
else
  _tap_fail "acquire_group_worktree_lock is re-entrant for the same holder"
fi

# Second session, live foreign holder ($$ is this test process) → blocked.
_rc=0
acquire_group_worktree_lock "demo" "$_DEAD_PID" "sid-b" || _rc=$?
assert_eq "$_rc" "1" "second session is blocked while a live holder owns the lock"

# A different group is unaffected by demo's lock.
if acquire_group_worktree_lock "other" "$$" "sid-a"; then
  _tap_pass "lock is per-group — a different group acquires independently"
else
  _tap_fail "lock is per-group — a different group acquires independently"
fi
release_group_worktree_lock "other" "$$" "sid-a" > /dev/null 2>&1 || true

# Release must refuse a stranger: neither pid nor session id matches.
_rc=0
release_group_worktree_lock "demo" "$_DEAD_PID" "sid-zzz" || _rc=$?
assert_eq "$_rc" "1" "release refuses a caller that holds neither pid nor session id"
assert_dir_exists "$(_group_worktree_lock_dir "demo")" \
  "refused release leaves the lock in place"

# Release by session id alone — the path hooks use (separate process, no pid).
if release_group_worktree_lock "demo" "" "sid-a"; then
  _tap_pass "release succeeds on a session-id match with no pid"
else
  _tap_fail "release succeeds on a session-id match with no pid"
fi

if [ -d "$(_group_worktree_lock_dir "demo")" ]; then
  _tap_fail "release removes the lock directory"
else
  _tap_pass "release removes the lock directory"
fi

# Releasing an absent lock is a no-op, not an error.
if release_group_worktree_lock "demo" "$$" "sid-a"; then
  _tap_pass "release of an absent lock is a no-op success"
else
  _tap_fail "release of an absent lock is a no-op success"
fi

# Stale lock: holder pid is dead → broken on sight so a crashed brief cannot
# wedge its group permanently.
mkdir -p "$(_group_worktree_lock_dir "demo")"
printf '%s\n' "$_DEAD_PID" > "$(_group_worktree_lock_dir "demo")/pid"
printf 'sid-crashed\n' > "$(_group_worktree_lock_dir "demo")/session_id"
if acquire_group_worktree_lock "demo" "$$" "sid-c" 2> /dev/null; then
  _tap_pass "acquire breaks a stale lock whose holder pid is dead"
else
  _tap_fail "acquire breaks a stale lock whose holder pid is dead"
fi
assert_eq "$(cat "$(_group_worktree_lock_dir "demo")/session_id")" "sid-c" \
  "stale-break re-records the new holder"
release_group_worktree_lock "demo" "$$" "sid-c" > /dev/null 2>&1 || true

# Unusable group name → rc 2, distinct from contention (rc 1).
_rc=0
acquire_group_worktree_lock "" "$$" "sid-a" || _rc=$?
assert_eq "$_rc" "2" "acquire returns 2 (not 1) for an unusable group name"

# --- orphaned-lock release (the close-hook net) ---
# A live holder must be left alone: the headless runner keeps the lock across
# its own post-session merge, and releasing it from inside the session would
# open the window that hold exists to close.
acquire_group_worktree_lock "demo" "$$" "sid-live" > /dev/null 2>&1 || true
_rc=0
release_group_worktree_lock_if_orphaned "demo" "sid-live" || _rc=$?
assert_eq "$_rc" "1" "orphaned-release leaves a lock whose holder is still live"
assert_dir_exists "$(_group_worktree_lock_dir "demo")" \
  "live holder's lock survives the orphaned-release net"
release_group_worktree_lock "demo" "$$" "sid-live" > /dev/null 2>&1 || true

# Dead holder, matching session → released.
mkdir -p "$(_group_worktree_lock_dir "demo")"
printf '%s\n' "$_DEAD_PID" > "$(_group_worktree_lock_dir "demo")/pid"
printf 'sid-ended\n' > "$(_group_worktree_lock_dir "demo")/session_id"
if release_group_worktree_lock_if_orphaned "demo" "sid-ended"; then
  _tap_pass "orphaned-release frees a lock whose holder process is gone"
else
  _tap_fail "orphaned-release frees a lock whose holder process is gone"
fi
if [ -d "$(_group_worktree_lock_dir "demo")" ]; then
  _tap_fail "orphaned-release removes the lock directory"
else
  _tap_pass "orphaned-release removes the lock directory"
fi

# Dead holder, DIFFERENT session → left alone (not ours to reclaim at close).
mkdir -p "$(_group_worktree_lock_dir "demo")"
printf '%s\n' "$_DEAD_PID" > "$(_group_worktree_lock_dir "demo")/pid"
printf 'sid-someone-else\n' > "$(_group_worktree_lock_dir "demo")/session_id"
_rc=0
release_group_worktree_lock_if_orphaned "demo" "sid-ours" || _rc=$?
assert_eq "$_rc" "1" "orphaned-release leaves a lock recorded against another session"
rm -rf "$(_group_worktree_lock_dir "demo")"

# Absent lock → no-op success.
if release_group_worktree_lock_if_orphaned "demo" "sid-ours"; then
  _tap_pass "orphaned-release of an absent lock is a no-op success"
else
  _tap_fail "orphaned-release of an absent lock is a no-op success"
fi

# --- release by owner pid (Decision 0054 Amendment: interactive sessions) ---
# An interactive session claims the lock under its own durable pid, which is
# still ALIVE at SessionEnd. Without the owner-pid condition the lock would
# outlive every interactive brief.
acquire_group_worktree_lock "demo" "$$" "sid-interactive" > /dev/null 2>&1 || true
if release_group_worktree_lock_if_orphaned "demo" "sid-interactive" "$$"; then
  _tap_pass "orphaned-release frees a live lock held by this session's own pid"
else
  _tap_fail "orphaned-release frees a live lock held by this session's own pid"
fi
if [ -d "$(_group_worktree_lock_dir "demo")" ]; then
  _tap_fail "owner-pid release removes the lock directory"
else
  _tap_pass "owner-pid release removes the lock directory"
fi

# A live holder that is NOT our pid must still be left alone, even when the
# session id matches — that is the headless case, where runner.sh holds the lock
# across its own post-session merge and releases it itself.
sleep 120 &
_RUNNER_STANDIN=$!
acquire_group_worktree_lock "demo" "$_RUNNER_STANDIN" "sid-headless" > /dev/null 2>&1 || true
_rc=0
release_group_worktree_lock_if_orphaned "demo" "sid-headless" "$$" || _rc=$?
assert_eq "$_rc" "1" "orphaned-release leaves a live runner-held lock alone despite a matching session id"
assert_dir_exists "$(_group_worktree_lock_dir "demo")" \
  "runner-held lock survives a close-time release attempt"
kill "$_RUNNER_STANDIN" 2>/dev/null || true
wait "$_RUNNER_STANDIN" 2>/dev/null || true
release_group_worktree_lock "demo" "$_RUNNER_STANDIN" "" > /dev/null 2>&1 || true

# ============================================================
# L8.3 — clean-start check
# ============================================================
tap_section "L8.3: clean-start check"

_WT="$(group_worktree_path "demo")"
git -C "$SB" worktree add "$_WT" "feature/tg-demo" > /dev/null 2>&1 || true

assert_dir_exists "$_WT" "git worktree add creates the group worktree"

if is_registered_worktree "$_WT"; then
  _tap_pass "is_registered_worktree recognises a real worktree"
else
  _tap_fail "is_registered_worktree recognises a real worktree"
fi

assert_eq "$(group_worktree_branch "$_WT")" "feature/tg-demo" \
  "group_worktree_branch reports the checked-out branch"

if check_group_worktree_clean "$_WT" "feature/tg-demo" > /dev/null; then
  _tap_pass "check_group_worktree_clean passes on a fresh worktree"
else
  _tap_fail "check_group_worktree_clean passes on a fresh worktree"
fi

# Gitignored files MUST NOT block — they are the whole reason the worktree is
# reused (dependency installs, build output, caches).
mkdir -p "$_WT/ignored-dir"
printf 'marker\n' > "$_WT/ignored-dir/.marker"
if check_group_worktree_clean "$_WT" "feature/tg-demo" > /dev/null; then
  _tap_pass "gitignored files do not fail the clean-start check"
else
  _tap_fail "gitignored files do not fail the clean-start check"
fi

# Untracked (non-ignored) file blocks.
printf 'dirt\n' > "$_WT/untracked.txt"
_rc=0
_reason=$(check_group_worktree_clean "$_WT" "feature/tg-demo") || _rc=$?
assert_eq "$_rc" "1" "an untracked file fails the clean-start check"
assert_contains "$_reason" "uncommitted changes" \
  "clean-start failure reason names the uncommitted changes"
assert_contains "$_reason" "untracked.txt" \
  "clean-start failure reason names the offending file"
rm -f "$_WT/untracked.txt"

# Modified tracked file blocks.
printf 'changed\n' >> "$_WT/seed.txt"
_rc=0
check_group_worktree_clean "$_WT" "feature/tg-demo" > /dev/null || _rc=$?
assert_eq "$_rc" "1" "a modified tracked file fails the clean-start check"
git -C "$_WT" checkout -- seed.txt > /dev/null 2>&1 || true

# The gitignored marker survived every check — this is verification item 2 of
# the brief, stated as its own assertion rather than inferred.
assert_file_exists "$_WT/ignored-dir/.marker" \
  "gitignored file persists across clean-start checks (brief-to-brief carry-over)"

# Advance the group branch so it is genuinely ahead of main, the normal state
# of a group branch part-way through its briefs. Without this, feature/tg-demo
# and main share a tip and the divergence check below cannot discriminate.
printf 'brief 1 work\n' >> "$_WT/seed.txt"
git -C "$_WT" add -A > /dev/null 2>&1 || true
git -C "$_WT" commit -qm "brief 1" > /dev/null 2>&1 || true

if check_group_worktree_clean "$_WT" "feature/tg-demo" > /dev/null; then
  _tap_pass "clean-start check passes again once brief 1's work is committed"
else
  _tap_fail "clean-start check passes again once brief 1's work is committed"
fi

# HEAD not at the expected branch tip blocks even when the tree is clean —
# the guard against a worktree parked on the wrong commit.
_rc=0
_reason=$(check_group_worktree_clean "$_WT" "main") || _rc=$?
assert_eq "$_rc" "1" "HEAD not matching the expected branch tip fails the check"
assert_contains "$_reason" "does not match tip" \
  "divergence failure reason is distinct from the dirty-tree reason"

# Missing directory is a failure, not a crash.
_rc=0
check_group_worktree_clean "$SB/.worktrees/tg-nonexistent" "main" > /dev/null || _rc=$?
assert_eq "$_rc" "1" "a missing worktree directory fails the clean-start check"

# ============================================================
# L8.2b — init-time lock claim (Decision 0054 Amendment)
# ============================================================
tap_section "L8.2b: init-time lock claim"

assert_eq "$(group_worktree_lock_holder_session "demo")" "" \
  "group_worktree_lock_holder_session is empty when no lock exists"

acquire_group_worktree_lock "demo" "$$" "sid-holder" > /dev/null 2>&1 || true
assert_eq "$(group_worktree_lock_holder_session "demo")" "sid-holder" \
  "group_worktree_lock_holder_session reports the recorded holder session"
release_group_worktree_lock "demo" "$$" "" > /dev/null 2>&1 || true

# The claim helper lives in _phase-helper.sh, which setup_sandbox already
# sourced. Not being inside a tg-* worktree is the overwhelmingly common case
# (every standalone session) and must be a silent no-op.
if _claim_group_worktree_lock_at_init "sid-any"; then
  _tap_pass "init claim is a no-op success outside a group worktree"
else
  _tap_fail "init claim is a no-op success outside a group worktree"
fi
if [ -d "$(_group_worktree_lock_dir "demo")" ]; then
  _tap_fail "init claim takes no lock outside a group worktree"
else
  _tap_pass "init claim takes no lock outside a group worktree"
fi

# Re-entrancy is keyed on SESSION ID, not pid. In a headless brief runner.sh
# has already claimed the lock for this same session under the RUNNER's pid —
# which is NOT the durable claude pid the claim helper would use. Keying on pid
# would make every headless group brief block itself on its own runner. This is
# the edge case the Pragmatist asked to pin down explicitly.
sleep 120 &
_RUNNER_PID=$!
acquire_group_worktree_lock "demo" "$_RUNNER_PID" "sid-shared" > /dev/null 2>&1 || true
assert_neq "$_RUNNER_PID" "$$" "the runner stand-in pid genuinely differs from this process"
_holder_before=$(cat "$(_group_worktree_lock_dir "demo")/pid")
if ( cd "$_WT" && _claim_group_worktree_lock_at_init "sid-shared" ) 2> /dev/null; then
  _tap_pass "init claim is re-entrant for a matching session id held under a DIFFERENT live pid"
else
  _tap_fail "init claim is re-entrant for a matching session id held under a DIFFERENT live pid" \
    "headless group briefs would block on their own runner"
fi
assert_eq "$(cat "$(_group_worktree_lock_dir "demo")/pid")" "$_holder_before" \
  "re-entrant claim does not steal the holder pid from the runner"

# A live foreign holder with a DIFFERENT session id blocks.
_rc=0
( cd "$_WT" && _claim_group_worktree_lock_at_init "sid-other" ) 2> /dev/null || _rc=$?
assert_eq "$_rc" "1" "init claim BLOCKS on a live foreign holder with a different session id"

# Override escape hatch.
_rc=0
( cd "$_WT" && REPO_OS_SKIP_GROUP_LOCK=1 _claim_group_worktree_lock_at_init "sid-other" ) 2> /dev/null || _rc=$?
assert_eq "$_rc" "0" "REPO_OS_SKIP_GROUP_LOCK=1 bypasses the init claim"

kill "$_RUNNER_PID" 2>/dev/null || true
wait "$_RUNNER_PID" 2>/dev/null || true
release_group_worktree_lock "demo" "$_RUNNER_PID" "" > /dev/null 2>&1 || true

# Inside a group worktree with no lock at all → claims it under our own pid.
if ( cd "$_WT" && _claim_group_worktree_lock_at_init "sid-fresh" ) 2> /dev/null; then
  _tap_pass "init claim acquires a free lock from inside a group worktree"
else
  _tap_fail "init claim acquires a free lock from inside a group worktree"
fi
assert_eq "$(group_worktree_lock_holder_session "demo")" "sid-fresh" \
  "init claim records the claiming session id"
release_group_worktree_lock "demo" "" "sid-fresh" > /dev/null 2>&1 || true

# ============================================================
# L8.4 — removal and lock release
# ============================================================
tap_section "L8.4: removal and lock release"

# A bare directory is not a worktree and must never be treated as one.
mkdir -p "$SB/.worktrees/tg-bare"
if is_registered_worktree "$SB/.worktrees/tg-bare"; then
  _tap_fail "is_registered_worktree rejects a bare directory"
else
  _tap_pass "is_registered_worktree rejects a bare directory"
fi
rm -rf "$SB/.worktrees/tg-bare"

acquire_group_worktree_lock "demo" "$$" "sid-final" > /dev/null 2>&1 || true

if remove_group_worktree "demo" "$$" "sid-final"; then
  _tap_pass "remove_group_worktree succeeds"
else
  _tap_fail "remove_group_worktree succeeds"
fi

if [ -d "$_WT" ]; then
  _tap_fail "remove_group_worktree removes the worktree directory"
else
  _tap_pass "remove_group_worktree removes the worktree directory"
fi

if git -C "$SB" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $_WT"; then
  _tap_fail "removed worktree no longer appears in git worktree list"
else
  _tap_pass "removed worktree no longer appears in git worktree list"
fi

if [ -d "$(_group_worktree_lock_dir "demo")" ]; then
  _tap_fail "remove_group_worktree releases the occupancy lock"
else
  _tap_pass "remove_group_worktree releases the occupancy lock"
fi

# Removing an absent worktree is a no-op success (idempotent terminal path).
if remove_group_worktree "demo" "$$" "sid-final"; then
  _tap_pass "remove_group_worktree is idempotent"
else
  _tap_fail "remove_group_worktree is idempotent"
fi

# Refuses to remove the tree the caller is standing in — that case is the
# sweep's job, not the caller's.
git -C "$SB" worktree add "$_WT" "feature/tg-demo" > /dev/null 2>&1 || true
_rc=0
( cd "$_WT" && remove_group_worktree "demo" "$$" "sid-final" ) 2> /dev/null || _rc=$?
assert_eq "$_rc" "1" "remove_group_worktree refuses when the caller is inside the worktree"
assert_dir_exists "$_WT" "refused removal leaves the worktree in place"

# ============================================================
# L8.5 — current_group_worktree_name
# ============================================================
tap_section "L8.5: current_group_worktree_name"

assert_eq "$( cd "$_WT" && current_group_worktree_name )" "demo" \
  "current_group_worktree_name derives the group from a tg- worktree root"

if ( cd "$SB" && current_group_worktree_name ) > /dev/null 2>&1; then
  _tap_fail "current_group_worktree_name fails outside a group worktree"
else
  _tap_pass "current_group_worktree_name fails outside a group worktree"
fi

# A per-session worktree (Decision 0033) must NOT be mistaken for a group one.
git -C "$SB" branch "feature/standalone" main > /dev/null 2>&1 || true
mkdir -p "$SB/.worktrees"
git -C "$SB" worktree add "$SB/.worktrees/daemon-20260101-000000-1234" \
  "feature/standalone" > /dev/null 2>&1 || true
if ( cd "$SB/.worktrees/daemon-20260101-000000-1234" && current_group_worktree_name ) > /dev/null 2>&1; then
  _tap_fail "current_group_worktree_name rejects a per-session worktree path"
else
  _tap_pass "current_group_worktree_name rejects a per-session worktree path"
fi

# ============================================================
# L8.6 — stale group worktree sweep
# ============================================================
tap_section "L8.6: stale group worktree sweep"

# The sweep lives in .automation/lib/cleanup.sh and needs REPO_ROOT plus the
# helpers already sourced above.
REPO_ROOT="$SB"
export REPO_ROOT
# shellcheck disable=SC1091
source "$(cd "$SCRIPT_DIR/../../.automation/lib" && pwd)/group-worktree-sweep.sh"

# Sealed branch → swept. The group worktree for demo is still checked out on
# feature/tg-demo; sealing that branch means the group is finished.
mkdir -p "$SB/.claude/local"
printf 'feature/tg-demo\n' > "$SB/.claude/local/closed-branches"
_swept=$(sweep_stale_group_worktrees)
assert_eq "$_swept" "1" "sweep removes a group worktree whose branch is sealed"
if [ -d "$_WT" ]; then
  _tap_fail "swept group worktree directory is gone"
else
  _tap_pass "swept group worktree directory is gone"
fi

# Per-session worktrees are never touched by the group sweep.
assert_dir_exists "$SB/.worktrees/daemon-20260101-000000-1234" \
  "sweep leaves per-session (non-tg-) worktrees alone"

# A live, unsealed group worktree is kept.
: > "$SB/.claude/local/closed-branches"
git -C "$SB" branch "feature/tg-active" main > /dev/null 2>&1 || true
_WT_ACTIVE="$(group_worktree_path "active")"
git -C "$SB" worktree add "$_WT_ACTIVE" "feature/tg-active" > /dev/null 2>&1 || true
_swept=$(sweep_stale_group_worktrees)
assert_eq "$_swept" "0" "sweep keeps a group worktree whose branch is live and unsealed"
assert_dir_exists "$_WT_ACTIVE" "live group worktree survives the sweep"

# A group worktree held by a live lock holder is kept even once sealed —
# the holder is mid-session and removing its tree would break it.
printf 'feature/tg-active\n' > "$SB/.claude/local/closed-branches"
acquire_group_worktree_lock "active" "$$" "sid-live" > /dev/null 2>&1 || true
_swept=$(sweep_stale_group_worktrees)
assert_eq "$_swept" "0" "sweep keeps a sealed group worktree while a live session holds its lock"
assert_dir_exists "$_WT_ACTIVE" "locked group worktree survives the sweep"
release_group_worktree_lock "active" "$$" "sid-live" > /dev/null 2>&1 || true

# Once the lock is released, the sealed worktree is swept.
_swept=$(sweep_stale_group_worktrees)
assert_eq "$_swept" "1" "sweep removes the sealed group worktree after its lock is released"

finish_tests
