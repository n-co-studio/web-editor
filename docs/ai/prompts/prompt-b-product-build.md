# Prompt B — Product Build

Read and follow AI.md. Read all files referenced in AI.md's source-of-truth sections.

## Project Specification
Read `docs/spec/compiled/manifest.json` to find the active version. Then read all files in `docs/spec/compiled/{active}/` before planning or implementing any work:
- `product.md` — What the product is and who it's for
- `architecture.md` — Tech stack and structure
- `design-system.md` — Visual language (spacing, typography, colors, components)
- `data-contracts.md` — Data models, API contracts, state
- `features/` — Per-feature specs (inputs, outputs, UI states, edge cases)
- `integrations.md` — External services, MCP connections
- `boundaries.md` — What NOT to build, protected areas

The compiled spec is the source of truth for what to build and how it should look and behave.

If `manifest.json` has `"active": null`, specs have not been compiled yet. Instruct the operator to run Prompt 0 first.

## Prototype Learnings
Before planning new features or architectural work, check `docs/spec/prototypes/` for completed experiment briefs. Validated learnings from prototype sessions may inform architecture decisions, feature design, or spec updates.

## Operating Rules
- Use HVST (see `workflow.md`) when debugging or instability appears
- All other rules (human-led architecture, gates, decisions, small scope, session log) are defined in AI.md and enforced by the Repo OS
