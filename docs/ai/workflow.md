# Workflow

## Execution Loop

1. **Plan** — goal, scope, files, verification steps
2. **Build** — small, reviewable increments
3. **Verify** — run checks required by gates
4. **Commit** — only after all gates pass

## HVST Protocol (debugging/instability)

Use when: fixing bugs, failing tests, unstable behavior. Not required for simple feature work.

Loop: **Hypothesis** → **Validate** (smallest experiment) → **Solve** (minimal fix) → **Test** (rerun checks) → **Record**

**Record** (after 2+ failed cycles): When resolved, add entry to `docs/ai/logs/known-issues.md` if not already present. At 2 consecutive failures, check `known-issues.md` for matches before continuing.

## Branch Categories

Work happens on categorized branches. Never commit directly to `main` — merge via PR only. See `docs/ai/quality-gates.md` for branch types and gate mapping.

## Session Lifecycle

At session close: verify all changes, commit, update session log (`docs/ai/logs/session-log.md`).
