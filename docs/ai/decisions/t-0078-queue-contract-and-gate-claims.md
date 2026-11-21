# Decision t-0078 — A queue run commits against its contract; a commit may not claim A6 ran when it did not

**Status:** Accepted
**Date:** 2026-11-20
**Amends:** Decision t-0077 §3 (decides the deferred question) and its Context (the gate it named).
`.claude/hooks/pre-commit-gates.sh`, the brief templates and `prompt-assembler.sh`'s trailer guidance.

## Triggers

- type: file
- path: `\.claude/hooks/pre-commit-gates\.sh`
- keywords: `scope_contract_missing, A6_claim_not_run, REPO_OS_AUTOMATION_ENTRY, Gates-A`

## Context

Checking t-0077 in the web-editor child (queue entry f12fd2d3, 2026-11-20) proved the carve-out: the
mode guard logged `pass_child` for the contract write. It also turned up two problems.

- **The wrong gate was named.** t-0077 and R62 said "the A6 scope gate". A6 checks only task-group
  contracts. A standard session's `.claude/local/task-contract.yaml` is read by the commit gate's
  scope check and by A5's contract scoring (t-0071), and both skip when the file is absent. A queue
  run that never writes its contract therefore commits with neither check, and nothing says so.
- **Gate trailers are self-reported.** No hook reads `Gates-A`. The child run's agent wrote
  `A6-pass` for a standard session, where A6 never runs; the brief templates' `A6-<result>`
  placeholder invited it, and this template's own commits in the same session did the same.

## Decision

1. **A queue run's standard session must have a scoped contract.** In the scope check, when
   `REPO_OS_AUTOMATION_ENTRY` is set (`runner.sh` exports it for queue runs) and `CLAUDE_HEADLESS=1`,
   the session type is `standard` and the phase is not `close`, a commit is blocked GATE-RECOVERABLE
   (`scope_contract_missing`) if the contract is missing or lists no `scope_files`. Interactive
   sessions, other session types, experiment branches and `REPO_OS_RECOVER` are unchanged.
2. **`A6-pass` outside a task group is refused.** In the A6 block, a commit whose `Gates-A` trailer
   contains `A6-pass` in a session that is not `taskgroup`/`taskgroup-merge` is blocked
   GATE-RECOVERABLE (`A6_claim_not_run`): write `A6-n/a`. A6 is the one entry whose run/no-run the
   hook can settle from the session type alone. The check reads the whole `Gates-A:` line, not
   `extract_trailer`, which stops at the first letter `n` (R64) and so hid `A6-pass` behind `A3-n/a`.
3. **The guidance says so.** `build-brief.md`, `finish-loop-brief.md`, `prompt-f-finish-loop.md` and
   `prompt-assembler.sh` now show `A6-n/a` outside task groups and state the rule.

## Known limits

- **The rest of `Gates-A` is still the agent's own record.** A1–A5 entries are not checked against
  what ran; verifying them would need the hook to record per-gate outcomes, which this decision does
  not build (Pragmatist). Read them as claims; the hook's analytics events are the evidence.
- **The A6 check is a backstop, not proof.** It matches `A6-pass` on a line that also has `Gates-A:`.
  `A6-PASS`, or an `A6-pass` on a line of its own, is not seen (Security). Prose quoting such a
  trailer is blocked, recoverably. The fix that matters is the guidance in Decision 3.
- **The contract is still the agent's file.** A queue run can write a contract that covers whatever
  it changed; headless runs carry no `contract_sha` binding (R58). The block makes the check run, not
  the contract honest.
- **Keyed on environment the runner sets.** A queue run started some other way, without
  `REPO_OS_AUTOMATION_ENTRY`, is treated as interactive.
