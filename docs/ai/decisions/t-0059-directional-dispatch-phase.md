# Decision t-0059 — Directional dispatch-phase acceptance for governance verdicts

**Status:** Accepted
**Date:** 2026-10-22
**Amends:** the verdict-capture contract in `.claude/hooks/state-writer.sh`. No session type,
phase sequence or gate definition changes.

## Triggers

- type: file
- path: `\.claude/hooks/state-writer\.sh`
- keywords: `dispatch_phase, phase_late_accepted, REPO_OS_STRICT_DISPATCH_PHASE, dispatch_phase_discrepancy, phase_mismatch`

## Context

Between 2026-10-20 and 2026-10-22 the daemon ran briefs against a gate chain that had only
recently become genuinely fail-closed (the commit/push gates were inert from 2026-02-11 to
2026-08-06; the gate repair landed 2026-09-19). Measured outcome over that window:

- **6 briefs landed, 5 stalled unrecoverably in `review/`, 1 failed.** Three of the five lost
  their work entirely — no commits, worktree removed.
- **Verdict rejections stepped up sharply:** 8 across the seven weeks from 31 August to
  12 October, then 5 on the 20th, 5 on the 21st and 7 on the 22nd.
- **Every rejection in that window was the same shape:**
  `reason=phase_mismatch agent=critic dispatch_phase=verify` or `dispatch_phase=commit`.

The mechanism: a session dispatched its Critic from `verify` or `commit` rather than `review`.
The verdict read `GATE_RESULT: APPROVED` — the work was correct and had been reviewed — but
`state-writer.sh` discarded it because the phase label did not match exactly. `diff-review-complete`
was therefore never written, A5 could never be satisfied, and the phase model has no backward
edge from `commit`. The session was permanently stuck. It escalated honestly, and its worktree
was then removed with the work inside.

One of the losses was the fix for the `HALT` race: built, tested, and approved by its own
Critic before being destroyed.

Destroying a correct verdict — and a whole session's work with it — to protect the provenance
of a phase label is the wrong trade. The check was right to exist and wrong to be fatal.

## Decision

`state-writer.sh` accepts a verdict dispatched **at or after** its expected phase, and records
the discrepancy. A verdict dispatched **before** its expected phase is still refused, as is a
verdict with no terminal `GATE_RESULT:` sentinel.

Position is compared by index in the session type's own phase sequence
(`get_phases_for_type`), so the rule follows each session type's shape rather than a hardcoded
order. For an agent with an alternation of acceptable phases (the Pragmatist's
`plan|review|build|synthesize`), the earliest acceptable position is used — "not early" is the
property being tested.

On acceptance the verdict file gains a `dispatch_phase_discrepancy:` line, an advisory is
emitted on stderr, and the event is logged as `phase_late_accepted`. The verdict is evidence;
a reader of that evidence can see it arrived out of sequence.

### Why direction matters, and is not symmetric

An early dispatch is a real integrity problem, not a sequencing slip. A Critic dispatched at
`plan`, before the code exists, would review an empty diff and return APPROVED — and the commit
gates check only that `dispatch_phase:` is **present and non-empty**, never its value. Accepting
an early verdict would therefore make A5 satisfiable without the built code ever having been
reviewed, for every session type. That hole stays closed.

Every one of the 20 observed rejections was at-or-after. The relaxation covers exactly the
observed failure and nothing more.

### Way out

`REPO_OS_STRICT_DISPATCH_PHASE=1` restores exact-match behaviour, logged through
`log_override`. This repo has produced six one-way doors in three days; this is not the seventh.

## What was considered and rejected

- **A new `mechanism-repair` session type with a lighter chain.** Approved by the operator and
  then withdrawn on review, because `hotfix` on a `hotfix/*` branch already supplies every
  element it would have added: the same phase sequence (`_phase-helper.sh`), a branch-derived
  A5 skip — `pre-commit-gates.sh` seeds `_A5_SKIP` from a branch-derived `IS_HOTFIX`
  (`CURRENT_BRANCH == hotfix/*`) and then **also** sets it when the session type's sequence
  lacks a `review` phase, which is the condition actually doing the work for `hotfix`
  regardless of branch name — and the
  `verify:build` loop. A fifth session-type literal would have to be kept correct across six or
  more call sites, and this repo already shows that cost landing — `session-close-check.sh`
  hardcodes `!= "hotfix"` rather than deriving from the sequence. **Mechanism repair runs as
  `hotfix` on a `hotfix/*` branch.** Revisit only if a documented friction appears.
