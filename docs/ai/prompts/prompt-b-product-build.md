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

## Phase Model

The phase model tracks session progress in `.claude/.state/phase-state`. Hooks enforce phase-appropriate actions. You do not need to read this file — hooks manage it automatically. See Decision 0014 for canonical phase definitions.

### Phase Sequences

**Standard Build:**

| Phase | Tag | Description |
|-------|-----|-------------|
| init | agent | Create branch from main, load spec and governance context |
| plan | agent | Define goal, scope, files, verification steps |
| approval | operator | Operator reviews and approves the plan |
| build | agent | Implement changes in small increments |
| review | agent | Critic cohesion review of diff |
| verify | agent | QA gate verification (A1–A6, B1–B3) |
| commit | agent | Commit with git trailers |
| op-review | operator | Operator reviews before close (review mode only — skipped in auto) |
| close | agent | Merge branch to main, seal branch, update session log |

Loops: `review→build` (cohesion findings), `verify→build` (QA failure)

**Task Group (Brief N of M):**

| Phase | Tag | Description |
|-------|-----|-------------|
| init | agent | Create branch (brief 1) or check out existing branch (briefs 2+) |
| contract-init | agent | Create contract (brief 1) or sync from contract (briefs 2+) |
| plan | agent | Define goal, scope, files, verification steps |
| approval | operator | Operator reviews plan (auto-passes for pre-approved groups) |
| build | agent | Implement changes in small increments |
| review | agent | Critic cohesion review of diff |
| verify | agent | QA gate verification (A1–A6, B1–B3) |
| commit | agent | Commit with git trailers |
| contract-update | agent | Update contract — brief status, session decisions, governance evidence |
| op-review | operator | Operator reviews (review mode only — skipped in auto) |
| close | agent | Non-final: close without merge. Final: merge to main, seal branch |

Loops: `review→build`, `verify→build`

**Hotfix:**

| Phase | Tag | Description |
|-------|-----|-------------|
| init | agent | Create branch from main (`hotfix/<description>`) |
| plan | agent | Define goal, scope, files, verification steps |
| approval | operator | Operator reviews and approves the plan |
| build | agent | Implement the fix |
| verify | agent | QA gate verification (A2 scope relaxed, A5 skipped) |
| commit | agent | Commit with git trailers |
| close | agent | Merge branch to main, seal branch |

Loops: `verify→build`

**Experiment:**

| Phase | Tag | Description |
|-------|-----|-------------|
| init | agent | Create or check out experiment branch |
| build | agent | Build directly — no plan required |
| commit | agent | Commit (A4 safety only) |
| close | agent | Close session, no merge to main |

### Auto/Review Mode

When presenting the plan for approval, include **auto** and **review** as options:
- **Auto** — agent completes through merge autonomously after all gates pass. The `op-review` phase is skipped.
- **Review** — agent pauses after verify for operator review before commit. Default.

The mode is set at plan approval and recorded in phase-state.

### Solo Mode (Decision 0015)

Solo mode enables direct merge to main at session close, replacing PR-based merge:
- Branch created from `main` at init phase: `git checkout -b <category>/<description>`
- At close (auto): merge branch to main directly, then seal branch
- At close (review): agent pauses at `op-review` for operator acceptance, then merges on acceptance
- Merge failure: `git merge --abort`, notify operator with conflict details. Agent does not attempt automatic conflict resolution on main

**Task group branch strategy**: One branch per group. Brief 1 creates the branch. Briefs 2 through N-1 commit and close without merge. Brief N (final) merges to main and seals the branch.

## Operating Rules
- At session start, create a branch from main: `git checkout -b <category>/<description>` (standard: `feature/<description>`, hotfix: `hotfix/<description>`)
- After Builder signals done, Orchestrator runs a cohesion review (Critic in cohesion mode) before invoking QA. Critical cohesion findings must be resolved before commit. See `quality-gates.md` gate A5.
- Use HVST (see `workflow.md`) when debugging or instability appears. When HVST debugging stalls (2+ consecutive failures), Orchestrator dispatches HVST Review Board for multi-agent hypothesis review before further fix attempts. See `_hvst-review.md`
- **Task Group Contract** — If the task brief contains a `### Task Group` section, this session is part of a multi-brief group. Contract path depends on repo mode (template mode: `.claude/local/task-groups/{group-name}.yaml`; product mode: `docs/ai/task-groups/{group-name}.yaml`):
  - **First session** (no contract file exists): Create the contract file from brief metadata, following `docs/ai/task-groups/_contract-template.yaml`. Populate identity, brief roster, conventions (naming/patterns/decisions/boundaries discovered during planning), and integration points
  - **Subsequent sessions** (contract file exists): Read the contract at session start. Conventions are REQUIRE-level constraints — follow all naming patterns, architectural patterns, decisions, and module boundaries. Read `session_decisions` for context from prior sessions
  - **At session close**: Update the contract — mark this brief's status as `complete`, set session number and branch, append any new session decisions. If this is not the last brief, confirm `next_brief` is set. Append a `governance:` entry for the current brief recording gate results (A1-A6, B1-B3), any overrides used, and a timestamp — this enables phase chain verification by subsequent sessions
  - **Standalone sessions** (no `### Task Group` section in brief): No contract-related behavior. Skip entirely
  - See `docs/ai/quality-gates.md` gate A6 for verification requirements
- **Session Branch Isolation** (Decision 0013) — Each session uses a dedicated branch. After session close, the branch is sealed and must not be reused. Start a new branch for new work. Task group sessions are exempt (multi-brief groups share one branch)
- Include git trailers on commits per the convention in `docs/ai/workflow.md` (Session Lifecycle → Git Trailer Convention)
- All other rules (human-led architecture, gates, decisions, small scope, session log) are defined in AI.md and enforced by the Repo OS