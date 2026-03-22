# Decision 0029 — Operator Acknowledgment Enforcement

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/hooks/(_phase-helper|plan-approval)\.sh`
- keywords: `approval, has_operator_gate, taskdef-brief, plan-approved`

## Decision
Generalize operator-acknowledgment enforcement by renaming `taskdef-brief`'s `op-review` phase to `approval`. This activates the existing `has_plan_gate` / `advance_phase` substance check that requires a `plan-approved` state file before advancing to the post-approval phase.

### Problem
Prompt T `taskdef-brief` sessions had an `op-review` phase for operator brief approval, but `op-review` is not recognized by `has_plan_gate()` — only `approval` triggers the mechanical gate. The agent could bypass the gate by presenting brief approval as conversational text instead of via `AskUserQuestion`, advancing through `op-review` without the hook writing `plan-approved`.

### Implementation

1. **Phase rename**: `taskdef-brief` phase sequence changed from `init dispatch synthesize op-review output close` to `init dispatch synthesize approval output close`. The `get_tag_for_phase` mapping preserves the `operator` tag.

2. **Gate 1 broadening**: `plan-approval.sh` regex expanded from `\bplan\b` to `\b(plan|brief|task)\b` so that brief-approval AskUserQuestion calls (which mention "brief" or "task" rather than "plan") trigger `plan-approved` state file creation.

3. **`has_operator_gate` helper**: New function in `_phase-helper.sh` that returns 0 when `get_tag_for_phase(stype, phase)` equals `operator`. Structural scaffolding for future operator gate enforcement — no current consumers.

4. **Forensic coverage**: The existing forensic check in `session-close-check.sh` automatically covers `taskdef-brief` because `has_plan_gate("taskdef-brief")` now returns true.

### Phase naming convention
- **`approval`** — canonical name for operator-gated approval phases. Activates `has_plan_gate` enforcement, requires `plan-approved` state file, blocks `advance_phase` to the post-approval phase without evidence.
- **`op-review`** — operator review pause without mechanical enforcement. Used for post-commit review before close (standard, taskgroup, taskgroup-merge, editor-live) and non-gated review pauses (advisory-init, audit). Not renamed by this decision.

## Implication
Any future session type that needs operator approval enforcement can use the `approval` phase name and automatically receive `plan-approved` gate enforcement — no new state files or cleanup logic needed. The `has_operator_gate` helper provides a query interface for custom gate logic.

## Alternatives Considered

1. **Full generalized `operator-ack` state file**: New state file for all `operator`-tagged phases, new blocking branch in `advance_phase`. Rejected — 11 unresolved architectural concerns (session binding, cleanup, auto-mode deadlock, no recovery path for "revise" at op-review), touches hot path for marginal benefit.

2. **Minimal regex-only fix**: Broaden Gate 1 only, without phase rename. Rejected — would not activate the `advance_phase` substance check, leaving a force-advance path open.
