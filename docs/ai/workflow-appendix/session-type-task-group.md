# Session Type: Task Group

When Prompt T splits a task into multiple briefs (Narrow path), each brief includes a `### Task Group` section. The briefs share a task group contract that coordinates naming, patterns, decisions, and integration points across sessions. Contract path depends on repo mode (template mode: `.claude/local/task-groups/{group-name}.yaml`; product mode: `docs/ai/task-groups/{group-name}.yaml`).

- **One branch per group**: Brief 1 creates the branch. Briefs 2 through N-1 commit and close without merge. Brief N (final) merges to main and seals the branch. Non-final briefs do not seal the branch (Decision 0013). The final brief's merge is gated by close-time re-verification when main changed a file the group's branch also changed — the branch is rebased and re-verified first, and a failed verdict leaves it unmerged and unsealed as `review:reverify-failed`. The rebase happens in the group's own worktree, which is not removed by it (Decision t-0056)
- **Contract lifecycle**: First Prompt B session creates the contract from brief metadata, following `docs/ai/task-groups/_contract-template.yaml`. Subsequent sessions read the contract at session start — conventions are binding constraints. At session close, update the contract: mark this brief's status as `complete`, set session number and branch, append any new session decisions. Append a `governance:` entry for the current brief recording gate results (A1–A6, B1–B3), any overrides used, and a timestamp. Prompt T never writes files
- **Conventions are REQUIRE-level**: All sessions must follow the naming patterns, architectural patterns, decisions, and module boundaries established in the contract
- **Sequential execution (default)**: Briefs are numbered and should be executed in order. The contract tracks `next_brief` for sequencing. The group also shares one worktree across all its briefs — see § Worktree Lifetime (Decision 0054)
- **Pre-approval mode**: Operator may set auto mode for the entire group at Prompt T time. Individual briefs inherit the mode without re-prompting. The `approval` phase auto-passes for pre-approved groups
- **Standalone sessions**: When the task brief has no `### Task Group` section, skip all contract-related behavior entirely
- **Gate A6**: Verifies contract compliance when a task group is present. Skipped automatically for standalone briefs. Override: `SKIP_CONTRACT_CHECK=1`

See `docs/ai/task-groups/_contract-template.yaml` for the contract structure and `docs/ai/quality-gates.md` for gate A6 details.

## Worktree Lifetime (Decision 0054)

