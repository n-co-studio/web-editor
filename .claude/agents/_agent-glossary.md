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
5-step debugging protocol for non-trivial failures. Requires hypothesis before code change. Tracked by `hvst-failure-tracker.sh`. Use when: bugs, failing tests, unstable behavior. Loop: **Hypothesis** → **Validate** (smallest experiment) → **Solve** (minimal fix) → **Test** (rerun) → **Record** (after 2+ failed cycles: add to `docs/ai/logs/known-issues.md`). At 2 consecutive failures, check `docs/ai/logs/known-issues.md` for matches. REQUIRE: known-issues documentation at session close (advisory, downgraded from blocking). Override: `SKIP_KNOWN_ISSUES_CHECK=1`.

**Review Board** (optional): At 2+ failures or operator request → Architect + Exploration + Critic (hypothesis mode). See `.claude/agents/_hvst-review.md`.

### Cohesion Review
Post-build Critic review (cohesion mode): checks diff + surrounding code for broken cross-references, dangling imports, inconsistent naming, contradictory patterns. Gate A5. Operates on code, not specs.

**Downstream Consumer Validation** — mandatory Critic finding category. For every modified function/interface: grep all callers, evaluate contract change (return type, params, side effects, errors), produce per-function finding: "Function `X` called by `Y` at `file:line`. After change, `Y` will receive [new behavior]. Impact: [works / breaks / needs update]." Flag as CRITICAL if any caller breaks. Evaluate concrete callers — do not speculate about theoretical consumers.

### Regression Gate (Sequential Brief Verification)
QA MUST check for prior briefs targeting the same files: (1) find prior brief in same task group (`briefs[]` in contract) or recent session logs (3 most recent `session-*.md`); (2) read its `verification:` checklist; (3) re-verify each item; (4) flag failures as CRITICAL: "Regression: prior brief [N] item '[item]' no longer passes." Regression findings are commit-blocking — they indicate this brief broke something a previous brief established.

### Knowledge Graph Protocol (Decision 0034)

Two-graph architecture: `docs/ai/knowledge-graph/graph.yaml` (template infrastructure nodes — decisions, hooks, prompts, agents) and `product-graph.yaml` (product code nodes, child-owned). Cross-layer edges stored in the source node's graph.

**Graph-First Lookup** — REQUIRE: Before any broad search (`grep -r`, `find`, repo-wide glob) in a build session, read `.claude/.state/kg-relevance-context` when it exists and is non-empty. This file is pre-computed by `_phase-helper.sh` at build phase entry via `kg-relevance.sh` (searches both graphs). When absent/empty: proceed with normal search.

**Session-Type Profiles:**

| Profile | Session Type | Read | Write |
|---------|-------------|------|-------|
| Full | Prompt B | REQUIRE: `kg-relevance-context` when present | REQUIRE-attempt at close |
| Expedited | Prompt H | Call `kg-relevance.sh` directly after investigation | REQUIRE-attempt at close |
| Light | Prompt E | Once at build entry if present | REQUIRE-attempt at close |
| Audit | Prompt C | Read-only (`graph-health` mode) | None |

**Rules:** Graph writes via shell I/O only (not Edit/Write). Route: template files → `graph.yaml`, product → `product-graph.yaml`. Lock via `mkdir` (`.graph-lock` / `.product-graph-lock`). Edge types: 8-type taxonomy (`governs`, `constrains`, `implements`, `depends-on`, `produces`, `consumes`, `tests`, `supersedes`). Agent edges: `source_type: agent-inferred`, confidence 0.7 (verified) / 0.3–0.5 (inferred). Never modify `operator-curated` edges. Stale edges: set `status: stale` (never delete). REQUIRE: attempt write at close before final commit — log failure and proceed, do not skip.

**Lifecycle:** Read — `.claude/.state/kg-relevance-context` (pre-computed). Write — session close, before final commit. Seed — `kg-seed.sh --target template|product` during Prompt A init.

### PM Scope Labels
PM-specific labels (orthogonal to severity): **IN-SCOPE**, **OUT-OF-SCOPE**, **DEFER**. Applied by PM Advisory alongside standard severity. Informational — do not affect Refinement Report routing.

