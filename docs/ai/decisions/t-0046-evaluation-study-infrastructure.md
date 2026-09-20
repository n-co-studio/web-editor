# Decision t-0046: Evaluation Study Infrastructure

**Status**: Accepted
**Date**: 2026-07-01
**Session**: daemon-20260701-134124-67409 (eval-study-infrastructure brief 1)

## Triggers

- type: file
- path: `\.claude/\.automation/schemas/eval-`
- path: `docs/spec/_templates/_eval-`
- path: `docs/ai/prompts/prompt-eval-study\.md`
- path: `docs/ai/eval/_nomenclature\.md`
- keywords: `eval study, evaluation study, lineage_id, study_id, cell_id, arm, n_reps, blinding, shuffle-manifest, eval-study, eval-cell, eval-suite, pre-registration, decision rule, raw-data-complete`

<!--
Scoped to the eval data model itself — schemas, templates, prompt, nomenclature —
not to `docs/ai/eval/{study_id}/` study records. Writing a study record *uses*
this convention; it does not change it, and a per-cell data commit demanding a
Decisions: trailer would make the trailer noise rather than signal.
-->

---

## Context

Repo OS had no portable structure for multi-arm evaluation studies. The "Repo OS A/B v5"
governance study (2026-07-01) was conducted ad hoc: arms, tasks, reps, blinding protocol,
judge config, and results were all organized per-study without a shared schema or template.

The single-hypothesis `_experiment-brief.md` template was insufficient for this use case:
it handles one question / one method and has no concept of arms, tasks across arms,
n_reps, blind judge config, or pre-registered decision rules with threshold comparisons.
Extending it would overload its single-responsibility contract.

A recurring structured evaluation capability was needed so that:
1. Future studies are pre-registered (study brief committed before cells run).
2. Results are raw-data-complete and re-derivable from committed records.
3. Raw artifacts containing live secrets never get committed.
4. Template and child (project) repos both write study records under the same structure.
5. The data model is connective: studies in the same lineage share a `lineage_id`,
   enabling longitudinal comparisons (v4 → v5 → v6).

## Decision

Ship a portable evaluation study data model with:

1. **Nomenclature** (`docs/ai/eval/_nomenclature.md`): lineage/study/arm/task/cell/suite/series
   hierarchy with stable ID scheme, two run contexts (template + project), committed-vs-gitignored
   retention split, and the secret-sanitization rule.

2. **Three schemas** (`.claude/.automation/schemas/eval-*.yaml`, matching existing repo schema style):
   - `eval-study.yaml`: pre-registered study manifest (arms, tasks, n_reps, judge, decision rule,
     provenance, blinding, status lifecycle)
   - `eval-cell.yaml`: per-cell run record (metrics + pointers only, never inline raw content)
   - `eval-suite.yaml`: deterministic harness results (TP/FN/FP/TN + TAP wire format)

3. **Two templates** (`docs/spec/_templates/`):
   - `_eval-study-brief.md`: pre-registration artifact (arms table, task set, n_reps, embedded
     rubric, seeded-shuffle blinding protocol per Zheng et al., pre-registered decision rule,
     threats to validity, deviation log pointer)
   - `_eval-report.md`: raw-data-complete results report (per-cell IDs + raw-artifact pointers,
     model/API version, target commit SHA, config hash, embedded rubric + raw judge output pointers,
     structured deviation log, auto-computed decision-rule verdict, cost table, honesty note)

