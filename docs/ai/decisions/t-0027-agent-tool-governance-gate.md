# Decision 0027 — Agent Tool Governance Gate

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/(hooks/(pretooluse-permission|_permission-allowlist)|settings\.json)`
- keywords: `is_readonly_agent, _PERMISSION_READONLY_AGENTS, agent_gate, REPO_OS_ALLOW_AGENT, Agent PreToolUse`

## Decision
Close the Agent tool governance bypass that allows write-capable subagents to be spawned during no-write session types (Prompt T, A, C, D, ephemeral), bypassing all hooks, phase model, and pre-commit gates.

1. **PreToolUse hook gate on Agent tool**: `pretooluse-permission.sh` handles `Agent` tool calls via a new `Agent` matcher in `settings.json`. When `TOOL_NAME == "Agent"`:
   - If phase-state is missing or empty → GATE-FINAL block (fail-closed). Override: `REPO_OS_ALLOW_AGENT=1`.
   - If session type is in the no-write list (`taskdef-query`, `taskdef-brief`, `audit`, `ephemeral`, `advisory-init`, `advisory-reinit`, `spec-fresh`, `spec-update`), extract `subagent_type` from `tool_input` and check against the read-only allowlist. Block if not in allowlist. Note: Prompt D (daemon-toggle) uses session type `ephemeral`, so it is covered by this list.
   - If session type is a write-capable type (`standard`, `taskgroup`, etc.), allow all agent types.

2. **Read-only agent allowlist**: Defined in `_permission-allowlist.sh` as `_PERMISSION_READONLY_AGENTS` array with `is_readonly_agent()` helper function. Contains: `architect`, `critic`, `exploration`, `pragmatist`, `pm-advisor`, `analytics`, `ux-strategist`, `accessibility`, `performance-engineer`, `data-strategist`, `security-analyst`, `user-review-tier-1/2/3`, `Explore`, `Plan`, `dev-orchestrator`, `auditor`, `claude-code-guide`, `security-hacker`.

3. **Bash deny pattern for `claude`**: Added `'claude '` and `'claude$'` to `_PERMISSION_DENY_BASH` to block `claude -p` subprocess escalation. Exemption: `CLAUDE_HEADLESS=1` (automation runner legitimately spawns `claude` via `runner.sh`).

4. **Prompt-level REQUIRE rules**: Defense-in-depth — Prompts T, A, C, D include: "REQUIRE: never use the Agent tool with write-capable subagent types (builder, qa-verifier, security-privacy, general-purpose, reviewer) or request worktree isolation. Only read-only advisory agents are permitted."

## Root Cause
The Agent tool operates below the governance layer. When an agent spawns a subagent via the Agent tool, the subagent receives its own tool set (Edit, Write, Bash, etc.) and executes independently. PreToolUse hooks on Edit/Write/Bash fire in the subagent's context, but the parent session's no-write governance (Prompt T's "never write files" rule) is a prompt-level constraint with no mechanical enforcement on subagent spawning. The `SubagentStart` event is notification-only and cannot block.

## Allowlist vs. Denylist Rationale
An allowlist of read-only agents was chosen over a denylist of write-capable agents because:
- The `general-purpose` subagent type has access to all tools and escapes any name-based denylist.
- Any future unnamed or new agent type also slips through a denylist.
- Allowlist is safer — new agent types default to blocked in restricted sessions until explicitly added.

## Maintenance Obligation
When new read-only agent types are added to `.claude/agents/`, they must also be added to `_PERMISSION_READONLY_AGENTS` in `_permission-allowlist.sh`. Failure to do so means the new agent type will be blocked in no-write sessions.

## Deferred Concerns
- **Worktree state isolation**: Hooks in worktree subagents read the main session's state files. This is a pre-existing concern requiring a separate brief. This decision's gate fires in the parent session BEFORE the worktree is created, so worktree path resolution is not a factor.
- **`isolation: "worktree"` parameter**: Not visible in PreToolUse `tool_input` (confirmed via Claude Code docs), so cannot be independently gated. The allowlist approach handles this implicitly — blocked agent types cannot use worktree isolation regardless.

## Override
`REPO_OS_ALLOW_AGENT=1` — bypasses the Agent tool gate with audit log entry via `log_override()`. Follows the existing pattern where every blocking gate has an override.

## Supersedes
None.
