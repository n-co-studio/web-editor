# Workflow

## Session Handoff Convention

REQUIRE: every pastable block for a new session must start with a plain-text short title (no `#` syntax). VS Code uses the first input line as the tab label.

## Phase Model

See: `.claude/agents/_agent-glossary.md` § Phase Model for phase definitions, automation tags, and session type variants.

Session-specific behavioral rules:
- **Plan-approval hook**: `AskUserQuestion` triggers the `plan-approval.sh` hook that writes the `plan-approved` state file and unblocks Edit/Write. Conversational plan approval does not trigger the hook (see `orchestrator.md` § Constraints). A valid handoff bundle (Decision 0038) also satisfies the gate — `_phase-helper.sh::drift_check` writes the same `plan-approved` schema from `.claude/local/handoff-bundle.yaml`.
- **Drift-check phase (Decision 0038)**: Standard / taskgroup sessions enter `drift-check` before `plan`. When a bundle is valid + fresh + spec snapshot matches + no scope-file drift, `drift_check` writes derived state files and the session forward-jumps to `build`. Otherwise, falls through to the legacy `plan → approval` flow.
- **Transition rules**: Forward-only, except defined loops (`review→build`, `verify→build`). Each loop increments the cycle counter. Forward-jump from `drift-check` to `build` (skipping `plan` and `approval`) is permitted when `drift_check` returns 0 — same skippable-phase semantics as `user-review`/`op-review`.
- **Session ID binding**: Phase-state is invalidated when the session ID changes, preventing stale state from prior sessions.

See Decision 0014 for the canonical phase sequence definitions and Decision 0038 for handoff bundle semantics.

## Execution Loop

The execution loop maps to phases in the standard build sequence:

1. **Drift-check** (drift-check phase, Decision 0038) — evaluate handoff bundle. On valid + fresh: skip to build. On absent / stale / drifted: fall through to plan.
2. **Plan** (plan phase, legacy fallback) — goal, scope, files, verification steps
3. **Build** (build phase) — small, reviewable increments
4. **Verify** (review + verify phases) — cohesion review (Critic checks diff for internal coherence), then gate checks (QA verifies A1–A6 + push gates)
5. **User Review** (user-review phase, optional) — persona simulation dispatch when task brief defines User Review scenarios. Skipped when no User Review section present
6. **Commit** (commit phase) — only after all gates pass

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

**Worktree isolation (Decision 0033)**: Every session runs in its own git worktree by default, eliminating branch conflicts and state interference when multiple sessions run concurrently. Interactive sessions: `claude --worktree`. Headless sessions: `runner.sh` passes `--worktree` automatically. The main worktree stays on `main` — no branch switching in the primary working tree. State files are isolated per session via `get_session_state_dir()` (Decision 0030). Opt-out: `REPO_OS_WORKTREE_ISOLATE=0` for runner sessions; omit `--worktree` for interactive.

**Init sequence**: REQUIRE: create the session branch as the first action in the init phase, before reading docs or writing files.

**Close sequence** — REQUIRE: execute these steps in order before the session ends:

1. Knowledge graph update (advisory — Decision 0034): if either `docs/ai/knowledge-graph/graph.yaml` (template) or `product-graph.yaml` (product) exists, update the appropriate graph with new nodes, new edges (`source_type: agent-inferred`), and updated `last_verified` dates via shell I/O. Template files → `graph.yaml`, product files → `product-graph.yaml`. Cross-layer edges go in the source node's graph. Use `mkdir`-based locking (`.graph-lock` for template, `.product-graph-lock` for product). If the write fails, proceed — graph updates are non-blocking. See `.claude/agents/_agent-glossary.md` § Knowledge Graph Protocol
2. Update session log (`docs/ai/logs/sessions/session-{id}.md`; template mode: `.claude/local/sessions/session-{id}.md`)
3. Commit all remaining changes including the session log
4. Merge to main (solo mode) — REQUIRE: merge is executed by `session-close-check.sh` (stop hook) and/or runner. Agent action depends on session type:
   - Precondition: `solo=true` in phase-state. All mergeable branch types (`feature/*`, `fix/*`, `hotfix/*`). Task group final briefs included — Gate 7 allows merge in the close phase. Non-final task group briefs close without merge. Experiment and release branches excluded per Decision 0015
   - **Worktree sessions (Decision 0033 default — `is_full_worktree_session()` true):** `git checkout main` is refused by git because main is checked out in the main worktree. The following ref-move commands are also **prohibited** — bash-guard Phase 1e blocks them with GATE-RECOVERABLE: `git branch -f main <ref>`, `git checkout -B main`, `git update-ref refs/heads/main <ref>`, `git fetch . <ref>:main`. Reason: they advance the ref pointer without updating the main working tree, so merged code is absent from disk. Correct merge mechanism: `session-close-check.sh` acquires `.claude/.state/.merge-lock` (flock with mkdir fallback, 3-attempt fail-closed); runs `git -C <main-repo-path> merge --ff-only <branch>` (fallback `git -C <main-repo-path> merge --no-ff -m "Merge <branch>" <branch>`); on failure runs `git -C <main-repo-path> merge --abort`; then unconditionally syncs the main working tree (`git -C <main-repo-path> reset HEAD -- .` then `git -C <main-repo-path> checkout HEAD -- .`) and verifies via `git -C <main-repo-path> diff HEAD --quiet` (stale result writes a gate-failure escalation). Runner's `_solo_merge_if_needed` runs the same worktree-aware path after the session exits. Agent action: commit changes and advance to close phase — do not attempt to merge. See Decision t-0030 § Merge Coordination and § Worktree Ref-Move Invariant
   - **Non-worktree sessions (session running in main checkout — rare since Decision 0033):** `git checkout main && git merge --ff-only <branch>` (fallback `--no-ff`); on failure: `git merge --abort && git checkout <branch>`, notify operator. Do not attempt conflict resolution on main. After success: call `write_merge_signal "<branch>"` so the stop hook skips its redundant merge attempt. Signal file NOT written on failure — stop hook retries as safety net
   - Post-merge push: `git push origin main` (advisory — warn on failure, do not block). Skipped in template mode (`repo-mode` = `template`). Skipped when no remote configured (`git remote get-url origin` fails). Never force-push. Push failure: warn operator to run `git push origin main` manually
   - Post-merge: agent's ONLY remaining action is step 5. No Edit/Write permitted on main (Gate 1 blocks)
   - Safety net: stop hook retains solo merge logic for sessions where the agent skips the close sequence or fails to signal. Stop hook and runner also push after merge (same advisory pattern)
5. Present closing summary to operator — this is the final agent message

Zero-change sessions (no commits, no working tree changes) are exempt from the session log requirement — the stop hook downgrades to advisory. Does not apply to `experiment/*` branches. BLOCK: session log modification and uncommitted changes at close — enforced by session-close-check.sh. Overrides: `SKIP_SESSION_LOG=1`, `SKIP_UNCOMMITTED_CHECK=1`.

### Solo Mode

See: `.claude/agents/_agent-glossary.md` § Phase Model for full semantics (branch types, auto/review behavior, conflict handling).

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

See: `_agent-glossary.md` § Phase Model (session-type sequences table) for semantics. Use `init_phase "ephemeral"` for Q&A/exploration. Convert to standard via `upgrade_session_type` when code changes are needed.

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
