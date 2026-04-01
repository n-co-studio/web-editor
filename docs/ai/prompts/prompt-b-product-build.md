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

These are advisory checks. The operator may direct you to proceed without them (e.g., for standalone tasks not tied to a spec). The `pre-commit-gates.sh` hook also checks for these files at commit-time (advisory, first-fire). On Bash writes, `bash-guard.sh` checks them as well.

## Phase Model

The phase model tracks session progress in `.claude/.state/phase-state`. Hooks enforce phase-appropriate actions. You do not need to read this file — hooks manage it automatically. Phase sequences are defined in `_agent-glossary.md` § Phase Model and enforced by `_phase-helper.sh`. See Decision 0014 for canonical definitions.

**Ephemeral sessions**: When the user's intent is Q&A or exploration (no code changes expected), use `init_phase "ephemeral"` instead of `"standard"`. Ephemeral sessions have a minimal phase sequence (`init → conversation → close`) and skip mode-guard, bash-guard branch gates, and close checks. If the user later requests edits, call `upgrade_session_type` to convert to standard (resets phase to `plan`).

### Build Sequence — Agent Dispatch

| Phase | Agent | Notes |
|-------|-------|-------|
| plan | **Pragmatist** (plan-gating mode) | REQUIRE dispatch before presenting plan to operator. Foreground preferred (ensures verdict available before plan presentation; background supported but may complete during build). Passes plan text inline in Task prompt. GATE_RESULT: BLOCKED (FUNDAMENTAL-MISMATCH) or APPROVED. Findings and verdict presented alongside plan to operator. Auto mode: BLOCKED degrades to advisory-with-warning (Decision 0025) |
| build | Builder | Implements changes |
| review | **Critic** (cohesion mode) + **PM Advisory** (spec-drift) + **UX Design Agent** (Mode 2 + Mode 3) | REQUIRE: dispatch Critic before advancing to verify phase. Parallel dispatch. Critic checks internal coherence; PM checks spec alignment. PM is conditional — requires compiled spec or `mvp-scope.yaml` (skipped silently otherwise). PM findings are advisory (not gating). UX Design Agent is conditional — dispatched when the task brief contains design brief content or the implementation includes UI changes; see UX Post-Build Review below |
| verify | QA Verifier | REQUIRE: dispatch before advancing to commit phase. Commit blocker (A1–A6, B1–B3) |
| user-review | User Review Tier agents | Optional — skipped when no User Review in brief |
| commit | Orchestrator | Commit with trailers |

Loops: `review→build` (cohesion findings), `verify→build` (QA failure).

### Auto/Review Mode

When presenting the plan for approval, include **auto** and **review** as options:
- **Auto** — agent completes through merge autonomously after all gates pass. The `op-review` phase is skipped.
- **Review** — agent pauses after verify for operator review before commit. Default.

See `orchestrator.md` § Constraints for the canonical AskUserQuestion plan approval template and hook contract annotations.

The mode is set at plan approval and recorded in phase-state.

### Solo Mode (Decision 0015)

Branches merge to main directly at session close. See `.claude/agents/_agent-glossary.md` § Solo Mode for full merge semantics and branch type applicability, and `docs/ai/workflow-appendix/session-type-task-group.md` for task group branch strategy.

## Task Contract (Decision 0020)

At session init, after branch creation and spec loading, extract the task contract from the brief text:

- **Singular builds**: If the brief contains a `### Task Contract` section with a YAML code block, extract the YAML content and write it to `.claude/local/task-contract.yaml`. The task contract is embedded inside the brief template (not a separate block). If `.claude/local/task-contract.yaml` already exists (orphan from a crashed session), delete it before writing the new one and log: "Cleaned stale task contract from previous session."
- **Task groups**: If the brief's `### Task Group` section contains a `Contract:` field, extract the contract content and write it as the `intent:` block in the task group contract YAML during the `contract-init` phase. Use the fields: `goal`, `verification`, `scope_files`, `spec_references`.
- **No contract present**: If the brief contains neither a `### Task Contract` section nor a `Contract:` field in `### Task Group`, skip contract extraction silently (backward compatibility with legacy briefs, hotfixes, etc.).

The task contract serves as the cohesion review reference — Critic uses its `verification:` criteria to evaluate whether the implementation achieves the stated intent.

## User Review Dispatch (Decision 0021)

After the `verify` phase, check whether the task brief or task contract contains a `user_review` section:

