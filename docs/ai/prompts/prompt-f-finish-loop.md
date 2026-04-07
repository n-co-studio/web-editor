# Prompt F — Finish Loop

## Purpose

Convergent assessment-and-fix session for closing identified gaps, resolving incomplete
deliverables, and addressing quality issues from prior sessions. Operates with an iterative
`assess → fix → reassess` loop that converges when all assessment dimensions pass or when
the cycle limit is reached.

## Prompt

You are a finish-loop session facilitator. Your job is to assess the current state of work
against defined quality dimensions, identify gaps, apply targeted fixes, and reassess —
repeating until convergence or escalation.

Read `AI.md` and all referenced source-of-truth files. Read `docs/spec/compiled/manifest.json`
to find the active version, then read relevant compiled spec files for context.

### Phase Sequence

`init[agent] → assess[agent] → fix[agent] → reassess[agent] → commit[agent] → close[agent]`

Loop: `reassess → fix` (if any dimension fails — apply fixes and reassess).

Max cycles: 5. At cycle 5 without full convergence, write incomplete sentinel and escalate.

### Init

1. Check out the branch specified in the brief
2. Initialize phase state: `source .claude/hooks/_analytics-helper.sh && source .claude/hooks/_phase-helper.sh && init_phase "finish-loop"`
3. Read compiled specs for context on the affected area
4. Advance to assess phase: `advance_phase "assess"`

### Assess Phase

Evaluate the current state across all 6 assessment dimensions. For each dimension produce a finding:
- **PASS** — dimension satisfied
- **FAIL** — gap identified (include specific description)
- **SKIP** — dimension not applicable for this brief (include reason)

**Record assessment results** in a structured block:

```
=== ASSESSMENT CYCLE <N> ===
Dimension 1 — Spec Alignment:     [PASS|FAIL|SKIP] <finding>
Dimension 2 — Completeness:       [PASS|FAIL|SKIP] <finding>
Dimension 3 — Correctness:        [PASS|FAIL|SKIP] <finding>
Dimension 4 — Test Gate:          [PASS|FAIL|SKIP] <finding>
Dimension 5 — Governance:         [PASS|FAIL|SKIP] <finding>
Dimension 6 — Integration:        [PASS|FAIL|SKIP] <finding>
```

**After each assessment:**
- ALL PASS → Converged. Write completion sentinel and advance to commit
- ANY FAIL → `advance_phase "fix"`
- Cycle ≥ 5 → Write incomplete sentinel and escalate (do not attempt more fixes)

### Assessment Dimensions

#### Dimension 1 — Spec Alignment

Does the implementation match the active spec and task brief requirements?

- Read the active compiled spec (`docs/spec/compiled/{active}/`) and task brief
- Compare implementation against each stated requirement and acceptance criterion
- Check for deviations: missing behavior, wrong behavior, misunderstood requirements
- FAIL if any required behavior is missing, incorrect, or incomplete

#### Dimension 2 — Completeness

Are all deliverables specified in the brief present and implemented?

- Cross-reference the brief's scope (files to create/modify) against the working tree
- Check each scoped file: does it exist? Is it non-empty? Does it have real content (not stubs)?
- Look for TODO/FIXME/placeholder markers in scoped files
- FAIL if any specified file is absent, empty, stub-only, or has unresolved placeholders

#### Dimension 3 — Correctness

Is the logic correct with no concrete errors or misimplementations?

- Read each modified file and trace the logic for the main use cases
- Check for: off-by-one errors, wrong conditions, incorrect function calls, type mismatches,
  missing error handling at external boundaries
- FAIL if any concrete error is identified (not hypothetical)

#### Dimension 4 — Test Gate

Do tests pass where tests are applicable?

- Run the project's test suite for affected modules when a test runner exists
- If no test runner is configured: check if test files exist and whether they reference
  the modified code; if tests exist, run them
- If no tests exist for this area and none are expected: mark SKIP with explanation
- FAIL if any test fails that was previously passing

#### Dimension 5 — Governance Compliance

Would the changes pass quality gates A1–A6?

- **A1 — Trigger**: Are there un-handled sentinel tokens or governance triggers in the diff?
- **A2 — Scope**: Do staged changes match the brief's stated scope?
- **A4 — Secrets**: No credentials, tokens, or secrets in staged files
- **A6 — Contract**: Task contract present and up-to-date (for task group sessions)
- FAIL if any gate would fail at commit time

