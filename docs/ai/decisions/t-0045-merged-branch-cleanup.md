# Decision 0045 — Merged Branch Cleanup

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/hooks/_cleanup-helper\.sh`
- path: `\.claude/hooks/session-close-check\.sh`
- path: `\.claude/\.automation/runner\.sh`
- keywords: `delete_merged_session_branch, merged branch cleanup, branch deletion on close, branch accumulation`

## Decision

Make deleting the session's local branch ref a standard close-sequence step for all branch-creating session types (`feature/*`, `fix/*`, `hotfix/*`, `experiment/*`, `live-editor-[0-9]*`), using `git branch -d` (merged-only — never force) with a `merge-base --is-ancestor` precheck.

### Protocol

1. **Function**: `delete_merged_session_branch(branch, [repo_dir])` in `_cleanup-helper.sh`.
   - Prefix allowlist guard: skips silently for any branch not matching `feature/*|fix/*|hotfix/*|experiment/*|live-editor-[0-9]*`.
   - Ancestor precheck: `git merge-base --is-ancestor "$branch" main` — returns 0 early if not merged (never deletes unmerged branches).
   - Delete: `git branch -d "$branch"` (fail-silent via `|| true`). `-d` is the safe merged-only flag; `-D` (force) is NEVER used.
   - `repo_dir` argument: used when the caller operates on a main repo from a worktree context (`git -C "$repo_dir"`).

2. **Call sites** — all `confirmed-merge-success` locations:

   | Site | File | Trigger condition |
   |------|------|-------------------|
   | no-init agent-merge | `session-close-check.sh` ~725 | Agent merged before phase-state existed |
   | zero-change agent-merge | `session-close-check.sh` ~859 | Agent merged in a zero-change session |
   | main agent-merge detection | `session-close-check.sh` ~1165 | Agent wrote merge signal in close phase |
   | hook solo-merge success | `session-close-check.sh` ~1312 | Hook's own solo-merge block succeeded |
   | runner solo-merge success | `runner.sh` `_solo_merge_if_needed()` | Daemon path merge succeeded; gated by `_is_final_taskgroup_entry` |

3. **Ledger-permanence invariant**: `record_closed_branch()` is always called BEFORE `delete_merged_session_branch()`. The closed-branches ledger entry is permanent; the branch ref deletion is a GC step. Deleting the ref does not remove the ledger entry.

4. **Worktree ordering**: The worktree directory is removed before `_solo_merge_if_needed()` runs in the runner. `delete_merged_session_branch()` operates on the main repo (`"${_main_repo:-}"`) — never on the worktree — so the ordering is safe.

5. **Task group gating**: In the runner, the delete is gated by `_is_final_taskgroup_entry` (same gate as `record_closed_branch`) — non-final task group briefs do not delete the branch since it is still needed for subsequent briefs.

6. **Backward compat**: `delete_merged_editor_live_branch()` is retained as an alias for `delete_merged_session_branch()` so any external callers (test fixtures, documentation, live-editor close scripts) continue to work without change.

7. **One-time backlog sweep** (at decision acceptance): `git branch --merged main | grep -E '^(feature|fix|hotfix|experiment)/'` to identify and `git branch -d` the accumulated branches. Logged in the implementing session log.

## Context

Before this decision, `delete_merged_editor_live_branch()` (Decision 0023 Amendment 2) deleted merged `live-editor-N` branches on close. All other branch types (`feature/*`, `fix/*`, `hotfix/*`) were permanently retained as local refs even after merging to main. Over time (hundreds of daemon sessions producing `feature/auto-*` branches), hundreds of merged branches accumulated. The delete function was strictly scoped to `live-editor-N` names in the `case` guard, so extending it to all session branch types requires generalizing the guard and wiring the call at all confirmed-merge-success sites (including the runner daemon path, which the original editor-live implementation did not cover).

The merged-only (`-d`) + ancestor-precheck design ensures:
- Unmerged branches are NEVER deleted (safety contract preserved from Decision 0023 Amendment 2).
- A branch that somehow reaches the delete call without being merged to main is preserved, not lost.
- No change to `record_closed_branch()` contract — shared across all session types.

## Consequences

- `.claude/hooks/_cleanup-helper.sh`: `delete_merged_editor_live_branch()` replaced by `delete_merged_session_branch()` with expanded prefix allowlist and `merge-base --is-ancestor` precheck; backward-compat alias retained.
- `.claude/hooks/session-close-check.sh`: 4 sites updated — 2 renamed (agent-merge detection, solo-merge success), 2 new calls added (no-init path, zero-change path).
- `.claude/.automation/runner.sh`: `delete_merged_session_branch` added after `record_closed_branch` in `_solo_merge_if_needed()` `_merge_ok=true` block, gated by `_is_final_taskgroup_entry`.
- `.claude/.automation/RUNNER-PARITY.md`: Row 57 added documenting Stop-hook and runner parity for merged branch deletion.
- `docs/ai/decisions/t-manifest.txt`: `t-0045-merged-branch-cleanup.md` added.
- `.claude/hooks/tests/layer5-live-editor-numbering.sh`: `delete_merged_editor_live_branch` references renamed; new test cases added for `feature/*`, `fix/*`, `hotfix/*`, `experiment/*` merged-delete and unmerged-preserve paths.
