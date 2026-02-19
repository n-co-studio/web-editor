# Decision 0006 — Prototyping Tiers

## Status
Accepted

## Decision
- Rapid prototyping uses the existing `experiment/*` branch category (A4 safety only, never merge to main)
- Three tiers determine documentation overhead — the operator self-selects:
  - **Napkin**: Quick test, no artifact required, verbal conclusion only
  - **Spike**: Focused hypothesis, single session, experiment brief required
  - **Proof of Concept**: Multi-session exploration, experiment brief + mini-spec notes required
- Tiers are a menu, not a gate — the system does not enforce tier selection
- Prompt 0.5 facilitates prototype sessions as a lightweight alternative to Prompt 0
- Experiment briefs are stored in `docs/spec/prototypes/` and survive branch deletion
- Only learnings are promoted from experiment branches, never code — rewrite into `feature/*` is required
- Validated PoC explorations may produce recommended spec additions or trigger new decision records
