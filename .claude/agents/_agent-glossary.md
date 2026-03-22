# Agent Glossary

Shared definitions for scope, risk, and enforcement.

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
5-step debugging protocol for non-trivial failures. Requires hypothesis before code change. Tracked by `hvst-failure-tracker.sh`. Use when: bugs, failing tests, unstable behavior. Loop: **Hypothesis** → **Validate** (smallest experiment) → **Solve** (minimal fix) → **Test** (rerun) → **Record** (after 2+ failed cycles: add to `known-issues.md`; template mode: `.claude/local/known-issues.md`). At 2 consecutive failures, check `known-issues.md` for matches. REQUIRE: known-issues documentation at session close (advisory, downgraded from blocking). Override: `SKIP_KNOWN_ISSUES_CHECK=1`.

**Review Board** (optional): At 2+ failures or operator request → Architect + Exploration + Critic (hypothesis mode). See `.claude/agents/_hvst-review.md`.

### Cohesion Review
Post-build Critic review (cohesion mode): checks diff + surrounding code for broken cross-references, dangling imports, inconsistent naming, contradictory patterns. Gate A5. Operates on code, not specs.

### PM Scope Labels
PM-specific labels (orthogonal to severity): **IN-SCOPE**, **OUT-OF-SCOPE**, **DEFER**. Applied by PM Advisory alongside standard severity. Informational — do not affect Refinement Report routing.

---

## Reserved Directories

| Directory | Purpose | Access |
|-----------|---------|--------|
| `~/.local/share/repo-os-analytics/` | Centralized hook telemetry (NDJSON by repo/date). Outside repo tree | Analytics agent only — all others MUST NOT read |
| `.claude/analytics/` (legacy) | Historical event data (pre-migration). Read-only | Analytics agent (historical reads only) |
| `.claude/.automation/` | Automation layer (Decision 0017). Tracked: schemas, config, decision cache, templates, lib. Gitignored: queue, reports, escalations, briefs, logs | Runner process + Dev Orchestrator (reports only). All others MUST NOT write |

---

## Enforcement

### Hook
Automated script at lifecycle events (pre-commit, session stop). Runs regardless of agent behavior.

### Subagent
Agent invoked via Task tool with isolated context and tool restrictions from YAML frontmatter. Frontmatter hooks (e.g., `agent-git-guard.sh` on Bash PreToolUse) run inside the subagent's context — they block actions like `git commit`/`git push` within the subagent without affecting the orchestrator.

### Hook Message Prefixes
All blocking hook messages use semantic prefixes for agent recovery:

| Prefix | Meaning | Format |
|--------|---------|--------|
| **GATE-RECOVERABLE** | Blocked but agent can fix and retry | `GATE-RECOVERABLE: <condition>. NEXT: <recovery action>. (override: <var>)` |
| **GATE-FINAL** | Blocked, no agent recovery path (immune paths, secrets) | `GATE-FINAL: <condition>. (override: <var>)` or `(no override)` |

Hook authors: use `GATE-RECOVERABLE` when the agent has a concrete next step. Use `GATE-FINAL` when only a human or env var can unblock.

### Settings
`.claude/settings.json` (team, committed) and `.claude/settings.local.json` (personal, gitignored).

### State Files
Governance evidence in `.claude/.state/`. Written by hooks via shell I/O (never model tools). Read by pre-commit gates.

| File | Writer | Gate |
|------|--------|------|
| `plan-approved` | `plan-approval.sh` | Branch guard, A2 scope (covers both plan approval and brief approval — Decision 0029) |
| `cohesion-reviewed` | `state-writer.sh` (critic) | State verification |
| `qa-verified` | `state-writer.sh` (qa-verifier) | State verification |
| `reviewer-signed` | `state-writer.sh` (reviewer) | High-risk detection |
| `security-signed` | `state-writer.sh` (security-privacy) | High-risk detection |
| `pragmatist-signed` | `state-writer.sh` (pragmatist) | Plan-review verification |
| `high-risk-detected` | `pre-commit-gates.sh` | Audit trail |
| `governance-checked` | `bash-guard.sh` (Gate 3, Bash) or `pre-commit-gates.sh` (Gate 3, commit) | First-fire marker (inter-session governance) |
| `phase-state` | `_phase-helper.sh` (via hooks) | Phase-aware flow tracking (session type, current phase, cycle) |
| `overrides.log` | `_analytics-helper.sh` (`log_override`) | Override audit (session-close-check) |
| `task-contract.yaml` | Orchestrator (model) | Task contract — intent reference for cohesion review (Decision 0020). Lives in `.claude/local/` (not `.state/`) because it is model-written; state-guard blocks model writes to `.state/` |
| `.stop-attempt-count` | `session-close-check.sh` | Stop hook attempt counter — safety valve at 3 attempts |
| `merge-source-branch` | `_phase-helper.sh` (`write_merge_signal`) | Agent-to-hook merge signal — indicates agent completed merge in close phase (session-close-check.sh skips redundant merge) |
| `scope-risk-gain` | Orchestrator (model) | Risk/gain context for unbriefed-in-scope files — read by `pre-commit-gates.sh` scope classification gate, included in advisory escalation (Decision 0017) |
| `brief-has-taskgroup` | `_phase-helper.sh` (`write_taskgroup_brief_signal`) | Session-type validation (`check_taskgroup_brief_mismatch` in `bash-guard.sh`, Decision 0026). Cleaned by `cleanup_session_files` |

