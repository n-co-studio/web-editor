# Repo OS

## Non-negotiables
- The operator creates and manages GitHub repositories (org/visibility/credentials). Agents must not do this.
- No code changes without a plan.
- Work happens in small, verifiable increments.
- **Gates must pass before commits (and before any push).**
- **Accepted decisions are mandatory. Decision violations block commits.**
- Session log is updated at session close. Zero-change sessions (no commits, no working tree changes) are exempt — the hook downgrades to advisory. Agent asks operator about PR to main for mergeable branches — never skip without operator direction.

## Authority
Operator-only:
- Create GitHub repo, manage org/user/visibility/credentials
- Decide when/where to push

Agent-allowed:
- Read/write files, run local commands
- Git operations (status/add/commit) once gates pass
- Push only when gates pass

## Source of Truth
- docs/spec/compiled/ (active version per manifest.json)
- docs/spec/prototypes/ (experiment briefs and prototype learnings)
- docs/ai/workflow.md
- docs/ai/quality-gates.md
- docs/ai/decisions/
- docs/ai/logs/session-log.md
- docs/ai/logs/known-issues.md
- docs/ai/governance/ (inter-session governance evidence)
- .claude/agents/orchestrator.md
- .claude/agents/_agent-glossary.md
- .claude/agents/_agent-workflow.md

On-demand (loaded by orchestrator.md triggers, not at session start):
- docs/spec/_templates/ (read during Prompt 0 only)
- .claude/agents/_advisory-board.md (read during Prompt A Phase 1)
- .claude/agents/_cohesion-review.md (read after Builder signals completion)
- .claude/agents/_hvst-review.md (read when HVST debugging stalls or operator requests debug review)
- docs/ai/task-groups/ (loaded when task brief contains `### Task Group`)

Hooks (`.claude/hooks/`) enforce automatically: mode-based file restrictions on Edit/Write/Bash (blocks edits outside active mode scope — template/child/autonomous per `.claude/repo-mode`), branch protection on Edit/Write (blocks file changes on `main`), plan-approval gate on Edit/Write (blocks edits without operator-approved plan — experiment branches exempt), inter-session governance check on first Edit/Write (advisory — warns if `spec-compiled` or `advisory-reviewed` missing), phase chain verification on first Edit/Write for task groups (advisory — warns if prior brief lacks governance evidence), plan-approval capture on AskUserQuestion (writes `.claude/.state/plan-approved` when operator confirms a plan), A4 secret scanning on commit (blocks), state file verification on commit (blocks without `plan-approved`/`cohesion-reviewed`/`qa-verified`), A2 scope >100 lines on commit (blocks unless large-scope approved), A6 task group contract staging on commit (blocks if contract modified but not staged), high-risk pattern detection on commit (blocks if risk patterns match and Reviewer/Security sign-offs missing), A1 decision trigger parser on commit (blocking — triggered decisions must be declared in Decisions: trailer), B1 naming convention on push (blocks), session log check on stop, override audit summary on stop (advisory — lists all governance overrides used), governance evidence verification on stop for task groups (advisory — warns if governance entry not written to contract), PR reminder on stop for mergeable branches (advisory), next-brief reminder on stop for task groups (advisory), state file cleanup on stop (removes all session-scoped `.state/` files). Experiment branches: A4 only (all state checks skipped). Emergency recovery: `REPO_OS_RECOVER=1` skips all state-dependent checks and branch-guard gates. Subagent frontmatter hooks block Builder/QA/Security from running git commit/push. Settings (`.claude/settings.json`) are auto-loaded by Claude Code. Neither hooks nor settings need to be read into context.

## Spec Convention
- **Templates** (`docs/spec/_templates/`): Blank spec files with placeholder fields. Synced from the upstream template repo. Do not fill these directly.
- **Compiled** (`docs/spec/compiled/`): Operator-filled specs, organized by version. Created by Prompt 0.
- **Feature Briefs** (`docs/spec/compiled/{active}/features/brief-{name}.md`): Lightweight feature specs for individual feature additions. Created by Prompt 0 Feature mode. Template at `docs/spec/_templates/feature-brief.md`.
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
