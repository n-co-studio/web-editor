# Decision t-0057 — The Close Is a Pipeline With Controls

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/\.automation/runner\.sh`
- path: `\.claude/\.automation/queue-cli\.sh`
- path: `\.claude/\.automation/lib/(queue-manager|reverify-merge|pr-manager)\.sh`
- path: `\.claude/\.automation/schemas/queue-entry\.yaml`
- path: `\.claude/\.automation/templates/pr-body\.md`
- keywords: `close_state, close_path, close_steps, merge_hold, queue_close_record, queue_close_state, queue_close_path, queue_close_merge_allowed, queue_set_close_path, queue_set_merge_hold, queue_set_pr, queue_is_final_taskgroup_entry, _close_record, _close_merge_held, _close_entry_close_path, --close-entry, hold-merge, set-close, close-status, close pipeline, pr_open, pr_refresh, pr_rerun, pr_update_branch, pr_merge, pr_gh_available, _pr_poll_sweep, pr.merge_method, pr.poll_seconds, pr.delete_branch, gh pr create, gh pr view, resolve-conflict, conflict_resolution, queue_conflict_resolve_allowed, queue_set_conflict_resolution, queue_close_rearm, _reverify_take_conflict_strategy`

## Context

A queue entry that finishes its checks has exactly one thing left to do and no
way to say so. `_solo_merge_if_needed()` runs rebase, close-time
re-verification (Decision t-0056), merge, push and seal in one unbroken stretch
inside the daemon loop, and the only trace it leaves on the entry is the final
`status` plus `reverified` and `overlap_files`. Three consequences follow.

**Nothing can report where the close is.** `completed` means merged on the solo
path and means nothing in particular otherwise. An entry that failed
re-verification, an entry that hit a rebase conflict, and an entry that merged
cleanly are all distinguishable only by hunting for an escalation file. A
pipeline view has nothing to render.

**The operator cannot intervene.** The merge happens at whatever moment the
daemon reaches it. There is no way to say "verified, but not yet" — to let a
release window close, or to look at a diff first — and no way to say "merge it
now" for an entry the runner left alone. The only available controls are
stopping the session (t-0055), which is far too blunt, and `solo_mode`, which
is set at intake and read once.

**The route is decided at intake and cannot be changed.** `solo_mode` picks
between merging directly and leaving the branch for a pull request, before
anyone has seen the work.

What is NOT in scope: the PR half of the route. `close_path: pr` is defined and
refused here; the commands that open and land a pull request are brief 2.

## Decision

### 1. The close has a state, and it is recorded, not inferred

Every entry carries `close_state`. Twelve values: `waiting`, `ready`, `held`,
`rebasing`, `reverifying`, `merging`, `pushed`, `pr_open`, `merged`,
`conflict`, `reverify_failed`, `handed_off`. Every transition of the solo path
writes the state as it happens, so what a report shows is where the pipeline
actually got to rather than a reader's reconstruction of it.

There is **one** derivation site, and it exists only for entries written before
this decision: `queue_close_state` maps a stored-empty field from `status`
(`completed` → `merged` on the solo path, `ready` otherwise; everything else →
`waiting`). Nothing else in the codebase performs that mapping. Old entries
load and report sensibly with no migration, and a wrong mapping has one place
to be fixed.

`close_state` and `close_steps` are derived state in the same sense `held_by`
is, and are absent from `queue_edit`'s allowlist for the same reason. Operator
intent gets its own subcommand.

### 2. `close_steps` is a rendered record, never a parsed one

Each transition appends one row — `{"step","status","at","detail"}` — to
`close_steps`. `step` is a lowercase word or hyphenated pair (`rebase`,
`reverify`, `merge`, `push`, `commit`, `contract`, `push-branch`, `open-pr`,
`checks`, `merge-pr`, `resolve`); `status` is `running | done | failed |
skipped`.

It is stored as a single-line flow sequence that is simultaneously valid YAML
and valid JSON — YAML 1.2 being a JSON superset — rendered once by
`queue_close_step_json` and round-tripped verbatim by the entry parser, exactly
as `overlap_files` already is. Nothing reads it back as structure. A `detail`
carrying newlines, tabs or double quotes is folded and escaped at render time,
because the thing most likely to end up in a `detail` is a list of conflicted
file paths and it must not be able to break the entry file.

### 3. A hold is its own field; `held` is only how it looks

`merge_hold` is a boolean set and cleared by `hold-merge` and `hold-merge
--release`. `held` is **never** written into `close_state`;
`queue_close_state` renders it from `merge_hold`.

Two reasons, both load-bearing. A hold must be placeable before an entry is
`ready` — holding a non-final task-group brief holds the *next* brief's start —
so a state value could not express it. And `--release` must not have to restore
a `close_state` it has no record of having overwritten. One source of truth,
one rendering.

The rendering never covers a finished state. An entry already `merged`,
`pushed` or `pr_open` reports that, held or not: a hold placed after the fact
must not relabel history.

It never covers a **refusing** state either, and that half is load-bearing
rather than cosmetic. §5's merge gate admits `held` on the solo path — an
operator merging an entry they held is releasing it in the same breath — so
rendering `held` over `conflict` or `reverify_failed` would turn a hold into a
way of *passing* the gate those states exist to fail. The criterion is not "is
this state finished" but "would the gate refuse it". Nothing is hidden by the
exemption: `merge_hold` is its own field, and `close-status` and `show --json`
both print it beside the state.

### 4. `close_path` resolves from `solo_mode`, then pins

A reader with no stored `close_path` resolves `solo_mode: true` → `solo`,
`false` → `pr`. The first close transition writes the resolved value onto the
entry. So `set-close` changes where the work goes *next* and cannot
retroactively rewrite the route the work already took.

### 5. Merge is fail-closed and refuses out loud

`queue_close_merge_allowed` admits a merge only when all of:

1. `status` is `completed`;
2. `reverified` is not `false` — a failed close-time re-verification (t-0056)
   bars the merge. `""` means the gate never ran, which is not a failure;
3. no criteria verdict in the session's
   `docs/ai/governance/criteria-verdicts/<session-id>.yaml` is `PARTIAL`,
   `INCONCLUSIVE` or `FAILED`;
4. `close_state` is `ready` or `held`;
5. the entry is the final brief of its task group;
6. `close_path` is `solo`.

It prints the reason it refused on stdout and returns 1. It never guesses
(Decision t-0061). `held` is admitted on purpose: an operator who asks to merge
an entry they held is releasing the hold in the same breath, and saying so with
two commands instead of one buys nothing.

### 6. The solo close pipeline has exactly one implementation

`queue-cli.sh merge <id>` does not merge. It checks the preconditions above and
then calls `runner.sh --close-entry <id>`, a third runner mode (mutually
exclusive with `--daemon` and `--brief-id`) that runs `_solo_merge_if_needed`
for one already-completed entry. A second merge implementation in the CLI would
be a second set of rules about what may reach main.

`--close-entry` acquires the merge lock only when `is_full_worktree_session` is
false — the same predicate `_solo_merge_if_needed` uses to decide whether it
takes the lock itself. The lock is flock `-n` and **not reentrant** (Decision
0030), so taking it in both places would fail closed on every operator merge.

It records `close_state` but deliberately does **not** move an
already-`completed` entry's queue status: a rebase conflict there writes the
existing `esc-merge-*` escalation and records `conflict`, without a `completed
→ review` transition nobody asked for. It passes no group name either, because
the group worktree lock and its removal are keyed to the session that holds
them and this process holds neither.

An explicit `--close-entry` outranks `merge_hold` (`_CLOSE_ENTRY_MODE`),
without which clause 5's admission of `held` would be unreachable.

### 7. The recorder cannot change the outcome

`_close_record` returns 0 on every failure path — no entry file, library not
loaded, queue unwritable — and swallows `queue_close_record` failures. A report
on the pipeline must never be able to decide whether a branch merges.

`_close_record_reverify_pass` records `reverify done` only when
`_RESULT_REVERIFIED` is literally `true`, so a gate that never ran is never
reported as passed.

### 8. Three failure sites record `ready`, and why that is honest

A merge-lock acquisition failure, a merge that fails without a conflict, and a
branch type the solo path will not merge have no matching enum value. All three
record `ready` with the distinction in the step row's `detail`. `ready` is the
truthful answer because all three are retryable: `conflict` would refuse the
retry at clause 5, and `merging` would strand the entry in a state nothing can
leave.

### 9. A task group closes once, at its last brief

Decision 0015 §3 unchanged. An earlier brief records `close_steps` for `commit`
(to the group branch) and `contract` (the group contract), then ends at
`close_state: handed_off`. `merge`, `set-close` and the brief-2 PR commands
refuse any brief that is not final. `hold-merge` on an earlier brief holds the
next brief's start, via the existing dequeue hold machinery.

The finality predicate moved to `queue_is_final_taskgroup_entry` in
`lib/queue-manager.sh`; `runner.sh`'s `_is_final_taskgroup_entry` is now a
one-line delegation to it. The operator path needs the same predicate, and a
copy would have left the seal gate and the merge gate free to disagree about
when a group branch may reach main. Behaviour, including the fail-open default
on error, is unchanged — a group branch that never seals is worse than one
sealed early.

### 10. Out of scope

The PR route (`push-branch`, `open-pr`, `checks`, `merge-pr`, and the `gh`
preflight) is brief 2 — **landed 2026-10-23, see the amendment below.**
Conflict resolution on either path is brief 3 — **landed 2026-10-23, see the
second amendment.** Interactive sessions are untouched: the stop hook has no
queue entry to record against and no merge to defer.

## Amendment 2026-10-23 — the pull request route (brief 2)

Clause 10 deferred the PR half of `close_path`. It is now implemented. Nothing
above is weakened: clauses 1-9 govern the solo path exactly as written, and the
clauses below are additive.

### 11. `gh` is the only way out, and there is exactly one of it

Every GitHub call in the repo lives in `.claude/.automation/lib/pr-manager.sh`
and goes through one helper, `_pr_gh`, which runs `gh` in a subshell at
`REPO_ROOT`. The library is sourced by `runner.sh` (close path, daemon poll) and
by `queue-cli.sh` (the `pr` subcommands), so the runner and the operator cannot
form different opinions about what a pull request's checks say or whether it may
merge — the same reason clause 6 gives for one solo implementation.

No token is read, written or stored. `gh` holds its own credentials; Repo OS
asks it questions. A repo on a non-GitHub forge is out of scope, not degraded
into: `pr_gh_available` reports it and the entry stops.

### 12. The route fires on `push_on_complete` and finality, not on `close_path`

`close_path` already resolves to `pr` for every `solo_mode: false` entry
(clause 4), so a `close_path`-only trigger would have begun pushing branches to
origin on every existing install the moment this shipped. Reaching origin stays
an explicit per-entry decision, which is what `push_on_complete` has always
meant.

Finality is the second condition, for clause 9's reason: a group closes once,
and opening a pull request per brief would put the same partial work in front of
a reviewer three times. A non-final brief takes the plain push it took before
this route existed.

### 13. The branch is sealed as soon as the pull request opens — and again when it merges

Sealing retires a branch from **local** session use (Decision 0013).
Everything the pull request has left to do — checks, `update-branch`, the merge
— happens on origin through `gh`, and none of it needs a local session. Holding
the seal until the merge landed would also have stranded the task group
worktree, whose removal keys on the branch appearing in `closed-branches`, for
as long as the pull request stayed open.

So `record_closed_branch` runs at **two** sites, not one: the runner's close arm
calls it when the pull request opens, and `pr_land` calls it again once the
merge lands. It is idempotent, so the second is not a double-seal — and the two
are not redundant either. The early call is what frees the worktree. The late
one is where the local branch is additionally deleted
(`delete_merged_session_branch`) and, when `pr.delete_branch` is true, the
remote branch too, because only then is the work actually on `main`.

### 14. A degrade records `ready` and never fails the entry

No `gh`, no auth, no remote: the reason goes in a `close_steps` row and the
entry stops at `ready`. It is not failed — the work is finished and correct; the
publishing step is what is unavailable.

`pushed` is deliberately not reused for this. It asserts *the branch reached
origin and nothing merged it*, which is false when there is no remote at all,
and an entry claiming it would read as further along than it is. `ready` is the
retryable state and `pr open` is the retry. This is clause 8's reasoning applied
to three more sites.

### 15. The poll reports; the operator's command transitions

`_pr_poll_sweep` re-reads every `completed/` entry at `close_state: pr_open`
once per daemon iteration, rate-limited to `pr.poll_seconds` (default 120) with
the stamp taken **before** the sweep so the interval cannot drift by the `gh`
round-trip time. It runs before the dequeue rather than in the idle branch, so a
repo whose queue is never empty still notices a merge.

It does **not** move an entry to `review/`. `queue_escalate` only acts on
`running/`, and an entry whose session genuinely completed is not fixed by
re-running it. The close state and the escalation are what the operator reads;
the `pr` subcommands are where a conflict becomes a status transition. This is
clause 7 generalised: a watcher must not be able to change an outcome.

### 16. Fail-closed on GitHub's answers, including its non-answers

`pr merge` reads mergeability and check status **live**, at the moment of the
merge, never from the entry — a refusal based on a cached reading is not a gate.
Then:

- `mergeable: UNKNOWN` is **refused but never routed to conflict.** GitHub
  computes mergeability asynchronously (gh cli#9583), so `UNKNOWN` is transient,
  not negative. Clause t-0061 fail-closure demands the refusal; escalating a
  pull request that is very likely fine would be a different error.
- Check status is read from the rollup **rows**, never its aggregate, which can
  report `SUCCESS` while a row reports `FAILED` (gh cli#14253). `conclusion` is
  the empty string — not null — on an unfinished run, so unfinished is pending,
  not passing.
- No conflicting-file list is claimed. The solo path can name them because it
  runs the merge; here GitHub holds the only merge and says a conflict exists
  without saying where. The escalation says so rather than inventing a list.
- `pr_land` takes **no merge lock** and does not hand off to `runner.sh` the way
  `merge` does. The lock exists to stop two local merges racing and to keep a
  re-verification verdict valid across rebase → verify → merge (t-0056). Neither
  applies to a `--ff-only` sync of `main` after GitHub has already merged, and
  there is no second merge gate that could disagree with the runner's — GitHub
  holds the only one.

## Amendment 2026-10-23 — conflict resolution (brief 3)

Clause 10 deferred what happens after a conflict. Both close paths could reach
`close_state: conflict` and neither could leave it: the entry sat in `review/`
with an escalation naming the problem and no command that could act on it. The
clauses below close that, and are additive — nothing above is weakened.

### 17. One `close_state` machine, both paths

There is one state machine, not a solo one and a PR one. `close_path` says
*which steps run*; `close_state` says *where the close got to*, in the same
twelve values whichever path produced them. `conflict` means the same thing on
both — the branch and main disagree and nothing may merge — even though on the
solo path it comes from a local `git rebase` and on the PR path from GitHub's
`mergeable: CONFLICTING`.

This is what makes a single recovery command possible. If the two paths had
their own vocabularies, `resolve-conflict` would have had to branch on the path
before it could even read the state, and every future control would pay the
same tax. The path-specific knowledge is pushed to the edges instead: the
rebase strategy is refused on the PR path (clause 19) and the "next step" line
names `merge` or `pr merge`, but the gate, the re-arm and the recorded state are
one implementation.

### 18. The controls are CLI commands, not config and not flags

Every operator decision in this pipeline is a subcommand of `queue-cli.sh`
taking an entry id: `merge`, `hold-merge`, `set-close`, `close-status`, the `pr`
family, and now `resolve-conflict`. None of them is a config field, an
environment variable, or a flag on `add`.

Config describes *policy* — how long to poll, which merge method to prefer —
and holds across every entry. These are *decisions about one entry at one
moment*, usually made in response to something that has already happened, and a
config field cannot express "this one, now". A flag on `add` is worse: it would
ask the operator to pre-commit to a conflict resolution before the work exists.

The consequence is that every control is auditable in the same way. Each writes
a `review_log_append` row and a `close_steps` row naming itself and its
arguments, so "why is this entry in this state" is answerable from the entry and
the review log without reconstructing a shell history.

### 19. A conflict on either path goes to review, and `resolve-conflict` is its one exit

A conflict escalates and moves the entry to `review/` on both paths — brief 2
already made the PR path do this through `queue_escalate` from the CLI. It does
not retry, and it does not fail the entry: the session's checks passed, and
nothing about re-running them resolves a disagreement with main.

`resolve-conflict <id> (--agent | --ours | --theirs | --manual)` is the only way
out of `close_state: conflict`, and it **never merges**. It records which
resolution was chosen and then re-arms the entry — `completed/` + `close_state:
ready` — so the existing pipeline runs again from its own beginning. Clause 6's
single-implementation property is therefore preserved exactly: there is still
one solo close (`_solo_merge_if_needed`) and one PR merge (`pr_merge`), and this
command starts neither, it only makes them eligible again.

**`--ours`/`--theirs` are recorded on the entry, not applied where the operator
stands.** This is the one non-obvious choice in the brief and it is load-bearing.
Resolving locally means merging main into the branch, which makes the branch
contain main's tip — and that empties `overlap_report.main_changed`, which is
the *only* trigger for Decision t-0056's close-time re-verification. The next
close would then skip re-verification and record a clean merge. The brief's own
requirement, that `--ours`/`--theirs` re-run all checks before the close, would
be false in precisely the situation a conflict proves it matters: main has moved
under a branch that was verified against an older main. The strategy is instead
carried to the single `git rebase` in `lib/reverify-merge.sh`, keeping rebase →
re-verify → merge inside one gate.

Two properties follow from where it is applied. The value is stored in the
**operator's** vocabulary — `ours` means the branch's side wins — because git
inverts this during a rebase (the replayed branch is "theirs"), and the
inversion belongs at the one rebase site rather than in the operator's head at
every read. And it is **read-and-clear**: taken and blanked before the rebase
runs, so one choice resolves one conflict and cannot silently steer an
unrelated rebase later.

`--ours`/`--theirs` are refused on `close_path: pr`. They are a local rebase
strategy and there is no local rebase on that path; accepting them would store a
value nothing reads and report a resolution that never happens. `--agent` and
`--manual` work on both, and the refusal names `set-close` as the third option.

The precondition is its own gate, `queue_conflict_resolve_allowed`, and
deliberately **not** `_queue_close_preconditions`. That gate asks "may this
reach main", and two of its clauses describe the exact state being recovered
from: clause 1 demands `completed` while a conflicted entry is in `review/`, and
clause 2 reads `reverified: false` as a standing refusal. Routing the recovery
command through it would make the command unreachable from the only situation it
exists for. What the new gate keeps is clause 5's finality — not for symmetry,
but because the re-arm reopens the parent work order (a conflicted entry's order
is `escalated`, and the runner's deferral guard would otherwise walk the fix
brief into `blocked/`), and with no unfinished sibling there is nothing that
guard is correctly holding back.

### 20. An agent resolution is a fix brief, not a new free session

`--agent` does not hand an agent a branch and a conflict. It generates a brief —
the conflicting files (from the escalation the merge path already wrote), both
sides as short SHAs with the `git show` / `git diff` commands to read them, the
operator's `--note`, and what happens when it completes — and queues it as a
**follow-up of the conflicted entry**, on the same branch.

The brief is the point. A session with a brief has a goal, a scope, a task
contract and the whole gate chain; a free session told "fix the conflict" has
none of those, and a conflict is exactly the situation where quietly dropping
one side looks like success. The generated contract constrains it twice —
resolve the conflict only, and leave the merge to the pipeline.

The linkage is `follow_up_of`, and it is created by delegating to
`follow-up-entry` rather than reimplementing it. That command owns what the
linkage means (Decision t-0055 clause 14): the copy to
`followup-<parent>-<n>.md`, the deliberately empty `branch` the dequeue selector
resolves, the inherited work order. A second enqueue path would be free to drift
from it.

Two consequences worth naming. The generated brief carries **no `### Task
Group` section** even when its parent is a task-group entry: without one
`_parse_brief_sequence` returns empty, the dequeue sequencing guard is skipped,
and the fix brief is eligible as soon as its parent is `completed` — which is
right, because it has no position in the group's sequence to wait for. And the
fix brief's completion **is** the close re-run: it shares the parent's work
order, so while it is outstanding the parent is not final and a `merge` on the
parent is refused; when it completes it is itself final and its own close runs
the whole pipeline on the shared branch. Nothing has to remember to re-merge the
parent.

### 21. A hold and a manual resolution never auto-merge

`merge_hold` and `--manual` both mean "not yet, and not without me". Neither
ever results in a merge the operator did not ask for in a separate command.

A held entry stops at `ready`. The runner's own solo close checks the hold and
declines; only an explicit `queue-cli.sh merge` (which outranks the hold,
because asking to merge a held entry is releasing it in the same breath) or
`hold-merge --release` followed by the daemon's next pass will move it. Clause 3
is what keeps this honest under a conflict: `held` renders over a *pending*
state only, never over `conflict` or `reverify_failed`, because the merge gate
admits `held` — so rendering a hold over a refusing state would have turned
placing a hold into a way to pass the gate `conflict` exists to fail.

`--manual` stores no strategy at all. The resolution arrives as commits the
operator makes, and the close re-runs on their next `merge` or `pr merge` — an
explicit command, after they have seen the result. `--agent` likewise stores no
strategy: a leftover one would steer a rebase the fix brief's commits were meant
to make unnecessary.

The escalation is read and **not** resolved. `resolve-conflict` takes the
conflicting-file list from the newest unresolved `esc-merge-*` naming the entry
and leaves `resolved: false` in place. Nothing in this system marks an
escalation resolved programmatically — `cleanup.sh` only deletes ones already
marked by hand — and adding an escalation-mutation mechanism as a side effect of
a merge command would be a new capability smuggled in under a recovery
operation.

## Consequences

- `.claude/.automation/schemas/queue-entry.yaml` gains `close_path`,
  `close_state`, `close_steps` and `merge_hold`, all optional. Schema **v1.10.0**
  — additive, so a minor bump
- `.claude/.automation/lib/queue-manager.sh` gains the `_QE_CLOSE_*` /
  `_QE_MERGE_HOLD` plumbing and the `queue_close_*` API: `queue_close_record`,
  `queue_close_state`, `queue_close_path`, `queue_close_step_json`,
  `queue_set_close_path`, `queue_set_merge_hold`, `queue_close_merge_allowed`,
  `queue_is_final_taskgroup_entry`. `queue_dequeue` gains a hold guard for a
  task group whose earlier brief carries `merge_hold`
- `.claude/.automation/runner.sh` records state through the whole solo path,
  gains `_close_record` / `_close_entry_path` / `_close_merge_held` /
  `_close_record_reverify_pass`, and gains the `--close-entry` mode.
  `_is_final_taskgroup_entry` becomes a delegation
- `.claude/.automation/lib/reverify-merge.sh` records `rebasing` and
  `reverifying`, and fills the rebase step's `detail` with the conflicting
  files — the caller only ever sees return code 1
- `.claude/.automation/queue-cli.sh` gains `merge`, `hold-merge`, `set-close`
  and `close-status`, all with `--json`; `show --json` reports `close_path`,
  `close_state`, `merge_hold` and `close_steps`
- `.claude/.automation/tests/test-close-pipeline.sh` is new (83 assertions).
  It is standalone, like `tests/test-reverify-merge.sh`, and not in
  `test-runner.sh`'s adversarial `SUITES`
- `.claude/.automation/RUNNER-PARITY.md` gains rows 67 (close state recording)
  and 68 (operator close controls); row 42 records the predicate move
- No new escalation type. A rebase conflict and a failed re-verification keep
  the `esc-merge-*` and `esc-reverify-*` artifacts t-0056 defined

### Brief 2 (amendment, 2026-10-23)

- `.claude/.automation/lib/pr-manager.sh` is new — the whole `gh` surface:
  `pr_gh_available`, `pr_open`, `pr_refresh`, `pr_rerun`, `pr_update_branch`,
  `pr_merge`, reporting through `_PR_*` result globals
- `.claude/.automation/templates/pr-body.md` is new — `{key}` substitution only,
  no shell expansion, so brief text cannot execute
- `.claude/.automation/schemas/queue-entry.yaml` gains `pr: {number, url}`,
  nested like `milestone:` because it is two fields describing one external
  entity. Schema **v1.11.0** — additive. `queue-manager.sh` gains the
  `_QE_PR_*` plumbing and `queue_set_pr`, which is **not** in `queue_edit`'s
  allowlist: the number is GitHub's to assign
- `.claude/.automation/config.yaml` gains a top-level `pr:` block —
  `merge_method` (`merge`), `poll_seconds` (`120`), `delete_branch` (`true`).
  Top-level because `_parse_config_field`'s range pattern only resolves
  top-level keys; every comment sits above its key and avoids writing any field
  name followed by a colon, which the unanchored field pattern would match
- `.claude/.automation/runner.sh` gains `_close_entry_close_path` (fail-safe to
  `solo`, the pre-amendment behaviour), the PR arm inside the
  `push_on_complete` branch, and `_pr_poll_sweep` + its pre-dequeue call site
- `.claude/.automation/queue-cli.sh` gains `pr open|refresh|status|rerun|
  update-branch|merge <id>`, all with `--json`. `pr status` spends no `gh` call
- `.claude/.automation/tests/test-pr-manager.sh` is new (150 assertions, `gh`
  stubbed on PATH against a real bare-repo origin). Both it and brief 1's
  `test-close-pipeline.sh` are now registered in `tests/run-automation-tests.sh`
  — brief 1 shipped its suite unregistered, which is why PR.25 asserts the
  registration rather than assuming it
- `RUNNER-PARITY.md` gains rows 69 (PR close path) and 70 (poll + PR controls)
- **Known coverage gap, recorded rather than implied:** the runner and CLI call
  sites are asserted *structurally* (PR.25 greps the shipped source). Neither
  file can be sourced — `runner.sh` parses argv and enters a daemon loop at
  load, `queue-cli.sh` dispatches on `"$1"` — so the assertions catch a
  `pr-manager` nothing calls, but not a call site passed the wrong entry, and
  the daemon poll has no behavioural coverage at all
- **The live `gh` preflight did not run.** `pretooluse-permission.sh` denies
  `gh` from an agent's Bash tool, so the brief's "run `gh --version` and
  `gh auth status`" step was unreachable from the session that implemented it.
  The degrade paths are exercised against a stub instead. Note that this
  blocks the *agent*, not the runner: the permission hook gates agent tool
  calls, not subprocesses inside `runner.sh` or `pr-manager.sh`, so `gh` is
  reachable in production. Brief 1's handoff note claimed otherwise and is
  wrong on that half
- **Known state gap, recorded rather than designed away:** `merging` is
  transient in both directions — forward to `merged`, back to `pr_open` when
  `gh pr merge` fails. An entry sticks in it only if that restoring
  `queue_close_record` *also* fails, because `merging` is not an admitted start
  state and the retry would be refused; the recovery is `set-close`. This is
  the price of every `queue_close_record` carrying `|| true` so that reporting
  can never decide whether a branch merges, and the solo path has the identical
  window
- §3's correction was found by the critic in cohesion mode, not by a test. The
  old rendering had shipped in brief 1 and its own tests passed, because they
  asserted the exemption list rather than the property the list was for. The
  property is now asserted directly: `test-close-pipeline.sh` CP.7 holds a
  conflicted entry and checks the *merge gate* still refuses it

### Brief 3 (amendment, 2026-10-23)

- `.claude/.automation/schemas/queue-entry.yaml` gains `conflict_resolution`
  (`""` | `ours` | `theirs`). Schema **v1.12.0** — additive. `queue-manager.sh`
  gains the `_QE_CONFLICT_RESOLUTION` plumbing and `queue_set_conflict_resolution`,
  which is **not** in `queue_edit`'s allowlist: the field steers a merge. The
  value is normalised to `""` on load for anything outside the closed set, at
  the one site every reader passes through, because it is spliced into a
  `git rebase` argument list
- `.claude/.automation/lib/queue-manager.sh` gains
  `queue_conflict_resolve_allowed` (the fail-closed precondition — entry loads,
  `close_state` is literally `conflict`, and the entry is final) and
  `queue_close_rearm` (review/ → completed/ at `close_state: ready`)
- `.claude/.automation/lib/reverify-merge.sh` gains
  `_reverify_take_conflict_strategy`, which reads the stored strategy, clears
  it, and prints the inverted `-X` argument for the one `git rebase`. Both of
  its dependencies are `type`-guarded, so the library still loads standalone
- `.claude/.automation/queue-cli.sh` gains `resolve-conflict <id>
  (--agent|--ours|--theirs|--manual) [--note TEXT]` with `--json`. It delegates
  the `--agent` enqueue to its own `follow-up-entry` subcommand rather than
  reimplementing the follow-up linkage
- `RUNNER-PARITY.md` gains row 71 (close conflict resolution)
- **`queue_close_rearm` clears exactly three fields and all three are
  load-bearing:** `status` (precondition clause 1 refuses anything but
  `completed`), `close_state` (clause 4 admits `ready` and `held` only), and
  `reverified` (clause 2 reads a stored `false` as a *standing* refusal, so a
  `reverify_failed` conflict would stay refused forever; `""` means "did not
  run"). `completed_at` is deliberately preserved — the session completed when
  it completed, and a close re-arm is not a second completion. `error_log` is
  cleared only after its contents reach the review log
- **Ordering is a refusal property, not a style choice.** The follow-up is
  enqueued and the strategy recorded *before* the re-arm, and the re-arm is
  last. Once an entry is back at `ready` the conflict is no longer visible as
  one, so a failure after that point would leave an entry that looks mergeable
  with nothing arranged to make it so
- **Known gap:** `--agent`'s round trip has no behavioural coverage. It runs
  `queue-cli.sh follow-up-entry` as a subprocess, and `queue-cli.sh` cannot be
  sourced (it dispatches on `"$1"`), so the suite covers the two library halves
  directly and the CLI half structurally — the same boundary brief 2 recorded
  for `pr-manager`'s call sites

## Override

There is no override that makes a refused merge proceed — every clause of
§5 is a condition under which main must not be written to unattended.
`hold-merge --release` removes a hold the operator placed; it does not bypass
anything. `set-close` changes the route but cannot relax the preconditions on
either route.

## Falsification Signals

Revisit this decision if any of these happen:

- `merge` refusals are routinely worked around by editing the entry file by
  hand — the preconditions are stricter than the work needs, and an operator
  bypassing the gate is worse than a looser gate.
- `close_state` is read anywhere that then re-derives it — the single
  derivation site has leaked, and the field is no longer load-bearing.
- `close_steps` is parsed back into structure by anything — the
  stored-verbatim property has been lost and the escaping is now a correctness
  dependency rather than a display one.
- Holds are placed on nearly every entry — the operator does not actually want
  automatic merges, and `solo_mode` should default the other way instead.
- The three `ready`-recording failure sites are indistinguishable in practice
  because nobody reads `detail` — they need their own states after all.
- `pr merge` is routinely refused on `mergeable: UNKNOWN` and the operator's
  habit becomes "refresh twice then merge" — the live read is happening too
  early, and `pr_merge` should wait for a determinate answer rather than report
  an indeterminate one (clause 16).
- `pr.poll_seconds` is raised repeatedly to quiet API usage — polling is the
  wrong mechanism and the route wants a webhook, not a tighter interval
  (clause 15).
- A `gh` call appears outside `lib/pr-manager.sh` — the single-surface property
  of clause 11 has been lost, and the runner and the operator can now disagree.
- `--agent` fix briefs routinely come back having changed behaviour rather than
  only resolved a conflict — the brief and its contract are not constraining
  enough, and the resolution wants a narrower session type than an inherited
  one (clause 20).
- `resolve-conflict` is run more than once on the same entry in a normal
  recovery — either the re-arm is not actually re-arming or the strategy is not
  reaching the rebase, and the read-and-clear of clause 19 is hiding which.
- Operators reach for `--ours`/`--theirs` far more often than `--agent` — the
  conflicts are mechanical, which would mean they are being caused upstream (by
  how branches are cut or how long they live) rather than being a close-time
  problem at all.
- `conflict_resolution` is read anywhere other than
  `_reverify_take_conflict_strategy` — the single consumption site has leaked
  and the inversion in clause 19 is now duplicated somewhere it can disagree.

## Amends

Nothing. Decision 0015 (solo mode), Decision 0030 (worktree session isolation,
merge coordination, the ref-move invariant), Decision 0054 (task group
worktree lifetime), Decision t-0056 (re-verify before merge) and Decision
t-0061 (fail-closed runner) remain binding and unchanged. This decision records
and exposes the close sequence those decisions already describe; it does not
change who merges, who seals, when, or what may reach main.

The brief-2 amendment amends nothing either, with one clarification rather than
a change. On `close_path: pr` the merge is performed **by GitHub**, not by a
local `git merge`, so Decision 0030's merge lock and ref-move invariant have
nothing to coordinate there (clause 16) — and the local step that follows is a
`--ff-only` sync, which is not a ref-move onto a stale working tree. Decision
0013 sealing is unchanged in substance and earlier in time (clause 13): the
branch is retired from local session use when the pull request opens, because
that is the moment no local session needs it again.

The brief-3 amendment amends nothing either. Decision t-0056 is strengthened
rather than relaxed: clause 19 exists precisely to keep its one trigger
(`overlap_report.main_changed`) intact through a conflict resolution, where the
obvious local fix would have silently disabled it. Decision t-0055's follow-up
semantics are used as written — `--agent` delegates to `follow-up-entry` and
adds no new linkage. Decision t-0061's fail-closed rule applies to the new
command in full: `resolve-conflict` refuses with a printed reason and a non-zero
exit rather than guessing a mode, a path or a strategy, and has no default mode
at all. Clause 6's single-implementation property is preserved, not excepted:
the command re-arms an entry and starts no merge of its own.
