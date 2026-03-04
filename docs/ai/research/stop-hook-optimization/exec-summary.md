# Executive Summary: Stop Hook Optimization

**Task Group:** stop-hook-optimization (Brief 4 of 4)
**Date:** 2026-03-03
**Status:** Complete
**Advisory Board:** Full (7 agents -- Architect, Performance Engineer, Security Analyst, Critic, Exploration, Data Strategist, UX Strategist)

---

## Problem Statement

The Repo OS hook system fires ~37.8 hooks per session across 460 measured sessions (Brief 1). While 94.2% of individual invocations complete in under 10ms (Brief 3), the session-close-check.sh stop hook creates disproportionate waste through its block-retry-block loop:

| Metric | Value | Source |
|--------|-------|--------|
| Sessions hitting stop hook | 455/460 (98.9%) | B1 |
| First-close failure rate | 38% (172/455 sessions) | B1 |
| Safety valve fires (3 attempts exhausted) | 10-16% of sessions | B1, B2 |
| Retry token overhead (estimated) | ~200,000 tokens across analysis period | B2 (order-of-magnitude) |
| BLOCKED message per retry | ~400-500 bytes stderr (~100-120 tokens) | B2 |
| Per-retry model processing cost | 600-1,400 tokens (input + reasoning + output) | B2 |
| Zero-change sessions (full check pipeline, no changes) | 36.3% (165 sessions) | B1 |
| Task group session block rate | 0% | B2 |
| Standard session share of blocks | 81% | B2 |

**Root cause:** The stop hook fires when Claude attempts to stop, but the agent's close sequence is supposed to run *before* the stop attempt. When the agent follows the sequence correctly, all checks pass. single_pass_block (91.4% of all blocks) represents the agent mid-close-sequence, not non-compliant -- the hook is essentially forcing the agent to do what it was already doing, at a cost of ~600-1,400 tokens per retry cycle.

**Data confidence caveat:** Token estimates use a ~4 chars/token heuristic with +/-20% stated uncertainty. Brief 2's dataset is 98.3% phase-test repos (automated test suites), not real agent sessions. The three briefs use non-overlapping dataset slices that produce different aggregate counts (B1: 680, B2: 1,042, B3: 1,719 session-close-check events). All figures should be treated as order-of-magnitude estimates, not engineering commitments.

---

## Key Findings

### 1. The stop hook's primary waste is token injection during retry loops, not execution time

Hook execution time is minimal (~113-203ms per invocation). The real cost is the 400-500 bytes of stderr injected into model context on each block, plus the model's ~500-1,200 token response processing each retry. The stop hook's close-sequence instructions (lines 562-567) duplicate prompt content, consuming ~60 tokens per retry with zero incremental value.

**Evidence:** B1 S5, B2 S2. Architect finding 8, UX finding 5.

### 2. The Claude Code API provides two unused capabilities that directly address the top waste sources

stop_hook_active (boolean field in Stop hook input JSON) enables retry detection without file I/O. JSON stdout output (decision, reason, systemMessage) enables controlled context injection -- reason goes to Claude (~15-25 tokens) while systemMessage goes to the operator (zero token cost). Neither capability is currently used by session-close-check.sh.

**Evidence:** B2 S3-4. Security finding 6 (P2 is governance-positive).

### 3. Only 1 of 4 blocking checks is essential for data safety; 3 are moveable to advisory

Uncommitted changes (gate 2) is the only check preventing data loss -- there is no alternative enforcement at close time. Session log (gate 1), HVST documentation (gate 3), and deferrals (gate 4) are governance artifacts that the agent prompt already requires. Moving gates 3-4 to advisory carries minimal risk. Gate 1 requires a nuanced approach -- keep blocking for sessions with committed changes; the zero-change downgrade already handles the Q&A case.

**Evidence:** B2 S5. Security findings 2-3 (minimum viable hook set). Critic finding 4 (compliance threshold unstated). Data Strategist finding 10 (classification rests on thin real-repo data -- 18 events).

### 4. Repo OS's git-transaction-boundary enforcement is architecturally unique and must be preserved

External research across 8 frameworks (Cursor, Windsurf, Aider, LangGraph, CrewAI, MCP, Guardrails AI, NeMo) confirms Repo OS is the only system enforcing governance at the git transaction boundary. This property is actor-independent (fires for human and AI) and bypass-resistant (shell hooks immune to prompt manipulation). Any proposal that converts this to probabilistic enforcement (T3-B advisory-only stop hook, T3-A minimal hybrid) is unacceptable for production.

**Evidence:** B3 S3-4, S7. Security finding 7.

### 5. The research datasets have significant methodological limitations that bound recommendation confidence

