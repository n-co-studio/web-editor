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
   - `session_type` — one of the 18 session type enum values
   - `session_id` — bound to `.claude/.session-id` for staleness protection
   - `mode` — `auto` or `review` (default: `review`)
   - `current_phase` — the phase the session is currently in
   - `cycle` — build iteration counter (starts at 1, increments on loop-back to build)
   - `phases_completed` — comma-delimited list of completed phases
   - `solo` — merge strategy flag (`true` or `false`, default: `false`) — see Decision 0015
   - `tag` — automation tag for the current phase (`agent`, `operator`, or `both`)
   - `timestamp` — ISO 8601 UTC timestamp of last phase transition

2. **Session type enum** (18 types):
   - Prompt B: `standard`, `taskgroup`, `taskgroup-merge`, `hotfix`, `experiment`, `editor-live`
   - Prompt 0: `spec-fresh`, `spec-update`
   - Prompt 0.5: `prototype-napkin`, `prototype-spike`, `prototype-poc`
   - Prompt A: `advisory-init`, `advisory-reinit`
   - Prompt C: `audit`
   - Prompt Q: `queue-triage`
   - Prompt T: `taskdef-query`, `taskdef-brief`
   - Ephemeral: `ephemeral`

3. **Phase sequences** — each session type defines an ordered list of phases with automation tags. Transitions are forward-only except for defined loops. Full sequences:

   **Prompt B — Standard Build:**
   `init[agent] → drift-check[agent] → plan[agent] → approval[operator] → build[agent] → review[agent] → verify[agent] → user-review[agent] → commit[agent] → op-review[operator] → close[agent]`
   Loops: `review→build` (cohesion findings), `verify→build` (QA failure)
   Skippable: `user-review` — forward-jump from `verify` to `commit` permitted when the task brief has no User Review section. Advisory-only phase — no state file written, no gate blocked. See Decision 0021 for system definition.
   `drift-check` (Decision 0038): when a valid handoff bundle is present, `drift_check()` writes `plan-approved` + `pragmatist-signed` directly from the bundle and the orchestrator forward-jumps to `build` (skipping `plan` and `approval`). When the bundle is absent / hard-expired / spec-drifted, drift-check falls through to the legacy `plan → approval` path with full agent re-derivation. Forward-jump `drift-check → build` is legal whenever `drift_check` returns 0; the `plan` and `approval` phases remain skippable in the same sense as `user-review`/`op-review`.

   **Prompt B — Task Group (Brief N of M):**
   `init[agent] → contract-init[agent] → drift-check[agent] → plan[agent] → approval[operator] → build[agent] → review[agent] → verify[agent] → user-review[agent] → commit[agent] → contract-update[agent] → op-review[operator] → close[agent]`
   Loops: `review→build`, `verify→build`
   Skippable: `user-review` — same rules as Standard Build. `drift-check` skip semantics match Standard Build (forward-jump to `build` when a per-brief bundle at `.claude/local/task-groups/{group}/briefs/{seq}.bundle.yaml` is valid).
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

   **Prompt Q — Queue Triage:**
   `init[agent] → conversation[both] → close[agent]`

   **Prompt T — Task Definition (Query):**
   `init[agent] → conversation[both] → close[agent]`

   **Prompt T — Task Definition (Brief):**
   `init[agent] → dispatch[agent] → synthesize[agent] → approval[operator] → output[agent] → close[agent]`

4. **Phase-to-gate-profile mapping** — which gates apply varies by session type and is enforced at `verify`/`commit` phases:
   - `standard`, `taskgroup`, `taskgroup-merge`: Full gates (A1–A6, B1–B3). A6 applies only to taskgroup/taskgroup-merge
   - `editor-live`: A4 per-loop commit; full gates (A1–A5, B1–B3) at final review/verify. A6 n/a (not a task group type)
   - `hotfix`: Expedited (A2 enforced uniformly, A5 skipped)
   - `experiment`, `prototype-*`: A4 safety only
   - `spec-fresh`, `spec-update`: Advisory only (governance evidence at close)
   - `advisory-init`, `advisory-reinit`: Advisory only (governance evidence at close)
   - `audit`: Read-only (no gates unless deferrals create file changes)
   - `queue-triage`: No gates (fully ephemeral)
   - `taskdef-query`: No gates (fully ephemeral)
   - `taskdef-brief`: Plan-approved gate only (Decision 0029 — `approval` phase requires `plan-approved` state file)

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
    - `bundle_valid [path]` — returns 0 when the handoff bundle at `path` (default `.claude/local/handoff-bundle.yaml`) parses and contains required top-level fields. Decision 0038
    - `bundle_expired [path]` — returns 1 fresh, 0 soft-expired, 2 hard-expired or unparseable. Decision 0038
    - `bundle_to_plan_approved [bundle] [sid]` — writes `plan-approved` state file derived from a valid bundle. Decision 0038
    - `bundle_to_pragmatist_signed [bundle] [sid]` — writes `pragmatist-signed` state file derived from `bundle.pragmatist.verdict`. Decision 0038
    - `drift_check [bundle]` — top-level drift-check evaluator: writes derived state and returns 0 on success; returns 1–5 with reason on stderr when caller should fall through to the legacy path or trigger focused re-approval. Decision 0038
    - `deterministic_alignment_check <plan> [contract]` — heuristic plan-vs-design alignment used by the Orchestrator when `implementation_design:` is present; emits `aligned`/`diverged`/`missing-design` on stdout and returns 0/1/2 respectively. Decision 0038

