# Workflow

## Session Handoff Convention

Every pastable block for a new session must start with a plain-text short title (no `#` syntax). VS Code uses the first input line as the tab label.

## Execution Loop

1. **Plan** — goal, scope, files, verification steps
2. **Build** — small, reviewable increments
3. **Verify** — cohesion review (Critic checks diff for internal coherence), then gate checks (QA verifies A1–A6 + push gates)
4. **Commit** — only after all gates pass

## Advisory Board Review

Runs after Prompt 0 completes, before Prompt B. Orchestrated by Prompt A Phase 1. Uses tiered activation to match review depth to scope. Re-initialization (after agent drift, decision conflicts, template sync, or mid-build spec changes) skips advisory review and goes directly to Phase 3 validation — operator selects the mode when Prompt A starts.

1. **Select tier** — Orchestrator picks Lite / Standard / Full based on scope (operator can override or skip)
2. **Activate** — Dispatch agents for the selected tier; scan for conditional signals at Full tier
3. **Review** — Specialists analyze specs in parallel, produce focused briefs
4. **Synthesize** — Orchestrator merges briefs into a Refinement Report
5. **Decide** — Operator reviews each finding: accept / reject / defer
6. **Proceed** — All critical findings addressed, move to Repo OS validation (Phase 3)

See `.claude/agents/_advisory-board.md` for tier definitions, activation logic, and report structure.

## HVST Protocol (debugging/instability)

Use when: fixing bugs, failing tests, unstable behavior. Not required for simple feature work.

Loop: **Hypothesis** → **Validate** (smallest experiment) → **Solve** (minimal fix) → **Test** (rerun checks) → **Record**

**Record** (after 2+ failed cycles): When resolved, add entry to `docs/ai/logs/known-issues.md` if not already present. At 2 consecutive failures, check `known-issues.md` for matches before continuing. Known-issues documentation is blocking at session close — the stop hook blocks if 2+ HVST failures occurred and `known-issues.md` was not updated. Override: `SKIP_KNOWN_ISSUES_CHECK=1` (use when failures were transient — network, timing).

**Review Board** (optional): At 2+ consecutive failures or on operator request, Orchestrator dispatches Architect + Exploration + Critic (hypothesis mode) to review failure context and produce ranked hypotheses before further fix attempts. See `.claude/agents/_hvst-review.md`.

## Branch Categories

Work happens on categorized branches. Never commit directly to `main` — merge via PR only. See `docs/ai/quality-gates.md` for branch types and gate mapping.

## Session Lifecycle

At session close: verify all changes, commit, update session log (`docs/ai/logs/session-log.md`). Zero-change sessions (no commits, no working tree changes) are exempt from the session log requirement — the stop hook downgrades to advisory instead of blocking. Ask operator whether to create a PR to merge to `main` — do not skip or defer without explicit operator direction. Does not apply to `experiment/*` branches. The stop hook enforces: session log modification (blocking), uncommitted changes (blocking), and open PR on mergeable branches (blocking). Overrides: `SKIP_SESSION_LOG=1`, `SKIP_UNCOMMITTED_CHECK=1`, `SKIP_PR_CHECK=1`.

**Session branch isolation** (Decision 0013): Each session uses a dedicated branch. When a session closes, the branch is sealed — no future session may edit files on it. Create a new branch for new work. Task group sessions are exempt (multi-brief groups may reuse branches across sessions). Override: `REPO_OS_SKIP_BRANCH_REUSE=1`.

### Git Trailer Convention

Commits include structured trailers for session metadata. Add trailers to the commit message body (after a blank line):

```
Session: N
Decisions: 0001, 0002
Gates-A: A1-pass A2-pass A3-n/a A4-pass A5-pass A6-n/a
Gates-B: B1-pass B2-n/a B3-n/a
```

Query session history: `git log --format="%(trailers:key=Session)"` or `git log --format="%(trailers)"` for all trailers.

### Prototype Sessions

Prototype sessions on `experiment/*` branches follow a lighter lifecycle. See `docs/ai/prompts/prompt-0.5-prototype.md` for full details. Key differences:
- **No plan-before-code requirement** — the experiment brief (Spike/PoC) or verbal direction (Napkin) is the plan
- **A4 safety only** — no process, quality, or review gates
- **Simplified session log** — one-line entry referencing the prototype brief
- **Agent chain** — Orchestrator + Builder only (no QA/Reviewer/Security unless requested)
- **At close** — update the Learnings and Disposition sections of the brief before deleting the branch

### Task Definition Sessions

Prompt T facilitates exploration and task planning without producing file artifacts. Two modes:
- **Query**: Conversational Q&A grounded in specs and codebase. No agent dispatch.
- **Brief**: 3-agent team (Architect, Exploration, Critic) produces a structured task brief for Prompt B.

Task definition sessions are fully ephemeral — no files written, no session log entries, no gates apply. The output is a terminal-displayed task brief the operator copy-pastes into a new Prompt B session. See `docs/ai/prompts/prompt-t-task-definition.md` for full details.

### Task Group Sessions

When Prompt T splits a task into multiple briefs (Narrow path), each brief includes a `### Task Group` section. The briefs share a task group contract that coordinates naming, patterns, decisions, and integration points across sessions. Contract path depends on repo mode (template mode: `.claude/local/task-groups/{group-name}.yaml`; product mode: `docs/ai/task-groups/{group-name}.yaml`).

- **Contract lifecycle**: First Prompt B session creates the contract from brief metadata. Subsequent sessions read and update it. Prompt T never writes files
- **Conventions are REQUIRE-level**: All sessions must follow the naming patterns, architectural patterns, decisions, and module boundaries established in the contract
- **Sequential execution recommended**: Briefs are numbered and should be executed in order. The contract tracks `next_brief` for sequencing
- **Gate A6**: Verifies contract compliance when a task group is present. Skipped automatically for standalone briefs. Override: `SKIP_CONTRACT_CHECK=1`

See `docs/ai/task-groups/_contract-template.yaml` for the contract structure and `docs/ai/quality-gates.md` for gate A6 details.

### Governance Layers

Three mechanical governance layers enforce process integrity:

1. **Inter-session pipeline** (`docs/ai/governance/`): Committed evidence files proving Prompt 0 (`spec-compiled`) and Prompt A (`advisory-reviewed`) completed. Written by the model at prompt completion. Read by Prompt B at session start. Verified by `branch-guard.sh` on first Bash write and by `pre-commit-gates.sh` at commit-time (both advisory, first-fire).

2. **Phase chain governance** (task group `governance:` section): Per-brief gate evidence in the task group contract. Written by the model at session close. Verified by `branch-guard.sh` on first Bash write and by `pre-commit-gates.sh` at commit-time (both advisory, first-fire). Enables sequential integrity — Brief N+1 can confirm Brief N completed with passing gates.

3. **Override audit** (`.claude/.state/overrides.log`): Session-scoped log of all governance override env vars used. Written by `log_override()` in `_analytics-helper.sh`. Summarized by `session-close-check.sh` at session end. Cleaned at session close.

State files in `.claude/.state/` are cleaned at session close to prevent stale state from leaking across sessions.
