# Agent Glossary

Shared definitions for scope, risk, and enforcement. All agents interpret these terms consistently.

---

## Scope

### Small Scope
ALL of: <100 lines production code, ≤3 files, single concern, reviewable in <10 minutes.

### Large Scope
Exceeds small thresholds. Must be split into smaller increments OR explicitly approved by operator.

### Structural Change
New modules/packages, core abstraction changes, DB schema modifications, API contract changes, build/dependency changes.

### Cross-Cutting Change
Logging/monitoring, auth/authz, error handling patterns, config/env changes, shared utility updates.

---

## Risk Levels

### High-Risk (Require Reviewer + Security sign-off)
- **Auth & Authorization**: Login, session, permissions, OAuth, tokens
- **Payments & Financial**: Billing, transactions, pricing, refunds
- **Data Persistence**: Migrations, schema changes, data deletion
- **Security Boundaries**: Input validation, cryptography, secrets
- **PII & Sensitive Data**: Personal info, health, financial records
- **External Integrations**: Third-party APIs, webhooks, data export

### Medium-Risk (Extra scrutiny)
Public-facing UI, performance-critical paths, caching, background jobs, rate limiting

### Low-Risk
Docs, tests, formatting, comments, dev tooling

---

## Protocols

### HVST (Hypothesis → Validate → Solve → Test → Record)
5-step debugging protocol for non-trivial failures. Prevents random-fix loops by requiring a hypothesis before any code change. Tracked by `hvst-failure-tracker.sh` hook. See `docs/ai/workflow.md` for full protocol definition.

---

## Enforcement

### Hook
Automated script at lifecycle events (pre-commit, session stop). Runs regardless of agent behavior.

### Subagent
Agent invoked via Task tool with isolated context and tool restrictions from YAML frontmatter.

### Settings
`.claude/settings.json` (team, committed) and `.claude/settings.local.json` (personal, gitignored).
