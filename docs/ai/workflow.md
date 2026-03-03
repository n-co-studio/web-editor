# Workflow

## Session Handoff Convention

REQUIRE: every pastable block for a new session must start with a plain-text short title (no `#` syntax). VS Code uses the first input line as the tab label.

## Phase Model

Sessions progress through an ordered sequence of phases tracked in `.claude/.state/phase-state`. Hooks enforce phase-appropriate actions automatically — agents do not need to read the phase-state file directly.

- **Phase sequences** are defined per session type in Decision 0014. Each prompt documents its own sequence.
- **Automation tags** (`agent`, `operator`, `both`) indicate who acts at each phase.
- **Auto/review mode**: Set at plan approval. Auto skips the `op-review` phase; review (default) pauses for operator acceptance before close.
- **Plan-approval hook**: Only `AskUserQuestion` triggers the `plan-approval.sh` hook that writes the `plan-approved` state file and unblocks Edit/Write. Conversational plan approval does not trigger the hook (see `orchestrator.md` § Constraints).
- **Transition rules**: Forward-only, except defined loops (`review→build`, `verify→build`). Each loop increments the cycle counter.
- **Session ID binding**: Phase-state is invalidated when the session ID changes, preventing stale state from prior sessions.

See Decision 0014 for the canonical phase sequence definitions and Decision 0015 for solo mode merge semantics.

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

Use when: fixing bugs, failing tests, unstable behavior. Not required for simple feature work.

Loop: **Hypothesis** → **Validate** (smallest experiment) → **Solve** (minimal fix) → **Test** (rerun checks) → **Record**

**Record** (after 2+ failed cycles): When resolved, add entry to `docs/ai/logs/known-issues.md` (template mode: `.claude/local/known-issues.md`) if not already present. At 2 consecutive failures, check `known-issues.md` for matches before continuing. BLOCK: known-issues documentation at session close — enforced by session-close-check.sh (blocks if 2+ HVST failures occurred and `known-issues.md` was not updated). Override: `SKIP_KNOWN_ISSUES_CHECK=1` (use when failures were transient — network, timing).

**Review Board** (optional): At 2+ consecutive failures or on operator request, Orchestrator dispatches Architect + Exploration + Critic (hypothesis mode) to review failure context and produce ranked hypotheses before further fix attempts. See `.claude/agents/_hvst-review.md`.

## User Review

Decision 0021. Optional LLM persona simulation providing synthetic user perspective on implementation output. Advisory-only — no gate, no state file, no mechanical enforcement.

**Phase position:** `user-review` phase in the standard and taskgroup build sequences, after `verify` and before `commit`. Skippable — when the task brief has no User Review section, the phase is forward-jumped (verify → commit directly).

**Opt-in mechanism:** User Review is never default-on. Two activation paths:
- **Task brief opt-in**: Prompt T includes a `### User Review` section specifying tiers, mode, and JTBD scenario definitions. The contract's `user_review:` block carries this into the Prompt B session.
- **Operator request**: The operator requests user review during the session (e.g., "run tier-2 review on the signup flow"). The Orchestrator constructs scenarios from the operator's description.

**Dispatch and synthesis:** When the `user-review` phase is active, the Orchestrator dispatches persona agents (`.claude/agents/_user-review-tier-{1,2,3}.md`) in parallel via the Task tool. Each agent walks through scenario steps by reading implementation files and narrating the simulated user experience. Results are synthesized: deduplicated across tiers, severity-escalated to the highest level when multiple tiers flag the same issue. The synthesized User Review Report is presented to the operator during `op-review`.

**Operator disposition:** Findings require operator disposition (accept / note / dismiss) — same pattern as advisory board findings (Decision 0007). Not a silent report. Deferred findings are noted in the closing summary.

**Operating mode exclusions:** User Review is available in child mode only. Excluded from template mode (no product code), autonomous mode (no operator), headless/automation mode (no operator interaction), and experiment sessions (lightweight lifecycle, no `user-review` phase).

**Token cost:** Three persona agents reading code and producing reports may consume 20,000–50,000 tokens per run. The opt-in mechanism mitigates cost — User Review only runs when explicitly requested.

## Branch Categories

Work happens on categorized branches. BLOCK: never commit directly to `main` — enforced by branch-guard.sh / write-guard.sh (Section 3). In solo mode (Decision 0015), branches merge to main directly at session close. See `docs/ai/quality-gates.md` for branch types and gate mapping.

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

Decision 0015. Branches merge to main directly at session close. Applies to `feature/*`, `fix/*`, `hotfix/*` branches only — `experiment/*` and `release/*` are excluded. In auto mode, merge happens autonomously after all gates pass. In review mode, the agent pauses at `op-review` for operator acceptance before merging. Merge failure triggers `git merge --abort` and operator notification — the agent does not attempt automatic conflict resolution on main.

