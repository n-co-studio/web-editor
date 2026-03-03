# Advisory Board — Shared Reference

Shared context for all advisory board specialists. Read this before producing your brief.

---

## Purpose

Review compiled specs or feature briefs before build begins. Identify gaps, risks, contradictions, and opportunities. All findings are advisory — the operator decides what to act on.

**Also used by Prompt T (Brief mode):** Architect, Exploration, and Critic are dispatched for task-scoped analysis (feasibility, alternatives, risks). Same agents and brief format, lighter scope — see `docs/ai/prompts/prompt-t-task-definition.md`.

---

## Review Tiers

The Orchestrator selects a tier based on scope before dispatching any agents. The operator can override at any time ("run full board" or "skip review").

| Tier | When | Agents | Est. Cost |
|---|---|---|---|
| **Skip** | Single-file fix, docs-only, typo | None | 0 |
| **Lite** | Small feature, 1-3 files, bounded scope | Architect + Critic | Low |
| **Standard** | Multi-file feature, new endpoints, moderate complexity | Architect + Critic + Exploration | Medium |
| **Full** | New subsystem, architectural change, full spec review | Standard + conditional specialists | High |

**Defaults:**
- Feature briefs → Lite (operator can escalate)
- Full compiled specs → Standard
- Operator requests "full board" or spec touches 3+ signal categories → Full

**Complexity heuristic (Orchestrator applies before defaulting to Standard):**
- Low-complexity signals → prefer Lite even for multi-file specs: CRUD endpoint, add test, update docs, refactor existing, rename, formatting
- High-complexity signals → escalate to Standard even for feature briefs: new pattern, integration, migration, breaking change, new subsystem, auth, real-time

---

## Activation Logic

The Orchestrator scans compiled specs (or the feature brief's "What It Touches" checkboxes) for trigger signals:

| Signal Keywords | Activates (Full tier only) |
|---|---|
| auth, sessions, OAuth, tokens, permissions, login | Security Analyst |
| UI, design-system, user-flows, forms, components, responsive | UX Strategist |
| real-time, websockets, video, streaming, large-data, media, CDN | Performance Engineer |
| database, data-contracts, migrations, schema, GDPR, data-lifecycle | Data Strategist |

**Core pair (Lite+):** Architect, Critic — always active when advisory board runs.
**Extended (Standard+):** Exploration — active at Standard tier and above.
**Conditional (Full only):** Security Analyst, UX Strategist, Performance Engineer, Data Strategist — signal-triggered, Full tier only.

---

<!-- Sync Brief Format with _advisory-board-lite.md -->
## Brief Format

Each specialist produces a focused brief:

```
## [Specialist Name] Brief

**Scope reviewed:** [which spec files / feature brief]
**Activation signal:** [Always / specific trigger]

### Findings
1. [Finding] — CRITICAL / RECOMMENDATION / IDEA
   - Context: [why this matters]
   - Suggestion: [what to do about it]

2. [Next finding...]

### Summary
- Critical: [count]
- Recommendations: [count]
- Ideas: [count]
```

---

## Refinement Report

The Orchestrator synthesizes all specialist briefs into a single report:

```
## Advisory Board — Refinement Report

### Review Tier: [Lite / Standard / Full] — [reason or operator override]

### Activation Summary
| Specialist | Status | Trigger |
|---|---|---|
| Architect | Ran | Core (Lite+) |
| Critic | Ran | Core (Lite+) |
| Exploration | Ran / Skipped | Standard+ |
| Security Analyst | Ran / Skipped | [trigger or "no signal"] |
| UX Strategist | Ran / Skipped | [trigger or "no signal"] |
| Performance Engineer | Ran / Skipped | [trigger or "no signal"] |
| Data Strategist | Ran / Skipped | [trigger or "no signal"] |

### Critical Findings (must address before build)
[Numbered list from any specialist — severity CRITICAL]

### Recommendations (operator decides)
[Numbered list grouped by specialist]

### Ideas (from Exploration + nice-to-haves from others)
[Numbered list]

### Unresolved Critic Findings (no specialist coverage)
[Critic findings that no other specialist addressed — operator must provide direction or assign follow-up]
```

---

## Critic Cross-Reference

During synthesis (step 6 of the Orchestration Procedure below), the Orchestrator pairs Critic findings with solutions from other specialists:

1. For each Critic finding, scan other specialists' briefs for a finding that addresses the same concern
2. If a match exists, attach the specialist's suggestion to the Critic finding in the Refinement Report (listed under Critical Findings or Recommendations as normal, with the paired suggestion noted)
3. If no specialist addressed the Critic's concern, list it under **Unresolved Critic Findings** — the operator must provide direction or assign follow-up before build begins

This preserves the Critic's adversarial focus (problems only) while ensuring every identified problem surfaces with a path forward.

---

## Operator Review

The operator reviews the refinement report and responds per-item:
- **Accept** — integrate into spec or create follow-up task
- **Reject** — document reason, proceed without
- **Defer** — acknowledged, not blocking, revisit later

No build begins until the operator has reviewed all Critical findings.

---

## Constraints

- BLOCK: advisory agents do not modify files — enforced by disallowedTools (Edit, Write) in subagent frontmatter
- BLOCK: no sub-subagents — enforced by disallowedTools (Task) in subagent frontmatter
- BLOCK: no code execution — enforced by disallowedTools (Bash) in subagent frontmatter
- GUIDE: parallel execution — all activated specialists run simultaneously
- REQUIRE: spec is the input (spec mode) — advisory board agents review compiled specs and feature briefs, not source code (source code may not exist yet). The Critic also has a cohesion mode (see `critic.md`) where implementation code is the input — that mode runs during the build flow, not as part of advisory board review.
- Advisory agents read `_advisory-board-lite.md` (compressed shared context) and `_agent-glossary.md` — not this full file. Lite format briefs omit `Activation signal:` and merge `Context:` / `Suggestion:` into inline prose — the Orchestrator should expect either format during synthesis
- REQUIRE: actionable suggestions — every specialist (except Critic) must include a concrete, actionable suggestion with every finding. Never flag a concern without proposing a path forward

---

## Orchestration Procedure

When running Prompt A Phase 1 (advisory board review), the Orchestrator follows this sequence:

1. **Select tier** — Apply defaults from Review Tiers table (feature brief → Lite, full spec → Standard). If the operator specified a tier, use that instead. If Skip, stop here
2. **Scan** compiled specs for activation signals (see Activation Logic above) — only relevant at Full tier
3. **Activate** agents for the selected tier:
   - Lite: Architect + Critic
   - Standard: Architect + Critic + Exploration
   - Full: Standard set + any signal-triggered conditional specialists
4. **Dispatch** all activated specialists in parallel — each receives the compiled spec files
5. **Collect** individual briefs from each specialist
6. **Synthesize** into a single Refinement Report (see Refinement Report above):
   a. Merge all non-Critic findings directly (they already include suggestions)
   b. Cross-reference each Critic finding against other specialists' briefs — if a specialist addressed the same concern, attach their suggestion to the Critic finding
   c. Any Critic finding with no matching specialist suggestion → list under "Unresolved Critic Findings" in the report (operator must provide direction)
7. **Present** report to operator for per-item review (accept / reject / defer)
8. **Record** operator decisions — no build begins until all Critical findings are addressed

For feature briefs: scan the feature brief's "What It Touches" checkboxes for activation signals. Default tier is Lite.
