# Decision 0011 — Task Group Contracts

## Status
Accepted

## Triggers

- type: file
- path: `docs/ai/task-groups/`
- path: `\.claude/local/task-groups/`
- keywords: `task.group, contract, A6, next_brief, pre-approval, one.branch.per.group, parallel, execution, completion_markers, merge_brief, boundaries`

Note: `.claude/local/` is gitignored, so the `.claude/local/task-groups/` trigger path is structurally inert for A1 enforcement in template mode — trigger matching operates on staged files, and gitignored paths are never staged. The path is listed here for documentation completeness and to ensure A1 enforcement activates correctly if this decision is evaluated in child/autonomous repos where task group contracts live at `docs/ai/task-groups/`.

## Decision
Add task group contracts to coordinate multi-brief sessions when Prompt T splits a task into briefs (Narrow path). Supports both sequential and parallel execution:
1. **Contract file**: YAML at `docs/ai/task-groups/{group-name}.yaml` following `_contract-template.yaml`. Contains identity, brief roster with `next_brief` sequencing, shared conventions, integration points, and append-only session decisions
2. **Creation**: First Prompt B session in a group creates the contract from brief metadata. Prompt T never writes files (Decision 0010)
3. **Conventions are REQUIRE-level**: Naming patterns, architectural patterns, key decisions, and module boundaries from the contract are mandatory constraints for all sessions in the group
4. **Gate A6 (Task Group Compliance)**: New commit gate verifying contract exists, conventions followed, and contract updated at session close. Independently skippable via `SKIP_CONTRACT_CHECK=1`. Applies only when task group is present
5. **Prompt T metadata**: Brief template gains `### Task Group` section. Narrow path sub-briefs include group name, sequence number, total count, and integration notes
6. **Hook enforcement**: Pre-commit blocking check when contract modified but not staged. Session-close advisory reminder for next brief in sequence. Both follow existing patterns (Decision 0004)
7. **Zero behavior when absent**: Standalone Prompt B sessions (no `### Task Group` in brief) have no contract-related behavior
8. **One branch per group** (Decision 0015): Brief 1 creates the branch. Briefs 2 through N-1 commit and close without merge — branch stays open. Brief N (final) merges to main and seals the branch. Non-final briefs never appear in the closed-branches ledger (Decision 0013)
9. **Brief-level sealing**: Only the final brief seals the branch. This removes the need for Gate 5 exemption logic — active task group branches are never in the ledger
10. **Pre-approval mode**: Prompt T asks the operator whether to pre-approve all briefs (auto mode — agent completes through merge autonomously) or review each individually (review mode). The contract carries this setting. Individual briefs inherit without re-prompting. The `approval` phase auto-passes for pre-approved groups
11. **Execution mode**: Contract `identity:` section includes `execution: sequential | parallel`. Default is `sequential`. When `parallel`, briefs with non-overlapping file scope can run concurrently. Prompt T sets this based on operator choice after scope analysis
12. **Boundaries**: Each brief in the roster gains a `boundaries: []` field — list of file path globs the brief owns exclusively. For parallel groups, edits outside boundaries require operator approval. For sequential groups, boundaries are advisory
13. **Completion markers**: Contract gains `completion_markers:` section (parallel only). Each content brief writes `.claude/.state/tg-{group}-brief-{seq}.complete` at session close. The merge brief checks all markers before proceeding
14. **Merge brief**: Contract gains `merge_brief:` section (parallel only) — `{ title, session, status }`. The merge brief is also listed in the `briefs:` roster as the last entry. It uses the `taskgroup-merge` session type (Decision 0014) to perform cross-session cohesion review, integration verification, and merge to main. Shared files that multiple briefs need to edit are owned by the merge brief's boundaries
15. **Gate 6 and `taskgroup-merge`**: Gate 6 (session overlap — Decision 0013) must accept `taskgroup-merge` sessions alongside `taskgroup` sessions on the same branch (advisory, not blocking)

## Consequences
- `docs/ai/task-groups/_contract-template.yaml` added (new template file)
- `docs/ai/task-groups/` added to AI.md on-demand Source of Truth
- `docs/ai/quality-gates.md` gains A6 row
- `.claude/agents/qa-verifier.md` gains A6 verification
- `.claude/agents/orchestrator.md` gains REQUIRE constraint, checklist items, on-demand procedure
- `docs/ai/prompts/prompt-t-task-definition.md` gains `### Task Group` in brief template and Narrow path instructions
- `docs/ai/prompts/prompt-b-product-build.md` gains Task Group Contract operating rule
- `.claude/hooks/pre-commit-gates.sh` gains blocking A6 check
- `.claude/hooks/session-close-check.sh` gains advisory next-brief reminder
- `.claude/agents/_agent-workflow.md` and `docs/ai/workflow.md` gain task group documentation
- Task group contract paths are mode-aware per Decision 0012: template mode uses `.claude/local/task-groups/`, product/child modes use `docs/ai/task-groups/`
- `docs/ai/task-groups/_contract-template.yaml` gains `execution`, `boundaries`, `completion_markers`, and `merge_brief` fields
- `docs/ai/prompts/prompt-t-task-definition.md` gains parallel detection logic and merge brief auto-generation in Narrow path
- `docs/ai/prompts/prompt-b-product-build.md` gains `taskgroup-merge` phase table and parallel operating rules (completion markers, boundary enforcement)
- `.claude/hooks/_phase-helper.sh` gains `taskgroup-merge` session type (Decision 0014)
- `.claude/hooks/session-close-check.sh` gains explicit `taskgroup-merge` handling in branch seal and solo merge paths
- `.claude/hooks/session-close-check.sh` `is_final_brief()` gained parallel execution awareness: `taskgroup` sessions with `execution: parallel` contracts always return `"false"` (parallel content briefs never merge); `taskgroup-merge` sessions check completion markers and return `"true"` only when markers exist. Sequential execution logic unchanged
- `.claude/hooks/session-close-check.sh` `cleanup_session()` cleans completion marker files (`tg-*-brief-*.complete`) when the session type is `taskgroup-merge`
- `.claude/agents/_cohesion-review.md` gains Cross-Session Cohesion Mode section for merge brief procedure