- **Unconditional acceptance from any phase.** Opens the vacuous-APPROVED path above.
- **A `commit:build` loop for recoverability.** `qa-verified` is validated on session id and
  field presence, never against the content it attested to, so a backward edge from `commit` to
  `build` would let cycle-2 code commit on cycle-1 QA evidence. `commit:verify` → `verify:build`
  reaches the same recovered state while forcing re-QA. Not added here in any case: this
  decision removes the stall that motivated it.
- **Dropping blocking cohesion review for gate-chain changes.** The argument rested on "13 of
  20 rejections were Critic verdicts", which is a misreading of the same data — those 13 were
  APPROVED verdicts destroyed by this very check. The Critic was the victim, not the cost
  centre, and this decision converts all 13 into accepted verdicts at no cost.

## Consequences

- The stalled briefs become completable, **with one exception**: a Critic's `EXPECTED_PHASE` is
  hardcoded `review`, and `taskgroup-merge` sequences `cohesion` instead of `review`, so a
  Critic verdict in a merge brief is refused from every phase — before and after this change.
  That is pre-existing and not a regression, but this decision does not unstick a merge brief.
  All 20 historical rejections of this shape would
  have been accepted.
- A5's guarantee weakens slightly in a stated way: a verdict may now attest to a diff reviewed
  at or after the expected point rather than exactly at it. The `dispatch_phase_discrepancy:`
  line makes that visible in the evidence rather than silent.
- Dispatching review agents from their own phase remains correct practice. This is a safety
  net, not a licence, and the advisory says so.

## Verification

`layer3-hook-integration.sh` gains six cases: a precondition pinning the phase ahead of
`review`; acceptance of a late dispatch; the discrepancy line naming the actual phases;
`GATE_RESULT:` not displaced by it; early dispatch still refused; and the override restoring
strict rejection. **281/281** in that suite, all 10 hook layers green, all 7 functional
automation suites green.

**Fail-first:** three of the six cases go red against the unmodified hook — the acceptance case
and the two discrepancy-recording cases — reproduced across three independent runs by swapping
`git show HEAD:.claude/hooks/state-writer.sh` over the live file. An earlier draft of this
record claimed only two, attributing the acceptance case's apparent pass to dispatch-record
carry-over between cases. That was wrong twice: the harness records no dispatch phase at all on
this path (the advisory confirms it: "no dispatch record; current phase used"), and the
acceptance case is genuinely fail-first. The real source of cross-case flakiness in that
harness is a separate defect — `_phase-helper.sh` iterates `for p in $phases` without declaring
`p` local in three places, so `advance_phase` clobbers any caller's loop variable of that name.
Worth its own fix; the code added here is immune, localising its own loop variable.

The acceptance behaviour is additionally evidenced by advisory count: zero
`ADVISORY: verdict from critic` lines against the unmodified hook, one with the change.

### Verified fail-closed vectors

Eleven probes drove the real hook through the test seam, walking each session type's own
sequence: a phase absent from the sequence rejects (`hotfix` has no `review`;
`taskgroup-merge` uses `cohesion`); an unknown session type rejects (empty sequence → no
indices); a **non-monotonic** sequence classifies correctly, which is the sharpest case —
`editor-live` orders `commit` before `review`, so a Critic from `commit` is EARLY there and is
refused; the Pragmatist's alternation resolves to its earliest member, with `plan` accepted and
`drift-check` refused; and an empty `VALIDATE_PHASE` never reaches this logic, because
`EXPECTED_PHASE` is only assigned inside `if [ -n "$VALIDATE_PHASE" ]` — such a verdict is
written with an empty `dispatch_phase:` and then refused downstream by the commit gate as "not
produced by a real agent dispatch".

Two widenings are accepted consciously: a Critic verdict is now acceptable from `close`, and a
Pragmatist verdict from any phase at or after `plan`.

## References

- `.claude/hooks/state-writer.sh` — `_phase_index`, directional acceptance block
- `.claude/hooks/_phase-helper.sh` — `get_phases_for_type`
- `.claude/hooks/pre-commit-gates.sh` — `IS_HOTFIX`, A5 skip, `dispatch_phase:` presence checks
- `docs/ai/logs/known-issues.md` — R25-R30, the one-way doors of this period
