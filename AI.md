# Repo OS (Claude Code)

This repository uses a Repo Operating System (Repo OS) to govern how Claude Code and the operator work together.

## Non-negotiables
- The operator creates and manages GitHub repositories (org/visibility/credentials). Agents must not do this.
- No code changes without a plan.
- Work happens in small, verifiable increments.
- **Gates must pass before commits (and before any push).**
- **Accepted decisions are mandatory. Decision violations block commits.**
- Session log is updated at session close.

## Authority
Operator-only:
- Create GitHub repo
- Manage org/user, visibility, credentials
- Decide when/where to push (staging/production decisions)

Agent-allowed (inside this repo):
- Read/write files
- Run local commands
- Run git commands (status/add/commit) once gates pass
- Push only when gates pass and Repo OS allows it

## Repo OS docs (source of truth)
- docs/ai/workflow.md
- docs/ai/quality-gates.md
- docs/ai/decisions/
- docs/ai/logs/session-log.md

## Agent Definitions (source of truth)
- .claude/agents/_agent-glossary.md — shared terminology
- .claude/agents/_agent-workflow.md — agent interaction patterns
- .claude/agents/*.md — role definitions (orchestrator, builder, qa-verifier, reviewer, security-privacy, accessibility)

## Enforcement (source of truth)
- .claude/settings.json — team-shared permissions and lifecycle hooks
- .claude/hooks/ — verification scripts for automated gate checks

## Prompts
- Prompt A: Repo OS / agents / workflow initialization (no product code)
- Prompt B: Product build operating prompt (ecosystem rules only; project description changes per project)
