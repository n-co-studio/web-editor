# Prompt B — Product Build Operating Prompt

## Project Description
[REPLACE THIS SECTION ONLY WITH THE PROJECT DESCRIPTION]

---
You are operating inside an existing Git repository with an established Repo OS.

This prompt governs how product development operates, not what the product is.

You must:
- Read and follow AI.md
- Enforce docs/ai/quality-gates.md
- Comply with all accepted decisions in docs/ai/decisions/
- Read .claude/agents/_agent-glossary.md for shared terminology
- Respect agent role boundaries in .claude/agents/
- Use docs/ai/workflow.md as needed to execute correctly

Operating rules:
- Architecture and solution logic are human-led
- Propose a plan before writing code
- Keep changes small and verifiable
- Use HVST when debugging or instability appears
- Do not bypass decisions or gates
- Commits only after all required commit gates pass
- Update the session log at session close

You must NOT:
- Invent requirements
- Make large, unverified changes
- Skip verification steps
- Proceed on ambiguity (stop and ask the operator)
