# Decision t-0039 — Critic Single-Dispatch Consolidation (Combined Mode)

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/agents/critic\.md`
- path: `\.claude/hooks/state-writer\.sh`
- keywords: `critic combined mode, cohesion + diff-review consolidation, dual-section output, review-phase dispatch, MODE: diff-review`

## Context

The Prompt B `review` phase historically dispatched Critic twice: once in cohesion mode (internal coherence — `cohesion-reviewed` state file) and again in diff-review mode (mechanical bug detection — `diff-review-complete` state file). Both dispatches operated on substantially overlapping context (the same diff, the same touched files), differed mainly in evaluative lens, and ran sequentially in the same phase.

The duplication paid a fixed cost in prompt assembly (system prompt, agent definition, repeated diff payload) without buying meaningful coverage separation. Wall-time parallelisation does not eliminate that cost — each dispatch still pays full prompt-assembly overhead — and operationally the two verdicts always travel together in Gate A5.

State-file routing already distinguished the two outputs via a `MODE: diff-review` sentinel parsed by `state-writer.sh`. The routing was binary and per-dispatch: one Critic output → one state file.

## Decision

### 1. Combined Mode Output Contract

Add a `combined` mode to the Critic agent (joins existing spec / cohesion / hypothesis / diff-review modes). Combined output is a single response containing two top-level sections in fixed order:

1. `## Cohesion Brief` — full cohesion review (Findings, Contract Verification, Completeness, Summary, completeness sentinels, `GATE_RESULT:` line)
2. `## Diff-Review Brief` — full diff-review (Findings, Summary, `MODE: diff-review`, `GATE_RESULT:` line)

Each section terminates with its own `GATE_RESULT: APPROVED|BLOCKED reason="..."` at column 0. The cohesion `GATE_RESULT:` appears inside the Cohesion section; the diff-review `GATE_RESULT:` is the final non-empty line of the response. Both must be APPROVED for the review phase to advance.

Combined mode is the default dispatch for the Prompt B `review` phase. The pre-existing single-mode dispatches (cohesion only, diff-review only) remain valid output shapes — used for targeted re-runs after a fix, hotpath dispatches, and backward-compatible reading of legacy session output.

### 2. Section-Aware State-File Routing

`state-writer.sh` parses Critic output and routes per these rules:

- **Combined output** (both `## Cohesion Brief` and `## Diff-Review Brief` headers at column 0): split the message at the diff-review header; extract per-section last-non-empty `GATE_RESULT:` lines; write `cohesion-reviewed` and `diff-review-complete` from this single SubagentStop event. Completeness sentinels (`COMPLETENESS:`, `COMPLETENESS_GATE:`) attach to `cohesion-reviewed`. Phase advance (`review → verify`) is governed by the cohesion `GATE_RESULT:`.
- **Single cohesion output** (no diff-review header): unchanged — write `cohesion-reviewed`, advance on APPROVED.
- **Single diff-review output** (`MODE: diff-review` sentinel, no combined headers): unchanged — write `diff-review-complete`, no phase advance.
- **Malformed combined output** (either section missing a `GATE_RESULT:`): skip both writes, log `combined_no_sentinel`, exit 0 (never blocks).

### 3. Dispatch Procedure Updates

- `prompt-b-product-build.md` Build Sequence — `review` phase row: dispatch one Critic call in combined mode; PM Advisory + UX Design Agent Mode 2/3 remain parallel siblings to the single Critic dispatch.
- `orchestrator.md` On-Demand Procedures — "Builder signals completion" row: single Critic dispatch in combined mode; targeted single-mode re-runs allowed after a fix.
- `_cohesion-review.md` Procedure — step 2 invokes Critic with `mode=combined`; step 5 (re-run) permits single-mode dispatch for surface-specific fixes.

### 4. Gate Semantics Unchanged

Gate A5 still requires both state files to exist with `GATE_RESULT: APPROVED`. BLOCKED in either section blocks commit. `pre-commit-gates.sh` reads the two state files identically to the pre-consolidation flow. `outcome-detector.sh` and `session-close-check.sh` are unaffected.

## Alternatives Considered

1. **Parallel two-dispatch via `Task` calls in one message** — Eliminates wall-time cost but not the model-call cost. Each `Task` still pays full prompt-assembly overhead (system prompt, agent definition, repeated diff). The duplication is in tokens consumed, not in elapsed seconds; parallelisation doesn't reach the cost being paid.

2. **Single mode renamed and old modes deleted** — Breaks backward compatibility with legacy session output (`MODE: diff-review` sentinel still appears in older `state-writer` payloads) and removes the targeted re-run path. The additive approach keeps single-mode dispatch valid for fix-focused re-runs without preserving a parallel implementation.

3. **State-writer combined detection via a new sentinel (e.g., `MODE: combined`)** — Adds a sentinel that duplicates information already encoded by the section headers. Detection via the two section headers is robust to malformed sentinels and keeps the output's structural intent (two sections) and routing signal (two files) aligned.

## Consequences

**Positive:**
- One model call replaces two for the most common review-phase action — same coverage, lower cost.
- Section-aware state-file routing keeps Gate A5 semantics identical: both state files, both APPROVED required.
- Combined and single-mode outputs coexist — no migration step needed for legacy sessions or in-flight workstreams.
- Output contract makes the dual-verdict structure explicit and human-readable (one Critic message, two named sections).

**Negative:**
- `state-writer.sh` gains a combined-detection branch (≈40 lines). The branch is directly load-bearing and covered by the layer-3 hook integration tests.
- Combined-output messages are longer than a single-mode message; total context fits well within the model's window for typical Prompt B review diffs, but very large diffs that previously pushed close to the cohesion-mode limit may need a forced split to single-mode dispatches. Not expected to be common.
- Re-run flow has a small new decision (combined vs. single-mode) — the cohesion-review procedure documents the heuristic (single-mode when only one surface had findings).

## References

- Decision t-0008: Cohesion Review Gate (gate A5 foundation)
- Decision t-0020: Task Contract System (contract verification within cohesion)
- Decision t-0014: Phase-Aware Flow Model (review-phase enforcement)
- `.claude/agents/critic.md` (mode definitions, combined output contract)
- `.claude/hooks/state-writer.sh` (section-aware routing)
- `docs/ai/quality-gates.md` § A5 (gate definition)
