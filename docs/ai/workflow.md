cat > docs/ai/workflow.md <<'EOF'
# Workflow (Repo OS)

This document defines how work is executed in this repository with Claude Code.

---

## 1) Agent Roles (Default)

- **Orchestrator**
  - Owns planning, sequencing, and final “done” declaration
  - Coordinates specialist agents
  - Ensures decisions + gates are applied

- **Builder**
  - Implements scoped changes according to the plan
  - Avoids large, unverified edits

- **QA / Verifier**
  - Runs required checks and reports results
  - Confirms gates are satisfied before commits/pushes

- **Reviewer**
  - Reviews code quality, architecture, maintainability
  - Required sign-off for high-risk or structural changes

- **Security / Privacy**
  - Checks for secrets, unsafe patterns, auth/data risks
  - Required sign-off when changes affect security boundaries

- **Accessibility (if applicable)**
  - Ensures basic a11y correctness for UI changes

---

## 2) Decision Handling (Mandatory)

Process:
1. Identify which decisions apply (docs/ai/decisions/)
2. Constrain the plan to comply with them
3. If a decision conflicts with the work, stop and propose a new decision record
4. **Decision violations block commits**

---

## 3) Standard Execution Loop (All work)

1. **Plan**
   - Define goal, scope, files to touch, and verification steps
2. **Build**
   - Implement small, reviewable increments
3. **Verify**
   - Run checks required by gates
4. **Commit**
   - Only after gates pass (including decision compliance)

---

## 4) HVST Protocol (Required for debugging/instability)

Use HVST when:
- fixing bugs
- diagnosing failing tests
- resolving unstable behavior

Loop until resolved:
- **Hypothesis**: what you believe is happening
- **Validate**: smallest experiment to confirm/refute
- **Solve**: minimal fix
- **Test**: rerun checks

HVST is not required for simple, low-risk feature work unless instability appears.

---

## 5) Session Lifecycle

- A “session” is a bounded unit of work with a clear goal.
- At session close:
  - all changes are verified
  - commits are made (and pushes as appropriate)
  - the session log is updated

EOF