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
| Normal session (main repo) | false | unset | Per-session state dir — independent governance |
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

All session types now route to per-session state directories (`wt-sessions/{sid}/`). When a per-session directory does not exist but a flat `.claude/.state/phase-state` contains a matching session ID, the flat directory is used (pre-migration backward compatibility — valid for that session only). New sessions always create per-session directories via `init_phase()`.

### Cross-Session Markers

Task group completion markers (`tg-*-brief-*.complete`) are inherently cross-session — written by content brief sessions and read by merge briefs and cohesion triggers. Helper functions `count_cross_session_markers()` and `clean_cross_session_markers()` scan all per-session directories (and the flat directory for backward compat) to find and clean markers.

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

## Worktree Ref-Move Invariant (Amendment — 2026-08-07)

**A worktree session MUST NEVER move a branch ref that is checked out in another worktree.**

Specifically, the following commands are prohibited from a worktree when the target branch is `main` (which is always checked out in the main worktree):

- `git branch -f main <ref>` / `git branch --force main <ref>`
- `git checkout -B main`
- `git update-ref refs/heads/main <ref>`
- `git fetch . <ref>:main`

### Why this is fatal

When `main` is moved by a ref-update (not a `git checkout` or `git merge` that updates the worktree), only the commit pointer changes. The main working tree's index and content remain frozen at the prior state. `git status` on main then shows staged reverts of the newly-merged work, and the merged code is absent from disk — indistinguishable from a deliberate staged revert. This caused merged governance code to be silently inactive.

### Correct close path for worktree sessions

Worktree sessions should use one of:

1. **Let the stop hook merge** (preferred for solo sessions): `session-close-check.sh` merges via `git -C <main-repo> merge` and syncs the main working tree. Call `write_merge_signal '<branch>'` to signal that the agent close phase is done and skip a redundant runner merge.

2. **Runner merge**: `runner.sh::_solo_merge_if_needed()` merges via `git -C <main-repo> merge` with unconditional post-merge sync and stale-tree verification.

Both paths run `git reset HEAD -- . && git checkout -- .` on the main repo after every merge (real or apparent) and verify via `git diff HEAD --quiet`. A stale result writes a `gate-failure` escalation.

### Mechanical enforcement

`bash-guard.sh` Phase 1e blocks the ref-move commands listed above with `GATE-RECOVERABLE` when the caller's `git rev-parse --git-dir` path contains `"worktrees"`. Recovery bypass: `REPO_OS_RECOVER=1`.