4. **Directory convention**:
   - Committed: `docs/ai/eval/{study_id}/` — study.yaml, cells/*.yaml, suites/*, shuffle-manifest.json,
     deviations.md, cell-index.yaml, report.md
   - Gitignored: `.claude/.automation/reports/eval/{study_id}/{cell_id}/` — diff.patch,
     transcript.log, judge-transcript.md, tokens.json, timing.json, submission/

5. **Mode parity** (`_mode-guard-helper.sh`): `docs/ai/eval/*` added to child and autonomous mode
   carve-outs so project repos can write their own study records. Template-only paths
   (`.claude/hooks/`, `docs/spec/_templates/`, etc.) remain protected.

6. **Wiring**: `AI.md` Source of Truth + Spec Convention updated; `_experiment-brief.md` note
   distinguishes single-hypothesis spikes from multi-arm studies; `.gitignore` adds
   `.claude/.automation/reports/eval/`.

## Rationale

**Why not extend `_experiment-brief.md` and `work-order.yaml`?**
The single-hypothesis spike shape (one question, one method, learnings/disposition) and the flat
work-order grouping don't carry arms/tasks/reps/provenance without overloading their contracts.
New sibling schemas keep both clean (Architect pattern; Pragmatist YAGNI preserved by not
pre-building open-ended generality).

**Why not store series as a schema level?**
Series (e.g. "all T4 cells") is a derived join, not a stored entity. Storing it would create
denormalization risk (drift between cell records and series cache) with no benefit. Series
are computed from `cells/*.yaml` projections.

**Why not commit raw artifacts for full reproducibility?**
`claude -p` is non-deterministic; models drift; n is small. Bit-reproducibility is false — claiming
it would be dishonest. More importantly, raw artifacts risk committing live secrets (motivating
example: v5 T5 `sk_live_` Stripe key test). Auditability via gitignored raw + committed pointers
is the honest, safe design.

**Why `_mode-guard-helper.sh` rather than `write-guard.sh`?**
`write-guard.sh` is immune (listed in `is_immune()`) — it cannot be modified by any agent via
model tools. The carve-out logic lives in `_mode-guard-helper.sh::is_carved_out()`, which is not
immune and is writable in template mode via the `.claude/hooks/*` carve-out. This is the
correct and intended editing surface for mode carve-outs.

## Consequences

- Child repos inheriting this template can write study records to `docs/ai/eval/` without
  `REPO_OS_UNLOCK_PATH` or mode overrides.
- Template-level studies (targeting governance machinery) use identical schemas/templates
  as project-level studies (targeting product code), supporting consistent tooling in Brief 2.
- Raw artifacts containing sensitive data stay in gitignored paths and pass the A4 secret scan
  boundary cleanly.
- Brief 2 (orchestration layer) can build the conductor agent, session-type, and prompt
  against this brief's schema + template artifacts as stable contracts.

## Alternatives Considered

See task brief `docs/ai/task-groups/eval-study-infrastructure` (session contract) for full
alternatives considered section.

## References

- `docs/ai/eval/_nomenclature.md`
- `.claude/.automation/schemas/eval-study.yaml`, `eval-cell.yaml`, `eval-suite.yaml`
- `docs/spec/_templates/_eval-study-brief.md`, `_eval-report.md`
- `.claude/hooks/_mode-guard-helper.sh` (carve-out added)
- Decision t-0022 (template decision naming — t-prefix reserved)
- Zheng et al. bias checklist (dual-ordering + position-blind judging)

---

## Amendment 1 — Orchestration Layer

**Date**: 2026-07-01
**Session**: daemon-20260701-140242-67409 (eval-study-infrastructure brief 2)

### What was added

**Thin conductor library** (`.claude/.automation/lib/eval-conductor.sh`): Bash-3 compatible
orchestration library composing existing runner/queue/work-order primitives. Public API:
`eval_load_study`, `eval_launch_cells`, `eval_await_cells`, `eval_collect_artifacts`,
`eval_extract_submission`, `eval_trigger_judge`, `eval_generate_report`, `eval_resolve_target`.
Does NOT duplicate runner.sh dequeue/launch logic.

**Two session types** (`docs/ai/workflow-appendix/session-type-eval.md`):
- `eval` (conductor): phase sequence `init→design→pre-register→launch→await→collect→judge→report→close`;
  full governance applies to conductor's own committed records; cells never merged to main.
- `eval-cell` (per-cell): phase sequence `init→build→commit→close`; per-cell worktree +
  per-PPID sidecar session ID; no close-merge; A4-only gate (standard arms) or full gate
  (full-governance arms, declared in `study.yaml:arms[].gate_profile`).

**Orchestrator prompt** (`docs/ai/prompts/prompt-eval-study.md`): Entry point for `eval` session
type; covers all eight phases from design through close; enforces pre-registration lock
(study.yaml committed before any cell runs) and blinding integrity (shuffle-manifest join at
report time only).

**`judge` permission profile** (`.claude/.automation/lib/permission-profiles.sh`): Read-only
scoring profile. Blocks: Edit, Write, Bash(git commit:*), Bash(git push:*), AskUserQuestion.
Permits: Read, Grep, Glob, and read-only Bash commands.

**Model routing** (`.claude/.automation/config.yaml`): `eval: sonnet`, `eval-cell: sonnet`,
`judge: haiku`. Operator-tunable defaults.

**Phase helper registration** (`.claude/hooks/_phase-helper.sh`): `eval` and `eval-cell` added
to `get_phases_for_type()` and `get_write_phases_for_type()`. Write-allowed phases for `eval`:
`pre-register launch collect judge report close`. For `eval-cell`: `build commit`.

**Glossary registration** (`.claude/agents/_agent-glossary.md`): `eval` and `eval-cell` added
to the Phase Model session-type table with phase sequences and notes.

**AI.md on-demand entries**: `session-type-eval.md` and `prompt-eval-study.md` added with
detection trigger (`eval/*` branch or `prompt-eval-study.md` reference).

### Isolation invariants (governance-critical)

1. **No shared `.session-id`**: per-PPID sidecar (`.session-id.<PPID>`) + per-cell worktree
   → each cell has a distinct `REPO_OS_SESSION_ID`.
2. **No concurrent merges to main**: cells commit to `eval/{study_id}/{arm}/{task}/r{rep}`
   branches only; never merged.
3. **Distinct phase-state paths**: each worktree has its own `wt-sessions/{cell_session_id}/`
   state directory — no collision with conductor or sibling cells.
4. **Branch pruning**: conductor prunes all `eval/{study_id}/**` branches at close.

### Blind-extraction protocol

`eval_extract_submission` strips from cell diff patches:
- Branch names / session log references
- Commit trailers: `Session:`, `Decisions:`, `Gates-A:`, `Gates-B:`, `Automation:`
- Governance-ceremony files: `.claude/`, `docs/ai/`, `AI.md`, `CLAUDE.md`

Output: `raw_root/{cell_id}/submission/submission.patch` (gitignored). Judge reads this;
shuffle-manifest join is deferred to report phase.

### Mode parity

`eval` and `eval-cell` operate in both template and project (child repo) contexts:
- Template: committed records in conductor's `docs/ai/eval/{study_id}/`
- Project: cell agents run in child repo worktrees; committed records still in conductor's repo

Child repos do not need additional unlock flags — the `is_carved_out` carve-out added in the
original decision (Brief 1) already covers `docs/ai/eval/*`.

### References (Amendment 1)

- `.claude/.automation/lib/eval-conductor.sh`
- `docs/ai/workflow-appendix/session-type-eval.md`
- `docs/ai/prompts/prompt-eval-study.md`
- `.claude/.automation/lib/permission-profiles.sh`
- `.claude/.automation/config.yaml`
- `.claude/hooks/_phase-helper.sh`
- `.claude/agents/_agent-glossary.md`
