# Prompt C — Project Audit

Read and follow `AI.md`. Read all files referenced in AI.md's source-of-truth sections.

## Phase Sequence

Phase sequences are defined in `_agent-glossary.md` § Phase Model and enforced by `_phase-helper.sh`. See Decision 0014 for canonical definitions. Audit: `init → scope → dispatch → synthesize → op-review → close`. The close phase is lightweight — zero-change unless deferrals produce file modifications.

## Project Context

Read `docs/spec/compiled/manifest.json` to check for an active spec version. If an active version exists, read all compiled spec files for grounding context. The spec state determines which dimensions are available (see Pre-Spec Behavior below).

## Dimension Menu

Select which dimensions to audit. Not all-or-nothing — pick what's relevant.

| Dimension | Agent | Mode / Scope | Specialist eligible for co-audit |
|---|---|---|---|
| Spec drift | Auditor | `drift` | Architect |
| Decision compliance | Auditor | `compliance` | — |
| Cohesion drift | Auditor | `cohesion-drift` | Architect |
| Security | Security/Privacy | full-codebase scope | Security Analyst (spec-level) |
| Performance | Performance Engineer | code-review scope | — (already specialist) |
| Governance | Auditor | `governance` | Analytics |
| Tech debt | Auditor | `tech-debt` | Analytics |
| Dependency health | Security/Privacy | full dep audit | — |

## Depth Tiers

The operator selects a tier, or the Orchestrator defaults based on context.

| Tier | When | Dimensions |
|---|---|---|
| **Quick** | Routine check-in | Governance + Security |
| **Standard** | Milestone or pre-release | Operator-selected dimensions (tech-debt available) |
| **Deep** | Full health audit | All dimensions |

Tech debt is available at Standard and Deep tiers. Not included in Quick tier.

If no tier is specified:
- Operator selected specific dimensions → **Standard**
- Operator said "full audit" or "health check" → **Deep**
- Operator asked about a single concern → **Standard** with that dimension only

## Pre-Spec Behavior

If `manifest.json` has `"active": null` (no compiled specs):

| Dimension | Behavior |
|---|---|
| Spec drift | **Skip** — no spec to compare against |
| Decision compliance | **Run** — works on decision records alone |
| Cohesion drift | **Run** — works on code alone |
| Security | **Run** — works on code alone |
| Performance | **Run** — works on code alone |
| Governance | **Degrade** — check session log and known issues only, skip decision staleness |
| Tech debt | **Run** — governance-scoped when no product code exists (categories 1–4 only; categories 5–7 adapt to available file types) |
| Dependency health | **Run** — works on code alone |

Inform the operator which dimensions were skipped or degraded and why.

## Dispatch

The Orchestrator dispatches selected dimensions in parallel:

- **Auditor dimensions** (drift, compliance, cohesion-drift, governance, tech-debt): Dispatch Auditor via Task with the mode specified. Each mode runs as a separate Task dispatch.
- **Security dimension**: Dispatch Security/Privacy via Task with explicit scope: "Full-codebase security review — not scoped to a diff or spec. Audit all source code for vulnerabilities, secrets, and security risks."
- **Performance dimension**: Dispatch Performance Engineer via Task with explicit scope: "Full-codebase performance review — not scoped to a diff or spec. Audit source code for performance issues, inefficient patterns, and optimization opportunities."
- **Dependency health dimension**: Dispatch Security/Privacy via Task with explicit scope: "Full dependency audit — check all dependency manifests for known vulnerabilities, outdated packages, and supply chain risks."

### Specialist Collaboration Dispatch

Three collaboration patterns (operator-selected):

**Escalation** — Automatic. When Auditor findings include `[ESCALATE: agent-name]` tags, the Orchestrator dispatches the named specialist with the finding context after the Auditor completes. One-shot.

**Co-audit** — Operator requests a specialist alongside a dimension (e.g., "audit drift with Architect"). Dispatch both the Auditor and the named specialist in parallel on the same scope. Merge their briefs during synthesis.

**Workshop** — Operator requests iterative review for a dimension. Run the loop:

1. Dispatch Auditor → collect findings
2. Dispatch specialist with Auditor findings → collect response
3. Dispatch Auditor with specialist response → collect refined findings
4. Cap at 2 rounds, then surface to operator regardless

Follows the cohesion review loop precedent from `.claude/agents/_cohesion-review.md`.

## Synthesis

The Orchestrator merges all dimension briefs into a single Audit Report:

```
## Audit Report

### Tier: [Quick / Standard / Deep]
### Dimensions: [which ran]

### Critical Findings
[Numbered, grouped by dimension, with specialist collaboration notes if escalated]

### Recommendations
[Numbered, grouped by dimension]

### Ideas
[Numbered]

### Dimension Summary
| Dimension | Findings | Critical | Status |
|---|---|---|---|
| Spec drift | 3 | 1 | Needs attention |
| Security | 0 | 0 | Clean |
| ... | | | |

### Skipped Dimensions
[Which were skipped and why — pre-spec, operator choice, etc.]
```

## Operator Review

Same pattern as the advisory board: the operator reviews the Audit Report and responds per finding:

- **Accept** — acknowledged, will address (operator may start a Prompt B session to remediate)
- **Reject** — not a real issue, document reason
- **Defer** — acknowledged, not blocking, revisit later

No auto-remediation — audit is read-only. The operator decides what action to take.

## Rules

- REQUIRE: **never write files.** Prompt C is read-only. All output goes to the terminal. **Exception:** Sessions that produce operator deferrals write to `known-issues.md` (Known Limitations table) and `.claude/.deferrals-pending` only — no other file modifications. The session is no longer zero-change, so follow the Close Sequence in `docs/ai/workflow.md` (update session log, commit deferral files and session log, present closing summary).
- REQUIRE: **never create session log entries.** Zero-change rule — no commits, no artifacts. Audit sessions are exempt. Does not apply when the deferral exception above is active.
- BLOCK: **specialist collaboration is Orchestrator-mediated** — enforced by disallowedTools (Task) on the Auditor. The Orchestrator detects escalation tags and handles all specialist dispatch.
- GUIDE: **cap workshop loops at 2 rounds**, then surface to operator.
- GUIDE: **context management** — each dimension scopes its scan (Glob patterns, file type filters) rather than loading the entire codebase. The Auditor defines scan boundaries per mode in its agent definition.
- GUIDE: **finding prioritization** — auditor caps findings at ~10 per dimension, CRITICAL first. Note if truncated.
- REQUIRE: **inform on skips** — always tell the operator which dimensions were skipped or degraded, and why (pre-spec, operator choice, etc.).

## Close Sequence

At close: update session log, commit all changes, present closing summary. See `docs/ai/workflow.md` Close Sequence. For zero-change audit sessions (no deferrals), the session log requirement is exempt.
