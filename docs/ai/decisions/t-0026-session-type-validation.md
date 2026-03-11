# Decision 0026 — Session-Type Validation for Task Group Briefs

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/hooks/(bash-guard|write-guard|_phase-helper)\.sh`
- keywords: `taskgroup_brief_mismatch, brief-has-taskgroup, check_taskgroup_brief_mismatch, write_taskgroup_brief_signal, REPO_OS_SKIP_TASKGROUP_CHECK`

## Decision
Add a mechanical check that detects when a brief contains `### Task Group` metadata but the session was initialized with a non-taskgroup session type. The mismatch is blocked at the first governed Bash write (bash-guard.sh Gate 2b) and first governed Edit/Write (write-guard.sh Gate 2b), before any implementation work can proceed.

1. **Fingerprint file**: The orchestrator writes `.claude/.state/brief-has-taskgroup` (via `write_taskgroup_brief_signal()`) when it detects a `### Task Group` section in the brief. This is a shell I/O write (bypasses write-guard.sh), following the same pattern as `write_merge_signal()`.

2. **Check function**: `check_taskgroup_brief_mismatch()` in `_phase-helper.sh`:
   - If `.claude/.state/brief-has-taskgroup` is absent → no-op (brief has no Task Group marker).
   - If `.claude/.state/phase-state` is absent → no-op (session type unknown).
   - If `session_type` is `taskgroup` or `taskgroup-merge` → allow.
   - Otherwise → **BLOCK** with message: "Brief contains ### Task Group but session type is '<type>' — expected 'taskgroup'. Re-initialize with init_phase("taskgroup")."

3. **Wiring**: The check is wired as Gate 2b in both bash-guard.sh (Phase 10) and write-guard.sh (Section 3), placed after Gate 2 (phase gate) and before Gate 6 (session overlap). At that point phase-state is guaranteed to exist (Gate 2 already ran).

4. **Override**: `REPO_OS_SKIP_TASKGROUP_CHECK=1` — bypasses the check and logs override via `log_override()`. Follows the existing override pattern (Decision 0004).

5. **Backward compatibility**: Repos that have never called `write_taskgroup_brief_signal()` have no fingerprint file. The check skips silently, preserving existing behavior.

6. **False-positive mitigation**: The `### Task Group` marker must appear in the actual brief section header (not in prose). The fingerprint is written explicitly by the orchestrator, not by parsing arbitrary text.

## Context
Three sessions in the token-usage-audit task group (Sessions 142–144) were initialized with `standard` session type instead of `taskgroup`. This caused:
- No `contract-init` phase → no task contract written → Critic had no `verification:` criteria
- Pre-commit gates passed without contract validation
- Premature merge to main without the taskgroup contract-update/op-review close sequence

Root cause: the enforcement gap was purely mechanical — the wrong session type was initialized without any check against the brief content. Decision 0018 added taskgroup merge protection but did not validate the session type at initialization. This decision closes that gap.

Decisions this extends:
- Decision 0018 — Mechanical Taskgroup Enforcement (extends enforcement scope to session-init)
- Decision 0020 — Task Contract System (this validation protects the contract-init phase)
- Decision 0014 — Phase-Aware Flow Model (session type determines phase sequence)
- Decision 0004 — Mechanical Enforcement (follows hook-based governance pattern)

## Consequences
- `docs/ai/decisions/t-0026-session-type-validation.md` created (this file)
- `.claude/hooks/_phase-helper.sh` updated: `write_taskgroup_brief_signal()` and `check_taskgroup_brief_mismatch()` added
- `.claude/hooks/bash-guard.sh` updated: Gate 2b wired after Gate 2, before Gate 6
- `.claude/hooks/write-guard.sh` updated: Gate 2b wired after Gate 2, before Gate 6
- `docs/ai/decisions/.a1-trigger-index` updated: entry for Decision 0026 added
- `docs/ai/decisions/t-manifest.txt` updated: `t-0026-session-type-validation.md` added
