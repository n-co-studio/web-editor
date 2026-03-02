# Decision 0021 — User Review System

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/agents/_user-review-tier-[1-3]\.md`
- keywords: `user-review, persona, tier`

## Decision
Introduce an advisory-only User Review system that uses LLM persona simulation to provide synthetic user perspective on implementation output. Dispatch and synthesis occur in the `user-review` phase; results are presented to the operator during `op-review`.

1. **System name and purpose**: User Review. Advisory-only LLM persona simulation providing synthetic user perspective on implementation output. The system simulates user behavior under persona constraints — it is not a usability test and does not produce empirical evidence. Findings are hypothesis-grade input for design decisions.

2. **Advisory-only nature**: All findings are advisory. No gate, no state file, no `GATE_RESULT` sentinel. Does not block commit. The Orchestrator dispatches and synthesizes results during the `user-review` phase, then presents results to the operator for disposition (accept / note / dismiss) during `op-review` using the same pattern as advisory board review (Decision 0007).

3. **Three persona tiers** (functional descriptors, non-gendered, non-racial):
   - **Tier 1 — Power User**: High technical fluency. Has existing mental models for the domain. Discovers edge cases, tests boundaries, attempts shortcuts, exploits power features. Error recovery: confident, tries multiple approaches before reporting friction.
   - **Tier 2 — Everyday User**: Moderate fluency. Has partial mental models. Follows primary flows, occasionally explores secondary features. Error recovery: tries once, then seeks help text or documentation.
   - **Tier 3 — Novice User**: Minimal fluency. No pre-existing mental model. Gets confused by jargon, relies on visual cues, abandons tasks at friction points. Error recovery: stops immediately. Aggressive confusion injection: "You have no mental model of this concept. You cannot infer what this button does from its label alone. When uncertain, stop and report CRITICAL."

4. **Two testing modes**:
   - **Static mode** (Phase 1 — this decision): Scenario-driven. The Orchestrator provides scenario YAML (see schema below) to the persona agent via Task prompt. The agent walks through the scenario steps by reading implementation files, narrating the simulated user's experience, confusion points, and satisfaction. All output is returned via Task result.
   - **Live mode** (Phase 2 — deferred): Interactive session simulation where the persona agent interacts with a running application via Playwright MCP. Not defined in this decision. Will require a separate decision extending this one when the need arises. Live mode is not available.

5. **Scenario schema** (YAML, JTBD job stories): Scenarios use "When [situation], I want to [motivation], so I can [outcome]" job stories for structured, falsifiable evaluation. See schema definition below.

6. **Results format**: Standardized output with per-tier severity tags mapped to existing advisory board vocabulary. Each output includes a mandatory LLM persona simulation caveat. See results format definition below.

7. **Operating mode exclusions**: User Review is available in **child mode only**. Excluded from:
   - **Template mode** — no product code exists to review
   - **Autonomous mode** — no operator present to disposition findings at `op-review`
   - **Headless/automation mode** — no operator interaction for disposition
   - **Experiment branches** — experiment sessions have no `user-review` phase (lightweight lifecycle)

8. **Per-project profile extensibility**: Child repos may override tier behavioral contracts via project-specific decisions (0100+ range) or by providing domain-specific context in the scenario's `context:` block. Base persona profiles (`.claude/agents/_user-review-tier-{1,2,3}.md`) apply as defaults. Profile overrides add context — they do not modify the base agent files (those are template-synced and locked in child mode).

9. **Forcing function**: Findings require operator disposition (accept / note / dismiss) during `op-review` — same pattern as advisory board findings (Decision 0007). Not a silent report. The Orchestrator synthesizes results in the `user-review` phase, then presents findings inline during `op-review` and waits for operator acknowledgment before proceeding to close.

10. **Token cost**: User Review is opt-in only (never default-on). Two activation paths:
    - **Task brief opt-in**: The task brief includes a `### User Review` section specifying which tiers to run and scenario definitions. The Orchestrator dispatches them during the `user-review` phase.
    - **Operator request**: The operator requests user review during the session (e.g., "run tier-2 review on the signup flow"). The Orchestrator constructs scenarios from the operator's description and dispatches during the `user-review` phase.

11. **Dedicated phase, no new gates or state files**: User Review runs in a dedicated `user-review` phase inserted after `verify` and before `commit` in the standard and taskgroup sequences (Decision 0014 amendment). The phase is skippable — forward-jump from `verify` to `commit` is permitted when the task brief has no User Review section. No new gate, no state file, no hook. The phase is advisory-only.

