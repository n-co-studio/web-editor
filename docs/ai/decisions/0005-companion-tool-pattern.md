# Decision 0005 — Companion Tool Pattern

## Status
Accepted

## Decision
- Companion tools extend the dev workflow without modifying Repo OS core governance
- They integrate via MCP servers registered in project-level `.claude/settings.json`
- The template ships clean — no companion tools pre-configured
- Companion tools are documented in the operator guide and surfaced (not pushed) during Prompt 0
- Companion tool reference specs live in `docs/ai/references/` (informational, not governance)
