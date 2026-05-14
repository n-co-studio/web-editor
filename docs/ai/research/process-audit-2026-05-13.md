# Repo OS — Process & Workflow Audit

**Date:** 2026-05-13
**Auditor:** Claude (Cowork agent), Mark Preston operating
**Scope:** End-to-end flows across all session types, with a focused validation of the suspected duplicated planning phase between Prompt T (task brief) and Prompt B (build).
**Source of truth read:** `AI.md`, the canonical governance index, plus every prompt, workflow appendix, agent definition, and decision file it cites.

---

## Executive summary

The user's hypothesis is correct, and the duplication is broader than first described.

A single piece of work passes through **two independent "planning" treatments** before any code is written. Prompt T runs four specialists in parallel, synthesises their findings into a structured brief that already contains a numbered `Approach`, an optional pre-approved `Implementation Design`, and a machine-readable `Task Contract` YAML, and asks the operator to approve it. Prompt B then re-opens the same package, drafts another execution plan from the same brief, dispatches the Pragmatist a second time, and asks the operator to approve that plan as well. The plan-gating substep is *aware* it is redundant — when an `implementation_design:` field is present in the contract the Pragmatist downgrades itself to an "alignment-check" sub-mode (`pragmatist.md` lines 105–106) — but the gate, the AskUserQuestion round-trip, the state file write, and the Orchestrator's own re-derivation of the plan all still happen.

That is one of seven re-validated inefficiencies. Together they add an estimated **~30% wall-time tax** and **~20–25% token tax** to the average brief→build pipeline, without producing proportionally more safety. Each is fixable without removing any of the governance guarantees the Repo OS exists to provide; the redundancy is in *coverage* of those guarantees, not in the guarantees themselves.

The diagrams supporting this report live in a FigJam file: <https://www.figma.com/board/RV1xqqIrXNx2b3kraMlTll>. Three boards: current end-to-end flow, annotated duplication hotspots, and the proposed lean flow.

---

## Methodology

1. Read `AI.md` and every file it cites as a source of truth.
2. Mapped the phase sequences of all 18 session types via `_agent-glossary.md` § Phase Model and `t-0014-phase-aware-flow-model.md`.
3. Traced the Prompt T → Prompt B handoff line by line, comparing what Prompt T produces against what Prompt B consumes.
4. Mapped the secondary flows (Prompts A, C, F, H, Q, E, taskgroup-merge, automation runner) and the supporting agents (Pragmatist, Critic, Architect, build-planner, dev-orchestrator).
5. Cross-referenced specialist dispatch tables to find the same agents doing similar work in different phases.
6. Catalogued the state-file dependency graph from `_agent-glossary.md` Enforcement § State Files to spot serialisation points.

The findings below cite the specific files and section anchors that produced them so future audits can re-verify cheaply.

---

## Validated finding 1 — Brief→Build planning duplication

### The claim

> The task brief session goes through init → planning → deliverable and produces a brief. The build sequence picks up the brief, initialises, and then does the plan phase again before the actual build work.

### Verdict

**Confirmed.** With a small refinement: the second "plan" phase has been *partially* aware of the duplication for some time (Decision 0025 introduced the alignment-check sub-mode), but the structural cost — an additional specialist dispatch, an operator round-trip via `AskUserQuestion`, a state-file write, and the Orchestrator's own plan re-derivation — has not been removed.

### Evidence

**Prompt T (Brief mode) phase sequence** (`t-0014` line 100–101, mirrored in `prompt-t-task-definition.md` § Phase Sequences):

```
init → dispatch → synthesize → approval → output → close
```

In `synthesize` the Orchestrator merges specialist findings into a draft brief containing a numbered `### Approach`, an optional `### Implementation Design` block, and a `### Task Contract` YAML block (`prompt-t-task-definition.md` Step 3 and the brief template at lines 260–371). The Approach is explicitly described as "Concrete enough for Prompt B to execute from" (line 277). Operator approval is required via `AskUserQuestion` (Step 4) and gated by `plan-approval.sh` writing the `plan-approved` state file (`t-0029`).

