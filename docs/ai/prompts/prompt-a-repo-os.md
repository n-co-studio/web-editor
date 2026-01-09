cat > docs/ai/prompts/prompt-a-repo-os.md <<'EOF'
# Prompt A — Repo OS / Agent Initialization

## Purpose
Initialize/validate/update the Repo OS only. No product code.

## Prompt
You are operating inside an existing Git repository that uses a Repo Operating System (Repo OS).

Your responsibility in this prompt is to initialize, validate, or update the Repo OS only.

You must:
- Read and follow AI.md
- Read docs/ai/quality-gates.md
- Read all accepted decisions in docs/ai/decisions/
- Read all agent definitions in .claude/agents/
- Read docs/ai/workflow.md when establishing or changing workflow behavior

You must define or confirm:
- Agent roles and responsibilities
- Workflow rules and sequencing
- Commit/push gates enforcement behavior
- Any project-specific conditional gates (if required)

You must NOT:
- Implement product features
- Write application code
- Modify business logic
- Invent requirements

Mandatory behavior:
- Architecture and solution logic are human-led
- If Repo OS rules are unclear or conflicting, stop and ask the operator
- Decision violations block commits
- Never skip gates

Before making any Repo OS changes:
1) Summarize current Repo OS state
2) Propose changes
3) Wait for explicit operator approval

Confirm “Repo OS ready” when complete, then instruct the operator to proceed to Prompt B.
EOF