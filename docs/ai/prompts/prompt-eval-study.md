# Prompt — Evaluation Study Orchestration

## Purpose

Conduct a multi-arm evaluation study using the `eval` conductor session type.
Covers: intake study design → pre-register → fan out cells → await → collect → judge → report → close.

This prompt is the entry point for the `eval` session type. It uses the thin conductor
library (`.claude/.automation/lib/eval-conductor.sh`) over existing runner/queue/work-order
primitives — it does NOT rewrite the runner.

## Prompt

You are an evaluation study conductor using the Repo OS `eval` session type.
Read `.claude/.automation/lib/eval-conductor.sh` and `docs/ai/eval/_nomenclature.md` before proceeding.

## Phase Initialization

1. `init_phase("eval")` (or `advance_phase("design")` if already initialized)
2. Read this prompt and the conductor lib in full
3. Read the study brief if provided (`_eval-study-brief.md` filled by the operator)

---

## Study Design Phase

**Objective:** Finalize the study design and produce a filled `_eval-study-brief.md`.

1. Read the operator's study intent or existing `_eval-study-brief.md` template
2. Confirm with the operator (or infer from brief):
   - `study_id` — `{YYYYMMDD}-{lineage_slug}-v{n}` (see nomenclature ID scheme)
   - `lineage_id` — versioned question slug
   - Arms (each arm = one held-constant condition)
   - Tasks (each task = one probe / what-the-agent-is-asked-to-do)
   - `n_reps` — number of repetitions per cell (minimum 3, 5+ recommended)
   - Judge model and rubric
   - Decision rule: metric, threshold, direction, verdict_map
   - Run context: `template` (governance machinery) or `project` (child repo product code)
   - Threats to validity (pre-declare before cells run)
3. Fill `docs/ai/eval/{study_id}/study.yaml` from the `eval-study.yaml` schema
4. Do NOT launch any cells yet

---

## Pre-Registration Phase

**CRITICAL: study.yaml must be committed BEFORE any cells run. This is the pre-registration anchor.**

1. Create the committed study directory: `docs/ai/eval/{study_id}/`
2. Write `study.yaml` (status: `registered`)
3. Generate the seeded `shuffle-manifest.json`:
   - Seed = deterministic hash of `study_id`
   - List each (arm × task × rep) tuple with a randomized anonymous label
   - Commit `shuffle-manifest.json` in the SAME commit as `study.yaml`
4. Write `deviations.md` stub (empty — populated at close if deviations occur)
5. Commit everything: `git add docs/ai/eval/{study_id}/ && git commit`
6. Verify the commit: `git ls-files docs/ai/eval/{study_id}/study.yaml`
7. Then call: `eval_load_study docs/ai/eval/{study_id}/study.yaml`

If `eval_load_study` fails (missing commit, wrong status, missing fields), fix before proceeding.

---

## Cell Launch Phase

1. `eval_launch_cells {study_id}` — expands arms × tasks × reps into cell queue entries
   - Creates cell stub records at `docs/ai/eval/{study_id}/cells/{arm}-{task}-r{rep}.yaml`
   - Status transitions: `registered → running` in `study.yaml`
   - Idempotent: already-completed cells are skipped
   - Optional: `--series {arm_id}` or `--series {task_id}` to restrict to a subset
2. Verify cell stubs created: `ls docs/ai/eval/{study_id}/cells/`
3. The runner will pick up each cell entry from the queue and launch them as `eval-cell`
   sessions in per-cell worktrees with distinct `REPO_OS_SESSION_ID`s

**Cell isolation invariants to verify before launch:**
- Each cell will run in its own worktree (`{repo}/.worktrees/{cell_session_id}/`)
- Cells use per-PPID session-id sidecars — no shared `.session-id`
- Cell branches: `eval/{study_id}/{arm_id}/{task_id}/r{rep}`
- Cells DO NOT merge to main; DO NOT seal the shared branch

---

## Await Phase

1. `eval_await_cells {study_id} [--timeout 7200]` — polls until all cells are terminal
   - Progress emitted every 30 seconds
   - Returns when all cells reach: completed / failed / review / blocked
2. Check partial failures:
   - If some reps failed → study marked `partial` → continue to collect phase
   - If ALL reps of an arm failed → blocking failure → escalate via escalation protocol
3. If timeout: write escalation file at `.claude/.automation/escalations/{entry_id}.yaml`
   with type `gate-failure`, then exit cleanly

---

## Collect Phase

1. `eval_collect_artifacts {study_id}` — reads each cell's raw artifacts and updates cell records
   - Populates: `wall_time_s`, `token_counts`, `gate_outputs`, `target_commit_sha`
   - Cell records carry metrics + pointers ONLY (no raw content)
   - Raw artifacts stay in gitignored `.claude/.automation/reports/eval/{study_id}/`
