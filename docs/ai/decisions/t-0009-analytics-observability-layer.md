# Decision 0009 — Analytics & Observability Layer

## Status
Accepted

## Triggers

- type: file
- path: `\.local/share/repo-os-analytics`
- path: `\.claude/hooks/_analytics`
- keywords: `analytics, telemetry, ndjson, log_hook_event`

## Decision
Add a lightweight analytics layer for data-driven hook optimization and operational insight:
1. **Hook telemetry**: Each hook emits a single JSONL event to `~/.local/share/repo-os-analytics/<repo-name>/events/<date>.ndjson` via shared helper `.claude/hooks/_analytics-helper.sh`. Repo name derived from `basename` of repo root. Events capture hook name, lifecycle event, tool name, outcome, duration, and causation reason. All writes are fail-silent (`|| true`) — analytics never blocks enforcement
2. **Schema v2**: Events use `v:2` with enrichment fields auto-appended by the helper: `mode` (operating mode), `branch` (current git branch). Optional fields `detail` (structured sub-reason), `path` (file path for blocks/allows), `session_type` (build/qa/audit/explore) are populated when relevant. v1 events remain valid (forward compatible via `v` field)
3. **Storage**: Centralized at `~/.local/share/repo-os-analytics/<repo-name>/events/` on the operator's machine (outside the repo tree). Central registry at `~/.local/share/repo-os-analytics/registry.json` maps absolute paths to all local repos for cross-repo analysis
4. **Isolation**: Analytics data lives outside the repo tree (`~/.local/share/repo-os-analytics/`), so broad repo-scoped Grep/Glob patterns never hit it. The Analytics specialist agent is the only consumer, invoked on-demand by the operator. Policy boundary documented in `_agent-glossary.md`
5. **Analytics specialist**: New agent `.claude/agents/analytics.md` (Read, Grep, Glob, Bash — no Edit/Write). Reads registry to discover repos, reads event files across repos, generates reports. Operator-invoked — never automatic. Third agent category: Operations (alongside Advisory Board and Build Team)
6. **Hook optimization** (Phase 0): Cache `git rev-parse --show-toplevel` across invocations. Combine 9 secret-scan grep calls into single pass. Short-circuit HVST success when counter is already zero. Reduce hook stdout to concise single-line messages. Reorder session-close-check to run blocking checks before advisory GitHub API call
7. **Noise reduction**: HVST failure tracker emits only on state transitions — PostToolUseFailure always emits, PostToolUse success emits only on counter reset (not for `already_zero` or `no_counter`). Reduces ~80-90% of HVST events
8. **Session type classification**: `.claude/.session-type` convention — operators or models write `build`, `qa`, `audit`, or `explore` at session start. Hooks infer from behavioral signals at session close if absent. Cleaned by `cleanup_session()`. Note: the 4-value vocabulary (`build/qa/audit/explore`) was superseded by Decision 0014's 14-value phase-state `session_type` enum (e.g., `standard`, `hotfix`, `taskgroup`, `audit`, `prototype-spike`). The `.session-type` file is now a legacy fallback — canonical session type is tracked in `.claude/.state/phase-state`
9. **Session ID**: Generated on first hook fire per session (`.claude/.session-id`), cleaned by Stop hook alongside `.hvst-fail-count`. Format: `YYYYMMDD-HHMMSS`
10. **Data lifecycle**: Event files older than 90 days deleted by Stop hook. No size limit on individual files (daily rotation keeps them small). Corrupt NDJSON lines skipped by analytics agent. Test-mode sessions (`REPO_OS_TEST_MODE=1`) are excluded from registry registration — `register_repo()` returns early to prevent test harness pollution of the global registry
11. **Comprehensive instrumentation**: Every `exit 0` and `exit 2` in every hook has a preceding `log_hook_event` call. Session-close early exits (SKIP_SESSION_LOG, 3-attempt safety valve, bootstrap recovery) all emit events. Override audit summary emits analytics event. Per-gate events in pre-commit for independent queryability

## Consequences
- `.claude/hooks/_analytics-helper.sh` added (shared helper, sourced by all hooks) — v2 adds `get_branch()`, `get_mode()` cached helpers and optional `detail`/`path` parameters
- `.claude/agents/analytics.md` added (new Operations-category agent) — updated for v2 schema and enriched report sections
- `_agent-glossary.md` gains Reserved Directories section with `.claude/analytics/` policy. Operational files table includes `.session-type`
- `_agent-workflow.md` gains Operations category in Subagent Reference
- `.gitignore` retains `.claude/analytics/` for legacy data (active data now at `~/.local/share/repo-os-analytics/`), `.claude/.session-id`, `.claude/.session-type`
- `.templatesyncignore` retains `.claude/analytics/` for backward compatibility (active data no longer written there)
- Decision 0004 unchanged — hooks remain enforcement-only; telemetry is a passive observer appended after enforcement logic
- All hooks emit v2 events with mode, branch, and optional detail/path/session_type fields
- Event schema versioned via `v` field in each event for forward compatibility — v1 events remain parseable
