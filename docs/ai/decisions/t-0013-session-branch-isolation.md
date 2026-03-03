# Decision 0013 — Session Branch Isolation

## Status
Accepted

## Triggers

- type: process
- keywords: `branch.reuse, session.isolation, closed-branches, one.session.per.branch, solo.merge, branch.seal, session.registry, session.overlap, concurrent.session`
- enforced_by: `.claude/hooks/branch-guard.sh`, `.claude/hooks/branch-guard-edit.sh`, `.claude/hooks/session-close-check.sh`

## Decision
Enforce one session per branch. When a session closes, the branch is sealed — no future session may edit files on it:
1. **Closed-branches ledger**: `.claude/local/closed-branches` (gitignored, one branch name per line). Appended by `session-close-check.sh` after all blocking checks pass. Not written for zero-change sessions or `main`
2. **Gate 5 in `branch-guard.sh`**: On every Edit/Write, checks if the current branch appears in the closed-branches ledger. If found, blocks with a message directing the operator to create a new branch
3. **Task group lifecycle**: Non-final task group briefs do not seal the branch at close — the branch stays open for the next brief in the group. Only the final brief (no `status: pending` briefs remaining in the contract) seals the branch. This means active task group branches never appear in the closed-branches ledger, so Gate 5 does not need a contract-scanning exemption
4. **Override**: `REPO_OS_SKIP_BRANCH_REUSE=1`. `REPO_OS_RECOVER=1` also bypasses (existing recovery logic)
5. **Session close recording**: All legitimate session closes (normal, 3-attempt safety valve, `SKIP_SESSION_LOG` override) append the branch name, subject to the task group lifecycle rule above. Zero-change sessions do not record (branch stays open for future use)
6. **Solo mode interaction** (Decision 0015): In solo mode, branches are merged to main before sealing. The merge-then-seal sequence ensures the branch is sealed only after a successful merge. On merge failure, the branch remains open (not sealed) for retry. Solo mode does not change the sealing contract — it adds a merge step before the existing seal step
7. **Task group branch lifecycle**: One branch per group. Brief 1 creates it. Briefs 2–N-1 close without merge or seal. Brief N merges to main and seals. This means the branch is only recorded in the closed-branches ledger once (on final brief close)
8. **Session registry**: `.claude/.state/sessions/` contains one YAML file per active session (`{session-id}.yaml` with `session_id`, `session_type`, `branch`, `pid`, `started_at`). `register_session()` writes the file at `init_phase()`. `unregister_session()` removes it at session close and cleans stale entries (dead PID or >24h age). `check_session_overlap()` runs on every Edit/Write/Bash (Gate 6) — blocks non-task-group same-branch overlap, advisory for task group sharing. Prompt T sessions (taskdef-query, taskdef-brief) are exempt. Override: `REPO_OS_SKIP_OVERLAP_CHECK=1`

## Consequences
- `.claude/hooks/branch-guard.sh` gains Gate 5 (session isolation — blocking) and Gate 6 (session overlap — blocking/advisory)
- `.claude/hooks/branch-guard-edit.sh` gains Gate 5 (session isolation — blocking) and Gate 6 (session overlap — blocking/advisory) for Edit/Write tool calls
- `.claude/hooks/session-close-check.sh` gains closed-branch recording in normal, override, and loop-guard paths; `cleanup_session()` calls `unregister_session()`
- `.claude/hooks/_analytics-helper.sh` gains `register_session()`, `unregister_session()`, `check_session_overlap()`, `_iso_to_epoch()`
- `.claude/hooks/_phase-helper.sh` `init_phase()` calls `register_session()` at session start
- `docs/ai/workflow.md` gains session branch isolation rule in Session Lifecycle
- `.claude/agents/orchestrator.md` gains REQUIRE constraint and checklist item
- `docs/ai/prompts/prompt-b-product-build.md` gains operating rule
- `AI.md` hooks description updated to mention Gate 5 and Gate 6
