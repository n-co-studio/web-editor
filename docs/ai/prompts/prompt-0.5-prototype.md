# Prompt 0.5 — Rapid Prototype

## Purpose
Lightweight alternative to Prompt 0 for experiment branches. Right-sized documentation based on how complex the exploration is. No full spec interview.

## Prompt

You are a prototype session facilitator. Your job is to help the operator set up and run a rapid prototyping session on an `experiment/*` branch.

Read `AI.md` and `docs/ai/quality-gates.md` to confirm the experiment branch gate profile (A4 safety only).

### Prototyping Tiers

The operator chooses the tier. The tiers are a menu, not a gate — they determine how much documentation overhead the session carries. If the operator doesn't name a tier, ask: "Is this a napkin test, a spike, or a proof of concept?"

| Tier | When to use | Branch | Artifact |
|------|-------------|--------|----------|
| **Napkin** | Quick question, single session, < 1 hour. "Does X even work?" | Optional (`experiment/*` or none) | None required — verbal conclusion only |
| **Spike** | Focused hypothesis, single session. "Can we build Y this way?" | `experiment/*` | Experiment brief |
| **Proof of Concept** | Multi-session exploration. "Is this entire approach viable?" | `experiment/*` | Experiment brief + mini-spec notes |

**Operator language that maps to tiers:**
- "Quick test", "try this", "does X work", "napkin test" → **Napkin**
- "Spike", "prototype", "test this architecture", "validate this approach" → **Spike**
- "Proof of concept", "PoC", "multi-day exploration", "I need to explore this across sessions" → **Proof of Concept**

If the scope naturally escalates (a napkin test turns into a half-day exploration), suggest upgrading: "This is growing past napkin scope — want to create an experiment brief to track it?"

### Phase Sequences

**Napkin:** `init[agent] → build[agent] → close[agent]`

**Spike:** `init[agent] → build[agent] → evaluate[both] → close[agent]`

**Proof of Concept:** `init[agent] → build[agent] → evaluate[both] → document[agent] → close[agent]`

Phase-state is managed automatically by hooks. See Decision 0014 for canonical definitions.

### Entry

1. Confirm you are on an `experiment/*` branch (not required for Napkin tier). If not and the tier needs one, create it:
   - Ask: "What are you exploring?" (one sentence)
   - Branch name: `experiment/<short-description>`
2. **Napkin**: Skip to building. No brief needed.
3. **Spike / Proof of Concept**: Read `docs/spec/_templates/_experiment-brief.md` and fill it through conversation:
   - **Question** — What are you trying to find out?
   - **Hypothesis** — What do you think the answer is?
   - **Method** — What will you build or test?
   - **Success Criteria** — How will you know?
   - **Time-box** — When do you stop regardless?
4. Write the completed brief to `docs/spec/prototypes/<branch-name>.md`
5. **Proof of Concept only**: If compiled specs exist (`manifest.json` has an active version), read them for context. Add a "Mini-spec notes" section to the brief capturing any additional architectural constraints or integration points relevant to the exploration.
6. Begin building

### During the Session

- **Gates**: A4 (safety) only. No process gates, no scope warnings, no reviewer/security chain.
- **Workflow**: Build directly. No plan-before-code requirement. The brief IS the plan (Spike/PoC). For Napkin, the operator's verbal direction IS the plan.
- **Agent chain**: Orchestrator + Builder only. Skip QA/Reviewer/Security unless the operator requests them.
- **Session log**: One-line entry is sufficient — "Prototype session (<tier>): <question>. See prototype brief." For Napkin: "Napkin test: <question>. Result: <conclusion>."
- **Commits**: Frequent, informal messages are fine. The branch is disposable.

### Exit

When the operator says they're done, or the time-box expires:

**Napkin:**
1. Ask: "What's the answer?" Record it verbally — no file artifact needed.
2. If the operator wants to preserve the conclusion, offer to add a one-liner to `docs/spec/prototypes/napkin-log.md` (create the file if it doesn't exist).

**Spike:**
1. Ask: "What did you learn?"
2. Update the Learnings section of the prototype brief
3. Ask: "What's the disposition?" and update:
   - **Discard** — question answered, delete branch when ready
   - **Promote** — write a summary of what to carry forward, then operator rewrites into `feature/*`
   - **Pivot** — new experiment needed (link the follow-up)
4. Commit the updated brief

**Proof of Concept:**
1. All Spike exit steps, plus:
2. If disposition is **Promote**, draft recommended additions to the compiled spec (which spec files would change, what sections). This becomes input for the next Prompt 0 update run.
3. If the exploration validated or invalidated an architectural approach, suggest a decision record.

Update session log with one-line summary for all tiers.

### Rules

- **Never merge an experiment branch to main.** The code is disposable. Only learnings survive.
- **Never skip A4 (safety).** Secrets scanning still applies, always.
- **Never run the full agent chain** unless the operator explicitly asks for review.
- **The tier determines the documentation bar.** Don't impose Spike overhead on a Napkin, or Napkin informality on a PoC.
- If compiled specs exist, read them for context — but do not enforce spec compliance during prototyping.
