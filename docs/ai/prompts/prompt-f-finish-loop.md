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
- **INHERITED** — dimension inherited from cache (cycle ≥ 2 only; see Assessment Cycle Cache)

**Record assessment results** in a structured block:

```
=== ASSESSMENT CYCLE <N> ===
Dimension 1 — Spec Alignment:     [PASS|FAIL|SKIP|INHERITED] <finding>
Dimension 2 — Completeness:       [PASS|FAIL|SKIP|INHERITED] <finding>
Dimension 3 — Correctness:        [PASS|FAIL|SKIP|INHERITED] <finding>
Dimension 4 — Test Gate:          [PASS|FAIL|SKIP|INHERITED] <finding>
Dimension 5 — Governance:         [PASS|FAIL|SKIP|INHERITED] <finding>
Dimension 6 — Integration:        [PASS|FAIL|SKIP|INHERITED] <finding>
```

**After each assessment:**
- ALL PASS or INHERITED (no FAIL) → Converged. Write completion sentinel and advance to commit
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

### Dimension Input Sets (Decision 0040)

Each dimension declares the file set whose content determines whether the dimension's
verdict can be inherited from a prior cycle. The set is the union of the brief's
declared `scope_files` (from the task contract) plus any dimension-specific extras.

The agent computes the set from the task contract at the start of each cycle.

| Dimension              | Input set                                                                                          |
|------------------------|----------------------------------------------------------------------------------------------------|
| 1 — Spec Alignment     | `scope_files` ∪ active spec files (`docs/spec/compiled/{active}/**/*.md`)                          |
| 2 — Completeness       | `scope_files`                                                                                      |
| 3 — Correctness        | `scope_files`                                                                                      |
| 4 — Test Gate          | `scope_files` ∪ test files in same modules (heuristic: matching basename `*.test.*`, `*_test.*`, `test_*.*`) |
| 5 — Governance         | `scope_files` ∪ working-tree change fingerprint (`git diff --name-only HEAD` — the files that would be staged at commit; fix phases write to the working tree without staging, so this captures the pending change set the governance gates would see) |
| 6 — Integration        | `scope_files` ∪ caller files identified at first fresh assessment (recorded in the assessment block and reused on subsequent cycles) |

For D6, when the first fresh assessment runs (cycle 1, or first reassessment after FAIL),
record the list of caller files identified during Downstream Consumer Validation in the
assessment block (e.g. `D6 callers: path/a, path/b`). On subsequent cycles, those exact
paths are appended to the input set so the hash captures both the modified files and
their consumers.

### Assessment Cycle Cache (Decision 0040)

Passing dimension verdicts are cached at `<session_state_dir>/finish-loop-cache.yaml`.
On cycle N ≥ 2, dimensions whose input hash matches the cached PASS hash are inherited
instead of re-assessed.

**Cycle 1 (always fresh):**
After each PASS verdict, record it:
```bash
source .claude/hooks/_analytics-helper.sh && source .claude/hooks/_phase-helper.sh
h=$(dimension_input_hash "<dimension-slug>" <input-file...>)
record_dimension_verdict "<dimension-slug>" "$h" "PASS" 1
```

**Cycles N ≥ 2:**
Before assessing each dimension, decide inherit vs reassess:

1. Compute the **touched-files set** for this cycle: files modified by the previous
   fix phase. Use `git diff --name-only <prev-cycle-head>` where `<prev-cycle-head>` is
   the commit-or-snapshot reference captured at the start of the previous cycle, or
   the working-tree modification list captured by the fix phase.

2. For each dimension D:
   - Compute `current_hash = dimension_input_hash "D" <D's input files>`
   - **Force-reassess** if D's input set intersects the touched-files set
     (regardless of hash). Reassess fully. This is the loop-back-source rule —
     a belt-and-suspenders guard against touch-and-revert edge cases where the
     hash alone would not invalidate the cache.
   - **Otherwise** try `cached_dimension_verdict "D" "$current_hash"`:
     - Exit 0 with `PASS` on stdout → mark `[INHERITED] PASS — hash <short>` in
       the assessment block, do not reassess
     - Exit 1 → reassess fully

3. After each fresh PASS verdict, call `record_dimension_verdict "D" "$current_hash" "PASS" <N>`
   so subsequent cycles can inherit.

4. FAIL verdicts are not cached. The next cycle's fix phase invalidates the prior
   hash; if a subsequent cycle re-assesses the same input state, a fresh assessment
   is required to confirm PASS.

Dimension slug names used in the cache (canonical):
`spec-alignment`, `completeness`, `correctness`, `test-gate`, `governance`, `integration`.

### Fix Phase

Apply targeted fixes for each FAIL finding from the most recent assessment.

**Fix principles:**
- One fix target per failing dimension per cycle — do not bundle unrelated fixes
- Minimal change: address the identified gap, do not refactor surrounding code
- Track each change: note what was modified and why
- Do NOT introduce new issues while fixing

After applying all fixes: `advance_phase "reassess"`

### Reassess Phase

Re-run the assessment for cycle N+1 using the Assessment Cycle Cache protocol:
dimensions whose input hash matches the cached PASS are inherited; the rest are
reassessed fully.

**Regression check** (mandatory, runs before recording results):

Hash comparison is the regression signal. The invariant is preserved:

- **Hash unchanged** → inputs identical → no regression is possible. Inherit `PASS`.
- **Hash changed (or force-reassess triggered)** → reassess fully. If the dimension
  was PASS in a prior cycle and now FAILs, this is a regression — record and
  escalate per the steps below.

When reassessing a previously-PASS dimension reveals FAIL:

1. Record in the assessment block: `[REGRESSION] <dimension> — previously passed, now fails: <description>`
2. Write regression sentinel:
   ```bash
   source .claude/hooks/_analytics-helper.sh && source .claude/hooks/_phase-helper.sh
   state_dir=$(get_session_state_dir)
   printf 'FINISH_LOOP_REGRESSION: %s/%s\n' "<dimension>" "<description>" >> "$state_dir/cohesion-reviewed"
   ```
3. Escalate: write escalation file and exit

**After reassess (no regression):**
- ALL PASS or INHERITED (no FAIL) → Converged → write completion sentinel (see Convergence Sentinels below) → proceed to Commit Phase
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
