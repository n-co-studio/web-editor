# {title} — Results ({date})

<!-- HONESTY NOTE: These results support AUDITABILITY, not bit-for-bit reproducibility.
     claude -p is non-deterministic; models drift; n is typically small (3–5 reps/cell).
     An independent party with the committed records can reconstruct WHAT was measured,
     HOW arms were defined, WHAT the judge scored, and WHY the decision rule fired.
     They CANNOT reproduce identical outputs by re-running the study.
     Do not claim reproducibility. Do not omit this note. Decision t-0046. -->

---

## TL;DR

[One sentence: the single citable claim from this study. Must be computable from the
Decision-Rule Verdict section below without additional interpretation.]

---

## Method

| Field | Value |
|-------|-------|
| `study_id` | `{study_id}` |
| `lineage_id` | `{lineage_id}` |
| Pre-registered at | `{ISO 8601 timestamp}` |
| Pre-registration commit | `{git SHA}` |
| Run context | `template` or `project` |
| Target repo | `{repo}` |
| Target baseline SHA | `{git SHA}` |
| n_reps | `{n}` |
| Judge model | `{model_id}` |
| Judge API version | `{api_version}` |
| Decision metric | `{metric}` |
| Decision threshold | `{threshold}` ({direction}) |

### Arms

| arm_id | Label | Condition |
|--------|-------|-----------|
| `{id}` | [label] | [condition] |
| ... | | |

### Task Set

| task_id | Description | What it probes |
|---------|-------------|----------------|
| `{id}` | [description] | [what probed] |
| ... | | |

---

## Provenance

<!-- Complete provenance enables auditability. Every field is required. -->

| Field | Value |
|-------|-------|
| Orchestrator model | `{model_id}` |
| Orchestrator API version | `{api_version}` |
| Config/prompt hash | `{sha256}` |
| Runner version | `{git SHA or tag}` |
| OS | `{os}` |
| Shell | `{shell}` |

### Per-arm model versions

| arm_id | Model | API version |
|--------|-------|-------------|
| `{id}` | `{model}` | `{api_version}` |
| ... | | |

---

## Results by Task

<!-- One table per task. Columns: arm_id, wall_time_s (mean), token_input (mean),
     token_output (mean), gate_pass_rate, hidden_rate (if applicable),
     blind_judge_score (mean), pbb_gap = judge − hidden_rate (if applicable). -->

### Task {task_id}: {description}

| arm_id | wall_time_s | tokens_in | tokens_out | gate_pass_rate | hidden_rate | judge_score | pbb_gap |
|--------|------------|-----------|------------|---------------|-------------|-------------|---------|
| `{id}` | | | | | | | |
| ... | | | | | | | |

*pbb_gap = blind judge score − hidden rate. Positive gap means the judge rated the
submission higher than the gate-measured hidden rate (measures judge leniency vs. mechanical detection).*

<!-- Repeat for each task_id -->

---

## Deterministic Suites

<!-- One row per suite. TAP file pointer is required. -->

| suite_id | Harness | n_runs | TP | FN | FP | TN | catch_rate | fp_rate | TAP |
|----------|---------|--------|----|----|----|----|------------|---------|-----|
| `{id}` | `{harness}` | | | | | | | | [tap](path/to.tap) |
| ... | | | | | | | | | |

*catch_rate = TP / (TP + FN). fp_rate = FP / (FP + TN).*

---

## Blind Judge

### Rubric

<!-- Copy the rubric verbatim from the study brief. Do not summarize. -->

**Dimensions**:

| Dimension | Description | Weight |
|-----------|-------------|--------|
| [dimension_1] | [description] | [weight] |
| ... | | |

**Overall score**: [combination method]

### Per-cell Raw Judge Outputs

<!-- Pointer to judge transcripts — do NOT inline the transcripts here. -->

Raw judge transcripts are in the gitignored raw artifact directories (see Raw Data / Cell Index below).

