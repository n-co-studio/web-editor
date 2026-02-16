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
3. **Run Prompt 0** — Build your project spec (guided interview, no code)
4. **Run Prompt A** — Initialize Repo OS (one-time setup)
5. **Run Prompt B** — Begin development work

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
- Run Prompt 0 first (build project spec)
- Then run Prompt A once (initialize Repo OS)

Why:
- Prompt 0 defines every detail of what you're building before any code exists
- Prompt A then verifies Repo OS, defines conditional gates, aligns agents

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

### Step 3 — Build your project spec (Prompt 0)

Start a Claude Code session and paste:

> Follow docs/ai/prompts/prompt-0-spec-builder.md. Read all files in docs/spec/ before proceeding.

The AI interviews you to fill out every spec file — product, architecture, design system, data models, features, integrations, and boundaries. No code is written. You define everything.

**Design system:** Defaults are baked into `docs/spec/design-system.md` (spacing, typography, breakpoints, colors, radii, shadows, layout patterns). You can accept them as-is, override with your brand values, or replace them via Figma MCP.

When the AI confirms "Spec complete", move to Step 4.

---

### Step 4 — Initialize Repo OS (Prompt A)

Paste:

> Follow docs/ai/prompts/prompt-a-repo-os.md.
> Read AI.md, docs/ai/quality-gates.md, docs/ai/decisions/, and .claude/agents/ before proceeding.

Complete Prompt A once.

---

### Step 5 — Begin development (Prompt B)

For every development session, paste:

> Follow docs/ai/prompts/prompt-b-product-build.md.
> Read AI.md, docs/ai/quality-gates.md, docs/ai/decisions/, .claude/agents/, and docs/spec/ before proceeding.

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

## 6.5) Mechanical Enforcement

Some gates are enforced automatically by hooks — scripts that run regardless of agent behavior.

**What's automatic:**
- Secret scanning runs before every commit (blocks if secrets found)
- Session log reminder runs when Claude stops responding
- Agent tool boundaries are enforced by frontmatter (e.g., Builder cannot spawn subagents, QA cannot edit files)

**What you customize per project:**
- Add lint, test, and build checks to `.claude/hooks/pre-commit-gates.sh`
- Adjust permissions in `.claude/settings.json` (team-shared) or `.claude/settings.local.json` (personal)

**Key files:**
- `.claude/settings.json` — team-shared hooks and permissions (committed to git)
- `.claude/settings.local.json` — personal overrides (gitignored)
- `.claude/hooks/` — verification scripts

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