### Session Branch Isolation

Decision 0013. Each session uses a dedicated branch. BLOCK: when a session closes, the branch is sealed — no future session may edit files on it (enforced by branch-guard.sh / write-guard.sh (Section 3)). Create a new branch for new work. Task group sessions are exempt (multi-brief groups share one branch across sessions). Override: `REPO_OS_SKIP_BRANCH_REUSE=1`.

**Concurrent session awareness**: The session registry (`.claude/.state/sessions/`) tracks active sessions. `register_session()` writes a YAML file at session init; `unregister_session()` removes it at close and cleans stale entries (dead PIDs, >24h age). When multiple sessions target the same branch, non-task-group overlap is blocked at edit time (Gate 6 in branch-guard hooks). Task group sessions sharing a branch receive an advisory warning. Prompt T sessions (taskdef-query, taskdef-brief) are exempt. Override: `REPO_OS_SKIP_OVERLAP_CHECK=1`.

### Git Trailer Convention

REQUIRE: commits include structured trailers for session metadata. Add trailers to the commit message body (after a blank line):

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

- **One branch per group**: Brief 1 creates the branch. Briefs 2 through N-1 commit and close without merge. Brief N (final) merges to main and seals the branch. Non-final briefs do not seal the branch (Decision 0013)
- **Contract lifecycle**: First Prompt B session creates the contract from brief metadata, following `docs/ai/task-groups/_contract-template.yaml`. Subsequent sessions read the contract at session start — conventions are binding constraints. At session close, update the contract: mark this brief's status as `complete`, set session number and branch, append any new session decisions. Append a `governance:` entry for the current brief recording gate results (A1–A6, B1–B3), any overrides used, and a timestamp. Prompt T never writes files
- **Conventions are REQUIRE-level**: All sessions must follow the naming patterns, architectural patterns, decisions, and module boundaries established in the contract
- **Sequential execution (default)**: Briefs are numbered and should be executed in order. The contract tracks `next_brief` for sequencing
- **Pre-approval mode**: Operator may set auto mode for the entire group at Prompt T time. Individual briefs inherit the mode without re-prompting. The `approval` phase auto-passes for pre-approved groups
- **Standalone sessions**: When the task brief has no `### Task Group` section, skip all contract-related behavior entirely
- **Gate A6**: Verifies contract compliance when a task group is present. Skipped automatically for standalone briefs. Override: `SKIP_CONTRACT_CHECK=1`

See `docs/ai/task-groups/_contract-template.yaml` for the contract structure and `docs/ai/quality-gates.md` for gate A6 details.

#### Parallel Execution

When Prompt T detects non-overlapping file scope across briefs, it offers parallel execution. The contract's `execution` field is set to `parallel`:

- **Boundaries**: Each brief declares file paths/globs it owns exclusively. Parallel briefs MUST restrict edits to their declared boundaries. Shared files (index files, config) are owned by the merge brief. Edits outside boundaries require explicit operator approval
- **Completion markers**: Each content brief writes `.claude/.state/tg-{group}-brief-{seq}.complete` at session close. The merge brief checks all markers before proceeding
- **Merge brief (Brief M)**: Auto-generated by Prompt T, appended as the last brief. Uses the `taskgroup-merge` session type (Decision 0014). Runs after all content briefs complete. Phase sequence: `init → contract-init → cohesion → verify → commit → op-review → close`. The `cohesion` phase performs cross-session cohesion review across the combined diff from all parallel briefs. Integration issues are resolved in the `cohesion` phase (self-loop: `cohesion→cohesion`). Close always merges to main and seals the branch
- **Branch strategy**: Same as sequential — one branch per group. Brief 1 creates the branch. Content briefs close without merge. Merge brief merges to main and seals

**Merge brief lifecycle:**

1. **`contract-init` phase**: Sync conventions from contract. Verify all content brief completion markers exist (glob: `.claude/.state/tg-*-brief-*.complete`). If any markers are missing, the agent blocks at this phase and reports which briefs have not completed. The operator restarts the failed brief or manually creates the marker file (`date -u +%Y-%m-%dT%H:%M:%SZ > .claude/.state/tg-{group}-brief-{seq}.complete`)
2. **`cohesion` phase**: Run `git diff main...HEAD` to produce the combined diff from all parallel content briefs. Dispatch Critic in cohesion mode against this diff. Resolve findings directly (self-loop: `cohesion→cohesion`, capped at 2 rounds). See `.claude/agents/_cohesion-review.md` Cross-Session Cohesion Mode
3. **`verify` phase**: QA verifies all gates (A1–A6, B1–B3). A6 applies (task group contract compliance)
4. **`close` phase**: Merge to main, seal branch, clean completion markers (hook removes all `tg-*-brief-*.complete` files from `.claude/.state/`)

