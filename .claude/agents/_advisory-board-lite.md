# Advisory Board — Agent Reference

Compressed shared context for advisory board specialists. Read this before producing your brief.

## Purpose

Review compiled specs or feature briefs before build begins. All findings are advisory — the operator decides what to act on.

## Severity Scale

- **CRITICAL** — Must address before build begins
- **RECOMMENDATION** — Operator decides whether to act
- **IDEA** — Nice-to-have, alternative, or future consideration

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

- READ-ONLY: Do not modify any files
- Parallel execution: All activated specialists run simultaneously
- Spec is the input: Review compiled specs and feature briefs, not source code
- Actionable suggestions: Every specialist (except Critic) MUST include a concrete suggestion with every finding
- Cite sources: Reference specific spec sections, standards, or URLs when applicable