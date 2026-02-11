# Gates (Process + Quality + Safety)

Gates are **blocking conditions**. If a required gate is not satisfied, you may not commit (or push).

If a gate cannot be met yet (e.g., tests not set up), it must be explicitly documented in the session log with a follow-up task.

> **Implementation Details:** See `.claude/agents/qa-verifier.md` for specific verification commands, evidence format templates, and examples.

---

## A) Commit Gates (Required)

### A1) Decision Compliance (Required)
- All applicable decisions in `docs/ai/decisions/` have been identified
- The plan and implementation comply with applicable decisions
- If a decision needs to change, propose a new decision record **before** committing

### A2) Process Gates (Required)
- A plan exists before code changes begin
- Scope is small and reviewable (no "big bang" edits)
- Changes are explainable: what changed + why
- Session log will be updated at session close (required)

### A3) Quality Gates (Required, if present in repo)
- Formatting check passes (or formatter has been run)
- Lint check passes (if lint exists)
- Build/compile passes (if build exists)

### A4) Safety Gates (Required)
- No secrets committed (tokens, keys, credentials, private URLs)
- No obviously sensitive data added to logs/fixtures (PII) if applicable

---

## B) Push Gates (Required)

All Commit Gates, plus:

### B1) Process Gates (Required)
- Commit message is meaningful and scoped
- If change is risky (auth, payments, data loss, security), Reviewer + Security must sign off

### B2) Quality Gates (Required, if present in repo)
- Tests pass (if tests exist)
- Typecheck passes (if a typed system exists)

### B3) Safety Gates (Required, when applicable)
- Dependency audit check has been run if dependencies changed
- No debug flags or verbose logging left enabled unintentionally

---

## C) Conditional Gates (Project-defined, enforceable)

Projects may define additional gates that trigger based on **change type**.
Examples:
- GPS/Nav/Voice changes require field testing evidence
- Auth changes require manual login/logout verification
- Payments changes require sandbox transaction verification
- Data migrations require dry-run + rollback plan

If a project defines conditional gates, they must be documented in:
- a decision record (recommended), and/or
- the project's workflow docs

Once defined, they are enforceable and **block commits/pushes** when triggered.

---

## D) Release Gates (Optional / Project-defined)

To be defined per project when needed:
- Integration/e2e suites
- Performance budgets
- Accessibility review checklist
- Security scanning / SAST
- Migration + rollback plan
