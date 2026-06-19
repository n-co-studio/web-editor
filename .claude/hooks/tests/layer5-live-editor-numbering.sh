#!/usr/bin/env bash
# Layer 5 — Editor-live durable monotonic counter (Decision 0023 Amendment 2).
#
# Covers next-live-editor-branch.sh numbering and the editor-live close-path
# branch deletion helper in _cleanup-helper.sh:
#   L5.1  Cold start: no HWM, no live refs -> live-editor-1, HWM written = 1.
#   L5.2  HWM floor: seed 25 -> live-editor-26.
#   L5.3  Reset-prevention: merge HWM to main, delete ALL live branches, rerun
#          -> next number does NOT reset to 1 (the bug this fix restores).
#   L5.4  Scan backstop: a higher live-editor-N ref than the HWM wins.
#   L5.5  Re-init guard: invoking while already on a live-editor-N branch returns
#          the same name and creates no new branch.
#   L5.6  Non-numeric HWM is treated as floor 0.
#   L5.7  delete_merged_editor_live_branch deletes a merged live-editor branch.
#   L5.8  delete_merged_editor_live_branch never touches feature/* branches.
#   L5.9  delete_merged_editor_live_branch is a safe no-op on an unmerged branch.
#   L5.10 No-duplicate: a second creation from main (first branch unmerged) sees
#          the live ref via the scan backstop and issues a distinct higher number.
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
tap_section "L5.7: delete_merged_editor_live_branch deletes merged live branch"
git -C "$SB2" checkout -q main
git -C "$SB2" branch live-editor-50 main >/dev/null 2>&1
git -C "$SB2" checkout -q live-editor-50
echo x > "$SB2/x.txt"; git -C "$SB2" add x.txt >/dev/null 2>&1; git -C "$SB2" commit -qm c >/dev/null 2>&1
git -C "$SB2" checkout -q main
git -C "$SB2" merge --no-ff -m m live-editor-50 >/dev/null 2>&1
delete_merged_editor_live_branch "live-editor-50" "$SB2"
if git -C "$SB2" show-ref --verify --quiet refs/heads/live-editor-50; then
  assert_eq "exists" "deleted" "merged live-editor-50 should be deleted"
else
  assert_eq "deleted" "deleted" "merged live-editor-50 deleted"
fi

# ============================================================
tap_section "L5.8: delete helper never touches feature/* branches"
git -C "$SB2" branch feature/keepme main >/dev/null 2>&1
git -C "$SB2" checkout -q feature/keepme
echo y > "$SB2/y.txt"; git -C "$SB2" add y.txt >/dev/null 2>&1; git -C "$SB2" commit -qm c2 >/dev/null 2>&1
git -C "$SB2" checkout -q main
git -C "$SB2" merge --no-ff -m m2 feature/keepme >/dev/null 2>&1
delete_merged_editor_live_branch "feature/keepme" "$SB2"
if git -C "$SB2" show-ref --verify --quiet refs/heads/feature/keepme; then
  assert_eq "preserved" "preserved" "feature/keepme preserved (not editor-live)"
else
  assert_eq "deleted" "preserved" "feature/keepme must NOT be deleted"
fi

# ============================================================
tap_section "L5.9: delete helper safe no-op on unmerged branch"
git -C "$SB2" branch live-editor-60 main >/dev/null 2>&1
git -C "$SB2" checkout -q live-editor-60
echo z > "$SB2/z.txt"; git -C "$SB2" add z.txt >/dev/null 2>&1; git -C "$SB2" commit -qm c3 >/dev/null 2>&1
git -C "$SB2" checkout -q main
delete_merged_editor_live_branch "live-editor-60" "$SB2"
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

finish_tests