### Task Contract Lifecycle

Decision 0020. Task contracts persist the brief's intent as a lightweight YAML artifact for cohesion review reference. Two lifecycle scopes:

- **Task-scoped** (singular builds): Written to `.claude/.state/task-contract.yaml` at session init by Prompt B. Cleaned at session close by `cleanup_session()` (same as other session-scoped state files). If `task-contract.yaml` already exists at session start (orphan from crashed session), delete it before writing the new one.

- **Group-scoped** (task groups): The `intent:` block lives in the task group contract YAML. Written by each brief at `contract-init` phase from Prompt T output. The `intent:` block persists in the contract as part of the group's governance record — it is not deleted at close. Each brief updates its own `intent:` fields during `contract-init`; the final contract captures the last brief's intent alongside accumulated governance evidence.

At cohesion review, the Orchestrator reads the task contract and passes its `verification:` criteria to Critic alongside the diff. Critic evaluates each criterion as VERIFIED, UNVERIFIED, or INCONCLUSIVE (advisory — feeds into the cohesion brief, not a separate gate). Sessions without task contracts skip contract verification silently.

### Automation Sessions

Decision 0017. Optional headless runner infrastructure in `.claude/.automation/`. Disabled by default (`config.yaml` → `runner.enabled: false`). When enabled, runners process queued task briefs via `claude -p` with full governance parity.

**Runner lifecycle:**

1. **Dequeue** — pick oldest `approved` queue entry, acquire flock-based queue lock, transition to `running`, release lock
2. **Pre-launch** — create branch (or check out existing for task groups), register session, write `plan-approved` state file, pre-seed `.claude/.session-id`. Phase-state is agent-initiated: the agent calls `init_phase()` as its first Bash action (fast-exits branch-guard.sh — no redirect/tee). With fail-closed enforcement (Decision 0019), edits before `init_phase()` are blocked when the sentinel is present. Custom runners MUST ensure `init_phase()` is called before any Edit/Write tool use
3. **Launch** — invoke `claude -p` with `--disallowedTools` permission profile and assembled prompt (template-based or inline fallback). Decision cache entries (max 10) are prepended to the prompt. When the brief contains a `## Task Contract` block (Decision 0020), the runner includes it in the assembled prompt; the agent extracts and writes it during init
4. **Post-session** — detect outcome (completed/failed/review), perform external cleanup (solo merge, session registry, branch sealing — Stop hook does not fire in headless mode), transition queue entry

**Toggle semantics:**

| Method | Effect |
|--------|--------|
| `config.yaml` → `runner.enabled: false` | Daemon sleeps 30s between checks. Queued entries preserved |
| `config.yaml` → `runner.enabled: true` | Daemon processes queue normally |
| Create `.claude/.automation/HALT` file | Daemon exits immediately. Use for emergency stop |
| Remove `HALT` file | Daemon resumes on next start |

**Escalation:** When a headless session exits at an `operator`-tagged phase, the runner writes an escalation file (`.claude/.automation/escalations/`) and transitions the queue entry to `review` status. Nine escalation types: `gate-failure`, `governance-block`, `phase-tag-escalation`, `ambiguity`, `scope-exceeded`, `dependency-missing`, `security-risk`, `structural-change`, `scope-deviation`. The `scope-deviation` type includes `scope_classification` (briefed/unbriefed-in-scope/out-of-scope) and `risk_gain` context for operator review.

**Queue validation:** Before dequeue, entries are validated: required fields (id, session_type, status), session type against Decision 0014 enum (`get_phases_for_type` must return non-empty), brief content non-empty and max 50KB, branch name sanitized to `[a-zA-Z0-9/_-]` max 100 chars. External-source entries may require HMAC-SHA256 signature verification (opt-in via `hmac_secret` in runner config).

**Decision cache:** Two-level merge — project-level (`.claude/.automation/decision-cache.yaml`) and local-level (`.claude/.automation/local-decision-cache.yaml`). Local can extend or narrow enforcement, never elevate (cannot change REQUIRE to GUIDE). Merged output: max 10 entries, each formatted as `Decision NNNN: summary (MECHANISM)`, prepended to the assembled prompt.

**File locking:** `flock`-based exclusive lock on `.claude/.automation/.queue-lock`. 5-second timeout, fails with error. Lock scope: single queue state transition (not entire session). Callers wrap individual `_transition()` calls.

**Dev orchestrator:** Cross-brief health reports between task group briefs. Runner invokes after content brief completes and before merge brief starts. Uses the `audit` session type. Reports go to `.claude/.automation/reports/` (gitignored). See `.claude/agents/dev-orchestrator.md`.

