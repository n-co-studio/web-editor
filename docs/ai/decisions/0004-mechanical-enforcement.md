# Decision 0004 — Mechanical Enforcement Layer

## Status
Accepted

## Context
Repo OS governance (roles, gates, decisions, handoffs) was enforced entirely through documentation — agents read instructions and chose to comply. Claude Code now supports executable subagents with tool restrictions, lifecycle hooks, and team-shared settings, enabling mechanical enforcement that runs regardless of agent behavior.

## Decision
Add a mechanical enforcement layer using Claude Code's native features:

1. **Executable Subagents**: Builder, QA/Verifier, Reviewer, Security/Privacy, and Accessibility agents include YAML frontmatter with `name`, `description`, `tools`, and `disallowedTools` fields. This enforces tool boundaries at runtime (e.g., Builder cannot spawn subagents, QA cannot edit files, Reviewer is read-only).

2. **Orchestrator Exception**: The Orchestrator remains a behavioral reference document (no frontmatter). It defines the main session's coordination behavior, not an invocable subagent. Shared reference files (`_agent-glossary.md`, `_agent-workflow.md`) also remain non-executable.

3. **Team-Shared Settings**: `.claude/settings.json` (committed to git) defines permissions and lifecycle hooks that apply to every session automatically. Personal overrides go in `.claude/settings.local.json` (gitignored).

4. **Verification Hooks**: Scripts in `.claude/hooks/` provide deterministic gate checks:
   - `PreToolUse` hook on `git commit` runs safety gate verification (secret scanning, scope check)
   - `Stop` hook checks session log update status (advisory)
   - Projects add project-specific checks (lint, test, build) to these scripts

5. **Source of Truth**: `.claude/settings.json` and `.claude/hooks/` are added to AI.md's source-of-truth list.

This extends Decision 0003 (agent structure) — frontmatter is now a required part of the agent definition structure for invocable agents.

## Consequences
- Agent tool boundaries are enforced by Claude Code runtime, not by instruction compliance
- Gate checks run automatically before commits via hooks
- Every project created from this template inherits the enforcement layer
- Projects must customize hook scripts for their specific tooling (lint, test, build commands)
- Orchestrator and shared files are explicitly excluded from frontmatter requirements
