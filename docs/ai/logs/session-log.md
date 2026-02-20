# Session Log

Each session adds one entry. Keep entries high-signal and readable.

**Rotation:** Keep last 3 sessions here. Move older entries to `session-archive.md`.

---

<!-- Template: copy this block for each new session entry

## Session N — YYYY-MM-DD — Brief description

**Status:** in-progress | complete
**Decisions applied:** [comma-separated IDs]
**Commits:** [hash — message]

### Goal
- [What this session set out to accomplish]

### Plan Summary
- [Key steps taken]

### Changes Made
- `path/to/file` — [what changed]

### Verification (Gates Evidence)
- Commit gates: A1 [pass/n-a], A2 [pass/n-a], A3 [pass/n-a], A4 [pass/n-a], A5 [pass/n-a]
- Push gates: B1 [pass/n-a], B2 [pass/n-a], B3 [pass/n-a]

### Failed Attempts (Brief)
- [None / brief description]

### Known Issues Logged
- [None / reference to known-issues.md entry]

### Follow-ups
- [Items deferred or discovered]

-->

## Session 16 — 2026-02-20 — Fix template-sync auth, permissions, and docs

**Status:** complete
**Decisions applied:** none
**Commits:** pending

### Goal
- Fix template-sync workflow failing in child repos (private template repo requires PAT)
- Reduce sync frequency from hourly to daily to conserve GitHub Actions minutes
- Document PAT setup requirement for operators

### Plan Summary
- Iteratively debugged 5 distinct failure modes across 6 workflow triggers
- Fixed auth chain: classic PAT → persist-credentials: false → source_gh_token → target_gh_token → .templatesyncignore → repo settings
- Updated template repo and pushed fixes to child repo (markpreston.co) via GitHub API
- Verified end-to-end: sync PR #6 created and merged in markpreston.co

### Changes Made
- `.github/workflows/template-sync.yml` — Daily cron, `persist-credentials: false`, `source_gh_token`, `target_gh_token`, updated inline PAT comments (classic PAT + repo + read:org)
- `.templatesyncignore` — Added `.github/workflows/template-sync.yml` (GITHUB_TOKEN cannot push workflow changes; also prevents overwriting repo-specific config)
- `repo-os-explainer.html` — Updated PAT instructions to classic PAT (not fine-grained), added repo settings step for "Allow GitHub Actions to create PRs"
- `docs/ai/logs/known-issues.md` — Logged template-sync debugging chain (Session 16)
- `docs/ai/logs/session-archive.md` — Archived Sessions 12 and 13
- `docs/ai/logs/session-log.md` — Rotated Sessions 12/13, updated Session 16

### Verification (Gates Evidence)
- Commit gates: A1 n/a, A2 pass, A3 n/a, A4 pass, A5 n/a (docs + workflow only)
- Push gates: B1 pass, B2 n/a, B3 n/a

### Failed Attempts (Brief)
- Fine-grained PAT: incompatible with git clone in GitHub Actions
- Missing `read:org` scope on classic PAT
- `actions/checkout` extraheader overriding PAT (fixed with `persist-credentials: false`)
- Push failed after removing credentials (fixed with `target_gh_token`)
- `GITHUB_TOKEN` cannot push workflow files (fixed with `.templatesyncignore`)
- Stale sync branch caused action to skip (deleted branch, re-triggered)
- Repo settings blocked PR creation (enabled via API)

### Known Issues Logged
- Template sync debugging chain logged to known-issues.md (Session 16)

### Follow-ups
- None — template sync verified end-to-end

---

## Session 15 — 2026-02-19 — Fix stop hook session weight and baseline hash bugs

**Status:** complete
**Decisions applied:** 0004
**Commits:** pending

### Goal
- Fix two unresolved known issues in `session-close-check.sh`:
  - Session 13: Stop hook blocks again after first block (stale baseline hash)
  - Session 14: Stop hook blocks on zero-change sessions (no session weight concept)

### Plan Summary
- Ran Lite advisory board (Architect + Critic) on proposed fix design
- Architect: 3 critical (hash path safety, timing window, bootstrap dependency), 3 recommendations, 2 ideas
- Critic: 4 critical (SKIP_SESSION_LOG stale hash, timing window, stash/reset false positive, race condition), 4 recommendations, 2 ideas
- Synthesized refinement report; operator approved all items including governance doc updates
- Cohesion review + QA caught missing `.gitignore` entry and terminology mismatch — fixed

### Changes Made
- `.claude/hooks/session-close-check.sh` — Restructured: `update_baseline()` + `cleanup_hvst()` functions, session weight detection via baseline SHA, blocking exit never updates baseline
- `AI.md` — Zero-change session exemption in non-negotiables
- `docs/ai/workflow.md` — Zero-change session exemption in Session Lifecycle
- `docs/ai/decisions/0004-mechanical-enforcement.md` — Updated Stop hook description
- `docs/ai/logs/known-issues.md` — Marked Session 13 + 14 issues as fixed
- `.gitignore` — Added `.session-baseline-sha`, updated comment
- `repo-os-explainer.html` — Hook description in table + file tree
- `docs/ai/logs/session-archive.md` — Archived Session 11
- `docs/ai/logs/session-log.md` — Rotated Session 11, added Session 15

### Verification (Gates Evidence)
- Commit gates: A1 pass, A2 pass, A3 pass (bash -n), A4 pass, A5 pass (cohesion clean after fixes)
- Push gates: B1 pass, B2 n/a, B3 n/a

### Failed Attempts (Brief)
- Initial proposal used `git log --since="4 hours ago"` — both advisory specialists flagged unreliable. Replaced with stored baseline commit SHA.

### Known Issues Logged
- Session 13 + 14 entries updated with fix details

### Follow-ups
- Push and create PR to merge to main

