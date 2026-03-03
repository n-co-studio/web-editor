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

### `~/.local/share/repo-os-analytics/`
Active centralized analytics store. Contains hook telemetry data (NDJSON event files) organized by repo name (`<repo-name>/events/<date>.ndjson`). Reserved for the Analytics specialist agent — all other agents MUST NOT read this directory. Data lives outside the repo tree, so broad repo-scoped Grep/Glob patterns never hit it. The Analytics agent is invoked on-demand by the operator only.

### `.claude/analytics/` (legacy)
May contain historical event data from before centralized storage migration. Read-only legacy data — the Analytics agent may still read this for historical analysis. No new events are written here.

### `.claude/.automation/`
Automation layer runtime directory (Decision 0017). Contains schemas (`schemas/`, tracked), config (`config.yaml`, tracked), decision cache (`decision-cache.yaml`, tracked), brief templates (`templates/`, tracked), runner libraries (`lib/`, tracked), and runtime artifacts (`queue/`, `reports/`, `escalations/`, `briefs/`, `logs/` — gitignored). Reserved for the runner process. The Dev Orchestrator agent writes health reports to `reports/` via Bash redirect. All other agents MUST NOT write to this directory.

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
| `governance-checked` | `branch-guard.sh` (Gate 3, Bash) or `pre-commit-gates.sh` (Gate 3, commit) | First-fire marker (inter-session governance) |
| `phase-state` | `_phase-helper.sh` (via hooks) | Phase-aware flow tracking (session type, current phase, cycle) |
| `overrides.log` | `_analytics-helper.sh` (`log_override`) | Override audit (session-close-check) |
| `task-contract.yaml` | Orchestrator (model) | Task contract — intent reference for cohesion review (Decision 0020) |
| `.stop-attempt-count` | `session-close-check.sh` | Stop hook attempt counter — safety valve at 3 attempts |
| `merge-source-branch` | `_phase-helper.sh` (`write_merge_signal`) | Agent-to-hook merge signal — indicates agent completed merge in close phase (session-close-check.sh skips redundant merge) |

**Operational files** (`.claude/`, outside `.state/`):

| File | Writer | Purpose |
|------|--------|---------|
| `.session-log-hash` | `session-close-check.sh` (`update_baseline`) | Session log content hash — baseline for next session's modification check |
| `.session-baseline-sha` | `session-close-check.sh` (`update_baseline`) | Commit SHA — baseline for zero-change session detection |
| `.session-id` | `_analytics-helper.sh` (`get_session_id`) | Session identifier for analytics event correlation |
| `.session-type` | Operator/model (manual) or `session-close-check.sh` (inferred) | Session classification (build/qa/audit/explore) for analytics |
| `.hvst-fail-count` | `hvst-failure-tracker.sh` | Consecutive Bash failure counter for HVST reminders |
| `.deferrals-pending` | Orchestrator (model) | Signals deferred audit/advisory findings — consumed by session-close-check |

Note: `.stop-attempt-count` moved to `.claude/.state/` (see State Files table above) for state-guard protection.

**Lifecycle:** `.state/` files (including `phase-state`, `.stop-attempt-count`), `.session-id`, `.session-type`, `.hvst-fail-count`, and `.deferrals-pending` are session-scoped — cleaned at close by `cleanup_session()`. `.session-log-hash` and `.session-baseline-sha` are persistent — survive across sessions, updated by `update_baseline()`.

---

## Constraint Severity Prefixes

Three severity levels classify behavioral constraints in governance files.

| Prefix | Meaning | Enforcement |
|--------|---------|-------------|
| **BLOCK** | Mechanically enforced. A hook or settings restriction prevents the action (exits non-zero or disallows the tool call). | Hook script, subagent `disallowedTools`, or `settings.json` wiring |
| **REQUIRE** | Process obligation. No mechanical enforcement — the model must comply. Violation is a process failure. | Agent prose, workflow rules, prompt instructions |
| **GUIDE** | Best practice. Deviation is acceptable with reason. | Advisory only |

**DELEGATE** is an orchestrator-specific routing prefix (not a severity level). Retained as-is in `orchestrator.md`.

### Classification Rules

