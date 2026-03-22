# Repo OS

## Non-negotiables
- The operator creates and manages GitHub repositories (org/visibility/credentials). Agents must not do this.
- No code changes without a plan.
- Work happens in small, verifiable increments.
- **Gates must pass before commits (and before any push).**
- **Accepted decisions are mandatory. Decision violations block commits.**
- Session log is updated and committed during the close phase, before the agent presents its closing summary. See `docs/ai/workflow.md` Close Sequence. Zero-change sessions (no commits, no working tree changes) are exempt — the hook downgrades to advisory.

## Authority
Operator-only:
- Create GitHub repo, manage org/user/visibility/credentials, configure remote

Agent-allowed:
- Read/write files, run local commands
- Git operations (status/add/commit) once gates pass
- Push to remote after merge (advisory — warn on failure, do not block)

## Source of Truth
- docs/spec/compiled/ (active version per manifest.json)
- docs/spec/prototypes/ (experiment briefs and prototype learnings)
- docs/ai/workflow.md (skip for ephemeral session type; load at init for all other session types)
- docs/ai/quality-gates-summary.md
- docs/ai/hook-rules-summary.md
- docs/ai/decisions/ (all files except t-0001 through t-0004, which are on-demand below; includes DIGEST.md as compressed foundational reference)
- docs/ai/logs/session-log.md (template mode: `.claude/local/session-log.md`)
- docs/ai/logs/known-issues.md (template mode: `.claude/local/known-issues.md`)
- docs/ai/governance/ (inter-session governance evidence)
- .claude/agents/orchestrator.md
- .claude/agents/_agent-glossary.md
- .claude/agents/_agent-workflow.md