### UX Design Agent
Three-mode UX agent (`.claude/agents/ux-designer.md`):

| Mode | Trigger | Output |
|------|---------|--------|
| 1 — Design (generative) | Prompt T — task mentions UI/screens/forms/design | Structured design brief |
| 2 — UX Review (advisory) | Prompt A spec review; Prompt B post-build (UI changes) | Advisory findings (CRITICAL / RECOMMENDATION / IDEA) |
| 3 — Design Health (evaluative) | Prompt B post-build — UI changes; after Mode 2 or parallel with Critic | Design health compliance findings |

Modes 1+3 auto-detect design system (`tailwind.config.*`, CSS-in-JS, token files). No design system: Mode 1 proposes minimum token set; Mode 3 recommends establishing one.

### Design Health Labels
Advisory only (no gate, no state file). Labels used by Mode 3: **TOKEN-VIOLATION** (hardcoded values where tokens should be used) · **COMPONENT-BYPASS** (custom impl where design system component exists) · **SYSTEM-DRIFT** (off-grid spacing, non-scale typography, ad-hoc colors, undefined breakpoints).

---

## Reserved Directories

| Directory | Purpose | Access |
|-----------|---------|--------|
| `~/.local/share/repo-os-analytics/` | Centralized hook telemetry (NDJSON by repo/date). Outside repo tree | Analytics agent only — all others MUST NOT read |
| `~/.local/share/repo-os-analytics/<repo>/evidence-manifest/` | Session-scoped governance evidence manifests (SHA-256 per evidence file at init_phase; refreshed by sanctioned writers; compared at pre-commit + session-close). One YAML file per session, keyed by sanitised session id. Outside repo tree — not reachable via in-repo Bash path bypass. Retention: deleted at session close by `cleanup_evidence_manifest()` | Governance hooks only (write: `_phase-helper.sh`; read: `compare_manifest()` in `pre-commit-gates.sh` + `session-close-check.sh`). All agents MUST NOT read or write directly |
| `.claude/analytics/` (legacy) | Historical event data (pre-migration). Read-only | Analytics agent (historical reads only) |
| `.claude/.automation/` | Automation layer (Decision 0017). Tracked: schemas, config, decision cache, templates, lib. Gitignored: queue, reports, escalations, briefs, logs | Runner process + Dev Orchestrator (reports only). All others MUST NOT write |

**Runtime report output path:** All runtime report artifacts (completion reports, blocker reports, escalation reports, health reports) MUST be written to `.claude/.automation/reports/`. Do not create new output directories under `.automation/` — use the existing gitignored paths listed above. This directory is the canonical destination for any YAML or JSON report generated during or after a session.

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

**Agent-written state files** (`.claude/.state/` unless noted):

| File | Writer | Gate / Purpose |
|------|--------|----------------|
| `plan-approved` | `plan-approval.sh` | Branch guard + A2 scope (Decision 0029) |
| `cohesion-reviewed` | `state-writer.sh` (critic — cohesion or combined mode) | A5 state verification; GATE_RESULT: BLOCKED is blocking |
| `diff-review-complete` | `state-writer.sh` (critic — diff-review or combined mode) | A5 state verification; written when Critic output contains either `MODE: diff-review` sentinel (single-mode) or both `## Cohesion Brief` and `## Diff-Review Brief` headers (combined mode — Decision 0039); GATE_RESULT: BLOCKED blocks commit |
| `qa-verified` | `state-writer.sh` (qa-verifier) | State verification |
| `reviewer-signed` | `state-writer.sh` (reviewer) | High-risk detection |
| `security-signed` | `state-writer.sh` (security-privacy) | High-risk detection |
| `pragmatist-signed` | Three legitimate writers — each stamps a provenance marker: (1) `state-writer.sh` (pragmatist Plan-Gating dispatch) → `dispatch_phase:`; (2) `bundle_to_pragmatist_signed()` in `_phase-helper.sh` (Decision 0038 drift-check) → `source: handoff-bundle`; (3) `write_alignment_check_pragmatist_signed()` in `_phase-helper.sh` (deterministic alignment-check) → `source: alignment-check`. Gate rejects files with no recognised marker. Do NOT write by hand. | Plan-review verification — commit gate requires presence + valid session_id + provenance marker |
| `functional-verified` | `pre-commit-gates.sh` (A3.4 inline) | A3.4 functional verification — written on script pass in headless/auto mode; required by binding gate when `_A34_APPLICABLE=true` and `IS_NO_REVIEW_BACKSTOP=true`. Decision 0044. |
| `kg-updated` | `pre-commit-gates.sh` (KG Update Gate) | KG Update Gate — written on gate pass when staged governance files have graph nodes and graph is current. Session-scoped. Suppresses `session-close-check.sh` advisory when present. Override: `REPO_OS_SKIP_KG_GATE=1` (interactive only). Decision 0034 Amendment 7. |

