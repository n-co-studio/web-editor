# Decision 0018 — Mechanical Task Group Enforcement

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/hooks/(bash-guard|branch-guard|pre-commit-gates)\.sh`
- keywords: `taskgroup, task.group, contract, merge, A6_contract_missing, tg_merge_blocked, SKIP_MERGE_GUARD`

## Decision
Add BLOCK-level mechanical enforcement for two task group governance obligations that were previously REQUIRE-level (agent must remember):

1. **A6.1 — Contract existence check** (`pre-commit-gates.sh`): When session type is `taskgroup` or `taskgroup-merge`, block commit if no contract YAML with `status: in_progress` exists in the contract directory. Uses filesystem check (not `git diff`), so it works in template mode where contracts are in `.claude/local/task-groups/` (gitignored). Inherits existing `SKIP_CONTRACT_CHECK=1` override and `SKIP_STATE` guard (REPO_OS_RECOVER, experiment branches). Shares contract directory resolution with existing A6.2 staging check.

2. **Gate 7 — Task group merge protection** (`branch-guard.sh`): Block `git checkout main`, `git switch main`, and `git merge` (when on main) for `taskgroup` and `taskgroup-merge` sessions during build phases. Fires before the fast-exit in branch-guard.sh (necessary because these commands have no redirect/tee write targets). Zero-fork implementation: `[[ ]]` string matching with lazy `get_session_type()` call only when a pattern matches. Excludes false positives: `main-*` and `main/*` branch prefixes, `git merge --abort`, `git merge-base`. Close-phase exemption: when the current phase is `close`, Gate 7 allows merge commands — the agent has passed through all prior phases and determined merge appropriateness. Stop hook retains solo merge as safety net. Override: `REPO_OS_SKIP_MERGE_GUARD=1`.

## Context
During the operator-automation-layer task group (brief 1 of 7), two governance failures were observed post-merge:
- The agent committed without creating the task group contract YAML, despite the `contract-init` phase existing in the phase sequence. No hook verified contract existence before commit.
- The agent merged a non-final brief to main by running `git checkout main && git merge feature/branch` via Bash. The stop hook's `is_final_brief()` and solo merge logic correctly prevent this at session close, but manual merge commands bypass the stop hook entirely because `branch-guard.sh` fast-exits for commands without redirect/tee write targets.

Both failures stem from the same gap: the governance hooks enforce rules reactively (at commit/push/stop time for specific conditions), but contract creation and branch lifecycle were REQUIRE-level obligations with no mechanical enforcement. The agent must "remember" to do them, and in this case it didn't.

## Consequences
- `pre-commit-gates.sh` A6 section expanded: header updated, A6.1 contract existence sub-gate added (~20 lines), existing staging check labeled A6.2
- `branch-guard.sh` gains Gate 7 (~30 lines) between `CURRENT_BRANCH` assignment and fast-exit, plus header comment updates. Note: Gate 7 consolidated into `bash-guard.sh` (Phase 3a); `branch-guard.sh` retained for rollback
- `docs/ai/quality-gates.md` A6 row updated to document both sub-gates
- `AI.md` hooks paragraph gains two new entries
- No changes to `session-close-check.sh` — existing logic is correct
- No changes to `write-guard.sh` — immune path
- No changes to `_phase-helper.sh` or `_analytics-helper.sh` — existing functions sufficient
- Override: `REPO_OS_SKIP_MERGE_GUARD=1` (new), `SKIP_CONTRACT_CHECK=1` (existing, covers A6.1)
- Recovery: `REPO_OS_RECOVER=1` bypasses both new gates
