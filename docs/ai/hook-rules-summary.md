# Hook Rules — Compressed Reference

> **Maintenance obligation:** update this file whenever hook blocking behavior changes in `bash-guard.sh`, `write-guard.sh`, or `pre-commit-gates.sh`.

| Condition | Hook | Recovery Action |
|-----------|------|-----------------|
| On `main` branch | bash-guard / write-guard (Gate 1) | `git checkout -b feature/<description>` |
| Plan not approved | bash-guard / write-guard (Gate 2) | Use `AskUserQuestion` to present plan for approval |
| No phase-state (fail-closed only) | bash-guard (Gate 2) | Call `init_phase()` via orchestrator (`REPO_OS_SKIP_PLAN_GATE=1`) |
| Mode violation (template/child/autonomous) | bash-guard / write-guard (mode-guard) | Switch mode or use `REPO_OS_UNLOCK_PATH=<path>` |
| Sealed branch reuse | bash-guard / write-guard (Gate 5) | `git checkout -b <category>/<description>` (new branch) |
| Task group merge outside close phase | bash-guard (Gate 7) | Wait for close phase (`REPO_OS_SKIP_MERGE_GUARD=1`) |
| State files missing (plan/cohesion/qa) | pre-commit-gates | Dispatch agents in order: plan approval → Critic cohesion → QA verify |
| High-risk without sign-off | pre-commit-gates | Dispatch Reviewer + Security agents |
| Secret detected (A4) | pre-commit-gates | Remove secret from staged files |

Recovery: `REPO_OS_RECOVER=1` bypasses all state-dependent checks (emergency only).
