# Agent Workflow & Handoffs

Visual reference for how agents coordinate during the standard execution loop.

---

## Standard Execution Flow

```
                    ┌─────────────────────────────────────────────────────────────────┐
                    │                         OPERATOR                                │
                    │              (Owns architecture, approves plans)                │
                    └─────────────────────────────────────────────────────────────────┘
                                                  │
                                                  │ Task Request
                                                  ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                    ORCHESTRATOR                                         │
│                                                                                         │
│  1. Read Repo OS docs (AI.md, workflow.md, gates, decisions)                           │
│  2. Identify applicable decisions                                                       │
│  3. Ask operator for clarification if needed                                           │
│  4. Create plan                                                                         │
│  5. Get operator approval                                                               │
└─────────────────────────────────────────────────────────────────────────────────────────┘
                                                  │
                                                  │ Approved Plan
                                                  ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                      BUILDER                                            │
│                                                                                         │
│  1. Read plan and applicable decisions                                                 │
│  2. Implement exactly as specified                                                     │
│  3. Run local checks (format, lint, build)                                             │
│  4. Signal completion                                                                   │
└─────────────────────────────────────────────────────────────────────────────────────────┘
                                                  │
                                                  │ Implementation Complete
                                                  ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                   QA / VERIFIER                                         │
│                               ⚠️ COMMIT BLOCKER                                         │
│                                                                                         │
│  1. Verify decision compliance (A1)                                                    │
│  2. Verify process gates (A2)                                                          │
│  3. Run quality gates (A3)                                                             │
│  4. Verify safety gates (A4)                                                           │
│  5. Report evidence                                                                     │
│  6. BLOCK or APPROVE                                                                   │
└─────────────────────────────────────────────────────────────────────────────────────────┘
                                                  │
                                    ┌─────────────┴─────────────┐
                                    │                           │
                           Gates PASS                   Gates FAIL
                                    │                           │
                                    ▼                           ▼
                    ┌───────────────────────────┐    ┌─────────────────────┐
                    │  High-risk change?        │    │  Return to Builder  │
                    │  (auth, payments, etc.)   │    │  (fix issues)       │
                    └───────────────────────────┘    └─────────────────────┘
                                    │
                      ┌─────────────┴─────────────┐
                      │                           │
                     YES                          NO
                      │                           │
                      ▼                           │
        ┌─────────────────────────────────┐       │
        │                                 │       │
        │  ┌──────────────┐               │       │
        │  │   REVIEWER   │ ◄─────────────┼───────┤ (Optional for
        │  │              │               │       │  non-high-risk)
        │  │ Code quality │               │       │
        │  │ Architecture │               │       │
        │  └──────────────┘               │       │
        │         │                       │       │
        │         ▼                       │       │
        │  ┌──────────────┐               │       │
        │  │  SECURITY /  │               │       │
        │  │   PRIVACY    │               │       │
        │  │              │               │       │
        │  │ OWASP, CVEs  │               │       │
        │  │ Secrets scan │               │       │
        │  └──────────────┘               │       │
        │         │                       │       │
        │  Both sign off?                 │       │
        │         │                       │       │
        └─────────┴───────────────────────┘       │
                  │                               │
                  ▼                               ▼
        ┌─────────────────────────────────────────────────────────┐
        │                                                         │
        │                    ✓ COMMIT ALLOWED                    │
        │                                                         │
        │                (QA runs push gates before push)         │
        └─────────────────────────────────────────────────────────┘
                                    │
                                    ▼
        ┌─────────────────────────────────────────────────────────┐
        │                                                         │
        │                   SESSION COMPLETE                      │
        │                                                         │
        │  • Session log updated                                  │
        │  • Decisions applied documented                         │
        │  • Verification evidence recorded                       │
        │  • Follow-ups noted                                     │
        │                                                         │
        └─────────────────────────────────────────────────────────┘
```

---

## Handoff Chain

Each agent's definition file contains its specific handoff format (what it sends and receives). The standard handoff chain is:

1. **Operator → Orchestrator**: Task request
2. **Orchestrator → Builder**: Approved plan with instructions, applicable decisions, scope boundaries
3. **Builder → QA/Verifier**: Completion signal with changes made, local check results
4. **QA → Reviewer** (when required): Code diff with risk assessment for sign-off
5. **QA → Security** (when required): Code diff with risk assessment for sign-off
6. **Orchestrator → Accessibility** (when applicable): UI code with component context

See individual agent files in `.claude/agents/` for detailed handoff format templates.

---

## Escalation Paths

- **Builder → Orchestrator**: Plan gaps, scope expansion needed, ambiguity, bugs outside scope
- **QA → Orchestrator**: Gate failures requiring plan revision, ambiguous gate requirements
- **Orchestrator → Operator**: Clarification needed, architectural decisions, scope changes, risk acceptance
- **Security → Orchestrator → Operator**: Risk acceptance decisions, security/functionality conflicts
- **Reviewer → Orchestrator**: Fundamental approach disagreements, decision violations requiring resolution

If operator is unresponsive (>2 prompts without response): pause session, document blocking question in session log, do not proceed with assumptions.

---

## Agent Interaction Matrix

| From \ To | Orchestrator | Builder | QA | Reviewer | Security | Accessibility | Operator |
|-----------|-------------|---------|-----|----------|----------|---------------|----------|
| **Orchestrator** | - | Plan, instructions | Verify request | Review request | Security request | A11y request | Questions, reports |
| **Builder** | Completion, escalations | - | (via Orchestrator) | - | - | - | - |
| **QA** | Results, gate failures | (via Orchestrator) | - | Sign-off request | Sign-off request | - | - |
| **Reviewer** | Verdict, escalations | (via Orchestrator) | Sign-off | - | - | - | - |
| **Security** | Verdict, risk decisions | (via Orchestrator) | Sign-off | - | - | - | - |
| **Accessibility** | Findings, escalations | (via Orchestrator) | - | - | - | - | - |
| **Operator** | Tasks, approvals, decisions | - | - | - | - | - | - |