11. **Lifecycle**: Phase-state is session-scoped and agent-initiated — the agent calls `init_phase` at session start, not a hook. Hooks cannot determine session type at launch, so phase-state creation is the agent's responsibility. When phase-state is absent or stale, hooks fail-open (backwards compatible). Cleaned by `cleanup_session()` in `session-close-check.sh` at session close (`rm -f "$state_dir/phase-state"`).

12. **Dispatch-phase binding for governance verdict validation** (added 2026-08-07 — session `daemon-20260807-154632-79148`): Governance agent verdicts (critic, qa-verifier, reviewer, security-privacy, pragmatist) must be validated against the phase at **dispatch time**, not the phase at **arrival time**. Agents take minutes to run; the session phase can advance legitimately while they run. Validating against the current (post-advance) phase produces false rejections.

    **Mechanism:**
    - `pretooluse-permission.sh` calls `record_dispatch_phase "$AGENT_SUBTYPE"` at Agent PreToolUse time for governance agents. This writes `agent_type: phase=<p> cycle=<c> ts=<t>` into the `dispatch_records:` section of `session-resume.yaml`.
    - `state-writer.sh` reads the dispatch record via `get_dispatch_phase "$AGENT_TYPE"` and validates the verdict against the **dispatch phase** when a record exists. Falls back to current phase when no dispatch record is present (backward compatibility — sessions without dispatch recording, or non-governance agents).
    - On rejection, `state-writer.sh` emits a detailed stderr message naming the agent, verdict, dispatch phase, and current phase, and writes an escalation file to `.claude/.automation/escalations/`. A discarded verdict must never look like success.
    - Governance verdict state files now include a `dispatch_phase:` field as dispatch evidence. `pre-commit-gates.sh` rejects verdict files (`qa-verified`, `cohesion-reviewed`, `diff-review-complete`) that lack this field — ensuring files must have been written by a real hook-mediated dispatch.

    **Known limitation:** `SubagentStop` does NOT fire when a governance agent is resumed via `SendMessage`. Verdicts from resumed agents are lost with no error visible to the orchestrator. Workaround: always re-dispatch governance agents via the Task tool. See `docs/ai/logs/known-issues.md` R3.

    **Preservation note:** `_headless-plan-approve.sh` writes `plan-approved` directly (sanctioned system auto-approval for headless plan phase) and is unaffected — it does not go through `state-writer.sh` and `plan-approved` is not subject to the `dispatch_phase:` check.

## Consequences
- `.claude/hooks/_phase-helper.sh` added (new sourced helper)
- `.claude/.state/phase-state` schema defined (session-scoped state file)
- `.claude/hooks/session-close-check.sh` gains `phase-state` cleanup in `cleanup_session()`
- `.claude/hooks/_analytics-helper.sh` gains `get_session_type()` function
- `.claude/agents/_agent-glossary.md` gains `phase-state` in State Files table
- `docs/ai/quality-gates.md` gains `phase-state` in State File Dependencies table
- No changes to `.claude/settings.json` (helper is sourced, not a standalone hook)
- No changes to `write-guard.sh` (hook shell I/O already bypasses it)
- **(2026-08-07)** `_phase-helper.sh` gains `record_dispatch_phase` and `get_dispatch_phase`; `write_resume_marker` preserves `dispatch_records:` section across phase advances
- **(2026-08-07)** `pretooluse-permission.sh` calls `record_dispatch_phase` for governance agents at Agent PreToolUse
- **(2026-08-07)** `state-writer.sh` validates verdicts against dispatch phase; rejects with loud stderr + escalation file; adds `dispatch_phase:` field to all verdict state files
- **(2026-08-07)** `pre-commit-gates.sh` rejects `qa-verified`, `cohesion-reviewed`, `diff-review-complete` that lack `dispatch_phase:` field
- **(2026-08-07)** `docs/ai/logs/known-issues.md` gains R3: SendMessage-resumed agents do not trigger SubagentStop

## Amendment — Same-Session Re-init Clears Evidence (2026-10-25)

**Status:** Accepted

`init_phase` rewrote `phase-state` on an authorised re-init and removed no
evidence, so a second work unit in one session inherited the first unit's
`plan-approved`, `pragmatist-signed`, `cohesion-reviewed`,
`diff-review-complete`, `qa-verified` and the `kg-updated` marker. Every one
carried a matching `session_id` and a valid `dispatch_phase`, so every check
`pre-commit-gates.sh` performs on them passed — including the A5 `BLOCKED` test,
since the inherited verdicts said APPROVED. A second unit could therefore commit
on the first unit's sign-off, reviewed by nobody. Filed as known-issue R40,
reproduced live twice.