1. A constraint is BLOCK only when a hook script or `disallowedTools` mechanically prevents the action. Reference the specific hook or setting.
2. When an agent (e.g., QA, Reviewer) issues a "block" verdict, the agent's own obligation to do so is REQUIRE — the agent is exercising judgment, not mechanical enforcement.
3. Structural content (tables, phase sequences, diagrams, definition lists) does not receive a prefix.
4. Tag at the bullet level, not per-clause.

---

## Phase Model

Sessions progress through ordered phases tracked in `.claude/.state/phase-state` (Decision 0014). Hooks manage phase transitions automatically.

### Phase Definitions

| Phase | Description |
|-------|-------------|
| init | Session setup — create branch, load context |
| plan | Define goal, scope, files, verification |
| approval | Operator reviews and approves plan |
| build | Implement changes |
| review | Critic cohesion review |
| verify | QA gate verification |
| user-review | User Review persona dispatch (optional — skipped when no User Review in brief) |
| commit | Commit with trailers |
| op-review | Operator review before close (skipped in auto mode) |
| close | Update session log, commit, merge to main, seal branch |
| contract-init | Task group: create or sync contract |
| contract-update | Task group: update contract at close |
| interview | Prompt 0: operator interview |
| write | Prompt 0: write spec files |
| governance | Write governance evidence |
| tier-select | Prompt A: select review tier |
| dispatch | Dispatch specialist agents |
| synthesize | Merge specialist findings |
| output | Display final output |
| conversation | Prompt T query: conversational Q&A |
| evaluate | Prompt 0.5: evaluate prototype results |
| document | Prompt 0.5 PoC: document learnings |
| scope | Prompt C: select audit dimensions |
| validate | Prompt A: validate Repo OS configuration |
| cohesion | Task group merge: cross-session cohesion review across parallel briefs |

### Automation Tags

| Tag | Meaning |
|-----|---------|
| `agent` | Agent proceeds autonomously |
| `operator` | Agent pauses for operator decision |
| `both` | Agent and operator work concurrently |

### Auto/Review Mode

- **Auto**: Agent completes through merge autonomously. `op-review` phase skipped.
- **Review**: Agent pauses at `op-review` for operator acceptance. Default.

### Solo Mode (Decision 0015)

Branches merge to main directly at session close. See `docs/ai/workflow.md` § Solo Mode for full semantics (branch types, merge behavior, conflict handling).

---

## Operating Modes

Three modes control which files an agent can modify. Enforced by `write-guard.sh` (Decision 0012).

### Template Mode
Governance-only access. The agent can create and modify governance files (`.claude/agents/`, `.claude/hooks/`, `.claude/settings.json`, `.claude/settings.local.json`, `.claude/local/session-log.md`, `.claude/local/known-issues.md`, `.claude/local/task-groups/*`, `docs/ai/prompts/`, `docs/ai/decisions/`, `docs/ai/logs/`, `docs/ai/workflow.md`, `docs/ai/quality-gates.md`, `docs/ai/task-groups/_contract-template.yaml`, `docs/spec/_templates/`, `AI.md`, `CLAUDE.md`, `repo-os-explainer.html`, `.github/`) but cannot touch product code. Task group contracts live at `.claude/local/task-groups/` (not `docs/ai/task-groups/`). Used in the upstream template repository. Set in `.claude/repo-mode` as `template`.

### Child Mode
Product code plus limited governance carve-outs. The agent can modify product code and: `docs/ai/decisions/0100+` (project-specific decisions), `docs/ai/logs/`, `docs/ai/governance/`, `docs/ai/task-groups/*.yaml` (non-underscore-prefixed), `docs/spec/compiled/`, `docs/spec/prototypes/`, `.claude/settings.local.json`. Template-owned governance files (`t-*` decisions, hooks, prompts, workflows) are protected. Default mode when `.claude/repo-mode` is missing. Set as `child`.

### Autonomous Mode
Product code plus minimal governance carve-outs: `docs/ai/logs/`, `docs/ai/task-groups/*.yaml` (non-underscore-prefixed). All other governance paths locked. Intended for headless operation with maximum governance protection. Set as `autonomous`.

