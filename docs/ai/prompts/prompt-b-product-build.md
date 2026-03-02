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
| user-review | agent | User Review persona dispatch (skipped when brief has no User Review section) |
| commit | agent | Commit with git trailers |
| op-review | operator | Operator reviews before close (review mode only — skipped in auto) |
| close | agent | Update session log, commit, merge to main (agent runs merge — see workflow.md Close Sequence), seal branch |

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
| user-review | agent | User Review persona dispatch (skipped when brief has no User Review section) |
| commit | agent | Commit with git trailers |
| contract-update | agent | Update contract — brief status, session decisions, governance evidence |
| op-review | operator | Operator reviews (review mode only — skipped in auto) |
| close | agent | Non-final: close without merge. Final: merge to main, seal branch |

Loops: `review→build`, `verify→build`

**Task Group Merge (Brief M — parallel groups only):**

| Phase | Tag | Description |
|-------|-----|-------------|
| init | agent | Check out existing task group branch |
| contract-init | agent | Sync from contract, verify all content briefs complete (completion markers) |
| cohesion | agent | Cross-session cohesion review across combined diff from all parallel briefs |
| verify | agent | QA gate verification (A1–A6, B1–B3) |
| commit | agent | Commit with git trailers |
| op-review | operator | Operator reviews (review mode only — skipped in auto) |
| close | agent | Merge to main, seal branch |

Loops: `cohesion→cohesion` (integration fixes found during review)

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

Branches merge to main directly at session close. See `docs/ai/workflow.md` § Solo Mode and § Task Group Sessions for full merge semantics, branch type applicability, and task group branch strategy.

## Task Contract (Decision 0020)

At session init, after branch creation and spec loading, extract the task contract from the brief text:

- **Singular builds**: If the brief contains a `## Task Contract` section with a YAML code block, extract the YAML content and write it to `.claude/.state/task-contract.yaml`. If `.claude/.state/task-contract.yaml` already exists (orphan from a crashed session), delete it before writing the new one and log: "Cleaned stale task contract from previous session."
- **Task groups**: If the brief's `### Task Group` section contains a `Contract:` field, extract the contract content and write it as the `intent:` block in the task group contract YAML during the `contract-init` phase. Use the fields: `goal`, `verification`, `scope_files`, `spec_references`.
- **No contract present**: If the brief contains neither a `## Task Contract` section nor a `Contract:` field in `### Task Group`, skip contract extraction silently (backward compatibility with legacy briefs, hotfixes, etc.).

The task contract serves as the cohesion review reference — Critic uses its `verification:` criteria to evaluate whether the implementation achieves the stated intent.

## User Review Dispatch (Decision 0021)

After the `verify` phase, check whether the task brief or task contract contains a `user_review` section:

- **No User Review defined:** Skip directly from `verify` to `commit` (forward-jump — Decision 0014 permits this).
- **User Review defined:** Advance to `user-review` phase and execute the dispatch procedure:

### Dispatch Procedure

1. **Read scenario definitions** from the task contract's `user_review:` block (tiers, mode, scenarios).
2. **Dispatch selected tier agents in parallel** via the Task tool. Each agent receives:
   - Their persona profile (`.claude/agents/_user-review-tier-{N}.md`)
   - The scenario definitions (YAML from the contract)
   - The list of files modified in the build (from `git diff --name-only` against the plan baseline)
3. **Collect results** from all dispatched agents.
4. **Synthesize across tiers:**
   - Aggregate findings from all tier reports
   - Deduplicate: when multiple tiers flag the same issue, keep the finding with the highest severity
   - Severity escalation: when Tier 1 says RECOMMENDATION and Tier 3 says CRITICAL for the same issue, the synthesized severity is CRITICAL (escalate to highest)
   - Produce a single **User Review Report** with all findings ranked by severity
5. **Advance to `commit` phase.** The synthesized User Review Report is carried forward for presentation.
6. **Present User Review Report** to operator during `op-review` (or if auto mode — findings are logged in the closing summary but do not block).
7. **Operator dispositions each finding** (accept / note / dismiss) during `op-review` — same pattern as advisory board findings (Decision 0007). No state file written, no gate blocked. Deferred findings are noted in the closing summary.

### Operating Mode Exclusions

User Review dispatch is skipped in:
- Template mode (no product code to review)
- Autonomous mode (no operator for disposition)
- Headless/automation mode (no operator interaction)
- Experiment sessions (lightweight lifecycle, no `user-review` phase)

See Decision 0021 for system definition, scenario schema, and results format.

## Operating Rules
- REQUIRE: at session start, create a branch from main: `git checkout -b <category>/<description>` (standard: `feature/<description>`, hotfix: `hotfix/<description>`)
- REQUIRE: extract and write task contract at session init when present in the brief (Decision 0020). Contract serves as cohesion review reference
- REQUIRE: after Builder signals done, Orchestrator runs a cohesion review (Critic in cohesion mode) before invoking QA. Critical cohesion findings must be resolved before commit. See `quality-gates.md` gate A5.
- GUIDE: use HVST (see `workflow.md`) when debugging or instability appears. When HVST debugging stalls (2+ consecutive failures), Orchestrator dispatches HVST Review Board for multi-agent hypothesis review before further fix attempts. See `_hvst-review.md`
- REQUIRE: **Task Group Contract** — if the task brief contains a `### Task Group` section, this session is part of a multi-brief group. Read and follow the contract lifecycle in `docs/ai/workflow.md` § Task Group Sessions. See `docs/ai/quality-gates.md` gate A6 for verification requirements
- BLOCK: **Session Branch Isolation** (Decision 0013) — each session uses a dedicated branch — enforced by branch-guard.sh / branch-guard-edit.sh. After session close, the branch is sealed and must not be reused. Start a new branch for new work. Task group sessions are exempt (multi-brief groups share one branch)
- REQUIRE: include git trailers on commits per the convention in `docs/ai/workflow.md` (Session Lifecycle → Git Trailer Convention)
- REQUIRE: **Parallel Task Group Completion Marker** — if the task brief has `Execution: parallel` in `### Task Group`, write a per-brief completion marker file at session close: `.claude/.state/tg-{group}-brief-{seq}.complete` (content: ISO 8601 timestamp). This signals to the merge brief that this content brief has completed
- REQUIRE: **Parallel Task Group Boundaries** — parallel briefs MUST restrict edits to files within their declared `Boundaries`. Edits outside boundaries require explicit operator approval. Shared files (e.g., index files, config) are owned by the merge brief
- All other rules (human-led architecture, gates, decisions, small scope, session log) are defined in AI.md and enforced by the Repo OS