A **sequential** task group gets ONE worktree for the whole life of its branch, at `.worktrees/tg-{group_name}` (the brief's `Group:` field, sanitised to one path component). Brief 1 creates it; briefs 2…N reuse it. This is the one exception to the per-session worktree of Decision 0033, and it exists so that untracked and gitignored working state — dependency installs, build output, caches — is not rebuilt for every brief in the group, and so a crashed brief's worktree survives for inspection.

Reuse is gated, not automatic:

- **Clean-start check**: before a brief starts in a reused worktree, `git status --porcelain` must be empty and HEAD must equal the group branch's tip. If not, the runner writes an `esc-dirty-tree-*` escalation (type `governance-block`) and the brief **does not start**. Gitignored files never fail this check — preserving them is the point.
- **Single occupant**: one session at a time, enforced by a lock at `.claude/.state/.tg-worktree-{group}.lock.dir` recording the holder's pid and session id. A lock whose holder process is gone is broken automatically, so a crash cannot wedge the group. REQUIRE: this is enforced mechanically for headless/daemon briefs (the runner acquires and releases it); an operator entering the worktree by hand is responsible for respecting it — check `git worktree list` and the lock directory first.
- **Branch mismatch is loud**: if the worktree exists on a branch other than the group branch, or a non-worktree directory sits at the path, the runner escalates and refuses to start. It never silently recreates the worktree.

Removal happens only when the group is finished or dead:

| Trigger | Who removes it |
|---------|----------------|
| Final brief merged **and** branch sealed | `runner.sh` (`_solo_merge_if_needed`) |
| Work order reaches `failed`, or group abandoned | `runner.sh` daemon loop / next cleanup sweep |
| Branch sealed, branch deleted, or no commit for 7 days — with no live session and no live lock holder | `sweep_stale_group_worktrees()` in `group-worktree-sweep.sh`, run by `run_cleanup` |

Normal exit of a non-final brief, crash cleanup, and FORCE-HALT all deliberately leave the worktree in place and release only the lock. Per-session governance state stays at `wt-sessions/{session-id}/` inside the worktree, so briefs sharing a worktree never share phase-state or gate evidence (Decision 0030).

One caveat on the first row: removal is keyed on the closed-branches ledger, and Decision 0013 seals a final entry's branch on *any* terminal outcome — so a brief that **failed** but was the last entry also has its worktree removed. A crash leaves the worktree for inspection; a failure that seals the branch does not. Inspect the branch in that case — the committed work is on it, and only reproducible gitignored state is gone.

### Operator — crash recovery

A crashed brief leaves its worktree on disk with whatever the crash left behind. To recover:

1. **Inspect.** `cd .worktrees/tg-{group}` and look at `git status`, build output, logs — this is the state the old per-brief worktree destroyed.
2. **Clean, or the restart will refuse.** The clean-start check runs on restart, so commit the work (`git add -A && git commit`) or discard it (`git checkout -- . && git clean -fd`, keeping gitignored state). Leaving the tree dirty produces a `dirty-tree` escalation instead of a started brief — that is intended, not a bug.
3. **Restart the brief.** Relaunch with `REPO_OS_ALLOW_REINIT=1` so the crashed session's stale phase-state is cleared. The existing worktree is reused.
4. **If the lock looks stuck**, confirm the recorded holder is dead (`cat .claude/.state/.tg-worktree-{group}.lock.dir/pid`, then `kill -0 <pid>`); a dead holder's lock is broken automatically on the next acquire. Remove the directory by hand only if the holder is dead and the automatic break did not fire.

### Operator — interactive brief in the group worktree

Interactive and headless briefs share the same worktree. To run a brief interactively:

```bash
# First brief in the group (worktree does not exist yet):
git worktree add .worktrees/tg-{group} {group-branch}

# Any later brief — the worktree already exists; just enter it:
cd .worktrees/tg-{group}
git status --porcelain     # must be empty before starting the brief
claude                     # NOT `claude --worktree` — that would create a second, per-session worktree
```

Two things to note:

- Do **not** pass `--worktree`: the point is to reuse the group's worktree, and `--worktree` would create a fresh per-session one from the invoking HEAD.
- `.claude/repo-mode` is gitignored and so is not carried over by `git worktree add`. The runner copies it when it creates the worktree; if you create the worktree by hand for the first brief, copy it yourself (`cp .claude/repo-mode .worktrees/tg-{group}/.claude/repo-mode`) or the mode guard falls back to its `child` default.

## Parallel Execution

When Prompt T detects non-overlapping file scope across briefs, it offers parallel execution. The contract's `execution` field is set to `parallel`:

- **Worktree isolation (Decision 0032, Decision 0033)**: REQUIRE: parallel content briefs MUST run as full worktree sessions (`claude --worktree` with `REPO_OS_SESSION_ID`). Each content brief gets its own worktree and branch, commits independently, and runs the full A1–A6 gate chain per brief. This eliminates race conditions from shared-branch parallel execution and provides crash safety — a crashed brief's committed work is preserved on its branch while other briefs continue unaffected. Note: as of Decision 0033, worktree isolation is the default for ALL session types — parallel task groups are no longer special-cased. Sequential task groups diverge as of Decision 0054: they share ONE group-scoped worktree across all their briefs rather than getting one per session (see § Worktree Lifetime). Parallel groups keep a worktree per brief, because their briefs own separate branches
- **Boundaries**: Each brief declares file paths/globs it owns exclusively. Parallel briefs MUST restrict edits to their declared boundaries. Shared files (index files, config) are owned by the merge brief. Edits outside boundaries require explicit operator approval
- **Completion markers**: Each content brief writes `.claude/.state/tg-{group}-brief-{seq}.complete` at session close. Markers use the shared `$_REPO_OS_ROOT/.claude/.state/` path (not per-session state dirs) so the merge brief can find them regardless of worktree state directory scoping. The merge brief checks all markers before proceeding
- **Knowledge-graph deltas (Decision 0034 Amendment 5)**: Each content brief Builder authors a per-brief KG delta at close — `$_REPO_OS_ROOT/.claude/.state/tg-{group}-brief-{seq}.kg-delta.yaml` — instead of locking and writing the shared graph. Deltas live in the same flat shared-state directory as completion markers (no naming collision: distinct suffixes `.complete` vs `.kg-delta.yaml`). The merge brief authors its own delta and runs `kg-merge-deltas.sh` to apply the union under one lock
- **Merge brief (Brief M)**: Auto-generated by Prompt T, appended as the last brief. Uses the `taskgroup-merge` session type (Decision 0014). Runs after all content briefs complete. Phase sequence: `init → contract-init → cohesion → verify → commit → op-review → close`. The `cohesion` phase performs cross-session cohesion review across the combined diff from all parallel briefs. Integration issues are resolved in the `cohesion` phase (self-loop: `cohesion→cohesion`). Close always merges to main and seals the branch
- **Branch strategy**: Each parallel content brief creates its own worktree branch (named `{group-branch}/brief-{seq}`, e.g., `feature/my-group/brief-1`). The merge brief runs on the group's base branch and combines all per-brief branches before cohesion review. The merge brief merges the combined result to main and seals all branches. The merge strategy (merge commits, cherry-pick, or rebase) is at the merge brief agent's discretion based on conflict complexity
- **Crash recovery**: If a content brief crashes, its committed work is preserved on its branch. To restart: clean up the stale worktree (`git worktree prune`), then relaunch with `REPO_OS_SESSION_ID=<new-id> REPO_OS_ALLOW_REINIT=1 claude --worktree` targeting the existing branch. Alternatively, skip the brief by manually creating its completion marker (`date -u +%Y-%m-%dT%H:%M:%SZ > .claude/.state/tg-{group}-brief-{seq}.complete`). See Decision 0032 § Crash Recovery
- **Monitoring**: Check per-brief progress via `git log {group-branch}/brief-{seq}`, contract roster `briefs[].status`, or completion markers (`ls .claude/.state/tg-*-brief-*.complete`)

**Merge brief lifecycle:**

1. **`contract-init` phase**: Sync conventions from contract. Verify all content brief completion markers exist (glob: `.claude/.state/tg-*-brief-*.complete`). If any markers are missing, the agent blocks at this phase and reports which briefs have not completed. The operator restarts the failed brief or manually creates the marker file (`date -u +%Y-%m-%dT%H:%M:%SZ > .claude/.state/tg-{group}-brief-{seq}.complete`). Read source branches from `briefs[].branch` in the contract roster
2. **`cohesion` phase**: Combine per-brief branches into the group's base branch (merge or cherry-pick each `briefs[].branch` from the contract roster). Then run `git diff main...HEAD` to produce the combined diff from all parallel content briefs. Dispatch Critic in cohesion mode against this diff. Resolve findings directly (self-loop: `cohesion→cohesion`, capped at 2 rounds). If merge conflicts arise, attribute each side to its source brief (the branch name encodes the brief sequence). See `.claude/agents/_cohesion-review.md` Cross-Session Cohesion Mode
3. **`verify` phase**: QA verifies all gates (A1–A6, B1–B3). A6 applies (task group contract compliance)
4. **`close` phase**: Knowledge-graph aggregation runs first (Decision 0034 Amendment 5):
   1. Author the merge brief's own delta to `$_REPO_OS_ROOT/.claude/.state/tg-{group}-brief-merge.kg-delta.yaml` from cross-session observations (integration edges between files owned by different content briefs, cross-cutting relationships visible in the combined diff)
   2. Run `bash .claude/tools/kg-merge-deltas.sh {group}` — reads all per-brief deltas + the merge-brief delta, dedups, applies under one lock to the shared graph
   3. If `$_REPO_OS_ROOT/.claude/.state/kg-aggregation-conflicts.log` was written by the aggregator, surface those conflicts as CRITICAL cohesion findings (do not silently accept)

   Then merge to main, seal all branches (group base + per-brief branches), clean completion markers AND delta files (hook removes all `tg-*-brief-*.complete` and `tg-*-brief-*.kg-delta.yaml` files from `.claude/.state/`)

## Task Contract Lifecycle

Decision 0020. Task contracts persist the brief's intent as a lightweight YAML artifact for cohesion review reference. Two lifecycle scopes:

- **Task-scoped** (singular builds): Prompt B extracts the YAML block from the `### Task Contract` section in the brief and writes it to `.claude/local/task-contract.yaml` at session init. The contract lives in `.claude/local/` (not `.state/`) because it is model-written — `state-guard` blocks model writes to `.state/`. Cleaned at session close by `cleanup_session()`. If `task-contract.yaml` already exists at session start (orphan from crashed session), delete it before writing the new one.

- **Group-scoped** (task groups): The `intent:` block lives in the task group contract YAML. Written by each brief at `contract-init` phase from Prompt T output. The `intent:` block persists in the contract as part of the group's governance record — it is not deleted at close. Each brief updates its own `intent:` fields during `contract-init`; the final contract captures the last brief's intent alongside accumulated governance evidence.

At cohesion review, the Orchestrator reads the task contract and passes its `verification:` criteria to Critic alongside the diff. Critic evaluates each criterion as VERIFIED, UNVERIFIED, or INCONCLUSIVE (advisory — feeds into the cohesion brief, not a separate gate). Sessions without task contracts skip contract verification silently.
