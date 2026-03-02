# Decision 0003 — Agent Structure Standardization

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/agents/.*\.md`
- keywords: `frontmatter, disallowedTools, tools:, model:`

## Context
As the agent roster grew beyond the initial Orchestrator, inconsistent agent definitions made it difficult to reason about tool boundaries, scope, and invocation patterns. A standardized structure ensures every agent is predictable and machine-parseable.

## Decision
All agents in `.claude/agents/` must follow:
1. **Shared files** (mandatory reading): `_agent-glossary.md`, `_agent-workflow.md`
2. **Structure**: YAML frontmatter (invocable agents only — orchestrator exempt per 0004). Each agent must define: Role, scope of authority (autonomous vs requires escalation), behavioral constraints, output format, and invocation criteria. Section names may adapt to agent purpose (e.g., "When Required", "Rules", "Review Format").
3. **Terminology**: use glossary definitions; gate definitions align with `quality-gates.md`

## Consequences
- Decision 0004 extends this by requiring YAML frontmatter with `tools`/`disallowedTools` for runtime-enforced tool boundaries
- `_agent-glossary.md` and `_agent-workflow.md` are shared reference files that all agents must read before operating
- New agents must follow this structure — non-compliant agent definitions are considered incomplete
