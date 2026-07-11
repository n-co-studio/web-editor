# Evaluation Study Nomenclature

Connective data model for multi-arm evaluation studies in Repo OS.
Decision t-0046.

---

## Hierarchy

```
Lineage
  └─ Study (pre-registered)
       ├─ Arm (held-constant condition)
       ├─ Task (probe)
       ├─ Cell = Arm × Task × Rep (one agent run)
       └─ Suite (deterministic harness, attached to a Study)

Series — derived query over Cells, NOT a stored level (see below)
```

### Lineage

A **lineage** is a versioned question answered across studies over time.
Example: "Does governance context improve agent accuracy?" answered in v4 → v5 → v6.

- `lineage_id`: kebab slug, e.g. `repo-os-governance-ab`
- Cross-study connective key. Does not own arms, tasks, or results.
- Persists across studies; a new study in the same lineage increments `v{n}`.

### Study

A **study** is one pre-registered evaluation.
Created by filling `_eval-study-brief.md` and committing `docs/ai/eval/{study_id}/study.yaml`
before any cells run (the SHA of that commit is the pre-registration anchor).

- `study_id = {YYYYMMDD}-{lineage_slug}-v{n}`
  Example: `20260701-repo-os-governance-ab-v5`
- Owns: arms, tasks, n_reps, decision rule, judge config, provenance, blinding.
- Status lifecycle: `registered → running → partial → completed | failed`

### Arm

An **arm** is a held-constant experimental condition (e.g., B0 bare / CX context-only / GV governance).

- `arm_id`: short label, e.g. `B0`, `CX`, `GV`
- Defined in the study manifest. Not a first-class schema file.

### Task

A **task** is a probe — one type of agent work evaluated across arms (e.g., T2 branch creation / T4 governance protocol / T5 secret handling).

- `task_id`: short label, e.g. `T2`, `T4`, `T5`
- Defined in the study manifest. Not a first-class schema file.

### Cell

A **cell** is the atomic unit: **one arm × one task × one repetition = one headless agent run**.

- `cell_id = {study_id}/{arm_id}/{task_id}/r{rep}`
  Example: `20260701-repo-os-governance-ab-v5/GV/T4/r1`
- Deterministic from coordinates → enables idempotent re-runs and re-derivable IDs.
- Committed record: `docs/ai/eval/{study_id}/cells/{arm_id}-{task_id}-r{rep}.yaml`
- Contains metrics + pointers only — **never inline raw diffs, transcripts, or secrets**.

### Suite

A **suite** is a deterministic, non-agent harness attached to a study (e.g., "run the gate test 30 times and count catch rate").

- `suite_id = {study_id}/{harness_slug}`
  Example: `20260701-repo-os-governance-ab-v5/gate-harness`
- Results recorded in TAP format (reuses `.claude/hooks/tests/` convention).
- Committed: `docs/ai/eval/{study_id}/suites/{harness_slug}.yaml` + TAP file pointer.

### Series (derived — NOT stored)

A **series** is a *query* over cells, not a stored schema level.
Example: "the T4 series" = all cells where `task_id = T4` across all arms and reps.

**Do not create a `series:` schema.** Series are computed by joining `cells/*.yaml`
on the relevant field. Storing them would be over-nesting and risk drift from the
canonical cell records.

---

## ID Scheme Summary

| Level | ID Pattern | Example |
|-------|-----------|---------|
| Lineage | `{kebab-slug}` | `repo-os-governance-ab` |
| Study | `{YYYYMMDD}-{lineage_slug}-v{n}` | `20260701-repo-os-governance-ab-v5` |
| Cell | `{study_id}/{arm_id}/{task_id}/r{rep}` | `20260701-…-v5/GV/T4/r1` |
| Suite | `{study_id}/{harness_slug}` | `20260701-…-v5/gate-harness` |

---

## Run Contexts

Two run contexts use the identical schemas, templates, and directory structure:

### (a) Template-level studies

- **Target**: the governance machinery itself — gate/hook harness, decision enforcement, session-type behavior.
- Example: Repo OS A/B v5 (measuring whether governance context improves agent task accuracy).
- Study records committed under `docs/ai/eval/{study_id}/` in the template repo.
- Raw artifacts in the template repo's `.claude/.automation/reports/eval/{study_id}/`.

### (b) Project-level studies

- **Target**: a child repo's product code, prompt variants, or agent behaviors.
- Example: "Does system-prompt version 3 reduce hallucination rate on our product domain?"
- Study records committed under `docs/ai/eval/{study_id}/` in the child repo.
- Raw artifacts in the child repo's `.claude/.automation/reports/eval/{study_id}/`.
- Child repos write to `docs/ai/eval/` via the `is_carved_out` child-mode carve-out
  added in Decision t-0046 (write-guard `_mode-guard-helper.sh`).

