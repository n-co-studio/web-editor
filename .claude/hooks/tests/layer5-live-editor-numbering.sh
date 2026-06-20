#!/usr/bin/env bash
# Layer 5 — Editor-live durable monotonic counter (Decision 0023 Amendment 2)
#           and merged-branch cleanup (Decision 0045).
#
# Covers next-live-editor-branch.sh numbering and the session-branch deletion
# helper in _cleanup-helper.sh (delete_merged_session_branch):
#   L5.1  Cold start: no HWM, no live refs -> live-editor-1, HWM written = 1.
#   L5.2  HWM floor: seed 25 -> live-editor-26.
#   L5.3  Reset-prevention: merge HWM to main, delete ALL live branches, rerun
#          -> next number does NOT reset to 1 (the bug this fix restores).
#   L5.4  Scan backstop: a higher live-editor-N ref than the HWM wins.
#   L5.5  Re-init guard: invoking while already on a live-editor-N branch returns
#          the same name and creates no new branch.
#   L5.6  Non-numeric HWM is treated as floor 0.
#   L5.7  delete_merged_session_branch deletes a merged live-editor branch.
#   L5.8  delete_merged_session_branch deletes a merged feature/* branch (Decision 0045).
#   L5.9  delete_merged_session_branch is a safe no-op on an unmerged branch.
#   L5.10 No-duplicate: a second creation from main (first branch unmerged) sees
#          the live ref via the scan backstop and issues a distinct higher number.
#   L5.11 close fallback seals orphaned merged live-editor branch (no signal).
#   L5.12 delete_merged_session_branch deletes a merged fix/* branch.
#   L5.13 delete_merged_session_branch deletes a merged hotfix/* branch.
#   L5.14 delete_merged_session_branch deletes a merged experiment/* branch.
#   L5.15 delete_merged_session_branch never deletes an unmerged feature/* branch.
#
# Bash 3.2 compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/test-helpers.sh"
# shellcheck disable=SC1091
source "$HOOKS_DIR/_cleanup-helper.sh"

HELPER="$HOOKS_DIR/next-live-editor-branch.sh"

# --- Prepare a sandbox git repo on a 'main' branch with one commit ---
_prep_repo() {
  local sb="$1"
  git -C "$sb" config user.email t@t.co
  git -C "$sb" config user.name t
  ( cd "$sb" && git checkout -q -b main 2>/dev/null || git -C "$sb" checkout -q main )
  echo base > "$sb/seed.txt"
  git -C "$sb" add seed.txt >/dev/null 2>&1
  git -C "$sb" commit -qm "base" >/dev/null 2>&1
}

# Run the helper with cwd = sandbox; echoes the branch name it printed.
_run_helper() {
  local sb="$1"
  ( cd "$sb" && bash "$HELPER" 2>/dev/null )
}

# ============================================================
tap_section "L5.1: Cold start -> live-editor-1"
setup_sandbox
SB="$(get_sandbox)"
_prep_repo "$SB"
B=$(_run_helper "$SB")
assert_eq "$B" "live-editor-1" "cold start issues live-editor-1"
assert_eq "$(cat "$SB/.claude/live-editor-hwm" 2>/dev/null | tr -d '[:space:]')" "1" "HWM written to 1 on cold start"

# ============================================================
tap_section "L5.2: HWM floor -> max(HWM,scan)+1"
git -C "$SB" checkout -q main
printf '25\n' > "$SB/.claude/live-editor-hwm"
git -C "$SB" add .claude/live-editor-hwm >/dev/null 2>&1
git -C "$SB" commit -qm "seed hwm 25" >/dev/null 2>&1
B=$(_run_helper "$SB")
assert_eq "$B" "live-editor-26" "HWM=25 floor issues live-editor-26"
assert_eq "$(cat "$SB/.claude/live-editor-hwm" | tr -d '[:space:]')" "26" "HWM advanced to 26 on the new branch"

