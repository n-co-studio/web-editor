# Decision 0004 — Mechanical Enforcement Layer

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/hooks/.*\.sh`
- path: `\.claude/settings\.json`
- keywords: `PreToolUse, PostToolUse, SubagentStop, Stop, phase-state, _phase-helper`

## Context
Prompt-only governance relies on the model's compliance — it can drift, forget, or misinterpret rules. Mechanical enforcement via hooks and frontmatter makes governance violations structurally impossible rather than merely discouraged. This is the enforcement backbone that all other decisions depend on.

## Decision
Enforce Repo OS mechanically using Claude Code native features:
1. **Subagent frontmatter**: Invocable agents (Builder, QA, Reviewer, Security, A11y) declare `tools`/`disallowedTools` in YAML frontmatter → runtime-enforced tool boundaries
2. **Subagent frontmatter hooks**: Builder, QA, and Security declare `PreToolUse` hooks in frontmatter → `agent-git-guard.sh` blocks `git commit` and `git push` commands (exit 2) while allowing other Bash usage. Note: `agent-git-guard.sh` is intentionally wired via frontmatter only — not registered in `settings.json` — because it targets subagent dispatch specifically. The architectural asymmetry (settings.json hooks apply to the main agent context; frontmatter hooks apply to subagent contexts) is a conscious design choice ensuring commit/push restrictions only affect subagents while leaving the Orchestrator free to commit
3. **Orchestrator exception**: Orchestrator + shared files (`_agent-glossary.md`, `_agent-workflow.md`) have no frontmatter — behavioral references only. Orchestrator is the only agent permitted to commit/push
4. **Team settings**: `.claude/settings.json` (committed) defines permissions + hooks. Personal overrides in `.claude/settings.local.json` (gitignored)
5. **Hooks** (`.claude/hooks/`):
   - `PreToolUse` on Edit/Write → `write-guard.sh` Section 3: branch-guard gates for file modifications — blocks edits on `main` (Gate 1), blocks edits in init/plan phase (Gate 2), session overlap check (Gate 6, Decision 0013 — blocks concurrent non-task-group sessions on same branch; advisory for task groups; exempt: Prompt T), and blocks edits on branches closed by a previous session (Gate 5, Decision 0013). Task group non-final briefs never seal the branch, so no exemption logic needed at Gate 5. Override: `REPO_OS_ALLOW_MAIN=1` (Gate 1), `REPO_OS_SKIP_OVERLAP_CHECK=1` (Gate 6), `REPO_OS_SKIP_BRANCH_REUSE=1` (Gate 5), `REPO_OS_RECOVER=1` (bypass all)
   - `PreToolUse` on Bash → `bash-guard.sh`: consolidated Bash PreToolUse hook (Phase 3a). State-guard, mode-guard, fail-closed phase enforcement (Decision 0019), task group merge protection (Gate 7, Decision 0018), blocks file modifications on `main` (Gate 1), blocks edits without approved plan (Gate 2, phase-state assertion), session overlap check (Gate 6, Decision 0013 — blocks concurrent non-task-group sessions on same branch; advisory for task groups; exempt: Prompt T), session branch isolation (Gate 5, blocking, Decision 0013). Ephemeral session fast-exit (Phase 3b). Only evaluates branch-guard gates when redirect (`>`, `>>`) or `tee` write targets resolve to in-repo paths; Bash commands without write targets fast-exit with no gate evaluation. Override: `REPO_OS_ALLOW_MAIN=1` (Gate 1), `REPO_OS_SKIP_PLAN_GATE=1` (Gate 2), `REPO_OS_SKIP_OVERLAP_CHECK=1` (Gate 6), `REPO_OS_SKIP_BRANCH_REUSE=1` (Gate 5), `REPO_OS_SKIP_MERGE_GUARD=1` (Gate 7). Experiment branches exempt from plan gate (Decision 0006)
   - `PreToolUse` on `git commit` → `pre-commit-gates.sh`: A4 secret scanning (blocks), state file verification (blocks — requires `plan-approved`, `cohesion-reviewed`, `qa-verified`; plan-approved skippable via `REPO_OS_SKIP_PLAN_GATE=1`), inter-session governance check (Gate 3, advisory — warns if `docs/ai/governance/spec-compiled` or `advisory-reviewed` missing on `feature/*`/`fix/*`/`hotfix/*`/`release/*` branches; first-fire), A2 scope >100 lines (blocks unless `large-scope: true` in plan-approved), A6 task group contract staging (blocks), high-risk pattern detection (blocks — requires `reviewer-signed` + `security-signed` when risk patterns match), A1 decision trigger parser (blocking — enforced by `docs/ai/decisions/.a1-triggers-enforced` sentinel; triggered decisions must be declared in `Decisions:` git trailer). Override: `SKIP_CONTRACT_CHECK=1`, `REPO_OS_SKIP_PLAN_GATE=1`, `REPO_OS_RECOVER=1` (skip all state checks). Experiment branches: A4 only. Hotfix branches: A2 enforced uniformly (large-scope: true in plan-approved satisfies it — headless sessions get this automatically via `_headless-plan-approve.sh`; interactive hotfix sessions have an approval phase to obtain it); cohesion-reviewed skipped (A5 session-type check: hotfix phase sequence has no review phase)
   - `PreToolUse` on `git push` → `pre-push-gates.sh`: B1 branch naming convention (blocks), stubs for B2/B3 project-specific checks (blocking when uncommented). Override: `REPO_OS_RECOVER=1`. Projects add test/typecheck/audit checks
   - `PostToolUse` on AskUserQuestion → `plan-approval.sh`: captures operator plan approvals as state. Writes `.claude/.state/plan-approved` when operator confirms a plan via AskUserQuestion (question contains "plan" + confirmation language + affirmative answer). Never blocks (PostToolUse). Override: `REPO_OS_SKIP_PLAN_GATE=1` (on bash-guard Bash and pre-commit-gates side)
   - `PostToolUse`/`PostToolUseFailure` on Bash → `hvst-failure-tracker.sh`: HVST failure tracking
   - `Stop` → `session-close-check.sh`: uses `stop_hook_active` for retry detection (Phase 1b — retries skip advisory checks, run only previously-blocking checks), JSON stdout output (Phase 2a — `decision`/`reason`/`systemMessage` replaces exit 2 + stderr), session weight detection (zero-change sessions downgrade to advisory). Blocking checks: session log update, uncommitted changes. Advisory checks: HVST known-issues (downgraded from blocking in Phase 2b — `known-issues.md` reminder when `hvst-fail-count` >= 2), deferrals known-issues (downgraded from blocking in Phase 2b — reminder when `.deferrals-pending` exists), override audit summary, governance evidence verification for task groups, task group next-brief reminder. Solo merge path: when `solo=true`, merges feature/fix/hotfix branches directly to main (ff-only preferred, fallback --no-ff). Task group branch lifecycle: non-final briefs skip branch seal; final brief seals branch. Session-scoped state cleanup (removes all `.claude/.state/` files + `.deferrals-pending` + `.stop-attempt-count`). Override: `SKIP_SESSION_LOG=1`, `SKIP_UNCOMMITTED_CHECK=1`, `SKIP_CONTRACT_CHECK=1`, `SKIP_KNOWN_ISSUES_CHECK=1`
   - `PreToolUse` on Edit/Write/Bash → `write-guard.sh`: unified state + mode enforcement. Section 1 (state-guard): blocks model writes to `.claude/.state/` — Edit/Write check `file_path`; Bash checks extracted write targets (`>`, `>>`, `tee`) not raw substring. Only governance hooks can write state files via shell I/O. Override: `REPO_OS_SKIP_STATE_GUARD=1` (skip guard), `REPO_OS_RECOVER=1` (allow recovery writes). Section 2 (mode-guard): blocks file modifications outside active mode scope (Decision 0012). Three modes: `template` (governance only), `child` (product + limited governance carve-outs), `autonomous` (product + minimal governance). Fast-exit for non-template modes after immune path check. Template mode retains full edit-time enforcement. Immune paths: `write-guard.sh`, `repo-mode` (enforced in all modes, no override). Override: `REPO_OS_SKIP_MODE_GUARD=1` (skip), `REPO_OS_UNLOCK_PATH=<path>` (single-file unlock)
   - `SubagentStop` → `state-writer.sh`: captures governance agent verdicts (critic, qa-verifier, reviewer, security-privacy) as state files in `.claude/.state/`. Extracts `GATE_RESULT:` sentinel from agent output. Never blocks (always exit 0)
6. Extends Decision 0003 — frontmatter is required for invocable agents
7. **State directory** (`.claude/.state/`): session-scoped state files written by governance hooks via shell I/O. Gitignored except `.gitkeep`. Files: `plan-approved` (written by `plan-approval.sh`), `cohesion-reviewed`, `qa-verified`, `reviewer-signed`, `security-signed` (written by `state-writer.sh`), `high-risk-detected` (written by `pre-commit-gates.sh` when risk patterns match staged files), `governance-checked` (written by `pre-commit-gates.sh` Gate 3 on commit, first-fire marker), `overrides.log` (written by `_analytics-helper.sh` `log_override()`, append-only). `sessions/` subdirectory: per-session YAML files for concurrent session tracking (written by `register_session()` at `init_phase()`, cleaned by `unregister_session()` at session close). Format varies: `plan-approved` uses `timestamp/question_hash/large-scope`; verdict files use `timestamp/agent/GATE_RESULT`; `high-risk-detected` uses `timestamp/reason`; first-fire marker contains `"checked"`; `overrides.log` uses `timestamp hook env_var` per line; session YAML uses `session_id/session_type/branch/pid/started_at`. Session ID binding (`_validate_state_session_id` in `pre-commit-gates.sh`) rejects state files whose embedded `session_id` does not match the current session — this is the defense against stale state files leaking from prior sessions or forged files planted by earlier processes
8. **Sentinel protocol**: governance-relevant agents (Critic cohesion mode, QA, Reviewer, Security) MUST emit `GATE_RESULT: APPROVED` or `GATE_RESULT: BLOCKED reason="..."` as their final output line — machine-parsed by `state-writer.sh`
9. **Inter-session governance** (`docs/ai/governance/`): committed evidence files proving Prompt 0 (`spec-compiled`) and Prompt A (`advisory-reviewed`) completed. Written by model at prompt close. Verified by `bash-guard.sh` Gate 3 on Bash writes and by `pre-commit-gates.sh` Gate 3 at commit-time (both advisory, first-fire). Read by Prompt B at session start
10. **Phase chain governance**: `governance:` section in task group contracts tracking per-brief gate evidence (A1-A6, B1-B3, overrides). Written by model at session close. Verified by `session-close-check.sh` at session close (advisory)
11. **Override audit**: `log_override()` in `_analytics-helper.sh` appends to `.claude/.state/overrides.log` on every override env var activation. `session-close-check.sh` summarizes at session end (safety valve fires are now auditable — Phase 1d). Override-capable hooks: `write-guard.sh`, `bash-guard.sh`, `pre-commit-gates.sh`, `pre-push-gates.sh`, `session-close-check.sh`
12. **Session-scoped state cleanup**: `session-close-check.sh` removes all `.claude/.state/` files (except `.gitkeep`) at session close, preventing stale state from leaking to the next session
13. **Phase-aware flow management** (Decision 0014): `_phase-helper.sh` (sourced helper, not standalone hook) provides `init_phase`, `advance_phase`, `assert_phase`, `get_phase`, `get_phase_mode`, `get_tag`, `get_solo`, `set_solo`, `set_phase_mode`. State tracked in `.claude/.state/phase-state` (session-scoped). Phase-state writes use shell I/O (bypasses `write-guard.sh`). Session ID binding prevents stale state. `write-guard.sh` Section 3 Gate 2 uses phase assertions to block edits in init/plan phases
14. **Solo mode merge** (Decision 0015): `session-close-check.sh` merges `feature/*`/`fix/*`/`hotfix/*` branches directly to main when `solo=true` in phase-state. FF-only preferred, fallback `--no-ff`. Merge failure triggers `git merge --abort` and operator notification. `experiment/*` and `release/*` excluded

## Consequences
- `.claude/hooks/` contains the enforcement scripts; `.claude/settings.json` wires them to Claude Code lifecycle events
- `.claude/.state/` is the session-scoped state directory — hooks communicate through state files, cleaned at session close
- All subsequent decisions (0005–0016) that add enforcement behavior do so by extending this hook infrastructure rather than introducing parallel mechanisms
- The sentinel protocol (`GATE_RESULT:`) creates a machine-readable contract between governance agents and the state-writer hook

## Amendment — A BLOCKED QA Verdict Blocks the Commit (2026-10-25)

**Status:** Accepted

§8 requires governance agents to emit `GATE_RESULT: APPROVED` or
`GATE_RESULT: BLOCKED reason="..."`, and names QA among them. The commit gate
honoured that for the Critic's verdicts and not for QA's: `cohesion-reviewed`
and `diff-review-complete` blocked on BLOCKED, while `qa-verified` was checked
only for existence, a matching `session_id` and a non-empty `dispatch_phase` —
all of which a BLOCKED verdict satisfies.

So a commit could land carrying its own QA verdict recording that it should not
have. Encountered live on 2026-10-24: `qa-verified` read BLOCKED over four
unresolved gate items and the gate would have allowed the commit. The session
re-dispatched QA instead of using it, but nothing mechanical required that.

**`GATE_RESULT: BLOCKED` in `qa-verified` now blocks**, matching the Critic
half. No session-type skip accompanies it: unlike A5's `_A5_SKIP`, `qa-verified`
is required on every non-experiment branch, so no session type legitimately
commits over a blocked QA verdict. `REPO_OS_RECOVER=1` remains the documented
emergency path.

This was an omission rather than a decision — `state-writer.sh` documents
BLOCKED as looping back to build, `qa-verifier.md` defines it as a refusal, and
no decision authorised committing over one. `quality-gates.md` recorded
"`GATE_RESULT: BLOCKED` is now blocking" for `cohesion-reviewed` only, which was
the clearest symptom that the QA half had simply never been written.
