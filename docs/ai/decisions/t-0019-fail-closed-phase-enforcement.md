# Decision 0019 — Fail-Closed Phase Enforcement

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/hooks/(branch-guard|branch-guard-edit)\.sh`
- path: `docs/ai/decisions/\.fail-closed-enforced`
- keywords: `fail-closed, no_phase_state, phase_gate_no_state, .fail-closed-enforced`

## Decision
Change branch-guard.sh and branch-guard-edit.sh Gate 2 (phase gate) from fail-open to fail-closed when phase-state is absent on governed branches. An opt-in sentinel file controls rollout.

1. **Sentinel file**: `docs/ai/decisions/.fail-closed-enforced` (empty file). When present, absent or stale phase-state triggers a BLOCK. When absent, the same condition triggers an advisory warning and allows (backward compatibility). Mirrors the `.a1-triggers-enforced` sentinel convention — decision-scoped, opt-in.

2. **branch-guard.sh Gate 2** — the existing `else` branch (phase-state absent/stale) that previously set `ALLOW_REASON="no_phase_state"` now checks the sentinel:
   - Sentinel present → BLOCK with message directing the agent to call `init_phase()` via the orchestrator. Override: `REPO_OS_SKIP_PLAN_GATE=1`.
   - Sentinel absent → advisory warning + allow. Log event: `phase_gate_no_state_advisory`.

3. **branch-guard-edit.sh Gate 2** — the `if [ -n "$CURRENT_PHASE" ]` block previously had no `else` branch (empty phase fell through silently). Now adds an `else` with path exemptions (`.claude/.state/`, `.claude/local/`, governance, task-groups — same as the `init|plan` exemptions), `REPO_OS_SKIP_PLAN_GATE` override, and sentinel-based block/advisory logic. Path exemptions require jq to parse `file_path` from the payload (cost only on the absent-phase-state path).

4. **Stale phase-state** is already handled: `get_phase()` returns empty for both stale (session ID mismatch) and absent (file missing). Both conditions trigger the same fail-closed path. No additional code needed.

5. **No bootstrap deadlock**: `init_phase()` is called via Bash without redirect/tee in the command string, so `branch-guard.sh` fast-exits before Gate 2. The `branch-guard-edit.sh` hook does not fire on Bash calls (only Edit/Write). Phase-state bootstrap is unaffected.

## Context
The phase model (Decision 0014) is the primary enforcement mechanism for plan approval. However, Gate 2 in both branch guards was fail-open when phase-state was absent — an agent that never called `init_phase()` could bypass all phase-based governance simply by omitting the initialization call. This was a known gap accepted during initial rollout for backward compatibility, but with the phase model now mature and all session types defined, the gap should be closed.

The sentinel pattern enables incremental adoption: repos that haven't adopted the phase model yet continue with advisory-only behavior, while repos that opt in get full enforcement.

## Consequences
- `.claude/hooks/branch-guard.sh` Gate 2 else branch: fail-open replaced with sentinel check (~8 lines added)
- `.claude/hooks/branch-guard-edit.sh` Gate 2: else branch added after `if [ -n "$CURRENT_PHASE" ]` with sentinel check and `REPO_OS_SKIP_PLAN_GATE` override (~10 lines added). Override added to header comment
- `docs/ai/decisions/.fail-closed-enforced` sentinel file created (empty)
- `AI.md` hooks paragraph updated to document fail-closed phase enforcement
- Existing exemptions unaffected: experiment/* branches (exempt before Gate 2), `.claude/.state/` writes (exempt), `.claude/local/` writes (exempt), governance paths (exempt), session types without plan gate (exempt)
- Existing overrides unaffected: `REPO_OS_RECOVER=1` (fires before Gate 2 in both hooks), `REPO_OS_SKIP_PLAN_GATE=1` (fires before sentinel check in branch-guard.sh, added to branch-guard-edit.sh)
- No changes to `_phase-helper.sh`, `pre-commit-gates.sh`, `session-close-check.sh`, or `write-guard.sh`