**Prompt B (standard) phase sequence** (`t-0014` line 40–41):

```
init → plan → approval → build → review → verify → user-review → commit → op-review → close
```

In `plan` the Orchestrator drafts an execution plan, then `pragmatist.md` is dispatched in Plan-Gating mode (`prompt-b-product-build.md` § Build Sequence — Agent Dispatch table). The plan is presented to the operator via `AskUserQuestion`, gated by the same `plan-approval.sh` hook (now writing a *fresh* `plan-approved` state file in the build session's state dir).

**The two state files are different files.** Prompt T's `plan-approved` lives in the brief session's state dir (`taskdef-brief` type). Prompt B's `plan-approved` lives in the build session's state dir (`standard` type). There is no carry-over (`t-0028`/`t-0030` worktree state isolation guarantees this — see `_agent-glossary.md` § Worktree State Isolation).

**The Pragmatist runs twice** as a direct consequence: once in Brief-Advisory mode (`pragmatist.md` lines 13, 96–98), once in Plan-Gating mode (lines 14, 100–106). When `implementation_design:` is present in the contract the second run *narrows* to an alignment check (lines 105–106) — but the dispatch, prompt assembly, model call, and state-file write still happen.

### Where the duplication actually shows up

| Activity | Done in Prompt T | Done in Prompt B plan | Truly new in Prompt B plan? |
|---|---|---|---|
| Read brief and contract | Yes (just produced it) | Yes (loads from disk / paste) | No |
| Load relevant spec sections | Yes (selective per Decision 0035) | Yes (re-loaded per § Project Specification) | No |
| Decide *what* will be built | Yes (Approach, Implementation Design) | "Plan" rephrases the same Approach | No |
| Decide *order* of build steps | Yes (numbered Approach) | Plan is the same order | No |
| Proportionality / over-engineering check | Yes (Pragmatist Brief-Advisory) | Yes (Pragmatist Plan-Gating) | No (alignment sub-mode acknowledges this) |
| Operator approval via AskUserQuestion | Yes | Yes | Approving the *same* artefact a second time |
| Cohesion / gap detection | Yes (Critic in Prompt T) | Deferred to `review` phase | Different phase, different scope — not duplicate |
| Build-time risk surfacing | Partial (Risks section in brief) | Plan-phase output | Mostly already in brief |

The only thing genuinely new in Prompt B `plan` is **selection of auto vs review mode** (`orchestrator.md` Plan-approval template). Everything else is re-derivation.

### Cost vs value

**Cost per build:**
- 1 specialist dispatch (Pragmatist Plan-Gating) — call this ~1k–3k tokens including the inline context block
- 1 plan draft turn from the Orchestrator — typically 500–1500 tokens of output, plus the model's own context window cost to "re-imagine" the plan
- 1 operator round-trip — the wall-time cost depends on the operator's availability; in headless / auto mode it short-circuits, but the AskUserQuestion is still constructed and the `plan-approved` state file is still written
- 1 phase transition (`plan → approval → build`) with its state-file writes

**Value:**
- Catches cases where the operator's brief is internally inconsistent with the codebase reality the Builder will see at run time — but this is what `review` (cohesion) + `verify` (QA) are already there to catch
- Catches plans that "diverge" from the Implementation Design — but if the design is in the contract, the Builder is *told* to follow it (`prompt-b-product-build.md` § Plan Phase — Design Mode Conditional) and the Critic in `review` is already given the design as alignment context
- Forces the operator to re-engage with the work — useful for long-running auto sessions, but real-time operators have already engaged at Prompt T

**Net assessment:** Plan-Gating mode is doing real work in exactly one scenario — the brief was queued days ago, the operator hasn't seen it since, and the codebase has drifted. In every other scenario it is paying full cost to re-validate a decision the operator just made.

### Recommendation 1A — Collapse the second plan gate into a "drift check"

Replace the unconditional `plan → approval` phases in Prompt B with a conditional `drift-check` phase that fires only when one of the following is true:

- More than N hours since the brief was approved (configurable; default 24h)
- `git log main..HEAD` shows commits touching files in the brief's `scope_files` since the brief was approved
- The contract is missing or malformed
- The session is being resumed after a crash (the existing `session-resume.yaml` signal)

When none of these conditions are met, Prompt B should skip `plan` + `approval` entirely and go straight to `build`. The handoff from Prompt T already carries: brief, contract, frozen plan (the numbered Approach), pre-approved Implementation Design, spec snapshot. That bundle *is* the plan-approved artefact; treating it as such avoids the second gate.

When the drift check does fire, present the operator with a diff between the brief's Approach and the current code state and ask for re-approval — that is a meaningful question, not a re-statement of the original one.

### Recommendation 1B — Demote Pragmatist Plan-Gating to assertion-only when contract has Implementation Design

If a non-trivial fraction of work routes through the Implementation Design path (and it should — anything beyond Small Scope per `_agent-glossary.md`), the alignment-check sub-mode is doing a one-line job: "does the plan match the design?" That can be a deterministic check by the Orchestrator against the contract's `implementation_design.components / key_interfaces / data_flow` fields, not a specialist dispatch. Reserve the full Pragmatist call for the contract-less / design-less path.

### Effort to implement

- Mostly prompt and `_phase-helper.sh` changes — drift-check is a new helper function plus a conditional `advance_phase` call
- One new decision file to record the policy change
- Hook updates: `pre-commit-gates.sh` and `bash-guard.sh` already accept missing plan-approved as a recoverable block on standard sessions; they need to accept the carried-forward signal from Prompt T as equivalent
- No changes to QA gates, cohesion review, or merge logic

**Estimated savings per build:** 1 specialist dispatch + 1 plan-draft turn + 1 operator round-trip + 2–3 state-file writes. On the order of **5–15% wall-time** for review-mode builds, **10–20% token reduction** in the plan + approval phases, and a meaningful drop in operator interruption pressure.

---

## Other validated findings

Each of the following follows the same audit pattern — cite the source, state the cost, propose a remediation. They are presented in rough impact-descending order.

### Finding 2 — Pragmatist dispatched up to three times for one piece of work

**Where:**
- Prompt T Brief mode dispatches Pragmatist in Brief-Advisory mode as a core specialist (`prompt-t-task-definition.md` Step 2 Dispatch table line 157, `pragmatist.md` line 13).
- Prompt A Phase 1 (Initialize mode) dispatches Pragmatist as part of the advisory board core group at every tier (`_advisory-board.md` core group — confirmed by the Explore agent against advisory-board.md).
- Prompt B `plan` phase dispatches Pragmatist in Plan-Gating mode (`prompt-b-product-build.md` § Build Sequence — Agent Dispatch).

**Cost:** Three model calls reviewing variants of the same intent, often against overlapping context. The Pragmatist's anti-pattern checklist (`pragmatist.md` lines 41–53) is the same in every mode.

**Recommendation:** Treat Pragmatist findings as durable across phases within the same logical work item. When Prompt T's Brief-Advisory run produces zero findings, write a `pragmatist-brief-clean` marker into the contract; Prompt B's Plan-Gating dispatch should be skipped if that marker is present AND the plan does not introduce new files or modules beyond `scope_files` in the contract. The same marker can be respected by Prompt A — if the contract was reviewed at T and is unchanged, skip the A-tier Pragmatist.

### Finding 3 — Operator gated 2–3 times for a single work item

Counting from "operator describes the task" to "code committed":

1. Prompt T Step 4 — approve the brief (always)
2. Prompt B plan — approve the plan (always, even with Implementation Design pre-approved)
3. Prompt B op-review — approve the result (skipped in auto mode; always present in review mode)

Three serial gates against the same author for the same work. The first two are the redundancy described in Finding 1; the third is a legitimate post-build review.

**Recommendation:** Folding gates 1 and 2 into a single "approve brief & enter build" gate is the dominant simplification. The auto-vs-review choice (currently made at gate 2) moves to gate 1, which is already the right place — by the time the operator has reviewed the brief, they know whether they want to babysit the build.

### Finding 4 — Spec and context re-loaded across session boundaries

`prompt-t-task-definition.md` Step 2 Pre-dispatch (lines 99–124) carefully selects which spec files load per specialist, per Decision 0035. The selective set is then synthesised into the brief. Prompt B at init (`prompt-b-product-build.md` § Project Specification) re-runs the same selective-load logic against the brief's `### Spec References` list — reading the same files, parsing the same `manifest.json`, optionally re-reading `DIGEST.md`.

**Cost:** Disk reads are cheap, but the model's *context window* is paying the full cost of those tokens twice. For a non-trivial product with ~10 feature files plus core specs, this is the largest fixed per-session cost in the pipeline.

**Recommendation:** Have Prompt T at `output` time write a snapshot manifest into the contract — `spec_snapshot: { files: [...], sha: <hash>, captured_at: ... }`. Prompt B at init verifies the hash against the working copy; if matching, the brief's already-loaded excerpts are trusted as in-context (i.e. carry them in the handoff bundle); if not matching, fall through to current behaviour and warn the operator that specs drifted between brief approval and build start.

### Finding 5 — Critic dispatched twice in `review` phase

`prompt-b-product-build.md` § Build Sequence — Agent Dispatch shows the `review` row dispatching Critic in cohesion mode and Critic in diff-review mode as two separate Task calls, then PM Advisory and UX Mode 2/3 in parallel. Two state files are produced (`cohesion-reviewed`, `diff-review-complete`), keyed off the `MODE: diff-review` sentinel in critic output (`_agent-glossary.md` Enforcement § State Files).

**Cost:** Two model invocations against the same diff, two prompt assemblies, two state-file writes. The cohesion mode looks at "diff + surrounding code for broken cross-references"; diff-review mode looks at "mechanical bug detection in staged changes." These are different checks but the *context they require is nearly identical*.

**Recommendation:** Run Critic once with both modes requested in a structured-output contract. Have the agent emit both `## Cohesion Review` and `## Diff Review` sections in one response with two `GATE_RESULT:` lines, and update `state-writer.sh` to write both state files based on section sentinels rather than the all-or-nothing `MODE: diff-review` flag. Same coverage, one dispatch.

### Finding 6 — Knowledge-graph writes do not aggregate across briefs in a task group

`Decision 0034` Amendment 3 requires every session to attempt a graph write at close. Task groups with `Execution: parallel` and N content briefs end up doing N + 1 writes (one per brief, one in the merge brief), each acquiring a `mkdir`-based lock on `graph.yaml` or `product-graph.yaml`. Each lock acquisition is fast but the writes are *serialised* by design.

**Recommendation:** Content briefs in a parallel group should write their proposed nodes/edges into the per-brief state dir (e.g. `tg-{group}-brief-{seq}.kg-delta.yaml`) instead of locking the shared graph. The merge brief, which already owns combining the per-brief diffs (`session-type-task-group.md` § Parallel Execution), reads those deltas, dedups, and performs a single write. The single-brief path is unchanged.

### Finding 7 — Prompt F (finish-loop) re-assesses passing dimensions every cycle

The Explore agent's read of `prompt-f-finish-loop.md` showed all six assessment dimensions re-running on every cycle, with a regression-check pass on already-PASS dimensions. The intent is right (regressions exist) but in the most common case — the issue is in dimension 6 and dimensions 1–5 are stable — five-sixths of the work is redundant per cycle.

**Recommendation:** Hash each dimension's input set (files + content sha + line ranges); if the hash hasn't changed since the prior PASS, skip re-assessment and inherit the prior verdict. Force re-assessment when the loop-back originates from a fix that touched any file the dimension considered. This is the standard cache-with-invalidation pattern that the rest of the build system already uses (state files, governance evidence).

### Finding 8 — Inter-session governance evidence is advisory-only and re-checked each session

`docs/ai/governance/spec-compiled` (written by Prompt 0) and `docs/ai/governance/advisory-reviewed` (written by Prompt A) are read by Prompt B at session start and re-validated by `pre-commit-gates.sh` at commit time. Both checks are advisory-first-fire (`AI.md` Hooks table). The advisory layer means a missing file warns but does not block.

**Cost:** Modest — a stat call plus the operator/agent reading a warning. But the same evidence is *recomputed* on every Prompt B session from scratch, even when the spec and advisory haven't changed.

**Recommendation:** Treat these as version-stamped artefacts (`spec_version`, `advisory_version` already in `prompt-a-repo-os.md` § Governance Evidence). Prompt B can fast-skip the check when both files are present and the embedded `spec_version` matches `manifest.json`'s active version. Today the files exist but their version field is informational, not load-bearing.

### Finding 9 — Hook chain has overlapping condition checks across multiple files

The hook table in `AI.md` lines 57–73 lists 12 hooks; `bash-guard.sh`, `write-guard.sh`, and `pre-commit-gates.sh` each independently check session overlap (Decision 0013), branch isolation, and phase enforcement (Decision 0019). The Explore agent flagged this as redundant work on each PreToolUse event.

**Recommendation:** Hoist the shared checks into `_phase-helper.sh` once per phase transition and cache the verdict in a hot state file (e.g. `phase-state.gates`) that the individual hooks consult. Hooks become cheap predicates against the cache; the expensive logic runs at phase boundaries only. This is a refactor, not a behaviour change.

---

## Findings flagged but de-prioritised

These showed up in the sweep but are not worth chasing now — listing them for completeness.

- **Architect re-dispatch (Prompt T + Prompt A).** Same agent, different scopes (task vs whole spec). Decision 0035's selective-load partly mitigates the context cost. The conceptual duplication is real but the contexts they review are genuinely different.
- **Prompt C dimension-per-Task dispatch.** Designed for independent escalation. Consolidating would lose that property; the cost is acceptable for an audit operation that runs rarely.
- **Session log split-commit (work commit + log commit).** Designed to keep the log as the last file modified per `prompt-b-product-build.md` § Operating Rules. The trade-off (two commits vs simpler audit trail) favours the current design.
- **Decision cache + brief trailer + agent re-read.** Three places decisions surface. The cost is small and the redundancy is defensive — agents are sometimes dispatched without the cache.

---

## Scoring summary

Subjective impact × effort scoring. Impact considers token + wall-time + operator-friction cost per typical build. Effort assumes one focused session of governance work.

| # | Finding | Impact | Effort | Priority |
|---|---|---|---|---|
| 1 | Brief→Build plan duplication | **High** | Low–Medium | **Do first** |
| 2 | Pragmatist 3× dispatch | High | Low | **Do first** |
| 3 | Operator gated 2–3× | High | Low (rolls in with #1) | **Do first** |
| 4 | Spec snapshot not carried | Medium–High | Medium | Second wave |
| 5 | Critic 2× in review | Medium | Low | Second wave |
| 6 | KG writes not aggregated | Medium (task groups only) | Low–Medium | Second wave |
| 7 | Finish-loop full re-assess | Medium (cycle-heavy sessions) | Medium | Third wave |
| 8 | Governance evidence re-check | Low–Medium | Low | Third wave |
| 9 | Hook overlap | Low (perf) | Medium | Third wave / refactor |

The first three findings are essentially one change shipped together — a redesigned brief→build handoff that carries the plan, the contract, the spec snapshot, and the Pragmatist verdict as a sealed bundle. That single change is the highest-leverage item in this audit.

---

## Proposed handoff bundle (the unifying remediation)

A "sealed bundle" makes the brief→build boundary lossless. Prompt T writes the bundle at `output`; Prompt B at `init` reads it and validates it. If it validates, the build skips `plan` and `approval` and starts at `build`. If it doesn't, Prompt B falls through to the current behaviour.

Conceptual schema:

```
.claude/local/handoff-bundle.yaml   # written by Prompt T at output
  brief_id: <slug + timestamp>
  approved_at: <ISO 8601>
  approved_by: <operator>
  mode: auto | review
  contract: <full Task Contract YAML, inlined>
  plan: <numbered Approach, inlined>
  implementation_design: <inlined if present>
  spec_snapshot:
    version: <manifest.json active>
    files: [{ path, sha }]
  pragmatist:
    verdict: APPROVED | NONE
    findings: []
  expiry:
    soft_hours: 24       # after this, drift check fires
    hard_hours: 168      # after this, full re-plan required
```

Prompt B init replaces today's `plan` + `approval` phases with:

```
init → drift-check → build → review → verify → user-review → commit → op-review → close
```

`drift-check` runs `_phase-helper.sh` predicates: bundle exists, hash matches, expiry not exceeded, no commits to scope_files since `approved_at`. Pass → straight to build. Fail → present the diff to the operator and ask for a focused re-approval (which is what Prompt B's plan phase *should* be doing today but instead re-derives from scratch).

This is the single change that lights up Findings 1, 2, 3, and 4. The other findings can be addressed independently.

---

## Diagrams

A FigJam file with three boards is available at:

<https://www.figma.com/board/RV1xqqIrXNx2b3kraMlTll>

1. **Current End-to-End Flow (Brief → Build)** — visualises the two-phase plan structure with operator gates and Pragmatist dispatches highlighted.
2. **Duplication & Inefficiency Hotspots** — annotates the seven validated findings at their source.
3. **Proposed Lean Flow** — shows the recommended bundle-driven flow that collapses the planning duplication.

---

## What to do next

1. Read the diagrams alongside this report — the picture and the prose reinforce each other.
2. Decide whether to act on the "do first" cluster (Findings 1 + 2 + 3) as a single redesign or as three independent decisions. The audit recommends the bundle redesign as one change because the pieces depend on each other.
3. If accepted, the change should go through Prompt T → Prompt B itself as a task group — eat your own dog food, validate the redesign by running it through the system it modifies.

## Citations

- [AI.md](AI.md) — canonical governance index
- [docs/ai/prompts/prompt-t-task-definition.md](docs/ai/prompts/prompt-t-task-definition.md) — Prompt T phase sequence, brief template, Step 2 dispatch table
- [docs/ai/prompts/prompt-b-product-build.md](docs/ai/prompts/prompt-b-product-build.md) — Prompt B build sequence, plan phase, design-mode conditional
- [docs/ai/prompts/prompt-a-repo-os.md](docs/ai/prompts/prompt-a-repo-os.md) — Prompt A advisory phases
- [docs/ai/workflow.md](docs/ai/workflow.md) — close sequence, session lifecycle
- [.claude/agents/_agent-glossary.md](.claude/agents/_agent-glossary.md) — phase model, state files, enforcement
- [.claude/agents/orchestrator.md](.claude/agents/orchestrator.md) — plan-approval template, on-demand procedures
- [.claude/agents/pragmatist.md](.claude/agents/pragmatist.md) — dual-mode definition, alignment-check sub-mode
- [.claude/agents/build-planner.md](.claude/agents/build-planner.md) — layer planning, dependency graphs
- [docs/ai/decisions/t-0014-phase-aware-flow-model.md](docs/ai/decisions/t-0014-phase-aware-flow-model.md) — phase sequences by session type
- [docs/ai/decisions/t-0025-pragmatist-agent.md](docs/ai/decisions/t-0025-pragmatist-agent.md) — Pragmatist plan-gating rationale
- [docs/ai/decisions/t-0035-selective-spec-loading.md](docs/ai/decisions/t-0035-selective-spec-loading.md) — selective-load mechanism
- [FigJam diagrams](https://www.figma.com/board/RV1xqqIrXNx2b3kraMlTll) — current flow, hotspots, proposed lean flow