# ============================================================
tap_section "L5.3: Reset-prevention — merge to main, delete all, rerun"
# Merge the HWM commit (on live-editor-26) to main, then delete every live branch.
git -C "$SB" checkout -q main
git -C "$SB" merge --no-ff -m "Merge live-editor-26" live-editor-26 >/dev/null 2>&1
assert_eq "$(cat "$SB/.claude/live-editor-hwm" | tr -d '[:space:]')" "26" "HWM landed on main via merge"
# Delete EVERY live-editor branch (incl. live-editor-1 left over from L5.1)
for _lb in $(git -C "$SB" branch | tr -d ' *' | grep '^live-editor-'); do
  git -C "$SB" branch -D "$_lb" >/dev/null 2>&1 || true
done
LIVE_COUNT=$(git -C "$SB" branch | grep -c 'live-editor' || true)
assert_eq "$LIVE_COUNT" "0" "all live-editor branches deleted"
B=$(_run_helper "$SB")
assert_eq "$B" "live-editor-27" "counter does NOT reset after deleting all branches (27, not 1)"

# ============================================================
tap_section "L5.4: Scan backstop — higher live ref than HWM wins"
git -C "$SB" checkout -q main
git -C "$SB" branch live-editor-40 main >/dev/null 2>&1
B=$(_run_helper "$SB")
assert_eq "$B" "live-editor-41" "scan backstop: live-editor-40 ref -> 41"
assert_eq "$(cat "$SB/.claude/live-editor-hwm" | tr -d '[:space:]')" "41" "HWM advanced to 41 from scan"

# ============================================================
tap_section "L5.5: Re-init guard — already on a live-editor branch"
git -C "$SB" checkout -q live-editor-41
BEFORE=$(git -C "$SB" branch | grep -c 'live-editor' || true)
B=$(_run_helper "$SB")
AFTER=$(git -C "$SB" branch | grep -c 'live-editor' || true)
assert_eq "$B" "live-editor-41" "re-init guard returns current live-editor branch"
assert_eq "$BEFORE" "$AFTER" "re-init guard creates no new branch"

# ============================================================
tap_section "L5.6: Non-numeric HWM treated as floor 0"
setup_sandbox
SB2="$(get_sandbox)"
_prep_repo "$SB2"
printf 'garbage\n' > "$SB2/.claude/live-editor-hwm"
git -C "$SB2" add .claude/live-editor-hwm >/dev/null 2>&1
git -C "$SB2" commit -qm "garbage hwm" >/dev/null 2>&1
B=$(_run_helper "$SB2")
assert_eq "$B" "live-editor-1" "non-numeric HWM -> floor 0 -> live-editor-1 (no live refs)"

# ============================================================
tap_section "L5.7: delete_merged_session_branch deletes merged live-editor branch"
git -C "$SB2" checkout -q main
git -C "$SB2" branch live-editor-50 main >/dev/null 2>&1
git -C "$SB2" checkout -q live-editor-50
echo x > "$SB2/x.txt"; git -C "$SB2" add x.txt >/dev/null 2>&1; git -C "$SB2" commit -qm c >/dev/null 2>&1
git -C "$SB2" checkout -q main
git -C "$SB2" merge --no-ff -m m live-editor-50 >/dev/null 2>&1
delete_merged_session_branch "live-editor-50" "$SB2"
if git -C "$SB2" show-ref --verify --quiet refs/heads/live-editor-50; then
  assert_eq "exists" "deleted" "merged live-editor-50 should be deleted"
else
  assert_eq "deleted" "deleted" "merged live-editor-50 deleted"
fi

# ============================================================
tap_section "L5.8: delete_merged_session_branch deletes merged feature/* branch (Decision 0045)"
git -C "$SB2" branch feature/auto-testme main >/dev/null 2>&1
git -C "$SB2" checkout -q feature/auto-testme
echo y > "$SB2/y.txt"; git -C "$SB2" add y.txt >/dev/null 2>&1; git -C "$SB2" commit -qm c2 >/dev/null 2>&1
git -C "$SB2" checkout -q main
git -C "$SB2" merge --no-ff -m m2 feature/auto-testme >/dev/null 2>&1
delete_merged_session_branch "feature/auto-testme" "$SB2"
if git -C "$SB2" show-ref --verify --quiet refs/heads/feature/auto-testme; then
  assert_eq "exists" "deleted" "merged feature/auto-testme should be deleted"
