# Decision 0014 — Phase-Aware Flow Model

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/hooks/_phase-helper\.sh`
- path: `\.claude/\.state/phase-state`
- keywords: `phase, session_type, init_phase, advance_phase, assert_phase, phase-state, get_phase, get_tag, taskgroup-merge, editor-live`
- enforced_by: `.claude/hooks/_phase-helper.sh`

## Decision
Add a phase-aware flow management system that tracks session progress through an ordered sequence of phases. Replaces implicit phase detection with an explicit state machine:

1. **Phase-state file**: `.claude/.state/phase-state` (session-scoped, key-value format). Fields:
   - `session_type` — one of the 17 session type enum values
   - `session_id` — bound to `.claude/.session-id` for staleness protection
   - `mode` — `auto` or `review` (default: `review`)
   - `current_phase` — the phase the session is currently in
   - `cycle` — build iteration counter (starts at 1, increments on loop-back to build)
   - `phases_completed` — comma-delimited list of completed phases
   - `solo` — merge strategy flag (`true` or `false`, default: `false`) — see Decision 0015
   - `tag` — automation tag for the current phase (`agent`, `operator`, or `both`)
   - `timestamp` — ISO 8601 UTC timestamp of last phase transition

2. **Session type enum** (17 types):
   - Prompt B: `standard`, `taskgroup`, `taskgroup-merge`, `hotfix`, `experiment`, `editor-live`
   - Prompt 0: `spec-fresh`, `spec-update`
   - Prompt 0.5: `prototype-napkin`, `prototype-spike`, `prototype-poc`
   - Prompt A: `advisory-init`, `advisory-reinit`
   - Prompt C: `audit`
   - Prompt T: `taskdef-query`, `taskdef-brief`
   - Ephemeral: `ephemeral`

3. **Phase sequences** — each session type defines an ordered list of phases with automation tags. Transitions are forward-only except for defined loops. Full sequences:

   **Prompt B — Standard Build:**
   `init[agent] → plan[agent] → approval[operator] → build[agent] → review[agent] → verify[agent] → user-review[agent] → commit[agent] → op-review[operator] → close[agent]`
   Loops: `review→build` (cohesion findings), `verify→build` (QA failure)
   Skippable: `user-review` — forward-jump from `verify` to `commit` permitted when the task brief has no User Review section. Advisory-only phase — no state file written, no gate blocked. See Decision 0021 for system definition.

   **Prompt B — Task Group (Brief N of M):**
   `init[agent] → contract-init[agent] → plan[agent] → approval[operator] → build[agent] → review[agent] → verify[agent] → user-review[agent] → commit[agent] → contract-update[agent] → op-review[operator] → close[agent]`
   Loops: `review→build`, `verify→build`
   Skippable: `user-review` — same rules as Standard Build.
   Notes: `contract-init` covers create (brief 1) and sync (briefs 2+) — same phase, different behavior based on brief number. Non-final close skips merge (branch stays open). Final close merges to main. `contract-init` is intentionally outside the `init|plan` edit block in `write-guard.sh (Section 3)` — edits during contract-init are scoped to contract file creation/update and are permitted by existing path exemptions (`docs/ai/task-groups/`, `.claude/local/`).

   **Prompt B — Task Group Merge (Brief M — parallel groups):**
   `init[agent] → contract-init[agent] → cohesion[agent] → verify[agent] → commit[agent] → op-review[operator] → close[agent]`
   Loops: `cohesion→cohesion` (self-loop — integration fixes found during cross-session review)
   Notes: No `plan`/`approval`/`build` phases — the merge brief reviews and integrates, it doesn't build. `cohesion` phase is unique to this type — agent runs cross-session cohesion review across the combined diff from all parallel briefs. `has_plan_gate` returns false (no approval phase). Close always merges to main and seals the branch (merge brief is always the final brief).

   **Prompt B — Hotfix:**
   `init[agent] → plan[agent] → approval[operator] → build[agent] → verify[agent] → commit[agent] → close[agent]`
   Loops: `verify→build`
   Notes: No review phase (A5 cohesion skipped). A2 scope relaxed in verify.

   **Prompt B — Experiment:**
   `init[agent] → build[agent] → commit[agent] → close[agent]`
   Notes: No plan phase (experiment brief is the plan). A4 safety only at commit.

   **Prompt B — Editor-Live:**
   `init[agent] → build[agent] → commit[agent] → review[agent] → verify[agent] → op-review[operator] → close[agent]`
   Loops: `commit→build` (next change iteration), `verify→build` (QA failure)
   Notes: No plan phase (operator's live edits are the plan). `commit:build` is a novel backward transition — the first from the `commit` phase. A4 safety per-loop commit; full gates (A5 + QA) at final review/verify before close. Child mode only. Cycle advisory at 50 iterations. `has_plan_gate` returns false (no approval phase).

   **Prompt 0 — Spec Builder (Fresh):**
   `init[agent] → interview[both] → write[agent] → approval[operator] → governance[agent] → close[agent]`

   **Prompt 0 — Spec Builder (Update):**
   `init[agent] → interview[both] → write[agent] → approval[operator] → governance[agent] → close[agent]`

   **Prompt 0.5 — Prototype (Napkin):**
   `init[agent] → build[agent] → close[agent]`

   **Prompt 0.5 — Prototype (Spike):**
   `init[agent] → build[agent] → evaluate[both] → close[agent]`

   **Prompt 0.5 — Prototype (PoC):**
   `init[agent] → build[agent] → evaluate[both] → document[agent] → close[agent]`

   **Prompt A — Advisory Review (Initialize):**
   `init[agent] → tier-select[both] → dispatch[agent] → synthesize[agent] → op-review[operator] → validate[agent] → governance[agent] → close[agent]`

   **Prompt A — Advisory Review (Re-initialize):**
   `init[agent] → validate[agent] → governance[agent] → close[agent]`

   **Prompt C — Project Audit:**
   `init[agent] → scope[both] → dispatch[agent] → synthesize[agent] → op-review[operator] → close[agent]`

   **Prompt T — Task Definition (Query):**
   `init[agent] → conversation[both] → close[agent]`

   **Prompt T — Task Definition (Brief):**
   `init[agent] → dispatch[agent] → synthesize[agent] → op-review[operator] → output[agent] → close[agent]`

4. **Phase-to-gate-profile mapping** — which gates apply varies by session type and is enforced at `verify`/`commit` phases:
   - `standard`, `taskgroup`, `taskgroup-merge`: Full gates (A1–A6, B1–B3). A6 applies only to taskgroup/taskgroup-merge
   - `editor-live`: A4 per-loop commit; full gates (A1–A5, B1–B3) at final review/verify. A6 n/a (not a task group type)
   - `hotfix`: Expedited (A2 scope relaxed, A5 skipped)
   - `experiment`, `prototype-*`: A4 safety only
   - `spec-fresh`, `spec-update`: Advisory only (governance evidence at close)
   - `advisory-init`, `advisory-reinit`: Advisory only (governance evidence at close)
   - `audit`: Read-only (no gates unless deferrals create file changes)
   - `taskdef-query`, `taskdef-brief`: No gates (fully ephemeral)

5. **Session ID binding** — `init_phase` reads the session ID from `.claude/.session-id` (guaranteed to exist via `get_session_id()` in `_analytics-helper.sh`). Every `assert_phase`, `get_phase`, and `advance_phase` call validates that the `session_id` in phase-state matches the current `.session-id`. Mismatch means the phase-state is stale (leftover from a crashed or prior session) and is treated as absent.

6. **Automation tag definitions**:
   - `agent` — agent proceeds autonomously, no pause point
   - `operator` — agent queues for operator review/decision before advancing
   - `both` — agent and operator work concurrently (e.g., interview, evaluation)

7. **Auto/review mode semantics**:
   - `auto` — agent closes the session autonomously after all gates pass. The `op-review` phase is skipped (forward transition past it)
   - `review` — agent pauses at `op-review` for operator acceptance. Operator may accept (→ close), give feedback (→ build), or reject (→ close without merge)
   - Default: `review` (conservative)
   - Task group pre-approval: operator sets `auto` for the entire group at Prompt T time. Individual briefs inherit the mode without re-prompting. The `approval` phase auto-passes for pre-approved groups

8. **Transition rules**:
   - Forward-only: `advance_phase` validates that the target phase appears after the current phase in the session type's sequence
   - Defined loops: `review→build` and `verify→build` for standard, taskgroup (hotfix has `verify→build` only; taskgroup-merge has `cohesion→cohesion` self-loop; editor-live has `commit→build` and `verify→build`). Each loop-back increments the `cycle` counter
   - All other backward transitions are illegal and return error
   - Skipping phases is allowed (forward jumps) — enables auto mode to skip `op-review`

9. **State guard bypass**: `_phase-helper.sh` writes to `.state/phase-state` via shell I/O (`printf ... > "$state_file"`). This bypasses `write-guard.sh`, which only intercepts model tool calls (PreToolUse on Edit/Write/Bash). This is the established pattern — all hook-written state files (`plan-approved`, `cohesion-reviewed`, `qa-verified`, `governance-checked`, `high-risk-detected`) use shell I/O to bypass the state guard

10. **Helper functions** in `.claude/hooks/_phase-helper.sh`:
    - `init_phase <session_type>` — creates phase-state with session_id, sets current_phase to `init`
    - `advance_phase <new_phase>` — validates transition legality, updates current_phase, appends prior phase to phases_completed, updates tag and timestamp
    - `assert_phase <required_phase>` — returns 0 if current phase index >= required phase index (stale-safe)
    - `get_phase` — returns current phase (empty if missing or stale)
    - `get_phase_mode` — returns auto/review mode (default: review). Named `get_phase_mode` to avoid collision with `get_mode` in `_analytics-helper.sh`
    - `get_tag` — returns current phase's automation tag
    - `get_solo` — returns solo mode flag (`true`/`false`, default: `false`). Decision 0015
    - `set_solo <true|false>` — updates solo field in phase-state. Decision 0015
    - `set_phase_mode <auto|review>` — updates mode field in phase-state
    - `has_plan_gate <session_type>` — returns 0 if session type has an `approval` phase (requires plan gate enforcement), 1 otherwise
    - `get_post_approval_phase <session_type>` — returns the phase immediately after `approval` in the sequence, or empty string if no approval phase

11. **Lifecycle**: Phase-state is session-scoped and agent-initiated — the agent calls `init_phase` at session start, not a hook. Hooks cannot determine session type at launch, so phase-state creation is the agent's responsibility. When phase-state is absent or stale, hooks fail-open (backwards compatible). Cleaned by `cleanup_session()` in `session-close-check.sh` at session close (`rm -f "$state_dir/phase-state"`).

## Consequences
- `.claude/hooks/_phase-helper.sh` added (new sourced helper)
- `.claude/.state/phase-state` schema defined (session-scoped state file)
- `.claude/hooks/session-close-check.sh` gains `phase-state` cleanup in `cleanup_session()`
- `.claude/hooks/_analytics-helper.sh` gains `get_session_type()` function
- `.claude/agents/_agent-glossary.md` gains `phase-state` in State Files table
- `docs/ai/quality-gates.md` gains `phase-state` in State File Dependencies table
- No changes to `.claude/settings.json` (helper is sourced, not a standalone hook)
- No changes to `write-guard.sh` (hook shell I/O already bypasses it)
