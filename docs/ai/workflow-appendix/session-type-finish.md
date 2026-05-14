# Session Type: Finish Loop

Convergent assessment-and-fix session type for closing identified gaps and resolving
incomplete deliverables from prior sessions. The agent iterates through an
`assess → fix → reassess` cycle until all quality dimensions pass (convergence) or the
cycle limit is reached (escalation).

- **Phase sequence**: `init → assess → fix → reassess → commit → close`
- **Loop**: `reassess → fix` (apply fixes and reassess when any dimension fails)
- **Cycle limit**: 5 cycles before incomplete escalation
- **No plan gate**: `has_plan_gate("finish-loop")` returns false — the assessment defines
  the plan. Pre-approval is written by the runner at launch.
- **Gate profile**: A1, A2 (pre-written), A4, A6 (when task group). A5 cohesion review
  is replaced by the structured dimension assessment.
- **Convergence signal**: `FINISH_LOOP_RESULT: COMPLETE` in `cohesion-reviewed` state file
- **Incomplete signal**: `FINISH_LOOP_RESULT: INCOMPLETE` → runner routes to `review:finish-incomplete`
- **Regression signal**: `FINISH_LOOP_REGRESSION: <dim>/<desc>` → runner routes to `review:scope-deviation`
- **Cycle cache** (Decision 0040): passing dimension verdicts are cached at `<session_state_dir>/finish-loop-cache.yaml` keyed by an input-file SHA-256. On cycle N ≥ 2, dimensions whose input hash matches the cached PASS hash are inherited; the rest are reassessed. Hash comparison is the regression signal. Loop-back-source files force-reassess. Cache is session-scoped, cleaned by `cleanup_session_files()` at close. See `docs/ai/prompts/prompt-f-finish-loop.md` § Dimension Input Sets, Assessment Cycle Cache.
- **Session mode**: headless automation (runner-invoked). Interactive operator not present.

**Assessment dimensions (6):**
1. Spec Alignment — implementation matches spec/brief requirements
2. Completeness — all deliverables present and non-stub
3. Correctness — logic correct, no concrete errors
4. Test Gate — tests pass (skippable when no tests configured)
5. Governance — would pass quality gates A1–A6
6. Integration — callers/consumers unbroken, cross-references valid

**Runner integration:**
- Template: `.claude/.automation/templates/finish-loop-brief.md`
- Outcome: `review:finish-incomplete` (INCOMPLETE sentinel) or `review:scope-deviation` (REGRESSION sentinel)
- Queue entry session_type field: `finish-loop`

See `docs/ai/prompts/prompt-f-finish-loop.md` for the full prompt definition and
convergence protocol.
