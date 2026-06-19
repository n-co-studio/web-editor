# Quality Gates — Compressed Reference

> This is a compressed reference for context-efficient loading. The full file (`docs/ai/quality-gates.md`) is authoritative.
> **Maintenance obligation:** update this file whenever `quality-gates.md` changes.

## Commit Gates (A)

| Gate | Summary | State File |
|------|---------|-----------|
| **A1 Decision Compliance** | All applicable decisions followed; conflicts → new decision record first. Trigger parser enforces mechanically (sentinel: `docs/ai/decisions/.a1-triggers-enforced`). | — (trigger index: `docs/ai/decisions/.a1-trigger-index`) |
| **A2 Process** | Plan before code. Session log updated at close. Scope >100 lines requires `large-scope: true` in `plan-approved`. Hotfix: scope limit relaxed. | `plan-approved` |
| **A3 Quality** | Formatter, lint, build/compile pass (when tooling exists). **A3.3**: `tsc --noEmit --incremental` passes (skips without `tsconfig.json`; override: `SKIP_BUILD_CHECK=1`). **A3.4**: In headless/auto, runs `package.json` scripts (`build`, `build:pack`, `test`, `verify`) + `npm pack --dry-run`; blocking when no human backstop, advisory otherwise; writes `functional-verified`; override: `SKIP_FUNC_CHECK=1`; Decision 0044. | `functional-verified` (headless/auto only) |
| **A4 Safety** | No secrets/PII. High-risk path/content detection → Reviewer + Security sign-off. Automation-specific: no unbriefed network calls, new deps, or out-of-repo writes. | `reviewer-signed`, `security-signed` |
| **A5 Cohesion** _(session types with review phase only)_ | Two parallel checks — both APPROVED required. **Cohesion**: Critic (cohesion mode) clean; `GATE_RESULT: APPROVED` in `cohesion-reviewed`. **Diff-review**: Critic (diff-review mode) clean; `GATE_RESULT: APPROVED` in `diff-review-complete`. Contract `verification:` criteria evaluated (advisory). Completeness pass: each criterion scored COMPLETE/INCOMPLETE/PARTIAL; INCOMPLETE triggers loop-back to Builder (advisory, 2-round cap). Session-type-aware: skips for hotfix and other types without review phase. | `cohesion-reviewed`, `diff-review-complete` |
| **A6 Task Group** _(taskgroup only)_ | **A6.1**: Contract with `status: in_progress` exists. **A6.2**: Modified contract YAML staged. **A6.3**: Each `integration_points[].artifact` in contract exists in working tree (file-existence check). | — (contract file check) |

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
| `hotfix/*` | Expedited: A2 scope relaxed, A5 skipped (no review phase). A1, A3, A4, B1–B3 still apply. |
| `experiment/*` | A4 only. Must not merge to main without full gates. |
| `standard`, `taskgroup`, `taskgroup-merge` | Full gates (A1–A6, B1–B3). A5 includes cohesion + diff-review. A6 (including A6.3): taskgroup/taskgroup-merge only. |
| `hotfix` session | A2 scope relaxed, A5 skipped. |
| `experiment`, `prototype-*` | A4 safety only. |
| `spec-fresh`, `spec-update`, `advisory-*` | Advisory only. |
| `audit` | Read-only (no gates unless deferrals create file changes). |
| `queue-triage` | No gates (fully ephemeral). |
| `taskdef-query` | No gates (fully ephemeral). |
| `editor-live` | Per-loop: A4 only. Close: full gates minus plan-approved. |
| `taskdef-brief` | Plan-approved gate only (Decision 0029). |

## State File Summary

| File | Gate | Notes |
|------|------|-------|
| `plan-approved` | A2 | Required for scope check; reads `large-scope: true` flag. Written by `plan-approval.sh` (legacy AskUserQuestion path) OR by `_phase-helper.sh::drift_check` (handoff bundle path — Decision 0038). Both provenances share schema and session_id binding |
| `cohesion-reviewed` | A5 | Skipped for session types without review phase; GATE_RESULT: BLOCKED now blocks commit |
| `diff-review-complete` | A5 | New (Brief 3); written by state-writer.sh when Critic runs diff-review mode; GATE_RESULT: BLOCKED blocks commit |
| `reviewer-signed`, `security-signed` | A4 | Required on high-risk detection |
| `pragmatist-signed` | Plan-gating | Written by Pragmatist plan-review (legacy dispatch), by `_phase-helper.sh::bundle_to_pragmatist_signed` (handoff bundle path), or by the Orchestrator's `deterministic_alignment_check` (alignment-aligned outcome). Decisions 0025 + 0038. Checked at commit time |
| `functional-verified` | A3.4 (headless/auto only) | Written by `pre-commit-gates.sh` inline on script pass; required by binding gate when `_A34_APPLICABLE=true` and `IS_NO_REVIEW_BACKSTOP=true`. Decision 0044. |
| `.claude/local/closed-branches` | Session isolation | Persistent ledger (not session-scoped) |

Recovery: `REPO_OS_RECOVER=1` skips all state-dependent checks.