Three non-overlapping datasets produce irreconcilable aggregate counts. B2's 98.3% phase-test population means token savings projections are extrapolated from 18 real-repo events. Duration measurements use 1-second buckets (B3) or 5-run averages on a single hardware platform (B1). No brief defines a before/after measurement protocol. Recommendations should be implemented with measurement validation, not assumed to deliver projected savings.

**Evidence:** Critic findings 1-2. Data Strategist findings 1-4, 8. Performance Engineer findings 1-2.

---

## Recommended Approach

### Phase 1 -- Quick Wins (zero governance risk)

Changes that reduce token waste without touching governance boundaries. Implement immediately.

| Step | Description | Effort | Dependency | Governance Impact | Rollback |
|------|-------------|--------|------------|-------------------|----------|
| 1a | **Remove close-sequence instructions from stderr** (P5). Delete lines 562-567 of session-close-check.sh -- these duplicate prompt content | S | None | Neutral -- removes redundant instructions | Re-add 6 lines |
| 1b | **Use stop_hook_active for retry fast-path** (P1). Parse field from input JSON; on retry, skip advisory checks (governance evidence, override audit, next-brief reminder) and run only previously-blocking checks | S | None | Neutral -- all blocking checks still run on first attempt | Remove conditional branch |
| 1c | **Promote zero-change detection above library sourcing** (Exploration R2). Check .session-baseline-sha and git diff --name-only before source statements; exit early for zero-change sessions without sourcing ~14ms of libraries | S | None | Neutral -- zero-change sessions already downgrade to advisory | Move source lines back |
| 1d | **Add safety valve to override audit** (Security R1/R4). Call log_override when the 3-attempt valve fires, making it visible in the session override audit | S | None | Strengthen -- previously invisible governance escape now auditable | Remove one line |

**Expected impact:** ~60 tokens/retry saved (1a), ~40% retry processing reduced (1b), ~25s sourcing overhead for zero-change sessions eliminated (1c), safety valve audit gap closed (1d).

### Phase 2 -- Governance-Neutral Refactors (same integrity, different mechanism)

Changes that maintain identical governance guarantees through different mechanisms. Implement after Phase 1 telemetry confirms baseline.

| Step | Description | Effort | Dependency | Governance Impact | Rollback |
|------|-------------|--------|------------|-------------------|----------|
| 2a | **Migrate to JSON stdout output** (P2). Replace exit 2 + stderr with exit 0 + JSON (decision/reason/systemMessage). Requires stdout-hygiene audit of all sourced helpers first (Architect C2) | M | Phase 1 complete; stdout-hygiene audit | Strengthen -- tighter control over model context; override hints moved to operator-only systemMessage | Revert to exit 2 + stderr |
| 2b | **Downgrade HVST + deferrals checks to advisory** (P4). Change add_failure to advisory echo for gates 3-4 | S | None (independent) | Weaken (minimal) -- knowledge-capture checks, not safety. Agent prompt compliance estimated 90-95% | Change back to add_failure |
| 2c | **Fast-path library sourcing elimination** (T1-A). Move source statements after fast-exit checks in all hooks that have pre-source fast paths | S | None | Neutral | Move source lines back |
| 2d | **Establish measurement baseline** (Data Strategist R8). Before Phase 3 decisions, collect 2-3 weeks of post-Phase-2 telemetry with real-repo filtering and millisecond-resolution duration recording | S | Phase 2a-c deployed | N/A -- observability improvement | N/A |

**Expected impact:** ~75-95 tokens/retry saved (2a), retry advisory clutter eliminated (2b), ~100-300ms/session sourcing saved (2c), decision confidence for Phase 3 established (2d).

### Phase 3 -- Architectural Evolution (requires operator decision)

Changes that alter the governance model. Implement only after Phase 2 telemetry validates savings and operator explicitly approves governance posture change.

| Step | Description | Effort | Dependency | Governance Impact | Rollback |
|------|-------------|--------|------------|-------------------|----------|
| 3a | **Consolidate write-guard + branch-guard for Bash calls** (T1-B). Single hook entry point, single stdin read, single JSON parse. Choose T1-B OR T2-A -- not both (Architect R4) | M | Phase 2 telemetry | Neutral if guards are proven idempotent (Critic R8 -- verify no ordering dependency) | Split back to two hooks |
| 3b | **Session intent classification at init** (Exploration I5). Route Q&A/exploration sessions to ephemeral session types at open, eliminating zero-change overhead entirely. Adds a lightweight intent gate at init | M | Phase 2 telemetry | Neutral -- ephemeral types already exempted | Remove intent gate |
| 3c | **Monitoring KPI dashboard** (Data Strategist I11). Track 5 KPIs: real-repo block rate, retry depth distribution, per-hook P50/P90/P99 duration, safety valve rate, token cost per session | M | Phase 2d baseline | N/A -- observability | N/A |

