# Decision 0005 — Companion Tool Pattern

## Status
Accepted

## Triggers

- type: file
- keywords: `companion, MCP`
<!-- paths: project-specific — downstream repos add path patterns for their companion tool files -->

## Context
Projects need external tooling (linters, formatters, domain-specific utilities) but integrating them directly into Repo OS governance would create tight coupling and template maintenance burden. MCP server registration provides a clean extension point that keeps governance and tooling independent.

## Decision
- Companion tools extend the dev workflow without modifying Repo OS core governance
- They integrate via MCP servers registered in project-level `.claude/settings.json`
- The template ships clean — no companion tools pre-configured
- Companion tools are documented in the operator-facing HTML explainer and surfaced (not pushed) during Prompt 0

## Consequences
- The template ships with no MCP servers in `settings.json` — downstream projects add their own
- Companion tools cannot modify governance files (enforced by Decision 0012's mode guard)
- Tool integration is project-specific and does not sync back to the template