Both contexts share the same `eval-study.yaml`, `eval-cell.yaml`, `eval-suite.yaml` schemas
and the same `_eval-study-brief.md` / `_eval-report.md` templates.

---

## Directory Convention

### Committed (portable, tracked in git, inherited by children via template-sync)

```
docs/ai/eval/
  {study_id}/
    study.yaml            # pre-registered manifest (eval-study.yaml schema)
    cells/
      {arm_id}-{task_id}-r{rep}.yaml   # per-cell record (eval-cell.yaml schema)
    suites/
      {harness_slug}.yaml              # deterministic suite record (eval-suite.yaml)
      {harness_slug}.tap               # TAP output (or pointer to it)
    shuffle-manifest.json # seeded arm-order per cell (blinding evidence)
    deviations.md         # structured deviation log (per-deviation: cell_id, description, disposition)
    cell-index.yaml       # denormalized projection of cells/*.yaml for report generation
    report.md             # filled from _eval-report.md template
```

**Committed records carry metrics and pointers only.**
They must pass gate A4 (secret scan) at every commit.

### Gitignored (local raw, may contain live secrets / large diffs)

```
.claude/.automation/reports/eval/
  {study_id}/
    {cell_id}/            # cell_id path-segments: arm/task/rep
      diff.patch
      transcript.log
      judge-transcript.md
      tokens.json
      timing.json
      submission/         # blinded code-only extract (branch names + session artifacts stripped)
```

These artifacts are listed under `.claude/.automation/reports/` in `.gitignore` (Decision 0017).

---

## Secret-Sanitization Rule

**Raw artifacts MUST NOT be committed.**

The motivating example: in the Repo OS A/B v5 study, task T5 tested whether the agent
accidentally committed a `sk_live_` prefixed Stripe live key. The raw judge transcript
for that cell necessarily contained the key text. Committing the raw transcript would
have defeated the entire purpose of the test.

Rules:
1. `cells/*.yaml` carries gate outputs, scores, and pointer paths — **no inline secrets**.
2. `submission/` extracts (blinded code-only snapshots) are stripped of branch names,
   session logs, commit trailers, governance-ceremony files before the judge sees them.
3. Every committed `cells/*.yaml` must pass gate A4 (secret scan).
4. If a cell's raw artifact directory contains a secret, that secret stays in
   `.claude/.automation/reports/eval/` (gitignored) and is never promoted to the
   committed record. If this makes the record incomplete, document the gap in
   `deviations.md` with `disposition: sanitized`.

---

## Blinding Protocol

Blinding prevents the judge from using arm identity (rather than code quality) as
a signal. Per Zheng et al. bias checklist:

1. **Seeded shuffle-manifest**: before any cells run, generate a seeded random mapping
   of (arm × task × rep) → submission order. Commit `shuffle-manifest.json` as part
   of pre-registration (same commit as `study.yaml`).
2. **Code-only extraction**: strip from each submission — branch names, session logs,
   commit trailers, governance-ceremony files (`.claude/`, `docs/ai/`, `AI.md`).
3. **Dual-ordering**: present each submission pair in both orders to the judge and
   average scores (controls for positional preference).
4. **Post-hoc verification**: the judge's shuffle-manifest reference in the report
   proves which submission was which arm. Any deviation is logged in `deviations.md`.

---

## Provenance Requirements

A study is re-derivable (not reproduced — see Auditability note below) when:
- `study.yaml` records: `orchestrator_model`, `config_hash`, `prompt_version`, `runner_version`, `env`
- Each `cells/*.yaml` records: `model`, `api_version`, `target_commit_sha`, `started_at`, `completed_at`, `wall_time_s`, `token_counts`
- `report.md` references: `study_id`, `cell-index.yaml`, `shuffle-manifest.json`, design doc path

## Auditability, Not Reproducibility

`claude -p` is non-deterministic; models drift; n is small (typically 3–5 reps per cell).
**These studies support auditability, not bit-for-bit reproducibility.**

- "Re-derivable" means: given the committed records, an independent party can reconstruct
  what was measured, how arms were defined, what the judge scored, and why the decision
  rule fired. It does NOT mean re-running the study will produce identical outputs.
- The report template's honesty note (`<!-- HONESTY NOTE -->`) must not be omitted.
- Threats to validity (N size, model API drift, judge prompt sensitivity) must be
  pre-declared in the study brief and repeated in the report.
