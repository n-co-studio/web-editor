# Eval Study Brief: [Short Title]

<!-- Pre-registration artifact. Complete ALL sections before any cells run.
     Commit this doc (or the filled study.yaml) and record the git SHA as the
     pre-registration anchor. Do not edit the Study Question, Hypothesis, Arms,
     Tasks, n_reps, Judge Config, Blinding Protocol, or Decision Rule after cells begin.
     Deviations must go in Deviation Log.

     This template covers MULTI-ARM evaluation studies (multiple held-constant conditions).
     For single-hypothesis spikes (one question, one experiment), use _experiment-brief.md instead.
     See docs/ai/eval/_nomenclature.md for the full data model and ID scheme.
     Decision t-0046. -->

## Study Metadata

| Field | Value |
|-------|-------|
| `study_id` | `{YYYYMMDD}-{lineage_slug}-v{n}` |
| `lineage_id` | `{lineage_slug}` |
| `run_context` | `template` or `project` |
| `target_repo` | `{repo identifier or "self"}` |
| `target_baseline_sha` | `{git SHA — fill after baseline commit}` |
| `pre_registered_at` | `{ISO 8601 — fill after pre-reg commit}` |

---

## Study Question

[One sentence: what specific property or capability is this study measuring?]

## Hypothesis

[What you expect the result to be, and why. Be specific enough that the Decision Rule
below follows directly from it. Example: "Providing governance context (arm GV) will
increase blind judge scores by ≥ 0.2 compared to bare (arm B0) because..."]

---

## Lineage

[Describe the lineage: what question is being answered across versions? Which prior study (if any)
does this continue? What changed vs. the prior version (different n_reps, new arm, refined task)?]

| Field | Value |
|-------|-------|
| Lineage | `{lineage_id}` |
| Prior version | `{prior study_id or "first in lineage"}` |
| What changed | [brief description] |

---

## Arms

| arm_id | Label | Condition (what is held constant) | What this arm isolates |
|--------|-------|----------------------------------|------------------------|
| `{id}` | [label] | [one sentence: the held-constant config] | [what capability/risk is isolated] |
| `{id}` | [label] | [one sentence] | [what is isolated] |
| ... | | | |

Minimum 2 arms. One arm should be a **control/baseline** (bare or current behavior).

---

## Task Set

| task_id | Description | What it probes | Expected baseline behavior |
|---------|-------------|----------------|---------------------------|
| `{id}` | [what the agent is asked to do] | [capability or risk measured] | [expected behavior without intervention] |
| `{id}` | [description] | [what it probes] | [baseline] |
| ... | | | |

---

## n_reps

`n_reps = {number}` — repetitions per cell (arm × task).

Minimum 3. Rationale: [why this n is sufficient for the decision rule below, or why it is an accepted limitation].

---

## Judge Config

| Field | Value |
|-------|-------|
| Model | `{model_id}` |
| API version | `{api_version}` |
| Profile | [default or path to config override] |

### Rubric

<!-- Embed the rubric inline. The judge sees this exactly. Do not leave placeholder text. -->

**Dimensions** (each scored 0.0–1.0):

| Dimension | Description | Weight |
|-----------|-------------|--------|
| [dimension_1] | [what this dimension measures] | [weight or "equal"] |
| [dimension_2] | [description] | [weight] |
| ... | | |

**Overall score**: [describe how dimensions are combined, e.g. "weighted average" or "minimum of all dimensions"]

**Zheng et al. bias checklist** (required before judging begins):
- [ ] Dual-ordering: each pair of submissions judged in both orders; scores averaged
- [ ] Code-only mode: branch names, session logs, commit trailers, `.claude/`, `docs/ai/`, `AI.md` stripped
- [ ] Shuffle manifest: arm identity is not visible in submission filenames or content
- [ ] Judge prompt reviewed for leading language (e.g., avoid "better" before the judge has seen both)

---

## Blinding Protocol

**Seeded shuffle manifest**: Before any cells run, generate a seeded random mapping
of (arm × task × rep) → submission order. Commit to `docs/ai/eval/{study_id}/shuffle-manifest.json`.

Random seed: `{seed — record here before generation}`

**What is mechanically stripped** from each submission before the judge sees it:
- Branch names and session IDs
- Session log files (`docs/ai/logs/sessions/`)
- Commit trailers (`Session:`, `Automation:`, `Decisions:`)
- All governance-ceremony files: `.claude/`, `docs/ai/`, `AI.md`, `CLAUDE.md`
- Any other metadata that would identify the arm

**What is preserved** (code-only content):
- Source code changes (the actual product of the agent's work)
- File structure changes
- Commit messages (minus trailers)

---

## Pre-registered Decision Rule

| Field | Value |
|-------|-------|
| Metric | `{metric — e.g. mean_blind_judge_score, pass_rate, hidden_rate}` |
| Threshold | `{numeric value}` |
| Direction | `above` or `below` |

**Verdicts**:
- Above threshold: [what this means — e.g. "adopt treatment arm"]
- Below threshold: [what this means — e.g. "do not adopt, collect more data"]
- Tie / inconclusive: [what constitutes a tie and what the next step is]

The decision rule must be computable from the raw cell records without post-hoc judgment.
Any post-hoc adjustment is a deviation (record in Deviation Log).

---

## Provenance to Capture

At study run time, record in `study.yaml`:
- [ ] Orchestrator model ID + API version
- [ ] Runner version (git SHA or tag)
- [ ] Config/prompt-version hash (sha256 of the orchestration config)
- [ ] OS + shell environment
- [ ] `target_baseline_sha` (the exact baseline commit)

At each cell run, record in `cells/{arm_id}-{task_id}-r{rep}.yaml`:
- [ ] `model`, `api_version`
- [ ] `started_at`, `completed_at`, `wall_time_s`
- [ ] `token_counts.input`, `.output`, `.cache`
- [ ] `target_commit_sha`
- [ ] Gate outputs
- [ ] `raw_artifact_dir` pointer

---

## Threats to Validity

Pre-declare threats before any cells run. Add to report unchanged.

| Threat | Type | Mitigation (or accepted limitation) |
|--------|------|-------------------------------------|
| Small n (n_reps = {n}) | Statistical | [mitigation or: "accepted — decision is directional not conclusive"] |
| Model API drift | External validity | [mitigation: e.g. pin API version; or: "cells run within 24h to minimize drift"] |
| Judge prompt sensitivity | Measurement | [mitigation: e.g. dual-ordering per Zheng et al.] |
| Task selection bias | Internal validity | [mitigation: e.g. tasks chosen to probe known failure modes, not cherry-picked wins] |
| [additional threat] | [type] | [mitigation] |

---

## Deviation Log Pointer

Deviations from this pre-registered plan are recorded in:
`docs/ai/eval/{study_id}/deviations.md`

Format: per-deviation entry with `cell_id`, `description`, `disposition`.
The report's Deviation Log section is generated from this file.
