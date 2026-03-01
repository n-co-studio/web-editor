# Agent Workflow & Handoffs

## Advisory Flow (Spec Review)

Runs after Prompt 0, before build begins. Orchestrated by Prompt A Phase 1. Tier selected before dispatch. See `.claude/agents/_advisory-board.md` for tier definitions, activation logic, agent roster, and report structure.

---

## Task Definition Flow (Prompt T — Brief Mode)

Lightweight spec-mode dispatch of Architect + Exploration + Critic for task scoping. No file output. See `docs/ai/prompts/prompt-t-task-definition.md`.

### Handoff Chain
1. **Operator → Orchestrator**: Task description (what/why/constraints)
2. **Orchestrator → Architect + Exploration + Critic**: Parallel dispatch with task context + specs
3. **Specialists → Orchestrator**: Lightweight briefs (same format as advisory board)
4. **Orchestrator → Operator**: Synthesized draft task brief for review
5. **Operator → Orchestrator**: Approve / revise / narrow / abandon
6. **Orchestrator → Operator**: Final task brief displayed for copy-paste into Prompt B

No file artifacts. No session log entry. No handoff to Build Flow — the operator manually carries the brief to a new Prompt B session.

**Narrow path (multi-brief):** When the operator narrows a task, each sub-brief includes a `### Task Group` section with group name, sequence, and integration notes. The first Prompt B session creates the task group contract; subsequent sessions read and comply. Contract path depends on repo mode (template mode: `.claude/local/task-groups/{group-name}.yaml`; product mode: `docs/ai/task-groups/{group-name}.yaml`). See `docs/ai/task-groups/_contract-template.yaml` for the contract structure.

---

## HVST Review Flow (Debug Stall)

Runs when HVST debugging stalls (2+ consecutive failures) or when the operator proactively requests a debug review. See `.claude/agents/_hvst-review.md` for the full procedure.

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

Runs on-demand when the operator invokes Prompt C. Read-only — no file modifications, no session log entries. See `docs/ai/prompts/prompt-c-project-audit.md` for the full prompt and `.claude/agents/auditor.md` for the Auditor agent definition.

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

```
                        OPERATOR
              (owns architecture, approves plans)
                            │
                     [init phase]
              create branch from main
                            │
                     [plan phase]
                      ORCHESTRATOR
               plans → gets approval → delegates
          (reads/creates task group contract if applicable)
                            │
                   [approval phase]
              operator approves plan (auto/review)
                            │
                     [build phase]
                        BUILDER
            implements → runs local checks → signals done
                            │
                    [review phase]
               CRITIC (cohesion mode)
            reviews diff for internal coherence
                            │
                  ┌─────────┴─────────┐
               CLEAN              FINDINGS
                  │                   │
                  │          Orchestrator reviews
                  │          clear fixes → Builder
                  │          ambiguity → Operator
                  │          re-run Critic if fixes
                  │                   │
                  └─────────┬─────────┘
                            │
                    [verify phase]
                    QA / VERIFIER ⚠️ COMMIT BLOCKER
              verifies all gates (A1–A6) → BLOCK or APPROVE
                            │
                  ┌─────────┴─────────┐
               PASS                 FAIL → back to Builder
                  │
            high-risk?
                  │
          ┌───────┴───────┐
         YES              NO
          │               │
   REVIEWER + SECURITY    │
     both sign off        │
          │               │
          └───────┴───────┘
                  │
                  ▼
            [commit phase]
           ✓ COMMIT ALLOWED
                  │
           [op-review phase]
         (review mode: pause for operator)
         (auto mode: skip to close)
                  │
            [close phase]
         merge branch to main (solo mode)
         seal branch (Decision 0013)
```

---

## Handoff Chain

### Advisory Phase
0a. **Operator → Orchestrator**: Completed spec (via Prompt 0)
0b. **Orchestrator → Advisory Board**: Spec files for parallel review
0c. **Advisory Board → Orchestrator**: Individual specialist briefs
0d. **Orchestrator → Operator**: Synthesized refinement report for review

### Build Phase
1. **Operator → Orchestrator**: Task request
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
| **Architect** | Lite+ | Core pair — always when board runs | No (advisory) |
| **Critic** (spec mode) | Lite+ | Core pair — always when board runs | No (advisory) |
| **Exploration** | Standard+ | Standard tier and above | No (advisory) |
| **Security Analyst** | Full | Signal-triggered at Full tier | No (advisory) |
| **UX Strategist** | Full | Signal-triggered at Full tier | No (advisory) |
| **Performance Engineer** | Full | Signal-triggered at Full tier | No (advisory) |
| **Data Strategist** | Full | Signal-triggered at Full tier | No (advisory) |

### Build Team (Implementation Phase)

| Agent | Invoke When | Blocks Commit? |
|-------|------------|----------------|
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

Operations and Audit agents are invoked directly by the operator, not as part of the plan→build→verify chain. They do not participate in handoffs.

Subagents load their own definitions from `.claude/agents/`. Do not read subagent files into orchestrator context.
