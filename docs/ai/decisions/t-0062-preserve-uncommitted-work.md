# Decision t-0062 — A dying session's uncommitted work is patched, not committed, before its worktree is removed

**Status:** Accepted
**Date:** 2026-10-22
**Amends:** the worktree-removal behaviour of `.claude/.automation/runner.sh`. No hook, gate
or queue-schema change.

## Triggers

- type: file
- path: `\.claude/\.automation/runner\.sh`
- path: `\.claude/\.automation/lib/work-preserver\.sh`
- keywords: `uncommitted work, review:dirty-noop, worktree remove, preserved patch, work preserver, force-halt, runner crash`

## Context

On 2026-10-21 a brief ran 80 minutes, exhausted its turn budget and ended
`review:dirty-noop` — the outcome whose whole purpose is to say "there is uncommitted work,
send it to an operator". The runner then ran `git worktree remove --force` on the tree. Four
modified files were destroyed, and the entry sat in `review/` inviting an operator to inspect
something that no longer existed.

There were three removal sites, all bare: the post-session path in `_run_single_entry`, the
`FORCE-HALT` handler, and `_runner_crash_cleanup`. Every one of them is a place where
uncommitted work is exactly what is most likely to exist.

Keeping the worktree is not the answer. Keeping them is what wedged the `task-details-header`
group: a retained tree blocks the next session and needs a human to clear it.

## Decision

**Capture, then remove.** Before any per-session worktree is removed, the runner writes a
patch of its working tree under `.claude/.automation/reports/` and records the path in the
queue entry's `error_log`. The worktree is then removed exactly as before.

All removals of a **per-session** worktree go through one function,
`remove_session_worktree` in `lib/work-preserver.sh`. A bare `git worktree remove --force`
of the session worktree in `runner.sh` is a regression; `tests/test-work-preserver.sh` greps
for it. Task-group worktrees are out of scope: they are removed by `remove_group_worktree`
(`hooks/_cleanup-helper.sh`) only after the group's branch is sealed or by the stale sweep,
never at the end of a brief (`Decision t-0054`).

### Patch, not commit

The brief offered two options: commit the work to the session branch, or patch it. Patch.

- **A commit would have to bypass or satisfy the pre-commit gates (A1–A6).** The work in
  question is, by definition, work that never reached the commit phase: no Critic, no QA
  verdict, no session log, often no passing tests. Committing it with `--no-verify` defeats
  the gates; committing it with the gates on fails, which is the likely result. Either way the
  safety net depends on the thing that just failed.
- **A commit puts unreviewed work into history that gets merged.** Solo mode and task-group
  sealing merge the session branch. A "preserved" commit on that branch is one `queue-cli.sh
  approve` away from `main`. A patch cannot be merged by accident; applying it is a
  deliberate act.
- **A patch survives what a branch does not.** Branches are sealed, pruned
  (`Decision t-0045`) and, in group flows, reset. A file under `reports/` is outside all of
  that and is reaped only by the documented `report_days` retention.
- **A patch is independently verifiable.** It is built so `git apply --check` succeeds
  against the baseline, and the test suite asserts that it does.

The cost is that a patch is inert: nothing in the toolchain looks at it. That is addressed
by making it discoverable (below) rather than by committing it.

### What the patch contains

Built from a **throwaway index**: `GIT_INDEX_FILE=<tmp>`, `git read-tree HEAD`,
`git add -A`, `git diff --cached --binary HEAD`.

- `git diff HEAD` alone omits untracked files, and a session's new test file is exactly the
  untracked file. Staging into a scratch index captures them, plus deletions and binaries.
- The worktree's real index is untouched, so the capture cannot disturb anything.
- `.gitignore` is honoured, so build output and state directories stay out.
- A `#`-prefixed header precedes the first `diff --git` line. `git apply` ignores it, so the
  file is both a record (entry, outcome, branch, base sha, time, `git status --short`) and a
  usable patch.

### When it captures

When **both** hold: no commits since the baseline sha, and `git status --short` is non-empty.

- A session that committed keeps its work on its branch — nothing is lost, so nothing is
  captured.
- A clean tree has nothing to keep.
- There is **no outcome-string gate**. `outcome-detector.sh`'s dirty check uses
  `git diff --name-only` and ignores untracked files, so a session that left only new files
  classifies as `completed:clean-noop`. Gating on `review:*` would silently drop precisely
  the work the untracked-file requirement exists to save. *(Clarification 2026-10-25: true
  when written; since known-issue R34 the dirty check counts untracked files and such a
  session is `review:dirty-noop`. The rule stands for the reason it shows — the classifier
  can be wrong, so preservation keys on git, not on the outcome string.)* The two conditions above already
  prevent a snapshot on every exit.
