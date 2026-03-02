# Decision 0007 — Advisory Board (Spec Review Layer)

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/agents/_advisory-board.*\.md`
- keywords: `advisory, tier, specialist, refinement`

## Decision
- Advisory Board is a team of 7 read-only specialist agents that review compiled specs before build begins
- Mix of always-on (Architect, Critic, Exploration) and conditional (Security Analyst, UX Strategist, Performance Engineer, Data Strategist)
- Exploration agent combines research and creative ideation (formerly separate Researcher + Innovator agents)
- Conditional activation is signal-based: Orchestrator scans compiled specs (or feature brief "What It Touches" field) for trigger keywords
- Advisory Board produces a Refinement Report synthesized by the Orchestrator, presented to the operator for per-item accept/reject/defer
- The operator remains the final arbiter — advisory findings are recommendations, not mandates
- Prompt A expands from single-phase to three phases: Advisory Board → Operator Review → Repo OS Validation
- Feature briefs stored at `docs/spec/compiled/{active}/features/brief-{name}.md` (created via Prompt T significant feature path — see Decision 0010)
- Promoted PoC explorations (from Decision 0006) can feed into feature brief → Advisory Board → Prompt B

## Consequences
- Prompt A becomes the orchestration point for spec review, not just Repo OS init
- 7 agent files + 2 shared reference files (`_advisory-board.md` for Orchestrator, `_advisory-board-lite.md` for agents) in `.claude/agents/`
- `_agent-workflow.md` gains advisory board in the handoff chain
- Feature brief template added to `docs/spec/_templates/`
- Advisory agents are distinct from build-phase agents (e.g., `security-analyst.md` reviews specs; `security-privacy.md` reviews code)
- Template sync will distribute advisory agents to downstream projects
