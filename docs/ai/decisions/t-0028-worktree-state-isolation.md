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

1. **`_REPO_OS_ROOT` always resolves to the main repo**: Derived from `BASH_SOURCE[0]` (the hook file's own location). Since hooks live at `.claude/hooks/` in the main repo and Claude Code registers them by absolute path in `settings.json`, `_REPO_OS_ROOT` points to the main repo root even when a hook fires inside a worktree subagent.

2. **State reads target the main session**: All `_phase-helper.sh` functions (`get_phase()`, `assert_phase()`, `_validate_phase_session()`) use `$_REPO_OS_ROOT/.claude/.state/phase-state`. In worktree context, hooks read the parent session's phase state. This is correct — worktree subagents do not have their own governance lifecycle.

3. **State writes target the main session**: `state-writer.sh` uses `get_repo_root()` to locate `.claude/.state/` and reads `STATE_SID` from the main repo's `.session-id`. A worktree governance agent's verdict would be written as if it were the main session's evidence, even though the agent reviewed code in the worktree (which may diverge from the main working tree).

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
None — the worktree guard is unconditional. If a worktree subagent's verdict needs to be recorded, re-dispatch the agent without worktree isolation.

## Supersedes
None. Addresses the deferred concern noted in Decision 0027 § Deferred Concerns.
