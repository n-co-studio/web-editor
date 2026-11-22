# Decision t-0082 — The advisory review's findings are a file, and Blocking ones must be resolved

**Status:** Accepted
**Date:** 2026-11-22
**Amends:** Prompt A Phase 2 and `_advisory-board.md` Operator Review. `.claude/tools/review-findings.sh`,
`.claude/.automation/schemas/review-findings.yaml`, `docs/ai/prompts/prompt-a-repo-os.md`,
`.templatesyncignore`, `.claude/hooks/pre-commit-gates.sh` (close-commit scope).

## Triggers

- type: file
- path: `\.claude/tools/review-findings\.sh|\.claude/\.automation/schemas/review-findings\.yaml|docs/spec/review-findings/`
- keywords: `review-findings, review_findings`

## Context

Prompt A presents its Refinement Report in chat: Critical Findings, Recommendations and Ideas, each
answered Accept, Reject or Defer. "All Critical findings must be addressed" was a prose rule. The
child app Massimo shows each finding on its Specs page as data, records the operator's decision
there, and needs Prompt A to read that decision back (Massimo request R5).

## Decision

1. **One file per reviewed spec version.** `docs/spec/review-findings/<version>.yaml`, schema
   `review-findings` v1.0.0 (SCHEMA-CHANGELOG v1.17.0), in the strict line layout of the project
   registry (t-0079). The repo owns it: the template ships none, and `.templatesyncignore` lists the
   directory (t-0051, t-0052).
2. **Fields.** Each finding has:
   - `id` (F1, F2, …);
   - `kind`: critical, recommendation or idea;
   - `severity`: Blocking for critical, Advisory otherwise;
   - `agent`, `spec_file` and `section`;
   - `finding` and `suggested_fix`;
   - `status`: open, applied, dismissed or deferred;
   - `reason`.

   An Unresolved Critic finding is critical, and a PM spec-edit proposal is a recommendation.
   Severity is written by the tool from kind, never supplied, so the two cannot disagree. Every value
   is one line.
3. **One writer.** `.claude/tools/review-findings.sh`:
   - `write <version>` validates the findings on stdin and creates the file atomically. It refuses an
     existing file unless `--replace` is given, so earlier decisions are not overwritten silently.
   - `set <version> <id> <status> [--reason]` records a decision and leaves every other finding
     unchanged. Massimo uses it too. A new decision replaces the previous reason.
   - `check <version>` exits 0 only when every Blocking finding is `applied`, or `dismissed` with a
     reason. Otherwise it exits 1 and names each one.

   A file that cannot be read is an error, never treated as absent.
4. **Status meanings.**
   - Accept → `applied` once the change is made.
   - Reject → `dismissed`. A Blocking finding needs the operator's reason; this is the "explicitly
     rejected" of R5.
   - Defer → `deferred`, which does not resolve a Blocking finding.
   - Advisory findings never block.
5. **Prompt A uses it.** Phase 2 writes every finding before presenting the report. It then records
   each CLI decision with `set`, or re-reads the file for decisions made in Massimo. `check` must exit
   0 before Phase 3. The `advisory-reviewed` evidence names the file (`findings:`).
6. **The session may commit the file.** A governance-close session commits only the paths
   `_close_commit_allowed` in `.claude/hooks/pre-commit-gates.sh` lists (t-0069). That list now
   includes `docs/spec/review-findings/<v>.yaml`, one level deep and `.yaml` only, for
   `advisory-init`/`advisory-reinit`. It also covers `spec-fresh`/`spec-update`, which run the review
   once R6 moves it before compile. Without this the file could be written but never committed. gate-conformance
   proves the file is allowed and that a nested path, a non-`.yaml` file or a compiled spec still
   is not.
7. **Why a tool, not Edit/Write.** An `advisory-init` session may write files only in its governance
   phase (write-guard, `_phase-helper.sh`). Changing that is a hooks change the operator merges by
   hand. The session runs the tool through Bash in synthesize and op-review, as Prompt T does for its
   bundles. The tool also keeps the layout strict for both writers.

## Known limits

- **One line per value.** A finding or fix longer than a line is summarised; the chat report keeps
  the full text.
- **No lock between writers.** `set` reads, changes and atomically replaces the file. If the session
  and Massimo both set a finding in the same instant, one update can be lost. A single operator makes
  this unlikely, and re-running the `set` restores it.
- **`--replace` discards the previous round.** A new review of the same version starts again. The
  previous file stays in git history.
- **R6 moves the review.** Request R6 runs the advisory review before compile. That review uses the
  same file, keyed by the version under review.