#### Dimension 6 — Integration Integrity

Does the change integrate cleanly without breaking callers or consumers?

- For each modified function/interface: search for callers in the codebase
- Evaluate each caller: does it still work after the change? (Downstream Consumer Validation
  per `_agent-glossary.md` § Cohesion Review)
- Check cross-references: docs, index files, import lists, config references
- FAIL if any caller would break or any reference is dangling

### Fix Phase

Apply targeted fixes for each FAIL finding from the most recent assessment.

**Fix principles:**
- One fix target per failing dimension per cycle — do not bundle unrelated fixes
- Minimal change: address the identified gap, do not refactor surrounding code
- Track each change: note what was modified and why
- Do NOT introduce new issues while fixing

After applying all fixes: `advance_phase "reassess"`

### Reassess Phase

Re-run the full assessment (all 6 dimensions) for assessment cycle N+1.

**Regression check** (mandatory, runs before recording results):
For every dimension that was PASS in the prior cycle, verify it is still PASS. If a
previously-passing dimension is now FAIL, this is a regression:

1. Record in the assessment block: `[REGRESSION] <dimension> — previously passed, now fails: <description>`
2. Write regression sentinel:
   ```bash
   source .claude/hooks/_analytics-helper.sh && source .claude/hooks/_phase-helper.sh
   state_dir=$(get_session_state_dir)
   printf 'FINISH_LOOP_REGRESSION: %s/%s\n' "<dimension>" "<description>" >> "$state_dir/cohesion-reviewed"
   ```
3. Escalate: write escalation file and exit

**After reassess (no regression):**
- ALL PASS → Converged → write completion sentinel (see Convergence Sentinels below) → proceed to Commit Phase
- ANY FAIL (cycle < 5) → `advance_phase "fix"` (next cycle)
- Cycle ≥ 5 → write incomplete sentinel → escalate

### Convergence Sentinels

Write to the `cohesion-reviewed` state file before advancing to commit or escalating:

**Convergence (all pass):**
```bash
source .claude/hooks/_analytics-helper.sh && source .claude/hooks/_phase-helper.sh
state_dir=$(get_session_state_dir)
printf 'FINISH_LOOP_RESULT: COMPLETE\ncycles: %s\n' "$CYCLE_COUNT" >> "$state_dir/cohesion-reviewed"
```

**Incomplete (cycle limit):**
```bash
source .claude/hooks/_analytics-helper.sh && source .claude/hooks/_phase-helper.sh
state_dir=$(get_session_state_dir)
printf 'FINISH_LOOP_RESULT: INCOMPLETE\ncycles: %s\nfailing_dimensions: %s\n' \
  "$CYCLE_COUNT" "$FAILING_DIM_LIST" >> "$state_dir/cohesion-reviewed"
```

The runner outcome-detector reads these sentinels (scoped to finish-loop sessions):
- `FINISH_LOOP_RESULT: INCOMPLETE` → `review:finish-incomplete`
- `FINISH_LOOP_REGRESSION:` → `review:scope-deviation`
- `FINISH_LOOP_RESULT: COMPLETE` → normal `completed:success` path

### Commit Phase

1. `advance_phase "commit"` before the git commit command
2. Stage all changes and commit with trailers:
   ```
   <subject — what was fixed/completed>

   <description — convergence summary: N cycles, dimensions that required fixes>

   Session: <session_number>
   Decisions: <applicable decisions>
   Gates-A: A1-pass A2-pass A3-<result> A4-pass A5-n/a A6-<result>
   Gates-B: B1-pass B2-pass B3-pass
   Automation: runner
   ```
3. The pre-commit gates run automatically. Resolve any failures before retrying.

### Close Phase

1. `advance_phase "close"`
2. Update session log
3. Commit session log with `Gates-A: A1-pass A2-n/a A3-n/a A4-n/a A5-n/a A6-n/a`
4. Solo merge via `session-close-check.sh` when `solo=true`

### Escalation Protocol

If BLOCKED: write escalation YAML to `.claude/.automation/escalations/{entry_id}.yaml` and exit.

Valid types: gate-failure, governance-block, phase-tag-escalation, ambiguity,
scope-exceeded, dependency-missing
