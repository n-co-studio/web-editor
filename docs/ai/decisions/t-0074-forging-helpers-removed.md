# Decision t-0074 — The helpers that wrote gate evidence are gone

**Status:** Accepted
**Date:** 2026-11-19
**Amends:** Decision t-0033 §8 and t-0014's preservation note (withdraws `_headless-plan-approve.sh`);
t-0073 §2 (the helper's name stays reserved). Closes known-issues R53 and R57.
`.claude/hooks/_headless-state-write.sh`, `.claude/hooks/_headless-plan-approve.sh` (deleted),
`.claude/tools/verify-pristine.sh`.

## Triggers

- type: file
- path: `\.claude/hooks/_headless-state-write\.sh`
- keywords: `_headless_write_state, forging helper, verify-pristine counter`

## Context

The operator chose to replace t-0073's text-based guard with an OS-level boundary (Claude Code's
Bash sandbox, hooks outside it). Mapping every writer of gate evidence for that step found
`_headless-state-write.sh`: sourcing it and calling `_headless_write_state qa-verified` wrote
`GATE_RESULT: APPROVED` into any named verdict file. The command text names no state path, and
bash-guard did not know the helper, so a forged `qa-verified`, `reviewer-signed` or
`security-signed` passed the commit gate (R57). Its sibling `_headless-plan-approve.sh` wrote
`plan-approved`; t-0073 refused it by name. Neither has a caller in code, prompts, tests or the
headless allowlist.

Separately, `verify-pristine.sh` counted TAP results only at the start of a line, so a result
behind a hook's unterminated stderr was lost (R53).

## Decision

1. **Both helpers are deleted** and withdrawn from the machinery manifest; template sync removes
   withdrawn entries from child repos (t-0051). Deleting beats guarding: nothing consumes them
   (Pragmatist).
2. **The approval helper's name stays reserved.** bash-guard's t-0073 refusal is kept, so a
   re-created copy under that name is still refused. To be reconsidered with the sandbox step.
3. **verify-pristine counts the TAP shape, not line starts.** A numbered result `[not ]ok N - `
   counts anywhere on a line, so a result glued to unterminated stderr counts
   (`deniednot ok 2 - `); an unnumbered `[not ]ok - ` counts only at line start or after a
   non-word character, so `look - ` and `book - ` do not. Prose such as "looks ok here" never
   counts. (QA caught the first version counting `look - ` as a pass.)

## Known limits

- The class is not closed: any sourced function or interpreter can still write the same lines
  (R2). Only the sandbox boundary closes it.
- `_is_prewritten_evidence` still accepts `question_hash: headless-runner`, the deleted helper's
  marker (it lets that `plan-approved` survive a first init). It has no writer now; it is removed
  with the sandbox step, where `plan-approved` writing is redesigned.
- A numbered result is not left-anchored (that is the R53 case), so a word ending in `ok` before
  a number and ` - ` (`took 5 - `) counts as a pass. An unnumbered failure glued to a word
  (`warnnot ok - `) reads as a **pass** — the pattern matches the ` ok - ` after the space
  (Reviewer). No suite prints unnumbered results after stderr, and a suite that fails this way
  and exits non-zero is still counted as a failure.
- A `not ok` line without the ` - ` separator is no longer counted (the old counter caught it). No
  suite prints that form; a suite doing so that also exits 0 would read as clean. A non-zero exit
  is still counted as a failure.
- Evidence files written before this record counts only, so they cannot be re-counted; their
  numbers are a floor.
