# Decision 0002 — Decisions Are Mandatory (Commit-Blocking)

## Status
Accepted

## Context
Process and safety constraints must be enforceable, not optional.
Without enforcement, decision records degrade into suggestions and are ignored over time.

## Decision
- Accepted decisions in `docs/ai/decisions/` are **mandatory**.
- For any change, applicable decisions must be identified and followed.
- If a decision conflicts with needed work, a new decision must be proposed before proceeding.
- **Decision violations block commits** (and therefore pushes).

## Consequences
- Decisions function as binding constraints ("laws") for both operator and agents.
- Enforcement occurs through:
  - Prompt compliance requirements
  - Gates that treat decision violations as failures
  - Session logging that records decisions applied per session
