# Decision 0036 — Daemon-Safe Branching

## Status
Accepted

## Triggers

- type: file
- path: `.claude/.automation/runner.sh`
- path: `.claude/.automation/lib/`
- path: `.claude/hooks/bash-guard.sh`
- keywords: `daemon, branch switch, git checkout, git switch, git reset --hard, runner, worktree isolation, hotfix, daemon-pid`

## Decision

The main working tree MUST NOT change branches while the automation daemon is running. Branch switches on the main working tree while the daemon is active corrupt in-flight sessions: the daemon sources `_phase-helper.sh`, `runner.sh`, and other governance files from `$REPO_ROOT`. Switching branches replaces these files mid-execution, causing crashes and data loss.

### Rule

- BLOCK: `git checkout <branch>`, `git checkout -b <branch>` (create-and-switch), `git switch <branch>`, `git switch -c <branch>` (create-and-switch), and `git reset --hard` on the main working tree when the daemon is active (detected via `.claude/.automation/.daemon-pid` or `pgrep -f "runner.sh --daemon"`)
- EXEMPT: `git checkout -- <file>` (file restores, not branch switches)
- EXEMPT: commands run from within a worktree context (git dir contains `worktrees`)

### Rationale

During a manual hotfix session, `git checkout -b` and `git checkout main` were run while the daemon (PID 9509) was actively processing a brief. The branch switches caused the daemon's in-flight session to crash (`failed:crash`) with zero commits — all work was lost. The entry had to be manually recovered.

Root cause: nothing in the governance layer or hook chain prevented branch switches when the daemon was active. The Prompt H hotfix workflow did not require daemon-awareness, and `bash-guard.sh` did not intercept `git checkout` or `git switch`.

### Enforcement

Two enforcement layers:

1. **Hook guard (`bash-guard.sh` Phase 1c):** Detects `git checkout`, `git switch`, and `git reset --hard` commands. Checks for an active daemon via PID file at `.claude/.automation/.daemon-pid` (no subprocess needed) with `pgrep -f "runner.sh --daemon"` fallback. If daemon is active, emits `GATE-RECOVERABLE` and blocks.

2. **Prompt rule (prompt-h-hotfix-debug.md):** REQUIRE rule instructs hotfix session facilitators to check for a running daemon before creating a hotfix branch, and to halt the daemon or use worktree isolation if one is found.

### Approved Alternatives

When a branch switch is needed while the daemon is running, use one of these options:

- **(a) Halt the daemon first:** `queue-cli.sh halt` stops the daemon cleanly. Branch switch can proceed once halted.
- **(b) Use a worktree for the interactive session:** `git worktree add .worktrees/<name> <branch>` — the worktree has its own HEAD and does not affect the main tree.
- **(c) Use `claude --worktree` for the interactive session:** Creates a worktree-isolated Claude session that does not interfere with the main working tree.

## Risks Accepted

1. **PID file staleness:** If the daemon crashes without cleaning up `.daemon-pid`, the guard may block unnecessarily. Mitigated by: `kill -0` liveness check against the stored PID before blocking.
2. **`pgrep` unavailability:** Some environments may not have `pgrep`. Mitigated by: PID file check runs first; `pgrep` is only the fallback. If both are unavailable, the guard is silent (no false blocks).
3. **Worktree context detection gap:** Commands using `git -C <path> checkout` that target the main tree from an external path will not be detected by the git-dir check. Accepted: this is an adversarial-only edge case.
