# Session Type: Task Definition

Prompt T facilitates exploration and task planning without producing file artifacts. Two modes:
- **Query**: Conversational Q&A grounded in specs and codebase. No agent dispatch.
- **Brief**: 4-agent team (Architect, Exploration, Critic, Pragmatist) plus conditional PM produces a structured task brief for Prompt B.

Task definition sessions are ephemeral — no files written (except optional queue intake), no session log entries. Query mode has no gates. Brief mode has one gate: the `approval` phase requires operator approval before advancing to `output` (Decision 0029 — enforced via `plan-approved` state file). The output is a terminal-displayed task brief the operator copy-pastes into a new Prompt B session. See `docs/ai/prompts/prompt-t-task-definition.md` for full details.

**Draft mode (Decision t-0067).** With `REPO_OS_TASKDEF_DRAFT=1` (Massimo) or the Step 4 option *Draft to queue*, the brief is queued as a `pending-review` entry right after synthesis (`queue-cli.sh add` without `--auto-approve`, no daemon start), bound to the session with `record_draft`, and revised in place. Approval comes from outside the session — `queue-cli.sh approve <id> [--mode review|auto]`, or `approve-wo <wo-id>` for a task group, approved together — and `accept_draft_approval` turns it into `plan-approved` (`source: queue-draft`, mode from the entries' `auto_mode`), moving the session to `output`. Removing the entry (`queue-cli.sh remove <id>`) ends the session: `discard_draft` deletes the draft's brief, sidecar contract and bundle files. The session cannot approve its own draft (`bash-guard.sh`), and brief files may be written only in `synthesize` and `output` (`write-guard.sh`).

## Phase Initialization (Required)

Task definition sessions MUST call `init_phase` at session start with the appropriate session type:

- **Query mode**: `init_phase 'taskdef-query'`
- **Brief mode**: `init_phase 'taskdef-brief'`

Each mode has its own phase sequence in `_phase-helper.sh` — `taskdef-query` and `taskdef-brief` are distinct session types. If the mode is ambiguous at session start, initialize as `taskdef-query`; if the operator later selects Brief, re-initialize with `REPO_OS_ALLOW_REINIT=1` and `init_phase 'taskdef-brief'`.

This is required so that:
1. The stop hook identifies the session as ephemeral and skips blocking close checks (preventing false blocks from concurrent sessions with uncommitted changes — Decision 0013)
2. The `pretooluse-permission.sh` hook allows read-only agent dispatch in Brief mode (the hook is fail-closed without phase-state — Decision 0027)

Phase-state writes use shell I/O, which bypasses write-guard (Decision 0014). This is consistent with the Prompt T no-write rule — infrastructure state files are exempt.