2. Verify cell records updated: check `wall_time_s` and `target_commit_sha` in cells/*.yaml
3. Commit the updated cell records: `git add docs/ai/eval/{study_id}/cells/ && git commit`

---

## Judge Phase

1. For each cell, call `eval_extract_submission {cell_id}` to produce blind code-only submission
   - Strips: branch names, session logs, commit trailers (Session:, Decisions:, Gates-A:, etc.)
   - Strips: governance-ceremony files (.claude/, docs/ai/, AI.md, CLAUDE.md)
   - Output: `raw_root/{cell_id}/submission/submission.patch` (gitignored)
2. `eval_trigger_judge {study_id}` — builds shuffle-manifest + enqueues judge entry
   - Judge runs under `judge` permission profile (read-only, no commits, no AskUserQuestion)
   - Judge reads shuffle_manifest + rubric + submissions
   - Judge writes raw scores to `raw_root/{cell_id}/judge-scores.json` (gitignored)
3. `eval_await_cells {study_id}` on the judge entries (reuse with judge queue entries)
4. If judge fails:
   - Mark `judge_status: failed` in affected cell records
   - Log deviation in `deviations.md`
   - Continue to report phase (verdict requires scores, but report without verdict is valid)

---

## Report Phase

1. `eval_generate_report {study_id}` — joins study.yaml + cells/*.yaml + judge outputs
   - Fills the `_eval-report.md` template (committed)
   - Computes decision-rule verdict: `above_threshold | below_threshold | pending`
   - Writes `report.md` to `docs/ai/eval/{study_id}/report.md`
   - Writes denormalized `cell-index.yaml` for re-derivation
2. Review report for completeness:
   - Decision-rule verdict matches pre-registered metric/threshold/direction
   - All deviations from the pre-registered plan are in `deviations.md`
   - Honesty note present (non-deterministic, auditability-not-reproducibility)
3. Commit report: `git add docs/ai/eval/{study_id}/ && git commit`

---

## Close Phase

1. Prune cell branches (they are evaluation artifacts, NOT features):
   ```bash
   git branch | grep "eval/{study_id}" | while read branch; do git branch -d "$branch" 2>/dev/null || git branch -D "$branch"; done
   ```
2. Update study status to `completed` in `study.yaml` and commit
3. Write session log at `docs/ai/logs/sessions/session-{id}.md`:
   - Summary: study conducted, verdict, any deviations
   - Changes: files created/modified in the eval dir
   - Gate results
4. Commit session log
5. The `eval` session type is NOT a solo session — it does NOT merge to main by default.
   If this is the final study in a series, the operator merges manually after review.

---

## Rules

- **Pre-registration lock:** study.yaml MUST be committed before cells run. If a cell runs before the commit, this is a deviation (log in deviations.md) and the study validity is compromised.
- **No cell merges to main:** Cell branches `eval/**` are pruned, not merged. Never run `git merge eval/**` on main.
- **Blinding integrity:** Do not look up which submission corresponds to which arm during the judge phase. The shuffle-manifest join happens at report time only.
- **Secret sanitization:** Cell raw artifacts may contain live secrets (test T5 in v5 study). Never commit from `raw_root`. Gate A4 applies to all committed records.
- **Partial failure handling:** A failed rep is a deviation, not a blocker (unless all reps of an arm fail). Log in deviations.md with `disposition: failed` or `disposition: retry`.
- **Mode parity:** For project-level studies (`run_context: project`), `target_repo` in study.yaml or `EVAL_TARGET_REPO` env var specifies the child repo. Committed records always go in the CONDUCTOR's repo at `docs/ai/eval/{study_id}/`.
- **Escalation:** If blocked at any phase and unable to resolve after 2 attempts, write an escalation file at `.claude/.automation/escalations/{entry_id}.yaml` and exit cleanly.

---

## References

- `docs/ai/eval/_nomenclature.md` — ID scheme, hierarchy, blinding protocol, auditability
- `.claude/.automation/lib/eval-conductor.sh` — conductor functions
- `.claude/.automation/schemas/eval-study.yaml` — study manifest schema
- `.claude/.automation/schemas/eval-cell.yaml` — cell record schema
- `docs/spec/_templates/_eval-study-brief.md` — pre-registration template
- `docs/spec/_templates/_eval-report.md` — report template
- `docs/ai/workflow-appendix/session-type-eval.md` — `eval`/`eval-cell` lifecycle
- Decision t-0046, Amendment 1 — orchestration layer governance record
