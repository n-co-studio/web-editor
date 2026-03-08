# Gates

Gates are **blocking conditions**. Unmet gate = no commit (or push). If a gate can't be met yet (e.g., no tests), document in session log with follow-up task.

Verification details: `.claude/agents/qa-verifier.md`

## A) Commit Gates

| Gate | Checks |
|------|--------|
| **A1 Decision Compliance** | All applicable decisions identified and followed. Conflicts → propose new decision record before committing. Mechanically enforced via trigger parser: decisions with `## Triggers` sections are matched against staged files and `+` diff lines — triggered decisions must be declared in `Decisions:` git trailer. Blocking (enforced by `docs/ai/decisions/.a1-triggers-enforced` sentinel). New decisions must include a `## Triggers` section. |
| **A2 Process** | Plan exists before code. Changes explainable (what + why). Session log updated at close. Scope >100 lines blocks commit unless `plan-approved` state file contains `large-scope: true`. Hotfix branches: A2 scope relaxed (check skipped). |
| **A3 Quality** (if tooling exists) | Formatter run. Lint passes. Build/compile passes. |
| **A4 Safety** | No secrets (tokens, keys, credentials, private URLs). No PII in logs/fixtures. High-risk pattern detection: staged files matching risk paths (`auth`, `login`, `session`, `payment`, `billing`, `crypto`, `migration`, `schema`) or containing risk content (`password`, `secret`, `token`) require Reviewer + Security sign-off. Test/fixture/mock paths and governance docs (`docs/ai/`, `.claude/`, `AI.md`, `CLAUDE.md`, `repo-os-explainer.html`) excluded from high-risk scanning (A4 secret scanning still applies to all files). **Automation-specific (A4-auto)**: when `Automation: runner` trailer is present, A4 additionally covers outbound network calls added without brief justification (curl/wget/fetch), new package dependencies added without brief instruction, and writes outside the repository root. Mechanical enforcement via permission profile blocklists; review-time enforcement via security-privacy agent's Automation Runtime checks. |
| **A5 Cohesion** (standard+ branches) | Critic (cohesion mode) reviewed diff for internal codebase coherence. All critical findings resolved. Re-run clean after fixes. When a task contract is present (Decision 0020), cohesion review also includes contract verification — Critic evaluates each `verification:` criterion as VERIFIED/UNVERIFIED/INCONCLUSIVE (advisory, not blocking). Mechanically verified: `cohesion-reviewed` state file must exist at commit time. |
| **A6 Task Group Compliance** (when applicable) | Two sub-gates (Decision 0018). **A6.1 Contract existence** (blocking): task group sessions (`taskgroup`/`taskgroup-merge`) must have a contract with `status: in_progress` in the contract directory before committing. Uses filesystem check — works in template mode with gitignored `.claude/local/task-groups/`. **A6.2 Contract staging** (blocking): modified contract YAML must be staged. Applies only when task brief contains `### Task Group`. Override: `SKIP_CONTRACT_CHECK=1`. |

### A1 Trigger Enforcement Sentinel

Gate A1's trigger parser is gated by the sentinel file `docs/ai/decisions/.a1-triggers-enforced`. This is an empty file whose presence enables mechanical enforcement — repos without it skip trigger parsing entirely (A1 still applies as a manual check).

**Why opt-in:** New repos and repos adopting Repo OS incrementally may not have `## Triggers` sections in their decision records yet. The sentinel lets teams enable enforcement after they've added triggers to all existing decisions.

**How to enable:** `touch docs/ai/decisions/.a1-triggers-enforced` in the repo root and commit it.

### A1 Trigger Index

The trigger parser uses a compiled index at `docs/ai/decisions/.a1-trigger-index` for fast matching. When the index is present, the parser reads it instead of parsing each decision file individually (eliminates ~80 subprocess forks per commit). Falls back to file-by-file parsing when the index is absent.

**Format:** `decision_id|path_regex|keywords` (pipe-delimited, one line per path pattern per decision). See the index file header for the full regeneration script.

**Regenerate after adding or modifying decision triggers:**

```bash
.claude/.automation/lib/rebuild-trigger-index.sh
```

