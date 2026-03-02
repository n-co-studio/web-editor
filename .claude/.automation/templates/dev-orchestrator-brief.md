# Headless Dev Orchestrator Session — audit

Read and follow AI.md. Read all files referenced in AI.md's source-of-truth sections.

## Automation Context

This is a headless automation session (runner-invoked via `claude -p`).
- Entry ID: {entry_id}
- Session type: audit (ephemeral — no gates, clean close)
- Task group: {group_name}
- Target branch: {branch_name}
- Permission profile: audit (read-only)
- Do NOT use `AskUserQuestion` — there is no interactive operator in headless mode
- Do NOT modify any files — this is a read-only audit session
- All output goes to `.claude/.automation/reports/`

## Agent Definition

Read `.claude/agents/dev-orchestrator.md` for the full agent definition, review procedure, and output format.

## Phase 1 — Init + Scope

1. Check out the target branch: `git checkout {branch_name}`
2. Read the task group contract:
   - Template mode: `.claude/local/task-groups/{group_name}.yaml`
   - Product mode: `docs/ai/task-groups/{group_name}.yaml`
3. Read `.claude/agents/_agent-glossary.md` for shared definitions

## Phase 2 — Scope

Identify review scope:
- List all completed briefs from the contract
- Determine commit ranges per brief using session numbers and `git log`
- Identify integration points that cross brief boundaries
- Check for existing drift-detection notices in `.claude/.automation/queue/completed/`

## Phase 3 — Review

Follow the Dev Orchestrator review procedure:

### 3a. Contract Status
Read and summarize brief statuses, gate results, and session decisions from the contract.

### 3b. Cohesion Check
Run `git diff main...HEAD` to capture the full branch diff. Review for:
- Naming consistency against contract `conventions.naming:`
- Pattern adherence against contract `conventions.patterns:`
- Interface alignment at `integration_points:`
- Import/export coherence across brief boundaries

### 3c. Drift Analysis
For each completed brief:
- Get the brief's commit range from git log (filter by Session: trailer)
- Compare declared `boundaries:` against `git diff --name-only` for those commits
- Flag unexpected changes, incomplete implementation, boundary violations

### 3d. Recommendations
Produce advisory recommendations for pre-merge actions, contract amendments, and risk areas.

## Phase 4 — Report

Write the Task Group Health Report to:
`.claude/.automation/reports/health-{group_name}-$(date +%Y%m%d-%H%M%S).yaml`

Follow the output format specified in the Dev Orchestrator agent definition.

## Phase 5 — Close

Exit cleanly. No commits, no merges, no session log updates.
This is an ephemeral audit session — all output is in the report file.

## Task Brief

{brief_text}
