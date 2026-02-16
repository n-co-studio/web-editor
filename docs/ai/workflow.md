# Workflow

## Execution Loop

1. **Plan** — goal, scope, files, verification steps
2. **Build** — small, reviewable increments
3. **Verify** — run checks required by gates
4. **Commit** — only after all gates pass

## HVST Protocol (debugging/instability)

Use when: fixing bugs, failing tests, unstable behavior. Not required for simple feature work.

Loop: **Hypothesis** → **Validate** (smallest experiment) → **Solve** (minimal fix) → **Test** (rerun checks)

## Branch Categories

Work happens on categorized branches. Category determines gate strictness — see `docs/ai/quality-gates.md` for the full mapping.

| Branch | When to use |
|--------|------------|
| `feature/*` | New functionality (default) |
| `fix/*` | Bug fixes |
| `hotfix/*` | Urgent production fixes (expedited gates) |
| `release/*` | Release candidates (all gates + release checklist) |
| `experiment/*` | Spikes and prototypes (safety gates only, never merge to main) |

**Rule:** Never commit directly to `main`. All work flows through a categorized branch and merges via PR.

## Session Lifecycle

At session close: verify all changes, commit, update session log (`docs/ai/logs/session-log.md`).
