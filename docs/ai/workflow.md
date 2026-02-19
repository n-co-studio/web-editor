# Workflow

## Execution Loop

1. **Plan** — goal, scope, files, verification steps
2. **Build** — small, reviewable increments
3. **Verify** — run checks required by gates
4. **Commit** — only after all gates pass

## Advisory Board Review

Runs after Prompt 0 completes, before Prompt B. Orchestrated by Prompt A Phase 1.

1. **Activate** — Orchestrator scans compiled specs for trigger signals, activates specialists
2. **Review** — Specialists analyze specs in parallel, produce focused briefs
3. **Synthesize** — Orchestrator merges briefs into a Refinement Report
4. **Decide** — Operator reviews each finding: accept / reject / defer
5. **Proceed** — All critical findings addressed, move to Repo OS validation (Phase 3)

See `.claude/agents/_advisory-board.md` for activation logic, brief format, and report structure.

## HVST Protocol (debugging/instability)

Use when: fixing bugs, failing tests, unstable behavior. Not required for simple feature work.

Loop: **Hypothesis** → **Validate** (smallest experiment) → **Solve** (minimal fix) → **Test** (rerun checks) → **Record**

**Record** (after 2+ failed cycles): When resolved, add entry to `docs/ai/logs/known-issues.md` if not already present. At 2 consecutive failures, check `known-issues.md` for matches before continuing.

## Branch Categories

Work happens on categorized branches. Never commit directly to `main` — merge via PR only. See `docs/ai/quality-gates.md` for branch types and gate mapping.

## Session Lifecycle

At session close: verify all changes, commit, update session log (`docs/ai/logs/session-log.md`).

### Prototype Sessions

Prototype sessions on `experiment/*` branches follow a lighter lifecycle. See `docs/ai/prompts/prompt-0.5-prototype.md` for full details. Key differences:
- **No plan-before-code requirement** — the experiment brief (Spike/PoC) or verbal direction (Napkin) is the plan
- **A4 safety only** — no process, quality, or review gates
- **Simplified session log** — one-line entry referencing the prototype brief
- **Agent chain** — Orchestrator + Builder only (no QA/Reviewer/Security unless requested)
- **At close** — update the Learnings and Disposition sections of the brief before deleting the branch
