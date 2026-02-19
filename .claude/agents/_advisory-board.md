# Advisory Board — Shared Reference

Shared context for all advisory board specialists. Read this before producing your brief.

---

## Purpose

Review compiled specs or feature briefs before build begins. Identify gaps, risks, contradictions, and opportunities. All findings are advisory — the operator decides what to act on.

---

## Activation Logic

The Orchestrator scans compiled specs (or the feature brief's "What It Touches" checkboxes) for trigger signals:

| Signal Keywords | Activates |
|---|---|
| auth, sessions, OAuth, tokens, permissions, login | Security Analyst |
| UI, design-system, user-flows, forms, components, responsive | UX Strategist |
| real-time, websockets, video, streaming, large-data, media, CDN | Performance Engineer |
| database, data-contracts, migrations, schema, GDPR, data-lifecycle | Data Strategist |

**Always active:** Researcher, Architect, Critic, Innovator (lower priority).

---

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

### Activation Summary
| Specialist | Status | Trigger |
|---|---|---|
| Researcher | Ran | Always |
| Architect | Ran | Always |
| Critic | Ran | Always |
| Security Analyst | Ran / Skipped | [trigger or "no signal"] |
| UX Strategist | Ran / Skipped | [trigger or "no signal"] |
| Performance Engineer | Ran / Skipped | [trigger or "no signal"] |
| Data Strategist | Ran / Skipped | [trigger or "no signal"] |
| Innovator | Ran | Always |

### Critical Findings (must address before build)
[Numbered list from any specialist — severity CRITICAL]

### Recommendations (operator decides)
[Numbered list grouped by specialist]

### Ideas (from Innovator + nice-to-haves from others)
[Numbered list]

### Unresolved Critic Findings (no specialist coverage)
[Critic findings that no other specialist addressed — operator must provide direction or assign follow-up]
```

---

## Critic Cross-Reference

During synthesis (step 5 of the Orchestration Procedure below), the Orchestrator pairs Critic findings with solutions from other specialists:

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

- READ-ONLY: Advisory agents do not modify any files
- No sub-subagents: `disallowedTools: Task` on all advisory agents
- No code execution: Advisory agents cannot run Bash commands
- Parallel execution: All activated specialists run simultaneously
- Spec is the input (spec mode): Advisory board agents review compiled specs and feature briefs, not source code (source code may not exist yet). The Critic also has a cohesion mode (see `critic.md`) where implementation code is the input — that mode runs during the build flow, not as part of advisory board review.
- No `_agent-workflow.md` reading: Advisory agents read this file and `_agent-glossary.md` — not the build-phase workflow doc
- Actionable suggestions: Every specialist (except Critic) MUST include a concrete, actionable suggestion with every finding. Never flag a concern without proposing a path forward

---

## Orchestration Procedure

When running Prompt A Phase 1 (advisory board review), the Orchestrator follows this sequence:

1. **Scan** compiled specs for activation signals (see Activation Logic above)
2. **Activate** always-on specialists (Researcher, Architect, Critic, Innovator) plus any triggered conditional specialists
3. **Dispatch** all activated specialists in parallel — each receives the compiled spec files
4. **Collect** individual briefs from each specialist
5. **Synthesize** into a single Refinement Report (see Refinement Report above):
   a. Merge all non-Critic findings directly (they already include suggestions)
   b. Cross-reference each Critic finding against other specialists' briefs — if a specialist addressed the same concern, attach their suggestion to the Critic finding
   c. Any Critic finding with no matching specialist suggestion → list under "Unresolved Critic Findings" in the report (operator must provide direction)
6. **Present** report to operator for per-item review (accept / reject / defer)
7. **Record** operator decisions — no build begins until all Critical findings are addressed

For Feature mode: scan the feature brief's "What It Touches" checkboxes for activation signals.