**Hook-written files** (all cleaned by `cleanup_session_files` unless noted): `phase-state` (`_phase-helper.sh` — phase tracking), `overrides.log` (`_analytics-helper.sh` — override audit, append-only), `high-risk-detected` (`pre-commit-gates.sh` — audit trail), `governance-checked` (`pre-commit-gates.sh` Gate 3 — first-fire inter-session marker, version-aware per Decision 0041), `governance-bash-fired` (`bash-guard.sh` Phase 1d — first-Bash-write inter-session marker, version-aware per Decision 0041), `merge-source-branch` (`_phase-helper.sh` `write_merge_signal` — agent-to-hook merge signal), `brief-has-taskgroup` (`_phase-helper.sh` — session-type validation, Decision 0026), `session-resume.yaml` (`_phase-helper.sh` — compression recovery, updated each phase), `cycle-escalation` (`_phase-helper.sh` — cycle cap at 5+, advisory), `cycle-advisory-N` (`bash-guard.sh` — per-cycle dedup), `kg-relevance-context` (`_phase-helper.sh` — KG pre-computed context at build entry, Decision 0034), `kg-search-advisory-fired` (`bash-guard.sh` — one-shot graph-first advisory dedup), `cross-session-context` (`_phase-helper.sh` via `_cross-session-context.sh` — recent git log + last session log tail injected at build entry), `finish-loop-cache.yaml` (`_phase-helper.sh` `record_dimension_verdict` — finish-loop dimension verdict cache, Decision 0040), `.stop-attempt-count` (`session-close-check.sh` — safety valve at 3 attempts, not cleaned). `kg-updated` (`pre-commit-gates.sh` KG Update Gate — session-scoped gate-pass marker, cleaned at close).

**Model-written files** (in `.claude/local/`, not `.state/` — state-guard allows): `task-contract.yaml` (orchestrator — intent + verification for cohesion review, Decision 0020), `scope-risk-gain` (orchestrator — risk/gain for unbriefed-in-scope files, Decision 0017).

**Other files:** `.pragmatist-enforced` (`.claude/local/` — gate deployment sentinel, persistent). Operational (`.claude/`): `.session-baseline-sha` (persistent baseline), `.session-id` (analytics, immune), `.session-type`, `.hvst-fail-count`, `.deferrals-pending`. Recovery: `.claude/.state/.recover-signal` (file-based `REPO_OS_RECOVER=1` alternative — single-use, auto-deletes). Registry: `.claude/.state/sessions/*.yaml` (session tracking — cleaned at close or after stale >24h/dead PID). Session-scoped files cleaned at close; per-session logs (`docs/ai/logs/sessions/session-{id}.md`) accumulate and are never auto-deleted.

### Worktree State Isolation (Decision 0028)

Worktree-isolated subagents (`isolation: "worktree"`) share the main repo's hook infrastructure — all state reads/writes target the main session's `.claude/.state/`. State writes blocked: `state-writer.sh` refuses when `is_worktree()` detects worktree CWD (verdicts silently skipped, reason: `worktree_blocked`). State reads pass through. Governance agents dispatched with worktree isolation will not produce state files — re-dispatch in-tree if evidence needed. Detection: `is_worktree()` compares `git rev-parse --git-dir` vs `--git-common-dir`. Full worktree sessions (`claude --worktree`): see Decision 0030.

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

