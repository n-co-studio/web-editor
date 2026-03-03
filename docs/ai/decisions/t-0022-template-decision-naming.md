# Decision 0022 — Template Decision Naming Convention (`t-` Prefix)

## Status
Accepted

## Triggers

- type: file
- path: `docs/ai/decisions/`
- path: `.claude/hooks/write-guard.sh`
- path: `.claude/hooks/pre-commit-gates.sh`
- path: `.claude/.automation/lib/child-sync-decisions.sh`
- keywords: `t-prefix, t-manifest, template decision, decision naming, child-sync-decisions`

## Context
Template-owned decision records (0001–0021) were distinguished from child-created decisions (0100+) via a numeric-range convention. This relied on filename regex patterns (`0[1-9][0-9][0-9]-*.md`) in write-guard enforcement. While functional, the convention had two limitations:
1. **No visual distinction** — template and child decisions shared the same `NNNN-name.md` format, making it impossible to tell them apart at a glance or via simple glob
2. **No deletion propagation** — when a template decision is removed upstream, `actions-template-sync` (add/update-only) cannot delete it from child repos, leaving orphaned files

## Decision
Introduce a `t-` prefix naming convention for template-owned decision records:

1. **Template decisions** use the filename format `t-NNNN-name.md` (e.g., `t-0001-repo-os-baseline.md`). The `t-` prefix indicates template ownership. The numeric portion (`NNNN`) preserves the original decision number for continuity
2. **Child decisions** continue to use `NNNN-name.md` with numbers 0100+ (e.g., `0100-custom-linting.md`). No prefix, no change to existing child workflow
3. **Manifest file** (`docs/ai/decisions/t-manifest.txt`): A tracked file listing all current `t-*.md` filenames, one per line, sorted. Synced to child repos via template-sync. Serves as the authoritative source for the cleanup step — no network calls needed. Updated whenever template decisions are added, renamed, or removed
4. **Write-guard enforcement** (Decision 0012): Child mode explicitly blocks `t-*.md` paths (template decisions immutable in child repos) while continuing to allow `0[1-9][0-9][0-9]-*.md` (child decisions). Template mode allows all `docs/ai/decisions/*`. Supersedes the numeric-range convention (0001–0099 locked / 0100+ allowed)
5. **Cleanup helper** (`.claude/.automation/lib/child-sync-decisions.sh`): Reads `t-manifest.txt`, lists local `t-*.md` files, computes orphans (local files not in manifest), deletes them via `git rm`. Supports `--dry-run` for safety. Called by the template-sync workflow's cleanup step
6. **A1 trigger index** (`.a1-trigger-index`): Decision IDs remain numeric (0001, 0002, etc.) — the `t-` prefix is a filename convention, not an ID change. The `Decisions:` git trailer format is unchanged

### Migration (Child Repos)
After the first template-sync following this change, child repos will have both old-name files (`0001-*.md`) and new-name files (`t-0001-*.md`). A one-time cleanup is required:
1. Delete old-name files: `git rm docs/ai/decisions/0001-*.md` through `0021-*.md`
2. Add the cleanup step to `template-sync.yml` (from the reference workflow template)
3. Verify: `ls docs/ai/decisions/t-*.md` matches `t-manifest.txt`

## Consequences
- All 21 existing template decisions renamed from `NNNN-name.md` to `t-NNNN-name.md`
- `t-manifest.txt` serves as the single source of truth for which template decisions should exist in child repos
- Write-guard enforces the `t-` prefix boundary mechanically (Decision 0004)
- Template decisions are visually distinguishable from child decisions at a glance
- Orphaned template decisions can be detected and cleaned up automatically via the cleanup helper
- The `Decisions:` git trailer and A1 trigger system are unaffected (they use numeric IDs, not filenames)
