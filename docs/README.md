cat > docs/README.md <<'EOF'
# Repo OS Documentation Index

This directory defines how the repository operates when using Claude Code.

## Core Documents

- **AI.md**  
  Root-level contract defining authority, non-negotiables, and how the operator and agents work together.

## AI / Repo OS

- **docs/ai/workflow.md**  
  Defines the development workflow, session lifecycle, and execution rules.

- **docs/ai/quality-gates.md**  
  Defines what “verified” means before commits and pushes are allowed.

- **docs/ai/decisions/**  
  Lightweight decision records related to Repo OS and workflow changes.

- **docs/ai/logs/session-log.md**  
  High-signal summary log updated at the end of each development session.

## Agents

- **.claude/agents/**  
  Project-local Claude Code agents (orchestrator, builder, QA, reviewer, etc.).
  Agent definitions live here and are version-controlled with the repo.

EOF
