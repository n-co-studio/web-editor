# Agent Workflow & Handoffs

## Advisory Flow (Spec Review)

Runs after Prompt 0, before build begins. Orchestrated by Prompt A Phase 1. Tier selected before dispatch. Canonical definition: `docs/ai/workflow.md` § Advisory Board Review. Agent reference: `.claude/agents/_advisory-board.md`.

---

## Task Definition Flow (Prompt T — Brief Mode)

Lightweight spec-mode dispatch of Architect + Exploration + Critic + Pragmatist for task scoping. No file output. Canonical definition: `docs/ai/prompts/prompt-t-task-definition.md`. See also `docs/ai/workflow-appendix/session-type-task-definition.md`.

### Handoff Chain
1. **Operator → Orchestrator**: Task description (what/why/constraints)
2. **Orchestrator → Architect + Exploration + Critic + Pragmatist**: Parallel dispatch with task context + specs
3. **Specialists → Orchestrator**: Lightweight briefs (same format as advisory board)
4. **Orchestrator → Operator**: Synthesized draft task brief for review
5. **Operator → Orchestrator**: Approve / revise / narrow / abandon
6. **Orchestrator → Operator**: Final task brief displayed for copy-paste into Prompt B

No file artifacts. No session log entry. No handoff to Build Flow — the operator manually carries the brief to a new Prompt B session.

**Narrow path (multi-brief):** When the operator narrows a task, each sub-brief includes a `### Task Group` section with group name, sequence, and integration notes. If sub-briefs have non-overlapping file scope, Prompt T offers parallel execution — parallel groups include `Execution: parallel`, per-brief `Boundaries:`, and an auto-generated merge brief (Brief M) that runs as `taskgroup-merge` session type. See `docs/ai/workflow-appendix/session-type-task-group.md` for contract lifecycle and `docs/ai/task-groups/_contract-template.yaml` for the contract structure.

---

## HVST Review Flow (Debug Stall)

Runs when HVST debugging stalls (2+ consecutive failures) or when the operator proactively requests a debug review. Canonical definition: `.claude/agents/_agent-glossary.md` § HVST. Procedure: `.claude/agents/_hvst-review.md`.

### Handoff Chain
1. **Builder stalls** — 2+ consecutive HVST failures, or operator observes unproductive debugging
2. **Orchestrator detects / operator requests** — Orchestrator reads `_hvst-review.md` procedure
3. **Orchestrator → Architect + Exploration + Critic (hypothesis mode)** — Parallel dispatch with error context, attempted hypotheses, files touched
4. **Specialists → Orchestrator** — Debug Briefs with findings
5. **Orchestrator synthesizes** — Ranked hypotheses (not consensus) ordered by evidence strength, falsifiability, implementation risk
6. **Operator / Builder picks hypothesis** — Selects which to validate first
7. **Builder validates** — Resumes HVST loop with chosen hypothesis
8. **If still stuck** — Escalate to operator (cap: 1 review board round)

---

## Audit Flow (Project Health)

Runs on-demand when the operator invokes Prompt C. Read-only — no file modifications (exception: deferrals write to `known-issues.md`). Canonical definition: `docs/ai/prompts/prompt-c-project-audit.md`. Agent reference: `.claude/agents/auditor.md`.

### Handoff Chain
1. **Operator → Orchestrator**: Dimension selection + tier (Quick / Standard / Deep)
2. **Orchestrator → Auditor (per dimension) + Security/Performance (if selected)**: Parallel dispatch with mode and scope
3. **Auditor → Orchestrator**: Dimension briefs (with `[ESCALATE: agent-name]` tags if any)
4. **Orchestrator → Specialist (if escalated)**: Focused follow-up on tagged findings
5. **Specialist → Orchestrator**: Escalation brief
6. **Orchestrator → Operator**: Synthesized Audit Report for per-finding review (accept / reject / defer)

### Specialist Collaboration Variants
- **Escalation**: Auditor tags a finding → Orchestrator dispatches specialist → one-shot response
- **Co-audit**: Operator requests specialist alongside Auditor → both dispatched in parallel → briefs merged
- **Workshop**: Iterative loop (Auditor → specialist → Auditor refine) → capped at 2 rounds → surface to operator

---

## Build Flow (Implementation)

