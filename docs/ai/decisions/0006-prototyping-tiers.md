# Decision 0006 — Prototyping Tiers

## Status
Accepted

## Triggers

- type: file
- path: `docs/ai/prompts/prompt-0\.5`
- path: `docs/spec/_templates/_experiment`
- keywords: `experiment, prototype, napkin, spike, prototype-napkin, prototype-spike, prototype-poc`

## Context
The standard build workflow (plan → build → verify → commit) is too heavyweight for exploratory work. Prototyping needs a lighter path that preserves safety (A4) while removing process overhead, with clear guardrails preventing experimental code from reaching main.

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
- **Phase sequences** (Decision 0014): Napkin `init→build→close`, Spike `init→build→evaluate→close`, PoC `init→build→evaluate→document→close`. Session types: `prototype-napkin`, `prototype-spike`, `prototype-poc`

## Consequences
- `docs/ai/prompts/prompt-0.5-prototype.md` added as a lightweight alternative to the full Prompt 0 → A → B pipeline
- `docs/spec/prototypes/` directory stores experiment briefs that persist after branch deletion
- `experiment/*` branches are excluded from merge to main (enforced by Decision 0015's solo mode) — code must be rewritten into `feature/*`
