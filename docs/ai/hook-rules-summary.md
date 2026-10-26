# Hook Rules — Compressed Reference

> **Maintenance obligation:** update this file whenever hook blocking behavior changes in `bash-guard.sh`, `write-guard.sh`, or `pre-commit-gates.sh`.

| Condition | Hook | Recovery Action |
|-----------|------|-----------------|
| On `main` branch | bash-guard / write-guard (Gate 1) | `git checkout -b feature/<description>` |
| Plan not approved | bash-guard / write-guard (Gate 2) | Use `AskUserQuestion` to present plan for approval |
| No phase-state (fail-closed only) | bash-guard (Gate 2) | Call `init_phase()` via orchestrator (`REPO_OS_SKIP_PLAN_GATE=1`) |
| Task group brief mismatch | bash-guard / write-guard (Gate 2b) | Re-init with correct session type (`REPO_OS_SKIP_TASKGROUP_CHECK=1`) |
| Mode violation (template/child/autonomous) | bash-guard / write-guard (mode-guard) | Switch mode or use `REPO_OS_UNLOCK_PATH=<path>` |
| Sealed branch reuse | bash-guard / write-guard (Gate 5) | `git checkout -b <category>/<description>` (new branch) |
| Task group merge outside close phase | bash-guard (Gate 7) | Wait for close phase (`REPO_OS_SKIP_MERGE_GUARD=1`) |
| State files missing (plan/cohesion/qa/pragmatist) | pre-commit-gates | Dispatch agents in order: Pragmatist plan-gating → plan approval → Critic cohesion → QA verify |
| Phase re-init blocked | _phase-helper (init_phase) | Set `REPO_OS_ALLOW_REINIT=1`. **It clears this session's governance evidence** — the new work unit re-earns plan approval and every verdict (R40). The documented crash restart uses a *new* `REPO_OS_SESSION_ID` and takes a different branch, so it is unaffected |
| High-risk without sign-off | pre-commit-gates | Dispatch Reviewer + Security agents |
| Product file (in `coverage.yaml` scope) staged without a described node, or a renamed/deleted file's node left behind | pre-commit-gates (KG product-graph gate) | `bash .claude/tools/kg-cover.sh --target product <file>...` to scaffold, replace the `"Product source file"` description with what the file does (20+ chars), update/stale nodes for renames and deletions, then `git add docs/ai/knowledge-graph/product-graph.yaml`. `REPO_OS_SKIP_KG_GATE=1` (interactive only). Decision 0034 Amendment 9. |
| Product file staged, node fine, graph not staged and no `kg-updated` this session (FRESHNESS) | pre-commit-gates (KG product-graph gate) | Refresh the touched nodes and `git add docs/ai/knowledge-graph/product-graph.yaml` — `kg-cover.sh` writes no marker. Decision 0034 Amendment 9. |
| Secret detected (A4) | pre-commit-gates / session-close-check | Remove secret from staged files. Pattern: `_secret-pattern.sh` (single source of truth) |
| Cycle count >= 3 | _phase-helper (advance_phase) | Advisory only — review scope and complexity |
| Cycle count >= 5 | _phase-helper (advance_phase) + bash-guard (Phase 3c) | Advisory + escalation marker in `.claude/.state/cycle-escalation`. Consider decomposing task or requesting operator input |

Recovery: `REPO_OS_RECOVER=1` bypasses all state-dependent checks (emergency only). File-based signal: `.claude/.state/.recover-signal` (single-use, consumed by first hook). See Decision 0031.
