# Decision 0011 — Task Group Contracts

## Status
Accepted

## Decision
Add task group contracts to coordinate multi-brief sessions when Prompt T splits a task into sequential briefs (Narrow path):
1. **Contract file**: YAML at `docs/ai/task-groups/{group-name}.yaml` following `_contract-template.yaml`. Contains identity, brief roster with `next_brief` sequencing, shared conventions, integration points, and append-only session decisions
2. **Creation**: First Prompt B session in a group creates the contract from brief metadata. Prompt T never writes files (Decision 0010)
3. **Conventions are REQUIRE-level**: Naming patterns, architectural patterns, key decisions, and module boundaries from the contract are mandatory constraints for all sessions in the group
4. **Gate A6 (Task Group Compliance)**: New commit gate verifying contract exists, conventions followed, and contract updated at session close. Independently skippable via `SKIP_CONTRACT_CHECK=1`. Applies only when task group is present
5. **Prompt T metadata**: Brief template gains `### Task Group` section. Narrow path sub-briefs include group name, sequence number, total count, and integration notes
6. **Hook enforcement**: Pre-commit advisory warning when contract modified but not staged. Session-close advisory reminder for next brief in sequence. Both follow existing patterns (Decision 0004) — never block
7. **Zero behavior when absent**: Standalone Prompt B sessions (no `### Task Group` in brief) have no contract-related behavior

## Consequences
- `docs/ai/task-groups/_contract-template.yaml` added (new template file)
- `docs/ai/task-groups/` added to AI.md on-demand Source of Truth
- `docs/ai/quality-gates.md` gains A6 row
- `.claude/agents/qa-verifier.md` gains A6 verification
- `.claude/agents/orchestrator.md` gains REQUIRE constraint, checklist items, on-demand procedure
- `docs/ai/prompts/prompt-t-task-definition.md` gains `### Task Group` in brief template and Narrow path instructions
- `docs/ai/prompts/prompt-b-product-build.md` gains Task Group Contract operating rule
- `.claude/hooks/pre-commit-gates.sh` gains advisory A6 check
- `.claude/hooks/session-close-check.sh` gains advisory next-brief reminder
- `.claude/agents/_agent-workflow.md` and `docs/ai/workflow.md` gain task group documentation