**Sentinel files** (`.claude/local/`, persistent across sessions, gitignored): `.pragmatist-enforced` (backward-compatible gate deployment marker — written on first `pragmatist-signed` enforcement in `pre-commit-gates.sh`, prevents false positives on sessions started before the gate was deployed).

**Operational files** (`.claude/`, outside `.state/`): `.session-log-hash` (log content hash), `.session-baseline-sha` (commit baseline), `.session-id` (analytics correlation), `.session-type` (session classification), `.hvst-fail-count` (HVST counter), `.deferrals-pending` (deferred findings signal).

**Session registry** (`.claude/.state/sessions/*.yaml`): Active session tracking (branch, PID, timestamp). Cleaned by `unregister_session()` at close and stale-entry cleanup (dead PIDs, >24h age).

**Lifecycle:** `.state/` files, `.session-id`, `.session-type`, `.hvst-fail-count`, `.deferrals-pending` are session-scoped (cleaned at close). `.session-log-hash` and `.session-baseline-sha` are persistent (survive across sessions).

### Worktree State Isolation (Decision 0028)

Worktree-isolated subagents (`isolation: "worktree"` in Agent tool) run in a separate git worktree but share the main repo's hook infrastructure. Hooks resolve `_REPO_OS_ROOT` from their own file path (main repo), so all state reads/writes target the main session's `.claude/.state/`.

**Contract:**
- **State writes blocked**: `state-writer.sh` refuses to write governance state files when `is_worktree()` detects a worktree CWD. Worktree subagent verdicts are silently skipped (audit-logged, reason: `worktree_blocked`).
- **State reads pass through**: Phase-state reads in worktree hooks reflect the main session's phase. This is intentional — worktree subagents operate under the parent session's governance.
- **Implication**: Governance agents (critic, qa-verifier, reviewer, security-privacy, pragmatist) dispatched with `isolation: "worktree"` will not produce state files. The parent session must re-dispatch in-tree if governance evidence is needed.
- **Detection**: `is_worktree()` in `_analytics-helper.sh` compares `git rev-parse --git-dir` vs `--git-common-dir`. Cached per-process.

---

## Constraint Severity Prefixes

| Prefix | Meaning | Enforcement |
|--------|---------|-------------|
| **BLOCK** | Mechanically enforced (hook/settings prevents action) | Hook script, `disallowedTools`, `settings.json` |
| **REQUIRE** | Process obligation (model must comply, no mechanical enforcement) | Agent prose, workflow rules |
| **GUIDE** | Best practice (deviation acceptable with reason) | Advisory only |

**DELEGATE**: orchestrator routing prefix (not severity). Classification: BLOCK only when mechanically enforced (reference the hook/setting). Agent "block" verdicts are REQUIRE. Structural content (tables, sequences) has no prefix. Tag at bullet level.

---

## Phase Model

Ordered phases tracked in `.claude/.state/phase-state` (Decision 0014). Hooks manage transitions automatically.

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
| conversation | Prompt T query / Prompt Q: conversational Q&A |
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

### Editor-Live Sessions

Operator-driven editing. Phases: `init → build → commit → review → verify → op-review → close`. No plan gate. Loops: `commit→build`, `verify→build`. A4 per-loop; full gates at close. Child mode only. Cycle advisory at 50. See Decision 0023.

### Advisory Sessions

Prompt A review sessions. Two session types:
- **advisory-init**: Full advisory review — `init → tier-select → dispatch → synthesize → op-review → validate → governance → close`. Dispatches specialist agents for multi-tier review.
- **advisory-reinit**: Lightweight re-review — `init → validate → governance → close`. Validates prior advisory configuration without full re-dispatch.

Both are advisory-only (governance evidence at close, no implementation gates).

### Ephemeral Sessions (Phase 3b)

Lightweight Q&A/exploration: `init → conversation → close`. Skips mode-guard, branch gates, close checks. No solo merge or branch seal. Convert to standard via `upgrade_session_type` (resets phase to `plan`). REQUIRE: on upgrade, read `workflow.md` and `quality-gates.md` (full) if not in context.

### Auto/Review Mode
**Auto**: completes through merge autonomously (`op-review` skipped). **Review** (default): pauses at `op-review` for operator acceptance.

### Solo Mode (Decision 0015)

Merge to main at session close. Applies to `feature/*`, `fix/*`, `hotfix/*` only (`experiment/*`, `release/*` excluded). Auto mode: autonomous after gates pass. Review mode: pauses at `op-review`. Merge failure: `git merge --abort` + operator notification (no auto conflict resolution on main).

