# Decision 0010 — Task Definition Prompt

## Status
Accepted

## Decision
Add Prompt T (Task Definition) as a lightweight exploration and task planning prompt:
1. **Two modes**: Query (conversational Q&A, no structured output) and Brief (dispatches 3-agent team, produces copy-pastable task brief for Prompt B)
2. **Agent team**: Architect + Exploration + Critic — same agents as advisory board Standard tier, repurposed for task-scoped analysis rather than full spec review
3. **Fully ephemeral**: No file artifacts. Output is terminal-only. Leverages existing zero-change session log exemption (no session log entries)
4. **No code changes**: Prompt T sessions are read-only exploration. No Edit, Write, or Bash mutation commands
5. **Operator confirmation**: Brief mode requires explicit operator approval before finalizing output. Draft is presented for review, revision, or splitting
6. **Spec-aware but spec-optional**: Reads compiled specs when available for grounding. Works from codebase analysis alone when specs do not exist
7. **Prompt B compatibility**: Task brief format is structured to map directly to Prompt B's plan-before-code workflow (goal, scope, files, approach, verification)

## Consequences
- `docs/ai/prompts/prompt-t-task-definition.md` added (new prompt file)
- `AI.md` Prompts section gains Prompt T entry
- `docs/ai/workflow.md` gains Task Definition Sessions subsection
- `.claude/agents/_agent-workflow.md` gains Task Definition Flow note
- No new agent files — reuses existing Architect, Exploration, and Critic agents in their spec-mode configurations
- No new hooks, gates, or settings changes — Prompt T produces no artifacts that require enforcement
- Pipeline flow: Prompt T is an on-demand side path available at any point, not a sequential step in the 0 → A → B pipeline
