# Decision 0002 — Decisions Are Mandatory (Commit-Blocking)

## Status
Accepted

## Triggers

- type: file
- path: `docs/ai/decisions/.*\.md`
- keywords: `mandatory, commit-blocking`

## Context
Without mandatory enforcement, decision records become advisory documentation that agents can silently ignore. Making decisions commit-blocking ensures architectural choices are respected mechanically, not just by convention.

## Decision
- Accepted decisions in `docs/ai/decisions/` are **mandatory**
- For any change, applicable decisions must be identified and followed
- Conflicts → propose new decision record before proceeding
- **Decision violations block commits** (and therefore pushes)

## Consequences
- Gate A1 enforces decision compliance mechanically via the trigger parser (Decision 0004)
- New decisions must be proposed before proceeding when conflicts arise — agents cannot silently override existing decisions
- The `Decisions:` git trailer on commits creates a permanent record of which decisions applied to each change
