# Quality Gates — Compressed Reference

> This is a compressed reference for context-efficient loading. The full file (`docs/ai/quality-gates.md`) is authoritative.
> **Maintenance obligation:** update this file whenever `quality-gates.md` changes.

## Commit Gates (A)

| Gate | Summary | State File |
|------|---------|-----------|
| **A1 Decision Compliance** | All applicable decisions followed; conflicts → new decision record first. Trigger parser enforces mechanically (sentinel: `docs/ai/decisions/.a1-triggers-enforced`). | — (trigger index: `docs/ai/decisions/.a1-trigger-index`) |
| **A2 Process** | Plan before code. Session log updated at close. Scope >100 lines requires `large-scope: true` in `plan-approved`. Hotfix: scope limit relaxed. | `plan-approved` |
| **A3 Quality** | Formatter, lint, build/compile pass (when tooling exists). | — |
| **A4 Safety** | No secrets/PII. High-risk path/content detection → Reviewer + Security sign-off. Automation-specific: no unbriefed network calls, new deps, or out-of-repo writes. | `reviewer-signed`, `security-signed` |
| **A5 Cohesion** _(standard+ only)_ | Critic cohesion review clean. Contract `verification:` criteria evaluated (advisory). | `cohesion-reviewed` |
| **A6 Task Group** _(taskgroup only)_ | Contract with `status: in_progress` exists; modified contract YAML staged. | — (contract file check) |

## Push Gates (B)

| Gate | Summary |
|------|---------|
| **B1 Process** | Branch name matches `<category>/<description>`. Meaningful commit message. |
| **B2 Quality** | Tests pass. Typecheck passes (when tooling exists). |
| **B3 Safety** | Dependency audit if deps changed. No debug flags left enabled. |

## Branch / Session-Type Gate Profiles

| Branch / Session Type | Gate Profile |
|----------------------|-------------|
| `main` | All gates (A + B). No direct commits. |
| `release/*` | All gates + C gates (release checklist, full test suite, Reviewer + Security sign-off). |
| `feature/*`, `fix/*` | Standard gates (A + B). |
| `hotfix/*` | Expedited: A2 scope relaxed, A5 skipped. A1, A3, A4, B1–B3 still apply. |
| `experiment/*` | A4 only. Must not merge to main without full gates. |
| `standard`, `taskgroup`, `taskgroup-merge` | Full gates (A1–A6, B1–B3). A6: taskgroup/taskgroup-merge only. |
| `hotfix` session | A2 scope relaxed, A5 skipped. |
| `experiment`, `prototype-*` | A4 safety only. |
| `spec-fresh`, `spec-update`, `advisory-*` | Advisory only. |
| `audit` | Read-only (no gates unless deferrals create file changes). |
| `taskdef-query`, `taskdef-brief` | No gates (fully ephemeral). |

## State File Summary

| File | Gate | Notes |
|------|------|-------|
| `plan-approved` | A2 | Required for scope check; reads `large-scope: true` flag |
| `cohesion-reviewed` | A5 | Skipped on `hotfix/*` |
| `reviewer-signed`, `security-signed` | A4 | Required on high-risk detection |
| `pragmatist-signed` | Plan-gating | Written by Pragmatist plan-review; checked at commit time |
| `.claude/local/closed-branches` | Session isolation | Persistent ledger (not session-scoped) |

Recovery: `REPO_OS_RECOVER=1` skips all state-dependent checks.
