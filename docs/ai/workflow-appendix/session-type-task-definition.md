# Session Type: Task Definition

Prompt T facilitates exploration and task planning without producing file artifacts. Two modes:
- **Query**: Conversational Q&A grounded in specs and codebase. No agent dispatch.
- **Brief**: 3-agent team (Architect, Exploration, Critic) produces a structured task brief for Prompt B.

Task definition sessions are fully ephemeral — no files written, no session log entries, no gates apply. The output is a terminal-displayed task brief the operator copy-pastes into a new Prompt B session. See `docs/ai/prompts/prompt-t-task-definition.md` for full details.