Phase labels correspond to Decision 0014 phase sequences. Auto/review mode set at approval phase.

| Phase | Actor | Condition | Action | Next Phase |
|-------|-------|-----------|--------|------------|
| init | Operator | — | Create branch from main | plan |
| plan | Orchestrator | — | Draft plan; read/create task group contract if applicable | plan-gate |
| plan-gate | Pragmatist | APPROVED | — | approval |
| plan-gate | Pragmatist | BLOCKED | Surface finding + "wrong if:" to operator; operator can override or re-plan; auto mode degrades to advisory | approval |
| approval | Operator | — | Approve plan (sets auto/review mode) | build |
| build | Builder | — | Implement; run local checks; signal done | review |
| review | Critic (cohesion) | CLEAN | — | verify |
| review | Critic (cohesion) | FINDINGS — clear fixes | Orchestrator sends fixes to Builder; re-run Critic | review |
| review | Critic (cohesion) | FINDINGS — ambiguity | Orchestrator escalates to Operator | review |
| verify | QA/Verifier | FAIL | Return to Builder | build |
| verify | QA/Verifier | PASS — not high-risk | — | user-review |
| verify | QA/Verifier + Reviewer + Security | PASS — high-risk | Reviewer + Security both sign off | user-review |
| user-review | Persona agents | User Review declared in task brief | Dispatch persona agents; synthesize findings | commit |
| user-review | — | No User Review in task brief | Skip | commit |
| commit | Orchestrator | — | ✓ Commit allowed | op-review |
| op-review | Operator | review mode | Pause for operator review | close |
| op-review | — | auto mode | Skip | close |
| close | Orchestrator | solo mode | Merge branch to main; seal branch (Decision 0013). Parallel content briefs: close without merge or seal — merge brief handles both | — |

---

## Merge Brief Flow (Parallel Task Group Integration)

Phase labels correspond to Decision 0014 `taskgroup-merge` phase sequence. Runs after all parallel content briefs complete.

| Phase | Actor | Condition | Action | Next Phase |
|-------|-------|-----------|--------|------------|
| init | Operator | — | Check out task group branch | contract-init |
| contract-init | Orchestrator | — | Sync from contract; verify all completion markers exist (`$_REPO_OS_ROOT/.claude/.state/tg-{group}-brief-{seq}.complete`); read source branches from `briefs[].branch` | cohesion |
| cohesion | Orchestrator | — | Combine per-brief branches into group base branch (merge/cherry-pick each `briefs[].branch`); then `git diff main...HEAD` for combined diff | cohesion (Critic) |
| cohesion | Critic (cohesion) | CLEAN | — | verify |
| cohesion | Critic (cohesion) | FINDINGS — clear fixes | Fix directly in merge brief | cohesion |
| cohesion | Critic (cohesion) | FINDINGS — ambiguity | Escalate to Operator | cohesion |
| verify | QA/Verifier | — | Verify all gates (A1–A6, B1–B3) | commit |
| commit | Orchestrator | — | ✓ Commit allowed | op-review |
| op-review | Operator | review mode | Pause for operator review | close |
| op-review | — | auto mode | Skip | close |
| close | Orchestrator | — | Merge branch to main; seal all branches (group base + per-brief); clean completion markers | — |

---

## Handoff Chain

### Advisory Phase
0a. **Operator → Orchestrator**: Completed spec (via Prompt 0)
0b. **Orchestrator → Advisory Board**: Spec files for parallel review
0c. **Advisory Board → Orchestrator**: Individual specialist briefs
0d. **Orchestrator → Operator**: Synthesized refinement report for review

### Build Phase
1. **Operator → Orchestrator**: Task request
1b. **Orchestrator → Pragmatist (plan-gating)**: Draft plan text for over-engineering review
1c. **Pragmatist → Orchestrator**: Plan review verdict (APPROVED/BLOCKED) with findings
2. **Orchestrator → Builder**: Approved plan, instructions, decisions, scope
3. **Builder → Orchestrator**: Completion signal, changes made, local check results
4. **Orchestrator → Critic (cohesion)**: Diff context, changed files, review request
5. **Critic → Orchestrator**: Cohesion Brief with findings
6. **Orchestrator → Builder** (if fixes needed): Specific fix instructions from cohesion findings
7. **Orchestrator → QA**: Verification request (after cohesion review clean)
8. **QA → Reviewer** (when required): Code diff with risk assessment
9. **QA → Security** (when required): Code diff with risk assessment
10. **Orchestrator → Accessibility** (when applicable): UI code with context

