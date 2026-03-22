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
| review | **Critic** (cohesion mode) + **PM Advisory** (spec-drift) | REQUIRE: dispatch Critic before advancing to verify phase. Parallel dispatch. Critic checks internal coherence; PM checks spec alignment. PM is conditional — requires compiled spec or `mvp-scope.yaml` (skipped silently otherwise). PM findings are advisory (not gating) |
| verify | QA Verifier | REQUIRE: dispatch before advancing to commit phase. Commit blocker (A1–A6, B1–B3) |
| user-review | User Review Tier agents | Optional — skipped when no User Review in brief |
| commit | Orchestrator | Commit with trailers |

Loops: `review→build` (cohesion findings), `verify→build` (QA failure).

### Auto/Review Mode

When presenting the plan for approval, include **auto** and **review** as options:
- **Auto** — agent completes through merge autonomously after all gates pass. The `op-review` phase is skipped.
- **Review** — agent pauses after verify for operator review before commit. Default.

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

## Operating Rules
- REQUIRE: at session start, create a branch from main: `git checkout -b <category>/<description>` (standard: `feature/<description>`, hotfix: `hotfix/<description>`)
- REQUIRE: extract and write task contract at session init when present in the brief (Decision 0020). Contract serves as cohesion review reference
- REQUIRE: after Builder signals done, Orchestrator runs a cohesion review (Critic in cohesion mode) before invoking QA. Critical cohesion findings must be resolved before commit. See `quality-gates.md` gate A5.
- GUIDE: use HVST (see `_agent-glossary.md` § HVST) when debugging or instability appears. When HVST debugging stalls (2+ consecutive failures), Orchestrator dispatches HVST Review Board for multi-agent hypothesis review before further fix attempts. See `_hvst-review.md`
- REQUIRE: **Task Group Contract** — if the task brief contains a `### Task Group` section, this session is part of a multi-brief group. Read and follow the contract lifecycle in `docs/ai/workflow-appendix/session-type-task-group.md`. See `docs/ai/quality-gates.md` gate A6 for verification requirements
- BLOCK: **Session Branch Isolation** (Decision 0013) — each session uses a dedicated branch — enforced by bash-guard.sh / write-guard.sh (Section 3). After session close, the branch is sealed and must not be reused. Start a new branch for new work. Task group sessions are exempt (multi-brief groups share one branch)
- REQUIRE: include git trailers on commits per the convention in `docs/ai/workflow.md` (Session Lifecycle → Git Trailer Convention)
- REQUIRE: **Parallel Task Group Completion Marker** — if the task brief has `Execution: parallel` in `### Task Group`, write a per-brief completion marker file at session close: `.claude/.state/tg-{group}-brief-{seq}.complete` (content: ISO 8601 timestamp). This signals to the merge brief that this content brief has completed
- REQUIRE: **Parallel Task Group Boundaries** — parallel briefs MUST restrict edits to files within their declared `Boundaries`. Edits outside boundaries require explicit operator approval. Shared files (e.g., index files, config) are owned by the merge brief
- REQUIRE: **Pragmatist Plan-Gating** (Decision 0025) — Pragmatist must be dispatched before presenting plan to operator. `pragmatist-signed` state file is verified at commit time by `pre-commit-gates.sh`. `advance_phase()` enforces `plan-approved` substance check before the post-approval phase transition. `init_phase()` blocks re-initialization for the same session (override: `REPO_OS_ALLOW_REINIT=1`). Session close runs forensic check on `phases_completed` to detect force-advance violations
- REQUIRE: **Session Log Ordering** — session log must be the last file modified before the close-phase commit. Do not commit the session log before implementation work is complete, and do not modify it after the final commit
- All other rules (human-led architecture, gates, decisions, small scope, session log) are defined in AI.md and enforced by the Repo OS