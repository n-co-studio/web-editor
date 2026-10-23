# Decision t-0056 — Shared Files Are a Signal; Re-verify Before Merge

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/\.automation/lib/(overlap-report|reverify-merge)\.sh`
- path: `\.claude/\.automation/runner\.sh`
- path: `\.claude/\.automation/queue-cli\.sh`
- keywords: `shared files, overlap report, overlap_report_build, overlap_report_main_changed, conflict_likely, main_changed, _reverify_before_merge, _solo_merge_if_needed, reverify-failed, reverify_timeout_seconds, re-verify before merge`

## Context

A brief is verified on its own branch, against main as it was when the branch
started. `_solo_merge_if_needed()` then merges at close — `--ff-only` first,
`--no-ff` as a fallback — and re-verifies nothing. The merge lock (Decision
0030) puts concurrent closes in a line but does not look at what it is merging.
Nothing checked files *across* open branches at all: session overlap (Decision
0013) is per-branch and advisory for task groups, and a parallel group's
`Boundaries:` are only planned at Prompt T.

Two branches touching the same file therefore play out three ways:

1. **Clean merge, works.** The common case. Nothing to do.
2. **Textual conflict.** Already caught — the runner writes an `esc-merge-*`
   escalation and sets `review:merge-conflict`.
3. **Clean merge, broken behaviour.** Git checked that the hunks do not
   collide, nothing checked that the combination works, and the combination was
   never verified by anyone. This is the gap.

Case 3 is not hypothetical arithmetic: a clean textual merge of two
independently-verified branches produces a tree that neither branch's
verification ran against.

## Decision

### 1. Shared files are advisory

The overlap report (`lib/overlap-report.sh`, surfaced by `queue-cli.sh
overlap`) is a read-only signal. The mere presence of overlap **never** changes
a queue entry's status, order, or eligibility to run. It takes no lock, writes
no state, and never touches main's working tree, index or HEAD — Massimo polls
it every few seconds, and a polling command that mutates state or contends on
the queue lock would be unsafe.

### 2. Status changes only on events

An entry's status changes when something *happens*, never because overlap
exists:

| Event | Status |
|-------|--------|
| Rebase or merge conflicts at close | `review:merge-conflict` (+ `esc-merge-*`) |
| Close-time re-verification does not pass | `review:reverify-failed` (+ `esc-reverify-*`) |

These are two different outcomes, and a rebase conflict is the *first* one — it
routes to `review:merge-conflict`, the path that already existed, not to
`review:reverify-failed`. The queue entry's `reverified` field does not
distinguish them: it reads `false` for a rebase conflict, a failed check set
and a timeout alike, because its question is "did this branch merge on
unverified evidence" and the answer is no in all three. The entry's `outcome`
is what says which happened, and the escalation id (`esc-merge-*` versus
`esc-reverify-*`) says it too.

On `review:reverify-failed` the branch is **not merged and not sealed**: it has
to stay open for the fix and the retry, and main must not receive code that
failed its own checks. The branch is also deliberately left *rebased* — the
thing that failed is the rebased code, so that is what the operator must be
able to reproduce. The pre-rebase SHA is recorded in the escalation instead;
resetting the ref back would both hide the failure and be a destructive ref
move.

### 3. Three overlap states shown to the operator

| State | Meaning |
|-------|---------|
| `shared` | Both branches changed this file since their merge-base with main |
| `conflict_likely` | A trial merge of the two branches conflicts on it |
| `main_changed` | Main changed this branch's file *after* the branch started |

`conflict_likely` takes precedence over `shared` for the same path. These three
names are the overlap report's output vocabulary, in both the text and JSON
renders. Massimo's shared-files indicator (Figma: SC / Shared files badge) is
the intended consumer and is not built yet, so nothing depends on them today —
but they are the names it is being designed against, and that is the reason to
settle them here rather than leave them to the first consumer.

Conflict prediction has two interchangeable implementations — `git merge-tree
--write-tree` (git >= 2.38) and a scratch-worktree trial merge — chosen by
capability probe. Both must exist and must agree: the operator machine runs git
2.56 but `.claude/.automation/Dockerfile` is `ubuntu:22.04` (git 2.34.1), where
a merge-tree-only implementation would silently report no conflicts.

### 4. Re-verify only when main changed the branch's files

`_reverify_before_merge()` runs inside `_solo_merge_if_needed()` and does
nothing unless main changed at least one file this branch also changed, since
their merge-base. With no such overlap the merge path is byte-for-byte the one
that shipped before, which is what keeps the common case fast.

There is deliberately **no separate fast-forward probe**. A branch that can
fast-forward has no commits on main since its merge-base, so the intersection
is necessarily empty — a second trigger that can only ever agree with the first
is a second thing to keep in step.

The gate is fail-closed. A re-verification that cannot be computed — no
merge-base, no scratch worktree, a dirty tree, a crash, a timeout, no verdict,
or both verdict sentinels — is a failure, not a pass. A verification gate that
passes on "no answer" is not a gate.

**Re-verification runs as a minimal headless session, because no non-agent
entry point exists.** Verification lives in exactly two places today, both
inside an agent session: the `qa-verifier` subagent dispatched at the `verify`
phase, and gates A1–A6 in `pre-commit-gates.sh` at commit. There was nothing
for this gate to reuse, so `lib/reverify-merge.sh` launches a read-only
`claude -p` session over the rebased tree under the `audit` permission profile,
bounded by `runner.reverify_timeout_seconds` (default 900) and routed on the
existing `taskgroup-merge` model key. It reports exactly one whole-line
sentinel, `REVERIFY-RESULT: PASS` or `REVERIFY-RESULT: FAIL`.

### 5. Where the merge lock is held, it covers rebase, re-verify and merge

On the worktree merge path (Decision 0030) the caller holds
`.claude/.state/.merge-lock` across the whole rebase → re-verify → merge
sequence. Anything narrower makes the gate pointless: another close could land
on main between the verdict and the merge, and the thing that was verified
would not be the thing that was merged. The lock is therefore never released
between the verdict and the merge it authorises.

The hold is consequently as long as a verification session, so
`reverify_timeout_seconds` also bounds how long another close can wait. A hold
exceeding that budget is reported by the *holder*, not the waiter: the holder is
the only party that knows how long it blocked others.

**The legacy `git checkout main` path holds no merge lock at all.** That is
pre-existing (RUNNER-PARITY row 5) and is not changed here, so this rule
enlarges a lock scope on the path that has one rather than introducing a lock
on the path that does not. Both paths run the re-verification gate, so they
cannot disagree about whether a branch is safe to merge; they differ only in
whether a concurrent close can interleave. Closing that gap is a separate
change to the legacy path's locking, not to this gate.

### 6. Out of scope

- **Automatic conflict resolution.** Conflicts are escalated for a human.
- **Re-ordering the queue by overlap.** Overlap does not change execution order.
- **Blocking work at Prompt T because of overlap with other open work.** A
  brief is never refused for touching a file another open branch touches.

## Consequences

- `.claude/.automation/lib/overlap-report.sh` is new — `overlap_report_build`,
  `overlap_report_text`, `overlap_report_json`, plus the stateless
  single-branch helpers `overlap_report_main_changed` and
  `overlap_report_main_commit`. Module-private names are prefixed `_or_` /
  `_OR_`. It is a sourced library, never executed standalone
- `.claude/.automation/queue-cli.sh` gains the `overlap` subcommand
- `.claude/.automation/lib/reverify-merge.sh` is new —
  `_reverify_before_merge()` returning 0 (merge as today), 1 (rebase
  conflicted), 2 (re-verification did not pass). It lives in its own sourceable
  lib rather than in `runner.sh`, which has top-level execution and so cannot
  be sourced by a test suite
- `.claude/.automation/runner.sh` calls the gate from both merge paths —
  worktree (Decision 0030), where it runs inside the merge lock, and the legacy
  `git checkout main` path, which holds no lock — and adds
  `review:reverify-failed` as a third close outcome alongside merge-ok and
  merge-conflict
- `.claude/.automation/schemas/queue-entry.yaml` gains `reverified`
  (`""` = did not run, `true`, `false`) and `overlap_files`;
  `schemas/runner-config.yaml` and `config.yaml` gain
  `runner.reverify_timeout_seconds`
- A new escalation id convention, `esc-reverify-*`, under the existing
  `gate-failure` type — naming the failing checks, the overlapping files, the
  main commit that changed them and the pre-rebase SHA. No schema enum change
- `.claude/.automation/tests/test-overlap-report.sh` and
  `tests/test-reverify-merge.sh` are new, both registered in
  `run-automation-tests.sh`
- `docs/ai/workflow-appendix/session-type-task-group.md` records that a final
  brief's merge is gated by close-time re-verification

## Override

There is no override that disables the re-verification gate — a branch whose
combined result failed its own checks must not reach main unattended. The
adjustable surfaces are `runner.reverify_timeout_seconds` (the wall-clock cap;
a timeout is a failure, never a pass) and
`REPO_OS_OVERLAP_NO_MERGE_TREE=1`, which forces the overlap report's
trial-merge path so the two conflict-prediction implementations can be compared
on one machine.

## Falsification Signals

Revisit this decision if any of these happen:

- `esc-reverify-*` escalations are routinely cleared as false alarms — the gate
  is reporting pre-existing branch failures as merge failures.
- Re-verification fires on most closes rather than a minority — the overlap
  trigger is not the narrow filter it was chosen to be, and the common path is
  no longer fast.
- Merge-lock hold warnings become routine — serialising a verification session
  inside the lock is costing more queue throughput than the gate is worth, and
  the rebase/verify/merge sequence needs a different concurrency design.
- `conflict_likely` and the actual rebase outcome disagree often — the two
  conflict-prediction paths, or the prediction itself, are not load-bearing.

## Amends

Nothing. Decision 0013 (session branch isolation and sealing), Decision 0015
(solo mode), Decision 0030 (worktree session isolation, merge coordination, the
ref-move invariant) and Decision 0054 (task group worktree lifetime) remain
binding and unchanged. This decision adds a gate inside the merge step those
decisions already describe; it does not change who merges, who seals, or when.
