# Prompt B — Product Build

Read and follow AI.md. Read all files referenced in AI.md's source-of-truth sections.

## Project Specification

Read `docs/spec/compiled/manifest.json` to find the active version.

**Selective spec loading (Decision 0035):** When compiled specs exist, use task-scoped loading based on the `### Spec References` section of the task brief:

1. **When `### Spec References` is present in the brief:**
   - Read `DIGEST.md` (if it exists at `docs/spec/compiled/{active}/DIGEST.md`) for orientation
   - Read the full text of each spec file explicitly listed in `### Spec References`
   - Verify `DIGEST.md` provenance: check that `spec_version` in DIGEST.md matches `manifest.json` `active`. If they differ, fall back to full spec loading
   - **Feature discovery — four-step fallback chain (Decision 0035):**
     1. Explicit reference in `### Spec References` section of this brief
     2. Knowledge graph relevance (`kg-relevance.sh`) when product graph exists with spec-feature nodes
     3. Keyword match between task scope and `manifest.json` `features[].scope_modules`
     4. When none of the above produces results AND the knowledge graph does not exist: load all feature briefs

2. **When `### Spec References` is absent** (legacy briefs, hotfixes, or pre-digest sessions):
   - Fall back to full spec loading — read all files in `docs/spec/compiled/{active}/`
   - This is the backward-compatible path; no regression in behavior

3. **When `manifest.json` has `"active": null`**: specs have not been compiled yet. Instruct the operator to run Prompt 0 first.

The compiled spec remains the source of truth. `DIGEST.md` is a derived artifact — when digest and spec conflict, spec wins.

Full spec file list for reference (used in fallback or when explicitly referenced):
- `product.md` — What the product is and who it's for
- `architecture.md` — Tech stack and structure
- `design-system.md` — Visual language (spacing, typography, colors, components)
- `data-contracts.md` — Data models, API contracts, state
- `features/` — Per-feature specs (inputs, outputs, UI states, edge cases)
- `integrations.md` — External services, MCP connections
- `boundaries.md` — What NOT to build, protected areas

## Prototype Learnings
Before planning new features or architectural work, check `docs/spec/prototypes/` for completed experiment briefs. Validated learnings from prototype sessions may inform architecture decisions, feature design, or spec updates.

## Inter-Session Governance

At session start, check `docs/ai/governance/` for governance evidence and evaluate the **version-match predicate** (Decision 0041). Both `manifest.json.active == null` and the evidence file's `spec_version == null` are normalised to the empty string before comparison:

```
governance_match(file) :=
  exists(file)
  AND (normalised(spec_version in file) == normalised(manifest.json.active))
```

For each evidence file (`spec-compiled` — Prompt 0; `advisory-reviewed` — Prompt A):
- **Match** → fast-skip silently. No warning, no operator prompt.
- **Mismatch** (file exists but `spec_version` differs from `manifest.json` `active`) → warn operator with both versions, e.g. `"Prompt 0 not re-run since spec v2026.03 → v2026.04 — re-run Prompt 0 to refresh spec-compiled evidence"`. Reset the first-fire marker so the commit-time check re-surfaces the same warning (see below).
- **Missing** → warn operator (existing behaviour), and reset the first-fire marker.

These are advisory checks. The operator may direct you to proceed without them (e.g., for standalone tasks not tied to a spec).

The same predicate is mirrored at two hook checkpoints:
- `pre-commit-gates.sh` Gate 3 (commit-time, first-fire suppressed via `.claude/.state/governance-checked` marker).
- `bash-guard.sh` first-Bash-write check (suppressed via `.claude/.state/governance-bash-fired` marker).

On mismatch or missing at any checkpoint, the corresponding marker is **not** written (and any pre-existing marker is deleted), so the warning surfaces on every subsequent check until the operator re-runs Prompt 0 / Prompt A or accepts the divergence.

## Phase Model

The phase model tracks session progress in `.claude/.state/phase-state`. Hooks enforce phase-appropriate actions. You do not need to read this file — hooks manage it automatically. Phase sequences are defined in `_agent-glossary.md` § Phase Model and enforced by `_phase-helper.sh`. See Decision 0014 for canonical definitions.

