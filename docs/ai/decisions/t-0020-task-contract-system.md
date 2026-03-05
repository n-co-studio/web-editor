# Decision 0020 — Task Contract System

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/\.state/task-contract\.yaml`
- path: `docs/ai/task-groups/.*\.yaml`
- path: `\.claude/local/task-groups/.*\.yaml`
- path: `\.claude/agents/_cohesion-review\.md`
- path: `\.claude/agents/critic\.md`
- keywords: `task-contract, task_contract, intent:, verification:`

## Decision
Introduce persistent task contracts that capture task-level intent (verification criteria, scope, spec references) as a referenceable artifact during builds. Contracts close the gap between ephemeral task briefs and structural cohesion review.

1. **Task contract**: A lightweight YAML artifact containing `goal`, `scope_files`, `scope_modules`, `approach`, `verification` (list of falsifiable criteria), `spec_references`, `constraints`, and `lifecycle` (enum: `task-scoped` | `group-scoped`). Schema defined below.

2. **Prompt T output**: Prompt T embeds the task contract as a `### Task Contract` section inside the single brief template (after `### Spec References`), so operators copy one block instead of two. For task groups, the contract content is embedded in each brief's `### Task Group` section as a `Contract:` field. Prompt T remains fully ephemeral — no file writes.

3. **Prompt B consumption**: At session init, Prompt B extracts the task contract from the brief text and writes it to `.claude/.state/task-contract.yaml`. For task groups, the `intent:` block is written into the group contract YAML during the `contract-init` phase. Stale contract detection: if `task-contract.yaml` already exists at session start, delete it before writing the new one.

4. **Cohesion review integration**: The cohesion review procedure reads the task contract and passes its `verification:` criteria to Critic alongside the diff. Critic evaluates each criterion as VERIFIED, UNVERIFIED, or INCONCLUSIVE. These findings are advisory — they feed into the cohesion brief but do not produce a separate gate result.

5. **Two lifecycle scopes**:
   - **Task-scoped** (singular builds): `.claude/.state/task-contract.yaml`. Cleaned at session close by `cleanup_session()`.
   - **Group-scoped** (task groups): `intent:` block in the group contract YAML. The `intent:` block persists in the contract as part of the group's governance record — it is not deleted at close. Each brief updates its own `intent:` fields during `contract-init`; the final contract captures the last brief's intent alongside accumulated governance evidence. Governance evidence (gate results, overrides) continues to use the existing `governance:` section in group contracts — no additional lifecycle management needed.

6. **No new gate**: Contract verification extends gate A5 (cohesion review) as advisory criteria. It does not introduce a new blocking gate. Intent adherence via verification criteria is model judgment (VERIFIED/UNVERIFIED/INCONCLUSIVE), not a mechanical binary check. Making it blocking would risk false positives that erode gate trust.

7. **Backward compatibility**: Sessions without task contracts (legacy sessions, hotfixes, experiment branches) skip contract verification silently. The `intent:` block in group contracts is optional — existing groups without it continue to work.

8. **Automation layer**: Headless runners (Decision 0017) include the full brief text (which contains the `### Task Contract` section inline) in the assembled prompt. The agent extracts the contract YAML and writes it to `.claude/.state/task-contract.yaml` during init. No separate parsing step is needed — the contract is part of the brief.

## Contract Schema

```yaml
# Task Contract — written to .claude/.state/task-contract.yaml (singular)
# or embedded as intent: block in task group contract (groups)
goal: ""                    # what this task accomplishes (1-2 sentences)
scope_files:                # files likely affected
  - ""
scope_modules:              # which parts of the system this touches
  - ""
approach:                   # numbered implementation steps
  - ""
verification:               # falsifiable criteria for completion
  - ""
spec_references:            # paths to relevant spec files
  - ""
constraints:                # constraints from operator or spec boundaries
  - ""
lifecycle: task-scoped      # task-scoped | group-scoped
```

**Group-scoped subset:** The `intent:` block in task group contracts carries only `goal`, `verification`, `scope_files`, and `spec_references` — the fields relevant to cohesion review. Fields like `scope_modules`, `approach`, `constraints`, and `lifecycle` are omitted because the group contract already captures scope and constraints at the group level.

## Context
Task briefs are ephemeral — they exist only in the session's initial paste. Once the build begins, the intent (verification criteria, scope, spec references) is lost from referenceable context. Cohesion review (gate A5) checks for internal codebase coherence but has no reference for whether the implementation achieves what was intended. This gap means intent drift can only be caught by operator review, not by the mechanical review pipeline.

Task contracts persist the brief's intent as a lightweight YAML artifact that the cohesion review and Critic can reference. The design preserves Prompt T's ephemeral nature (Decision 0010) by having Prompt B write the contract from the brief text at session init.

## Consequences
- `docs/ai/decisions/t-0020-task-contract-system.md` created (this file)
- `docs/ai/prompts/prompt-t-task-definition.md` Step 5 updated: embeds `### Task Contract` YAML block inside the single brief template
- `docs/ai/prompts/prompt-b-product-build.md` init sequence updated: extraction rule references `### Task Contract` (level-3 heading inside the brief, not level-2); operating rule added
- `docs/ai/task-groups/_contract-template.yaml` updated: `intent:` block added
- `.claude/agents/_cohesion-review.md` procedure updated: contract retrieval and Critic instruction
- `.claude/agents/critic.md` cohesion mode updated: Contract Verification subsection added
- `.claude/agents/orchestrator.md` updated: contract retrieval before Critic dispatch
- `docs/ai/workflow.md` updated: Task Contract Lifecycle section added
- `docs/ai/quality-gates.md` A5 description updated: references contract verification
- `AI.md` source-of-truth paragraph updated
- `.claude/hooks/session-close-check.sh` `cleanup_session()` updated: `rm -f` for `task-contract.yaml`
- No new gates, no new hooks, no new state files beyond `task-contract.yaml`
