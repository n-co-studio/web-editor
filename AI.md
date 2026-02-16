# Repo OS

## Non-negotiables
- The operator creates and manages GitHub repositories (org/visibility/credentials). Agents must not do this.
- No code changes without a plan.
- Work happens in small, verifiable increments.
- **Gates must pass before commits (and before any push).**
- **Accepted decisions are mandatory. Decision violations block commits.**
- Session log is updated at session close.

## Authority
Operator-only:
- Create GitHub repo, manage org/user/visibility/credentials
- Decide when/where to push

Agent-allowed:
- Read/write files, run local commands
- Git operations (status/add/commit) once gates pass
- Push only when gates pass

## Source of Truth
- docs/spec/
- docs/ai/workflow.md
- docs/ai/quality-gates.md
- docs/ai/decisions/
- docs/ai/logs/session-log.md
- .claude/agents/
- .claude/settings.json
- .claude/hooks/

## Prompts
- docs/ai/prompts/prompt-0-spec-builder.md
- docs/ai/prompts/prompt-a-repo-os.md
- docs/ai/prompts/prompt-b-product-build.md
