# Decision 0004 — Mechanical Enforcement Layer

## Status
Accepted

## Decision
Enforce Repo OS mechanically using Claude Code native features:
1. **Subagent frontmatter**: Invocable agents (Builder, QA, Reviewer, Security, A11y) declare `tools`/`disallowedTools` in YAML frontmatter → runtime-enforced tool boundaries
2. **Subagent frontmatter hooks**: Builder, QA, and Security declare `PreToolUse` hooks in frontmatter → `agent-git-guard.sh` blocks `git commit` and `git push` commands (exit 2) while allowing other Bash usage
3. **Orchestrator exception**: Orchestrator + shared files (`_agent-glossary.md`, `_agent-workflow.md`) have no frontmatter — behavioral references only. Orchestrator is the only agent permitted to commit/push
4. **Team settings**: `.claude/settings.json` (committed) defines permissions + hooks. Personal overrides in `.claude/settings.local.json` (gitignored)
5. **Hooks** (`.claude/hooks/`):
   - `PreToolUse` on Edit/Write → `branch-guard.sh`: blocks file modifications on `main` before any work is done. Override: `REPO_OS_ALLOW_MAIN=1`
   - `PreToolUse` on `git commit` → `pre-commit-gates.sh`: A4 secret scanning (blocks), A2 scope check (advisory), A6 task group contract staging check (advisory). Override: `SKIP_CONTRACT_CHECK=1`
   - `PreToolUse` on `git push` → `pre-push-gates.sh`: B1 branch naming convention (advisory), stubs for B2/B3 project-specific checks. Projects add test/typecheck/audit checks
   - `PostToolUse`/`PostToolUseFailure` on Bash → `hvst-failure-tracker.sh`: HVST failure tracking
   - `Stop` → `session-close-check.sh`: session log update check (blocks via exit 2, with `stop_hook_active` guard and session weight detection — zero-change sessions downgrade to advisory), PR-to-main reminder for mergeable branches (advisory), HVST known-issues reminder (advisory), task group next-brief reminder (advisory). Override: `SKIP_SESSION_LOG=1`, `SKIP_CONTRACT_CHECK=1`
6. Extends Decision 0003 — frontmatter is required for invocable agents