## Scenario Schema

```yaml
# User Review Scenario — passed to persona agent via Task prompt
scenario:
  name: ""                    # short identifier
  job_story: ""               # "When [situation], I want to [motivation], so I can [outcome]"
  mode: static                # static (Phase 1) | live (Phase 2, deferred)
  entry_point: ""             # where the user starts (page, screen, file path)
  goal: ""                    # what the user is trying to accomplish
  steps:                      # ordered interaction sequence
    - action: ""              # what the user does
      expects: ""             # what the user expects to happen
  context:                    # optional context for the persona
    domain_knowledge: ""      # what this user type would already know
    prior_experience: ""      # comparable products/features they've used
  success_criteria:           # how to judge if the job story is satisfied
    - ""
```

## Results Format

```
## User Review Results — [Tier N: Persona Name]

**Scenario:** [scenario name]
**Job story:** [job story text]

> **LLM Persona Simulation Caveat:** These results are generated by an LLM
> simulating a user persona, not from actual user testing. LLM persona
> simulation may over-succeed compared to real users — particularly at
> Tier 3 (Novice). Findings indicate potential issues, not validated user
> behavior. Treat as hypothesis-grade input for design decisions.

### Walkthrough
1. [Step] — [narration of experience: what the persona sees, thinks, does, feels]

### Findings
1. [SEVERITY]: **[Title]** — [description of the friction point or success]
   - Step: [which step triggered this]
   - Impact: [what happens to the user's task completion]

### Summary
- Critical: [count]
- Recommendations: [count]
- Ideas: [count]
- Verdict: [COMPLETED | COMPLETED WITH FRICTION | ABANDONED]
```

**Severity tags** (aligned with advisory board vocabulary, Decision 0007):
- **CRITICAL** — Task impossible for this tier. The simulated user cannot complete the job story
- **RECOMMENDATION** — Friction warranting change. The user can complete the task but with confusion, extra steps, or hesitation
- **IDEA** — Optional improvement. The user completes smoothly but an enhancement is plausible

## Context
Existing governance review agents (QA, Critic, Reviewer, Security) validate code quality, coherence, and safety. None simulate the user's perspective. The `user-review` phase dispatches persona agents and synthesizes results; the `op-review` phase provides the operator pause point where those results inform the accept/reject decision before merge. This is a lightweight intervention — advisory-only, opt-in, no new gates — providing signal without governance overhead.

LLM persona simulation is inherently limited. Research (UXAgent, SimUser) confirms LLMs over-succeed compared to real users, especially at novice tiers. The agents cannot replicate genuine cognitive load, motor skill constraints, visual perception, or emotional state. The mandatory caveat in every results output ensures the operator treats findings as hypotheses, not evidence. The aggressive confusion injection in Tier 3 partially mitigates over-success but is a known limitation, not a complete solution.

## Consequences
- `docs/ai/decisions/0021-user-review-system.md` created (this file)
- `.claude/agents/_user-review-tier-1.md` created (Power User persona)
- `.claude/agents/_user-review-tier-2.md` created (Everyday User persona)
- `.claude/agents/_user-review-tier-3.md` created (Novice User persona)
- `.claude/agents/_agent-glossary.md` updated: User Review section added (system definition, tier table, severity mapping, risk classification, operating mode exclusions)
- `.claude/agents/_agent-workflow.md` updated: User Review subagent reference table added (three rows)
- `docs/ai/decisions/.a1-trigger-index` regenerated to include Decision 0021 triggers
- Decision 0014 amended: `user-review` phase added to standard and taskgroup sequences (skippable, advisory-only)
- `.claude/hooks/_phase-helper.sh` updated: `user-review` registered in `get_phases_for_type` and `get_tag_for_phase`
- `docs/ai/prompts/prompt-t-task-definition.md` updated: optional User Review section in brief template, `user_review` field in task contract
- `docs/ai/prompts/prompt-b-product-build.md` updated: user-review dispatch logic
- `.claude/agents/orchestrator.md` updated: On-Demand Procedure entry for User Review dispatch
- `docs/ai/workflow.md` updated: User Review section documenting phase position and opt-in mechanism
- `docs/ai/quality-gates.md` updated: advisory note for User Review
- No new gates, no new hooks, no new state files
