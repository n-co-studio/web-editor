# Workflow

## Session Handoff Convention

REQUIRE: every pastable block for a new session must start with a plain-text short title (no `#` syntax). VS Code uses the first input line as the tab label.

## Phase Model

See: `.claude/agents/_agent-glossary.md` § Phase Model for phase definitions, automation tags, and session type variants.

Session-specific behavioral rules:
- **Plan-approval hook**: Only `AskUserQuestion` triggers the `plan-approval.sh` hook that writes the `plan-approved` state file and unblocks Edit/Write. Conversational plan approval does not trigger the hook (see `orchestrator.md` § Constraints).
- **Transition rules**: Forward-only, except defined loops (`review→build`, `verify→build`). Each loop increments the cycle counter.
- **Session ID binding**: Phase-state is invalidated when the session ID changes, preventing stale state from prior sessions.

See Decision 0014 for the canonical phase sequence definitions.

## Execution Loop

The execution loop maps to phases in the standard build sequence:

1. **Plan** (plan phase) — goal, scope, files, verification steps
2. **Build** (build phase) — small, reviewable increments
3. **Verify** (review + verify phases) — cohesion review (Critic checks diff for internal coherence), then gate checks (QA verifies A1–A6 + push gates)
4. **User Review** (user-review phase, optional) — persona simulation dispatch when task brief defines User Review scenarios. Skipped when no User Review section present
5. **Commit** (commit phase) — only after all gates pass

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

See: `.claude/agents/_agent-glossary.md` § HVST for the full protocol definition, record step, and review board procedure.

## User Review

See: `.claude/agents/_agent-glossary.md` § User Review for the full system definition, tiers, dispatch procedure, and operator disposition.

## Branch Categories

Work happens on categorized branches. BLOCK: never commit directly to `main` — enforced by bash-guard.sh / write-guard.sh (Section 3). In solo mode (Decision 0015), branches merge to main directly at session close. See `docs/ai/quality-gates.md` for branch types and gate mapping.

## Session Lifecycle

**Init sequence**: REQUIRE: create the session branch as the first action in the init phase, before reading docs or writing files.

**Close sequence** — REQUIRE: execute these steps in order before the session ends:

1. Update session log (`docs/ai/logs/session-log.md`; template mode: `.claude/local/session-log.md`)
2. Commit all remaining changes including the session log
3. Merge to main (solo mode) — REQUIRE: agent executes the merge explicitly:
   - Precondition: `solo=true` in phase-state. All mergeable branch types (`feature/*`, `fix/*`, `hotfix/*`). Task group final briefs included — Gate 7 allows merge in the close phase. Non-final task group briefs close without merge. Experiment and release branches excluded per Decision 0015
   - Merge: `git checkout main && git merge --ff-only <branch>` (fallback `--no-ff`)
   - On success: call `write_merge_signal "<branch>"` (writes `.claude/.state/merge-source-branch` via shell I/O — stop hook detects this and skips redundant merge)
   - On failure: `git merge --abort && git checkout <branch>`, notify operator. Do not attempt conflict resolution on main. Signal file is NOT written — stop hook retries merge as safety net
   - Post-merge push: `git push origin main` (advisory — warn on failure, do not block). Skipped in template mode (`repo-mode` = `template`). Skipped when no remote configured (`git remote get-url origin` fails). Never force-push. Push failure: warn operator to run `git push origin main` manually
   - Post-merge: after push attempt (success or failure), agent's ONLY remaining action is step 4. No Edit/Write permitted on main (Gate 1 blocks)
   - Safety net: stop hook retains solo merge logic for sessions where the agent fails to merge or skips the close sequence. Stop hook and runner also push after merge (same advisory pattern)
4. Present closing summary to operator — this is the final agent message

Zero-change sessions (no commits, no working tree changes) are exempt from the session log requirement — the stop hook downgrades to advisory. Does not apply to `experiment/*` branches. BLOCK: session log modification and uncommitted changes at close — enforced by session-close-check.sh. Overrides: `SKIP_SESSION_LOG=1`, `SKIP_UNCOMMITTED_CHECK=1`.

### Solo Mode

See: `.claude/agents/_agent-glossary.md` § Solo Mode for full semantics (branch types, auto/review behavior, conflict handling).

