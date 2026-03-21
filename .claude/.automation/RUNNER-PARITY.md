# Runner ↔ Stop Hook Parity Contract

Maintenance checklist mapping every `session-close-check.sh` (Stop hook)
responsibility to its `runner.sh` equivalent. When the stop hook changes,
check this doc to determine what runner.sh must also change.

Decision 0017: Stop hook does NOT fire in `claude -p` mode.
Runners must handle post-session tasks externally.

## Parity Checklist

| # | Responsibility | Stop Hook (`session-close-check.sh`) | Runner (`runner.sh` / `lib/`) | Notes |
|---|---------------|--------------------------------------|-------------------------------|-------|
| 1 | Session log check | Blocking — verifies session log modified since baseline | N/A — runner does not enforce; agent writes session log during close phase | Agent responsibility in headless mode |
| 2 | Uncommitted changes check | Blocking — verifies no unstaged/staged changes | `runner_external_cleanup()` writes dirty-tree escalation if uncommitted changes present (hardening 4.1) | Stop hook blocks; runner escalates |
| 3 | HVST known-issues check | Advisory — reminds agent to update known-issues.md after 2+ failures | N/A — runner does not enforce | Agent responsibility via prompt instructions |
| 4 | Deferrals known-issues check | Advisory — reminds agent to update known-issues.md for deferred findings | N/A — runner does not enforce | Agent responsibility via prompt instructions |
| 5 | Solo merge | Merges feature/fix/hotfix branch to main (ff-only → no-ff fallback) | `_solo_merge_if_needed()` performs identical merge logic post-session with merge conflict escalation | Runner adds scope-deviation escalation on merge conflict |
| 6 | Post-merge push | Advisory push to origin after solo merge (skips template mode, no remote) | Same advisory push pattern in `_solo_merge_if_needed()` + `push_on_complete` flag for non-solo entries | Runner also supports `push_on_complete` for feature branches |
| 7 | Branch sealing | `record_closed_branch()` via `seal_branch_if_applicable()` — conditional on session type, finality | `record_closed_branch()` in `_solo_merge_if_needed()` (runs after `_run_single_entry()` returns); skips when branch is empty or main | Both use shared `_cleanup-helper.sh` |
| 8 | Session registry cleanup | `cleanup_session()` calls `unregister_session()` before state file cleanup | `runner_external_cleanup()` calls `unregister_session()` before `cleanup_session_files()` | Unregistration is a distinct step — both paths call it first |
| 9 | State file cleanup | `cleanup_session()` delegates to `cleanup_session_files()` after unregister | Runner delegates to same `cleanup_session_files()` from `_cleanup-helper.sh` | Shared helper includes `pragmatist-signed` and `scope-risk-gain` (hardening 3.2) |
| 10 | Completion marker cleanup | Removes `tg-*-brief-*.complete` for `taskgroup-merge` sessions | Same — `cleanup_session_files()` handles based on session type | Shared helper |
| 11 | Override audit summary | Advisory — lists all governance overrides used this session | N/A — runner does not summarize overrides | Overrides are logged in `overrides.log` regardless |
| 12 | Governance evidence check | Advisory — verifies task group contract has governance entry | N/A — runner does not verify | Agent responsibility via prompt instructions |
| 13 | Next-brief reminder | Advisory — prints reminder for pending briefs in task group | N/A — runner manages queue sequencing directly | Runner uses queue state machine instead |
| 14 | Baseline SHA update | Updates `.session-log-hash` and `.session-baseline-sha` | `runner_external_cleanup()` updates `.session-baseline-sha` with validated SHA (hardening H8) | Both paths update baseline |
| 15 | 3-attempt safety valve | Exits unconditionally after 3 stop attempts; preserves A4 secret scan (hardening C5) | N/A — runner has circuit breaker (3 consecutive global failures) | Different mechanism, same intent. Safety valve now writes A4 escalation if secrets detected |
| 16 | Task group finality check | `is_final_brief()` reads contract and checks completion markers | Runner receives finality from queue entry metadata (solo_mode flag) | Behavioral divergence: stop hook reads contract; runner reads queue config |
| 17 | Agent-merge detection | Reads `merge-source-branch` signal file to skip redundant merge | N/A — runner always handles merge externally | No signal file needed in headless mode |

### Stop Hook Only (items 18-23)

| # | Responsibility | Stop Hook | Runner | Notes |
|---|---------------|-----------|--------|-------|
| 18 | Zero-change fast exit | Exits before library sourcing when no uncommitted/staged/recent changes and no pending state files | N/A — runner always runs full cleanup after `claude -p` | Performance optimization for interactive mode |
| 19 | No-init fast exit | If `phase-state` absent, exits after honoring merge signals and sealing branch | N/A — runner always calls `state_manager_setup()` which ensures state exists | Safety net for interactive sessions that exit before init |
| 20 | Ephemeral session exemption | Types `taskdef-query`, `taskdef-brief`, `audit`, `ephemeral` skip all blocking close checks | Runner runs same `runner_external_cleanup()` for all types | Ephemeral sessions uncommon in automation |
| 21 | Spec/prototype session log exemption | Types `spec-fresh`, `spec-update`, `prototype-*` set `SESSION_LOG_EXEMPT=true` | N/A — runner does not enforce session log check (item 1) | Added in hardening |
| 22 | KPI summary emission | `_emit_kpi_summary` with stop attempt count and session type | N/A — runner logs outcome to stderr but no KPI summary | Telemetry for interactive observability |
| 23 | `register_repo()` call | Calls `register_repo "$REPO_ROOT"` for global analytics registry | N/A — runner does not call `register_repo()` | Runner sessions not in global analytics registry |

