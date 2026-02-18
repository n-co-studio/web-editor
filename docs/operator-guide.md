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

### Trigger: Template sync (automatic)
Sync PRs are created and auto-merged weekly. No operator action needed unless spec templates changed.

Action (only if `docs/spec/_templates/` was updated):
- Re-run Prompt 0 (enters update mode, creates new version)

Why:
- Governance updates (agents, gates, prompts) land automatically
- Your compiled specs, logs, and decisions are never overwritten (protected by `.templatesyncignore`)
- See Section 9.5 for full setup and details

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
| Security / Privacy | Checks for secrets, auth risks, vulnerabilities | **Yes** (when required) |
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

> Follow docs/ai/prompts/prompt-0-spec-builder.md. Read docs/spec/compiled/manifest.json and all files in docs/spec/_templates/ before proceeding.

The AI interviews you to fill out every spec file — product, architecture, design system, data models, features, integrations, and boundaries. No code is written. You define everything. Output goes to a versioned directory under `docs/spec/compiled/`.

**Design system:** Defaults are baked into `docs/spec/_templates/design-system.md` (spacing, typography, breakpoints, colors, radii, shadows, layout patterns). You can accept them as-is, override with your brand values, or replace them via Figma MCP.

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
> Read AI.md and all files it references before proceeding.

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
- HVST failure tracking on every Bash command (reminds agent to check `known-issues.md` after 2+ consecutive failures)
- Session log + known-issues reminder runs when Claude stops responding
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

## 8) Branch Categories

Work happens on categorized branches. Category determines gate strictness.

| Branch | Purpose | Gates |
|--------|---------|-------|
| `main` | Production-ready | All gates. Protected — merge via PR only. |
| `release/*` | Release candidates | All gates + release checklist. Reviewer + Security on every merge. |
| `feature/*` | New functionality | Standard gates (A + B). |
| `fix/*` | Bug fixes | Standard gates (A + B). |
| `hotfix/*` | Urgent production fixes | Expedited: A2 scope relaxed. A1, A3, A4 enforced. |
| `experiment/*` | Spikes, prototypes | A4 (safety) only. Never merge to main — rewrite into `feature/*`. |

Naming: `<category>/<short-description>`. Unrecognized branches default to `feature/*` rules.

---

## 9) Scaling: Multi-Agent Teams

You can run parallel agent teams — one Claude Code session per branch, each following the same Repo OS governance independently.

**Operator responsibilities for parallel teams:**
- Define clear file/module ownership per branch (avoid overlap)
- Use per-branch session logs: `docs/ai/logs/session-log-<branch-name>.md`
- Coordinate shared model/schema changes sequentially (one branch first, merge, rebase others)
- Review cross-branch integration at PR time — agents only see their own branch

**What Repo OS handles:** Gates, secret scanning, agent boundaries, and decision compliance all run independently per session.

**What it does not handle:** Cross-branch signaling, automatic conflict detection, and merge-time gate escalation. These are operator responsibilities.

See the HTML explainer (`repo-os-explainer.html` → Scaling) for the full setup checklist.

---

## 9.5) Template Sync — Keeping Governance Up to Date

If your repo was created from a template, you can sync governance updates (workflow rules, agent definitions, gates, prompts) without losing your project-specific specs or decisions.

**Sync is one-way: template → your repo.** The template repo is the upstream authority for governance. Your project repo receives updates from it but never pushes changes back. If you need to improve the template itself, do that directly in the template repo — not from a project instance.

### How It Works

- `.github/workflows/template-sync.yml` runs weekly (Monday 04:00 UTC) or on manual trigger
- It compares your repo against the template, creates a PR, and auto-merges it
- `.templatesyncignore` protects your compiled specs, logs, and decisions from being overwritten
- Every sync is recorded as a merged PR in your repo's GitHub history for audit

By default, syncs are fully automatic — no operator action needed. The workflow creates a PR (for audit trail) and immediately merges it. Your compiled specs, logs, and decisions are never touched thanks to `.templatesyncignore`.

### GitHub Prerequisites

The sync workflow uses GitHub Actions (CI/CD automation built into GitHub). Before setup:

