# Cohesion Review — Procedure Reference

Read by the Orchestrator after Builder signals completion, before invoking QA.

---

## Procedure

1. **Gather context** — Run `git diff` to capture the changes. Identify files touched and their immediate neighbors (files that import from or are imported by the changed files).
2. **Invoke Critic** — Dispatch Critic as subagent via Task with mode=cohesion. Pass the diff output and list of files to review in the Task prompt.
3. **Review findings** — Read the Cohesion Brief. Categorize each finding:
   - **Clear fix**: Unambiguous broken reference or inconsistency → delegate to Builder
   - **Ambiguous**: Could be intentional or could be a problem → surface to operator for decision
4. **Resolve** — If clear fixes exist, delegate to Builder with specific instructions. If ambiguous findings exist, pause and present to operator.
5. **Re-run** — If Builder made fixes, invoke Critic (cohesion mode) again to verify resolution. GUIDE: cap at 2 rounds — after that, escalate remaining findings to operator for accept/defer.
6. **Proceed** — When Cohesion Brief shows clean (zero critical findings, or all findings operator-accepted) → invoke QA for gate verification.

---

## Related References

- **Critic agent definition:** `.claude/agents/critic.md` (cohesion mode scope, constraints, brief format)
- **Gate A5:** `docs/ai/quality-gates.md` (cohesion review gate definition)
- **Decision 0008:** `docs/ai/decisions/0008-cohesion-review-gate.md`