### Runner Only (items 24-31)

| # | Responsibility | Stop Hook | Runner | Notes |
|---|---------------|-----------|--------|-------|
| 24 | Dirty-tree guard before entry | N/A | `git checkout -- . && git clean -fd` before processing each queue entry | Prevents cascading dirty state between entries |
| 25 | Merge-idempotency on retry | N/A | On retry (`_retry_count > 0`), checks `git merge-base --is-ancestor` to skip re-execution | Prevents duplicate work |
| 26 | Queue state transitions | N/A | Transitions entry to `completed`/`review`/`failed` with lock and retry | Lock failure writes `gate-failure` escalation |
| 27 | Cohesion trigger dispatch | N/A | `check_cohesion_triggers()` on completed entries (now with queue lock — hardening 6.1) | Different dispatch mechanism than interactive |
| 28 | Drift detection dispatch | N/A | `run_drift_detection()` for `taskgroup` sessions after completion | Runner-only post-session analysis |
| 29 | Work order lifecycle | N/A | `wo_check_completion()` transitions parent work order on child completion/failure | Runner-layer orchestration. Status transitions validated (hardening H5/H6) |
| 30 | Headless AskUser deny | N/A — interactive sessions allow AskUserQuestion | `ask-user-deny.sh` blocks AskUserQuestion when `CLAUDE_HEADLESS=1` | Defense-in-depth alongside `--disallowedTools` |
| 31 | Queue write-protection | N/A | `write-guard.sh` blocks agent writes to `.claude/.automation/queue/` | Prevents agents from manipulating own queue entries |

## Shared Hardening Notes

These apply identically in both modes (same hooks fire during `claude -p`):

- **Session-bound state files** (C1/C4/H4): `state-writer.sh` embeds `session_id` in state files. `pre-commit-gates.sh` validates session_id match at commit time. Rejects forged/stale files.
- **Strict sequential phase enforcement** (C2/C3/H1): `_phase-helper.sh` only allows adjacent transitions + skippable phases (`user-review`, `op-review`). Non-adjacent jumps rejected.
- **Phase validation in state-writer** (C6/H3): `state-writer.sh` validates current phase matches agent type before writing governance state files.
- **Double-init guard** (M1): `init_phase()` refuses re-initialization if phase-state exists for the current session.
- **A4 secret scan patterns**: Expanded to include `github_pat_`, `glpat-`, `npm_`, `xox*`, `sk-proj-`, `pypi-`. Same `pre-commit-gates.sh` fires in both modes.
- **Permission allowlist**: `source`/`.` scoped to Repo OS paths; `cp`/`mv` removed. In headless, fall-through denies instead of showing dialog (hardening 4.4).
- **A1 headless escalation** (4.3): When A1 runs in advisory mode and `CLAUDE_HEADLESS=1`, an escalation file is written for operator visibility.
- **Test seam guard**: `_REPO_OS_TEST_ROOT` requires `/tmp/` or `/private/tmp/` prefix.
- **Config sanitization** (M2): `_parse_config_field()` rejects values containing shell metacharacters.
- **Path traversal guard** (6.3): `prompt-assembler.sh` rejects brief paths containing `..` or absolute paths outside REPO_ROOT.

### Daemon Only (items 32-38)

| # | Responsibility | Stop Hook | Runner | Notes |
|---|---------------|-----------|--------|-------|
| 32 | Health check file | N/A | `lib/health-check.sh` — `_write_health()` writes `.automation/.health` atomically each poll cycle with status, timestamp, pid, uptime, session counts. External consumers: `health_status()`, `health_is_alive()` | Gitignored runtime artifact |
| 33 | Graceful shutdown | N/A | SIGTERM/SIGINT sets `_SHUTDOWN_REQUESTED` flag; current session completes, then loop exits cleanly | EXIT trap writes final `stopped` status |
| 34 | Startup crash recovery | N/A | `_startup_crash_recovery()` scans for orphaned running entries, stale health/lock files, orphaned session state on daemon start | Fail-closed: ambiguous state writes escalation |
| 35 | Configurable poll interval | N/A | `poll_interval` config field (default 60s) replaces hardcoded idle sleep | Live-reloaded each cycle |
| 36 | Configurable cooldown | N/A | `cooldown_between_sessions` config field (default 5s) replaces hardcoded inter-session pause | Live-reloaded each cycle |
| 37 | Max consecutive sessions | N/A | `max_consecutive_sessions` config field (default 0 = unlimited); daemon exits cleanly when limit reached | Counter resets on idle cycle |
| 38 | Deployment artifacts | N/A | `repo-os-runner.plist` (macOS launchd template), `Dockerfile` (container template) | Templates with placeholder paths |

## Shared Code

Both paths source `_cleanup-helper.sh` for:
- `cleanup_session_files()` — state file removal (includes `pragmatist-signed`, `scope-risk-gain`)
- `record_closed_branch()` — branch seal ledger

Additional shared infrastructure:
- `_solo_merge_if_needed()` — extracted from `_run_single_entry()` into standalone function (runner.sh)
- `_validate_phase_session()` — session-bound state validation used by all hooks (_phase-helper.sh)
- `_runner_crash_cleanup()` — EXIT trap handler for runner crash recovery (runner.sh)
- `recover_orphaned_running()` — standalone recovery for stranded running entries (cleanup.sh)

## When to Update This Doc

Update this checklist when:
- A new blocking check is added to `session-close-check.sh`
- A new post-session responsibility is added to either path
- The shared cleanup helper gains new cleanup targets
- Solo merge logic changes in either path
- A hardening fix changes the security surface of hooks or runner post-session tasks
