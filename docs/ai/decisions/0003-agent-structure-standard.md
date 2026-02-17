# Decision 0003 — Agent Structure Standardization

## Status
Accepted

## Decision
All agents in `.claude/agents/` must follow:
1. **Shared files** (mandatory reading): `_agent-glossary.md`, `_agent-workflow.md`
2. **Structure**: YAML frontmatter (invocable agents only — orchestrator exempt per 0004). Each agent must define: Role, scope of authority (autonomous vs requires escalation), behavioral constraints, output format, and invocation criteria. Section names may adapt to agent purpose (e.g., "When Required", "Rules", "Review Format").
3. **Terminology**: use glossary definitions; gate definitions align with `quality-gates.md`