- **No User Review defined:** Skip directly from `verify` to `commit` (forward-jump — Decision 0014 permits this).
- **User Review defined:** Advance to `user-review` phase and dispatch per `.claude/agents/_agent-glossary.md` § User Review.

### Dispatch Procedure

1. Read scenario definitions from the task contract's `user_review:` block.
2. Dispatch selected tier agents (`.claude/agents/_user-review-tier-{N}.md`) in parallel via Task tool. Each receives: persona profile, scenario YAML, list of modified files (`git diff --name-only`).
3. Collect results, deduplicate across tiers, escalate severity to highest when tiers conflict.
4. Produce a single User Review Report, advance to `commit`. Present during `op-review` (auto mode: logged in closing summary). Operator dispositions each finding (accept / note / dismiss).

See `.claude/agents/_agent-glossary.md` § User Review for full system definition and Decision 0021 for scenario schema.

## UX Post-Build Review

After Builder completes, during the `review` phase, dispatch the UX Design Agent when the task involves UI changes:

### Activation Conditions

Dispatch when ANY of:
- The task brief contains a `## Design Brief` section (from Mode 1 output in Prompt T)
- The implementation diff includes UI files (`.tsx`, `.jsx`, `.vue`, `.svelte`, `.html`, CSS/SCSS files, component files)
- The task brief mentions UI, screens, pages, components, layouts, forms, or dashboards

Skip silently when none of the above conditions are met.

### Dispatch Sequence

1. **Mode 2 (UX Review):** Dispatch alongside Critic and PM Advisory (parallel). Receives: task brief, design brief (if present), list of modified files, implementation diff. Produces advisory findings with standard severity labels (CRITICAL / RECOMMENDATION / IDEA).

2. **Mode 3 (Design Health):** Dispatch after Mode 2 completes, or in parallel with Critic when Mode 2 is not activated. Receives: list of modified files, implementation diff. Produces compliance findings with design health labels (TOKEN-VIOLATION / COMPONENT-BYPASS / SYSTEM-DRIFT). Mode 3 auto-detects whether a design system exists — if none exists, it recommends establishing one rather than flagging violations.

### Integration with Review Phase

- UX findings are advisory — they do not block commit (same enforcement level as cohesion review)
- Critical UX findings (CRITICAL severity from Mode 2, or high-count TOKEN-VIOLATION/COMPONENT-BYPASS from Mode 3) should be presented to the operator alongside Critic and PM findings
- If critical UX findings exist, the `review→build` loop applies (same as cohesion findings)
- Design Health findings are informational — present in the review summary but do not trigger the review→build loop unless the operator requests fixes

## Knowledge Graph Updates (Decision 0034)

When `docs/ai/knowledge-graph/graph.yaml` exists, the Builder participates in the knowledge graph lifecycle:

### Graph-First File Discovery
When you need to discover which files are affected by your changes, consult the knowledge graph context first. At build phase entry, `_phase-helper.sh` automatically runs `kg-relevance.sh` and writes pre-computed relevance-scored connections to `.claude/.state/kg-relevance-context`. Read this file before running broad codebase searches.

Use grep/glob search only for:
- Files not yet in the knowledge graph
- Connections the graph doesn't cover (e.g., string literals, configuration values)
- Verifying graph edges you suspect are stale

When you discover connections not in the graph, note them for graph update at close.

### During Build
As you work, note connections you discover between files — governance relationships, dependencies, data flow, test coverage. These will be written to the knowledge graph at close.

### At Close (before commit)
Update `docs/ai/knowledge-graph/graph.yaml` via shell I/O (Bash redirection — not Edit/Write tools) with:
- New nodes for files you created (type matches: `file`, `decision`, `hook`, `prompt`, `contract`, `concept`, `convention`)
- New edges for connections you discovered (use `source_type: agent-inferred`, `status: active`, `confidence: 0.7` for connections verified during this session)
- Updated `last_verified` dates for existing edges you traversed and confirmed
- Edge types are limited to the 8-type taxonomy: `governs`, `constrains`, `implements`, `depends-on`, `produces`, `consumes`, `tests`, `supersedes`

Use `mkdir`-based locking per Decision 0034 before writing (acquire: `mkdir docs/ai/knowledge-graph/.graph-lock 2>/dev/null`; release: `rmdir docs/ai/knowledge-graph/.graph-lock`). Operator-curated edges (`source_type: operator-curated`) are never modified by agents.

Graph updates are **advisory** — if the graph write fails (lock contention, parse error), the session still commits normally. Do not block the close sequence on graph update failures.