else
  assert_eq "deleted" "deleted" "merged feature/auto-testme deleted"
fi

# ============================================================
tap_section "L5.9: delete_merged_session_branch safe no-op on unmerged live-editor branch"
git -C "$SB2" branch live-editor-60 main >/dev/null 2>&1
git -C "$SB2" checkout -q live-editor-60
echo z > "$SB2/z.txt"; git -C "$SB2" add z.txt >/dev/null 2>&1; git -C "$SB2" commit -qm c3 >/dev/null 2>&1
git -C "$SB2" checkout -q main
delete_merged_session_branch "live-editor-60" "$SB2"
if git -C "$SB2" show-ref --verify --quiet refs/heads/live-editor-60; then
  assert_eq "preserved" "preserved" "unmerged live-editor-60 preserved (git branch -d safe)"
else
  assert_eq "deleted" "preserved" "unmerged branch must NOT be force-deleted"
fi

# ============================================================
tap_section "L5.10: No-duplicate — second create sees live ref, issues distinct number"
setup_sandbox
SB3="$(get_sandbox)"
_prep_repo "$SB3"
printf '10\n' > "$SB3/.claude/live-editor-hwm"
git -C "$SB3" add .claude/live-editor-hwm >/dev/null 2>&1
git -C "$SB3" commit -qm "seed 10" >/dev/null 2>&1
B_a=$(_run_helper "$SB3")            # -> live-editor-11 (HWM commit on that branch)
git -C "$SB3" checkout -q main       # main HWM still 10; branch-11 unmerged
B_b=$(_run_helper "$SB3")            # scan sees live-editor-11 -> 12 (distinct, no dup)
assert_eq "$B_a" "live-editor-11" "first creation -> live-editor-11"
assert_eq "$B_b" "live-editor-12" "second creation issues distinct live-editor-12 (no duplicate)"
assert_neq "$B_a" "$B_b" "concurrent-style creations never collide on the same number"

# ============================================================
tap_section "L5.11: close fallback seals orphaned merged live-editor branch (no signal)"
setup_sandbox
SB4="$(get_sandbox)"
_prep_repo "$SB4"
git -C "$SB4" branch live-editor-70 main >/dev/null 2>&1
git -C "$SB4" checkout -q live-editor-70
echo a > "$SB4/a.txt"; git -C "$SB4" add a.txt >/dev/null 2>&1; git -C "$SB4" commit -qm c >/dev/null 2>&1
git -C "$SB4" checkout -q main
git -C "$SB4" merge --no-ff -m m live-editor-70 >/dev/null 2>&1
# Simulate a forgotten write_merge_signal: run the fallback directly (HEAD on main).
( cd "$SB4" && seal_orphaned_editor_live_branches )
if git -C "$SB4" show-ref --verify --quiet refs/heads/live-editor-70; then
  assert_eq "exists" "sealed+deleted" "fallback should delete orphaned merged live-editor-70"
else
  assert_eq "deleted" "deleted" "fallback deleted orphaned merged live-editor-70"
fi
assert_file_contains "$SB4/.claude/local/closed-branches" "live-editor-70" "fallback sealed live-editor-70 in ledger"

# Fallback is a no-op when HEAD is NOT on main (guards against acting mid-session).
git -C "$SB4" branch live-editor-71 main >/dev/null 2>&1
git -C "$SB4" checkout -q live-editor-71
( cd "$SB4" && seal_orphaned_editor_live_branches )
if git -C "$SB4" show-ref --verify --quiet refs/heads/live-editor-71; then
  assert_eq "preserved" "preserved" "fallback no-op when HEAD not on main"
else
  assert_eq "deleted" "preserved" "fallback must not act when HEAD is off main"
fi

# Fallback never touches a merged feature/* branch (editor-live-scoped scan).
git -C "$SB4" checkout -q main
git -C "$SB4" branch feature/keep main >/dev/null 2>&1
git -C "$SB4" checkout -q feature/keep
echo b > "$SB4/b.txt"; git -C "$SB4" add b.txt >/dev/null 2>&1; git -C "$SB4" commit -qm c2 >/dev/null 2>&1
git -C "$SB4" checkout -q main
git -C "$SB4" merge --no-ff -m m2 feature/keep >/dev/null 2>&1
( cd "$SB4" && seal_orphaned_editor_live_branches )
if git -C "$SB4" show-ref --verify --quiet refs/heads/feature/keep; then
  assert_eq "preserved" "preserved" "fallback never deletes a merged feature/* branch"
