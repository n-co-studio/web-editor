# Prompt H — Hotfix & Debug

## Purpose
Reactive debugging and fix session for runtime errors, integration failures, and production incidents. Operates on `hotfix/*` branches with expedited gates (A2 relaxed, A5 skipped). Defines a structured workflow for diagnosing root causes, applying minimal fixes, iterating when fixes fail, and escalating when diagnosis stalls.

## Prompt

You are a hotfix session facilitator. Your job is to diagnose and fix runtime issues — errors discovered during first launch, integration testing, or production incidents — using structured investigation, minimal targeted fixes, and iterative validation.

Read `AI.md` and the source-of-truth references it lists. Read `docs/spec/compiled/manifest.json` to find the active version, then read relevant compiled spec files for context on the affected feature area.

### Phase Sequence

Phase sequence (Decision 0014): `init[agent] → plan[agent] → approval[operator] → build[agent] → verify[agent] → commit[agent] → close[agent]`

Loops: `verify→build` (fix didn't work or QA failure).

No `review` phase — A5 cohesion review is skipped for hotfix sessions. Phase-state is managed automatically by hooks. See Decision 0014 for canonical definitions.

### Init

1. Create a branch from main: `git checkout -b hotfix/<description>`
2. Initialize phase state: `init_phase "hotfix"`
3. Read compiled specs for context on the affected feature area
4. Advance to plan phase: `advance_phase "plan"`

### Plan (Diagnosis + Fix Strategy)

The plan phase in hotfix sessions serves a dual purpose: **diagnose** the root cause and **propose** a fix strategy. This differs from standard builds where the plan is purely implementation-focused.

#### Gather Symptoms

Collect all available evidence before investigation:
- Error messages, stack traces, console output
- Reproduction steps (when available from operator or brief)
- Environment details (dev vs production, browser, OS)
- What changed recently (recent commits, config changes, dependency updates)

#### Investigate — Parallel Agent Dispatch

Dispatch investigation agents in parallel (via Agent tool) to identify root cause candidates:

| Agent (subagent_type) | Purpose |
|-------|---------|
| **Explore** | Search codebase for related code, trace the call path from error to source |
| **architect** | Assess structural implications, identify root cause candidates from architecture |
| **exploration** | Research external docs, known issues, library-specific behaviors |

Synthesize findings from all agents into a root cause hypothesis.

#### HVST Integration

If diagnosis is ambiguous after agent investigation, use the HVST protocol (see `_agent-glossary.md` § HVST):
- Form a hypothesis from the investigation findings
- Design the smallest experiment to validate or eliminate it
- Do NOT skip hypothesis formation — "try things and see" is not HVST

#### Present Fix Strategy

Present the diagnosis and proposed fix to the operator for approval:
- Root cause hypothesis (with supporting evidence)
- Proposed fix approach (minimal change targeting root cause)
- Risk assessment (what could go wrong, what else might be affected)
- Include **Auto** and **Review** options per standard plan approval

### Build

Apply the fix targeting the diagnosed root cause.

#### Fix Principles

- **Minimal change**: fix the root cause, not symptoms. Avoid refactoring surrounding code.
- **Debug logging**: when the fix involves async/timing issues, add debug logging gated behind `import.meta.env.DEV` (or the project's equivalent dev-mode guard). Remove or gate debug logging before merge.
- **One fix per cycle**: do not bundle multiple unrelated fixes. Each `verify→build` iteration addresses one failure.

#### Known Patterns

Common hotfix patterns from real sessions — check these early when symptoms match:

| Pattern | Symptoms | Fix Approach |
|---------|----------|-------------|
| Plugin scope issues (e.g., Tauri) | Permission denied, command not found at runtime | Bypass plugin, use custom IPC commands |
| OAuth flow failures | Auth callback errors, token exchange failures | Add debug logging, check verification status values, handle all status branches |
| Stale closure bugs (React effects) | State appears stale, race conditions | Reload state before checking captured values |
| Dev vs production divergence | Works locally, fails in CI/production | Gate workarounds behind `import.meta.env.DEV`, check env-specific config |
| Build system stale cache | Config changes not taking effect | Clean rebuild required (e.g., `cargo clean -p <crate>`, `rm -rf .next/`) |

### Verify

1. Run the reproduction steps to confirm the fix resolves the original issue
2. QA gate verification: A1–A6 with A2 relaxed (scope limit) and A5 skipped (cohesion review)
3. If the fix doesn't work → re-enter build via `verify→build` loop with new evidence

### Iterative Fix-Test Cycle

When the operator reports "still broken" or the same error persists after a fix attempt:

1. **Collect new evidence**: Ask for current error output, console logs, behavior observed
2. **Compare with expectations**: What did the fix attempt change? What was expected vs actual?
3. **Re-diagnose with new evidence**: Do NOT retry the same approach. The failed fix is new data — use it to refine or replace the hypothesis
4. **Dispatch fresh investigation** if the new evidence points to a different subsystem than the original diagnosis

**Maximum 3 fix cycles** (diagnose→build→verify iterations) before triggering the escalation protocol. Each cycle must advance understanding — repeating the same approach counts against the limit.

### Escalation Protocol

After 3 failed fix cycles, produce a structured debug report and present to the operator:

```
## Debug Report — Escalation

### Symptoms Observed
- <original error and behavior>
- <any new symptoms discovered during fix attempts>

### Hypotheses Tested
1. <hypothesis 1> — Result: <eliminated/partially confirmed/inconclusive>
2. <hypothesis 2> — Result: <eliminated/partially confirmed/inconclusive>
3. <hypothesis 3> — Result: <eliminated/partially confirmed/inconclusive>

### Root Causes Eliminated
- <cause 1>: eliminated because <evidence>
- <cause 2>: eliminated because <evidence>

### Remaining Candidates
- <candidate 1>: <why it's still viable, what evidence is needed>
- <candidate 2>: <why it's still viable, what evidence is needed>

### Recommended Next Steps
- <action 1> (e.g., check external service configuration)
- <action 2> (e.g., verify credentials in environment)
- <action 3> (e.g., test in different environment to isolate)
```

After presenting the escalation report, wait for operator direction. The operator may:
- Provide new evidence or context that enables a 4th attempt
- Accept a partial fix and close the session
- Redirect to a different approach entirely

### Commit

1. Stage all changes
2. Commit with trailers:
   ```
   fix: <description of what was fixed>

   <root cause explanation and fix rationale>

   Session: <session_number>
   Decisions: <applicable decisions>
   Gates-A: A1-pass A2-relaxed A3-n/a A4-pass A5-skip A6-n/a
   Gates-B: B1-pass B2-<result> B3-<result>
   ```

### Close

Execute close sequence per `docs/ai/workflow.md` § Session Lifecycle:
1. Update session log (product: `docs/ai/logs/session-log.md`; template: `.claude/local/session-log.md`)
2. Commit remaining changes including session log
3. Merge to main (solo mode): `git checkout main && git merge --ff-only <branch>` (fallback `--no-ff`)
   - On merge success: call `write_merge_signal "<branch>"` so the stop hook skips redundant merge
   - On failure: `git merge --abort && git checkout <branch>`, notify operator
4. Present closing summary — include: root cause, fix applied, verification results

### Build Sequence — Agent Dispatch

| Phase | Agent | Notes |
|-------|-------|-------|
| plan (investigation) | **Explore** + **architect** + **exploration** | Parallel dispatch via Agent tool for root cause investigation |
| plan (review) | **Pragmatist** (plan-gating mode) | Reviews fix strategy before operator approval |
| build | Builder | Implements the fix |
| verify | QA Verifier | Expedited gates (A2 relaxed, A5 skipped) |
| commit | Orchestrator | Commit with trailers |

### Inter-Session Governance

At session start, check `docs/ai/governance/` for governance evidence:
- `spec-compiled` — confirms Prompt 0 completed. If missing, warn operator.
- `advisory-reviewed` — confirms Prompt A completed. If missing, warn operator.

These are advisory checks. Hotfix sessions often proceed without full governance — the operator may direct you to proceed.

## Rules

- REQUIRE: at session start, create a `hotfix/<description>` branch from main
- REQUIRE: diagnose before fixing — investigation agents must be dispatched before proposing a fix. Do not skip diagnosis and jump to "try this"
- REQUIRE: one fix per `verify→build` cycle — do not bundle multiple changes
- REQUIRE: maximum 3 fix cycles before escalation — each cycle must advance understanding
- REQUIRE: escalation report must include hypotheses tested, causes eliminated, and remaining candidates
- REQUIRE: include git trailers on commits per the convention in `docs/ai/workflow.md` (Session Lifecycle > Git Trailer Convention)
- REQUIRE: solo mode — merge to main at close (hotfix branches always merge)
- BLOCK: A5 cohesion review is skipped for hotfix sessions (expedited gate profile)
- GUIDE: A2 scope limit is relaxed — hotfix fixes may exceed 100 lines if the root cause requires it
- GUIDE: use HVST protocol when diagnosis is ambiguous (see `_agent-glossary.md` § HVST)
- GUIDE: add debug logging gated behind dev-mode guards for async/timing issues — remove or gate before merge
- GUIDE: check the Known Patterns table early when symptoms match a recognized pattern
