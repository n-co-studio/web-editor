# Decision 0008 — Post-Build Cohesion Review Gate

## Status
Accepted

## Decision
- New commit gate **A5 (Cohesion)** requires a post-build coherence review before commit
- The existing Critic agent operates in a second mode (cohesion) alongside its spec mode (advisory board)
- Cohesion mode reviews the diff + touched files + immediate neighbors for internal codebase coherence — not spec alignment
- Scope: broken cross-references, dangling imports, inconsistent naming, half-finished integrations, contradictory patterns
- The Orchestrator invokes Critic in cohesion mode after Builder signals done, before QA runs
- Orchestrator passes the git diff and file list in the Task prompt; Critic remains read-only (Read/Glob/Grep only)
- Orchestrator reviews Critic findings: surfaces ambiguity to operator, delegates clear fixes to Builder
- If fixes were made, Critic is re-run (2-round cap, then escalate to operator for accept/defer)
- QA verifies A5 behaviorally: evidence of cohesion review, findings addressed, re-run if fixes applied
- A5 applies to branches with standard gates (feature/*, fix/*) and full gates (main, release/*) — not experiment/* (A4 only) or hotfix/* (expedited)

## Consequences
- Critic agent gains dual-mode operation (spec mode + cohesion mode)
- Quality gates table gains A5 row
- QA verifier gains A5 check
- Orchestrator verification checklist gains cohesion review step
- Build flow gains Critic step between Builder and QA
- `_advisory-board.md` "spec is the input" constraint scoped to spec mode only
