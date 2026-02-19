# Agent Workflow & Handoffs

## Advisory Flow (Spec Review)

Runs after Prompt 0, before build begins. Orchestrated by Prompt A Phase 1.

```
                        OPERATOR
              (completes spec via Prompt 0)
                            │
                            ▼
                      ORCHESTRATOR
           scans spec → activates specialists → synthesizes
                            │
                ┌───────────┼───────────┐
                ▼           ▼           ▼
          ALWAYS-ON    CONDITIONAL   ALWAYS-ON
       ┌────────────┐  (if triggered)  │
       │ Researcher  │  Security Analyst│
       │ Architect   │  UX Strategist  Innovator
       │ Critic      │  Perf Engineer  │
       └────────────┘  Data Strategist │
                │           │           │
                └───────────┼───────────┘
                            ▼
                   REFINEMENT REPORT
                            │
                            ▼
                     OPERATOR REVIEW
              (accept / reject / defer per item)
```

See `.claude/agents/_advisory-board.md` for activation logic, brief format, and report structure.

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
                    QA / VERIFIER ⚠️ COMMIT BLOCKER
               verifies all gates → BLOCK or APPROVE
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
3. **Builder → QA**: Completion signal, changes made, local check results
4. **QA → Reviewer** (when required): Code diff with risk assessment
5. **QA → Security** (when required): Code diff with risk assessment
6. **Orchestrator → Accessibility** (when applicable): UI code with context

## Subagent Reference

### Advisory Board (Spec Review Phase)

| Agent | Invoke When | Blocks Commit? |
|-------|------------|----------------|
| **Researcher** | Always (spec review) | No (advisory) |
| **Architect** | Always (spec review) | No (advisory) |
| **Critic** | Always (spec review) | No (advisory) |
| **Security Analyst** | Auth, PII, APIs, payments in spec | No (advisory) |
| **UX Strategist** | UI, design-system, user-flows in spec | No (advisory) |
| **Performance Engineer** | Real-time, large-data, media in spec | No (advisory) |
| **Data Strategist** | Database, data-contracts, migrations in spec | No (advisory) |
| **Innovator** | Always, lower priority (spec review) | No (advisory) |

### Build Team (Implementation Phase)

| Agent | Invoke When | Blocks Commit? |
|-------|------------|----------------|
| **Builder** | Plan approved, ready to implement | No |
| **QA/Verifier** | Builder signals done, before any commit | **Yes** — always |
| **Reviewer** | Structural, high-risk, or cross-cutting changes | **Yes** — when required |
| **Security** | Auth, PII, deps changed, crypto, external integrations | **Yes** — when required |
| **Accessibility** | Public-facing UI modified, forms, interactive widgets | No (advisory) |

Subagents load their own definitions from `.claude/agents/`. Do not read subagent files into orchestrator context.
