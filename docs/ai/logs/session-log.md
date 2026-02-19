# Session Log

Each session adds one entry. Keep entries high-signal and readable.

**Rotation:** Keep last 3 sessions here. Move older entries to `session-archive.md`.

---

## Session 2 — 2026-02-18 — Cohesion audit and cross-reference fixes

**Status:** complete
**Decisions applied:** 0001, 0002, 0003, 0004, 0005
**Commits:** 04f7520

### Goal
- Comprehensive audit of repo OS template for incohesion, disconnects, loose ends, and ambiguity
- Fix all 25 issues identified across 5 categories (broken references, terminology, workflow disconnects, loose ends, ambiguity)

### Plan Summary
- Remove stale references to deleted `docs/ai/references/` directory and `visual-bridge-spec.md`
- Align high-risk triggers across quality-gates.md, _agent-glossary.md, reviewer.md, and HTML explainer
- Make A2 scope check explicitly advisory (not blocking), matching enforcement audit findings
- Merge C/D gate tiers into single "C — Conditional + Release" with C1-C3 release gates
- Add HVST Record step consistently across all references
- Add shared file reading (First Action) to all executable agents per Decision 0003
- Add Builder escalation protocol, Decision 0005 card, Orchestrator identity note
- Move Companion Tools content from operator-guide.md to HTML explainer, then delete operator-guide.md
- Update file tree, prompt starters, and all cross-references in HTML explainer

### Changes Made
- `AI.md` — Added `session-archive.md` to source of truth index
- `docs/ai/decisions/0001-repo-os-baseline.md` — Added Commit 0 definition
- `docs/ai/decisions/0005-companion-tool-pattern.md` — Removed stale `docs/ai/references/` line, updated to HTML explainer reference
- `docs/ai/quality-gates.md` — A2 scope advisory, B1 high-risk aligned with glossary, C section expanded with C1-C3 release gates
- `.claude/agents/qa-verifier.md` — Added shared file reading, A2 scope advisory warning
- `.claude/agents/builder.md` — Added shared file reading, escalation protocol section
- `.claude/agents/reviewer.md` — Added First Action with shared file reading
- `.claude/agents/security-privacy.md` — Added First Action with shared file reading
- `.claude/agents/accessibility.md` — Added First Action with shared file reading
- `.claude/agents/_agent-glossary.md` — Added HVST definition in new Protocols section
- `docs/spec/_templates/integrations.md` — Removed stale `visual-bridge-spec.md` reference
- `docs/README.md` — Added HTML explainer mention
- `repo-os-explainer.html` — 20+ edits: fixed Decision 0001/0003 cards, added 0005 card, Orchestrator identity, HVST Record step, merged C/D gates, A2 advisory, hvst-failure-tracker.sh in hooks table, updated file tree, simplified prompt starters, added Companion Tools section
- `docs/operator-guide.md` — Deleted (all content now in HTML explainer)

### Verification (Gates Evidence)
- Commit gates: A1 pass (all 5 decisions followed), A2 pass (plan existed, scope advisory — 15 files, operator-approved audit), A3 n/a (no tooling), A4 pass (no secrets)
- Push gates: B1 pass (meaningful message), B2 n/a (no tests/typecheck), B3 n/a (no deps changed)
- Cross-reference review: automated reviewer agent verified 8 consistency checks — all PASS
- Override: committed directly to main (operator explicit override — template repo, no PR workflow active yet)

### Failed Attempts (Brief)
- Parallel Edit calls failed with "File has not been read yet" error despite prior reads — switched to sequential edits
- Background builder agents failed due to Edit permission denial in background mode — completed all edits in main session

### Known Issues Logged
- None

### Follow-ups
- Consider adding branch category awareness to pre-commit-gates.sh (carried from Session 1) → resolved in Session 3
- Builder commit/push enforcement is behavioral-only (no hook) → resolved in Session 3

---

## Session 3 — 2026-02-18 — Mechanical enforcement audit and implementation

