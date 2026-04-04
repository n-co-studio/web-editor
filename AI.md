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
- docs/ai/workflow-summary.md
- docs/ai/quality-gates-summary.md
- docs/ai/hook-rules-summary.md
- docs/ai/decisions/ (all files except t-0001 through t-0004, which are on-demand below; includes DIGEST.md as compressed foundational reference)
- docs/ai/logs/sessions/session-{id}.md (template mode: `.claude/local/sessions/session-{id}.md`)
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
- docs/ai/prompts/prompt-h-hotfix-debug.md (read when session type is hotfix — detected at init from `hotfix/*` branch or operator signal)
- docs/ai/workflow-appendix/session-type-task-group.md (read when session type is task-group or taskgroup-merge — detected at init from `### Task Group` in brief)
- docs/ai/workflow-appendix/session-type-automation.md (read when session type is automation — detected at init from runner context or operator signal)
- docs/ai/workflow-appendix/session-type-queue-triage.md (read when session type is queue-triage — detected at init from Prompt Q invocation)
- docs/ai/knowledge-graph/graph.yaml, docs/ai/knowledge-graph/product-graph.yaml (read when task brief references files with graph nodes or session touches governance-adjacent paths; used for relevance scoring via `.claude/tools/kg-relevance.sh` which searches both graphs automatically; Decision 0034)
- docs/ai/quality-gates.md (read in full when in verify or commit phase, or when QA agent is dispatched)
- docs/ai/workflow.md (read when `upgrade_session_type` is called on an ephemeral session; read in full when in verify or commit phase, or when detailed close sequence reference is needed)

Hooks (`.claude/hooks/`) enforce governance automatically via phase-aware flow management (Decision 0014). Neither hooks nor settings (`.claude/settings.json`, auto-loaded by Claude Code) need to be read into context.

| Hook | Event | Gates / Checks | Blocking? |
|------|-------|---------------|-----------|
| `write-guard.sh` | Edit, Write | Mode guard (template/child/autonomous per `.claude/repo-mode`), main branch protection (§3), phase-aware edit gate (§3, blocks init/plan), session overlap (Decision 0013), session branch isolation (§3, Decision 0013) | BLOCK (overlap: advisory for task groups; isolation: task groups exempt) |
| `pretooluse-permission.sh` | Agent PreToolUse | Session-type-aware agent allowlist — blocks write-capable subagents in no-write sessions, fail-closed on missing phase-state, `claude` Bash deny pattern (Decision 0027) | BLOCK (GATE-FINAL) |
| `pretooluse-permission.sh` | Bash PreToolUse | Deny list blocks dangerous Bash commands (including `claude` subprocess — Decision 0027), allow list passes safe ones (`_permission-allowlist.sh`). Headless (`CLAUDE_HEADLESS=1`): fail-closed for unknown commands, exempt from `claude` deny. Interactive: pass-through. Audit log: `.claude/.automation/logs/permission-audit.log` (Decision 0017) | BLOCK (deny/headless-unknown) / allow / pass-through |
| `bash-guard.sh` | Bash | Consolidated Bash PreToolUse (Phase 3a): state-guard, mode guard, plan-approval gate, fail-closed phase enforcement (Decision 0019), task group merge protection (Decision 0018), session overlap, session branch isolation. Ephemeral session fast-exit (Phase 3b) | BLOCK (phase enforcement: advisory when sentinel absent; ephemeral: pass-through) |
| `plan-approval.sh` | AskUserQuestion | Writes `plan-approved` state file when operator confirms plan | — (state writer) |
| `ask-user-deny.sh` | AskUserQuestion PreToolUse | Blocks `AskUserQuestion` when `CLAUDE_HEADLESS=1` (Decision 0017) | BLOCK (interactive pass-through) |
| `permission-request.sh` | PermissionRequest | Auto-approves curated tools/safe Bash (`_permission-allowlist.sh`), denies dangerous patterns, falls through to VS Code dialog. Audit log: `.claude/.automation/logs/permission-audit.log` (Decision 0017) | BLOCK (deny) / allow / fallthrough |
| `pre-commit-gates.sh` | commit | A1 trigger parser, A2 scope (>100 lines), A4 secret scan, A6 contract existence + staging (Decision 0018), state file verification (`plan-approved`/`cohesion-reviewed`/`qa-verified`/`pragmatist-signed`), scope classification (Decision 0017), high-risk pattern detection, inter-session governance | BLOCK (governance: advisory, first-fire) |
| `pre-push-gates.sh` | push | B1 naming convention | BLOCK |
| `session-close-check.sh` | stop | Session log, solo merge safety net (Decision 0015), completion marker validation (taskgroup-merge), branch sealing (Decision 0013), session registry cleanup, state file cleanup, override audit, governance evidence (task groups), next-brief reminder | BLOCK (audit/governance/reminder: advisory) |
| `agent-git-guard.sh` | Bash PreToolUse (subagents) | Blocks Builder/QA/Security from `git commit`/`git push` | BLOCK |
| `hvst-failure-tracker.sh` | Bash PostToolUse | Tracks consecutive Bash failures, prompts HVST protocol | advisory |
| `state-writer.sh` | SubagentStop | Captures `cohesion-reviewed`, `qa-verified`, `reviewer-signed`, `security-signed`, `pragmatist-signed` (subagent worktree: skip — Decision 0028; full worktree session: allow — Decision 0030) | — (state writer) |

Experiment branches: A4 only (all state checks skipped). Emergency recovery: `REPO_OS_RECOVER=1` skips all state-dependent checks and bash-guard gates. File-based signal: `.claude/.state/.recover-signal` (single-use, consumed by first hook). See Decision 0031.

Automation layer (Decision 0017): optional headless runner in `.claude/.automation/` — toggle via `runner.enabled: true` in `config.yaml` or create a `HALT` file to stop immediately. Supports 10 escalation types (gate-failure, governance-block, phase-tag-escalation, ambiguity, scope-exceeded, dependency-missing, security-risk, structural-change, scope-deviation, stale-branch). Worktree isolation default for all sessions (Decision 0033); opt-out: `REPO_OS_WORKTREE_ISOLATE=0`. See `docs/ai/workflow-appendix/session-type-automation.md` for full lifecycle, parity contract, and integration surface.

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
- docs/ai/prompts/prompt-h-hotfix-debug.md
- docs/ai/prompts/prompt-q-queue-triage.md
- docs/ai/prompts/prompt-t-task-definition.md

## Versioning
Template versions use CalVer git tags (e.g., `v2026.02.1`). Tags are auto-created on merge to `main` when Repo OS files change (`.github/workflows/auto-version-tag.yml`). See GitHub Releases for changelog.
