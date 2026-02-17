# Decision 0004 — Mechanical Enforcement Layer

## Status
Accepted

## Decision
Enforce Repo OS mechanically using Claude Code native features:
1. **Subagent frontmatter**: Invocable agents (Builder, QA, Reviewer, Security, A11y) declare `tools`/`disallowedTools` in YAML frontmatter → runtime-enforced tool boundaries
2. **Orchestrator exception**: Orchestrator + shared files (`_agent-glossary.md`, `_agent-workflow.md`) have no frontmatter — behavioral references only
3. **Team settings**: `.claude/settings.json` (committed) defines permissions + hooks. Personal overrides in `.claude/settings.local.json` (gitignored)
4. **Hooks** (`.claude/hooks/`): `PreToolUse` on commit → safety gates; `PostToolUse`/`PostToolUseFailure` on Bash → HVST failure tracking; `Stop` → session log + known-issues check. Projects add lint/test/build checks
5. Extends Decision 0003 — frontmatter is required for invocable agents