Ordered phases tracked in `.claude/.state/phase-state` (Decision 0014). Tags: `agent` (autonomous) · `operator` (pauses) · `both`. Auto mode: skips `op-review`. Solo mode (Decision 0015): merges `feature/*`/`fix/*`/`hotfix/*` to main; `experiment/*`/`release/*` excluded; merge failure → abort + notify.

| Phase | Description |
|-------|-------------|
| init | Setup |
| drift-check | Evaluate handoff bundle (Decision 0038). On valid + fresh: forward-jump to build. On absent/stale: fall through to plan |
| plan | Scope + plan (legacy fallback when drift-check falls through) |
| approval | Operator approves (legacy fallback when drift-check falls through) |
| build | Implement |
| review | Critic cohesion |
| verify | QA gates |
| user-review | Persona dispatch (opt-in, standard only) |
| commit | Commit with trailers |
| op-review | Operator review (skipped in auto) |
| close | Session log + merge + seal |
| contract-init | Task group: create/sync contract |
| contract-update | Task group: update at close |
| cohesion | Taskgroup-merge: cross-brief cohesion |

Session-type-specific phases (see sequences table): `interview`/`write` (Prompt 0), `tier-select`/`dispatch`/`synthesize`/`output`/`governance`/`validate` (advisory), `conversation` (ephemeral/queue-triage), `evaluate`/`document` (prototype), `scope` (Prompt C), `design`/`pre-register`/`launch`/`await`/`collect`/`judge`/`report` (eval).

| Session type | Phase sequence | Notes |
|-------------|----------------|-------|
| standard | init→[drift-check]→[plan]→[approval]→build→review→verify→[user-review]→commit→[op-review]→close | drift-check (Decision 0038): valid bundle → forward-jump to build (skip plan/approval); otherwise fall through to legacy plan/approval. op-review skipped in auto |
| hotfix | init→plan→approval→build→verify→commit→close | Loop: verify→build; A2 enforced (large-scope: true satisfies), A5 skip; max 3 cycles; bundle handling not applied |
| editor-live | init→build→commit→review→verify→op-review→close | No plan gate; loop: commit→build; child mode only |
| finish-loop | init→assess→fix→reassess→commit→close | Loop: reassess→fix; convergent quality assessment; cycle cap 5 |
| advisory-init | init→tier-select→dispatch→synthesize→op-review→validate→governance→close | Advisory only |
| advisory-reinit | init→validate→governance→close | Lightweight re-review |
| ephemeral | init→conversation→close | Skip gates; upgrade via `upgrade_session_type` |
| taskgroup-merge | init→contract-init→cohesion→verify→commit→[op-review]→close | Cross-brief Critic; seal all branches |
| eval | init→design→pre-register→launch→await→collect→judge→report→close | Conductor: orchestrates arms×tasks×reps; full governance on own committed records; cells NOT merged to main. Decision t-0046 |
| eval-cell | init→build→commit→close | Per-cell agent in isolated worktree; no close-merge; A4-only gate (standard arm) or full gate (full-governance arm). Decision t-0046 |

---

## Operating Modes

Three modes control file-edit permissions. Enforced by `write-guard.sh` (Decision 0012).

| Mode | Scope | Governance Carve-outs |
|------|-------|-----------------------|
| **template** | Governance only (no product code) | Full governance access (`.claude/`, `docs/ai/`, `docs/spec/_templates/`, `.github/`, `AI.md`, `CLAUDE.md`, `repo-os-explainer.html`). Contracts at `.claude/local/task-groups/`. Automation layer at `.claude/.automation/*` |
| **child** (default) | Product code + limited governance | `docs/ai/decisions/0100+`, `docs/ai/logs/`, `docs/ai/governance/`, `docs/ai/task-groups/*.yaml` (non `_`-prefixed), `docs/spec/compiled/`, `docs/spec/prototypes/`, `.claude/settings.local.json`, `.claude/.automation/reports/*` (Dev Orchestrator health reports only — Decision t-0017 §10), `docs/ai/knowledge-graph/product-graph.yaml` (child-owned product graph — Decision t-0034). Template `t-*` files protected |
| **autonomous** | Product code + minimal governance | `docs/ai/logs/`, `docs/ai/task-groups/*.yaml` (non `_`-prefixed) only |

