# Decision 0047 — Session Lifecycle: Stop/SessionEnd Split

## Status
Accepted

## Triggers

- type: process
- keywords: `stop.hook, session.end, session.close, branch.seal, cleanup, session.lifecycle, SessionEnd, multi.turn`
- enforced_by: `.claude/hooks/session-close-check.sh`, `.claude/settings.json`

## Context

The `Stop` event in Claude Code fires at the end of **every assistant turn** — not only at true session termination. In multi-turn interactive sessions and in headless sessions where the Stop hook blocks and forces Claude to continue working, the hook fires repeatedly. Prior to this decision, `session-close-check.sh` performed destructive close work (state cleanup, branch sealing, solo merge safety net) on every Stop firing, which caused:

1. `.claude/.session-id` being rewritten mid-session, orphaning the per-session state directory
2. Per-session state directories being removed while the session was still running
3. Active branches appended to `.claude/local/closed-branches`, causing Gate 5 to refuse all edits while the session was live

Three consecutive sessions in a child repo logged stop-hook interference as a deviation. A second incident (`c027bf23`) left an unsealed branch, no session log, and a stale registry entry reporting the session as live for two days.

`SessionEnd` is a Claude Code hook event that fires exactly once at true session termination (normal exit). It is **purely informational**: exit 2 shows a message to the user but does not block. This makes it the correct signal for cleanup work.

## Decision

Split the responsibilities of `session-close-check.sh` between the `Stop` and `SessionEnd` events:

### 1. Stop event: advisory and blocking checks only

The `Stop` handler runs advisory/blocking checks and never performs destructive actions:
- **Blocking**: session log existence check, uncommitted changes check
- **Advisory**: HVST failure notice, deferrals notice, override audit, governance evidence, KG update notice, next-brief reminder, completeness warning, phase forensic
- **Fast exits**: pause detection (interactive sessions), foreign-state guard, zero-change exit, ephemeral/spec session fast-exit

The 3-attempt safety valve (fires after 3 blocked Stop attempts) transitions from "force cleanup" to "allow with advisory". It no longer seals the branch or cleans state — those are now owned by `SessionEnd`.

### 2. SessionEnd event: destructive cleanup

The `SessionEnd` handler runs all destructive close work:
- Agent-merge signal detection → `record_closed_branch`, push, delete merged branch
- Editor-live orphaned branch seal
- Solo merge safety net (when `solo=true` and agent did not merge)
- Branch sealing (`seal_branch_if_applicable`)
- State file cleanup (`cleanup_session`)
- Baseline SHA update (`update_baseline`)
- Evidence manifest cleanup

`SessionEnd` always exits 0 (informational event — blocking has no effect).

### 3. Self-sealing guard in `seal_branch_if_applicable`

`seal_branch_if_applicable` gains a guard: when invoked from the `Stop` path (HOOK_EVENT ≠ SessionEnd), it refuses to seal. This is belt-and-suspenders so a future re-wiring cannot resurrect the bug.

### 4. Crash path: startup reaper

`SessionEnd` does not fire on hard kill or crash. The existing `sweep_stale_sessions()` (called at `init_phase` via `register_session`) already removes registry entries whose process is dead (`kill -0` check) and entries older than 24h. This startup-sweep reaper is the cleanup path for crashed sessions. Unsealed branches from crashed sessions are intentionally left open for retry — consistent with the existing merge-failure behavior in Decision 0013 §6.

### 5. Settings wiring

`settings.json` gains a `SessionEnd` entry pointing to `session-close-check.sh` (no matcher required — the hook reads `hook_event_name` from the JSON payload).

### 6. Event detection in the hook

`session-close-check.sh` reads `hook_event_name` from the JSON input (`jq -r '.hook_event_name // "Stop"'`) immediately after sourcing libraries. On `Stop` it follows the advisory/blocking path; on `SessionEnd` it follows the destructive cleanup path.

## Consequences

- `session-close-check.sh`: major restructure — event detection added, destructive paths gated on `HOOK_EVENT = SessionEnd`, Stop safety valve changed from "force cleanup" to "allow with advisory"
- `.claude/settings.json`: `SessionEnd` hook entry added
- `AI.md`: hook table updated — `session-close-check.sh` now listed under both `Stop` and `SessionEnd` events
- Branch sealing and state cleanup no longer run during a live session's turn-end Stop firings — this is the primary bug fix
- Sessions that crash without `SessionEnd` leave branches unsealed (same as before for merge-failure cases); `sweep_stale_sessions` cleans the stale registry entry at next session init
- The `is_session_closing()` predicate remains in `_phase-helper.sh` for pause detection (interactive sessions only; prevents blocking checks from firing on every interactive turn)
- Decision 0013 (session branch isolation) and Decision 0015 (solo mode merge) semantics are preserved: branches are still sealed at close; solo merges still happen at close. The change is WHEN the close event is — now correctly at `SessionEnd`

## Consequences for In-Flight Sessions

