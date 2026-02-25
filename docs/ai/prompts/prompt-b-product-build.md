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

## Inter-Session Governance
At session start, check `docs/ai/governance/` for governance evidence:
- `spec-compiled` — confirms Prompt 0 completed. If missing, warn operator.
- `advisory-reviewed` — confirms Prompt A completed. If missing, warn operator.

These are advisory checks. The operator may direct you to proceed without them (e.g., for standalone tasks not tied to a spec). The `pre-commit-gates.sh` hook also checks for these files at commit-time (advisory, first-fire). On Bash writes, `branch-guard.sh` checks them as well.

## Operating Rules
- After Builder signals done, Orchestrator runs a cohesion review (Critic in cohesion mode) before invoking QA. Critical cohesion findings must be resolved before commit. See `quality-gates.md` gate A5.
- Use HVST (see `workflow.md`) when debugging or instability appears. When HVST debugging stalls (2+ consecutive failures), Orchestrator dispatches HVST Review Board for multi-agent hypothesis review before further fix attempts. See `_hvst-review.md`
- **Task Group Contract** — If the task brief contains a `### Task Group` section, this session is part of a multi-brief group. Contract path depends on repo mode (template mode: `.claude/local/task-groups/{group-name}.yaml`; product mode: `docs/ai/task-groups/{group-name}.yaml`):
  - **First session** (no contract file exists): Create the contract file from brief metadata, following `docs/ai/task-groups/_contract-template.yaml`. Populate identity, brief roster, conventions (naming/patterns/decisions/boundaries discovered during planning), and integration points
  - **Subsequent sessions** (contract file exists): Read the contract at session start. Conventions are REQUIRE-level constraints — follow all naming patterns, architectural patterns, decisions, and module boundaries. Read `session_decisions` for context from prior sessions
  - **At session close**: Update the contract — mark this brief's status as `complete`, set session number and branch, append any new session decisions. If this is not the last brief, confirm `next_brief` is set. Append a `governance:` entry for the current brief recording gate results (A1-A6, B1-B3), any overrides used, and a timestamp — this enables phase chain verification by subsequent sessions
  - **Standalone sessions** (no `### Task Group` section in brief): No contract-related behavior. Skip entirely
  - See `docs/ai/quality-gates.md` gate A6 for verification requirements
- **Session Branch Isolation** (Decision 0013) — Each session uses a dedicated branch. After session close, the branch is sealed and must be merged via PR. Start a new branch for new work. Task group sessions are exempt
- Include git trailers on commits per the convention in `docs/ai/workflow.md` (Session Lifecycle → Git Trailer Convention)
- All other rules (human-led architecture, gates, decisions, small scope, session log) are defined in AI.md and enforced by the Repo OS
