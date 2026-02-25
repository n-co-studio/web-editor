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
5-step debugging protocol for non-trivial failures. Prevents random-fix loops by requiring a hypothesis before any code change. Tracked by `hvst-failure-tracker.sh` hook. At 2+ consecutive failures or on operator request, Orchestrator may dispatch HVST Review Board (Architect + Exploration + Critic (hypothesis mode)) for multi-agent hypothesis review. See `.claude/agents/_hvst-review.md` for review board procedure and `docs/ai/workflow.md` for full protocol definition.

### Cohesion Review
Post-build review by the Critic agent (cohesion mode) checking the diff and surrounding code for internal codebase coherence: broken cross-references, dangling imports, inconsistent naming, half-finished integrations, and contradictory patterns. Verified by QA as gate A5. Not the same as spec review (advisory board) — cohesion operates on code, not specs.

---

## Reserved Directories

### `.claude/analytics/`
Reserved for the Analytics specialist agent. Contains hook telemetry data (NDJSON event files). All other agents MUST NOT read, Glob, or Grep this directory during normal operations. When using Grep or Glob with broad patterns, exclude analytics: `--glob '!.claude/analytics/**'`. The Analytics agent is invoked on-demand by the operator only.

---

## Enforcement

### Hook
Automated script at lifecycle events (pre-commit, session stop). Runs regardless of agent behavior.

### Subagent
Agent invoked via Task tool with isolated context and tool restrictions from YAML frontmatter.

### Settings
`.claude/settings.json` (team, committed) and `.claude/settings.local.json` (personal, gitignored).

### State Files
Session-scoped governance evidence in `.claude/.state/`. Written by hooks via shell I/O (never model tools). Read by pre-commit gates to verify governance steps completed.

| File | Writer | Gate |
|------|--------|------|
| `plan-approved` | `plan-approval.sh` | Branch guard, A2 scope |
| `cohesion-reviewed` | `state-writer.sh` (critic) | State verification |
| `qa-verified` | `state-writer.sh` (qa-verifier) | State verification |
| `reviewer-signed` | `state-writer.sh` (reviewer) | High-risk detection |
| `security-signed` | `state-writer.sh` (security-privacy) | High-risk detection |
| `high-risk-detected` | `pre-commit-gates.sh` | Audit trail |
| `governance-checked` | `branch-guard.sh` (Gate 3) | First-fire marker (inter-session governance) |
| `phase-chain-checked` | `branch-guard.sh` (Gate 4) | First-fire marker (phase chain verification) |
| `overrides.log` | `_analytics-helper.sh` (`log_override`) | Override audit (session-close-check) |

**Operational files** (`.claude/`, outside `.state/`):

| File | Writer | Purpose |
|------|--------|---------|
| `.session-log-hash` | `session-close-check.sh` (`update_baseline`) | Session log content hash — baseline for next session's modification check |
| `.session-baseline-sha` | `session-close-check.sh` (`update_baseline`) | Commit SHA — baseline for zero-change session detection |
| `.session-id` | `_analytics-helper.sh` (`get_session_id`) | Session identifier for analytics event correlation |
| `.hvst-fail-count` | `hvst-failure-tracker.sh` | Consecutive Bash failure counter for HVST reminders |

**Lifecycle:** `.state/` files, `.session-id`, and `.hvst-fail-count` are session-scoped — cleaned at close by `cleanup_session()`. `.session-log-hash` and `.session-baseline-sha` are persistent — survive across sessions, updated by `update_baseline()`.

---

## Operating Modes

Three modes control which files an agent can modify. Enforced by `mode-guard.sh` (Decision 0012).

### Template Mode
Governance-only access. The agent can create and modify governance files (`.claude/agents/`, `.claude/hooks/`, `.claude/settings.json`, `.claude/settings.local.json`, `docs/ai/prompts/`, `docs/ai/decisions/`, `docs/ai/logs/`, `docs/ai/workflow.md`, `docs/ai/quality-gates.md`, `docs/ai/task-groups/_contract-template.yaml`, `docs/spec/_templates/`, `AI.md`, `CLAUDE.md`, `.github/`) but cannot touch product code. Used in the upstream template repository. Set in `.claude/repo-mode` as `template`.

### Child Mode
Product code plus limited governance carve-outs. The agent can modify product code and: `docs/ai/decisions/0100+` (project-specific decisions), `docs/ai/logs/`, `docs/ai/governance/`, `docs/ai/task-groups/*.yaml` (non-underscore-prefixed), `docs/spec/compiled/`, `docs/spec/prototypes/`, `.claude/settings.local.json`. Template-owned governance files (0001–0099 decisions, hooks, prompts, workflows) are protected. Default mode when `.claude/repo-mode` is missing. Set as `child`.

### Autonomous Mode
Product code plus minimal governance carve-outs: `docs/ai/logs/`, `docs/ai/task-groups/*.yaml` (non-underscore-prefixed). All other governance paths locked. Intended for headless operation with maximum governance protection. Set as `autonomous`.

### Mode Resolution
Priority: `REPO_OS_MODE` env var > `.claude/repo-mode` file > default `child`. Override: `REPO_OS_SKIP_MODE_GUARD=1` (skip entirely), `REPO_OS_UNLOCK_PATH=<path>` (single-file unlock, immune paths excluded).

### Decision Range Convention
Decisions 0001–0099 are template-synced and locked in child/autonomous modes. Decisions 0100+ are project-specific and editable in child mode. Mode-guard enforces via filename regex `0[1-9][0-9][0-9]-*.md`.

---

## Governance Prefixes

Protected path prefixes enforced by `mode-guard.sh`. Files under these prefixes are governance-scoped and subject to mode-based restrictions:

| Prefix | Scope |
|--------|-------|
| `.claude/` | Hooks, settings, agents, state |
| `docs/ai/` | Decisions, logs, governance, prompts, workflows, task groups |
| `docs/spec/_templates/` | Spec templates (synced from upstream) |
| `.github/` | Workflows, CI/CD configuration |
| `AI.md` | Root governance document |
| `CLAUDE.md` | Claude configuration document |

Immune paths (never modifiable, no override): `.claude/hooks/mode-guard.sh`, `.claude/repo-mode`. To maintain immune paths, set `REPO_OS_SKIP_MODE_GUARD=1` (disables guard entirely, logged in `overrides.log`). As a last resort, Python file I/O bypasses Bash command scanning.
