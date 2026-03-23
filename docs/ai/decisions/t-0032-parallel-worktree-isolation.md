# Decision 0032 — Parallel Task Group Worktree Isolation

## Status
Accepted

## Triggers

- type: file
- path: `docs/ai/(workflow-appendix/session-type-task-group|prompts/prompt-t-task-definition|task-groups/_contract-template)\.`
- keywords: `parallel, worktree, Execution: parallel, worktree isolation, per-brief branch`

## Decision
Parallel task group content briefs MUST run as full worktree sessions (`claude --worktree` with `REPO_OS_SESSION_ID`), each committing to its own isolated branch. The merge brief combines per-brief branches before performing cross-session cohesion review. This is a REQUIRE-level constraint — no mechanical hook enforcement is added in this decision. Future follow-up may upgrade to BLOCK-level boundary enforcement.

### Problem
Parallel content briefs sharing a single branch create race conditions: concurrent `git add && git commit` operations can overwrite each other's staged work, produce interleaved commits that obscure per-brief authorship, and make crash recovery impossible (a crashed brief's partial work is entangled with other briefs' commits). The existing completion marker and boundary systems mitigate scope conflicts but do not address the fundamental shared-branch concurrency problem.

### Solution
Leverage Decision 0030's worktree session infrastructure to give each parallel content brief its own worktree and branch:

1. **Per-brief branches**: Each parallel content brief creates a worktree branch named `{group-branch}/brief-{seq}` (e.g., `feature/my-group/brief-1`). The brief commits independently to this branch with full A1–A6 gate enforcement per brief
2. **Completion markers on shared path**: Content briefs write completion markers to `$_REPO_OS_ROOT/.claude/.state/` (the main repo's state directory, not the per-session state directory). This ensures the merge brief can find markers regardless of worktree state directory scoping
3. **Merge brief branch combining**: The merge brief reads `briefs[].branch` from the contract roster to identify source branches, then merges or cherry-picks each into the group's base branch. Merge conflicts are attributed per-brief via branch naming. After combining, `git diff main...HEAD` produces the full parallel diff for cohesion review
4. **Crash safety**: A crashed content brief's committed work is preserved on its dedicated branch. Other briefs are completely unaffected. The operator can restart the failed brief targeting the same worktree branch, resuming from the last committed state

### Crash Recovery

When a parallel content brief crashes mid-session:

1. **Committed work is safe**: The brief's branch (`{group-branch}/brief-{seq}`) retains all committed work. Other briefs are unaffected
2. **Clean up the stale worktree** (if needed): `git worktree remove <worktree-path>` or `git worktree prune` if the directory was already deleted
3. **Restart the brief**: Launch a new session targeting the existing branch. Use a new `REPO_OS_SESSION_ID` and set `REPO_OS_ALLOW_REINIT=1` to clear stale phase state from the crashed session:
   ```
   REPO_OS_SESSION_ID=<new-unique-id> REPO_OS_ALLOW_REINIT=1 claude --worktree
   ```
   The agent checks out the existing brief branch and resumes from the last committed state
4. **Alternative — skip the brief**: If restart is impractical, manually create the completion marker so the merge brief can proceed:
   ```
   date -u +%Y-%m-%dT%H:%M:%SZ > .claude/.state/tg-{group}-brief-{seq}.complete
   ```
   The merge brief will include whatever was committed on the brief's branch before the crash

### What This Does NOT Change
- Sequential task groups remain on a shared branch (no worktree requirement)
- Boundary enforcement stays REQUIRE-level (agent-remembered, not hook-enforced)
- No changes to hook code (`write-guard.sh`, `bash-guard.sh`, etc.)
- No changes to the automation runner
- Decision 0030's worktree infrastructure is used as-is — no duplication

## Implication
- `session-type-task-group.md` § Parallel Execution updated: worktree isolation requirement, per-brief branch naming, merge brief branch-combining lifecycle
- `prompt-t-task-definition.md` § Parallel detection updated: merge brief template includes branch combining, operator instructions reference `claude --worktree`
- `_contract-template.yaml` updated: `briefs[].branch` documented as the source of truth for merge brief branch discovery (no redundant `source_branches` field)
- Operators launching parallel briefs must use `claude --worktree` with a unique `REPO_OS_SESSION_ID` per brief

## Supersedes
None. Extends Decision 0030 (worktree infrastructure) and Decision 0018 (task group enforcement) for the parallel execution case.

## Override
None — REQUIRE-level constraint. Operators who cannot use worktree isolation should use sequential execution instead.
