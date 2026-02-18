# Agent Workflow & Handoffs

## Execution Flow

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

1. **Operator → Orchestrator**: Task request
2. **Orchestrator → Builder**: Approved plan, instructions, decisions, scope
3. **Builder → QA**: Completion signal, changes made, local check results
4. **QA → Reviewer** (when required): Code diff with risk assessment
5. **QA → Security** (when required): Code diff with risk assessment
6. **Orchestrator → Accessibility** (when applicable): UI code with context

## Subagent Reference

| Agent | Invoke When | Blocks Commit? |
|-------|------------|----------------|
| **Builder** | Plan approved, ready to implement | No |
| **QA/Verifier** | Builder signals done, before any commit | **Yes** — always |
| **Reviewer** | Structural, high-risk, or cross-cutting changes | **Yes** — when required |
| **Security** | Auth, PII, deps changed, crypto, external integrations | **Yes** — when required |
| **Accessibility** | Public-facing UI modified, forms, interactive widgets | No (advisory) |

Subagents load their own definitions from `.claude/agents/`. Do not read subagent files into orchestrator context.