**Resolution:** `REPO_OS_MODE` env var > `.claude/repo-mode` file > default `child`. Override: `REPO_OS_SKIP_MODE_GUARD=1` (skip entirely), `REPO_OS_UNLOCK_PATH=<path>` (single-file unlock, immune paths excluded).

### Overrides

All overrides logged via `log_override()`.

| Override | Hook | Gate | Effect |
|----------|------|------|--------|
| `SKIP_SESSION_LOG=1` | session-close-check | Session log | Bypass session log check |
| `SKIP_UNCOMMITTED_CHECK=1` | session-close-check | Uncommitted changes | Allow close with dirty tree |
| `SKIP_KNOWN_ISSUES_CHECK=1` | session-close-check | Known-issues (advisory) | Suppress known-issues reminder |
| `SKIP_CONTRACT_CHECK=1` | session-close-check | Task group contract | Bypass A6 contract + governance |
| `SKIP_CROSS_SESSION_CONTEXT=1` | _phase-helper | Cross-session context injection | Bypass git log + session log injection at build entry |
| `REPO_OS_RECOVER=1` | pre-commit-gates | All state checks | Emergency recovery — skip plan-approved, cohesion-reviewed, diff-review-complete, qa-verified, pragmatist-signed, kg-updated |
| `REPO_OS_SKIP_PLAN_GATE=1` | pre-commit-gates / bash-guard | plan-approved | Bypass plan-approved check |
| `REPO_OS_SKIP_PRAGMATIST_GATE=1` | pre-commit-gates | pragmatist-signed | Bypass pragmatist-signed check (Decision 0025) |
| `SKIP_FUNC_CHECK=1` | pre-commit-gates | A3.4 functional-verified | Bypass A3.4 functional verification (build/pack/test scripts). **Interactive mode only** — ignored in headless/auto (IS_NO_REVIEW_BACKSTOP=true); writes governance-block escalation and continues. Use `REPO_OS_RECOVER=1` to bypass in headless/auto (Decision t-0044 Amendment 1). |
| `REPO_OS_SKIP_KG_GATE=1` | pre-commit-gates | KG Update Gate | Bypass KG Update Gate. **Interactive mode only** — ignored in headless/auto (IS_NO_REVIEW_BACKSTOP=true); gate still enforced. Use `REPO_OS_RECOVER=1` to bypass in headless/auto. Decision 0034 Amendment 7. |
| `REPO_OS_FUNC_CHECK_TIMEOUT` | pre-commit-gates | A3.4 functional-verified | Per-command timeout in seconds for A3.4 script execution (default: 120). |
| `REPO_OS_ALLOW_REINIT=1` | _phase-helper | double-init guard | Allow re-init of phase state (crash recovery) |

### Decision Naming Convention
`t-NNNN-*.md` = template decisions (synced from upstream, locked in child/autonomous). `0100-*.md`+ = child decisions (editable in child mode). Enforced by mode-guard `t-` prefix check (Decision 0022). `t-manifest.txt` lists template decisions for orphan cleanup.

---

## User Review

Decision 0021. LLM persona simulation — synthetic user perspective. Advisory only (no gate, no state file). Phase: `user-review` (after `verify`, before `commit`). Opt-in only: `### User Review` section in brief (with tiers/scenarios). Never default-on. Child mode only — excluded from template, autonomous, headless, and experiment sessions. Token cost: 20k–50k per run.

**Dispatch:** Persona agents in parallel → deduplicate → escalate to highest severity → present at `op-review`. Operator: accept / note / dismiss.

| Tier | Persona | Mental Model | Error Recovery |
|------|---------|-------------|----------------|
| **1** | Power User | Strong | 2–3 alternatives |
| **2** | Everyday User | Partial | Once, then help |
| **3** | Novice User | None | Stops immediately |

---

## Governance Prefixes

Protected paths enforced by `write-guard.sh`: `.claude/`, `docs/ai/`, `docs/spec/_templates/`, `.github/`, `AI.md`, `CLAUDE.md`, `repo-os-explainer.html`. Immune (no override): `.claude/hooks/write-guard.sh`, `.claude/repo-mode`, `.claude/.session-id`. To maintain: `REPO_OS_SKIP_MODE_GUARD=1` (logged).
