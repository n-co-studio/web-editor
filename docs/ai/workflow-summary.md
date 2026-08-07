# Workflow — Compressed Reference

> Compressed from `docs/ai/workflow.md` — update both when either changes.
> **Maintenance obligation:** update this file whenever `workflow.md` changes.
> Full file is authoritative. Load it in verify/commit phase, on ephemeral upgrade, or when detailed close-sequence reference is needed.

## Execution Loop

| Phase | Action |
|-------|--------|
| **Drift-check** | Evaluate handoff bundle. Valid + fresh → forward-jump to Build (skip Plan/Approval). Absent / stale → fall through to legacy Plan. Decision 0038 |
| **Plan** | (Legacy fallback) Goal, scope, files, verification steps |
| **Build** | Small, reviewable increments |
| **Verify** | Cohesion review (Critic), then gate checks (QA: A1-A6 + B) |
| **User Review** | Persona simulation dispatch (optional — when brief defines scenarios) |
| **Commit** | Only after all gates pass |

## Close Sequence

1. Knowledge graph update (advisory — Decision 0034): update the appropriate graph (`graph.yaml` for template, `product-graph.yaml` for product) via shell I/O if either exists — new nodes, new edges, updated `last_verified`. Cross-layer edges go in source node's graph. Non-blocking
2. Update session log (product: `docs/ai/logs/sessions/session-{id}.md`; template: `.claude/local/sessions/session-{id}.md`)
3. Commit all remaining changes including session log
4. Solo merge: handled by `session-close-check.sh` (stop hook) and/or runner — see `docs/ai/workflow.md` § Close Sequence step 4 for full detail
   - **Worktree sessions (default):** stop hook acquires merge lock, runs `git -C <main-repo-path> merge --ff-only <branch>` (fallback `--no-ff`), aborts on failure, syncs main working tree. Agent does NOT merge directly. Prohibited: `git checkout main`, `git branch -f main`, and other ref-move commands — they advance the pointer without updating the working tree (Decision t-0030)
   - **Non-worktree sessions (rare):** `git checkout main && git merge --ff-only <branch>` (fallback `--no-ff`); on success `write_merge_signal "<branch>"`; on failure `git merge --abort && git checkout <branch>`, notify operator
   - Post-merge push: `git push origin main` (advisory, skip template mode / no remote, never force-push)
5. Present closing summary — final agent message

Zero-change sessions: exempt from session log (stop hook downgrades to advisory).

## Git Trailer Convention
```
Session: N
Decisions: 0001, 0002
Gates-A: A1-pass A2-pass A3-n/a A4-pass A5-pass A6-n/a
Gates-B: B1-pass B2-n/a B3-n/a
```

## Session Lifecycle
| Rule | Detail |
|------|--------|
| **Init** | Create session branch first, before reading docs or writing files. Sessions run in worktrees by default (Decision 0033) |
| **Branch isolation** | One session per branch; sealed at close (Decision 0013; task groups exempt) |
| **Solo mode** | Merge to main at close for `feature/*`, `fix/*`, `hotfix/*`. Non-final task group briefs skip merge |
| **Overlap** | Registry blocks same-branch overlap (task groups: advisory only) |

## Branch Categories
| Category | Gate Profile |
|----------|-------------|
| `feature/*`, `fix/*` | Standard (A + B) |
| `hotfix/*` | Expedited: A2 relaxed, A5 skipped |
| `experiment/*` | A4 only; full gates required before merge to main |
| `release/*` | All gates + C gates (release checklist, Reviewer + Security sign-off) |
| `main` | All gates. No direct commits |

## Governance Layers

| Layer | Location | Enforcement |
|-------|----------|-------------|
| Inter-session pipeline | `docs/ai/governance/` | bash-guard + pre-commit-gates (advisory, first-fire) |
| Phase chain (task groups) | Contract `governance:` section | session-close-check (advisory) |
| Override audit | Per-session state `overrides.log` | session-close-check (summary at close) |
