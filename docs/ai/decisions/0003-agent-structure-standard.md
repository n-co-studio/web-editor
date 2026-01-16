# Decision 0003 — Agent Structure Standardization

## Status
Accepted

## Context
Initial agent definitions were minimal specifications (~500 bytes each). As the Repo OS matured, comprehensive documentation was needed for consistent autonomous operation, clear handoffs, and unambiguous decision-making.

## Decision
All agent definitions in `.claude/agents/` must follow a standardized structure:

1. **Shared Files** (mandatory reading for all agents):
   - `_agent-glossary.md` — shared terminology definitions
   - `_agent-workflow.md` — workflow diagram and handoff protocols

2. **Agent Definition Structure** (each agent file):
   - Role, Authority, Required Reading, Invocation Criteria
   - Must (numbered responsibilities), Must Not (constraints)
   - Verification Checklist, Escalation Paths
   - Examples (2-3 scenarios), Handoffs

3. **Terminology Consistency**:
   - All agents use glossary definitions (small scope, high-risk, gate, etc.)
   - Gate definitions align with quality-gates.md
   - Risk levels and scope thresholds are quantified

## Consequences
- All agents must read shared files before execution
- Handoff protocols are standardized across agent interactions
- Terminology is consistent across agents and documentation
- New agents must follow the established structure
- Agent behavior is predictable and verifiable