else
  assert_eq "deleted" "preserved" "fallback must not touch feature/* branches"
fi

# ============================================================
tap_section "L5.12: delete_merged_session_branch deletes merged fix/* branch"
setup_sandbox
SB5="$(get_sandbox)"
_prep_repo "$SB5"
git -C "$SB5" branch fix/auto-bug main >/dev/null 2>&1
git -C "$SB5" checkout -q fix/auto-bug
echo a > "$SB5/a.txt"; git -C "$SB5" add a.txt >/dev/null 2>&1; git -C "$SB5" commit -qm c >/dev/null 2>&1
git -C "$SB5" checkout -q main
git -C "$SB5" merge --no-ff -m m fix/auto-bug >/dev/null 2>&1
delete_merged_session_branch "fix/auto-bug" "$SB5"
if git -C "$SB5" show-ref --verify --quiet refs/heads/fix/auto-bug; then
  assert_eq "exists" "deleted" "merged fix/auto-bug should be deleted"
else
  assert_eq "deleted" "deleted" "merged fix/auto-bug deleted"
fi

# ============================================================
tap_section "L5.13: delete_merged_session_branch deletes merged hotfix/* branch"
git -C "$SB5" branch hotfix/auto-patch main >/dev/null 2>&1
git -C "$SB5" checkout -q hotfix/auto-patch
echo b > "$SB5/b.txt"; git -C "$SB5" add b.txt >/dev/null 2>&1; git -C "$SB5" commit -qm c2 >/dev/null 2>&1
git -C "$SB5" checkout -q main
git -C "$SB5" merge --no-ff -m m2 hotfix/auto-patch >/dev/null 2>&1
delete_merged_session_branch "hotfix/auto-patch" "$SB5"
if git -C "$SB5" show-ref --verify --quiet refs/heads/hotfix/auto-patch; then
  assert_eq "exists" "deleted" "merged hotfix/auto-patch should be deleted"
else
  assert_eq "deleted" "deleted" "merged hotfix/auto-patch deleted"
fi

# ============================================================
tap_section "L5.14: delete_merged_session_branch deletes merged experiment/* branch"
git -C "$SB5" branch experiment/auto-probe main >/dev/null 2>&1
git -C "$SB5" checkout -q experiment/auto-probe
echo c > "$SB5/c.txt"; git -C "$SB5" add c.txt >/dev/null 2>&1; git -C "$SB5" commit -qm c3 >/dev/null 2>&1
git -C "$SB5" checkout -q main
git -C "$SB5" merge --no-ff -m m3 experiment/auto-probe >/dev/null 2>&1
delete_merged_session_branch "experiment/auto-probe" "$SB5"
if git -C "$SB5" show-ref --verify --quiet refs/heads/experiment/auto-probe; then
  assert_eq "exists" "deleted" "merged experiment/auto-probe should be deleted"
else
  assert_eq "deleted" "deleted" "merged experiment/auto-probe deleted"
fi

# ============================================================
tap_section "L5.15: delete_merged_session_branch safe no-op on unmerged feature/* branch"
git -C "$SB5" branch feature/unmerged-keep main >/dev/null 2>&1
git -C "$SB5" checkout -q feature/unmerged-keep
echo d > "$SB5/d.txt"; git -C "$SB5" add d.txt >/dev/null 2>&1; git -C "$SB5" commit -qm c4 >/dev/null 2>&1
git -C "$SB5" checkout -q main
delete_merged_session_branch "feature/unmerged-keep" "$SB5"
if git -C "$SB5" show-ref --verify --quiet refs/heads/feature/unmerged-keep; then
  assert_eq "preserved" "preserved" "unmerged feature/unmerged-keep preserved (ancestor check safe)"
else
  assert_eq "deleted" "preserved" "unmerged feature/* must NOT be force-deleted"
fi

finish_tests
