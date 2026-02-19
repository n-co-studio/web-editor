# Decision 0007 — Advisory Board (Spec Review Layer)

## Status
Accepted

## Decision
- Advisory Board is a team of 8 read-only specialist agents that review compiled specs before build begins
- Mix of always-on (Researcher, Architect, Critic, Innovator) and conditional (Security Analyst, UX Strategist, Performance Engineer, Data Strategist)
- Conditional activation is signal-based: Orchestrator scans compiled specs (or feature brief "What It Touches" field) for trigger keywords
- Advisory Board produces a Refinement Report synthesized by the Orchestrator, presented to the operator for per-item accept/reject/defer
- The operator remains the final arbiter — advisory findings are recommendations, not mandates
- Prompt A expands from single-phase to three phases: Advisory Board → Operator Review → Repo OS Validation
- Prompt 0 gains a third mode (Feature) for adding individual features to an active spec version
- Feature briefs stored at `docs/spec/compiled/{active}/features/brief-{name}.md`
- Promoted PoC explorations (from Decision 0006) can feed into Feature mode → Advisory Board → Prompt B

## Consequences
- Prompt A becomes the orchestration point for spec review, not just Repo OS init
- 8 new agent files + 1 shared reference file added to `.claude/agents/`
- `_agent-workflow.md` gains advisory board in the handoff chain
- Feature brief template added to `docs/spec/_templates/`
- Advisory agents are distinct from build-phase agents (e.g., `security-analyst.md` reviews specs; `security-privacy.md` reviews code)
- Template sync will distribute advisory agents to downstream projects