**Ephemeral sessions**: When the user's intent is Q&A or exploration (no code changes expected), use `init_phase "ephemeral"` instead of `"standard"`. Ephemeral sessions have a minimal phase sequence (`init → conversation → close`) and skip mode-guard, bash-guard branch gates, and close checks. If the user later requests edits, call `upgrade_session_type` to convert to standard (resets phase to `plan`).

### Drift-Check Phase (Decision 0038)

When the brief came from Prompt T (Brief mode), Prompt T wrote a sealed **handoff bundle** at `.claude/local/handoff-bundles/<brief_id>.yaml` (singular, per-brief — Decision t-0043) or `.claude/local/task-groups/{group}/briefs/{seq}.bundle.yaml` (task groups). The bundle carries the approved Task Contract, plan, optional Implementation Design, spec snapshot, and Pragmatist verdict — everything the receiving session needs to skip plan re-derivation. The singular path is resolved by `brief_id` read from the task contract; when no `brief_id` is present (legacy briefs), `drift_check` falls back to the deprecated legacy fixed path `.claude/local/handoff-bundle.yaml`.

**Init ordering (REQUIRE — Decision t-0043):** `drift_check` resolves the per-brief bundle path by reading `brief_id` from `.claude/local/task-contract.yaml`. For **standard sessions there is no `contract-init` phase**, so you MUST write the task contract (including its `brief_id` field, sourced from the pasted brief's `### Task Contract`) to `.claude/local/task-contract.yaml` **before** invoking `drift_check`. If `drift_check` runs first, `_resolve_brief_id` returns empty, the per-brief bundle is never found, and the session silently falls through to the legacy plan→approval path (logged as `no-brief-id:fallthrough`). Task groups already satisfy this ordering via the `contract-init → drift-check` sequence.

After `init_phase` and the task-contract write (and `contract-init` for task groups), advance to `drift-check`. Invoke `drift_check()` from `_phase-helper.sh` via Bash:

```
source .claude/hooks/_analytics-helper.sh && source .claude/hooks/_phase-helper.sh
drift_check
```

Interpret the return code:

| Return | Meaning | Action |
|--------|---------|--------|
| 0 | Bundle valid + fresh + no drift | `plan-approved` and `pragmatist-signed` written from bundle. Forward-jump: `advance_phase "build"` (skipping `plan` and `approval`) |
| 1 | No bundle present | Fall through: `advance_phase "plan"` and run the legacy plan-derivation flow below |
| 2 | Bundle hard-expired | Same as code 1 (legacy path), with advisory logged |
| 3 | Bundle soft-expired | Operator advisory only — caller may proceed with code 0 semantics or trigger focused re-approval |
| 4 | Spec snapshot mismatch | Surface the diff to the operator via `AskUserQuestion` (focused re-approval); on confirm, write state and forward-jump |
| 5 | Scope-file commits since approval | Same as code 4 (focused re-approval with per-file diff) |

**Bundle-aware init shortcut:** When `drift_check` returns 0, also seed `.claude/local/task-contract.yaml` from `bundle.contract` (use `yq` or `awk` extraction — same content already validated by drift-check). Skip the brief-markdown extraction step in § Task Contract below.

### Build Sequence — Agent Dispatch

| Phase | Agent | Notes |
|-------|-------|-------|
| drift-check | **Orchestrator** (deterministic) | Decision 0038 — evaluate the handoff bundle. On bundle valid + fresh: write `plan-approved` + `pragmatist-signed` from bundle and forward-jump to `build` (no Pragmatist dispatch, no AskUserQuestion). On fall-through: continue to `plan` as below |
| plan (legacy fallback only) | **Pragmatist** (plan-gating mode) | REQUIRE dispatch only when drift-check fell through to the legacy path. Foreground preferred (ensures verdict available before plan presentation; background supported but may complete during build). Passes plan text inline in Task prompt. GATE_RESULT: BLOCKED (FUNDAMENTAL-MISMATCH) or APPROVED. Findings and verdict presented alongside plan to operator. Auto mode: BLOCKED degrades to advisory-with-warning (Decision 0025). When `implementation_design:` is present in the task contract AND a bundle exists, this dispatch is replaced by `deterministic_alignment_check` (see § Pragmatist Alignment below) |
| build | Builder | Implements changes |
| review | **Critic** (combined mode: cohesion + diff-review) + **PM Advisory** (spec-drift) + **UX Design Agent** (Mode 2 + Mode 3) | REQUIRE: dispatch Critic once in combined mode before advancing to verify phase. Combined output has two top-level sections (`## Cohesion Brief` and `## Diff-Review Brief`), each ending with its own `GATE_RESULT:` line; `state-writer.sh` writes both `cohesion-reviewed` and `diff-review-complete` from that single dispatch (Decision 0039). PM Advisory + UX agents run in parallel with Critic. PM is conditional — requires compiled spec or `mvp-scope.yaml` (skipped silently otherwise). PM findings are advisory (not gating). UX Design Agent is conditional — dispatched when the task brief contains design brief content or the implementation includes UI changes; see UX Post-Build Review below. Single-mode Critic dispatches (cohesion only, or diff-review only with `MODE: diff-review` sentinel) remain valid for targeted re-runs after a fix |
| verify | QA Verifier | REQUIRE: dispatch before advancing to commit phase. Commit blocker (A1–A6, B1–B3) |
| user-review | User Review Tier agents | Optional — skipped when no User Review in brief |
| commit | Orchestrator | Commit with trailers |

Loops: `review→build` (cohesion findings), `verify→build` (QA failure).

**Mechanism changes (Decision t-0063).** A change to the enforcement mechanism — hooks, `.claude/tools/`, `.claude/.automation/` scripts, their tests, `settings.json` — is verified by the machinery it modifies. In the review phase run `bash .claude/tools/verify-pristine.sh --classify`; on `mechanism-change: yes`, add the four self-referential questions in `.claude/agents/_cohesion-review.md` (§ mechanism-change addendum) to the Critic dispatch. Before commit, stage the change, then run `bash .claude/tools/verify-pristine.sh --suite=<each suite you changed or added> --out=docs/ai/governance/pristine-evidence/<name>.yaml` and `git add -f` the evidence file; `pre-commit-gates.sh` blocks a mechanism change without fresh evidence (`mechanism_change_no_pristine_evidence`). The evidence is bound to the staged files — re-run it after any further edit. New tests are expected to fail in a pristine run; report the counts, do not hide them. The operator exit `REPO_OS_SKIP_PRISTINE_GATE=1` is interactive-only; a headless session that cannot produce evidence escalates.

### Pragmatist Alignment (Decision 0038 § 7)

When `bundle.implementation_design` (or contract `implementation_design:`) is present, Pragmatist Plan-Gating's alignment sub-mode is replaced by a deterministic Orchestrator-side check. Invoke:

```
deterministic_alignment_check "<plan_text>" "$REPO_ROOT/.claude/local/task-contract.yaml"
```

- Output `aligned` (return 0) → write `pragmatist-signed` directly: call `bundle_to_pragmatist_signed` if a bundle is present, else call `write_alignment_check_pragmatist_signed "aligned"` (both helpers are in `_phase-helper.sh`). No Task dispatch. Do NOT write the file by hand — the helpers stamp the required provenance marker that the commit gate verifies.
- Output `diverged` (return 1) → surface the divergence to the operator. If operator confirms intentional divergence, call `write_alignment_check_pragmatist_signed "diverged"` — this writes `GATE_RESULT: BLOCKED`, which will block the commit unless the operator explicitly overrides. Otherwise, dispatch full Pragmatist in plan-gating mode as a fallback.
- Output `missing-design` (return 2) → fall back to full Pragmatist dispatch (current behavior).

### Legacy Plan/Approval Path

When `drift_check` returns non-zero (codes 1–2), use the legacy plan phase:

**Design-mode conditional:** Brief contains a `### Implementation Design` section AND task contract has an `implementation_design:` field.

- **Alignment review mode** (both present): The plan = execution order aligned to the approved design. Do not re-architect. Confirm the implementation follows the approved Components, Key Interfaces, Data Flow, and Error Handling. Present the plan as "executing approved design" — the Pragmatist will validate alignment, not proportionality.
- **Standard mode** (neither or only one present): Plan the implementation from scratch, dispatch Pragmatist for full proportionality review.
- **Divergence** (only one present — mismatch between brief and contract): Default to standard mode. Log in plan summary: "Implementation Design mismatch: present in [brief/contract] but not [contract/brief] — treating as standard plan phase."

When in alignment review mode, the Critic's cohesion review also receives the `implementation_design:` contract content as additional context for evaluating whether the build faithfully implements the approved design.

### Auto/Review Mode

**Bundle path (default):** mode is set by the operator at Prompt T Step 4 and recorded in `bundle.mode`. `drift_check` writes the mode into `plan-approved` so `phase-state` carries it through the session — no AskUserQuestion is required.

**Legacy path:** When `drift_check` falls through to the legacy plan phase, present the plan via AskUserQuestion with **auto** and **review** options:
- **Auto** — agent completes through merge autonomously after all gates pass. The `op-review` phase is skipped.
- **Review** — agent pauses after verify for operator review before commit. Default.

See `orchestrator.md` § Constraints for the canonical AskUserQuestion plan approval template and hook contract annotations.

### Solo Mode (Decision 0015)

Branches merge to main directly at session close. See `.claude/agents/_agent-glossary.md` § Phase Model for full merge semantics and branch type applicability, and `docs/ai/workflow-appendix/session-type-task-group.md` for task group branch strategy.

## Task Contract (Decision 0020)

At session init, after branch creation and spec loading:

**Product graph auto-seeding (first-session guard):** If `docs/ai/knowledge-graph/product-graph.yaml` does not exist, run `.claude/tools/kg-seed.sh --target product` to bootstrap the product graph, passing one `--file-pattern` per source extension (e.g. `--file-pattern 'src/**/*.ts' --file-pattern 'src/**/*.tsx'`). Skip if the file already exists — the seeder refuses to overwrite one. This is a first-session-only operation. The seeded nodes all say `"Product source file"`, which the commit gate rejects; they become real as files are touched. The gate stays advisory until the repo declares its scope in `docs/ai/knowledge-graph/coverage.yaml` (roots and extensions — see `docs/ai/knowledge-graph/README.md`); propose that file to the operator rather than inventing its roots.

Extract the task contract from the brief text:

- **Singular builds**: If the brief contains a `### Task Contract` section with a YAML code block, extract the YAML content and write it to `.claude/local/task-contract.yaml`. The task contract is embedded inside the brief template (not a separate block). If `.claude/local/task-contract.yaml` already exists (orphan from a crashed session), delete it before writing the new one and log: "Cleaned stale task contract from previous session."
- **Sidecar contract**: If the brief does not contain a `### Task Contract` section, check for a sidecar file at the same path as the brief with a `.yaml` extension (e.g., `.claude/.automation/briefs/20260404-foo.yaml` alongside `.claude/.automation/briefs/20260404-foo.md`). If the sidecar exists, copy it to `.claude/local/task-contract.yaml`. For copy-pasted briefs (no file path available), this path is skipped — the "No contract present" fallback applies.
- **Task groups**: If the brief's `### Task Group` section contains a `Contract:` field, extract the contract content and write it as the `intent:` block in the task group contract YAML during the `contract-init` phase. Use the fields: `goal`, `verification`, `scope_files`, `spec_references`.
- **Sidecar contract**: If a `.contract.yaml` sidecar file exists alongside the brief in `.claude/.automation/briefs/` (same slug, `.contract.yaml` extension), read it as the task contract source instead of re-parsing the embedded `### Task Contract` section. Takes precedence over embedded extraction for singular builds. The sidecar is a standalone YAML file containing the same content as the embedded `### Task Contract` block — write it directly to `.claude/local/task-contract.yaml`. The **No contract present** fallback still applies when neither a sidecar nor an embedded `### Task Contract` section nor a `Contract:` field exists.
- **No contract present**: If the brief contains neither a `### Task Contract` section nor a sidecar `.yaml` file nor a `Contract:` field in `### Task Group`, skip contract extraction silently (backward compatibility with legacy briefs, hotfixes, etc.).

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

## Knowledge Graph Integration (Decision 0034 — Full Profile)

When `docs/ai/knowledge-graph/product-graph.yaml` exists, the Builder participates in the knowledge graph lifecycle. It is the only graph: the template graph (`graph.yaml`) was retired in Decision 0034 Amendment 9.

### Graph Writes
- **Product files** (application code, product features) → update `product-graph.yaml`. A node needs a description that says what the file does — the seeder default `"Product source file"` and anything under 20 characters are rejected at commit.
- **Renames** → update the existing node's `path`; **deletions** → remove the node or set `status: stale`.
- Governance files (hooks, prompts, decisions, agents) are not graphed.
- Edges that point at retired template node ids are left alone; they are reported as dangling, advisory only.

### Graph-First File Discovery
REQUIRE: when `.claude/.state/kg-relevance-context` exists and is non-empty, read it before running any broad codebase search (`grep -r`, `find`, repo-wide glob patterns). At build phase entry, `_phase-helper.sh` automatically runs `kg-relevance.sh` (over the product graph) and writes pre-computed relevance-scored connections to `.claude/.state/kg-relevance-context`.

Use grep/glob search only for:
- Files not yet in the knowledge graph
- Connections the graph doesn't cover (e.g., string literals, configuration values)
- Verifying graph edges you suspect are stale
- When `kg-relevance-context` is absent or empty (documented exception — not default behavior)

When you discover connections not in the graph, note them for graph update at close.

### During Build
As you work, note connections you discover between files — governance relationships, dependencies, data flow, test coverage. These will be written to the knowledge graph at close.

### At Close (before commit)

The write path branches on session type:

**Single-brief, sequential task group, hotfix, editor-live (default path):** Update the appropriate graph file via shell I/O (Bash redirection — not Edit/Write tools) with:
- New nodes for files you created (type matches: `file`, `decision`, `hook`, `prompt`, `contract`, `concept`, `convention`). Set `layer` to match the graph (`template` or `product`)
- New edges for connections you discovered (use `source_type: agent-inferred`, `status: active`, `confidence: 0.7` for connections verified during this session)
- Updated `last_verified` dates for existing edges you traversed and confirmed
- Edge types are limited to the 8-type taxonomy: `governs`, `constrains`, `implements`, `depends-on`, `produces`, `consumes`, `tests`, `supersedes`

Use `mkdir`-based locking per Decision 0034 before writing (`.product-graph-lock`). Operator-curated edges (`source_type: operator-curated`) are never modified by agents.

**Parallel content brief (`Execution: parallel` in `### Task Group`):** Do NOT write to the shared graph. Instead, author a per-brief KG delta at `$_REPO_OS_ROOT/.claude/.state/tg-{group}-brief-{seq}.kg-delta.yaml` via shell I/O from the worktree's main session. Schema and authoring rules: see `.claude/agents/builder.md` § Knowledge Graph Delta and Decision 0034 Amendment 5. The merge brief aggregates all per-brief deltas in a single locked write — eliminates the N+1 lock contention pattern.

**Merge brief (`taskgroup-merge` session type):** At close, before the final commit:
1. Author the merge brief's own delta at `$_REPO_OS_ROOT/.claude/.state/tg-{group}-brief-merge.kg-delta.yaml` from cross-session observations only the merge brief can make (integration edges between files owned by different content briefs, cross-cutting relationships visible in the combined diff). Same schema as content-brief deltas.
2. Run `bash .claude/tools/kg-merge-deltas.sh {group}` — reads all per-brief deltas + the merge-brief delta, dedups (last `authored_at` wins on `last_verified`; max wins on `confidence`; first-seen wins on `status` conflict; operator-curated edges immutable), and applies the union to the shared graph under a single lock.
3. If `$_REPO_OS_ROOT/.claude/.state/kg-aggregation-conflicts.log` was written, surface those tuples as CRITICAL cohesion findings — do not silently accept.

REQUIRE: attempt graph writes (or delta writes for parallel content briefs) at close before the final commit. If the write fails (lock contention, parse error), log the failure in the closing summary and proceed to commit — do not block the close sequence. Skipping the attempt entirely is a REQUIRE violation (Decision 0034 Amendment 3). Note: this tolerate-failure stance governs close-time writes only. The KG product-graph gate in `pre-commit-gates.sh` (Decision 0034 Amendment 9) is separately blocking at commit time — a staged product file inside the repo's `coverage.yaml` scope without a described node, a renamed or deleted file whose node was left behind, or no graph update this session will block the commit regardless of the close-write outcome. Fix it, then `git add docs/ai/knowledge-graph/product-graph.yaml`.

## Operating Rules
- REQUIRE: at session start, create a branch from main: `git checkout -b <category>/<description>` (standard: `feature/<description>`, hotfix: `hotfix/<description>`)
- REQUIRE: extract and write task contract at session init when present in the brief (Decision 0020). Contract serves as cohesion review reference
- REQUIRE: after Builder signals done, Orchestrator dispatches Critic once in combined mode (cohesion + diff-review) before invoking QA. The Task prompt passes both the diff + immediate-neighbor files (cohesion scope) and the staged diff + surrounding 20 lines per changed function (diff-review scope). Critic emits both `## Cohesion Brief` and `## Diff-Review Brief` sections in one response, each ending with its own `GATE_RESULT:`. `state-writer.sh` parses the dual-section output and writes both `cohesion-reviewed` and `diff-review-complete`. Critical findings in either section must be resolved before commit; BLOCKED in either section blocks Gate A5. Targeted re-runs after a fix may use single-mode dispatch (cohesion only, or diff-review only with `MODE: diff-review` sentinel). See `quality-gates.md` gate A5 and Decision 0039.
- GUIDE: use HVST (see `_agent-glossary.md` § HVST) when debugging or instability appears. When HVST debugging stalls (2+ consecutive failures), Orchestrator dispatches HVST Review Board for multi-agent hypothesis review before further fix attempts. See `_hvst-review.md`
- REQUIRE: **Task Group Contract** — if the task brief contains a `### Task Group` section, this session is part of a multi-brief group. Read and follow the contract lifecycle in `docs/ai/workflow-appendix/session-type-task-group.md`. See `docs/ai/quality-gates.md` gate A6 for verification requirements
- BLOCK: **Session Branch Isolation** (Decision 0013) — each session uses a dedicated branch — enforced by bash-guard.sh / write-guard.sh (Section 3). After session close, the branch is sealed and must not be reused. Start a new branch for new work. Task group sessions are exempt (sequential groups share one branch; parallel groups use per-brief worktree branches — see Decision 0032)
- REQUIRE: include git trailers on commits per the convention in `docs/ai/workflow.md` (Session Lifecycle → Git Trailer Convention)
- REQUIRE: **Parallel Task Group Completion Marker** — if the task brief has `Execution: parallel` in `### Task Group`, write a per-brief completion marker file at session close: `$_REPO_OS_ROOT/.claude/.state/tg-{group}-brief-{seq}.complete` (content: ISO 8601 timestamp). Use the shared `$_REPO_OS_ROOT/.claude/.state/` path explicitly (not the per-session state directory from `get_session_state_dir()`), so the merge brief can find markers regardless of worktree state directory scoping (Decision 0032). This signals to the merge brief that this content brief has completed
- REQUIRE: **Parallel Task Group Boundaries** — parallel briefs MUST restrict edits to files within their declared `Boundaries`. Edits outside boundaries require explicit operator approval. Shared files (e.g., index files, config) are owned by the merge brief
- REQUIRE: **Pragmatist Plan-Gating** (Decision 0025) — Pragmatist must be dispatched before presenting plan to operator. `pragmatist-signed` state file is verified at commit time by `pre-commit-gates.sh`. `advance_phase()` enforces `plan-approved` substance check before the post-approval phase transition. `init_phase()` blocks re-initialization for the same session (override: `REPO_OS_ALLOW_REINIT=1`). Session close runs forensic check on `phases_completed` to detect force-advance violations
- REQUIRE: **Session Log Ordering** — session log must be the last file modified before the close-phase commit. Do not commit the session log before implementation work is complete, and do not modify it after the final commit
- REQUIRE: **Integration Verification Items** — verify all items in the Verification section marked with "Build verification", "Integration points", or "Cross-session" before signaling completion. These items are mechanically verifiable — do not mark as verified without running the check. "Build verification" requires running `tsc --noEmit` (when `tsconfig.json` exists). "Integration points" requires confirming that all imports/exports between the brief's files and existing modules resolve. "Cross-session" requires reviewing `git log --oneline -10` for relevant recent changes.
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