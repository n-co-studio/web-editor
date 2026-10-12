# Decision 0033 — Session Worktree Default

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/(\.automation/runner|hooks/(session-close-check|_phase-helper|_cleanup-helper|_analytics-helper))\.sh`
- keywords: `worktree, REPO_OS_WORKTREE_ISOLATE, --worktree, session isolation, concurrent session, .worktrees`

## Decision
Make worktree isolation the default for all sessions — interactive, headless, and daemon-spawned. Every session runs in its own git worktree, eliminating branch conflicts, working tree collisions, and state file interference when multiple sessions run concurrently on the same repo.

### Background
Decision 0030 built per-session state directories (`wt-sessions/{sid}/`) and worktree-aware merge coordination. Decision 0032 required parallel task group briefs to use worktrees. This decision extends the worktree default to ALL session types, making the concurrent isolation model universal rather than special-cased.

### Implementation

1. **Runner worktree flag**: `runner.sh` passes `--worktree` to every `claude -p` invocation. The `--worktree` flag is a Claude Code feature that creates a temporary worktree, runs the session in it, and cleans up on exit. Combined with the existing `REPO_OS_SESSION_ID` export, this gives each daemon session full worktree isolation with per-session governance state.

2. **Interactive sessions**: Operators launch `claude --worktree` for interactive sessions. VS Code extension users get this behavior from Claude Code's native worktree support. The main worktree stays on `main` — no more branch switching in the primary working tree.

3. **Worktree directory**: `.worktrees/` added to `.gitignore` for any local worktree storage. Claude Code's `--worktree` flag manages its own worktree paths, but operators using manual `git worktree add` should use this directory.

4. **Opt-out**: `REPO_OS_WORKTREE_ISOLATE=0` environment variable disables the `--worktree` flag in `runner.sh` for debugging or constrained environments. Interactive sessions can simply omit `--worktree`.

5. **State isolation**: Already handled by Decision 0030 infrastructure — `get_session_state_dir()` routes all state reads/writes to per-session directories under `wt-sessions/{sid}/`.

6. **Merge coordination**: Already handled by Decision 0030 — `flock`/`mkdir` serialization on `.merge-lock` for concurrent solo merges.

7. **Mode guard carve-out**: `.gitignore` added to `is_governance()` in `_mode-guard-helper.sh` and carved out in template mode, since it is template-managed (REPO-OS MANAGED markers).

8. **Headless plan approval helper**: `_headless-plan-approve.sh` provides shell I/O plan-approved state file writing for headless sessions where AskUserQuestion is blocked. Uses the established pattern (Decision 0014 §9) of shell I/O bypassing tool-level hooks.

### What This Does NOT Change
- Decision 0028 (subagent worktree state block) remains in effect
- Decision 0030 (per-session state directories) used as-is
- Decision 0032 (parallel task group worktree isolation) unchanged
- Sequential task groups: unaffected (shared branch, worktree isolation is per-session) — **amended by Decision 0054; see § Amendment 2026-10-06 below**
- All governance gates: unchanged (hooks fire in worktree context via absolute path registration)

## Consequences
- `.claude/.automation/runner.sh`: `claude -p` invocations gain `--worktree` flag (conditional on `REPO_OS_WORKTREE_ISOLATE`)
- `.gitignore`: gains `.worktrees/` entry
- `.claude/hooks/_mode-guard-helper.sh`: `.gitignore` added to `is_governance()` and template carve-outs
- `.claude/hooks/_headless-plan-approve.sh`: new helper for headless plan approval (shell I/O bypass pattern — complements `state-manager.sh` pre-write for sessions spawned outside the runner, e.g., direct `claude -p` invocations)
- `docs/ai/workflow.md`: Session Lifecycle gains worktree-by-default documentation
- `docs/ai/workflow-appendix/session-type-task-group.md`: parallel execution simplified (worktree is now default, not special-cased)
- `.claude/agents/orchestrator.md`: session init updated to reference worktree default
- `AI.md`: hooks table updated with worktree default reference
- `RUNNER-PARITY.md`: updated to reflect worktree flag addition

## Supersedes
None. Extends Decision 0030 (worktree infrastructure) and Decision 0032 (parallel worktree requirement) to cover all session types by default.

## Override
`REPO_OS_WORKTREE_ISOLATE=0` — disables `--worktree` flag in runner. Interactive sessions: omit `--worktree` from CLI invocation.

---

## Implementation Note (Amendment — 2026-06-19)

**Implementation point #1 above is partially inaccurate.** The decision text says `runner.sh` passes `--worktree` to `claude -p`. The actual implementation uses `git worktree add "$dir" "$branch"` followed by `cd "$launch_dir"` instead of the `--worktree` flag. This is intentional and correct.

**Rationale for `git worktree add` over `--worktree`:**

The `--worktree` Claude Code flag creates a temporary worktree from the invoking process's HEAD (i.e., `main`), not from the target feature branch. This would cause every daemon session to start on `main` regardless of the target branch, which would break branch targeting entirely.

`git worktree add "$dir" "$branch"` explicitly checks out the target branch into the worktree directory, so the session starts on the correct branch. See `runner.sh` lines 750–757:

```bash
# Worktree isolation (Decision 0033): create a worktree targeting the feature
# branch so the session runs in isolation. Manual git worktree add is used
# instead of --worktree flag because --worktree creates from the invoking
# process's HEAD (main), not the target branch.
local worktree_dir="${REPO_ROOT}/.worktrees/${REPO_OS_SESSION_ID}"
if git worktree add "$worktree_dir" "$_SETUP_BRANCH" 2>/dev/null; then
```

The code is correct. This note reconciles the decision text with the implementation.

---

## Amendment — 2026-10-06: Sequential Task Group Worktree Lifetime (Decision 0054)

The "What This Does NOT Change" bullet above reads:

> Sequential task groups: unaffected (shared branch, worktree isolation is per-session)

That line is accurate as a description of what this decision implemented, but
it was never a decision about sequential task groups — it recorded a side
effect. Because worktree isolation is per-session and each brief in a group is
its own session, a sequential group sharing one branch got a worktree created
and force-removed for every brief. Two costs followed:

- untracked and gitignored working files (dependency installs, build output,
  caches) were rebuilt for every brief in the group; and
- a crashed brief's worktree was force-removed along with the state an operator
  would have wanted to inspect.

**Decision 0054 supersedes this bullet for the worktree-lifetime question
only.** A sequential task group now gets ONE worktree at
`.worktrees/tg-{group_name}` for the whole life of its branch: brief 1 creates
it, briefs 2…N reuse it behind a clean-start check and a single-occupancy lock,
and it is removed only after the final brief merges and seals, when the group
fails or is abandoned, or by the stale sweep.

Everything else in this decision stands unchanged:

- Worktree isolation remains the default for **all** session types.
- Standalone sessions keep the per-session worktree at
  `.worktrees/{session-id}` described here.
- Parallel task groups keep Decision 0032's per-brief branches and worktrees.
- `REPO_OS_WORKTREE_ISOLATE=0` remains the opt-out and disables group worktrees
  along with everything else.
- Per-session governance state stays at `wt-sessions/{sid}/` per Decision 0030,
  so briefs sharing a group worktree still do not share phase-state or gate
  evidence.

See `docs/ai/decisions/t-0054-task-group-worktree-lifetime.md`.
