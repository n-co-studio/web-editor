# Schema Changelog

## Deprecation Policy

Schemas follow a 2-version support window:
- **Deprecated in N**: Schema field or structure marked deprecated. Runners must handle both old and new forms.
- **Removed in N+2**: Deprecated field/structure removed. Runners using old form will fail.

Breaking changes (field removal, type change, required field addition) increment the major version. Additive changes (new optional fields) increment the minor version.

---

## v1.12.0 — Conflict Resolution

**Date:** 2026-10-23
**Decision:** t-0057 (Close Pipeline Controls), brief 3 of 3

### Changes

**queue-entry.yaml** (+1 field):
- `conflict_resolution` (string, default `""`, one of `""` | `ours` | `theirs`) — the rebase strategy chosen by `resolve-conflict --ours|--theirs`, carried to the single `git rebase` in `lib/reverify-merge.sh`, which reads it once and clears it. Written by `queue_set_conflict_resolution` and by nothing else; absent from `queue_edit`'s allowlist, because it steers a merge.
- `close_steps[].step` gains `resolve` — the row a `resolve-conflict` re-arm appends, carrying the mode and the operator note in its `detail`. It is the only step name an operator causes directly; every other one is a pipeline action.

**review-log-entry.yaml** (no field change):
- Two new event names registered: `entry-conflict-resolved` (the operator's choice) and `entry-conflict-resolve-reason` (the refusal that preceded it, written before `error_log` is cleared). Reconciling the enum by diff — as the file's own comment instructs — also surfaced twelve names emitted since the 2026-10-21 pass and never listed, all from t-0055's operator commands plus brief 1 of this decision. They are now listed. Nothing validates this enum mechanically, which is exactly why it drifts.

**`--ours`/`--theirs` are stored, not applied — and that is the point of the field.** The obvious implementation resolves the conflict where the operator stands: merge `main` into the branch with `-X ours`, commit, done. It is wrong for a reason that is invisible until it bites. Resolving locally makes the branch contain main's tip, which empties `overlap_report.main_changed` — the *only* trigger for the t-0056 close-time re-verification. The next close would then skip re-verification and record a clean merge, so the brief's own requirement ("`--theirs`/`--ours` re-run all checks before the close") would be false in exactly the situation a conflict proves it matters: main has moved under a verified branch. Carrying the strategy to the one real rebase keeps rebase → re-verify → merge inside a single pipeline with a single gate.

**The value is stored in the operator's vocabulary, and git's inversion is applied once.** `ours` means *the branch's side wins*. During `git rebase main` the branch is being replayed onto main, so git calls main "ours" and the branch "theirs" — the opposite of what the operator said. The translation (`ours` → `-Xtheirs`, `theirs` → `-Xours`) lives in `_reverify_take_conflict_strategy` at the rebase site and nowhere else. Storing git's spelling instead would have put the inversion in the operator's head at every read of the entry.

**Read-and-clear, not read.** The strategy is cleared as it is taken, before the rebase runs. A strategy that survived its attempt would silently steer the *next* rebase too — including one the operator ordered months later for an unrelated reason. One choice resolves one conflict.

**`""` on load for anything outside the closed set.** Normalised in `_load_queue_entry`, at the one place every reader passes through, for the same reason `pr.number` is validated there: the value is spliced into a `git rebase` argument list. An unrecognised value must become the empty string before it can reach git, not after.

**`queue_close_rearm` is not `queue_reopen_reviewed`.** Reopening returns an entry to `approved/`, which re-runs the brief from its plan phase — right when the *session* failed, wrong here. The session's checks passed and were recorded; only the merge was refused, and re-running the brief would discard a verified result to fix a merge. The re-arm instead writes `completed/` + `close_state: ready`, which is not a convenience but what `_queue_close_preconditions` clauses (1) and (4) require. Three fields are cleared and all three are load-bearing: `status` (clause 1 refuses anything but `completed`), `close_state` (clause 4 admits `ready` and `held` only), and `reverified` (clause 2 reads a stored `false` as a *standing* refusal, so a `reverify_failed` conflict would stay refused forever; `""` means "did not run", and the next close runs the gate again). `error_log` is cleared last and only after its contents reach the review log.

**The precondition is its own gate, not `_queue_close_preconditions`.** That gate asks "may this reach main", and two of its clauses describe the exact state a conflicted entry is in — clause (1) wants `completed` while the entry sits in `review/`, clause (2) treats `reverified: false` as permanent. Routing the recovery command through it would make the command unreachable from the only situation it exists for. What `queue_conflict_resolve_allowed` *does* keep is clause (5), finality — and not merely for symmetry: the re-arm reopens the parent work order (a conflicted entry's work order is `escalated`, and the runner's post-dequeue guard defers then blocks an escalated order's entries, which would walk the `--agent` fix brief straight into `blocked/`). With no unfinished sibling there is nothing for that guard to hold back, so finality is what makes the reopen safe.

**An agent resolution is a fix brief, not a free session.** `--agent` generates a brief naming the conflicting files (from the escalation the merge path already wrote), both sides as short SHAs with the `git show`/`git diff` commands to read them, the operator's `--note`, and what happens on completion — then queues it through `follow-up-entry`, which is not reimplemented here. That command owns the linkage t-0055 clause 14 defines (the copy to `followup-<parent>-<n>.md`, `follow_up_of`, the deliberately empty `branch` the dequeue selector resolves, the inherited work order), and a second enqueue path would be free to drift from it. The generated brief carries **no `### Task Group` section** even when the parent is a task-group entry: `_parse_brief_sequence` then returns empty, the dequeue sequencing guard is skipped, and the fix brief is eligible as soon as its parent is `completed` — which is correct, since it has no position in the group's sequence to wait for.

**The fix brief's completion *is* the close re-run.** It shares the parent's work order, so once the parent is re-armed to `completed` the fix brief becomes the group's unfinished entry — which also means the parent is no longer final and a `merge` on it is refused while the fix is outstanding. When the fix completes it is itself final, and its own close runs the whole pipeline on the shared branch: rebase, re-verification, merge. Nothing has to remember to re-merge the parent.

**`--ours`/`--theirs` are refused on `close_path: pr`.** They are a local rebase strategy, and the pull request path updates the branch through `gh` where there is no local rebase to hand one to. Accepting the flag there would store a value nothing reads and report a resolution that never happens. `--agent` and `--manual` work on both paths, and the refusal names `set-close` as the third option.

**The escalation is read, not resolved.** `resolve-conflict` takes the conflicting-file list from the newest unresolved `esc-merge-*` naming the entry (`esc-merge-lock-*` excluded: a different event sharing the prefix, and one that sorts *after* the dated ids in a glob) and leaves `resolved: false` in place. Nothing in this system marks an escalation resolved programmatically — `cleanup.sh` only deletes ones already marked — and inventing that here would have added an escalation-mutation mechanism as a side effect of a merge command.

---

## v1.11.0 — Pull Request Close Path

**Date:** 2026-10-23
**Decision:** t-0057 (Close Pipeline Controls), brief 2 of 3

### Changes

**queue-entry.yaml** (+1 nested field):
- `pr` (map, default: `{number: 0, url: ""}`) — the pull request opened for this entry on `close_path: pr`. `number` is `0` and `url` is `""` until `open-pr` succeeds. Written by `queue_set_pr` and by nothing else — deliberately absent from `queue_edit`'s allowlist, because the number is GitHub's to assign, not the operator's to choose.

**config.yaml** (+1 top-level block, 3 fields): `pr.merge_method` (`merge`), `pr.poll_seconds` (`120`), `pr.delete_branch` (`true`).

**`close_state` rendering, corrected (no schema change):** v1.10.0 had `merge_hold: true` render as `held` over every stored state except `merged`, `pushed` and `pr_open`. It now also leaves `conflict` and `reverify_failed` alone. The exemption list in v1.10.0 was described as "a finished state", but the real criterion is *a state the merge gate refuses*, and those two are refusing states that are not finished. Because `_queue_close_preconditions` admits `held` on the solo path — an operator merging an entry they held is releasing it in the same breath — rendering `held` over `conflict` made placing a hold a way to **pass** the gate that `conflict` exists to fail. The hold is still visible either way: `merge_hold` is its own field and both `close-status` and `show --json` print it beside the state.

**`pr` is nested, where `close_state` and the rest are flat.** Two fields describing one external entity, written together and read together, following the `milestone:` precedent rather than inventing `pr_number`/`pr_url`. The url is stored rather than rebuilt from the number so that reporting never has to know the repo slug — the entry stays readable on a machine with no remote configured.

**The block is top-level in config.yaml, not nested under `runner:`.** `_parse_config_field`'s `sed` range pattern only resolves top-level keys. Within the block every comment sits above its key and never writes a field name followed by a colon: the field pattern is an unanchored `/<field>:/` over the block, so `merge_method:` in a comment would be matched as a second hit and concatenated onto the real value before `head -1` could discard it.

**The pull request route fires on `push_on_complete` and finality, not on `close_path` alone.** `close_path` already resolves to `pr` for every `solo_mode: false` entry, so triggering on it would start pushing branches to origin on every existing install the moment this shipped. Opting a branch into reaching origin stays a per-entry decision. Finality is the second condition (Decision 0015 §3): a task group closes once, at its last brief, and opening a pull request per brief would put the group's partial work in front of a reviewer three times. A non-final brief takes the plain push it took before this route existed.

**The branch is sealed as soon as the pull request opens, and sealed again when it merges.** Sealing retires a branch from *local* session use (Decision 0013), and on this path there is nothing left locally to wait for: checks, `update-branch` and the merge itself all happen on origin through `gh`. Deferring the seal to merge time would also have stranded the task group worktree, whose removal keys on the branch appearing in `closed-branches` — a pull request can sit open for days. So `record_closed_branch` runs at both sites: once in the runner's close arm when the pull request opens, and again in `pr_land` once the merge lands. It is idempotent, so the second is not a double-seal; `pr_land` is also where the local branch is deleted (`delete_merged_session_branch`) and, when `pr.delete_branch` is true, the remote one. The early seal is what frees the worktree; the late one is what cleans up now that the work is on `main`.

**A degrade records `ready`, not `pushed`.** With no `gh`, no auth or no remote the entry stops at `ready` with the reason in the step `detail`, and is never failed (brief 2 step 5). `pushed` could not be reused: it means *the branch reached origin and nothing merged it*, which is false when there is no remote at all, and an entry reporting `pushed` would read as further along than it is. `ready` is the retryable state, and `pr open` is the retry.

**The daemon's poll sweep reports; it does not transition.** It re-reads every `completed/` entry at `close_state: pr_open`, rate-limited to `pr.poll_seconds` with the timestamp stamped *before* the sweep so the interval does not drift by the `gh` round-trip time. It runs before the dequeue rather than in the idle branch, so a repo whose queue is never empty still notices a merge. It does not move an entry to `review/`: `queue_escalate` only acts on `running/`, and an entry whose session genuinely completed is not fixed by re-running it. The close state and the escalation are what the operator reads; the `pr` subcommands are where a conflict becomes a status transition.

**No conflicting-file list is recorded on this path.** The solo path can name the conflicted files because it runs the merge locally. Here GitHub holds the only merge, and `mergeable: CONFLICTING` says that a conflict exists without saying where. The escalation says so rather than claiming a list it does not have.

**`mergeable: UNKNOWN` is refused but never routed to conflict.** GitHub computes mergeability asynchronously (gh cli#9583), so `UNKNOWN` is a *transient* answer, not a negative one. Fail-closed (Decision t-0061) means a merge on an unverifiable precondition is refused — but routing to `review:merge-conflict` on it would escalate a pull request that is very likely fine. The refusal names the state and says to refresh.

**Check status is read from the rollup rows, never from its aggregate.** The aggregate `statusCheckRollup` state can read `SUCCESS` while an individual row reads `FAILED` (gh cli#14253). `conclusion` is also the empty string — not null — on a run that has not finished, so an unfinished check is pending, not passing. Both are read per row.

**`pr_land` takes no merge lock.** The lock exists to stop two local merges racing and to keep a re-verification verdict valid across rebase → verify → merge (row 63). Neither applies: GitHub performed the merge, and the local step is a `--ff-only` sync of `main` that has no verdict to invalidate and nothing to conflict with. `pr merge` therefore does not hand off to `runner.sh` the way `merge` does — there is no second merge gate that could disagree with the runner's.

**`close_state: merged` describes the pull request, not the local sync.** `_pr_land` records `merged` even when its `push` step row reads `failed` — local `main` diverged, or the fetch failed. GitHub merged the pull request; that is settled, and a stale local `main` cannot un-settle it. Making the state conditional would leave an entry whose work is already on `origin/main` reporting something retryable, and `pr merge` would then refuse it (the gate admits `pr_open` only) with nothing left to retry. Two separate signals on purpose: the state says where the work got to, the step row says what the operator still has to reconcile.

**Known gap: `merging` can strand on a double failure.** `merging` is transient in both directions — forward to `merged`, back to `pr_open` when `gh pr merge` fails. The one way to be stuck in it is for that restoring `queue_close_record` to fail as well (entry file gone or unwritable), because `merging` is not in `queue_pr_merge_allowed`'s admitted set, so the retry would be refused; the recovery is `set-close`. This is the price of every `queue_close_record` on the path carrying `|| true` — reporting must never decide whether a branch merges (parity row 67) — and the solo path has the identical window. Recorded rather than designed away.

**The runner and CLI call sites are covered structurally, not behaviourally.** `runner.sh` parses argv and enters a daemon loop at load; `queue-cli.sh` dispatches on `"$1"`. Neither can be sourced, so `test-pr-manager.sh` PR.25 greps the shipped source for the call sites instead. That catches a green `pr-manager` that nothing ever calls — the failure the suite would otherwise miss entirely — but not a call site passing the wrong entry, and the daemon poll has no behavioural coverage at all. Recorded here as a known gap rather than left implied.

---

## v1.10.0 — Close State and Solo Controls

**Date:** 2026-10-23
**Decision:** t-0057 (Close Pipeline Controls), brief 1 of 3

### Changes

**queue-entry.yaml** (+4 fields):
- `close_state` (string, default: `""`) — where the close pipeline has got to: `waiting`, `ready`, `held`, `rebasing`, `reverifying`, `merging`, `pushed`, `pr_open`, `merged`, `conflict`, `reverify_failed`, `handed_off`. **Derived state, not operator input** — absent from `queue_edit`'s allowlist, like `held_by`.
- `close_path` (string, default: `""`) — `solo` or `pr`: how this entry's work reaches main. `""` means not yet decided.
- `close_steps` (list, default: `[]`) — one row per step, `{"step","status","at","detail"}`, in the order they ran. `status` is `running | done | failed | skipped`. Appended by `queue_close_record`; absent from `queue_edit`'s allowlist.
- `merge_hold` (boolean, default: `false`) — the operator has held this entry's merge. Set and cleared only by `hold-merge` / `hold-merge --release`.

**The state is recorded, never inferred — except at exactly one site.** Every transition of the solo close path writes `close_state` as it happens, so a report shows where the pipeline actually is rather than a reader's guess about it. The one exception is an entry written before v1.10.0, which loads with the field empty: `queue_close_state` maps its `status` to a state (`completed` → `merged` on the solo path, `ready` otherwise; everything else → `waiting`) and nothing else in the codebase performs that mapping. Old entries therefore load and report sensibly without a migration, and there is a single place to change if the mapping is ever wrong.

**`close_path` is resolved from `solo_mode` but pinned on first use.** A reader with no stored value resolves `solo_mode: true` → `solo`, `false` → `pr`. The first close transition writes the resolved value onto the entry, so a later `set-close` changes where the work goes *next* and cannot retroactively rewrite the route the work already took.

**A hold is its own field, and `held` is only a rendering of it.** `held` is never written into `close_state`. The hold has to be placeable before an entry is `ready` — holding a non-final task-group brief holds the *next* brief's start — and `--release` must not have to restore a `close_state` it has no record of. So `merge_hold` is the single source of truth and `queue_close_state` renders `held` from it, never over a finished state (`merged`, `pushed`, `pr_open`): holding an entry that already merged must not relabel history. **Superseded in v1.11.0:** "a finished state" turned out to be the wrong criterion — the rendering must also leave `conflict` and `reverify_failed` alone, which are refusing rather than finished. See v1.11.0 above.

**Merge is fail-closed (Decision t-0061).** `queue_close_merge_allowed` admits a merge only from `ready` or `held`, and only when the entry is `completed`, close-time re-verification did not fail (`reverified: false` refuses; `""` means it never ran, which is not a failure), no criteria verdict in the session's `criteria-verdicts/<session-id>.yaml` is `PARTIAL`, `INCONCLUSIVE` or `FAILED`, the entry is the final brief of its task group, and `close_path` is `solo`. It prints the reason it refused rather than guessing.

**`close_steps` is stored verbatim, the way `overlap_files` is.** It is written as a single-line flow sequence that is simultaneously valid YAML and valid JSON — YAML 1.2 being a JSON superset — rendered once by `queue_close_step_json` and round-tripped as opaque text by `_load_queue_entry`/`_write_queue_entry`. Nothing parses it back. A step `detail` carrying newlines, tabs or quotes is folded and escaped at render time, so a conflicted-file list cannot break the entry file.

**Three failure sites have no matching enum value, and all three record `ready`.** A merge-lock acquisition failure, a merge that fails without a conflict, and a branch type the solo path will not merge are each retryable, so they record `ready` with the distinction carried in the step row's `detail`. `conflict` would refuse the retry and `merging` would strand the entry; neither is true of these.

**Task groups close once, at the last brief (Decision 0015 §3).** An earlier brief records `close_steps` for `commit` and `contract` and ends at `close_state: handed_off`. `merge`, `set-close` and the PR commands refuse any brief that is not final. The finality predicate moved to `queue_is_final_taskgroup_entry` in `queue-manager.sh` and the runner's `_is_final_taskgroup_entry` now delegates to it — a copy would have left the seal gate and the merge gate free to disagree about when a group branch may reach main.

---

## v1.9.0 — Follow-ups

**Date:** 2026-10-23
**Decision:** t-0055 (Operator Session Control), clause 14

### Changes

**queue-entry.yaml** (+0 fields — two semantic changes):
- `follow_up_of` is now **populated**. v1.8.0 declared and round-tripped it against this brief; `follow-up-entry <parent-id> --brief <path>` writes it. It is set once, at creation, and is deliberately absent from `queue_edit`'s allowlist: re-parenting an entry would invalidate the `followup-<parent-id>-<n>.md` brief filename that records the same link on disk, leaving two sources of truth that could disagree.
- `branch` on a follow-up is created **empty on purpose** and resolved at dequeue. See below.

**Linkage is one forward pointer, and the reverse direction is a scan.** `show --json` on a parent reports `follow_ups: [{id, status}]`; that array is computed by scanning the queue for entries whose `follow_up_of` matches, not read from a field. t-0055 clause 14 rejects a stored back-pointer list because it would have to be kept in sync by whoever creates the child, and because the set of follow-ups is a query over the queue rather than a fact the parent owns. On a follow-up, `show --json` and `list --json` report the flat `follow_up_of`.

**Where a follow-up runs is decided at dequeue, not at creation.** The parent's branch may be live, merged or sealed by the time the follow-up reaches the front of the queue, and only one of those answers is right:

| Parent's branch at dequeue | Resolved branch |
|---|---|
| Exists and is not an ancestor of `main` | the parent's branch — the follow-up continues it |
| Merged into `main`, or deleted/sealed | `follow-up/<parent-slug>-<n>`, cut from current `main` |

The resolved value is written back to the entry before it transitions to `running`, so `show` reports the branch the session actually used and the runner consumes `branch` unchanged — there is no follow-up-specific branch logic in the runner.

**A follow-up never overtakes its parent.** `queue_dequeue` skips any entry whose `follow_up_of` names a parent that is not `completed` and still exists. That covers every row of the table above with one predicate: queued, running, stopped, review and blocked parents all hold the follow-up, and a parent that has been pruned away releases it rather than stranding it forever. The existing hold machinery is complementary, not redundant: `_hold_release_ok` condition (d) is what stops a follow-up being *released* from a stopped parent's hold, while this guard is what stops one being dequeued ahead of a parent that was never stopped at all.

**`discard-entry` escalates follow-ups it was not holding.** v1.8.0 wrote one `parent-discarded` escalation per entry in `queue_hold_holding`. That list only ever contains `approved` entries, so a follow-up still sitting in `pending-review` when its parent was discarded got nothing. The held list and the direct-follow-up list are now unioned and deduped before the escalations are written. No new escalation type: `parent-discarded` already says exactly this.

**`follow-up-draft <parent-id> [--json]`** prints a draft brief and queues nothing. It gathers what the parent left undone from four sources, because no one of them is populated for every parent: unchecked `- [ ]` lines in the parent brief's verification section; `PARTIAL` and `INCONCLUSIVE` criteria in the parent session's `docs/ai/governance/criteria-verdicts/<session-id>.yaml`; the entry's `error_log`; and any escalation naming the entry. The parent's goal is carried over as context. The operator edits the draft and passes it to `follow-up-entry` — nothing reaches the queue without that step.

**Prompt assembly** gains a `## Parent task` section for any entry with `follow_up_of`, appended beside the `## Operator notes` section and built the same fail-open way.

---

## v1.8.0 — Hold the Line Behind a Stopped Entry

**Date:** 2026-10-22
**Decision:** t-0055 (Operator Session Control), clauses 9–11

### Changes

**queue-entry.yaml** (+3 fields):
- `held_by` (string, default: `""`) — the id of the stopping/stopped/discarded entry that is holding this one back. **Derived state, not operator input:** it is recomputed from scratch by `queue_hold_evaluate` on every dequeue tick and is deliberately absent from `queue_edit`'s editable-field whitelist. A non-empty value makes the entry invisible to the dequeue selector.
- `independent` (boolean, default: `false`) — operator opt-out. An independent entry is never held and never even evaluated, for work known to be unrelated to anything that might stop. Set with `add --independent` or `edit <id> independent true`.
- `follow_up_of` (string, default: `""`) — the id of the entry this one follows up on. **Written by the v1.8.0 writer but populated by a later brief's `follow-up-entry`.** Round-tripped from the start on purpose: `_write_queue_entry` rewrites whole files, so a v1.8.0 process that loaded and rewrote an entry created by a later version would otherwise silently drop the pointer. The release predicate already reads it, so an entry that follows up on the stopped one is never auto-released.

**escalation.yaml** (+1 type, 10 → 11):
- `parent-discarded` — written for every entry still held by an entry the operator discards. The hold is released by the same command, but the work the entry was queued behind never landed, so its scope needs re-checking before it runs. Severity `blocking`.

**Release is a proof obligation, not a default.** While an entry is stopping or stopped, every entry *after* it in dequeue order (greater priority value, or equal priority and a later `created_at`) is held. It is released only when all four of these hold: its brief's `scope_files` are disjoint from the stopped entry's `scope_files` ∪ the files its branch has changed since `main` ∪ its worktree's uncommitted paths; its branch is neither the stopped entry's branch nor descended from it; it is not in the stopped entry's work order; and it is not a follow-up of it. **An entry whose brief declares no `scope_files` can never satisfy the first condition** — unknown scope is treated as overlapping scope.

**Re-evaluated every tick, not computed at stop time.** The stopped branch's changed-file set grows while it is stopped, so an entry released on one tick can legitimately be held on the next. `queue_dequeue` therefore calls `queue_hold_evaluate` before it sorts, fail-soft: a hold-evaluation error must not stall the queue.

**`released` is derived, never stored.** `show --json` reports `hold: { holding: [...], released: [...] }`, where `released` is computed on read as "approved, after the holder, `held_by` empty". There is no second file to fall out of step with `held_by`.

**`show --json`** also gains a `session` block — `{ state, stopped_mode, brief_seq, started_at, elapsed_s, claude_session_id }` with `state` ∈ `running | stopping | stopped | not-running | closed` — and the flat `held_by` and `independent` members. `stopping` is the gap the control directory makes visible: a `running` entry whose control dir already holds a `STOP`, `FORCE` or `DISCARD` flag but whose child has not exited yet.

**`discard-entry <id> [--reason TEXT]`** moves a non-running entry to `failed/` with `error_log` set to the reason (default `discarded-by-operator`), writes a `DISCARD` flag to the control directory, releases every hold pointing at it and escalates each released entry as `parent-discarded`. Per Decision t-0054 it removes a single task's worktree (through `remove_session_worktree`, so uncommitted work is preserved as a patch first) but leaves a *group's* worktree in place and escalates the parent work order instead. It refuses a `running` entry and tells the operator to `stop-entry --force` first, rather than racing a live session.

---

## v1.7.0 — Operator Stop and Resume

**Date:** 2026-10-13
**Decision:** t-0055 (Operator Session Control)

**Numbering note (2026-10-22):** this entry was authored as v1.5.0 on the `task-details-header` branch while main independently shipped v1.5.0 (runner liveness) and v1.6.0 (turn budget). When the branch was replayed onto main it was renumbered v1.7.0 so the history stays linear; the `(v1.7.0)` tags in `queue-entry.yaml` and the note in `runner-config.yaml` follow it.

### Changes

**queue-entry.yaml** (+1 status, +2 fields):
- `status` enum gains `stopped` — an entry whose agent was stopped by the operator. Terminal for the daemon (it is not dequeued) but not for the work: the worktree and the Claude session survive, and `resume-entry` moves the entry back to `approved`. Total status count: 7 → 8, with a matching `queue/stopped/` directory.
- `stopped_mode` (string, default: `""`) — `graceful` (the agent ended itself at its next tool call) or `forced` (the runner signalled the child). Read when composing the resume message so a force-stopped session warns about the working tree.
- `resume` (boolean, default: `false`) — set by `resume-entry`, consumed and cleared by the runner at dequeue. Tells the runner to continue the recorded Claude session (`claude -p --resume <uuid>`) instead of minting a new one. Needed because the entry is back in `approved/` by the time the runner reads it, so its stopped history is no longer inferable from the directory.

**runner-config.yaml** (+1 field):
- `runner.stop_grace_seconds` (integer, default: `120`) — how long a graceful stop waits for the agent to reach a tool call before the runner escalates to a forced stop. Guards against an agent that is mid-thought, or looping without tool calls, never seeing the flag. Its comment sits ABOVE the key (see v1.5.0 on comment placement); the originally authored trailing comment contained `(` and would have made the field read as absent.

**Resume handle:** the `claude_session_id` needed to resume outlives the session record (`runner_external_cleanup` unregisters it at close), so the runner persists it to `.claude/.state/control/<entry-id>/resume.yaml`. This extends the t-0055 control-directory convention: an UPPERCASE bare filename is a flag whose existence is the signal; a lowercase filename is durable data.

---

## v1.6.0 — Turn Budget

**Date:** 2026-10-21
**Decision:** 0017 (Operator Automation Layer)

### Changes

**runner-config.yaml** (+1 field):
- `session_max_turns` (integer, default: `400`) — turn budget passed to `claude -p` as
  `--max-turns`. Must be greater than zero; a missing or non-numeric value falls back to the
  in-code default. Was a hardcoded `200` at both launch sites until 2026-10-21, when two
  multi-part briefs exhausted it after roughly 40 minutes each.

**Outcome vocabulary** (+1 detail): `review:turn-budget-exhausted`. A session that runs out of
turns exits ZERO, so one of those two briefs was classified `completed:clean-noop` and its
queue entry left the queue as though the work were done. The detector now checks the stderr for
the max-turns banner ahead of every success branch — including ahead of the new-commits branch,
because partial commits followed by exhaustion is the case that most resembles success.

**queue-entry transitions** (+1 command, no schema change): `queue-cli.sh reopen-entry <id>`
moves an entry from `review/` back to `approved/`, resets `retry_count`, clears its
`.defer-count-<id>` file, preserves the prompt that ran as `last_prompt`, and reopens its
parent work order. Added here because no transition out of `review/` existed for ANY `review:*`
outcome, which would have made the new detail a one-way door.

The work-order half is load-bearing, not incidental: every entry has a work order, a child in
`review` makes it `escalated`, and the runner's post-dequeue guard defers an entry whose work
order is escalated — three cycles, then `blocked/`. A reopen that cleared only the entry
therefore relocated the failure rather than clearing it. The reopen is **scoped**: a `single`
work order is reopened outright, but a `group` one is left alone when another child is still in
`review`/`blocked`/`failed`, because flipping the group to `open` would un-gate siblings the
guard is deliberately holding and would erase the group's `failure_entry_id` while the failed
sibling remains. In that case the command says so and points at `reopen-wo`.

**review-log-entry.yaml** (event enum reconciled): added `entry-reopened` for the new command,
and backfilled six names that were already being emitted and had never been listed —
`entry-blocked`, `entry-recovered`, `transition-failed`, `work-order-failed`,
`work-order-reopened`, `work-order-reconciled`. Nothing validates this enum mechanically, which
is how it drifted; the file now says to reconcile it with a diff against the call sites rather
than by eye, because the first pass at this missed `transition-failed` and miscounted the rest.

**Comment placement** remains part of the contract — see v1.5.0. The new field follows it.

---

## v1.5.0 — Runner Liveness: Session TTL and Circuit Breaker Cooldown

**Date:** 2026-10-20
**Decision:** 0017 (Operator Automation Layer)

### Changes

**runner-config.yaml** (+2 fields):
- `circuit_breaker_cooldown_seconds` (integer, default: `1800`) — seconds after the breaker trips before ONE probe entry is allowed. The failure count is not cleared, so a failed probe re-trips for another window. `0` disables expiry; recovery is then `queue-cli.sh reset-breaker` only. A missing or non-numeric value falls back to the default; a breaker whose own state is unreadable stays tripped (fails closed).
- `session_max_ttl_seconds` (integer, default: `21600`) — per-session elapsed-time cap in seconds; `0` disables it. Implemented 2026-04-04 but never recorded here, so this entry backfills it.

**Comment placement is part of the contract for both.** `_parse_config_field` takes everything after `<field>: ` as the value, so a trailing comment is concatenated onto it and — if it contains `(`, `)`, `;`, `&`, `|`, `$` or a backtick — rejected by the metacharacter sanitiser, leaving the field to read as ABSENT and silently fall back to the hardcoded default. Both fields shipped with that defect in `config.yaml` and were repaired on 2026-10-20 by moving the comments above the keys. Keep comments on their own line when adding any field.

**No reader changes required.** Both fields are optional with in-code defaults, so a `config.yaml` without them behaves as before. `queue-cli.sh` gains `reset-breaker` (no schema surface).

---

## v1.4.0 — Work Metadata: Project and Milestone

**Date:** 2026-10-12
**Decision:** 0017 (Operator Automation Layer)

### Changes

**work-order.yaml** (+2 fields):
- `project` (string, default: `""`) — free-text project name shown in the Task details header. Optional; YAML without this field loads unchanged.
- `milestone` (nested object, default: all empty/zero) — milestone info rendered as "Milestone 01/06" in the UI. Three sub-fields: `name` (string), `index` (integer, 1-based position), `total` (integer, total count).

**queue-entry.yaml** (+2 fields):
- `project` (string, default: `""`) — per-entry project override. Entry value wins over work order value; empty defers to work order.
- `milestone` (nested object, same shape as work order) — per-entry milestone override. Entry wins over work order; all-zero/empty defers to work order.

**Resolution rule:** Entry fields win → work order fields win → empty. `show --json` and `list --json` return resolved values. For task groups, project and milestone are set once on the work order; all child entries inherit via resolution.

**queue-cli.sh** — `add` gains `--project`, `--milestone-name`, `--milestone-index`, `--milestone-total`. `edit <id> project|milestone.name|milestone.index|milestone.total <value>` works on entries; use `--work-order` flag to edit the parent work order instead.

---

## v1.3.0 — Stale-Branch Escalation Type

**Date:** 2026-03-28
**Decision:** 0013 (Session Branch Isolation)

### Changes

**escalation.yaml** (+1 type):
- `stale-branch` added to `type` enum — used for crashed sessions where the branch is left unsealed for operator investigation, and for orphan branch detection during cleanup. Total type count: 9 → 10.

---

## v1.2.0 — Post-Audit Remediation Trigger

**Date:** 2026-03-26
**Decision:** 0017 (Operator Automation Layer)

### Changes

**runner-config.yaml** (+2 fields):
- `runner.auto_remediation` (boolean, default: `false`) — opt-in toggle for automatic remediation queue entry generation after audit sessions complete with actionable health report findings.
- `runner.auto_remediation_severity` (string, default: `CRITICAL`) — severity filter for findings extraction. Accepts `CRITICAL` or `CRITICAL,RECOMMENDATION`.

**New module: `lib/remediation-trigger.sh`** — sourced by `runner.sh`. Single public function `check_remediation_trigger` called in the `completed)` post-transition block after `check_cohesion_triggers`. Reads the newest health report, extracts findings by severity, deduplicates against existing queue entries, caps at 3 remediation entries per audit, and enqueues grouped findings as `standard` session type.

**cohesion-trigger.sh** — `_check_line_threshold` now accepts an optional `brief_path` parameter and skips line-counter increment for remediation sessions (entries whose brief contains `[remediation-source:]`). This prevents remediation-audit-remediation feedback loops.

---

## v1.1.1 — Work-Order Deferral

**Date:** 2026-03-20
**Decision:** 0017 (Operator Automation Layer)

### Changes

**review-log-entry.yaml**: Added `entry-deferred` to event enum. Emitted when an entry is deferred because its parent work order is escalated (sibling in review/failed/blocked).

**queue-manager.sh**: Added `queue_defer()` — moves running entry back to approved without retry increment.

**work-order-manager.sh**: Added `wo_is_escalated()` — lightweight status check for work order escalation.

**runner.sh**: Added work-order deferral guard in daemon loop — defers entries belonging to escalated work orders.

---

## v1.1.0 — Work Order & Review Log

**Date:** 2026-02-28
**Decision:** 0017 (Operator Automation Layer)

### Schemas

| Schema | Purpose |
|--------|---------|
| `work-order.yaml` | Groups related queue entries into an operator-visible unit. Status: `open` -> `completed` / `escalated` |
| `review-log-entry.yaml` | NDJSON line shape for the review log event stream. Daily files: `review-log-YYYY-MM-DD.jsonl` |

### Fields

**work-order.yaml** (8 fields): id, type, label, entry_ids, status, created_at, updated_at, completed_at

**review-log-entry.yaml** (7 fields): seq, timestamp, event, work_order_id, entry_id, summary, detail

**queue-entry.yaml** (+1 field): work_order_id (optional, v1.1.0)

**runner-config.yaml** (+1 field): retention.review_log_days

---

## v1.0.0 — Initial Schemas

**Date:** 2026-02-27
**Decision:** 0017 (Operator Automation Layer)

### Schemas

| Schema | Purpose |
|--------|---------|
| `queue-entry.yaml` | Single automation task in the queue. State machine: `pending-review` -> `approved` -> `running` -> `completed`/`failed`/`review`/`blocked` |
| `escalation.yaml` | Operator-directed escalation from a runner. Six escalation types covering all runner failure modes |
| `blocker-report.yaml` | Runner-written failure report with stderr capture, git status, and analytics events |
| `runner-config.yaml` | Operational configuration for automation runners. Master toggle, retry limits, retention policy |

### Fields

**queue-entry.yaml** (14 fields): id, status, session_type, branch, brief_path, prompt, auto_mode, solo_mode, retry_count, max_retries, error_log, created_at, updated_at, completed_at

**escalation.yaml** (11 fields): id, queue_entry_id, type, severity, phase_at_exit, tag_at_exit, message, context, created_at, resolved, resolution

**blocker-report.yaml** (12 fields): id, queue_entry_id, timestamp, type, exit_code, branch, phase_at_exit, tag_at_exit, stderr_tail, git_status, analytics_events, resolution (nested: status, notes, resolved_at)

**runner-config.yaml** (9 fields): runner.enabled, runner.default_auto_mode, runner.default_solo_mode, runner.max_retries, runner.heartbeat_interval, runner.stderr_tail_lines, runner.cohesion_trigger, retention.queue_days, retention.report_days, retention.escalation_days
