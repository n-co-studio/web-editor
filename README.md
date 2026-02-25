# Repo OS

AI-native project governance for Claude Code. Enforces quality gates, decision compliance, and session-based workflows through mechanical hooks — not convention alone. Open [repo-os-explainer.html](repo-os-explainer.html) in a browser for the interactive visual overview.

## Quick Start

1. **Create a repo** from this template (GitHub "Use this template")
2. Verify `.claude/repo-mode` reads `child` (default for downstream projects)
3. Run **Prompt 0** — builds your project specification in `docs/spec/compiled/`
4. Run **Prompt A** (Initialize) — advisory board reviews your spec, sets up governance
5. Run **Prompt B** with a task brief — plan, build, verify, commit

Prompts live in `docs/ai/prompts/`. See [AI.md](AI.md) for the full authority model.

## Operating Modes

Set in `.claude/repo-mode`. Override per-session with `REPO_OS_MODE=<mode>`.

| Mode | File Access | Use Case |
|------|-------------|----------|
| `template` | Governance only (no product code) | Upstream template development |
| `child` | Product code + limited governance | Default for downstream projects |
| `autonomous` | Product code + minimal governance | Headless / CI operation |

See [Decision 0012](docs/ai/decisions/0012-file-edit-restrictions.md) for carve-out details.

## Prompt Chain

| Prompt | Name | Purpose |
|--------|------|---------|
| **0** | Spec Builder | Build complete project specification through structured conversation |
| **0.5** | Rapid Prototype | Lightweight experiments on `experiment/*` branches (Napkin / Spike / PoC) |
| **A** | Repo OS Init | Advisory board spec review + governance evidence setup |
| **B** | Product Build | Implementation loop: plan, build, verify, commit |
| **T** | Task Definition | Exploration and task planning (produces briefs for Prompt B) |
| **C** | Project Audit | Menu-driven audit across configurable dimensions |

## Hook Chain

All hooks live in `.claude/hooks/` and are wired via `.claude/settings.json`.

| Hook | Lifecycle | Role |
|------|-----------|------|
| `state-guard.sh` | PreToolUse (Edit/Write/Bash) | Blocks model writes to `.claude/.state/` |
| `mode-guard.sh` | PreToolUse (Edit/Write/Bash) | Enforces mode-based file restrictions |
| `branch-guard.sh` | PreToolUse (Edit/Write) | Blocks main edits, enforces plan gate, governance advisory |
| `plan-approval.sh` | PostToolUse (AskUserQuestion) | Captures plan approvals as state |
| `hvst-failure-tracker.sh` | PostToolUse (Bash) | Tracks consecutive failures for HVST escalation |
| `agent-git-guard.sh` | PreToolUse (git commit/push) | Blocks subagent commits and pushes |
| `pre-commit-gates.sh` | PreToolUse (git commit) | Enforces A1, A2, A4, A5, A6 gates |
| `pre-push-gates.sh` | PreToolUse (git push) | Enforces B1 branch naming convention |
| `state-writer.sh` | SubagentStop | Captures governance agent verdicts as state files |
| `session-close-check.sh` | Stop | Session log check, override audit, state cleanup |

## Quality Gates

Full definitions in [quality-gates.md](docs/ai/quality-gates.md).

**Commit (A)** — enforced by `pre-commit-gates.sh`:

| Gate | Checks |
|------|--------|
| A1 | Decision compliance (trigger parser matches staged files to decision triggers) |
| A2 | Process and scope (plan exists, under 100 lines or large-scope approved) |
| A3 | Quality (formatter, linter, build — if tooling exists) |
| A4 | Safety (no secrets, no PII, high-risk pattern detection) |
| A5 | Cohesion review (Critic verified diff for internal coherence) |
| A6 | Task group contract compliance (if applicable) |

**Push (B)** — enforced by `pre-push-gates.sh`:

| Gate | Checks |
|------|--------|
| B1 | Branch naming convention (`category/description`) |
| B2 | Tests and typecheck pass (if tooling exists) |
| B3 | No debug flags left enabled, dependency audit if deps changed |

**Release (C)** — checked during release merges:

| Gate | Checks |
|------|--------|
| C1 | Version bumped, changelog updated, release notes drafted |
| C2 | Full test suite passes, all A + B gates |
| C3 | Reviewer + Security sign-off |

## Branch Naming

Enforced by gate B1 at push time. Format: `category/short-description`.

| Category | Purpose | Gate Profile |
|----------|---------|-------------|
| `main` | Production-ready | All gates, merge via PR only |
| `release/*` | Release candidates | All gates + C1–C3 |
| `feature/*` | New functionality | Standard (A + B) |
| `fix/*` | Bug fixes | Standard (A + B) |
| `hotfix/*` | Urgent production fixes | Expedited (A2 relaxed, A5 skipped) |
| `experiment/*` | Spikes and prototypes | A4 only (safety) |

## Team Setup

### Discussions

Enable GitHub Discussions and create these categories: **Announcements** (team updates), **Decision Proposals** (RFCs for new decisions), **Q&A** (usage questions), **Ideas** (feature brainstorming), **Show & Tell** (demos and learnings).

### Labels

Import labels from [.github/labels.json](.github/labels.json):

```sh
cat .github/labels.json | jq -c '.[]' | while read label; do
  gh label create "$(echo $label | jq -r .name)" \
    --color "$(echo $label | jq -r .color)" \
    --description "$(echo $label | jq -r .description)" \
    --force
done
```

### Decision Numbering

- **0001–0099** — Template-synced decisions. Locked in child/autonomous modes.
- **0100+** — Project-specific decisions. Editable in child mode.

## For Template Contributors

- **Versioning:** CalVer git tags (`vYYYY.MM.MICRO`), auto-created on merge to `main` when Repo OS files change
- **Template sync:** Child repos sync from this template automatically. Protected paths listed in [`.templatesyncignore`](.templatesyncignore)
- **Template mode:** Governance paths only — use `REPO_OS_UNLOCK_PATH` for one-off product path access
- **Visual guide:** Open [`repo-os-explainer.html`](repo-os-explainer.html) in a browser for the interactive system diagram

## Links

- [AI.md](AI.md) — Canonical governance index and authority model
- [Workflow](docs/ai/workflow.md) — Session lifecycle, HVST protocol, git trailer convention
- [Quality Gates](docs/ai/quality-gates.md) — Gate definitions, branch profiles, state files
- [Decisions](docs/ai/decisions/) — Accepted governance decisions (0001–0099 template-synced)
- [Prompts](docs/ai/prompts/) — All session prompts (0, 0.5, A, B, T, C)
- [Agent Glossary](.claude/agents/_agent-glossary.md) — Scope definitions, risk levels, protocols
- [Visual Explainer](repo-os-explainer.html) — Interactive system overview