## Subagent Reference

### Advisory Board (Spec Review Phase)

| Agent | Tier | Invoke When | Blocks Commit? |
|-------|------|------------|----------------|
| **Architect** | Lite+ | Core group — always when board runs | No (advisory) |
| **Critic** (spec mode) | Lite+ | Core group — always when board runs | No (advisory) |
| **Pragmatist** (brief-advisory mode) | Lite+ | Core group — always when board runs | No (advisory) |
| **Exploration** | Standard+ | Standard tier and above | No (advisory) |
| **Security Analyst** | Full | Signal-triggered at Full tier | No (advisory) |
| **UX Strategist** | Full | Signal-triggered at Full tier | No (advisory) |
| **Performance Engineer** | Full | Signal-triggered at Full tier | No (advisory) |
| **Data Strategist** | Full | Signal-triggered at Full tier | No (advisory) |

### Build Team (Implementation Phase)

| Agent | Invoke When | Blocks Commit? |
|-------|------------|----------------|
| **Pragmatist (plan-gating)** | Plan drafted, before presenting to operator | No (Orchestrator handles BLOCKED — auto mode degrades to advisory) |
| **Builder** | Plan approved, ready to implement | No |
| **Critic (cohesion)** | Builder signals done, before QA | No (Orchestrator resolves findings before QA) |
| **QA/Verifier** | Cohesion review clean, before any commit | **Yes** — always |
| **Reviewer** | Structural, high-risk, or cross-cutting changes | **Yes** — when required |
| **Security** | Auth, PII, deps changed, crypto, external integrations | **Yes** — when required |
| **Accessibility** | Public-facing UI modified, forms, interactive widgets | No (advisory) |

### HVST Review Board (Debug Stall)

| Agent | Invoke When | Blocks Commit? |
|-------|------------|----------------|
| **Architect** | HVST stall (2+ failures) or operator requests debug review | No (advisory) |
| **Exploration** | HVST stall (2+ failures) or operator requests debug review | No (advisory) |
| **Critic** (hypothesis mode) | HVST stall (2+ failures) or operator requests debug review | No (advisory) |

### Audit (Operator-Invoked)

| Agent | Invoke When | Blocks Commit? |
|-------|------------|----------------|
| **Auditor** | Operator runs Prompt C — dispatched per dimension (drift, compliance, cohesion-drift, governance, tech-debt) | No (read-only) |

Audit agents are dispatched by the Orchestrator during Prompt C. Security/Privacy and Performance Engineer may also be dispatched in audit scope (full-codebase, not diff-scoped). See `docs/ai/prompts/prompt-c-project-audit.md`.

### Operations (Operator-Invoked Tools)

| Agent | Invoke When | Blocks Commit? |
|-------|------------|----------------|
| **Analytics** | Operator requests hook telemetry analysis or cross-repo reporting | No (standalone) |
| **Security Hacker** | Operator requests adversarial security analysis of a scoped attack surface | No (advisory) |

Operations and Audit agents are invoked directly by the operator, not as part of the plan→build→verify chain. They do not participate in handoffs.

### User Review (User-Review Phase)

| Agent | Invoke When | Blocks Commit? |
|-------|------------|----------------|
| **User Review Tier 1** (Power User) | Task brief/contract declares `user_review` with tier-1, or operator requests during session | No (advisory) |
| **User Review Tier 2** (Everyday) | Task brief/contract declares `user_review` with tier-2, or operator requests during session | No (advisory) |
| **User Review Tier 3** (Novice) | Task brief/contract declares `user_review` with tier-3, or operator requests during session | No (advisory) |

User Review agents are dispatched by the Orchestrator during the `user-review` phase (after `verify`, before `commit`). The phase is skipped when the task brief has no User Review section. Agents simulate user personas walking through implementation scenarios using JTBD job stories. Results are synthesized (deduplicated, severity-escalated) and presented during `op-review`. All findings are advisory — the operator decides disposition (accept / note / dismiss). Available in child mode only. See Decision 0021.

Subagents load their own definitions from `.claude/agents/`. REQUIRE: do not read subagent files into orchestrator context.
