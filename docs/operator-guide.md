# Operator Guide — Repo OS

This guide is for the **human operator**.
It explains how to start projects, run sessions, and interact with the Repo OS safely and effectively.

Agents do NOT treat this file as instruction.
This is a reference for you.

---

## Quick Start — New Repo Setup

1. **Create repo from template**
   - Go to template repo on GitHub
   - Click "Use this template" → "Create a new repository"
   - Set repo name, owner, and visibility
   - Click "Create repository"
2. **Clone locally** — `git clone <REPO_URL> && cd <REPO_NAME>`
3. **Run Prompt A** — Initialize Repo OS (one-time setup)
4. **Run Prompt B** — Begin development work

See Section 3 for detailed steps.

---

## 1) Mental Model (Read Once)

- You (the operator) own intent, architecture, and final authority
- AI agents execute within constraints
- The Repo OS enforces:
  - decisions (mandatory)
  - gates (commit-blocking)
  - roles (who does what)

If something feels unclear or risky:
pause and clarify before proceeding.

---

## 2) Triggers — What to Run and When

### Trigger: New project (fresh repo from template)
Action:
- Run Prompt A once

Why:
- Verify Repo OS
- Define any project-specific conditional gates
- Confirm agents and workflow are aligned

---

### Trigger: Repo OS change (agents, gates, decisions)
Action:
- Run Prompt A
- Create a new decision record if behavior changes

---

### Trigger: Normal feature work or bug fixes
Action:
- Run Prompt B

---

### Trigger: Confusion, drift, or unexpected agent behavior
Action:
- Stop
- Re-run Prompt A or explicitly reference docs/ai/workflow.md

---

## 2.5) Agent Definitions

The `.claude/agents/` directory contains comprehensive agent definitions:

**Shared files** (read by all agents):
- `_agent-glossary.md` — defines terms like "small scope", "high-risk", "gate"
- `_agent-workflow.md` — shows how agents coordinate and hand off work

**Agent roles**:

| Agent | Purpose | Blocks Commits? |
|-------|---------|-----------------|
| Orchestrator | Plans, coordinates, ensures human-led architecture | No |
| Builder | Implements scoped changes per plan | No |
| QA/Verifier | Verifies all gates before commits | **Yes** |
| Reviewer | Reviews code quality (high-risk/structural) | **Yes** (when required) |
| Security | Checks for secrets, auth risks, vulnerabilities | **Yes** (when required) |
| Accessibility | Reviews UI for WCAG compliance | No (advisory) |

Each agent definition includes: authority boundaries, required reading, invocation criteria, responsibilities, constraints, escalation paths, and examples.

---

## 3) Starting a New Project (Step-by-Step)

### Step 1 — Create repo from template (Operator-only)
- Use GitHub "Use this template"
- Choose repo name, visibility, org

---

### Step 2 — Clone locally
```bash
git clone <REPO_URL>
cd <REPO_NAME>
```

---

### Step 3 — Start Claude Code session

Starter line to paste:

> Follow docs/ai/prompts/prompt-a-repo-os.md.
> Read AI.md, docs/ai/quality-gates.md, docs/ai/decisions/, and .claude/agents/ before proceeding.

Complete Prompt A once.

---

### Step 4 — Begin development

For normal work, paste:

> Follow docs/ai/prompts/prompt-b-product-build.md.
> Read AI.md, docs/ai/quality-gates.md, docs/ai/decisions/, and .claude/agents/ before proceeding.

---

## 4) Operator Responsibilities (Non-Delegable)

You must:
- Own architecture and solution direction
- Approve plans for non-trivial work
- Decide when risk is acceptable
- Decide when something is "done"
- Create repos and manage GitHub settings

Agents must never do these things.

---

## 5) Decision Discipline

- Decisions are mandatory
- Decision violations block commits
- If a decision no longer fits:
  - create a new decision
  - do not silently ignore old ones

Decisions are laws, not notes.

---

## 6) Gates — How to Think About Them

Gates are not bureaucracy.
They exist to:
- prevent silent failure
- prevent AI overreach
- prevent rushed decisions

If a gate cannot be met yet:
- document it in the session log
- create a follow-up task

---

## 7) Session Hygiene

At the end of a session:
- commits are clean
- gates are satisfied
- session log is updated
- next steps are clear

If those aren't true, the session isn't done.

---

## 8) Rule Overrides

Rules may be overridden only when:
- you explicitly decide to
- and you document why

Conscious override beats silent drift.