**A re-init that replaces this same session's phase-state now clears that
session's evidence**, and the new work unit re-earns all of it. Three properties
make this safe rather than destructive:

1. **Scope.** Three cases, decided by one `_clear_scope` value:
   - **An authorised same-session re-init** (`REPO_OS_ALLOW_REINIT=1`) clears
     **everything**, pre-write markers included. A second work unit re-earns its
     approval whatever wrote the first one.
   - **A first init** clears leftover verdicts but **preserves** any file marked
     `source: runner`, `source: handoff-bundle`, `question_hash: runner-auto` or
     `question_hash: headless-runner`. This case was added on operator decision
     after the amendment's first draft, which said a first init was untouched.
     The condition attached to it was "assuming this doesn't break the task group
     chain", and that condition is load-bearing: `state-manager.sh` pre-writes
     `plan-approved` for every daemon and task-group brief and states that
     phase-state is *not* pre-seeded, so those briefs reach `init_phase` as a
     first init with their approval already on disk. Clearing indiscriminately
     would strand every one at "plan-approved missing". Markers are matched per
     **file**, not per filename, because `bundle_to_pragmatist_signed` writes
     `pragmatist-signed` the same way.
   - **The different-session branch** clears nothing: it adopts or overwrites
     another session's state, whose evidence already fails
     `_validate_state_session_id` at the gates, and deciding what that path may
     delete is a separate question.
   **The limit, stated rather than implied:** on a first init a *forged* marker
   preserves its file. That is strictly narrower than the previous behaviour,
   where a first init preserved everything unconditionally, so it is not a new
   weakness — but the marker now carries a decision it was not designed for.
2. **Placement.** The clear precedes the `phase-state` rewrite, not merely
   `write_evidence_manifest`. The ancestry check later in `init_phase` appends
   `main_ancestry: fail` and returns 1 *after* that rewrite, so clearing late
   would leave a failed re-init with a freshly reset phase beside stale
   approvals — the same defect in a worse shape. Preceding the manifest write
   also matters: the manifest would otherwise re-baseline the inherited files as
   legitimately present, leaving `compare_manifest` blind.
3. **Direction.** The clear only removes files, and every gate treats an absent
   verdict as blocking. Its worst outcome is a self-inflicted re-review, never a
   bypass.

**One list, two consumers.** `_SESSION_EVIDENCE_FILES` in `_cleanup-helper.sh`
is shared by `cleanup_session_files` at close and by the re-init clear, because
two hand-maintained lists would reproduce exactly the drift this fixes.
`phase-state`, `phase-state.gates` and `session-resume.yaml` are deliberately
outside it: close deletes them, and a re-init must not, because it is building
that state rather than discarding it. Stated precisely, since an earlier draft
of this paragraph said `init_phase` "rewrites all three" — it rewrites
`phase-state` early, while `write_resume_marker` and `compute_phase_gates` run
near the end, after the ancestry check's `return 1` paths. A re-init that fails
there leaves the other two holding the previous unit's contents. Neither carries
an approval, so that is staleness and not an inheritance hole.
`criteria-verdicts.yaml` is inside it — t-0048 keeps that sidecar out of the
evidence *manifest*, which is a different question from whether a new work unit
should inherit it.

**The clear is logged with each file's verdict**, and so is each file it could
NOT clear. A re-init can discard a `GATE_RESULT: BLOCKED`, and nothing else
would record that. The skip case matters as much: `_delete_if_owned`
correctly refuses to delete a file owned by a different session id, and that is
reported rather than passed over in silence. Stated carefully, because an earlier
draft of this paragraph overstated it: whether the next unit actually *inherits*
such a file depends on which id the commit gate resolves, and the gate rejects a
genuinely foreign file as stale — the inheritance case is the narrow one where
the gate's id matches the file and `init_phase`'s does not. The report is a
WARNING, not `GATE-RECOVERABLE`, because this path blocks nothing.
`REPO_OS_ALLOW_REINIT` is now recorded through `log_override` rather than only
echoed to stderr. **Not yet asserted by any test**, which is the weakest part of
this amendment: that log line is the only trace of a discarded verdict.

**Label corrected.** The override was documented as "crash recovery" in
`hook-rules-summary.md` and in the code comment. The documented crash restart
(t-0032 §3) uses a *new* `REPO_OS_SESSION_ID`, so it takes the other branch and
is unaffected by this change. The same-session branch is what a second work unit
uses, which is what the label now says.

**Known gap, recorded not closed:** some test layers do not pin
`_REPO_OS_ROOT` and use fixed session ids, so a suite resolving to the real repo
and calling `reset_phase` would clear real evidence for that id. `reset_phase`
already removes the state directory first, making the clear a no-op there, and
the hazard predates this change — real `phase-state` is already overwritten by
that path. Tracked as a numbered finding rather than widened into this change.