## Operating Rules
- REQUIRE: at session start, create a branch from main: `git checkout -b <category>/<description>` (standard: `feature/<description>`, hotfix: `hotfix/<description>`)
- REQUIRE: extract and write task contract at session init when present in the brief (Decision 0020). Contract serves as cohesion review reference
- REQUIRE: after Builder signals done, Orchestrator runs a cohesion review (Critic in cohesion mode) before invoking QA. Critical cohesion findings must be resolved before commit. See `quality-gates.md` gate A5.
- GUIDE: use HVST (see `_agent-glossary.md` § HVST) when debugging or instability appears. When HVST debugging stalls (2+ consecutive failures), Orchestrator dispatches HVST Review Board for multi-agent hypothesis review before further fix attempts. See `_hvst-review.md`
- REQUIRE: **Task Group Contract** — if the task brief contains a `### Task Group` section, this session is part of a multi-brief group. Read and follow the contract lifecycle in `docs/ai/workflow-appendix/session-type-task-group.md`. See `docs/ai/quality-gates.md` gate A6 for verification requirements
- BLOCK: **Session Branch Isolation** (Decision 0013) — each session uses a dedicated branch — enforced by bash-guard.sh / write-guard.sh (Section 3). After session close, the branch is sealed and must not be reused. Start a new branch for new work. Task group sessions are exempt (sequential groups share one branch; parallel groups use per-brief worktree branches — see Decision 0032)
- REQUIRE: include git trailers on commits per the convention in `docs/ai/workflow.md` (Session Lifecycle → Git Trailer Convention)
- REQUIRE: **Parallel Task Group Completion Marker** — if the task brief has `Execution: parallel` in `### Task Group`, write a per-brief completion marker file at session close: `$_REPO_OS_ROOT/.claude/.state/tg-{group}-brief-{seq}.complete` (content: ISO 8601 timestamp). Use the shared `$_REPO_OS_ROOT/.claude/.state/` path explicitly (not the per-session state directory from `get_session_state_dir()`), so the merge brief can find markers regardless of worktree state directory scoping (Decision 0032). This signals to the merge brief that this content brief has completed
- REQUIRE: **Parallel Task Group Boundaries** — parallel briefs MUST restrict edits to files within their declared `Boundaries`. Edits outside boundaries require explicit operator approval. Shared files (e.g., index files, config) are owned by the merge brief
- REQUIRE: **Pragmatist Plan-Gating** (Decision 0025) — Pragmatist must be dispatched before presenting plan to operator. `pragmatist-signed` state file is verified at commit time by `pre-commit-gates.sh`. `advance_phase()` enforces `plan-approved` substance check before the post-approval phase transition. `init_phase()` blocks re-initialization for the same session (override: `REPO_OS_ALLOW_REINIT=1`). Session close runs forensic check on `phases_completed` to detect force-advance violations
- REQUIRE: **Session Log Ordering** — session log must be the last file modified before the close-phase commit. Do not commit the session log before implementation work is complete, and do not modify it after the final commit
- All other rules (human-led architecture, gates, decisions, small scope, session log) are defined in AI.md and enforced by the Repo OS

## Integration Test Requirement

When the task brief modifies a pipeline or multi-stage system, the Builder MUST execute a full lifecycle integration test before signaling completion.

### Activation

This requirement activates when ANY of:
- The brief's `scope_files` touch more than one stage of a known pipeline (e.g., `runner.sh` + `branch-manager.sh`, or store + component + IPC, or intake → queue → session → merge)
- The brief explicitly includes an `### Integration Test` section
- The Architect or Pragmatist flagged the change as cross-stage during planning

### What the Integration Test Must Define

The brief (or the Orchestrator during planning) must specify:
1. **Full lifecycle** — the end-to-end flow to test (e.g., "branch creation → session launch → commit → merge → cleanup")
2. **Concrete steps** — executable actions the Builder must perform after implementation to verify the full pipeline works, not just the individual stage
3. **Expected outcomes** — what success looks like at each stage boundary (e.g., "merge completes without conflict", "state file is cleaned up")

### Enforcement

- REQUIRE: if the brief touches a pipeline, the Builder must run the full integration test flow before signaling done. Individual unit-level verification is not sufficient
- REQUIRE: integration test results must be included in the Builder's completion signal so the Critic and QA verifier can evaluate pipeline health
- GUIDE: when the Orchestrator drafts the plan, it should identify pipeline boundaries and pre-populate the integration test steps. If the brief omits them, the Orchestrator adds them during planning