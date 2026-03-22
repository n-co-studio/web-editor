# Decision 0010 — Task Definition Prompt

## Status
Accepted

## Triggers

- type: file
- path: `docs/ai/prompts/prompt-t`
- keywords: `task definition, Brief mode, Query mode, significant feature, taskdef-query, taskdef-brief`

## Decision
Add Prompt T (Task Definition) as a lightweight exploration and task planning prompt:
1. **Two modes**: Query (conversational Q&A, no structured output) and Brief (dispatches 3-agent team, produces copy-pastable task brief for Prompt B)
2. **Agent team**: Architect + Exploration + Critic — same agents as advisory board Standard tier, repurposed for task-scoped analysis rather than full spec review
3. **Fully ephemeral**: No file artifacts. Output is terminal-only. Leverages existing zero-change session log exemption (no session log entries)
4. **No code changes**: Prompt T sessions are read-only exploration. No Edit, Write, or Bash mutation commands
5. **Operator confirmation**: Brief mode requires explicit operator approval before finalizing output. Draft is presented for review, revision, or splitting
6. **Spec-aware but spec-optional**: Reads compiled specs when available for grounding. Works from codebase analysis alone when specs do not exist
7. **Prompt B compatibility**: Task brief format is structured to map directly to Prompt B's plan-before-code workflow (goal, scope, files, approach, verification)
8. **Significant feature path**: When the operator describes a feature requiring spec-level definition (new user-facing capability, new data model, new integration), Brief mode produces a two-brief task group: Brief 1 writes the feature spec (runs as Prompt B, writes to `compiled/{active}/features/brief-{name}.md`), Brief 2 builds the feature (standard Prompt B). Detection: operator describes something touching data contracts, integrations, or boundaries — or explicitly requests a feature spec. This absorbs Prompt 0 Feature mode, which is removed
9. **Phase sequences** (Decision 0014): Query `init→conversation→close`, Brief `init→dispatch→synthesize→approval→output→close` (Decision 0029 renamed `op-review` → `approval` for mechanical enforcement). Session types: `taskdef-query`, `taskdef-brief`
10. **Task group auto-approval**: When producing a task group (Narrow path), Prompt T asks whether to pre-approve all briefs (auto mode) or review each individually. The contract carries this setting

## Consequences
- `docs/ai/prompts/prompt-t-task-definition.md` added (new prompt file)
- `AI.md` Prompts section gains Prompt T entry
- `docs/ai/workflow.md` gains Task Definition Sessions subsection
- `.claude/agents/_agent-workflow.md` gains Task Definition Flow note
- No new agent files — reuses existing Architect, Exploration, and Critic agents in their spec-mode configurations
- No new hooks, gates, or settings changes — Prompt T produces no artifacts that require enforcement
- Pipeline flow: Prompt T is an on-demand side path available at any point, not a sequential step in the 0 → A → B pipeline
- Prompt 0 Feature mode removed — redirect note in Prompt 0 points to Prompt T significant feature path
- `docs/ai/prompts/prompt-0-spec-builder.md` Feature mode section removed, redirect added
