# Decision 0001 — Repo OS Baseline

## Status
Accepted

## Triggers

- type: file
- path: `AI\.md`
- path: `docs/ai/prompts/prompt-.*\.md`
- keywords: `prompt system, verification gate, session-based`

## Context
Repo OS needed a foundational operating model that separates operator authority from agent execution, ensures verifiable work through mandatory gates, and provides a repeatable prompt-based workflow. Without this baseline, agent-assisted development lacks accountability and reproducibility.

## Decision
- Explicit authority model: operator vs agent (see AI.md)
- Prompt system: Prompt 0 (spec), Prompt A (Repo OS init), Prompt B (product build). Extended by Decision 0006 (Prompt 0.5 — prototyping) and Decision 0010 (Prompt T — task definition)
- Mandatory verification gates before commits
- Session-based work with high-signal logging
- GitHub template repository as source of truth
- Baseline must exist (Commit 0) before any product code. Commit 0 is the initial commit produced after Prompt A initializes the Repo OS.

## Consequences
- `AI.md` is the canonical governance index — all authority, source-of-truth paths, and prompt references live there
- Every session produces a log entry, creating an auditable trail of agent work
- All subsequent decisions extend this baseline — the prompt system, gate model, and authority boundary are foundational constraints
