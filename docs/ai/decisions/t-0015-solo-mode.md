# Decision 0015 — Solo Mode

## Status
Accepted

## Triggers

- type: process
- keywords: `solo, solo.mode, direct.merge, merge.to.main`
- enforced_by: `.claude/hooks/session-close-check.sh`

## Decision
Add a solo mode that enables direct merge to main at session close. Designed for single-operator repositories where self-review replaces external review:

1. **Solo mode activation**: Set via a `solo` field in `.claude/.state/phase-state` (`solo: true` or `solo: false`, default: `false`). Solo mode is orthogonal to the `mode` field (auto/review) — solo controls whether the session merges to main at close, while auto/review controls *when* the operator reviews (before close vs at close). Activation: operator sets solo at session start or via task group pre-approval. The `solo` field is part of the phase-state schema (Decision 0014) and managed by `get_solo`/`set_solo` in `_phase-helper.sh`

2. **Branch lifecycle**:
   - Branch created from `main` at `init` phase (standard: `feature/<description>`, hotfix: `hotfix/<description>`)
   - At `close` phase (solo auto): merge branch to main directly (`git checkout main && git merge --ff-only <branch>`, fallback `--no-ff` if fast-forward not possible), then seal branch
   - At `close` phase (solo review): agent pauses at `op-review` for operator acceptance, then merges on acceptance
   - Experiment branches (`experiment/*`) are excluded from solo merge — they follow their own close behavior (abandon/promote per Prompt 0.5 and quality-gates.md). `release/*` branches are excluded from solo merge (release gates C1–C3 mandate external review — team-mode extension point). Solo mode only applies to mergeable branch types (`feature/*`, `fix/*`, `hotfix/*`)

3. **Task groups in solo mode**:
   - One branch per group, created by brief 1
   - Briefs 2 through N-1: commit to branch, update contract, close without merge. Branch stays open
   - Brief N (final): commit to branch, update contract, merge branch to main, seal branch
   - All briefs share the same branch — no intermediate merges
   - Merge brief (Brief M, parallel groups): always the final brief. Runs `taskgroup-merge` session type. At close: merges to main and seals branch. `is_final_brief()` returns `"true"` based on completion marker presence, not brief roster `status: pending` checks

4. **Merge failure handling**:
   - Validate `git merge` exit code before branch seal
   - On merge conflict or failure: `git merge --abort`, notify operator with conflict details
   - Agent does not attempt automatic conflict resolution on main — operator must resolve
   - Branch remains open (not sealed) on merge failure, allowing retry

5. **Recovery path**:
   - If a defective merge is discovered post-close: `git revert -m 1 <merge-commit>` on main
   - The reverted branch can be re-checked-out, fixed, and re-merged
   - Recovery is an operator-initiated action, not automated

6. **Non-main base branches** (future exception, not implemented):
   - Hotfix and release branches may need non-main base branches (e.g., merge hotfix to `release/v1` instead of `main`)
   - Current implementation always merges to main
   - When needed: amend this decision to add a `target_branch` field to phase-state

## Consequences
- `session-close-check.sh` gained solo-mode merge logic: merges `feature/*`/`fix/*`/`hotfix/*` branches directly to main when `solo=true` (ff-only preferred, fallback `--no-ff`). Merge failure triggers `git merge --abort` and operator notification
- `_phase-helper.sh` gained `get_solo`/`set_solo` functions, `solo` field in phase-state schema, and `write_merge_signal()` for the agent-to-hook merge signal
- Branch-guard Gate 1 (main protection) unaffected — Gate 1 only blocks file writes on main, not merge commands. The agent runs `git checkout main && git merge` in the close phase; the stop hook retains solo merge logic as a safety net for sessions where the agent fails to merge. Task group sessions merge via the agent in the close phase — Gate 7 has a close-phase exemption that allows merge commands when the current phase is `close` (Decision 0018 amendment)
- Decision 0013 (session branch isolation) unchanged — branches are still sealed at close, just merged first in solo mode
- `is_final_brief()` recognizes `taskgroup-merge` as always-final (marker-based finality check for parallel groups, separate from sequential `status: pending` logic)
