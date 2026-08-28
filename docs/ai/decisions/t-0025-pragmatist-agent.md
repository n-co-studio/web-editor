# Decision 0025 — Pragmatist Agent

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/agents/pragmatist\.md`
- keywords: `pragmatist, over-engineer, yagni, plan-review`

## Decision
Introduce a dual-mode Pragmatist agent that reviews implementation proposals for over-engineering, unnecessary complexity, and disproportionate approaches. Integrates at Prompt T (Brief-Advisory mode, always-on core specialist) and Prompt B (Plan-Gating mode, reviews implementation plans before build).

1. **Dual-mode design**: Two modes specified by Orchestrator in Task prompt:
   - **Brief-Advisory mode** (Prompt T): Dispatched as 4th core specialist alongside Architect, Exploration, and Critic. Uses standard advisory board brief format. No GATE_RESULT.
   - **Plan-Gating mode** (Prompt B): Dispatched during `plan` phase after Builder drafts the plan but before presenting to operator. Uses Reviewer-style format with GATE_RESULT sentinel.

2. **Review criteria**: Anchored to Fowler's YAGNI cost taxonomy (Cost of Build, Cost of Carry) with a falsifiable anti-pattern checklist. Each finding must include "This finding is wrong if: [condition]" for falsifiability.

3. **Custom severity levels**:
   - OVER-ENGINEERED (maps to RECOMMENDATION) — Disproportionate approach; simpler alternative exists
   - FUNDAMENTAL-MISMATCH (maps to CRITICAL) — Solution architecture fundamentally exceeds the problem space

4. **Plan-Gating verdict** (Prompt B only):
   - FUNDAMENTAL-MISMATCH → `GATE_RESULT: BLOCKED reason="..."`
   - OVER-ENGINEERED alone → `GATE_RESULT: APPROVED`
   - Auto mode degradation: BLOCKED degrades to advisory-with-warning (log finding, proceed, operator notified post-session). Prevents auto mode from becoming unresolvable while preserving signal.

5. **Boundary with Reviewer**: Pragmatist does NOT check implementation-level code style, function length, naming conventions, or test coverage — those are Reviewer territory. Pragmatist operates on proposals and plans, not code.

6. **State file**: `pragmatist-signed` — written by one of three legitimate paths, each stamping a provenance marker; the commit gate (`pre-commit-gates.sh`) requires at least one recognised marker after session_id validation:
   - **Writer 1** — `state-writer.sh` on SubagentStop (Pragmatist Plan-Gating dispatch): stamps `dispatch_phase:`.
   - **Writer 2** — `bundle_to_pragmatist_signed()` in `_phase-helper.sh` (Decision 0038 drift-check path): stamps `source: handoff-bundle`.
   - **Writer 3** — `write_alignment_check_pragmatist_signed()` in `_phase-helper.sh` (Orchestrator deterministic alignment-check, Decision 0038 §7): stamps `source: alignment-check`.
   A file carrying none of these markers is rejected as hand-written. The marker is a provenance signal, not a cryptographic boundary — this raises the bar from "trivially forgeable" to "deliberately forgeable" (Decision t-0004). Session-scoped, cleaned at close. **Do not write this file by hand**; use the appropriate helper.

7. **Triage guidance**: If a finding was addressed at Prompt T (Brief-Advisory), Prompt B mode should reference the prior resolution rather than re-flagging the same concern.

8. **Agent constraints**: Read-only (tools: Read, Glob, Grep; disallowed: Edit, Write, Bash, Task). Model: sonnet. First action: read `_advisory-board-lite.md` and `_agent-glossary.md`.

9. **Plan-Gating demotion to deterministic check (Decision 0038, amendment)**: When a valid handoff bundle is present at `.claude/local/handoff-bundle.yaml` AND the bundle (or contract) carries an `implementation_design:` field, Plan-Gating's alignment sub-mode is demoted to an Orchestrator-side deterministic check (`deterministic_alignment_check` in `_phase-helper.sh`). The Pragmatist is not dispatched in the aligned case — `pragmatist-signed` is written directly from `bundle.pragmatist.verdict` via `bundle_to_pragmatist_signed`. Full Pragmatist Plan-Gating dispatch is preserved for: (a) sessions without a bundle (legacy path), (b) bundles without `implementation_design` (no design to align against), (c) deterministic check returning `diverged` with operator declining to confirm the divergence.

## Context
Existing advisory board specialists (Architect, Critic, Exploration) identify structural gaps, logical errors, and alternatives — but none specifically targets disproportionate complexity. The Reviewer agent checks implementation-level code quality post-build but does not evaluate whether the chosen approach was proportionate to the problem. The Pragmatist fills this gap by catching over-engineering before implementation begins (Prompt T) and before plan approval (Prompt B).

The dual-mode design follows the Critic precedent (spec mode, cohesion mode, hypothesis mode) where the same agent serves different review functions depending on dispatch context. The GATE_RESULT sentinel follows the Reviewer/Critic cohesion pattern for mechanical state capture.

## Consequences
- `docs/ai/decisions/t-0025-pragmatist-agent.md` created (this file)
- `.claude/agents/pragmatist.md` created (dual-mode agent definition)
- `docs/ai/prompts/prompt-t-task-definition.md` updated: Pragmatist added as 4th core specialist in dispatch table, synthesis rules, and rules section
- `docs/ai/prompts/prompt-b-product-build.md` updated: Pragmatist dispatch during plan phase with GATE_RESULT
- `.claude/agents/_advisory-board.md` updated: Core pair → Core group (Architect, Critic, Pragmatist), activation logic, Refinement Report template
- `.claude/agents/_advisory-board-lite.md` updated: Pragmatist shared context added
- `.claude/agents/_agent-workflow.md` updated: Pragmatist in Subagent Reference tables, Build Flow, Handoff Chain
- `.claude/agents/_agent-glossary.md` updated: `pragmatist-signed` in State Files table
- `.claude/hooks/state-writer.sh` updated: captures `pragmatist-signed` state
- `docs/ai/quality-gates.md` updated: plan-review gate added
- `.claude/agents/orchestrator.md` updated: Pragmatist dispatch rules for both modes
- `AI.md` updated: state-writer hook description includes `pragmatist-signed`

### Amendment — Pragmatist-Signed Provenance (2026-08-07)

Closed the forgery hole identified on 2026-08-07: the original gate checked only existence and `session_id`, which a hand-written file could satisfy. Three legitimate writers now each stamp a distinct provenance marker; the gate accepts any recognised marker and rejects a file carrying none.

Changes:
- `§6` above updated: provenance marker requirement documented for all three writers
- `.claude/hooks/_phase-helper.sh` updated: `write_alignment_check_pragmatist_signed()` added (Writer 3 — alignment-check path)
- `.claude/hooks/pre-commit-gates.sh` updated: pragmatist-signed gate now requires `dispatch_phase:` OR `source: handoff-bundle` OR `source: alignment-check`
- `docs/ai/prompts/prompt-b-product-build.md` updated: "a session-derived equivalent" replaced with the named helper, with explicit guidance not to write the file by hand