- If the baseline is missing or cannot be resolved, it captures. Preserving something
  redundant is cheaper than losing something.

Covered paths: the normal post-session path (`review:dirty-noop` and every other outcome),
`_runner_crash_cleanup`, and the `FORCE-HALT` handler. A kept task-group worktree is
snapshotted on the normal exit path only; crash cleanup and the FORCE-HALT handler leave it
in place untouched. Since the in-session watcher kills the child, a force-halted session
usually reaches the normal exit path and is recorded there; the handler's own capture is
the fallback for a halt that arrives with a live worktree.

### Where it is recorded

- `error_log` of the queue entry, via `preserved_work_note`. `queue-cli.sh show <id>` prints
  it, including under `--json`. **Every** outcome transition carries the note, not just the
  review-bound ones: `queue_complete`, `queue_escalate` and `queue_incomplete` take an
  optional note, and the `queue_fail` / `queue_fail_terminal` reasons have it appended.
  This is required, not tidiness: untracked-only work classifies as `completed:clean-noop`,
  and an entry that goes to `completed/` with an empty `error_log` would be a patch nobody
  can find. *(Clarification 2026-10-25: true when written; since known-issue R34 the
  classifier counts untracked files and such a session is `review:dirty-noop`. The rule —
  every transition carries the note — is unchanged.)* With nothing preserved, `error_log` is byte-identical to before.
- The note never contains `|`. `queue-cli.sh review` reads `queue-reporter.sh`'s
  pipe-delimited rows with `IFS='|'`; a `|` in `error_log` truncates it and shifts
  `work_order_id`. The note is joined to the outcome with `; `.
- The FORCE-HALT handler's own escalation `context`, on the fallback path where that
  handler writes one.
- `reopen-entry` clears `error_log`, but the patch stays in `reports/` and is named by entry
  id.

### Deliberately not done

- **No escalation YAML is written for the preserved work.** `detect_outcome` counts every
  escalation file for an entry id regardless of `resolved`; one written here would make a
  reopened retry classify as `review:escalation`.
- **Capture never fails the close.** Every step is guarded; an unwritable `reports/`, a failed
  `mktemp` or a failed diff warns on stderr and returns 0. Removal proceeds regardless. This
  trades "the tree is never removed unless its work is saved" for "the close always
  completes": the brief required the removal not be blocked, and a full disk should degrade a
  reviewable failure into a warning, not into a wedged daemon. The loss is announced, not
  silent.
- **The classification gap is not fixed here.** `detect_outcome` ignoring untracked files is
  a separate defect (see `known-issues.md`). This decision makes it survivable, not correct.
  *(Clarification 2026-10-25: that defect, known-issue R34(a), is now fixed —
  `detect_outcome` counts untracked files. This decision's preservation does not depend on
  the fix and is unchanged.)*

## Retention fix

`lib/cleanup.sh` reaped only `reports/*.yaml`. A `.patch` would have accumulated forever.
Both the live sweep and the dry-run now cover `*.patch`, at the existing `report_days`
(default 90). A test asserts expired patches are reaped and fresh ones kept.

## Verification

`tests/test-work-preserver.sh` (44 cases, real git repos and worktrees under `/tmp`; never
the real repo or queue). Each case was shown to fail against the wrong implementation:

- remove-only stub (the pre-fix behaviour): every capture case fails — tracked
  modification, untracked files, deletion/binary, header, apply-check, apply-reproduces-tree,
  missing-baseline, announced-loss.
- `git stash` of the tracked changes (pre-fix `runner.sh`, `queue-manager.sh`,
  `cleanup.sh`): the queue-visibility, runner call-site and retention cases fail.
- keep-everything stub (snapshot on every exit, never remove): the worktree-removed,
  committed-session and clean-no-op cases fail.
- a `|` put back in the note (the defect the Critic found in review): the
  `queue-cli.sh review` row, work-order-spill and no-pipe cases fail.

## References

- `.claude/.automation/lib/work-preserver.sh` — capture and removal
- `.claude/.automation/runner.sh` — the three removal sites
- `.claude/.automation/docs/blocker-playbook.md` section 5 — operator procedure
- `docs/ai/decisions/t-0054-task-group-worktree-lifetime.md` — why group worktrees are kept
- `docs/ai/logs/known-issues.md` — adjacent defects found
