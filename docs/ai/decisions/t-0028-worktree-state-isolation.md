# Decision 0028 — Worktree State Isolation

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/hooks/(state-writer|_analytics-helper)\.sh`
- keywords: `is_worktree, worktree_blocked, _CACHED_IS_WORKTREE, git-common-dir`

## Decision
Harden the governance state boundary between worktree-isolated subagents and the parent session. When a governance agent runs inside a git worktree (spawned via `isolation: "worktree"` in the Agent tool), `state-writer.sh` refuses to write state files.

### Audit Findings

1. **`_REPO_OS_ROOT` in subagent worktrees (this decision's scope)**: For governance agents spawned with `isolation: "worktree"` from a session running in the main repo, the parent session's hooks fire with the main repo as CWD. `_REPO_OS_ROOT` (derived from `BASH_SOURCE[0]`) resolves to the main repo root. `state-writer.sh` uses `get_repo_root()` and therefore targets the main repo's `.claude/.state/`.

   **Correction for full worktree sessions (Decision 0030 scope, empirically established 2026-08-07)**: When Claude Code is launched directly inside a worktree (`(cd "$worktree_dir" && claude -p ...)`), hooks are registered via RELATIVE paths in `settings.json`, so `BASH_SOURCE[0]` resolves relative to the worktree CWD. In this case, `_REPO_OS_ROOT` = **worktree root**, not the main repo. The runner (which sources hooks via absolute paths) resolves to the main repo root; the agent hooks resolve to the worktree root. See Decision 0030 for the per-session state dir design that accounts for this.

2. **State reads target the main session (subagent scope)**: All `_phase-helper.sh` functions (`get_phase()`, `assert_phase()`, `_validate_phase_session()`) use `$_REPO_OS_ROOT/.claude/.state/phase-state`. In subagent worktree context (where `_REPO_OS_ROOT` = main repo), hooks read the parent session's phase state. This is correct — worktree subagents do not have their own governance lifecycle.

3. **State writes target the main session (subagent scope)**: `state-writer.sh` uses `get_repo_root()` to locate `.claude/.state/` and reads `STATE_SID` from the main repo's `.session-id`. A worktree governance agent's verdict would be written as if it were the main session's evidence, even though the agent reviewed code in the worktree (which may diverge from the main working tree).

### Implementation

1. **`is_worktree()` helper** in `_analytics-helper.sh`: Compares `git rev-parse --git-dir` vs `git rev-parse --git-common-dir`. If they differ, the CWD is in a worktree. Cached per-process (`_CACHED_IS_WORKTREE`). Requires git 2.5+ (released 2015).

2. **`state-writer.sh` worktree guard**: After sourcing libraries and before the state file mapping, checks `is_worktree()`. If true, logs an audit event (`worktree_blocked` reason code) and exits 0 (never blocks — consistent with state-writer's non-blocking design).

3. **State reads unchanged**: Phase-state reads in `write-guard.sh`, `bash-guard.sh`, and other hooks continue to read the main session's state in worktree context. This is intentional — worktree subagents operate under the parent session's governance.

## Implication
Governance agents (critic, qa-verifier, reviewer, security-privacy, pragmatist) dispatched with `isolation: "worktree"` will not produce state files. If governance evidence is needed, the parent session must re-dispatch the agent without worktree isolation.

## Alternatives Considered

1. **Full state isolation per worktree**: Create a separate `.claude/.state/` in each worktree with its own session ID and phase tracking. Rejected — worktree subagents are short-lived and do not have their own governance lifecycle. They operate under the parent session's governance.

2. **Disable worktree isolation entirely**: Remove `isolation: "worktree"` from all agent definitions. Rejected — worktree isolation has legitimate uses for parallel non-conflicting work (e.g., read-only exploration agents).

3. **Write to a worktree-scoped state directory**: State files written to a separate directory that the parent session's pre-commit gates do not read. Rejected — adds complexity without benefit. The simpler approach (refuse writes) is correct because worktree agent verdicts should not serve as governance evidence for the main working tree.

## Relationship to Decision 0027
Decision 0027 (Agent Tool Governance Gate) is the primary defense — it prevents write-capable subagents from being spawned in no-write sessions. This decision hardens a secondary attack surface: even in write-capable sessions where governance agents are legitimately dispatched, worktree isolation must not produce governance evidence based on divergent code.

## Override
None — the worktree guard is unconditional for subagent worktrees. If a worktree subagent's verdict needs to be recorded, re-dispatch the agent without worktree isolation.

**Note**: Decision 0030 supersedes this decision **for full worktree sessions** (`claude --worktree` with `REPO_OS_SESSION_ID` set). The subagent worktree block defined here remains in effect.

## Gitignored Governance Path Disposition Table (Amendment — 2026-08-07)

For each gitignored governance path, the correct disposition in worktree sessions:

| Path | Disposition | Rationale |
|------|-------------|-----------|
| `.claude/repo-mode` | **Propagate** | Copied by `runner.sh` at worktree creation (`4bce973`). Small, session-invariant, must exist before session starts. Verified effective. |
| `.claude/.state/wt-sessions/{sid}/` | **Worktree-local** | Per-session phase state created by `init_phase()` in the worktree. Correct per Decision 0030. Runner and agent must target the same root — see runner.sh mitigation note. |
| `.claude/local/handoff-bundles/` | **Resolve to main** | Bundles written by Prompt T in the main-repo context (runner). `_handoff_bundle_path()` now uses `get_main_repo_root()` so Prompt B in a worktree can find bundles. Missing bundle now emits a loud WARNING rather than silently returning a wrong path. |
| `.claude/local/known-issues.md` | **Drop** | Gitignored canonical = invisible in worktrees and git history. Consolidated to `docs/ai/logs/known-issues.md` (tracked). The `.claude/local/known-issues.md` is now a deprecation pointer. `AI.md` updated to remove the template-mode override convention. |
| `.claude/local/sessions/` | **Drop** | Same reason. `AI.md` now points to `docs/ai/logs/sessions/` unconditionally (no template-mode override). MEMORY.md already reflects this for worktree sessions. |
| `.claude/.automation/escalations/` | **Resolve to main** | Daemon reads escalations from the main repo. Agents in worktree sessions should write escalations to the main repo path: `$(get_main_repo_root)/.claude/.automation/escalations/`. The Escalation Protocol in session prompt docs should be updated to use `get_main_repo_root()`. |
| `.claude/.automation/queue/` | **Resolve to main** | Runner manages queue in the main repo. Worktree agents do not write to the queue directly; no change needed. |

### Loud-failure Pattern

Where a canonical governance file is expected and absent, prefer loud failure over silent fallback:
- `_handoff_bundle_path()` now prints a three-line WARNING when the bundle file is not found at the resolved path.
- Future additions should follow this pattern: emit `WARNING: <path> not found — <context hint>` to stderr, never silently substitute a different path.

## Supersedes
None. Addresses the deferred concern noted in Decision 0027 § Deferred Concerns.
