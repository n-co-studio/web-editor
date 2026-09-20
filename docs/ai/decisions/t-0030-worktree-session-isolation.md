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

**Amended 2026-08-31:** The original implementation used `REPO_OS_SESSION_ID` as the sole discriminator between full worktree sessions and subagent worktrees. This was insufficient: sessions launched via the harness `EnterWorktree` tool do not inject `REPO_OS_SESSION_ID`, so they were misclassified as subagent worktrees, and their governance verdicts were silently discarded. See Decision 0030 § Amendment 2026-08-31 below.

The correct discriminator is **session identity** — specifically, whether `init_phase` was called in this worktree context. A full worktree session always calls `init_phase`, which creates `phase-state` in the resolved state dir. A subagent worktree (spawned into a fresh worktree by the Agent tool) never calls `init_phase`, so no `phase-state` exists.

`is_full_worktree_session()` uses two signals (either suffices):

| Signal | Mechanism | Covers |
|--------|-----------|--------|
| `REPO_OS_SESSION_ID` env var set | Set by `claude --worktree` launcher | Legacy `claude --worktree` path (backward compat) |
| `phase-state` file in resolved state dir | Written by `init_phase` at session start | Sessions launched via `EnterWorktree` (harness tool) |

| Context | `is_worktree()` | `REPO_OS_SESSION_ID` | `phase-state` in state dir | Treatment |
|---------|-----------------|---------------------|---------------------------|-----------|
| Normal session (main repo) | false | unset | n/a | `is_worktree()` false — normal governance |
| Subagent worktree (`isolation: "worktree"`) | true | unset | absent (no init_phase) | Decision 0028 applies — state writes blocked |
| Full worktree session (`claude --worktree`) | true | set | present | Per-session state dir — independent governance |
| Full worktree session (`EnterWorktree`) | true | unset | present (init_phase ran) | Per-session state dir — independent governance |

`is_full_worktree_session()` returns true when `is_worktree()` is true AND either `REPO_OS_SESSION_ID` is set OR `phase-state` exists in the resolved state dir.

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

## Amendment — 2026-08-31: EnterWorktree Detection Gap

### Problem

`is_full_worktree_session()` originally tested only `is_worktree() && [ -n "${REPO_OS_SESSION_ID:-}" ]`. The `REPO_OS_SESSION_ID` env var is set by `claude --worktree` but NOT by the harness `EnterWorktree` tool. Sessions launched via `EnterWorktree` are legitimate full worktree sessions (they call `init_phase`, manage their own governance lifecycle, and produce real verdicts), but were being misclassified as subagent worktrees.

The effect: `state-writer.sh:48` (`if is_worktree && ! is_full_worktree_session`) discarded all verdicts from `EnterWorktree` sessions — `pragmatist-signed`, `cohesion-reviewed`, `diff-review-complete`, and `qa-verified` were never written. Governance evidence existed only in prose session logs, defeating the purpose of mechanical state files.

Observed in three consecutive sessions in child repo `markpreston.co` (8969e3a8, b8ad0ab0, 3bd3c950). Each required a `.recover-signal` file with verdicts quoted in the session log to unblock commits.

### Root Cause

The detection tested **launch method** (env var injected at launch), not **session identity** (whether the session has an independent governance lifecycle). Launch method is not session identity.

The env var cannot be set from inside a running session: hooks execute in the Claude Code process, not in the session's Bash child, so an `ENV=1 command` prefix never reaches them.

### Fix

`is_full_worktree_session()` now uses two signals (either suffices):

1. **`REPO_OS_SESSION_ID`** — preserved as primary signal for `claude --worktree` sessions (backward compatible).
2. **`phase-state` file in resolved state dir** — written by `init_phase` at session start. A subagent worktree (Agent tool, `isolation: "worktree"`) spawns a fresh worktree and never calls `init_phase`, so no `phase-state` exists in `_REPO_OS_ROOT/.claude/.state/wt-sessions/{sid}/`. An `EnterWorktree` session calls `init_phase`, so the file exists.

### Invariant Preserved

The Decision 0028 protection (subagent worktrees must not write governance verdicts) is preserved: subagent worktrees have no `phase-state` in their `_REPO_OS_ROOT`-rooted state dir (they run in a fresh worktree, `init_phase` is never called there), so `is_full_worktree_session()` correctly returns false for them.

### Files Changed

- `.claude/hooks/_analytics-helper.sh` — `is_full_worktree_session()` updated
- `.claude/hooks/tests/layer1c-worktree-functions.sh` — two new test cases added (L1c.2)
- `docs/ai/decisions/t-0030-worktree-session-isolation.md` — this amendment
