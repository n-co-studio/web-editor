# Cohesion Review — Procedure Reference

Read by the Orchestrator after Builder signals completion, before invoking QA.

---

## Procedure

1. **Gather context** — Run `git diff` to capture the changes. Identify files touched and their immediate neighbors (files that import from or are imported by the changed files). Capture the staged diff (`git diff --cached`) and surrounding context (20 lines per changed function) for the diff-review side. Read `.claude/local/task-contract.yaml` (singular builds) or the `intent:` block from the task group contract (groups) if present.
2. **Invoke Critic** — Dispatch Critic as subagent via Task with **mode=combined** (Decision 0039). Pass both the cohesion context (diff + files-touched + immediate neighbors) and the diff-review context (`git diff --cached` + surrounding 20 lines per changed function) in the Task prompt. If a task contract is present, also pass the contract's `verification:` criteria and instruct Critic to evaluate each criterion (see Contract Verification in `critic.md`). Combined output emits both `## Cohesion Brief` and `## Diff-Review Brief` sections, each with its own `GATE_RESULT:`; `state-writer.sh` writes both `cohesion-reviewed` and `diff-review-complete` from the single SubagentStop event.
   **Mechanism-change addendum (Decision t-0063).** Before dispatching, run `bash .claude/tools/verify-pristine.sh --classify`. If it prints `mechanism-change: yes`, the change touches the enforcement mechanism (hooks, tools, runner/queue/automation scripts, their tests, `settings.json`) — the same set the commit gate's `mechanism-change-detected` marker is derived from. (The marker itself only exists at commit time, after review, so review consumes the classification instead; the two share `_mechanism-helper.sh`.) For such a change the Critic's usual question — "is this internally coherent?" — is not enough, because the change is reviewed and verified by the machinery it modifies. Add these four questions to the Task prompt and require an explicit answer to each, with file:line evidence:
   1. **What verifies this change, and did this change touch it?** Name each suite or gate that would catch a defect here. For each, say whether the diff modified it, its helpers, or its fixtures. A verifier that was edited in the same diff is not independent evidence.
   2. **What does the verifier no longer catch?** For every weakened, removed, loosened or re-ordered check, assertion, exclusion or exit path: what class of defect used to be caught and now is not?
   3. **Is there an exit that is not a gate, and an exit that is not reachable?** A new block needs a documented operator exit; a new exit must not be honoured in headless/auto mode unless the decision record says so. Name both for every new or changed gate.
   4. **What was shown to fail before it was shown to pass?** For each new test or assertion, state the evidence it fails against the code without the change (wrong implementation, stub, or the merge base). An assertion never seen to fail is unverified, not green.
   Also report the `harness_changed:` and `code_changed:` lines from `verify-pristine.sh` for the operator: a change to a test harness is exactly what the pristine run is built to expose.
3. **Review findings** — Read the Cohesion Brief and (when combined mode was used) the Diff-Review Brief. Apply the same triage to each finding in each brief:
   - **Clear fix**: Unambiguous broken reference, inconsistency, or mechanical bug → delegate to Builder
   - **Ambiguous**: Could be intentional or could be a problem → surface to operator for decision
   - Critical findings in either brief block the review-phase advance until resolved (or operator-accepted)
