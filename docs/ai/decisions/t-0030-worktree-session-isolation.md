# Decision 0030 — Worktree Session Isolation

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/hooks/(state-writer|_analytics-helper|_phase-helper|session-close-check|_cleanup-helper)\.sh`
- keywords: `is_full_worktree_session, get_session_state_dir, REPO_OS_SESSION_ID, wt-sessions, merge-lock`

## Decision
Enable full independent Claude Code sessions running in git worktrees (`claude --worktree`) with per-session governance isolation and sequential merge coordination back to main. This supersedes Decision 0028 **for full worktree sessions only** — subagent worktree governance writes remain blocked.

### Discrimination: Full Worktree Sessions vs Subagent Worktrees

The key discriminator is the `REPO_OS_SESSION_ID` environment variable:

| Context | `is_worktree()` | `REPO_OS_SESSION_ID` | Treatment |
|---------|-----------------|---------------------|-----------|
| Normal session (main repo) | false | unset | Standard governance — flat `.claude/.state/` |
| Subagent worktree (`isolation: "worktree"`) | true | unset | Decision 0028 applies — state writes blocked |
| Full worktree session (`claude --worktree`) | true | set | Per-session state dir — independent governance |

`is_full_worktree_session()` returns true when both conditions hold.

### Per-Session State Directories

Full worktree sessions store governance state in `$_REPO_OS_ROOT/.claude/.state/wt-sessions/{sid}/` instead of the flat `.claude/.state/` directory. This prevents cross-session state file collisions. The `get_session_state_dir()` helper routes all state reads/writes to the correct directory.

State files stored per-session: `phase-state`, `plan-approved`, `cohesion-reviewed`, `qa-verified`, `reviewer-signed`, `security-signed`, `pragmatist-signed`, `overrides.log`, `merge-source-branch`, `.stop-attempt-count`, `scope-risk-gain`, `high-risk-detected`, `governance-checked`, `brief-has-taskgroup`.

### Session Identity

Full worktree sessions inject `REPO_OS_SESSION_ID` at launch. `get_session_id()` checks this env var first, bypassing the `.session-id` file entirely. This avoids file races when multiple sessions share `_REPO_OS_ROOT` (which always resolves to the main repo via `BASH_SOURCE[0]`).

### Session Registry

The shared session registry (`.claude/.state/sessions/{sid}.yaml`) gains a `worktree_path` field for full worktree sessions. Overlap detection, stale-PID cleanup, and branch isolation checks continue to operate across all session types.

### Merge Coordination

Full worktree sessions cannot `git checkout main` (protected by git — main is checked out in the main worktree). Instead, they use `git -C <main-repo>` to run merge commands in the main repo context.

Concurrent merge serialization uses `flock` (with `mkdir` fallback) on `.claude/.state/.merge-lock`. The `record_closed_branch()` function uses a separate lock on `.claude/.state/.closed-branches-lock` for atomic append.

### Backward Compatibility

When `REPO_OS_SESSION_ID` is not set, `get_session_state_dir()` returns the flat `.claude/.state/` directory. No behavioral change for single-session repos or non-worktree sessions.

## Implication
- `state-writer.sh` allows governance writes for full worktree sessions while continuing to block subagent worktrees
- All phase-state functions route through `get_session_state_dir()` for state file paths
- `session-close-check.sh` solo merge path uses `git -C` for worktree sessions with merge lock serialization
- `runner.sh` `_solo_merge_if_needed()` gains the same worktree-aware merge path
- `record_closed_branch()` uses file locking for concurrent safety

## Supersedes
Decision 0028 **for full worktree sessions only**. Decision 0028 remains in effect for subagent worktrees — the `is_worktree() && !is_full_worktree_session()` guard preserves the subagent block.

## Override
`REPO_OS_SESSION_ID` — set by the worktree session launcher. Must not be set manually for subagent contexts.
