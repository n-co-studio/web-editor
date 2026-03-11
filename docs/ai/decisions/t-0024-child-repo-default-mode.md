# Decision 0024 — Child Repo Default Mode

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/repo-mode`
- path: `\.gitignore`
- path: `\.templatesyncignore`
- path: `\.claude/hooks/(session-close-check|pre-commit-gates|_automation-bridge)\.sh`
- keywords: `repo-mode, get_mode, IS_TEMPLATE, child, template, REPO_OS_MODE`

## Context
Child repos created from the template inherited a committed `.claude/repo-mode` file containing `template`. This required operators to manually change it to `child` after creating a repo — a step that was easy to miss. Missing this step caused the mode guard to enforce template restrictions in a child repo, blocking product code edits.

Three hooks (`session-close-check.sh`, `pre-commit-gates.sh`, `_automation-bridge.sh`) read mode directly from the file without checking the `REPO_OS_MODE` env var, creating inconsistency with the three-tier resolution chain used by `write-guard.sh` and `bash-guard.sh`.

## Decision
Make child repos default to `child` mode by removing `.claude/repo-mode` from git tracking:

1. **Gitignore**: `.claude/repo-mode` added to `.gitignore` (managed template section). File is no longer committed or tracked
2. **Template sync exclusion**: `.claude/repo-mode` added to `.templatesyncignore` so it is not synced to child repos
3. **Local file retained**: Template repo operators create `.claude/repo-mode` locally with `template` content. The file exists on disk but is not tracked by git
4. **Default behavior**: When `.claude/repo-mode` is absent (the default for child repos), all hooks default to `child` mode via the three-tier resolution chain: `REPO_OS_MODE` env var > `.claude/repo-mode` file > default `child`
5. **Hook harmonization**: `session-close-check.sh`, `pre-commit-gates.sh`, and `_automation-bridge.sh` now use `get_mode()` from `_analytics-helper.sh` instead of inline file reads. This aligns them with the three-tier resolution used by `write-guard.sh` and `bash-guard.sh`
6. **`install-hooks.sh` unchanged**: Reads the file directly with `child` as default — correctly handles absent file (skips install in child repos)

## Migration

### Existing child repos with committed `.claude/repo-mode = template`
Run once to fix:
```bash
git rm --cached .claude/repo-mode
rm -f .claude/repo-mode
```

### Template repo operators
After pulling this change, create the local file once:
```bash
echo "template" > .claude/repo-mode
```

## Consequences
- Child repos created from this template work correctly out of the box — no manual `.claude/repo-mode` step needed
- Template repo requires one-time local file creation (documented in migration section)
- All six mode-reading hooks now use consistent three-tier resolution
- `REPO_OS_MODE` env var works in all hooks, not just `write-guard.sh` and `bash-guard.sh`
- Decision 0012 immune path semantics are unchanged — string match fires regardless of file existence