**Status:** complete
**Decisions applied:** 0002, 0004
**Commits:** b520f7a, 98ce603, 263f06c

### Goal
- Audit all Repo OS rules for enforcement gaps (rules stated as blocking but with no mechanical enforcement)
- Implement mechanical enforcement for the critical gaps identified

### Plan Summary
- Add branch protection to `pre-commit-gates.sh` (block commits on `main`)
- Create `pre-push-gates.sh` with B1 naming convention check and B2/B3 stubs, wire in `settings.json`
- Create `agent-git-guard.sh` and add frontmatter `PreToolUse` hooks to Builder, QA, Security (block `git commit`/`git push`)
- Upgrade `session-close-check.sh` from advisory to blocking (`exit 2` with `stop_hook_active` guard)
- Update Decision 0004, AI.md, HTML explainer to reflect new enforcement layer
- Archive Session 1 per rotation policy

### Changes Made
- `.claude/hooks/pre-commit-gates.sh` — Added branch protection: blocks commits on `main` unless `REPO_OS_ALLOW_MAIN=1`
- `.claude/hooks/pre-push-gates.sh` — New: B1 branch naming convention (advisory), stubs for B2/B3 project-specific checks
- `.claude/hooks/agent-git-guard.sh` — New: blocks `git commit` and `git push` in subagents via `exit 2`
- `.claude/hooks/session-close-check.sh` — Upgraded from advisory to blocking: reads stdin JSON for `stop_hook_active` guard, exits 2 if session log not modified, override via `SKIP_SESSION_LOG=1`
- `.claude/settings.json` — Added `PreToolUse` matcher for `Bash(git push:*)`
- `.claude/agents/builder.md` — Added frontmatter `hooks.PreToolUse` wiring `agent-git-guard.sh`
- `.claude/agents/qa-verifier.md` — Added frontmatter `hooks.PreToolUse` wiring `agent-git-guard.sh`
- `.claude/agents/security-privacy.md` — Added frontmatter `hooks.PreToolUse` wiring `agent-git-guard.sh`
- `docs/ai/decisions/0004-mechanical-enforcement.md` — Expanded with all new enforcement mechanisms, override env vars, hook details
- `AI.md` — Updated hooks description to reflect full enforcement scope
- `repo-os-explainer.html` — Updated hooks table (6 rows), file tree (2 new files), customizing hooks paragraph
- `docs/ai/logs/session-archive.md` — Archived Session 1
- `docs/ai/logs/session-log.md` — Added Session 3, rotated Session 1 to archive

### Verification (Gates Evidence)
- Commit gates: A1 pass (decisions 0002/0004 followed), A2 pass (plan existed, scope documented), A3 n/a (no tooling), A4 pass (no secrets)
- Push gates: B1 pass (meaningful message), B2 n/a (no tests/typecheck), B3 n/a (no deps changed)
- Override: committed directly to main (operator explicit override — template repo, no PR workflow active yet)

### Failed Attempts (Brief)
- Investigated `disallowedTools` frontmatter for granular `Bash(git commit:*)` patterns — not supported, frontmatter only accepts full tool names. Used frontmatter `hooks` with `PreToolUse` matcher instead (documented pattern for this use case)

### Known Issues Logged
- None

### Follow-ups
- A1 (decision compliance) remains behavioral-only — shell scripts cannot meaningfully verify semantic decision compliance
- A3 quality gate stubs remain operator-customizable by design
- Orchestrator has no mechanical tool restrictions (by design per Decision 0004) — all constraints are behavioral

---

## Session 4 — 2026-02-18 — Add prototyping tier system (Napkin / Spike / PoC)

**Status:** complete
**Decisions applied:** 0001, 0002, 0004, 0006
**Commits:** aa09dba — feat(repo-os): add prototyping tiers and early branch protection

