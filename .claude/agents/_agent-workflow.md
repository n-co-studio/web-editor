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

See individual agent files for handoff format templates.