4. **Resolve** — If clear fixes exist, delegate to Builder with specific instructions. If ambiguous findings exist, pause and present to operator.
5. **Re-run** — If Builder made fixes, re-invoke Critic. A targeted single-mode re-run (cohesion only, or diff-review only with `MODE: diff-review`) is acceptable when only one section had findings; combined re-run is preferred when fixes touched both surfaces. GUIDE: cap at 2 rounds — after that, escalate remaining findings to operator for accept/defer.
6. **Completeness pass** — After the cohesion review is clean (or findings resolved), evaluate whether the task contract's verification criteria are satisfied:
   a. Read `.claude/local/task-contract.yaml` (already loaded in step 1). If no contract or no `verification:` field exists, skip this pass silently.
   b. For each `verification:` criterion, evaluate the current codebase state (read files, check diffs) and produce a verdict:
      - **COMPLETE** — the criterion is demonstrably satisfied
      - **INCOMPLETE** — the criterion is not satisfied; include specific feedback on what is missing
      - **PARTIAL** — some evidence exists but the criterion is not fully met; include what remains
      - **N/A** — the criterion is annotated `[deferred]` in the task contract; excluded from completeness count
   c. Produce a completeness score: `completeness: N/M criteria met` (count COMPLETE as met; exclude N/A criteria from both numerator and denominator).
   d. If any criterion is INCOMPLETE, include specific remediation feedback and set `COMPLETENESS_GATE: NEEDS_WORK`. Delegate to Builder for fixes. The Orchestrator tracks total Critic dispatch cycles (cohesion findings + completeness fixes share a single counter). If INCOMPLETE criteria remain after the 2-round cap is exhausted: in interactive sessions, escalate remaining to operator for accept/defer; in headless sessions, close with INCOMPLETE status (the runner classifies as `review:incomplete-deliverable` and routes to review queue).
   e. Include the completeness results in the Critic's output, after the Contract Verification section. The `### Completeness` section goes inside the Cohesion Brief body. The `COMPLETENESS:` sentinel line must be emitted **after** the brief body, followed immediately by a `COMPLETENESS_GATE: APPROVED` or `COMPLETENESS_GATE: NEEDS_WORK` line, and **before** the `GATE_RESULT:` line — all as top-level unindented lines (not inside a code block). `GATE_RESULT:` must remain the last non-empty line. See `critic.md` § Cohesion Brief Format for the canonical output template.
   f. The `COMPLETENESS:` and `COMPLETENESS_GATE:` lines are sentinels captured by `state-writer.sh` and recorded in the `cohesion-reviewed` state file. `GATE_RESULT:` must remain the last non-empty line of output (state-writer.sh depends on this). `COMPLETENESS_GATE` is distinct from `GATE_RESULT` — it reflects completeness, not cohesion. **COMPLETENESS_GATE is blocking**: `outcome-detector.sh` classifies `NEEDS_WORK` sessions as `review:incomplete-deliverable` instead of `completed:success`; `pre-commit-gates.sh` emits GATE-RECOVERABLE when `COMPLETENESS_GATE: NEEDS_WORK` is present in the cohesion-reviewed state file.
7. **Proceed** — When Cohesion Brief shows clean (zero critical findings, or all findings operator-accepted) and completeness pass has no INCOMPLETE criteria (or remaining INCOMPLETE criteria are operator-accepted or round cap reached) → invoke QA for gate verification.

---

## Cross-Session Cohesion Mode (Merge Brief)

When the Orchestrator runs a merge brief (`taskgroup-merge` session type), cohesion review operates differently from standard single-session review.

### Diff Scope

Use `git diff main...HEAD` to capture the combined diff from all parallel content briefs on the shared branch. This produces the full branch diff (not just the current session's changes), ensuring the review covers all parallel work.

### Focus Areas

1. **Naming consistency** — verify that naming conventions established in the task group contract are followed uniformly across all briefs' output
2. **Interface alignment** — check that producer/consumer integration points (contract `integration_points:`) connect correctly (matching types, expected signatures, compatible data shapes)
3. **Duplicate logic** — identify repeated or near-duplicate implementations across brief boundaries that should be consolidated
4. **Import/export coherence** — verify that all cross-module imports resolve, exports are present, and no circular dependencies were introduced
5. **Shared file integration** — check index files, config, and other shared files owned by the merge brief for completeness (all modules registered, all routes wired)

### Finding Resolution

- **Clear fix**: Merge brief fixes directly. The `cohesion` phase self-loops (`cohesion→cohesion`) to allow iterative fixes
- **Ambiguous finding**: Escalate to operator for decision before proceeding
- **Cap**: 2 cohesion rounds. After that, escalate remaining findings to operator for accept/defer

### Invocation

Dispatch Critic as subagent via Task with **mode=cohesion** (not combined). Merge-brief cohesion reviews operate cross-session over the full branch diff; the diff-review surface (mechanical bug detection on staged changes) is already covered by each content brief's own review phase and is not re-run on the merge. Pass the `git diff main...HEAD` output and the full list of files changed on the branch. The Critic's scope is the entire branch diff, not a single brief's changes. Only `cohesion-reviewed` is written by this dispatch.

---

## Related References

- **Critic agent definition:** `.claude/agents/critic.md` (cohesion mode scope, constraints, brief format)
- **Gate A5:** `docs/ai/quality-gates.md` (cohesion review gate definition)
- **Decision 0008:** `docs/ai/decisions/t-0008-cohesion-review-gate.md`
