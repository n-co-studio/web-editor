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

## PM Advisory

PM Advisory is a Standard+ specialist that reviews for product-goal fit, MVP scope alignment, and spec cohesion. PM uses the same severity scale (CRITICAL / RECOMMENDATION / IDEA) plus orthogonal scope labels (IN-SCOPE / OUT-OF-SCOPE / DEFER). PM may include spec-edit proposals — structured proposals for spec changes that the Orchestrator presents to the operator. See `_pm-advisor.md` for full assessment format.