---

## Operating Modes

Three modes control file-edit permissions. Enforced by `write-guard.sh` (Decision 0012).

| Mode | Scope | Governance Carve-outs |
|------|-------|-----------------------|
| **template** | Governance only (no product code) | Full governance access (`.claude/`, `docs/ai/`, `docs/spec/_templates/`, `.github/`, `AI.md`, `CLAUDE.md`, `repo-os-explainer.html`). Contracts at `.claude/local/task-groups/` |
| **child** (default) | Product code + limited governance | `docs/ai/decisions/0100+`, `docs/ai/logs/`, `docs/ai/governance/`, `docs/ai/task-groups/*.yaml` (non `_`-prefixed), `docs/spec/compiled/`, `docs/spec/prototypes/`, `.claude/settings.local.json`. Template `t-*` files protected |
| **autonomous** | Product code + minimal governance | `docs/ai/logs/`, `docs/ai/task-groups/*.yaml` (non `_`-prefixed) only |

**Resolution:** `REPO_OS_MODE` env var > `.claude/repo-mode` file > default `child`. Override: `REPO_OS_SKIP_MODE_GUARD=1` (skip entirely), `REPO_OS_UNLOCK_PATH=<path>` (single-file unlock, immune paths excluded).

### Session Close Overrides

Stop hook (`session-close-check.sh`) gates. All overrides logged via `log_override()`.

| Override | Gate | Effect |
|----------|------|--------|
| `SKIP_SESSION_LOG=1` | Session log (blocking) | Bypasses session log check |
| `SKIP_UNCOMMITTED_CHECK=1` | Uncommitted changes (blocking) | Allows close with dirty tree |
| `SKIP_KNOWN_ISSUES_CHECK=1` | Known-issues (advisory) | Suppresses known-issues reminder |
| `SKIP_CONTRACT_CHECK=1` | Task group contract (blocking) | Bypasses A6 contract + governance checks |

### Pre-Commit Overrides

Commit hook (`pre-commit-gates.sh`) gates. All overrides logged via `log_override()`.

| Override | Gate | Effect |
|----------|------|--------|
| `REPO_OS_RECOVER=1` | All state-dependent checks | Emergency recovery — skips plan-approved, cohesion-reviewed, qa-verified, pragmatist-signed |
| `REPO_OS_SKIP_PLAN_GATE=1` | plan-approved (blocking) | Bypasses plan-approved state file check |
| `REPO_OS_SKIP_PRAGMATIST_GATE=1` | pragmatist-signed (blocking) | Bypasses pragmatist-signed state file check (Decision 0025) |

### Phase Helper Overrides

Phase management (`_phase-helper.sh`) gates.

| Override | Gate | Effect |
|----------|------|--------|
| `REPO_OS_ALLOW_REINIT=1` | init_phase double-init guard | Allows re-initialization of phase state for the same session (crash recovery) |

### Decision Naming Convention
`t-NNNN-*.md` = template decisions (synced from upstream, locked in child/autonomous). `0100-*.md`+ = child decisions (editable in child mode). Enforced by mode-guard `t-` prefix check (Decision 0022). `t-manifest.txt` lists template decisions for orphan cleanup.

---

## User Review

Decision 0021. LLM persona simulation — synthetic user perspective on implementation. Advisory only (no gate, no state file). Phase: `user-review` (after `verify`, before `commit`). Skipped when brief has no `### User Review` section.

**Activation** (never default-on): task brief opt-in (`### User Review` section with tiers/scenarios, carried via contract `user_review:` block) or operator request mid-session.

**Dispatch:** Orchestrator dispatches persona agents (`_user-review-tier-{1,2,3}.md`) in parallel. Results deduplicated across tiers, severity-escalated to highest. Report presented at `op-review`. Operator dispositions each finding (accept / note / dismiss). Deferred findings noted in closing summary.

**Exclusions:** Child mode only. Excluded from template, autonomous, headless/automation, and experiment sessions. Token cost: 20k–50k per run (mitigated by opt-in).

| Tier | Persona | Mental Model | Error Recovery | Confusion Threshold |
|------|---------|-------------|----------------|---------------------|
| **1** | Power User | Strong | 2–3 alternatives | Low |
| **2** | Everyday User | Partial | Once, then help | Moderate |
| **3** | Novice User | None | Stops immediately | High |

---

## Governance Prefixes

Protected path prefixes enforced by `write-guard.sh`, subject to mode-based restrictions: `.claude/`, `docs/ai/`, `docs/spec/_templates/`, `.github/`, `AI.md`, `CLAUDE.md`, `repo-os-explainer.html`.

Immune paths (never modifiable, no override): `.claude/hooks/write-guard.sh`, `.claude/repo-mode`. To maintain: `REPO_OS_SKIP_MODE_GUARD=1` (disables guard entirely, logged).
