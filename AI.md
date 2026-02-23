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
- .claude/agents/orchestrator.md
- .claude/agents/_agent-glossary.md
- .claude/agents/_agent-workflow.md

On-demand (loaded by orchestrator.md triggers, not at session start):
- docs/spec/_templates/ (read during Prompt 0 only)
- .claude/agents/_advisory-board.md (read during Prompt A Phase 1)
- .claude/agents/_cohesion-review.md (read after Builder signals completion)
- .claude/agents/_hvst-review.md (read when HVST debugging stalls or operator requests debug review)
- docs/ai/task-groups/ (loaded when task brief contains `### Task Group`)

Hooks (`.claude/hooks/`) enforce automatically: branch protection on Edit/Write (blocks file changes on `main`), A4 secret scanning on commit, A6 task group contract staging check on commit (advisory), B1 naming convention on push, session log check on stop, PR reminder on stop for mergeable branches (advisory), next-brief reminder on stop for task groups (advisory). Subagent frontmatter hooks block Builder/QA/Security from running git commit/push. Settings (`.claude/settings.json`) are auto-loaded by Claude Code. Neither hooks nor settings need to be read into context.

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