### Goal
- Add a tiered rapid prototyping system to repo-OS using existing `experiment/*` branch category
- Three tiers (Napkin / Spike / PoC) as operator-selected documentation levels, not gates
- Integrate into all source-of-truth files and the HTML explainer including decision navigator

### Plan Summary
- Create experiment brief template, Prompt 0.5 prototype prompt, Decision 0006
- Update AI.md, quality-gates.md, workflow.md, prompt-b-product-build.md, .templatesyncignore
- Add prototyping section to HTML explainer with operator language mapping, decision navigator path, glossary entries
- Run cohesion review to verify cross-reference integrity
- Move branch protection from commit-time to Edit/Write-time (branch-guard.sh)

### Changes Made
- `docs/spec/_templates/_experiment-brief.md` — New: experiment brief template (hypothesis, method, success criteria, time-box, learnings, disposition)
- `docs/ai/prompts/prompt-0.5-prototype.md` — New: prototype prompt with tier system, operator language mapping, per-tier entry/during/exit flows
- `docs/ai/decisions/0006-prototyping-tiers.md` — New: decision record for prototyping tiers
- `docs/spec/prototypes/.gitkeep` — New: directory for experiment briefs (protected from template sync)
- `AI.md` — Added prompt-0.5 to Prompts, `docs/spec/prototypes/` to Source of Truth
- `docs/ai/quality-gates.md` — `experiment/*` row references Prompt 0.5 and tiers
- `docs/ai/workflow.md` — Added Prototype Sessions subsection under Session Lifecycle
- `docs/ai/prompts/prompt-b-product-build.md` — Added Prototype Learnings section
- `.templatesyncignore` — Added `docs/spec/prototypes/`
- `repo-os-explainer.html` — Sidebar link, triggers row, full Prototyping section with operator language table, updated branch table, file tree, 0006 decision card, navigator path (3 tier sub-options), glossary entries, template sync table, branch-guard in hooks table
- `.claude/hooks/branch-guard.sh` — New: blocks Edit/Write on `main` before any work starts
- `.claude/settings.json` — Added PreToolUse matchers for Edit and Write → branch-guard.sh
- `.claude/hooks/pre-commit-gates.sh` — Removed branch protection (moved to branch-guard.sh)
- `docs/ai/decisions/0004-mechanical-enforcement.md` — Updated to reflect branch-guard.sh

### Verification (Gates Evidence)
- Commit gates: A1 pass (decisions 0001/0002/0004/0006 followed), A2 pass (plan existed, operator approved), A3 n/a (no tooling), A4 pending (pre-commit hook will run)
- Push gates: B1 pass (branch name `feature/prototyping-tiers`), B2 n/a, B3 n/a
- Cohesion review: reviewer agent verified all cross-references, terminology, governance chain, template sync safety, HTML structure — all PASS

### Failed Attempts (Brief)
- Initial prototype prompt written without tier system — operator caught the omission, rewrote with full tier support
- Started work on `main` instead of branching first — operator caught, moved to `feature/prototyping-tiers` (no commits were made on main)
- Session log not updated proactively — operator caught the gap

### Known Issues Logged
- None

### Follow-ups
- Agent glossary could add "experiment brief" and "prototype tier" terms (optional)
- Experiment branch merge prevention is convention-only, not mechanically enforced (intentional — documented in Decision 0006)

---

## Session <N> — <YYYY-MM-DD> — <Short Goal>

**Status:** complete | incomplete
**Decisions applied:** <0001, 0002, ... | None>
**Commits:** <hash — message | None>

### Goal
- <What we were trying to achieve>

### Plan Summary
- <Bullets of the chosen approach>

### Changes Made
- <Bullets of what changed>

### Verification (Gates Evidence)
- Commit gates: pass/fail
- Push gates: pass/fail/n-a
- Evidence:
  - <command> → <pass/fail summary>

### Failed Attempts (Brief)
- <1-line bullets: what was tried + why it failed>

### Known Issues Logged
- <New entries added to known-issues.md, or "None">

### Follow-ups
- <Next tasks / known issues>
