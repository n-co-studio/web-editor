# Decision 0023 — Editor-Live Session Type

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/hooks/_phase-helper\.sh`
- path: `\.claude/\.state/phase-state`
- keywords: `editor-live, fswatch, visual change, pending_visual_changes, acknowledge_visual_change, commit:build`

## Decision
Add an `editor-live` session type for continuous visual-development workflows where the operator edits files in an external editor and the agent responds to each saved change. The session type is registered in the phase model (Decision 0014) with a novel loop topology.

1. **Session type**: `editor-live`. Registered in `_phase-helper.sh` as a session type in the Decision 0014 enum (17 types total).

2. **Phase sequence**:
   `init[agent] → build[agent] → commit[agent] → review[agent] → verify[agent] → op-review[operator] → close[agent]`

   No `plan` or `approval` phases — the operator's live edits are the plan. The agent enters `build` immediately after `init` and responds to file-change signals.

3. **Loops**: `commit:build` (return to build after committing to handle the next change), `verify:build` (QA failure triggers rebuild).

   The `commit:build` loop is a novel backward transition — the first in the system where the `commit` phase loops back to `build`. The `advance_phase` function handles this correctly: registered loop pairs bypass forward-only index validation (line ~419-433 in `_phase-helper.sh`).

4. **Automation tags**: All phases tagged `agent` except `op-review` → `operator`. The operator interacts through the external editor, not through phase-level approval gates.

5. **Gate profile**: A4 (safety) enforced per commit within the build-commit loop. Full gates (A5 cohesion + QA verification) enforced at the `review`/`verify` phases before close. This gives lightweight per-iteration safety with comprehensive final review.

6. **Signal mechanism**: Tracked status file + filesystem watcher. The MCP server writes a change record when the operator saves a file. The agent polls via `get_pending_visual_changes` MCP tool to detect new changes.
   - **macOS/Linux**: `fswatch` monitors the project directory for file saves
   - **Fallback**: `inotifywait` (Linux) when `fswatch` is unavailable
   - **Change record**: Status file in `.claude/.state/` tracks pending visual changes with file path, timestamp, and change type

7. **MCP integration**: Two MCP tools provide the agent-facing interface:
   - `get_pending_visual_changes` — returns list of files changed since last acknowledgment
   - `acknowledge_visual_change` — marks a change as processed, advancing the agent to respond to the next change

8. **Close signal**: The operator sends the structural keyword "close session" to signal the end of the editor-live session. The agent then advances through `review → verify → op-review → close`.

9. **Cycle advisory**: At 50 build-commit iterations, the agent emits an advisory suggesting the operator close the session to maintain context quality. Not a hard limit — the operator may continue.

10. **Operating mode**: Child mode only. Template mode has no product code to visually edit. Autonomous mode has no operator for live interaction.

11. **Plan gate**: `has_plan_gate("editor-live")` returns false (1) — no `approval` phase in the sequence. The plan-approval hook and plan-gate enforcement do not apply.

12. **Cross-platform**: `fswatch` is the primary watcher (available on macOS via Homebrew and Linux via package managers). `inotifywait` (from `inotify-tools`) serves as the Linux fallback. The MCP server detects availability at startup and selects the appropriate backend.

## Context
Standard build sessions require a plan-approval gate before entering the build phase. Editor-live sessions invert this: the operator works in an external editor (e.g., VS Code, Figma export, design tool), and the agent responds to each saved change. The plan is implicit in the operator's edits. The `commit:build` loop enables the agent to commit completed work and return to the build phase for the next change — a topology not needed by any existing session type.

The variant-within-standard approach was considered but rejected because the phase topology is fundamentally different (no plan gate, commit:build loop). The experiment session type was also considered but rejected because experiments lack review/verify at close and are scoped to `experiment/*` branches.

## Consequences
- `.claude/hooks/_phase-helper.sh` updated: `editor-live` added to `get_phases_for_type`, `get_loops_for_type`, `get_tag_for_phase`
- Decision 0014 amended: session type enum incremented to 17 (also added missing `ephemeral`), `editor-live` added to enum list and phase sequence documentation
- `.claude/agents/_agent-glossary.md` updated: `editor-live` phase definitions added to Phase Model section
- `docs/ai/decisions/t-manifest.txt` updated: `t-0023-editor-live-session-type.md` added
- `docs/ai/decisions/.a1-trigger-index` regenerated to include Decision 0023 triggers
- No new hooks, no new state files (uses existing `.claude/.state/` infrastructure)
- `write-guard.sh` updated: `editor-live` added to phase-exempt session types (Gate 2, Section 3) — allows edits in `init` phase without plan gate
- `_permission-allowlist.sh` updated: `fswatch`/`inotifywait` added to safe Bash command prefixes
- No changes to `bash-guard.sh` (`has_plan_gate` implicitly handles `editor-live` — no `approval` phase)
- `pre-commit-gates.sh` updated: editor-live detection with per-loop (A4 only) and close (full gates minus plan-approved) commit profiles