A staleness warning is emitted when any decision file has a newer modification time than the index. The index should be committed (tracked, not gitignored).

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
| `main` | Production-ready code | All gates (A + B). Protected — no direct commits. Solo mode (Decision 0015): mergeable branches merge directly at session close. |
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
| `pragmatist-signed` | `state-writer.sh` (pragmatist) | Plan-review verification |
| `high-risk-detected` | `pre-commit-gates.sh` | Audit trail (written when risk patterns match) |
| `governance-checked` | `pre-commit-gates.sh` (Gate 3, commit) | First-fire marker (inter-session governance advisory) |
| `phase-state` | `_phase-helper.sh` (via hooks) | Phase-aware flow tracking (read by hooks for phase assertions) |
| `overrides.log` | `_analytics-helper.sh` (`log_override`) | Override audit summary (session-close-check) |

Note: Gate 5 (session isolation, Decision 0013) uses `.claude/local/closed-branches` — a persistent ledger, not a session-scoped state file. It is not listed in the table above because it is not cleaned at session close. Gate 5 is enforced by `write-guard.sh` (Section 3) on Edit/Write and `bash-guard.sh` on Bash.

**Recovery override:** Set `REPO_OS_RECOVER=1` to skip all state-dependent checks in pre-commit, pre-push, and bash-guard gates. Emergency path for hook crashes or debugging sessions.

### Fail-Closed Phase Enforcement Sentinel

The phase-gate hooks (`bash-guard.sh` for Bash, `write-guard.sh` Section 3 for Edit/Write — Gate 2) check for phase-state before allowing edits on governed branches. Behavior depends on the sentinel file `docs/ai/decisions/.fail-closed-enforced`:

- **Sentinel present** → phase-state absent or stale triggers a **BLOCK**. The agent must call `init_phase()` (via the orchestrator) to initialize phase-state before editing. Override: `REPO_OS_SKIP_PLAN_GATE=1`.
- **Sentinel absent** → phase-state absent or stale triggers an **advisory warning** and allows the edit (backward compatibility).

**Why opt-in:** Mirrors the `.a1-triggers-enforced` convention. Repos that haven't adopted the phase model yet continue with advisory-only behavior. The template repo ships with the sentinel enabled.

**How to enable:** `touch docs/ai/decisions/.fail-closed-enforced` in the repo root and commit it.

**Exemptions:** Experiment branches (exempt before Gate 2), `.claude/.state/` writes, `.claude/local/` writes, governance paths, and task-group paths are all exempt from the phase gate. The `REPO_OS_RECOVER=1` emergency override bypasses all state-dependent checks including this one.

See Decision 0019 for full implementation details.

## Phase-to-Gate Mapping

Which gates apply varies by session type. Enforced at `verify`/`commit` phases. See Decision 0014 for the full mapping:

| Session Types | Gate Profile |
|---------------|-------------|
| `standard`, `taskgroup`, `taskgroup-merge` | Full gates (A1–A6, B1–B3). A6 applies only to taskgroup/taskgroup-merge |
| `hotfix` | Expedited (A2 scope relaxed, A5 skipped) |
| `experiment`, `prototype-*` | A4 safety only |
| `spec-fresh`, `spec-update`, `advisory-init`, `advisory-reinit` | Advisory only (governance evidence at close) |
| `audit` | Read-only (no gates unless deferrals create file changes) |
| `taskdef-query`, `taskdef-brief` | No gates (fully ephemeral) |

**Merge brief gate ordering:** The `taskgroup-merge` session type replaces the `review` phase with `cohesion` (cross-session cohesion review using `git diff main...HEAD`). Gate A5 (cohesion) is satisfied by the `cohesion` phase rather than a separate `review` phase. Gate A6 always applies to merge briefs (task group contract must be updated). The `verify` phase runs all remaining gates (A1–A4, A6, B1–B3) after cohesion completes.

**Plan Review (advisory/gating):** The Pragmatist agent reviews implementation plans during the `plan` phase (Prompt B) before presenting to the operator. FUNDAMENTAL-MISMATCH findings produce `GATE_RESULT: BLOCKED`; OVER-ENGINEERED findings alone produce `GATE_RESULT: APPROVED`. The `pragmatist-signed` state file records the verdict. In auto mode, BLOCKED degrades to advisory-with-warning (operator notified post-session). No gate number is assigned — enforcement is via Orchestrator dispatch, not pre-commit hooks. See Decision 0025.

**User Review (advisory):** The `user-review` phase runs after `verify` and before `commit` in standard and taskgroup sequences. User Review findings are advisory-only — they follow the Prompt C audit pattern (presented to operator but no state file written, no gate blocked). No gate number is assigned. The phase is skippable: sessions without a User Review section in the task brief forward-jump from `verify` directly to `commit`. See Decision 0021.
