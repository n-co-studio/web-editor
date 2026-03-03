# Decision 0016 — Auditor Agent & Prompt C Audit Dispatch

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/agents/auditor\.md`
- path: `docs/ai/prompts/prompt-c-project-audit\.md`
- keywords: `auditor, audit, dimension, co-audit, workshop, escalation, tech-debt, cohesion-drift`

## Decision
Establish the Auditor as a dedicated project health analyst agent with Prompt C as its multi-mode dispatch framework:
1. **Auditor agent**: Read-only specialist (`.claude/agents/auditor.md`) with five scan modes — drift, compliance, cohesion-drift, governance, tech-debt. Each mode defines its own scan boundaries, input artifacts, and finding categories. Uses the advisory board brief format for output. Capped at ~10 findings per mode, CRITICAL first
2. **Prompt C dispatch**: Prompt C (`docs/ai/prompts/prompt-c-project-audit.md`) orchestrates multi-dimension audit sessions. The Orchestrator selects dimensions from the dimension menu, dispatches agents in parallel, and synthesizes results into a unified Audit Report
3. **Depth tiers**: Quick (governance + security), Standard (operator-selected dimensions), Deep (all dimensions). Tech debt available at Standard and Deep only. Tier auto-inferred from operator language when not explicit
4. **Pre-spec degradation**: When `manifest.json` has `"active": null`, spec-dependent dimensions (drift) skip and governance degrades. Other dimensions run normally on code alone
5. **Specialist collaboration**: Three Orchestrator-mediated patterns — Escalation (Auditor tags findings with `[ESCALATE: agent-name]`, Orchestrator dispatches specialist one-shot), Co-audit (Orchestrator dispatches Auditor and specialist in parallel on same scope), Workshop (iterative loop capped at 2 rounds, following cohesion review precedent from `_cohesion-review.md`)
6. **Read-only enforcement**: Auditor has `disallowedTools: Edit, Write, Bash, Task` in frontmatter. Prompt C sessions produce no file artifacts except when operator deferrals write to `known-issues.md` and `.deferrals-pending`
7. **Agent dispatch prohibition**: Auditor cannot dispatch agents directly — enforced by `disallowedTools: Task`. All specialist collaboration routes through the Orchestrator via escalation tags
8. **Phase sequence** (Decision 0014): `init→scope→dispatch→synthesize→op-review→close`. Session type: `audit`

## Context
The Auditor agent and Prompt C were introduced to provide on-demand project health auditing as a distinct capability from advisory board spec review (Decision 0007) and build-phase cohesion review (Decision 0008). The Critic's cohesion mode is diff-scoped and build-phase only; the Auditor's cohesion-drift mode scans the entire codebase for accumulated drift regardless of when it was introduced. This warranted a separate agent and prompt rather than extending existing structures.

## Consequences
- `.claude/agents/auditor.md` added with five-mode scan definitions and collaboration patterns
- `docs/ai/prompts/prompt-c-project-audit.md` added with dimension menu, depth tiers, dispatch rules, and synthesis format
- `_agent-glossary.md` gains Auditor in the Operations category alongside Analytics
- `_agent-workflow.md` gains audit session handoff chain
- Decision 0014 gains `audit` session type with its phase sequence
- Prompt C is read-only by default — the zero-change session log exemption applies. Deferral exception activates close sequence when operator deferrals produce file modifications
- Auditor finding format reuses the advisory board brief structure (Decision 0007), maintaining consistency across review outputs