On-demand (loaded by orchestrator.md triggers, not at session start):
- docs/ai/decisions/t-0001-repo-os-baseline.md, t-0002-decisions-are-mandatory.md, t-0003-agent-structure-standard.md, t-0004-mechanical-enforcement.md (read when modifying foundational governance or when DIGEST.md reference is insufficient)
- docs/spec/_templates/ (read during Prompt 0 only)
- .claude/agents/_advisory-board.md (read during Prompt A Phase 1)
- .claude/agents/_pm-advisor.md (read when PM Advisory dispatched — Prompt T/A/B review phase, on-demand)
- .claude/agents/_cohesion-review.md (read after Builder signals completion)
- .claude/agents/_hvst-review.md (read when HVST debugging stalls or operator requests debug review)
- docs/ai/task-groups/ (loaded when task brief contains `### Task Group`; template mode uses `.claude/local/task-groups/` for contracts)
- .claude/local/task-contract.yaml (task contract — written at session init from brief text, read at cohesion review; Decision 0020)
- docs/ai/workflow-appendix/session-type-prototype.md (read when session type is prototype — detected at init from brief or experiment/* branch)
- docs/ai/workflow-appendix/session-type-task-definition.md (read when session type is task-definition — detected at init from Prompt T invocation)
- docs/ai/workflow-appendix/session-type-editor-live.md (read when session type is editor-live — detected at init from brief or operator signal)
- docs/ai/workflow-appendix/session-type-task-group.md (read when session type is task-group or taskgroup-merge — detected at init from `### Task Group` in brief)
- docs/ai/workflow-appendix/session-type-automation.md (read when session type is automation — detected at init from runner context or operator signal)
- docs/ai/quality-gates.md (read in full when in verify or commit phase, or when QA agent is dispatched)
- docs/ai/workflow.md (read when `upgrade_session_type` is called on an ephemeral session)

Hooks (`.claude/hooks/`) enforce governance automatically via phase-aware flow management (Decision 0014). Neither hooks nor settings (`.claude/settings.json`, auto-loaded by Claude Code) need to be read into context.

| Hook | Event | Gates / Checks | Blocking? |
|------|-------|---------------|-----------|
| `write-guard.sh` | Edit, Write | Mode guard (template/child/autonomous per `.claude/repo-mode`), main branch protection (§3), phase-aware edit gate (§3, blocks init/plan), session overlap (Decision 0013), session branch isolation (§3, Decision 0013) | BLOCK (overlap: advisory for task groups; isolation: task groups exempt) |
| `pretooluse-permission.sh` | Agent PreToolUse | Session-type-aware agent allowlist — blocks write-capable subagents in no-write sessions, fail-closed on missing phase-state, `claude` Bash deny pattern (Decision 0027) | BLOCK (GATE-FINAL) |
| `pretooluse-permission.sh` | Bash PreToolUse | Deny list blocks dangerous Bash commands (including `claude` subprocess — Decision 0027), allow list passes safe ones (`_permission-allowlist.sh`). Headless (`CLAUDE_HEADLESS=1`): fail-closed for unknown commands, exempt from `claude` deny. Interactive: pass-through. Audit log: `.claude/.automation/logs/permission-audit.log` (Decision 0017) | BLOCK (deny/headless-unknown) / allow / pass-through |
| `bash-guard.sh` | Bash | Consolidated Bash PreToolUse (Phase 3a): state-guard, mode guard, plan-approval gate, fail-closed phase enforcement (Decision 0019), task group merge protection (Decision 0018), session overlap, session branch isolation. Ephemeral session fast-exit (Phase 3b) | BLOCK (phase enforcement: advisory when sentinel absent; ephemeral: pass-through) |
| `branch-guard.sh` | _(deprecated)_ | Retained for rollback. Bash calls now handled by `bash-guard.sh` | — |
| `plan-approval.sh` | AskUserQuestion | Writes `plan-approved` state file when operator confirms plan | — (state writer) |
| `ask-user-deny.sh` | AskUserQuestion PreToolUse | Blocks `AskUserQuestion` when `CLAUDE_HEADLESS=1` (Decision 0017) | BLOCK (interactive pass-through) |
| `permission-request.sh` | PermissionRequest | Auto-approves curated tools/safe Bash (`_permission-allowlist.sh`), denies dangerous patterns, falls through to VS Code dialog. Audit log: `.claude/.automation/logs/permission-audit.log` (Decision 0017) | BLOCK (deny) / allow / fallthrough |
| `pre-commit-gates.sh` | commit | A1 trigger parser, A2 scope (>100 lines), A4 secret scan, A6 contract existence + staging (Decision 0018), state file verification (`plan-approved`/`cohesion-reviewed`/`qa-verified`), scope classification (Decision 0017), high-risk pattern detection, inter-session governance | BLOCK (governance: advisory, first-fire) |
| `pre-push-gates.sh` | push | B1 naming convention | BLOCK |
| `session-close-check.sh` | stop | Session log, solo merge safety net (Decision 0015), completion marker validation (taskgroup-merge), branch sealing (Decision 0013), session registry cleanup, state file cleanup, override audit, governance evidence (task groups), next-brief reminder | BLOCK (audit/governance/reminder: advisory) |
| `agent-git-guard.sh` | Bash PreToolUse (subagents) | Blocks Builder/QA/Security from `git commit`/`git push` | BLOCK |
| `hvst-failure-tracker.sh` | Bash PostToolUse | Tracks consecutive Bash failures, prompts HVST protocol | advisory |
| `state-writer.sh` | SubagentStop | Captures `cohesion-reviewed`, `qa-verified`, `reviewer-signed`, `security-signed`, `pragmatist-signed` (worktree: skip — Decision 0028) | — (state writer) |

Experiment branches: A4 only (all state checks skipped). Emergency recovery: `REPO_OS_RECOVER=1` skips all state-dependent checks and bash-guard/branch-guard gates.

Automation layer (Decision 0017): optional headless runner infrastructure in `.claude/.automation/`. Schemas define contracts for queue entries, escalations (9 types: gate-failure, governance-block, phase-tag-escalation, ambiguity, scope-exceeded, dependency-missing, security-risk, structural-change, scope-deviation), blocker reports, and runner config. Default config (`config.yaml`) ships with `enabled: false`. Runtime artifacts (queue/, reports/, escalations/, briefs/, logs/) are gitignored. When enabled, runners invoke `claude -p` with full governance parity — same hooks, same gates, same phase model. Stop hook does not fire in headless mode; runners handle post-session tasks (solo merge, registry cleanup, branch sealing) externally. Toggle: set `runner.enabled: true` in `.claude/.automation/config.yaml` or create a `HALT` file to stop the daemon immediately. Standalone intake CLI (`lib/intake.sh`) creates queue entries without the interactive bridge — accepts brief path, session type, auto-approve, solo, and push flags; auto-enables the runner when entries are added. External integration surface includes queue validation (required fields, session type, branch name sanitization, opt-in HMAC), push_on_complete flag (per-entry opt-in branch push after session completion — solo pushes main, non-solo pushes feature branch), AskUserQuestion deny hook (PreToolUse — blocks interactive prompts in headless mode via `CLAUDE_HEADLESS=1` env var, defense-in-depth alongside `--disallowedTools`), decision cache (two-level merge with never-elevate rule, max 10 entries prepended to prompts), and flock-based file locking for queue mutations. Solo merge path includes merge conflict escalation: ff-only → no-ff fallback → on conflict, writes scope-deviation escalation with conflict file list and transitions entry to review. Scope classification model: scope-deviation escalations include `scope_classification` (briefed/unbriefed-in-scope/out-of-scope) and `risk_gain` (risk/gain context for operator review). Child-sync pipeline (`lib/child-sync.sh`) resolves GitHub org via three-tier fallback: `REPO_OS_GITHUB_ORG` env var → `# org:` directive in `child-repos.conf` → hardcoded default. Runner/stop-hook parity contract at `.claude/.automation/RUNNER-PARITY.md` maps every `session-close-check.sh` responsibility to its `runner.sh` equivalent — update when either path changes. See `docs/ai/workflow-appendix/session-type-automation.md` for full runner lifecycle.

## Spec Convention
- **Templates** (`docs/spec/_templates/`): Blank spec files with placeholder fields. Synced from the upstream template repo. Do not fill these directly.
- **Compiled** (`docs/spec/compiled/`): Operator-filled specs, organized by version. Created by Prompt 0.
- **Feature Briefs** (`docs/spec/compiled/{active}/features/brief-{name}.md`): Lightweight feature specs for individual feature additions. Created via Prompt T significant feature path (two-brief task group). Template at `docs/spec/_templates/feature-brief.md`.
- **Manifest** (`docs/spec/compiled/manifest.json`): Tracks the active version. Read `active` field to resolve the current spec path: `docs/spec/compiled/{active}/`.
- If `manifest.json` has `"active": null`, specs have not been compiled yet. Run Prompt 0.

## Prompts
- docs/ai/prompts/prompt-0-spec-builder.md
- docs/ai/prompts/prompt-0.5-prototype.md
- docs/ai/prompts/prompt-a-repo-os.md
- docs/ai/prompts/prompt-b-product-build.md
- docs/ai/prompts/prompt-c-project-audit.md
- docs/ai/prompts/prompt-d-daemon-toggle.md
- docs/ai/prompts/prompt-e-editor-live.md
- docs/ai/prompts/prompt-t-task-definition.md

## Versioning
Template versions use CalVer git tags (e.g., `v2026.02.1`). Tags are auto-created on merge to `main` when Repo OS files change (`.github/workflows/auto-version-tag.yml`). See GitHub Releases for changelog.
