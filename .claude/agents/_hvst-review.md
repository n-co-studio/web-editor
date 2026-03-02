# HVST Review Board — Procedure Reference

Read by the Orchestrator when HVST debugging stalls or when the operator proactively requests a debug review.

---

## Trigger Conditions

- **Operator request**: Operator explicitly asks for a debug review or hypothesis review during an HVST loop
- **Stalled debugging**: Orchestrator detects 2+ consecutive HVST failures (tracked via `.claude/.hvst-fail-count`)

Operator request is the primary path. The 2-failure trigger is a safety net.

---

## Input Scope

Provide each specialist with failure artifacts and local context only:

- **Failing command + output** — the exact command that failed and its error output
- **Hypotheses attempted so far** — what was tried and what each attempt ruled out
- **Files touched during debugging** — list of files modified in the HVST loop
- **Recent changes** — `git log --since` for changes in the current session
- **Known issues** — relevant entries from `docs/ai/logs/known-issues.md` (template mode: `.claude/local/known-issues.md`) (if any match)

**Scope boundary**: Failure artifacts + local code context only. Do NOT pass full specs, full codebase scans, or unrelated module context. Keep input tight to control context window pressure.

---

## Dispatch Procedure

Dispatch all three specialists in parallel via Task tool. Each receives the input scope above plus mode-specific focus:

| Specialist | Focus |
|---|---|
| **Architect** | Structural analysis: Does the failure trace cross module boundaries? Are there dependency ordering issues? Does the error pattern suggest an architectural assumption violation? |
| **Exploration** | Alternative hypotheses: What non-obvious causes exist? Are there similar patterns in known issues or best practices? What adjacent systems could be contributing? |
| **Critic** (hypothesis mode) | Hypothesis soundness: Do attempted hypotheses explain all symptoms? What evidence would falsify them? Are multiple issues being conflated? What assumptions are unstated? |

---

## Debug Brief Format

Each specialist returns a brief using this format:

```
## [Agent Name] Debug Brief

**Error Context:** [what failed — command + output summary]

1. SEVERITY: **[Title]** — [finding with hypothesis/structural/alternative focus]
2. ...

Summary: C: [n] | R: [n] | I: [n]
```

Severity scale (same as advisory board): CRITICAL / RECOMMENDATION / IDEA.

---

## Synthesis Procedure

The Orchestrator merges the three Debug Briefs into ranked hypotheses. This is NOT a consensus — preserve competing hypotheses.

**Ranking criteria** (in order):
1. **Evidence strength** — How well does the hypothesis explain all observed symptoms?
2. **Falsifiability** — Can this hypothesis be tested with a small, fast experiment?
3. **Implementation risk** — How much does validating this hypothesis cost if wrong?

**Output**: Present ranked hypotheses to the operator (or Builder if operator delegates). The operator/Builder picks which hypothesis to validate first.

---

## Resolution Logic

- **Clear hypothesis**: A single high-confidence, falsifiable hypothesis emerges → Builder validates it via the HVST loop
- **Ambiguous/conflicting**: Specialists disagree or evidence is inconclusive → escalate to operator for direction
- **No actionable findings**: Review board found nothing beyond what was already tried → escalate to operator

**Cap**: 1 review board round before operator escalation. Do not dispatch a second review board to review the first review board's findings.

---

## Relationship to Cohesion Review

These are complementary, not overlapping:

- **HVST Review Board** examines hypotheses *during* debugging — when the Builder is stuck and needs diagnostic help
- **Cohesion Review** examines code *after* Builder completes — checking the finished change for internal codebase coherence

They operate at different points in the workflow and serve different purposes.

---

## Related References

- **Critic agent definition:** `.claude/agents/critic.md` (hypothesis mode scope, constraints, brief format)
- **HVST protocol:** `docs/ai/workflow.md` (full protocol definition)
- **Known issues:** `docs/ai/logs/known-issues.md` (template mode: `.claude/local/known-issues.md`) (checked as input during dispatch)
- **Cohesion review:** `.claude/agents/_cohesion-review.md` (complementary post-build review)