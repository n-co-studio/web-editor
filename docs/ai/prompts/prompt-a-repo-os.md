# Prompt A — Repo OS Initialization & Advisory Review

Read and follow AI.md. Read all files referenced in AI.md's source-of-truth sections.

**Scope**: Initialize, validate, or update the Repo OS. Review specs via Advisory Board. No product code.

## Phase 1 — Advisory Board Review

Run after Prompt 0 completes (spec or feature brief is ready). Skip this phase if `manifest.json` has `"active": null` (no spec yet).

1. Read `docs/spec/compiled/manifest.json` to find the active version
2. Read all compiled spec files in `docs/spec/compiled/{active}/`
3. Read `.claude/agents/_advisory-board.md` for tier definitions, activation logic, and report format
4. **Select review tier** (operator can override):
   - Feature brief → **Lite** (Architect + Critic)
   - Full compiled spec → **Standard** (+ Exploration)
   - Operator requests full board or spec touches 3+ signal categories → **Full** (+ conditional specialists)
   - Single-file fix or docs-only → **Skip**
5. At Full tier, scan specs for conditional activation signals:
   - Auth/sessions/OAuth/tokens/permissions → Security Analyst
   - UI/design-system/user-flows/forms/components → UX Strategist
   - Real-time/websockets/large-data/media/streaming → Performance Engineer
   - Database/data-contracts/migrations/schema/GDPR → Data Strategist
   - **Feature mode:** Use "What It Touches" checkboxes as activation signals
6. Dispatch activated specialists in parallel
7. Collect specialist briefs

## Phase 2 — Operator Review

1. Synthesize specialist briefs into a single Refinement Report (see `_advisory-board.md` format)
2. Present to operator organized as:
   - **Critical Findings** — must address before build
   - **Recommendations** — operator decides
   - **Ideas** — from Exploration and nice-to-haves
   - **Activation Summary** — which specialists ran and why
3. Operator reviews each item: Accept / Reject / Defer
4. For accepted items: note what changes to make (spec updates, new constraints, follow-ups)
5. All Critical findings must be addressed (accepted or explicitly rejected with reason) before proceeding

## Phase 3 — Repo OS Validation

Define or confirm:
- Agent roles and responsibilities
- Workflow rules and sequencing
- Gate enforcement behavior
- Project-specific conditional gates (if needed)

Before changes: summarize current state → propose changes → wait for operator approval.

Confirm "Repo OS ready" when complete, then instruct operator to proceed to Prompt B.
