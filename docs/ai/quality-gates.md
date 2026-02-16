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

## Branch Categories

Branch type determines which gates apply and at what strictness.

| Branch Pattern | Purpose | Gate Profile |
|----------------|---------|-------------|
| `main` | Production-ready code | All gates (A + B). Protected — no direct commits. Merge via PR only. |
| `release/*` | Release candidates | All gates (A + B) + release checklist (D gates). Reviewer + Security required on every merge. |
| `feature/*` | New functionality | Standard gates (A + B). Normal workflow. |
| `fix/*` | Bug fixes | Standard gates (A + B). Normal workflow. |
| `hotfix/*` | Urgent production fixes | Expedited: A2 scope limit relaxed (operator discretion). A1, A3, A4 still enforced. Push gates still apply. |
| `experiment/*` | Spikes, prototypes, exploration | A4 (safety) only. No push to main without full gates. Must not be merged — rewrite into `feature/*` branch. |

**Naming convention:** `<category>/<short-description>` (e.g., `feature/user-auth`, `hotfix/stripe-webhook-fix`).

**Default behavior:** Branches not matching a category are treated as `feature/*`.

## C) Conditional + Release Gates

If project-defined gates exist (in decision records or project docs), they block commits/pushes when triggered.