1. **GitHub Actions must be enabled** on your project repo. It's on by default for all repos — you only need to check this if your org has explicitly disabled it. Go to repo **Settings → Actions → General** and confirm actions are allowed.
2. **Workflow permissions** must allow read/write. Go to repo **Settings → Actions → General → Workflow permissions** and select **Read and write permissions**. The workflow declares its own permissions (`contents: write`, `pull-requests: write`), but the repo-level setting must allow it.
3. **Branch protection (if used)**: If `main` has branch protection rules requiring PR reviews or status checks, the auto-merge step will not be able to bypass them. Either:
   - Allow the "github-actions" bot to bypass protection rules (Settings → Branches → Edit rule → "Allow specified actors to bypass"), or
   - Use manual merge mode instead (see "Want to review before merge?" below)

### Setup (One-Time)

1. Open `.github/workflows/template-sync.yml`
2. Replace `OWNER/repo-OS-template` with the actual path to your template repo (e.g., `your-org/repo-OS-template`)
3. If the template repo is private, create a Personal Access Token with repo read access and add it as a repository secret named `TEMPLATE_SYNC_TOKEN`, then replace `${{ secrets.GITHUB_TOKEN }}` with `${{ secrets.TEMPLATE_SYNC_TOKEN }}`

**Note:** The template repo itself should NOT have this workflow. Only project repos created from the template need it. The template is the source — it doesn't sync from itself.

### Want to review before merge?

If you prefer to manually review sync PRs before they merge, remove the `Auto-merge sync PR` step from `.github/workflows/template-sync.yml`. Sync PRs will then stay open until you merge them:
- Go to your project repo on GitHub → **Pull requests** tab
- Sync PRs have the title `chore: sync with upstream template` and the label `template-sync`
- Review the diff, then click **Merge** when satisfied

### After a Template Sync

Syncs happen automatically. The only time you need to take action is if spec templates changed:
- Check the merged PR diff — if `docs/spec/_templates/` has new fields or files, re-run Prompt 0
  - It will detect the existing compiled version and enter **update mode**
  - It copies your latest version, shows new/changed fields, and asks what to fill in
  - Output goes to a new version (e.g., `v2`) — your previous version is preserved
- If only governance files changed (agents, gates, prompts), no action needed — they're already live

### Merge Conflicts

If your project has locally modified a governance file that the template also updated (e.g., you customized `.claude/hooks/pre-commit-gates.sh` and the template also changed it), the auto-merge will fail. The sync PR stays open and you resolve the conflict manually — same as any git merge conflict.

To avoid this for files you always want to customize, add them to `.templatesyncignore`. That way the template sync skips them entirely.

### What Syncs vs What Stays

| Syncs from template | Protected (never overwritten) |
|---|---|
| `AI.md` | `docs/spec/compiled/` |
| `docs/ai/prompts/` | `docs/ai/logs/` |
| `docs/ai/workflow.md` | `docs/ai/decisions/` |
| `docs/ai/quality-gates.md` | `.claude/settings.local.json` |
| `.claude/agents/` | |
| `.claude/hooks/` | |
| `docs/spec/_templates/` | |

---

## 9.7) Companion Tools

Repo OS is a governance framework. Companion tools extend the development workflow without modifying the core system.

### Visual Bridge (Optional)

A Chrome extension + MCP server for visually editing live front-end UI and feeding precise change requests back to Claude Code.

**What it does:**
- Operator selects and adjusts elements in the browser (spacing, typography, colors, sizing)
- Edits snap to the project's design system tokens
- Structured diffs with exact source file and line number are sent to Claude Code
- Claude Code applies the precise edit — no fuzzy matching, no guessing

**Setup (per project):**

1. Install the dev plugin in your project:
   ```bash
   npm install -D @visual-bridge/dev-plugin
   ```

2. Add it to your build config:
   ```ts
   // vite.config.ts
   import { visualBridge } from '@visual-bridge/dev-plugin'
   export default defineConfig({
     plugins: [visualBridge()]
   })
   ```

3. Add the MCP server to `.claude/settings.json`:
   ```json
   {
     "mcpServers": {
       "visual-bridge": {
         "command": "npx",
         "args": ["@visual-bridge/mcp-server"]
       }
     }
   }
   ```

4. Install the Chrome extension from the Chrome Web Store

**Design token discovery:** The MCP server auto-reads tokens from your project's Tailwind config, tokens.json, or `docs/spec/compiled/{active}/design-system.md`. No additional configuration needed.

**Not required:** Visual Bridge is entirely optional. Projects that don't install it are completely unaffected. No Repo OS files depend on it.

---

## 10) Rule Overrides

Rules may be overridden only when:
- you explicitly decide to
- and you document why

Conscious override beats silent drift.
