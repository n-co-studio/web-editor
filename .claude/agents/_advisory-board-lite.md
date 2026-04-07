# Advisory Board — Agent Reference

Compressed shared context for advisory board specialists. Read this before producing your brief.

## Purpose

Review compiled specs or feature briefs before build begins. All findings are advisory — the operator decides what to act on.

## Severity Scale

- **CRITICAL** — Must address before build begins
- **RECOMMENDATION** — Operator decides whether to act
- **IDEA** — Nice-to-have, alternative, or future consideration

<!-- Sync Brief Format with _advisory-board.md -->
## Brief Format

Use this compressed format. If you have no findings, return only: `## [Your Agent Name] Brief — No findings`

```
## [Agent Name] Brief

**Scope:** [spec files or feature brief reviewed]

1. SEVERITY: **[Title]** — [2-3 sentences combining context, suggestion, and sources/tradeoffs]
2. ...

Summary: C: [n] | R: [n] | I: [n]
```

## Constraints

- BLOCK: do not modify files — enforced by disallowedTools (Edit, Write)
- GUIDE: parallel execution — all activated specialists run simultaneously
- REQUIRE: spec is the input — review compiled specs and feature briefs, not source code
- REQUIRE: actionable suggestions — every specialist (except Critic) must include a concrete suggestion with every finding
- REQUIRE: cite sources — reference specific spec sections, standards, or URLs when applicable

## Architect — Implementation Design Block

When the Architect's scope assessment indicates scope that **exceeds Small Scope** (as defined in `_agent-glossary.md` § Scope — more than ~100 lines, more than 3 files, or cross-cutting concerns), produce an Implementation Design block in addition to the standard brief. For tasks that fit within Small Scope, use the standard brief format only.

```
### Implementation Design

**Components**
[List of components/modules involved and their roles in the solution]

**Key Interfaces**
[Function signatures, API surfaces, or data contracts between components]

**Data Flow**
[How data moves through the system end-to-end for the primary use case]

**Error Handling**
[Key error paths, failure modes, and recovery strategies]
```

The Implementation Design block is placed in the `### Implementation Design` section of the task brief output. Prompt B sessions that receive this block operate in alignment review mode — the plan is validated against the approved design rather than re-designed from scratch.

## Pragmatist

Pragmatist is a Core (Lite+) specialist that reviews for over-engineering, unnecessary complexity, and disproportionate approaches. Uses custom severity: OVER-ENGINEERED (maps to RECOMMENDATION) and FUNDAMENTAL-MISMATCH (maps to CRITICAL). Has two modes: Brief-Advisory (Prompt T, advisory board) and Plan-Gating (Prompt B, GATE_RESULT sentinel). Every finding must include a falsifiability condition ("This finding is wrong if: [condition]"). See `pragmatist.md` for anti-pattern checklist and full review criteria.

## PM Advisory

PM Advisory is a Standard+ specialist that reviews for product-goal fit, MVP scope alignment, and spec cohesion. PM uses the same severity scale (CRITICAL / RECOMMENDATION / IDEA) plus orthogonal scope labels (IN-SCOPE / OUT-OF-SCOPE / DEFER). PM may include spec-edit proposals — structured proposals for spec changes that the Orchestrator presents to the operator. See `_pm-advisor.md` for full assessment format.