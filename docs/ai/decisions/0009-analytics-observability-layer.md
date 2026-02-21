# Decision 0009 — Analytics & Observability Layer

## Status
Accepted

## Decision
Add a lightweight analytics layer for data-driven hook optimization and operational insight:
1. **Hook telemetry**: Each hook emits a single JSONL event to `.claude/analytics/events/<date>.ndjson` via shared helper `.claude/hooks/_analytics-helper.sh`. Events capture hook name, lifecycle event, tool name, outcome, duration, and causation reason. All writes are fail-silent (`|| true`) — analytics never blocks enforcement
2. **Storage**: Per-repo at `.claude/analytics/` (gitignored). Central registry at `~/.local/share/repo-os-analytics/registry.json` maps absolute paths to all local repos for cross-repo analysis
3. **Isolation**: During normal operations, agents do not read `.claude/analytics/`. The Analytics specialist agent is the only consumer, invoked on-demand by the operator. Policy boundary documented in `_agent-glossary.md`; agents using Grep/Glob exclude `.claude/analytics/` from searches
4. **Analytics specialist**: New agent `.claude/agents/analytics.md` (Read, Grep, Write only). Reads registry to discover repos, reads event files across repos, generates reports. Operator-invoked — never automatic. Third agent category: Operations (alongside Advisory Board and Build Team)
5. **Hook optimization** (Phase 0): Cache `git rev-parse --show-toplevel` across invocations. Combine 9 secret-scan grep calls into single pass. Short-circuit HVST success when counter is already zero. Reduce hook stdout to concise single-line messages. Reorder session-close-check to run blocking checks before advisory GitHub API call
6. **Session ID**: Generated on first hook fire per session (`.claude/.session-id`), cleaned by Stop hook alongside `.hvst-fail-count`. Format: `YYYYMMDD-HHMMSS`
7. **Data lifecycle**: Event files older than 90 days deleted by Stop hook. No size limit on individual files (daily rotation keeps them small). Corrupt NDJSON lines skipped by analytics agent

## Consequences
- `.claude/hooks/_analytics-helper.sh` added (shared helper, sourced by all hooks)
- `.claude/agents/analytics.md` added (new Operations-category agent)
- `_agent-glossary.md` gains Reserved Directories section with `.claude/analytics/` policy
- `_agent-workflow.md` gains Operations category in Subagent Reference
- `.gitignore` gains `.claude/analytics/` and `.claude/.session-id`
- `.templatesyncignore` gains `.claude/analytics/` (child repo data stays local)
- Decision 0004 unchanged — hooks remain enforcement-only; telemetry is a passive observer appended after enforcement logic
- All 6 hooks gain 2-3 lines (source helper, call log_event) — no enforcement logic changes
- Event schema versioned via `v` field in each event for forward compatibility
