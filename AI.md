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
- docs/ai/workflow.md
- docs/ai/quality-gates.md
- docs/ai/decisions/
- docs/ai/logs/session-log.md (template mode: `.claude/local/session-log.md`)
- docs/ai/logs/known-issues.md (template mode: `.claude/local/known-issues.md`)
- docs/ai/governance/ (inter-session governance evidence)
- .claude/agents/orchestrator.md
- .claude/agents/_agent-glossary.md
- .claude/agents/_agent-workflow.md

On-demand (loaded by orchestrator.md triggers, not at session start):
- docs/spec/_templates/ (read during Prompt 0 only)
- .claude/agents/_advisory-board.md (read during Prompt A Phase 1)
- .claude/agents/_cohesion-review.md (read after Builder signals completion)
- .claude/agents/_hvst-review.md (read when HVST debugging stalls or operator requests debug review)
- docs/ai/task-groups/ (loaded when task brief contains `### Task Group`; template mode uses `.claude/local/task-groups/` for contracts)
- .claude/.state/task-contract.yaml (task contract — written at session init from brief text, read at cohesion review; Decision 0020)

Hooks (`.claude/hooks/`) enforce automatically via phase-aware flow management (Decision 0014): mode-based file restrictions on Edit/Write/Bash (blocks edits outside active mode scope — template/child/autonomous per `.claude/repo-mode`; non-template modes fast-exit after immune path check), branch protection on Edit/Write (blocks file changes on `main` via `branch-guard-edit.sh`), phase-aware edit gating on Edit/Write (blocks edits in init/plan phase via `branch-guard-edit.sh`), session overlap check on Edit/Write/Bash (blocks concurrent non-task-group sessions on same branch — advisory for task groups and taskgroup-merge, exempt for Prompt T; Decision 0013), session branch isolation on Edit/Write (blocks edits on branches from closed sessions — task groups exempt, Decision 0013), task group merge protection on Bash (blocks git checkout main / git merge for taskgroup/taskgroup-merge sessions — Decision 0018), plan-approval gate on Bash writes (blocks without operator-approved plan — experiment branches exempt), fail-closed phase enforcement on Edit/Write/Bash writes (blocks when phase-state absent and sentinel present — advisory when sentinel absent; Decision 0019), inter-session governance check on first Bash write or commit (advisory — warns if `spec-compiled` or `advisory-reviewed` missing), AskUserQuestion deny on AskUserQuestion PreToolUse (blocks `AskUserQuestion` in headless mode when `CLAUDE_HEADLESS=1` — defense-in-depth for automation sessions; interactive sessions pass through; Decision 0017), plan-approval capture on AskUserQuestion (writes `.claude/.state/plan-approved` when operator confirms a plan), PermissionRequest auto-approve on PermissionRequest (auto-approves curated tools and safe Bash patterns via `permission-request.sh`/`_permission-allowlist.sh`, denies dangerous Bash patterns like rm -rf/sudo/curl to external URLs, falls through to VS Code dialog for unknown commands; audit log at `.claude/.automation/logs/permission-audit.log` — Decision 0017), A4 secret scanning on commit (blocks), state file verification on commit (blocks without `plan-approved`/`cohesion-reviewed`/`qa-verified`), A2 scope >100 lines on commit (blocks unless large-scope approved), A6 task group contract existence on commit (blocks taskgroup/taskgroup-merge sessions without active contract — Decision 0018), A6 task group contract staging on commit (blocks if contract modified but not staged), scope classification on commit (compares staged files against task contract `scope_files` — out-of-scope blocks commit with escalation, unbriefed-in-scope writes advisory escalation with risk/gain context; Decision 0017), high-risk pattern detection on commit (blocks if risk patterns match and Reviewer/Security sign-offs missing), A1 decision trigger parser on commit (blocking — triggered decisions must be declared in Decisions: trailer), B1 naming convention on push (blocks), session log check on stop, override audit summary on stop (advisory — lists all governance overrides used), governance evidence verification on stop for task groups (advisory — warns if governance entry not written to contract), solo mode merge on stop (safety net — agent runs merge in close phase via write_merge_signal + git merge; hook retries if agent did not merge — Decision 0015), completion marker validation on stop for taskgroup-merge (checks `.claude/.state/tg-*-brief-*.complete` markers exist before allowing merge — parallel content briefs always skip merge), next-brief reminder on stop for task groups (advisory), branch sealing on stop (records branch in closed-branches ledger — Decision 0013; task group non-final briefs skip seal), session registry cleanup on stop (unregisters session, cleans stale entries), state file cleanup on stop (removes all session-scoped `.state/` files; taskgroup-merge also removes completion marker files). Experiment branches: A4 only (all state checks skipped). Emergency recovery: `REPO_OS_RECOVER=1` skips all state-dependent checks and branch-guard gates. Subagent frontmatter hooks block Builder/QA/Security from running git commit/push. Settings (`.claude/settings.json`) are auto-loaded by Claude Code. Neither hooks nor settings need to be read into context.

Automation layer (Decision 0017): optional headless runner infrastructure in `.claude/.automation/`. Schemas define contracts for queue entries, escalations (9 types: gate-failure, governance-block, phase-tag-escalation, ambiguity, scope-exceeded, dependency-missing, security-risk, structural-change, scope-deviation), blocker reports, and runner config. Default config (`config.yaml`) ships with `enabled: false`. Runtime artifacts (queue/, reports/, escalations/, briefs/, logs/) are gitignored. When enabled, runners invoke `claude -p` with full governance parity — same hooks, same gates, same phase model. Stop hook does not fire in headless mode; runners handle post-session tasks (solo merge, registry cleanup, branch sealing) externally. Toggle: set `runner.enabled: true` in `.claude/.automation/config.yaml` or create a `HALT` file to stop the daemon immediately. Standalone intake CLI (`lib/intake.sh`) creates queue entries without the interactive bridge — accepts brief path, session type, auto-approve, solo, and push flags; auto-enables the runner when entries are added. External integration surface includes queue validation (required fields, session type, branch name sanitization, opt-in HMAC), push_on_complete flag (per-entry opt-in branch push after session completion — solo pushes main, non-solo pushes feature branch), AskUserQuestion deny hook (PreToolUse — blocks interactive prompts in headless mode via `CLAUDE_HEADLESS=1` env var, defense-in-depth alongside `--disallowedTools`), decision cache (two-level merge with never-elevate rule, max 10 entries prepended to prompts), and flock-based file locking for queue mutations. Solo merge path includes merge conflict escalation: ff-only → no-ff fallback → on conflict, writes scope-deviation escalation with conflict file list and transitions entry to review. Scope classification model: scope-deviation escalations include `scope_classification` (briefed/unbriefed-in-scope/out-of-scope) and `risk_gain` (risk/gain context for operator review). Child-sync pipeline (`lib/child-sync.sh`) resolves GitHub org via three-tier fallback: `REPO_OS_GITHUB_ORG` env var → `# org:` directive in `child-repos.conf` → hardcoded default. Runner/stop-hook parity contract at `.claude/.automation/RUNNER-PARITY.md` maps every `session-close-check.sh` responsibility to its `runner.sh` equivalent — update when either path changes. See `docs/ai/workflow.md` § Automation Sessions for full runner lifecycle.

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
- docs/ai/prompts/prompt-t-task-definition.md

## Versioning
Template versions use CalVer git tags (e.g., `v2026.02.1`). Tags are auto-created on merge to `main` when Repo OS files change (`.github/workflows/auto-version-tag.yml`). See GitHub Releases for changelog.