Sessions initialized before this change may complete without `SessionEnd` wiring if the hook fires before settings are reloaded. The change is tolerant: Stop no longer does destructive work, so the worst case is that a session completes but cleanup happens at the next `SessionEnd` (or via the startup reaper at the next session init). No governance state is lost.

## Amendment — 2026-09-01: Review Findings from the Landing Session

The three sessions that produced this decision's implementation self-reported success; none was reviewed by an independent agent. The landing session (2026-09-01) dispatched Critic, QA and security-privacy against the full stack before merge. Four things this decision did not say, but the implementation assumed, are recorded here.

### 7. No-init sessions do not seal (previously silent)

The SessionEnd dispatch guards `seal_branch_if_applicable` on the presence of `phase-state`:

```
if [ "$BRANCH_SEALED" = false ] && [ -f "$_SESSION_STATE_DIR/phase-state" ]; then
```

This **inverts** the pre-t-0047 behaviour, where a no-init close sealed the branch, and Layer 3 §L3.10b Test 1 was rewritten to assert the inversion. The test cited "§3" as authority. §3 governs only the Stop-path guard in `seal_branch_if_applicable` — it does not address no-init sealing, and §2 lists branch sealing as SessionEnd work with no phase-state precondition. The change was therefore a silent amendment.

It is nonetheless **the correct behaviour**, and is adopted here deliberately. The old rationale ("Decision 0019 fail-closed blocks all edits without phase-state, so no work can exist") does not hold when `phase-state` is *absent at the resolved path* rather than never written — precisely what session-identity churn produces. In that case real work does exist, and sealing retires a branch nobody finished with, stranding it behind Decision 0013's no-reuse rule. Declining to seal is the safe direction: an unsealed branch can be retried, a sealed one cannot.

### 8. Destructive close work must run behind the foreign-state guard

§2 moved merge, seal and cleanup into the SessionEnd dispatch, which sits above the Stop path's foreign-state guard in the file. The dispatch therefore ran all destructive work, and `exit 0`ed, without that guard ever executing.

This is not a skipped advisory check. `cleanup_session()` resolves `close_sid` via `get_session_id()` against the shared, first-writer-wins `.claude/.session-id`. When two sessions co-reside in one working copy, a SessionEnd firing for process A unregisters session B and deletes B's session-scoped state including B's `phase-state`, while B is still running — after which Decision 0019 fail-closed enforcement blocks every edit in B. Reproduced under mutation in `layer6-stop-sessionend-split.sh` §L6.5c.

**Requirement:** the SessionEnd dispatch MUST evaluate the foreign-state guard before any destructive action and bail out when the resolved state belongs to a different live process. Implemented as `_is_foreign_live_state()`, shared by both close paths so they cannot drift. Covered by §L6.5c.

### 9. SessionEnd cannot block, so close-path failures require durable escalation

§2 states SessionEnd always exits 0 because blocking has no effect. The implementation carried that through by deleting the Stop path's `_output_block` on merge failure — but replaced it with nothing, and also dropped the merge-lock fail-closed escalation, the ref-move anomaly warning, and the stale-tree detection backstop that Decision 0030 requires. Merge and working-tree-sync failures became silent by construction: the only trace was an analytics line.

**Requirement:** every failure on the SessionEnd destructive path MUST write a durable escalation under `.claude/.automation/escalations/`. Losing the ability to block is not licence to lose the signal. Implemented as `_write_close_escalation()`, used for merge-lock failure, stale main working tree, and incomplete solo merge. A failed merge still does NOT seal — the branch stays reusable per Decision 0013 §6.

### 10. `settings.json` immunity is not amended by this decision

§5 authorises adding a `SessionEnd` entry to `.claude/settings.json` — a one-time content change. It does not amend `_mode-guard-helper.sh`, and does not make `settings.json` agent-writable in template mode as standing policy. The implementation carved the file out of `is_immune()` for template mode and cited "Decision 0047" for it. That carve-out has been reverted; the `SessionEnd` entry it was added to enable is already committed and needs no standing exemption. Should a future change require editing `settings.json`, it needs its own decision, not a rider on this one.

### Also noted, not amended here

`is_full_worktree_session()` (Decision 0030 Amendment 2026-08-31) now accepts the *presence of a file* where it previously required an environment variable. A file's existence is forgeable by an agent; the env var, injected by the launcher into the hook's process tree, was not. The amendment's stated invariant — that a subagent worktree has no `phase-state` at its resolved state dir — holds only while `_REPO_OS_ROOT` resolves to the worktree root. Hooks are wired in `settings.json` by relative path, which does so; but `_analytics-helper.sh` documents a second resolution path where `_REPO_OS_ROOT` becomes the main repo root, and under that path the parent session's `phase-state` IS visible and the invariant inverts. Verified empirically during the landing session: in a real worktree with `REPO_OS_SESSION_ID` unset, `is_full_worktree_session()` returns true when resolved against the main repo and false when resolved against the worktree. Filed as a follow-up rather than changed here — see `.claude/.automation/briefs/20260901-close-checks-session-tree-repo-root.md`, whose most natural fix (routing repo-root through `get_main_repo_root()`) would make the unsafe resolution the live one and silently break Decision 0028.