| cell_id | judge_score | transcript_ref |
|---------|-------------|----------------|
| `{cell_id}` | `{score}` | `{raw_artifact_dir}/judge-transcript.md` |
| ... | | |

### Blinding Evidence

Shuffle manifest: `docs/ai/eval/{study_id}/shuffle-manifest.json`

Random seed used: `{seed}`

Bias-checklist compliance:
- [ ] Dual-ordering applied (each pair judged in both orders; scores averaged)
- [ ] Code-only extraction: branch names, session logs, commit trailers, `.claude/`, `docs/ai/`, `AI.md` stripped
- [ ] Arm identity not visible in submission filenames or content at time of judging

---

## Decision-Rule Verdict

Pre-registered rule: `{metric}` {direction} `{threshold}`

| Arm | Mean {metric} | vs. threshold | Result |
|-----|--------------|---------------|--------|
| `{control_arm}` | `{value}` | — | baseline |
| `{treatment_arm}` | `{value}` | {above/below} | [verdict] |

**Auto-computed verdict**: [ADOPT / DO NOT ADOPT / INCONCLUSIVE]

[One sentence restating the verdict from the pre-registered map.]

Post-hoc deviations from the pre-registered rule: [none | see Deviation Log entry {id}]

---

## Cost / Weight

| arm_id | Mean wall_time_s | Mean tokens_in | Mean tokens_out | Mean tokens_cache | Relative cost |
|--------|-----------------|----------------|-----------------|-------------------|---------------|
| `{id}` | | | | | |
| ... | | | | | |

*Relative cost = total tokens (in + out) normalized to the lightest arm.*

---

## Threats to Validity

<!-- Copy verbatim from the study brief. Add post-hoc threats as additional rows. -->

| Threat | Type | Mitigation (or accepted limitation) |
|--------|------|-------------------------------------|
| Small n (n_reps = {n}) | Statistical | [from brief] |
| Model API drift | External validity | [from brief] |
| Judge prompt sensitivity | Measurement | [from brief] |
| [additional post-hoc threat if any] | [type] | [mitigation] |

---

## Deviation Log

<!-- Structured — one entry per deviation from the pre-registered plan.
     Deviations are not failures; they are transparency requirements.
     Source of truth: docs/ai/eval/{study_id}/deviations.md -->

| # | cell_id | Description | Disposition |
|---|---------|-------------|-------------|
| 1 | `{cell_id or "study-level"}` | [what deviated from the pre-registered plan] | [accepted / corrected / sanitized / flagged] |
| ... | | | |

*Disposition values: `accepted` (deviation does not affect verdict), `corrected` (fixed before final tally),
`sanitized` (raw artifact contained sensitive data — redacted from committed record),
`flagged` (may affect verdict — see TL;DR caveat if applicable).*

---

## Raw Data / Cell Index

<!-- This section makes the report re-derivable from the cell records.
     Generated from docs/ai/eval/{study_id}/cell-index.yaml.
     Do not fill manually — generate with: cat cells/*.yaml | <index tool> -->

| cell_id | arm_id | task_id | rep | status | wall_time_s | raw_artifact_dir |
|---------|--------|---------|-----|--------|------------|-----------------|
| `{cell_id}` | `{arm}` | `{task}` | `{rep}` | completed | `{s}` | `.claude/.automation/reports/eval/{path}` |
| ... | | | | | | |

---

## References

| Artifact | Path |
|----------|------|
| Study manifest | `docs/ai/eval/{study_id}/study.yaml` |
| Cell index | `docs/ai/eval/{study_id}/cell-index.yaml` |
| Shuffle manifest | `docs/ai/eval/{study_id}/shuffle-manifest.json` |
| Study brief (pre-reg) | `docs/ai/eval/{study_id}/brief.md` or spec path |
| Deviation log | `docs/ai/eval/{study_id}/deviations.md` |
| Decision record | `docs/ai/decisions/t-0046-evaluation-study-infrastructure.md` |
