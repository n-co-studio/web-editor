# Decision t-0083 — A spec is reviewed before it is approved, and compiled only after

**Status:** Accepted
**Date:** 2026-11-22
**Amends:** t-0014 (the spec-fresh and spec-update sequences) and t-0082 (who writes the
findings file). Files: `.claude/hooks/_phase-helper.sh`,
`.claude/hooks/pre-commit-gates.sh` (close-commit scope), `.claude/tools/spec-compile.sh`,
`docs/ai/prompts/prompt-0-spec-builder.md`, `docs/ai/prompts/prompt-a-repo-os.md`,
`.templatesyncignore`.

## Triggers

- type: file
- path: `\.claude/tools/spec-compile\.sh|docs/spec/drafts/`
- keywords: `spec-compile, spec_compile`

## Context

Prompt 0 wrote the operator's answers straight into `docs/spec/compiled/v{n}/`. It set
`manifest.json` active in its step 7, before the operator said "Spec complete". The advisory review
(Prompt A) ran afterwards, in a separate session, on a version that was already active. Two
problems followed:
- an unapproved, unreviewed spec counted as compiled;
- a finding could only be fixed by editing a compiled version.

The child app Massimo models a spec as DRAFT → REVIEW → APPROVE → COMPILE, treats a compiled version
as never changing, and offers `spec.compile` (Massimo request R6; the operator chose this order).

## Decision

1. **The order.** spec-fresh and spec-update run
   `init → interview → write → advisory-review → approval → compile → governance → close`
   (was `init → interview → write → approval → governance → close`).
   - advisory-review is tagged both: agents review, the operator decides. It is not named
     `review`, because the commit gate's A5 check and `state-writer.sh` read a phase of that name
     as the code review. A spec session would then be blocked on a Critic cohesion verdict it
     never needs.
   - approval is the operator's "Spec complete".
   - compile is an agent phase.

   `advance_phase` refuses a jump over a phase that is not skippable. A session therefore reaches
   approval only through advisory-review, and governance only through compile. Edit/Write is
   allowed in write, advisory-review (applying accepted findings) and governance. compile writes only through the tool.
   `plan-approval.sh` is unchanged: it advances to whichever phase follows approval.
2. **The draft has its own place.** `docs/spec/drafts/v{n}/` holds the version being written:
   - Fresh mode starts it from the templates.
   - Update mode copies the latest compiled version into it, leaving out `DIGEST.md`.
   - It is owned by the repo: `.templatesyncignore` lists it, and the template ships none.
   - The mode guard needs no entry. It restricts governance paths only, and `docs/spec/` outside
     `_templates/` is not one, so a child writes the draft as it writes `docs/spec/compiled/`.
   - Nothing writes into `docs/spec/compiled/` except compile.
3. **The review runs on the draft.** Prompt 0's review step follows Prompt A Phases 1 and 2 on the
   draft. It writes the findings with `review-findings.sh` (t-0082), keyed by the draft's version.
   The Skip tier still writes an empty findings file.
4. **One compile tool.** `.claude/tools/spec-compile.sh`:
   - `check <version>` exits 0 only when the draft can be compiled. Otherwise it exits 1 and prints
     one line per problem, each starting with a code a front end can show:
     - `DRAFT_MISSING`: there is no draft directory.
     - `VERSION_EXISTS`: the version is already compiled, or listed in `manifest.json`.
     - `TBD_UNRESOLVED`: a `[TBD]` remains outside an HTML comment, given as file:line.
     - `ASSUMPTIONS_NOT_EMPTY`: the "Assumptions: NONE" section of `boundaries.md` has text, or
       the section is missing.
     - `FINDINGS_UNRESOLVED`: `review-findings.sh check` does not pass.
   - `compile <version>` runs the same check. It then:
     - copies the draft to `docs/spec/compiled/<version>/`;
     - adds the version entry to `manifest.json` and sets `active`. The entry has `version`,
       `created`, `templateCommit`, `specFiles` and `featureFiles`, the fields Prompt 0 used to
       write by hand;
     - runs `spec-digest.sh` (advisory, Decision 0035);
     - removes the draft.

     If the copy or the manifest update fails, it removes what it wrote, so a refused or failed
     compile changes nothing.

   Prompt 0 asks for "Spec complete" only after `check` passes. The question names the plan, so the
   approval hook records it.
5. **Evidence and handoff.** The governance phase writes `spec-compiled` and also
   `advisory-reviewed`, which has `review_tier`, `mode: spec-review` and `findings:`. A spec session
   has run the review, so its handoff is Prompt T, the build. Prompt A Initialize remains for:
   - a deliberate re-review;
   - a spec compiled before this decision.
6. **What a spec session may commit** (`_close_commit_allowed`, t-0069). Besides what it allowed
   before, it may commit:
   - `docs/ai/governance/advisory-reviewed`;
   - `docs/spec/drafts/**`, including deletions. Compile removes a draft that may have been
     committed earlier, for example by an operator saving drafts in Massimo.

   A deletion anywhere else is still out of scope.
7. **No findings check in the commit hook.** The Pragmatist judged a second check redundant: the
   compile tool already refuses unresolved findings, and the `spec-compiled` evidence gate stays the
   commit-time control. A session that writes the manifest and evidence by hand bypasses the tool.
   That is the same trust the evidence gate has always placed in the agent.
8. **Why a separate compile phase.** Folding compile into governance would give the same
   commit-time guarantee. However, Massimo's spec-builder run header lists the Repo OS phases from
   `get_phases_for_type`, and Massimo has a distinct Compiling stage. The phase is what Massimo
   observes.

## Known limits

- **A paused interview cannot commit its draft.** A spec session still commits only at close, on
  `spec-compiled` evidence. A draft left mid-interview stays uncommitted on the session's branch, as
  before. Progress events for the spec builder are request R9, later.
- **Prompt T still writes feature briefs into `docs/spec/compiled/{active}/features/`.** That
  is a write into a compiled version. It is outside this decision and unchanged.
- **The `[TBD]` scan skips HTML comments only.** A `[TBD]` inside a code fence still blocks.
- **Findings keep their draft paths.** A finding's `spec_file` names `docs/spec/drafts/v{n}/…`,
  and compile removes that directory. A reader maps it to `docs/spec/compiled/v{n}/`, with the same
  file under the same version.
- **Compile does not edit the draft.** `check` passes before approval, so a refusal at compile
  means something changed since. A fix that needs a draft edit is a new spec-update session.