**Auto mode activation:** When the operator selects auto mode during plan approval for a task group session, the `plan-approval.sh` hook automatically queues remaining pending briefs from the task group contract, enables the runner (`config.yaml` → `runner.enabled: true`), and starts the daemon. Daemon output is logged to `.claude/.automation/logs/runner.log` (gitignored). Briefs are queued with `auto_mode: true` and `solo_mode: true` (final brief only). The current session continues interactively; subsequent briefs execute headlessly via the runner. Idempotent: briefs already in the queue (pending-review, approved, or running) are skipped. Brief content convention: `.claude/.automation/briefs/{group-name}/brief-{N}.md` — if pre-populated by the operator, the prompt assembler reads them; otherwise sessions receive governance context and contract metadata via the taskgroup-brief template. Activation requires the automation layer to be installed (config.yaml must exist). Standalone (non-task-group) auto mode sessions are unaffected.

**Circuit breaker:** 3 consecutive global failures pause the daemon (60s sleep between checks). Reset on first success.

**Intake CLI:** Standalone entry point for queue entry creation without the interactive bridge (`plan-approval.sh`). Usage: `.claude/.automation/lib/intake.sh --brief <path> [--auto-approve] [--session-type <type>] [--solo] [--push]`. Auto-enables the runner (`config.yaml` → `runner.enabled: true`) when entries are added. Accepts brief path, session type (Decision 0014 enum), auto-approve (place directly in `approved/`), solo mode, and push-on-complete flags.

**push_on_complete:** Per-entry opt-in flag for branch push after session completion. When `push_on_complete: true` in the queue entry: solo sessions push main after merge, non-solo sessions push the feature branch. Push is advisory — failure warns but does not block. Enabled via `--push` flag in intake CLI or `push_on_complete` field in queue entry YAML.

**Scope classification:** The pre-commit gate (`pre-commit-gates.sh`) classifies staged files against the task contract's `scope_files` list at commit time. Three categories: **briefed** (exact match — no action), **unbriefed-in-scope** (parent directory matches a scope file's parent — advisory escalation with risk/gain context), **out-of-scope** (no match — blocking, commit denied). The agent populates risk/gain context via `.claude/.state/scope-risk-gain` state file before commit. Escalation files are written to `.claude/.automation/escalations/` for runner integration. Classification is path-based (deterministic, no LLM). See Decision 0017 § Scope Classification Model.

**PermissionRequest hook:** The `permission-request.sh` hook (wired to the `PermissionRequest` event in `settings.json`) auto-approves curated tools and Bash commands, denies dangerous patterns, and falls through to the VS Code dialog for unknown commands. Every request is logged to `.claude/.automation/logs/permission-audit.log` (gitignored, append-only). Deny list has priority over allow list (fail-safe). Does not fire in `claude -p` mode — headless sessions use `--disallowedTools` profiles instead. See Decision 0017 § PermissionRequest Hook.

**AskUserQuestion deny hook:** The `ask-user-deny.sh` PreToolUse hook blocks `AskUserQuestion` in headless automation mode when `CLAUDE_HEADLESS=1` is set (by `runner.sh`). Defense-in-depth alongside `--disallowedTools`. Interactive sessions pass through unaffected. Blocked sessions are instructed to write escalation files instead.

### Governance Layers

Three mechanical governance layers enforce process integrity:

1. **Inter-session pipeline** (`docs/ai/governance/`): Committed evidence files proving Prompt 0 (`spec-compiled`) and Prompt A (`advisory-reviewed`) completed. Written by the model at prompt completion. Read by Prompt B at session start. Verified by `branch-guard.sh` on first Bash write and by `pre-commit-gates.sh` at commit-time (both advisory, first-fire).

2. **Phase chain governance** (task group `governance:` section): Per-brief gate evidence in the task group contract. Written by the model at session close. Verified by `session-close-check.sh` at session close (advisory). Enables sequential integrity — Brief N+1 can confirm Brief N completed with passing gates.

3. **Override audit** (`.claude/.state/overrides.log`): Session-scoped log of all governance override env vars used. Written by `log_override()` in `_analytics-helper.sh`. Summarized by `session-close-check.sh` at session end. Cleaned at session close.

**Override scoping recommendation:** Prefer `VAR=value command` over `export VAR` when applying governance overrides. The inline pattern scopes the override to a single command invocation; `export` persists for the entire session, which risks accidentally bypassing governance for subsequent operations. Example: `SKIP_SESSION_LOG=1 git commit -m "..."` rather than `export SKIP_SESSION_LOG=1` followed by separate commands.

State files in `.claude/.state/` are cleaned at session close to prevent stale state from leaking across sessions.
