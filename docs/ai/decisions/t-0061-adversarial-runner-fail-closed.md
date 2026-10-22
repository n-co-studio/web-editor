# Decision t-0061 — The adversarial runner fails closed on unknown severity

**Status:** Accepted
**Date:** 2026-10-22
**Amends:** the gating policy of `.claude/.automation/tests/test-runner.sh`. No suite,
hook or gate definition changes.

## Triggers

- type: file
- path: `\.claude/\.automation/tests/test-runner\.sh`
- keywords: `adversarial runner, severity gating, TOTAL_MEDIUM, untagged failure, fail closed`

## Context

The runner tagged failures `[CRITICAL]`, `[HIGH]`, `[MEDIUM]`, `[LOW]`, sent anything
untagged to MEDIUM via its `*)` default, and exited non-zero only on CRITICAL or HIGH.
So a failure it could not classify could not fail the run — fail-open on precisely the
case it understands least.

Measured, not theorised. The `SETUP: could not reach phase` failures added under R32,
which report that an adversarial case never ran, carried no severity tag. Forcing them
produced **14 such failures, the line "RESULT: 14 governance bypass(es) found", and
exit 0**. A runner that prints "bypasses found" and reports success is incoherent on its
own terms.

MEDIUM not gating was never a considered policy either. It tags real correctness checks
in these suites — queue lock starvation, transition without a lock, JSON injection into
the queue index, YAML duplicate-field override — and was non-blocking only as a side
effect of sharing a tier with the untagged default.

## Decision

The runner exits non-zero on **CRITICAL, HIGH, MEDIUM, or any failure whose severity
cannot be determined**. Only an explicitly `[LOW]`-tagged failure is advisory.

An unclassifiable failure counts as CRITICAL rather than MEDIUM. `SETUP:` failures are
additionally tagged `[CRITICAL]` at the source, so the behaviour is stated rather than
inherited from a default.

## Why this was safe to land now

All five suites were at 0 failures of every severity when the change was made, so
tightening turned nothing red. Tightening a gate while it is green is the cheap moment;
doing it later means arguing about an existing failure at the same time.

## Verification

Mutation-tested in both directions: `_reach` forced to fail produces 14 untagged SETUP
failures and the runner now exits **1** (it exited 0 before); the unmutated tree exits
**0** with 62/62. The suites, hooks and files under test were restored byte-identically
after each probe.

## References

- `.claude/.automation/tests/test-runner.sh` — severity parse and exit gate
- `.claude/.automation/tests/sandbox-setup.sh` — `_setup_at`, which emits the SETUP failures
- `docs/ai/decisions/t-0049-gate-exit-contract.md` — hook exit-code contract
- `docs/ai/logs/known-issues.md` — R32, the suite repair that surfaced this
