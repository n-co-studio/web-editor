# Prompt A — Repo OS Initialization & Advisory Review

Read and follow AI.md. Read all files referenced in AI.md's source-of-truth sections.

**Scope**: Initialize, validate, or update the Repo OS. Review specs via Advisory Board. No product code.

## Mode Selection (mandatory — do not proceed without operator choice)

Present the two modes and wait for the operator to choose one. Do not begin any phase until a mode is explicitly selected.

- **Initialize** — First run, or major spec rewrite. Runs full advisory review (Phases 1 → 2 → 3). Use after Prompt 0 completes for the first time or after a significant spec overhaul.
- **Re-initialize** — Repeat run after build has started. Skips advisory review, goes straight to validation (Phase 3 only). Use after agent drift, decision conflicts, template sync updates, or mid-build spec changes where specs have already been reviewed.

REQUIRE: do not proceed to any phase before the operator selects a mode.

### Phase Sequences

Phase sequences are defined in `_agent-glossary.md` § Phase Model and enforced by `_phase-helper.sh`. See Decision 0014 for canonical definitions. Initialize: `init → tier-select → dispatch → synthesize → op-review → validate → governance → close`. Re-initialize: `init → validate → governance → close`.

After mode selection, build your task list to match the selected mode:
- **Initialize**: Phase 1 (advisory review) → Phase 2 (operator review) → Phase 3 (validation)
- **Re-initialize**: Phase 3 (validation) only

## Phase 1 — Advisory Board Review (Initialize mode only)

Run after Prompt 0 completes (spec or feature brief is ready). Skip this phase if `manifest.json` has `"active": null` (no spec yet). Skip entirely in Re-initialize mode.

1. Read `docs/spec/compiled/manifest.json` to find the active version
2. **Orchestrator loads full specs for activation signal scanning** — read all compiled spec files in `docs/spec/compiled/{active}/`. Tier selection and conditional specialist activation require full fidelity; selective loading does NOT apply to the Orchestrator's own reads in Phase 1 (Decision 0035)
3. Read `.claude/agents/_advisory-board.md` for tier definitions, activation logic, and report format; selective context per specialist mapping is defined there
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
   - **Feature brief:** Use "What It Touches" checkboxes as activation signals
6. Dispatch activated specialists in parallel
7. Collect specialist briefs

## Phase 2 — Operator Review (Initialize mode only)

Skip entirely in Re-initialize mode.

1. Synthesize specialist briefs into a single Refinement Report (see `_advisory-board.md` format)
2. Present to operator organized as:
   - **Critical Findings** — must address before build
   - **Recommendations** — operator decides
   - **Ideas** — from Exploration and nice-to-haves
   - **Activation Summary** — which specialists ran and why
3. Operator reviews each item: Accept / Reject / Defer
4. For accepted items: note what changes to make (spec updates, new constraints, follow-ups)
5. If PM Advisory ran and included spec-edit proposals: present each proposal to the operator (accept / reject / defer). For accepted proposals, execute the edit using Edit tool (Orchestrator writes on behalf of PM). Record outcomes in session log
6. All Critical findings must be addressed (accepted or explicitly rejected with reason) before proceeding

## Phase 3 — Repo OS Validation (both modes)

Silently validate:
- Agent roles and responsibilities are defined
- Workflow rules and sequencing are consistent
- Gate enforcement behavior is configured
- Project-specific conditional gates (if any) are coherent

If all checks pass: confirm "Repo OS ready" and output a handoff block (see Session Handoff Convention in `workflow.md`):

~~~
[Project or Feature Name] Build — Prompt B

Follow docs/ai/prompts/prompt-b-product-build.md.
~~~

If a task brief exists, instruct the operator to append it.

If issues found: list only the problems, propose fixes, and wait for operator approval before confirming readiness.

## Knowledge Graph Seeding (Decision 0034)

There is no template knowledge graph to seed: `graph.yaml` and its governance seeding were retired (Decision 0034 Amendment 9). Prompt A does not create any graph.

- Do NOT create `product-graph.yaml` in the template repo. A child repo creates its own with `.claude/tools/kg-seed.sh --target product` (it refuses to overwrite an existing graph), describes the seeded nodes, and declares what the commit gate should hold it to in `docs/ai/knowledge-graph/coverage.yaml` — see `docs/ai/knowledge-graph/README.md`.

## Governance Evidence

After Phase 3 validation passes ("Repo OS ready"), write a governance evidence file at `docs/ai/governance/advisory-reviewed`:

```
timestamp: <ISO 8601 UTC>
session: <current session number>
spec_version: <active version from manifest.json>
review_tier: <lite | standard | full | skip>
mode: <initialize | re-initialize>
status: complete
```

This file is committed and read by subsequent Prompt B sessions as inter-session governance proof.

**`spec_version` is load-bearing** (Decision 0041): Prompt B, `pre-commit-gates.sh` Gate 3, and `bash-guard.sh` Phase 1d evaluate `spec_version == manifest.json.active` to fast-skip the governance warning. Write the literal active version string, not a placeholder. When `manifest.json.active` is `null` (template-mode / pre-spec state), write `spec_version: null` so the predicate matches.

## Rules

- REQUIRE: **never use the Agent tool with write-capable subagent types** (builder, qa-verifier, security-privacy, general-purpose, reviewer) or request worktree isolation. Only read-only advisory agents are permitted.

## Close Sequence

At close: update session log, commit all changes (including governance evidence), present closing summary. See `docs/ai/workflow.md` Close Sequence.
