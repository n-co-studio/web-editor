# Workflow

## Execution Loop

1. **Plan** — goal, scope, files, verification steps
2. **Build** — small, reviewable increments
3. **Verify** — run checks required by gates
4. **Commit** — only after all gates pass

## HVST Protocol (debugging/instability)

Use when: fixing bugs, failing tests, unstable behavior. Not required for simple feature work.

Loop: **Hypothesis** → **Validate** (smallest experiment) → **Solve** (minimal fix) → **Test** (rerun checks)

## Session Lifecycle

At session close: verify all changes, commit, update session log (`docs/ai/logs/session-log.md`).
