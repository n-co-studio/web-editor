cat > docs/ai/decisions/0001-repo-os-baseline.md <<'EOF'
# Decision 0001 — Repo OS Baseline

## Status
Accepted

## Context
This repository serves as a template defining a Repo Operating System (Repo OS) for working with Claude Code in Visual Studio Code.

A consistent, explicit operating model is required to:
- Separate operator authority from agent execution
- Prevent uncontrolled or unsafe actions
- Ensure repeatable project setup
- Enforce planning, verification, and clean commits

## Decision
We establish a Repo OS baseline consisting of:
- An explicit authority model (operator vs agent)
- A two-prompt system:
  - Prompt A: Repo OS initialization
  - Prompt B: Product build operations
- Mandatory verification gates before commits
- Session-based work with high-signal logging
- A GitHub template repository as the source of truth

This baseline is committed as **Commit 0** and must exist before any product code is generated.

## Consequences
- All new projects start from this template
- Repo OS changes are deliberate and version-controlled
- Agents operate only within defined boundaries
- Product logic is never mixed with Repo OS definition

EOF