**Expected impact:** ~300-600ms/session saved from guard consolidation (3a), ~36% of sessions reclassified to fast path (3b), ongoing optimization decisions become data-driven (3c).

### NOT Recommended

| Proposal | Reason | Source |
|----------|--------|--------|
| **T3-B: Advisory-only stop hook** | Collapses actor-independent mechanical enforcement -- Repo OS's core architectural differentiator. ~50% compliance reduction expected | Security R7, B3 S3a |
| **T3-A: Minimal-hook hybrid** | Creates governance gap between edit and commit time. Mode guard unreliable via prompts | B3 S3c, Security minimum viable hook set |
| **P3: Session log to full advisory** | Removes the only post-sequence cross-check that a session completed its governance sequence (for non-zero-change sessions). The zero-change carveout already handles Q&A sessions | Security C2, Performance R7 |
| **P7: State file for targeted retry** | Hidden dependency on P1 (Architect C1). Marginal returns (+20% on P1) with medium complexity. P1 alone captures most retry improvement | Architect C1, Performance I9 |
| **T3-D: Prompt + agent handler hybrid** | Probabilistic enforcement, negative latency impact from LLM evaluation | B3 S3, Security |
| **T2-C: Stop hook completion-marker pattern** | Structurally distinct from P7 (T2-C signals full close-sequence completion; P7 records per-check failure state). Deferred -- requires further design to avoid duplication with existing merge-source-branch mechanism (Architect C3). Evaluate after Phase 2 | Architect C3, B3 S5 |
| **T2-B: Mode-guard to SessionStart** | Eliminates 29.2% of invocations by computing mode once at SessionStart. Performance endorses as top ROI but API limitation (CLAUDE_ENV_FILE only available to Bash calls, not hook processes) narrows benefit significantly (B3 S3b). Deferred to Phase 3 evaluation | B3 S3b, Performance R3 |

---

## Governance Impact Assessment

### Mechanical Guarantees Preserved

- **Pre-commit gates** (A1-A6, B1-B3): Completely unchanged. Secret scanning, decision trailers, scope verification, contract compliance -- all remain mechanical at git transaction boundary
- **Uncommitted changes check** (stop hook gate 2): Remains blocking in all phases. Last line of defense against data loss at session close
- **Session log check** (stop hook gate 1): Remains blocking for all sessions with committed changes. Zero-change sessions already exempt (current behavior)
- **Branch isolation** (Decision 0013): Unchanged. Write-guard and branch-guard enforcement unaffected
- **Phase-aware flow** (Decision 0014): Unchanged. Phase enforcement via branch-guard unaffected
- **State-guard protection**: .claude/.state/ write protection unchanged

### Mechanical Guarantees Modified

- **HVST documentation check** (stop hook gate 3): Blocking to Advisory (Phase 2b). Agent prompt still requires documentation; hook provides reminder instead of block. Risk: ~5-10% of sessions with 2+ HVST failures may skip documentation
- **Deferrals documentation check** (stop hook gate 4): Blocking to Advisory (Phase 2b). Same risk profile as gate 3. Both gates fire rarely (only when specific conditions met)

### New Enforcement Mechanisms

- **stop_hook_active retry differentiation** (Phase 1b): First attempt runs all checks; retries target only previously-failed checks. Net effect: same coverage, fewer redundant checks
- **JSON stdout output** (Phase 2a): reason field provides controlled, concise context to Claude; systemMessage provides full details to operator. Override hints no longer consume model attention
- **Safety valve audit visibility** (Phase 1d): Safety valve fires now appear in override audit, closing a governance observability gap

### Net Governance Posture Change

**Strengthened** on the model-context control axis (P2 tightens what the model sees), **unchanged** on the commit-gate axis (pre-commit gates untouched), **slightly relaxed** on the close-sequence knowledge-capture axis (HVST/deferrals advisory). The core guarantee -- mechanical enforcement at the git transaction boundary -- is fully preserved.

---

## Proposed Decision

**Title:** Decision NNNN -- Stop Hook Optimization Phase 1-2
**Status:** Proposed
**Mechanism:** REQUIRE (implementation follows phased rollout with telemetry validation)

**Summary:** Optimize session-close-check.sh to reduce token waste from block-retry loops while preserving governance integrity. Phase 1 implements zero-risk quick wins (remove duplicate instructions, use stop_hook_active for retry fast-path, lazy library sourcing, safety valve audit). Phase 2 migrates to JSON stdout output and downgrades HVST/deferrals to advisory. Phase 3 deferred pending telemetry. All pre-commit gates unchanged. Uncommitted changes and session log (non-zero-change) remain blocking.

