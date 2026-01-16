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

## Handoff Protocols

### Orchestrator → Builder Handoff

**What Orchestrator provides:**
```
## Implementation Request

**Plan Reference:** [link or inline plan]
**Goal:** [single sentence]

### Scope
- Files to modify: [list]
- Estimated changes: [X lines, Y files]
- Constraints: [any limits]

### Applicable Decisions
- [decision file]: [specific constraint]
- [decision file]: [specific constraint]

### Implementation Steps
1. [Step 1]
2. [Step 2]
3. [Step 3]

### Verification
- Run: [commands]
- Check: [conditions]

### Notes
- [Any clarifications or warnings]
```

**What Builder returns:**
```
## Implementation Complete

**Status:** Complete / Blocked (reason)

### Changes Made
- [file]: [what changed]

### Lines Changed
- Added: X
- Modified: Y
- Deleted: Z

### Local Checks
| Check | Status |
|-------|--------|
| Format | PASS |
| Lint | PASS |
| Build | PASS |

### Notes
- [Any discoveries or follow-up recommendations]

**Ready for QA:** YES / NO
```

---

### Builder → QA/Verifier Handoff

**What QA receives:**
- Implementation completion signal
- List of files changed
- Local check results
- Any notes from Builder

**What QA returns:**
```
## Verification Report

**Status:** APPROVED / BLOCKED

### Commit Gates
| Gate | Status | Evidence |
|------|--------|----------|
| A1: Decision Compliance | PASS | Checked 0001, 0002 |
| A2: Process | PASS | Plan exists, scope small |
| A3: Quality | PASS | `npm run lint` - no errors |
| A4: Safety | PASS | No secrets found |

### Push Gates (if pushing)
| Gate | Status | Evidence |
|------|--------|----------|
| B1: Sign-offs | PASS | Reviewer + Security approved |
| B2: Tests | PASS | 42 tests passed |
| B3: Audit | N/A | No dependency changes |

**Verdict:** [COMMIT ALLOWED / BLOCKED - reason]
```

---

### QA → Reviewer Handoff (When Required)

**Triggers:**
- High-risk domain (auth, payments, data, security)
- Structural change
- Push gate B1 requires sign-off

**What Reviewer receives:**
- Code diff
- Risk level assessment
- Context from Orchestrator's plan

**What Reviewer returns:**
```
## Code Review

**Verdict:** APPROVE / APPROVE WITH NOTES / REQUEST CHANGES / BLOCK

### Blocking Issues
[list or "None"]

### Suggestions
[list or "None"]

**Sign-off:** GRANTED / WITHHELD
```

---

### QA → Security Handoff (When Required)

**Triggers:**
- Auth/security boundaries touched
- PII/sensitive data involved
- Dependencies changed
- Push gate B1 requires sign-off

**What Security receives:**
- Code diff
- Risk level assessment
- Dependency change list (if applicable)

**What Security returns:**
```
## Security Review

**Severity:** CRITICAL / HIGH / MEDIUM / LOW / NONE
**Verdict:** APPROVE / REQUEST CHANGES / BLOCK

### Secrets Scan
PASS / FAIL

### Vulnerabilities
[list with CWE/OWASP reference or "None"]

### Dependency Audit
PASS / FAIL / N/A

**Sign-off:** GRANTED / WITHHELD
```

---

### Orchestrator → Accessibility Handoff (When Applicable)

**Triggers:**
- UI components created or modified
- Forms or interactive elements added
- Public-facing changes

**What Accessibility receives:**
- UI code for review
- Context on component purpose

**What Accessibility returns:**
```
## Accessibility Review

**Verdict:** PASS / PASS WITH NOTES / RECOMMEND CHANGES / ESCALATE

### Issues
[list with WCAG reference and severity]

### Recommendations
[prioritized fixes]
```

---

## Escalation Flow

```
Builder                 Orchestrator                  Operator
   │                         │                           │
   │  "Plan gap found"       │                           │
   ├────────────────────────►│                           │
   │                         │                           │
   │                         │  "Clarification needed"   │
   │                         ├──────────────────────────►│
   │                         │                           │
   │                         │  "Here's the answer"      │
   │                         │◄──────────────────────────┤
   │                         │                           │
   │  "Revised plan"         │                           │
   │◄────────────────────────┤                           │
   │                         │                           │


QA                      Orchestrator                  Operator
   │                         │                           │
   │  "Gate failed"          │                           │
   ├────────────────────────►│                           │
   │                         │                           │
   │                         │  Plan revision            │
   │                         │  (may need approval)      │
   │                         ├──────────────────────────►│
   │                         │                           │
   │                         │◄──────────────────────────┤
   │                         │                           │
   │  Revised code from      │                           │
   │  Builder, re-verify     │                           │
   │◄────────────────────────┤                           │


Security                Orchestrator                  Operator
   │                         │                           │
   │  "Risk acceptance       │                           │
   │   needed"               │                           │
   ├────────────────────────►│                           │
   │                         │                           │
   │                         │  "Accept risk?"           │
   │                         ├──────────────────────────►│
   │                         │                           │
   │                         │  "Accepted" / "Fix it"    │
   │                         │◄──────────────────────────┤
   │                         │                           │
   │  Decision recorded      │                           │
   │◄────────────────────────┤                           │
```

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

---

## Quick Reference: Who Does What

| Action | Who | Blocks? |
|--------|-----|---------|
| Receive task | Orchestrator | - |
| Read Repo OS docs | Orchestrator, all agents | - |
| Create plan | Orchestrator | - |
| Approve plan | Operator | - |
| Implement code | Builder | - |
| Run local checks | Builder | - |
| Verify gates | QA | **YES** |
| Block commit | QA | **YES** |
| Review code quality | Reviewer | **YES** (when required) |
| Review security | Security | **YES** (when required) |
| Review accessibility | Accessibility | No (advisory) |
| Approve commit | QA | **YES** |
| Update session log | Orchestrator | - |
| Accept risk | Operator | - |
