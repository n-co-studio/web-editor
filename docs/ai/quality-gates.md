# Gates

Gates are **blocking conditions**. Unmet gate = no commit (or push). If a gate can't be met yet (e.g., no tests), document in session log with follow-up task.

Verification details: `.claude/agents/qa-verifier.md`

## A) Commit Gates

| Gate | Checks |
|------|--------|
| **A1 Decision Compliance** | All applicable decisions identified and followed. Conflicts → propose new decision record before committing. |
| **A2 Process** | Plan exists before code. Scope is small/reviewable. Changes explainable (what + why). Session log updated at close. |
| **A3 Quality** (if tooling exists) | Formatter run. Lint passes. Build/compile passes. |
| **A4 Safety** | No secrets (tokens, keys, credentials, private URLs). No PII in logs/fixtures. |

## B) Push Gates

All Commit Gates, plus:

| Gate | Checks |
|------|--------|
| **B1 Process** | Meaningful commit message. High-risk changes (auth, payments, data loss, security) → Reviewer + Security sign-off. |
| **B2 Quality** (if tooling exists) | Tests pass. Typecheck passes. |
| **B3 Safety** (when applicable) | Dependency audit if deps changed. No debug flags left enabled. |

## C) Conditional + Release Gates

If project-defined gates exist (in decision records or project docs), they block commits/pushes when triggered.
