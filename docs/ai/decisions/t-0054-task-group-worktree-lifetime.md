# Decision 0054 — Task Group Worktree Lifetime

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/(\.automation/(runner|lib/group-worktree-sweep|lib/cleanup)|hooks/(_cleanup-helper|session-close-check))\.sh`
- keywords: `group worktree, tg-, group_worktree_path, acquire_group_worktree_lock, remove_group_worktree, sweep_stale_group_worktrees, clean-start, worktree lifetime, worktree reuse`

## Decision

A **sequential task group** gets ONE worktree for the whole life of its branch.
Brief 1 creates it, briefs 2…N reuse it, and it is removed only when the group
is finished or abandoned.

1. **Path.** Task group worktrees live at `.worktrees/tg-{group_name}`, where
   `{group_name}` is the brief's `Group:` field sanitised to one path component
   (`[a-zA-Z0-9_-]`). Standalone sessions keep `.worktrees/{session-id}`
   (Decision 0033).

2. **Create or reuse.** At launch for a sequential task group entry: if the
   group worktree exists, is a git-registered worktree, and is checked out on
   the group branch, reuse it. If it does not exist, create it with
   `git worktree add` on the group branch. If a path exists that git does not
   know as a worktree, or a worktree exists on a different branch, **fail
   loudly** with an escalation. It is never silently recreated.

3. **Clean-start guarantee.** Before a brief starts in a reused worktree,
   `git status --porcelain` must be empty and HEAD must equal the group
   branch's tip. Otherwise a `dirty-tree` escalation is written and the brief
   does not start. Gitignored files are exempt by construction —
   `--porcelain` omits them without `--ignored` — and their survival is the
   point of the reuse.

4. **Single occupant.** Only one session may run in a group worktree at a time,
   enforced by a lock at `.claude/.state/.tg-worktree-{group}.lock.dir` holding
   the holder's pid and session id. The session registry's task-group overlap
   check stays advisory for a shared *branch*; for a shared *worktree* it is
   blocking. The lock is claimed by `runner.sh` for headless briefs and by
   `init_phase()` for every other session, so occupancy is BLOCK-level for both
   (see § Amendment 2026-10-08). Override: `REPO_OS_SKIP_GROUP_LOCK=1`.

5. **Cleanup.** Normal exit of any brief and crash cleanup do **not** remove a
   group worktree. It is removed only when:
   a. the final brief's branch has merged **and** been sealed;
   b. the group's work order reaches `failed`, or the group is abandoned; or
   c. the stale sweep finds a group worktree whose branch is sealed, whose
      branch no longer exists, or which has had no commit for 7 days — in each
      case with no live session on the branch and no live lock holder.
   The occupancy lock is released on every path, including crash and
   force-halt.

   **Sealed-but-failed is not a crash.** Removal in case (a) is keyed on the
   closed-branches ledger, and Decision 0013's seal rule already records a
   branch as closed on *any* terminal outcome of a final entry — including a
   non-solo brief that failed. Such a brief therefore loses its worktree, even
   though it did not crash. That is correct (the branch is retired, so no
   further brief will run) but it is a different operator experience from §6:
   a **crash** leaves the worktree for inspection, a **failure that also seals
   the branch** does not. Inspect the branch itself in that case — the work is
   committed on it, and only reproducible gitignored state is lost.

6. **Crash recovery.** A crashed brief leaves its worktree in place for
   inspection. The restart path (`REPO_OS_ALLOW_REINIT=1`) reuses it, subject
   to the clean-start check in §3 — so a crash that left uncommitted work
   requires the operator to commit or discard it first. That is deliberate:
   inspection and a clean start are both preserved, in that order.

7. **Scope.** Parallel task groups are out of scope and keep the per-brief
   branches and worktrees of Decision 0032. Standalone session behaviour is
   unchanged.

### Why this is a decision and not a side effect

Decision 0033 made worktree isolation the default for all sessions and recorded
the consequence for sequential groups in a single line: *"Sequential task
groups: unaffected (shared branch, worktree isolation is per-session)."* No
decision ever weighed per-group against per-session worktrees for a group that
shares one branch across many sessions. The resulting behaviour — a new
worktree created and force-removed for every brief — was a side effect.

Its two costs:

- **Rebuilt working state.** Untracked and gitignored working files (dependency
  installs, build output, caches) are discarded and rebuilt for every brief in
  the group, even though all briefs share one branch and one logical task.
- **Unrecoverable crashes.** A crashed brief's worktree is force-removed by
  `_runner_crash_cleanup` and the force-halt path, taking with it exactly the
  state an operator would want to inspect.

### Per-session governance state is unchanged

Per-session state still lives at `wt-sessions/{session-id}/` **inside** the
worktree, so the governance isolation of Decision 0030 is untouched: briefs
sharing a worktree do not share phase-state, gate evidence, or session
identity. The runner's `plan-approved` mirror is re-written on every brief,
including the reuse path, because it is session-scoped.

### Branch freshness is handled worktree-side

`branch_manager_setup()` keeps a branch fresh against main in three cases:
delete-and-recreate when the branch is an ancestor of main (Case 1), rebase
when it is behind main (Case 3), no-op when it is ahead (Case 2). Cases 1 and 3
use `git branch -D` and `git checkout`, and **git refuses both against a branch
that is checked out in a live worktree**. Rather than weaken
`branch-manager.sh` for every entry type, `_resolve_group_worktree()` mirrors
the same three cases using `git -C <worktree>`: Case 1 retires the worktree and
lets the normal create path rebuild from current main, Case 3 rebases inside
the worktree (safe, because the clean-start check has already run), Case 2 is a
no-op. `branch-manager.sh` is unmodified.

## Implication

- `.claude/hooks/_cleanup-helper.sh` gains the group worktree primitives:
  `_sanitize_group_name`, `group_worktree_path`, `_group_worktree_lock_dir`,
  `current_group_worktree_name`, `acquire_group_worktree_lock`,
  `release_group_worktree_lock`, `release_group_worktree_lock_if_orphaned`,
  `is_registered_worktree`, `group_worktree_branch`,
  `check_group_worktree_clean`, `remove_group_worktree`
- `.claude/.automation/runner.sh` gains `_resolve_group_worktree()`,
  `_brief_is_sequential_group()`, `_write_group_worktree_escalation()`, the
  `_CURRENT_WORKTREE_IS_GROUP` / `_CURRENT_GROUP_NAME` globals, and a seventh
  `brief_path` parameter on `_run_single_entry`. `_solo_merge_if_needed` gains a
  fifth `group_name` parameter. All three worktree-removal sites (normal exit,
  `_runner_crash_cleanup`, FORCE-HALT) now branch on
  `_CURRENT_WORKTREE_IS_GROUP`
- `.claude/.automation/lib/group-worktree-sweep.sh` is new —
  `sweep_stale_group_worktrees()`, wired into `run_cleanup()` in `cleanup.sh`
  behind a `type` guard
- `.claude/hooks/session-close-check.sh` releases an orphaned group worktree
  lock on the SessionEnd path. It does not remove the worktree: a hook running
  inside the worktree cannot remove the tree it is standing in
- `.claude/hooks/tests/layer8-group-worktree.sh` is new (61 assertions);
  `run-phase-tests.sh` gains Layer 8; `test-helpers.sh` gains
  `assert_dir_exists`
- Outcome details added: `failed:group-worktree-locked`,
  `failed:group-worktree-dirty`, `failed:group-worktree-branch-mismatch`,
  `failed:group-worktree-unregistered`

## Known Limitations

**Interactive occupancy was REQUIRE-level, not BLOCK-level** — **closed by
§ Amendment 2026-10-08.** As originally shipped the lock was acquired and
released only by `runner.sh`, so it was mechanically enforced for headless and
daemon sessions while an operator entering a group worktree by hand got only the
session registry's advisory overlap warning. Closing the gap meant acquiring the
lock from `init_phase()` — a shared code path used by every session type — which
was deliberately deferred rather than smuggled in here. The operator
subsequently authorised that scope.

**Parallel task groups are untouched.** A parallel group's content briefs own
separate branches (Decision 0032), so a shared worktree would be wrong for
them. Giving each parallel brief a *persistent per-brief* worktree is a
plausible follow-up with the same cost argument, but it is a different design
and is not decided here.

## Alternatives Considered

1. **Track occupancy in the session registry instead of a new lock.** The
   registry (`.claude/.state/sessions/{sid}.yaml`) already records a pid per
   session and already has dead-pid staleness logic, so a `group_worktree:`
   field plus a filtered query would avoid a second occupancy-tracking format.
   Rejected: the registry writes **one file per session id**, so two sessions
   each write their own file and neither observes the other's claim atomically.
   That is precisely why its task-group overlap check is advisory — it can
   report overlap after the fact but cannot prevent it. The requirement here is
   mutual exclusion, which needs a single contended object; `mkdir` on a shared
   path provides it. The lock deliberately stores only a holder pointer (pid +
   session id) so the registry remains the source of truth for session
   metadata.

2. **flock, as used for `.merge-lock`.** Rejected: the merge lock is held for
   seconds inside one process and can live on a file descriptor. Group
   occupancy must persist for a whole session and stay observable from
   short-lived hook processes, which cannot inherit the descriptor. Liveness is
   therefore recorded explicitly, and a lock whose holder pid is gone is broken
   on sight — without that, a crashed brief would wedge its group permanently.

3. **A new `dirty-tree` escalation type.** The brief called the brief-start
   refusal a `dirty-tree` escalation. Rejected as an enum addition: the
   schema's existing `governance-block` type already means "hook enforcement
   prevented action", and `state-manager.sh` already writes an
   `esc-dirty-tree-*` escalation under it at headless close. The new escalation
   follows that id convention under the same type, so no schema or
   SCHEMA-CHANGELOG change is needed.

4. **Keep removing per-brief but skip only gitignored paths.** Copying or
   symlinking gitignored state between per-brief worktrees. Rejected: more
   machinery than keeping one worktree, and it would not fix the crash-recovery
   half of the problem at all.

5. **Thread a "sealed" flag through the five seal sites in
   `_solo_merge_if_needed`.** Rejected in favour of reading the
   closed-branches ledger: it is the same signal Decision 0013 uses, it is one
   check instead of five, and it already encodes the case that matters — a
   merge conflict deliberately leaves the branch unsealed for retry, so the
   worktree must survive too.

## Falsification Signals

Revisit this decision if any of these happen:

- `dirty-tree` escalations at brief start become frequent — the clean-start
  guarantee is costing more than the rebuild it replaced.
- Gitignored state carried between briefs causes a gate to pass or fail where a
  clean worktree would not — carry-over is leaking into verification.
- Group worktrees are left behind after their branch is sealed — the terminal
  removal paths or the sweep are not firing.

## Override

`REPO_OS_WORKTREE_ISOLATE=0` disables worktree isolation entirely (Decision
0033), which also disables group worktrees. `GROUP_WORKTREE_STALE_DAYS` tunes
the sweep's age threshold (default 7). There is no override that keeps worktree
isolation on but forces per-session worktrees for task groups — a group whose
`Group:` field is missing already falls back to a per-session worktree with a
warning.

## Amends

Decision 0033 § "What This Does NOT Change" — the bullet reading "Sequential
task groups: unaffected (shared branch, worktree isolation is per-session)" is
superseded for the worktree-lifetime question only. See Decision 0033
§ Amendment 2026-10-06. Decisions 0013 (branch isolation and sealing), 0028
(subagent worktree state block), 0030 (per-session state directories, merge
coordination, ref-move invariant) and 0032 (parallel task group worktrees)
remain binding and unchanged.

---

## Amendment — 2026-10-08: Interactive Occupancy Is Now BLOCK-Level

§ Known Limitations originally recorded that single occupancy was mechanically
enforced for headless briefs only, because `runner.sh` was the sole party
claiming the lock. An operator entering a group worktree by hand for an
interactive brief could start a second session in a worktree another session was
already using, and would see only the session registry's advisory overlap
warning. The operator authorised closing that gap.

**`init_phase()` now claims the lock.** `_claim_group_worktree_lock_at_init()`
in `_phase-helper.sh` runs on every session init with three outcomes:

| Condition | Outcome |
|-----------|---------|
| Not inside a `tg-*` worktree | No-op success — every standalone session |
| Lock already recorded against **this session id** | No-op success (see re-entrancy below) |
| Live foreign holder with a different session id | `GATE-RECOVERABLE`, `init_phase` returns 1 |

Occupancy is therefore BLOCK-level for interactive, `EnterWorktree` and headless
sessions alike. Override: `REPO_OS_SKIP_GROUP_LOCK=1` (logged via
`log_override`).

### Re-entrancy is keyed on session id, never on pid

In a headless brief `runner.sh` has already claimed the lock for the *same*
session, recording the **runner's** pid — which is not the durable claude pid
`init_phase` would use. Keying re-entrancy on pid would make every headless
group brief block on its own runner. The session id is the one identity both
parties share, so it is the only safe key. Pinned by an explicit test case
(`layer8-group-worktree.sh` § L8.2b) that holds the lock under a different live
pid and asserts the claim is still re-entrant and does not steal the holder pid.

### Release is now pid-aware

An interactive session's lock holder is its own claude process, which is still
alive at SessionEnd, so the original orphan-only release condition could never
fire for it. `release_group_worktree_lock_if_orphaned()` takes an optional
`owner_pid` and releases when the recorded holder is **either** gone **or** this
session's own process. A runner-held lock carries the runner's pid, so it is
still left alone and released by the runner after its post-session merge — the
window that hold exists to close is preserved.

### Placement inside init_phase

The claim runs **before** the phase-state write. A session blocked here never
initialised, so it must not leave phase-state behind; leaving it would trip the
double-init guard on the operator's retry and make a recoverable "worktree
occupied" message look like a corrupted session.

`_phase-helper.sh` sources `_cleanup-helper.sh` lazily inside the new function
behind a `type` guard rather than at load. The dependency is acyclic (both need
only `_analytics-helper.sh`), and the guard means a partial deployment degrades
to the pre-amendment behaviour instead of aborting init.

### Files changed

- `.claude/hooks/_phase-helper.sh` — `_claim_group_worktree_lock_at_init()`, called from `init_phase()`
- `.claude/hooks/_cleanup-helper.sh` — `group_worktree_lock_holder_session()`; `release_group_worktree_lock_if_orphaned()` gains `owner_pid`
- `.claude/hooks/session-close-check.sh` — passes the durable pid at SessionEnd
- `.claude/hooks/tests/layer8-group-worktree.sh` — § L8.2b
- `.claude/agents/_agent-glossary.md` — `REPO_OS_SKIP_GROUP_LOCK` override row
- `.claude/.automation/RUNNER-PARITY.md` — row 58 updated

---

## Amendment — 2026-10-12: The Group Worktree Never Activated In Production

This decision shipped working code and a passing test suite, and still never
took effect for a single real brief. Recorded here because the failure mode —
not the feature — is the transferable lesson.

`_resolve_group_worktree()` resolves the group name through
`_extract_group_name()` in `lib/cohesion-trigger.sh`, which was:

```
grep -oE 'Group:\s*\S+' "$f" | head -1 | sed 's/Group:[[:space:]]*//'
```

Real briefs carry the canonical form that `_parse_brief_taskgroup_metadata`
requires and the templates emit:

```
### Task Group
- **Group:** my-group
```

Against that, `\S+` consumed the closing bold markers, so the regex matched
`Group:**` and the helper returned the literal `**`. `_sanitize_group_name("**")`
reduces to the empty string, `group_worktree_path` therefore failed, and
`_resolve_group_worktree` returned "not applicable" **silently** — no warning,
because the empty-group guard above it tests for an empty return and `**` is not
empty. Every sequential task group fell back to a per-session worktree, exactly
as before this decision existed.

It was not only the worktree. The same helper feeds the cohesion trigger and
drift detection, so the daemon logged `no contract found for group '**'` and
drift detection lost its group scope too.

**Why the tests passed.** The fixtures in
`.claude/.automation/tests/test-group-worktree-lifecycle.sh` were written with a
bare `Group: x` line — a form no real brief uses. The suite verified the
mechanism against a format that does not occur in production. A second instance
of the same mistake was found while fixing this: `_brief_is_sequential_group()`
matched a bare `Execution: parallel` but not the canonical
`- **Execution:** parallel`, so a PARALLEL group would have been classified
sequential and handed a shared worktree — two briefs racing one working tree,
precisely what Decision 0032 exists to prevent. That defect never fired only
because no parallel group has run since.

**Fixed.** `_extract_group_name` now parses the canonical form first, scoped to
the `### Task Group` section so a stray `Group:` elsewhere cannot win, and falls
back to an anchored bare form for legacy briefs. `_brief_is_sequential_group`
accepts both forms. The fixtures were rewritten to the canonical format with a
legacy fixture retained alongside, and explicit parser assertions added for
canonical / legacy / absent. Against the pre-fix source those assertions produce
13 failures, including the downstream worktree ones; after the fix the suite is
54/54.

**The rule worth keeping:** a fixture that invents its own input format tests the
mechanism and not the integration. When a parser has a canonical producer, the
fixture must come from that producer's format.