### Mode Resolution
Priority: `REPO_OS_MODE` env var > `.claude/repo-mode` file > default `child`. Override: `REPO_OS_SKIP_MODE_GUARD=1` (skip entirely), `REPO_OS_UNLOCK_PATH=<path>` (single-file unlock, immune paths excluded).

### Session Close Overrides

The stop hook (`session-close-check.sh`) enforces blocking gates at session close:

| Override | Gate | Effect |
|----------|------|--------|
| `SKIP_SESSION_LOG=1` | Session log modification | Bypasses session log check |
| `SKIP_UNCOMMITTED_CHECK=1` | Uncommitted changes | Allows close with dirty working tree |
| `SKIP_KNOWN_ISSUES_CHECK=1` | Known-issues documentation (HVST + deferrals) | Bypasses known-issues modification checks |
| `SKIP_CONTRACT_CHECK=1` | Task group contract check | Bypasses A6 contract staging and governance evidence checks |

All overrides are logged via `log_override()` and summarized in the override audit.

### Decision Naming Convention
Template decisions use the `t-` prefix (`t-0001-*.md` through `t-NNNN-*.md`) and are synced from upstream, locked in child/autonomous modes. Child decisions use plain numeric names (`0100-*.md`+) and are editable in child mode. Mode-guard enforces via the `t-` prefix check (Decision 0022). The `t-manifest.txt` file lists all template decisions for orphan cleanup in child repos.

---

## User Review

### System
LLM persona simulation providing synthetic user perspective on implementation output. Advisory only — no gate, no state file, no mechanical enforcement. Dispatch and synthesis occur in the `user-review` phase (after `verify`, before `commit`); results are presented to the operator during `op-review` for disposition. Skipped (forward-jump to `commit`) when no User Review is defined. Opt-in via task brief (`### User Review` section) or operator request. See Decision 0021.

### Persona Tiers

| Tier | Persona | Mental Model | Error Recovery | Confusion Threshold |
|------|---------|-------------|----------------|---------------------|
| **Tier 1** | Power User | Strong — infers from experience | Tries 2–3 alternatives | Low — comfortable with ambiguity |
| **Tier 2** | Everyday User | Partial — knows common patterns | Tries once, then seeks help | Moderate — needs visible guidance |
| **Tier 3** | Novice User | None — every interaction is new | Stops immediately | High — abandons at first friction |

### Severity Mapping
User Review findings use the advisory board severity scale (Decision 0007):
- **CRITICAL** — Task-blocking friction (user cannot complete the job story)
- **RECOMMENDATION** — Notable friction (user completes with confusion or extra steps)
- **IDEA** — Enhancement opportunity (user completes smoothly, improvement plausible)

### Risk Classification
Low-risk (advisory). No commit gate, no sign-off requirement. Findings feed into `op-review` disposition only.

### Operating Mode Exclusions
User Review is available in **child mode only**. Excluded from:
- Template mode (no product code to review)
- Autonomous mode (no operator for disposition)
- Headless/automation mode (no operator interaction)
- Experiment sessions (no `user-review` phase)

### LLM Persona Simulation Caveat
All User Review outputs include a mandatory caveat acknowledging that results are LLM-simulated, not empirical user testing. Findings are hypothesis-grade input. LLM persona simulation may over-succeed — particularly at Tier 3 (Novice).

---

## Governance Prefixes

Protected path prefixes enforced by `write-guard.sh`. Files under these prefixes are governance-scoped and subject to mode-based restrictions:

| Prefix | Scope |
|--------|-------|
| `.claude/` | Hooks, settings, agents, state |
| `docs/ai/` | Decisions, logs, governance, prompts, workflows, task groups |
| `docs/spec/_templates/` | Spec templates (synced from upstream) |
| `.github/` | Workflows, CI/CD configuration |
| `AI.md` | Root governance document |
| `CLAUDE.md` | Claude configuration document |
| `repo-os-explainer.html` | Repo OS explainer page (template artifact) |

Immune paths (never modifiable, no override): `.claude/hooks/write-guard.sh`, `.claude/repo-mode`. To maintain immune paths, set `REPO_OS_SKIP_MODE_GUARD=1` (disables guard entirely, logged in `overrides.log`). As a last resort, Python file I/O bypasses Bash command scanning.