---

## Advisory Board Debate Summary

### Key Agreements (all/most specialists endorse)

1. **P2 (JSON stdout) is the strongest single proposal** -- Architect endorses with stdout-hygiene audit requirement; Performance ranks it top ROI; Security classifies it as governance-positive (tightens model-context control); UX identifies it as prerequisite for better DX
2. **P5 (remove close-sequence instructions) should be implemented first** -- Architect (lowest-risk, highest-clarity); UX (duplicate instructions violate single source of truth)
3. **T3-B (advisory-only stop hook) is unacceptable for production** -- Security (collapses actor-independent enforcement); Architect (architectural regime change); B3 external research confirms ~50% compliance reduction
4. **Dataset limitations must be acknowledged in all quantitative claims** -- Performance, Critic, Data Strategist all flag measurement conflicts, phase-test contamination, and insufficient real-repo sample size
5. **Token savings are order-of-magnitude estimates, not precision figures** -- Three specialists independently flag +/-20% error propagation and phase-test data contamination
6. **Uncommitted changes (gate 2) is the non-negotiable blocking check** -- Security (data loss prevention, last line of defense); B2 essential/moveable classification

### Key Disagreements

**1. P3 (session log to advisory)**
- *For*: Performance (reduces blocks), UX (improves DX if operator informed), B2 (90-95% compliance without blocking)
- *Against*: Security (removes cross-session audit guarantee for non-zero-change sessions), Performance (hidden regression -- baseline hash corruption), Critic (classification not tied to governance risk model)
- *Resolution*: **Keep current behavior.** The zero-change carveout already handles Q&A sessions (the dominant false-positive population). For sessions with committed changes, the session log block provides the only mechanical verification that the governance sequence completed. The ~1K tokens/session savings from P3 does not justify the governance regression.

**2. P1 vs P7 vs sentinel file for retry optimization**
- *P1 (stop_hook_active)*: Architect endorses with P7 subordination rule; Security confirms governance-neutral (API field not model-writable)
- *P7 (state file for targeted retry)*: Architect flags hidden dependency on P1; Performance questions "+20%" claim derivation
- *Sentinel file* (Exploration): Simpler mechanism but introduces new state file
- *Resolution*: **Implement P1 alone.** It uses an existing API capability, requires no new state files, and captures the majority of retry improvement. P7's marginal gains don't justify the complexity. Prototype P1 to validate stop_hook_active is reliable across session types before full integration.

**3. Implementation ordering (time-axis vs token-axis)**
- Architect recommends: P5 then P1 then P2 then P4 then T1-A (dependency-driven, risk-ordered)
- Performance recommends: P6 (P1+P2 combined) + T2-B as top priority pair (ROI-driven)
- *Resolution*: **Follow Architect's dependency ordering.** P5 first (validates telemetry pipeline), P1 second (adds retry fast-path), P2 third (requires stdout audit). The Performance ROI ranking is directionally correct but combining P1+P2 into P6 on day one introduces the stdout-hygiene risk the Architect identified.

**4. T1-B (guard consolidation) vs T2-A (unified dispatcher)**
- Architect: mutually exclusive paths -- choose one per implementation cycle
- Performance: T2-B (mode-guard to SessionStart) as higher ROI
- *Resolution*: **Defer to Phase 3.** Evaluate after Phase 2 telemetry confirms whether per-tool-call overhead is still a material cost center post-optimization.

### Minority Opinions Preserved

- **Exploration**: Session intent classification at init (finding 5) could eliminate zero-change overhead at the source rather than optimizing the detection path. The board agrees this is architecturally sound but defers it to Phase 3 as it requires orchestrator prompt changes and operator workflow modification.
- **Data Strategist**: The essential/moveable classification (B2 S5) rests on 18 real-repo events -- statistically insufficient for confident governance decisions. A minimum of 100 real-repo sessions should be analyzed before any blocking check is permanently downgraded. The board recommends Phase 2d (measurement baseline) addresses this before Phase 3 decisions.
- **Critic**: No brief addresses concurrent session race conditions for proposed caching (T1-C) or completion marker (T2-C) mechanisms targeting .claude/.state/. The board notes this applies to Phase 3 proposals only and should be analyzed before those implementations proceed.
- **UX Strategist**: Progressive governance feedback (inline validation during session rather than batch validation at close) is the long-term architectural direction that would eliminate the block-retry pattern entirely. The board agrees but classifies this as a future research direction beyond the current optimization scope.
