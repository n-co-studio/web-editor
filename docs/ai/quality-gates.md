# Gates

Gates are **blocking conditions**. Unmet gate = no commit (or push). If a gate can't be met yet (e.g., no tests), document in session log with follow-up task.

Verification details: `.claude/agents/qa-verifier.md`

## A) Commit Gates

| Gate | Checks |
|------|--------|
| **A1 Decision Compliance** | All applicable decisions identified and followed. Conflicts → propose new decision record before committing. Mechanically enforced via trigger parser: decisions with `## Triggers` sections are matched against staged files and `+` diff lines — triggered decisions must be declared in `Decisions:` git trailer. Blocking (enforced by `docs/ai/decisions/.a1-triggers-enforced` sentinel). New decisions must include a `## Triggers` section. |
| **A2 Process** | Plan exists before code. Changes explainable (what + why). Session log updated at close. Scope >100 lines blocks commit unless `plan-approved` state file contains `large-scope: true`. Hotfix branches: A2 scope relaxed (check skipped). |
| **A3 Quality** (if tooling exists) | Formatter run. Lint passes. Build/compile passes. |
| **A4 Safety** | No secrets (tokens, keys, credentials, private URLs). No PII in logs/fixtures. High-risk pattern detection: staged files matching risk paths (`auth`, `login`, `session`, `payment`, `billing`, `crypto`, `migration`, `schema`) or containing risk content (`password`, `secret`, `token`) require Reviewer + Security sign-off. Test/fixture/mock paths and governance docs (`docs/ai/`, `.claude/`, `AI.md`, `CLAUDE.md`) excluded from high-risk scanning (A4 secret scanning still applies to all files). |
| **A5 Cohesion** (standard+ branches) | Critic (cohesion mode) reviewed diff for internal codebase coherence. All critical findings resolved. Re-run clean after fixes. Mechanically verified: `cohesion-reviewed` state file must exist at commit time. |
| **A6 Task Group Compliance** (when applicable) | Task group contract exists at `docs/ai/task-groups/{group-name}.yaml` and is current. Conventions from contract followed. Contract updated at session close. **Blocking**: modified contract must be staged. Applies only when task brief contains `### Task Group`. Override: `SKIP_CONTRACT_CHECK=1`. |

## B) Push Gates

All Commit Gates, plus:

| Gate | Checks |
|------|--------|
| **B1 Process** | **Blocking**: branch name must match naming convention (`<category>/<description>`). Meaningful commit message. |
| **B2 Quality** (if tooling exists) | Tests pass. Typecheck passes. |
| **B3 Safety** (when applicable) | Dependency audit if deps changed. No debug flags left enabled. |

## Branch Categories

Branch type determines which gates apply and at what strictness.

| Branch Pattern | Purpose | Gate Profile |
|----------------|---------|-------------|
| `main` | Production-ready code | All gates (A + B). Protected — no direct commits. Merge via PR only. |
| `release/*` | Release candidates | All gates (A + B) + release checklist (C gates). Reviewer + Security required on every merge. |
| `feature/*` | New functionality | Standard gates (A + B). Normal workflow. |
| `fix/*` | Bug fixes | Standard gates (A + B). Normal workflow. |
| `hotfix/*` | Urgent production fixes | Expedited: A2 scope limit relaxed, A5 skipped (operator discretion). A1, A3, A4 still enforced. Push gates still apply. |
| `experiment/*` | Spikes, prototypes, exploration | A4 (safety) only. No push to main without full gates. Must not be merged — rewrite into `feature/*` branch. See Prompt 0.5 for prototyping tiers (Napkin / Spike / PoC). |

**Naming convention:** `<category>/<short-description>` (e.g., `feature/user-auth`, `hotfix/stripe-webhook-fix`).

**Default behavior:** Branches not matching a category are treated as `feature/*`.

## C) Conditional + Release Gates

### Conditional Gates
Project-specific gates defined in decision records or project docs. When their trigger conditions are met, they block commits or pushes. Examples: performance benchmarks, API compatibility checks, migration validation.

### Release Gates
Apply to `release/*` branches before merge to `main`:

| Gate | Checks |
|------|--------|
| **C1 Release Checklist** | Version bumped. Changelog updated. Release notes drafted. |
| **C2 Full Verification** | All A + B gates pass. Full test suite (not just related tests). |
| **C3 Sign-offs** | Reviewer + Security sign-off required on every release merge. |

## State File Dependencies

Pre-commit gates verify governance steps completed by checking state files in `.claude/.state/`. State files are written by hooks (shell I/O only — never model tools).

| State File | Writer | Required By |
|------------|--------|-------------|
| `plan-approved` | `plan-approval.sh` | State verification, A2 scope (large-scope flag) |
| `cohesion-reviewed` | `state-writer.sh` (critic) | State verification (skipped on `hotfix/*`) |
| `qa-verified` | `state-writer.sh` (qa-verifier) | State verification |
| `reviewer-signed` | `state-writer.sh` (reviewer) | High-risk detection |
| `security-signed` | `state-writer.sh` (security-privacy) | High-risk detection |
| `high-risk-detected` | `pre-commit-gates.sh` | Audit trail (written when risk patterns match) |
| `governance-checked` | `branch-guard.sh` (Gate 3) | First-fire marker (inter-session governance advisory) |
| `phase-chain-checked` | `branch-guard.sh` (Gate 4) | First-fire marker (phase chain verification advisory) |
| `overrides.log` | `_analytics-helper.sh` (`log_override`) | Override audit summary (session-close-check) |

**Recovery override:** Set `REPO_OS_RECOVER=1` to skip all state-dependent checks in pre-commit, pre-push, and branch-guard (Edit/Write) gates. Emergency path for hook crashes or debugging sessions.
