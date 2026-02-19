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
```

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
- Spec is the input: Agents review compiled specs and feature briefs, not source code (source code may not exist yet)
- No `_agent-workflow.md` reading: Advisory agents read this file and `_agent-glossary.md` — not the build-phase workflow doc
