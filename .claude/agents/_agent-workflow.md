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

---

## Build Flow (Implementation)

```
                        OPERATOR
              (owns architecture, approves plans)
                            │
                            ▼
                      ORCHESTRATOR
               plans → gets approval → delegates
                            │
                            ▼
                        BUILDER
            implements → runs local checks → signals done
                            │
                            ▼
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
                            ▼
                    QA / VERIFIER ⚠️ COMMIT BLOCKER
              verifies all gates (A1–A5) → BLOCK or APPROVE
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
           ✓ COMMIT ALLOWED
         (QA runs push gates before push)
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

### Operations (Operator-Invoked Tools)

| Agent | Invoke When | Blocks Commit? |
|-------|------------|----------------|
| **Analytics** | Operator requests hook telemetry analysis or cross-repo reporting | No (standalone) |

Operations agents are invoked directly by the operator, not as part of the plan→build→verify chain. They do not participate in handoffs.

Subagents load their own definitions from `.claude/agents/`. Do not read subagent files into orchestrator context.