### Session Branch Isolation

Decision 0013. Each session uses a dedicated branch. BLOCK: when a session closes, the branch is sealed — no future session may edit files on it (enforced by bash-guard.sh / write-guard.sh (Section 3)). Create a new branch for new work. Task group sessions are exempt (multi-brief groups share one branch across sessions). Override: `REPO_OS_SKIP_BRANCH_REUSE=1`.

**Concurrent session awareness**: The session registry (`.claude/.state/sessions/`) tracks active sessions. `register_session()` writes a YAML file at session init; `unregister_session()` removes it at close and cleans stale entries (dead PIDs, >24h age). When multiple sessions target the same branch, non-task-group overlap is blocked at edit time (Gate 6 in bash-guard.sh / write-guard.sh). Task group sessions sharing a branch receive an advisory warning. Prompt T sessions (taskdef-query, taskdef-brief) are exempt. Override: `REPO_OS_SKIP_OVERLAP_CHECK=1`.

### Git Trailer Convention

REQUIRE: commits include structured trailers for session metadata. Add trailers to the commit message body (after a blank line):

```
Session: N
Decisions: 0001, 0002
Gates-A: A1-pass A2-pass A3-n/a A4-pass A5-pass A6-n/a
Gates-B: B1-pass B2-n/a B3-n/a
```

Query session history: `git log --format="%(trailers:key=Session)"` or `git log --format="%(trailers)"` for all trailers.

### Prototype Sessions — See: `docs/ai/workflow-appendix/session-type-prototype.md`

### Task Definition Sessions — See: `docs/ai/workflow-appendix/session-type-task-definition.md`

### Ephemeral Sessions

Lightweight session type for Q&A and exploration (Phase 3b). Phase sequence: `init → conversation → close`. Skips mode-guard, bash-guard branch gates, and close checks (no session log, no commit check). Does not trigger solo merge or branch seal. Use `init_phase "ephemeral"` when the user's intent is Q&A or exploration with no code changes expected. If the user later requests code changes, call `upgrade_session_type` to convert to standard (resets phase to `plan`).

### Editor Live Sessions — See: `docs/ai/workflow-appendix/session-type-editor-live.md`

### Task Group Sessions — See: `docs/ai/workflow-appendix/session-type-task-group.md`

Includes: Parallel Execution, Merge brief lifecycle, Task Contract Lifecycle (Decision 0020).

### Automation Sessions — See: `docs/ai/workflow-appendix/session-type-automation.md`

Includes: Runner lifecycle, toggle semantics, escalation, queue validation, decision cache, file locking, dev orchestrator, auto mode activation, circuit breaker, intake CLI, push_on_complete, scope classification, PermissionRequest hook, AskUserQuestion deny hook.

### Governance Layers

Three mechanical governance layers enforce process integrity:

1. **Inter-session pipeline** (`docs/ai/governance/`): Committed evidence files proving Prompt 0 (`spec-compiled`) and Prompt A (`advisory-reviewed`) completed. Written by the model at prompt completion. Read by Prompt B at session start. Verified by `bash-guard.sh` on first Bash write and by `pre-commit-gates.sh` at commit-time (both advisory, first-fire).

2. **Phase chain governance** (task group `governance:` section): Per-brief gate evidence in the task group contract. Written by the model at session close. Verified by `session-close-check.sh` at session close (advisory). Enables sequential integrity — Brief N+1 can confirm Brief N completed with passing gates.

3. **Override audit** (`.claude/.state/overrides.log`): Session-scoped log of all governance override env vars used. Written by `log_override()` in `_analytics-helper.sh`. Summarized by `session-close-check.sh` at session end. Cleaned at session close.

**Override scoping recommendation:** Prefer `VAR=value command` over `export VAR` when applying governance overrides. The inline pattern scopes the override to a single command invocation; `export` persists for the entire session, which risks accidentally bypassing governance for subsequent operations. Example: `SKIP_SESSION_LOG=1 git commit -m "..."` rather than `export SKIP_SESSION_LOG=1` followed by separate commands.

State files in `.claude/.state/` are cleaned at session close to prevent stale state from leaking across sessions.
