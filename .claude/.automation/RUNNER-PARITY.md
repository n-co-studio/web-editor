# Runner ↔ Stop Hook Parity Contract

Maintenance checklist mapping every `session-close-check.sh` (Stop hook)
responsibility to its `runner.sh` equivalent. When the stop hook changes,
check this doc to determine what runner.sh must also change.

Decision 0017: Stop hook does NOT fire in `claude -p` mode.
Runners must handle post-session tasks externally.

## Parity Checklist

| # | Responsibility | Stop Hook (`session-close-check.sh`) | Runner (`runner.sh` / `lib/cleanup.sh`) | Notes |
|---|---------------|--------------------------------------|----------------------------------------|-------|
| 1 | Session log check | Blocking — verifies session log modified since baseline | N/A — runner does not enforce session log check; the agent writes it during close phase | Agent responsibility in headless mode |
| 2 | Uncommitted changes check | Blocking — verifies no unstaged/staged changes | N/A — runner trusts agent completed cleanly | Outcome detector catches crash state |
| 3 | HVST known-issues check | Advisory — reminds agent to update known-issues.md after 2+ failures (downgraded from blocking in Phase 2b) | N/A — runner does not enforce | Agent responsibility via prompt instructions |
| 4 | Deferrals known-issues check | Advisory — reminds agent to update known-issues.md for deferred findings (downgraded from blocking in Phase 2b) | N/A — runner does not enforce | Agent responsibility via prompt instructions |
| 5 | Solo merge | Merges feature/fix/hotfix branch to main (ff-only → no-ff fallback) | `_run_single_entry()` performs identical merge logic post-session with merge conflict escalation | Runner adds scope-deviation escalation on merge conflict |
| 6 | Post-merge push | Advisory push to origin after solo merge (skips template mode, no remote) | Same advisory push pattern in `_run_single_entry()` + `push_on_complete` flag for non-solo entries | Runner also supports `push_on_complete` for feature branches |
| 7 | Branch sealing | `record_closed_branch()` via `seal_branch_if_applicable()` — conditional on session type, finality | `record_closed_branch()` in `_run_single_entry()` for all completed entries | Both use shared `_cleanup-helper.sh` |
| 8 | Session registry cleanup | `cleanup_session()` calls `unregister_session()` (from `_analytics-helper.sh`) before state file cleanup | Runner calls `unregister_session()` separately via `_analytics-helper.sh` before `cleanup_session_files()` | Unregistration is a distinct step from state file cleanup — both paths must call it first |
| 9 | State file cleanup | `cleanup_session()` delegates to `cleanup_session_files()` after unregister | Runner delegates to same `cleanup_session_files()` from `_cleanup-helper.sh` | Shared helper eliminates divergence (audit C5) |
| 10 | Completion marker cleanup | Removes `tg-*-brief-*.complete` for `taskgroup-merge` sessions | Same — `cleanup_session_files()` handles based on session type | Shared helper |
| 11 | Override audit summary | Advisory — lists all governance overrides used this session | N/A — runner does not summarize overrides | Overrides are logged in `overrides.log` regardless |
| 12 | Governance evidence check | Advisory — verifies task group contract has governance entry | N/A — runner does not verify | Agent responsibility via prompt instructions |
| 13 | Next-brief reminder | Advisory — prints reminder for pending briefs in task group | N/A — runner manages queue sequencing directly | Runner uses queue state machine instead |
| 14 | Baseline SHA update | Updates `.session-log-hash` and `.session-baseline-sha` | N/A — baseline tracking is for interactive sessions only | Not needed in headless mode |
| 15 | 3-attempt safety valve | Exits unconditionally after 3 stop attempts | N/A — runner has circuit breaker (3 consecutive global failures) | Different mechanism, same intent |
| 16 | Task group finality check | `is_final_brief()` determines merge eligibility | Runner receives finality from queue entry metadata (solo_mode flag) | Different mechanism — runner uses explicit config |
| 17 | Agent-merge detection | Reads `merge-source-branch` signal file to skip redundant merge | N/A — runner always handles merge externally | No signal file needed in headless mode |

## Shared Code

Both paths source `_cleanup-helper.sh` for:
- `cleanup_session_files()` — state file removal
- `record_closed_branch()` — branch seal ledger

This shared helper was extracted (audit C5) to eliminate the divergence
risk inherent in maintaining two independent cleanup implementations.

## When to Update This Doc

Update this checklist when:
- A new blocking check is added to `session-close-check.sh`
- A new post-session responsibility is added to either path
- The shared cleanup helper gains new cleanup targets
- Solo merge logic changes in either path
