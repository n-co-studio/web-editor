# Decision 0055 — Operator Session Control

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/(\.automation/(runner|queue-cli|lib/queue-manager|lib/work-order-manager)|hooks/(_analytics-helper|pretooluse-permission|posttooluse-context|operator-control|operator-notes))\.sh`
- keywords: `control_state, claude_session_id, control directory, get_control_dir, session_record_set, stop-entry, resume-entry, discard-entry, follow-up-entry, hold-the-line, operator note, note-entry, notes-entry, notes/delivered, STOP flag, FORCE flag, resume.yaml, stopped_mode, stop_grace_seconds`

## Decision

An operator can take control of a *single running queue entry* — stop it, force
it, resume it, discard it, leave it a note, or spin a follow-up off it — without
halting the daemon and without reaching into state by hand. Control is expressed
as **files in a per-entry control directory**, polled by the parties that can
act on them.

This decision specifies the whole design. It is implemented across briefs 2–6
of the `task-details-header` group; brief 2 builds only clauses 1–4.

### The record and the directory (brief 2)

1. **Session record control fields.** A launched entry's session record at
   `.claude/.state/sessions/<sid>.yaml` carries six additional top-level
   snake_case scalars:

   | Field | Meaning |
   | --- | --- |
   | `entry_id` | The queue entry this session is running. |
   | `work_order_id` | The work order the entry belongs to, or empty. |
   | `claude_session_id` | The UUID passed to `claude -p --session-id`; the handle a resume uses. |
   | `child_pid` | The pid of the `claude` process, cleared when it exits. |
   | `worktree` | The directory the session was launched in. |
   | `control_state` | `running`, `stopping` or `stopped`. |

   `runner.sh` writes all six before launch with `control_state: running`,
   updates `child_pid` once the child is backgrounded, and sets
   `control_state: stopped` when the child exits for any reason. Brief 3 adds
   the `stopping` transition.

2. **Merge-writes, not rewrites.** Every write to a session record replaces
   only the named fields and re-emits every other line verbatim, including
   lines it does not recognise. Readers treat an absent field as empty and
   return success, never an error. This is load-bearing in two directions: the
   runner writes the record *before* launch and the launched agent's
   `init_phase` calls `register_session()` *after*, so an unconditional rewrite
   on either side would drop the other's fields; and records written before a
   field existed must still load.

3. **`claude_session_id` is generated, not discovered.** The runner mints a
   lowercase RFC 4122 UUID and passes it as `claude -p --session-id <uuid>`.
   It is not scraped from a transcript path or a log line. If no UUID source is
   available the runner warns and launches without the flag; the entry then runs
   normally but is not resumable by id, and `claude_session_id` is empty rather
   than wrong.

4. **The control directory.** Per-entry control lives at
   `.claude/.state/control/<entry-id>/`, resolved through `get_main_repo_root()`
   — **never** `_REPO_OS_ROOT`. Inside a worktree session `_REPO_OS_ROOT` is the
   worktree root (Decision 0028), so a flag written by the operator in the main
   repo and a flag read by the session in its worktree would be two different
   files. The control directory follows handoff bundles, escalations and the
   daemon queue in resolving to the one shared root. The same rule applies to the
   session record accessors.

   Layout:

   ```
   .claude/.state/control/<entry-id>/
     STOP                 # request a graceful stop        (brief 3)
     FORCE                # escalate to a hard kill        (brief 3)
     DISCARD              # abandon the entry's work       (brief 4)
     notes/               # operator notes awaiting delivery (brief 5)
       <epoch>-<n>.md
       delivered/
         <epoch>-<n>.md
   ```

   Flag files are **uppercase bare filenames**, matching the existing
   `HALT` / `FORCE-HALT` daemon flags. Their content is advisory (a reason
   string); their *existence* is the signal. The entry directory is created at
   launch; `notes/` is created by the party that first writes a note, so an
   entry with no notes has no empty directory to interpret.

5. **Flags, not signals.** Operator control is file-flag driven and polled. A
   flag set while nothing is watching is still honoured when a watcher starts;
   a signal sent to a process that has already exited is lost. This mirrors the
   daemon's existing `HALT` / `FORCE-HALT` mechanism, and it is what makes
   `stop-entry` safe to run against an entry that is between turns.

### Stop, force stop and resume (brief 3)

6. **Graceful stop.** `stop-entry <entry-id>` writes `STOP` and sets
   `control_state: stopping`. A `PreToolUse` hook sees the flag on the next tool
   call and returns `{"continue": false, "stopReason": "<operator reason>"}`.
   The run ends at a tool boundary — no partial edit, no half-written file — and
   `control_state` becomes `stopped` when the child exits. The transcript is
   **not** deleted: the session stays resumable by `claude_session_id`. The
   `STOP` flag is removed by the stop path once the child has exited, so a
   stopped entry does not re-stop itself on resume.

   A stop is **not an outcome the session produced**, so the runner reads the
   flags before outcome detection and overrides the result: the entry moves to
   `queue/stopped/` with `status: stopped`, and its retry count, the circuit
   breaker and the failure counter are all left alone. The worktree, the group
   worktree lock and the Claude session survive. The per-session TTL clock is not
   paused but restarted — it is recomputed per launch, so a resumed entry gets a
   full TTL rather than the remainder of the one it was stopped in.

   **Close-phase guard.** The hook ignores `STOP` once the session's
   `current_phase` is `close`. Stopping inside close would leave the entry's work
   uncommitted and its branch unsealed, which is strictly worse than the handful
   of tool calls close costs. Nothing is lost by waiting: the flag stays set, the
   runner honours it when the child exits, and the entry still lands in
   `stopped/`. `control_state` stays `stopping` throughout, which the UI reads as
   "stopping after close".

7. **Force stop.** `stop-entry --force <entry-id>`, or a second `stop-entry`
   while a `STOP` is still pending, writes `FORCE`. A watcher started alongside
   the child sends `SIGTERM` to `child_pid`, waits 10 s, then sends `SIGKILL` —
   the same sequence as `FORCE-HALT`. Force stop makes no promise about tool
   boundaries, so it is the second choice, not the first. The entry still goes to
   `stopped/` and is still resumable; `stopped_mode: forced` records which kind
   of stop it was, so the resume message can warn about the working tree.

   **Grace-period fallback.** A graceful stop depends on the session making a
   tool call. The same watcher escalates a `STOP` it has seen for
   `runner.stop_grace_seconds` (default 120, `0` disables) by writing `FORCE`
   itself, so one code path performs every kill. "Stop, and force it if that does
   not take" needs no second operator action.

   **Clean-start exemption.** A force stop kills the child mid-edit, so the
   worktree is dirty by construction. The runner waives Decision 0054's
   clean-start check for exactly one case: the entry resuming into the worktree
   *its own* stop left dirty. Without the waiver "still resumable" would be false
   for every forced stop. The waiver is narrow — same entry, same worktree, only
   on the resume path — so a dirty tree still blocks every *other* brief, which
   remains the intended outcome.

8. **Resume.** `resume-entry <entry-id>` clears `STOP` and `FORCE` and moves the
   entry from `stopped/` back to `approved/` with `resume: true`. The flags are
   cleared *before* the entry becomes dequeuable, or the resumed session would be
   stopped again by its own first tool call. `resume: true` is a one-shot
   instruction: the runner clears it on the running copy before launch, so a
   crash mid-session cannot leave an entry permanently flagged for resume.

   The runner then relaunches with `claude -p --resume <uuid>` from the **same**
   worktree, with the message "Resumed by operator." plus, after a forced stop,
   "The previous session was force-stopped; check the working tree before
   continuing." The brief itself is not re-sent — it is already in the transcript
   the resume continues. Claude keys transcripts by working directory, so the
   runner asserts the launch directory matches the recorded one and falls back to
   a fresh session rather than resume into an empty transcript.

   **The resume handle is a file, not the session record.** `unregister_session()`
   deletes the record at close, and a stop runs the normal close path, so the
   record is gone by the time a resume reads it. The runner therefore writes
   `.claude/.state/control/<entry-id>/resume.yaml` (`claude_session_id`,
   `worktree`, `repo_os_session_id`, `stopped_mode`, `stopped_at`) when it honours
   a stop. This extends clause 4's convention: inside a control directory an
   UPPERCASE bare filename is a **flag**, a lowercase filename is **durable
   data**. The recorded `repo_os_session_id` is reused rather than re-minted, so
   the resumed session's commits carry the same `Session:` trailer as the work
   they continue. An entry with no handle, or a handle with no session id, still
   runs — from a fresh session, with a warning, rather than failing an entry the
   operator asked to resume.

### Discard and hold-the-line (brief 4)

9. **Discard.** `discard-entry <entry-id> [--reason TEXT]` writes `DISCARD` and
   moves the entry to `failed/` with `error_log` set to the reason (default
   `discarded-by-operator`). Discard does **not** delete the branch or the
   transcript — it marks the work abandoned and leaves the evidence in place for
   the operator. The worktree follows Decision 0054: a single task's worktree is
   removed through `remove_session_worktree`, which preserves uncommitted work as
   a patch first; a *group's* worktree is shared by every brief in the group and
   outlives any one of them, so it is left in place and the parent work order is
   escalated instead. Every entry still held by the discarded one is released and
   escalated as `parent-discarded` — the hold is gone, but the work it was queued
   behind never landed, so an operator has to re-check its scope before it runs.

   Discard **refuses a `running` entry** and tells the operator to
   `stop-entry --force` first. An earlier draft had it force-stop the entry
   itself; that races a live session against a queue transition for no gain,
   since the two-step form is one extra command and leaves the stop auditable on
   its own.

10. **Hold the line.** While an entry is `stopping`, `stopped` by operator
    action, or `DISCARD`ed, every entry queued **after** it is held. "After"
    means later in dequeue order: a greater priority value, or the same priority
    and a later `created_at`. A held entry carries `held_by: <entry-id>` and is
    invisible to the dequeue selector.

    This is deliberately wider than a sequential group. A stopped entry has an
    unfinished, possibly dirty worktree and an unmerged branch, and nothing about
    that is specific to group membership — any later entry touching the same
    files or branch would build on a half-finished predecessor. The hold is
    derived state, recomputed from queue and control-directory contents on every
    tick; it is **not** an operator-managed lock, so there is no hold to forget to
    release and `held_by` is deliberately absent from `queue_edit`'s editable
    fields.

    **Opt-out.** `independent: true` on an entry (`add --independent`,
    `edit <id> independent true`) exempts it from holds entirely. It is the
    operator's escape hatch for work known to be unrelated to anything that might
    stop, and the one place the hold yields to a human assertion instead of a
    proof.

11. **Automatic release.** Release is a proof obligation, not a default. A held
    entry is released — `held_by` cleared, the reason logged — only when **all**
    of these hold:

    - its brief's `scope_files` do not overlap the stopped entry's `scope_files`
      ∪ the files its branch has changed since `main` ∪ the uncommitted paths in
      its worktree;
    - its target branch is neither the stopped entry's branch nor descended from
      it;
    - it is not in the stopped entry's work order;
    - it is not a follow-up of the stopped entry (clause 14).

    **An entry whose brief declares no `scope_files` is never auto-released.**
    Unknown scope is treated as overlapping scope: there is nothing to prove the
    release with, and the entry's own brief is the thing that failed to say.

    **Re-evaluated on every dequeue tick, not computed at stop time.** The
    stopped branch's changed-file set grows while it is stopped, so an entry
    released on one tick can legitimately be held on the next. Evaluation is
    fail-soft: an error in the hold computation must not stall the queue.

    **Resolution clears the rest.** `resume-entry` clears every `held_by`
    pointing at the entry — whatever was waiting was only waiting on its outcome,
    and anything genuinely related is re-held by the next tick if it stops again.
    `discard-entry` clears them too and escalates each one, per clause 9.

    **`released` is derived, never stored.** `show --json` reports
    `hold: { holding: [...], released: [...] }`, where `released` is computed on
    read as "approved, after the holder, `held_by` empty". A stored list would be
    a second lock-shaped file that could disagree with `held_by`.

### Names

12. **Names.** `halt`, `force-halt` and `resume` (clear HALT) are unchanged and
    stay daemon-wide. Every new command takes an entry id and ends in `-entry`.

### Operator notes (brief 5)

13. **Note delivery.** `note-entry <entry-id> (--text TEXT | --file PATH)` writes
    `notes/<epoch>-<n>.md`. A `PostToolUse` hook drains the directory and returns
    the contents as
    `{"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "<notes>"}}`,
    so the note reaches the running session as context next to a tool result
    rather than as a new user turn. Delivered notes are **moved** to
    `notes/delivered/`, not deleted: delivery is observable after the fact, and a
    note is delivered exactly once. A note written to an entry that is not
    running stays queued and is delivered when the entry next runs.

    **Three routes, one history.** A note reaches the agent by whichever route
    the entry's state allows: `running` → the `PostToolUse` hook, at the next
    tool step; `stopped` → `runner.sh`, appended to the resume message; anything
    else → `runner.sh`, appended to the prompt when the entry starts. The last
    two share one drain function, so all three move what they delivered to
    `notes/delivered/` and `notes-entry` reports the same history whichever ran.
    The prompt and resume routes append **after** the brief, so a note reads as
    an amendment to the brief rather than a replacement for it.

    **`sent_at` is the filename; `delivered_at` is a sidecar.** A note body is
    plain operator text by contract and carries no metadata, so `sent_at` is
    derived from the `<epoch>` prefix of the filename and the delivering route
    writes an ISO-8601 UTC timestamp to `notes/delivered/<name>.md.at`. Putting
    either timestamp *inside* the note would mean parsing operator prose; a
    second index file would be a thing that can disagree with the directory.
    `epoch_to_iso()` in `_analytics-helper.sh` formats the first, portable
    across BSD `date -r` and GNU `date -d @`.

    **Two caps, for two different reasons.** A note is capped at **2,000
    characters** because it competes with the brief for the agent's attention —
    anything longer is a brief, not a note. The hook delivers at most **three
    notes per tool call** because it fires on every tool use and an unbounded
    `additionalContext` would bury the tool result the agent actually asked for;
    the rest arrive at the following steps, oldest first. The runner routes are
    uncapped: they run once, before the session starts, where there is no tool
    result to bury.

    **A closed entry is refused.** `note-entry` rejects a `completed` or `failed`
    entry and points at `reopen-entry`. The alternative is a note that is pending
    forever against an entry with no agent left to read it.

    **A work order id stands in for "the next brief".** With no brief of a group
    running, `note-entry <work-order-id>` resolves to the first non-terminal
    entry in the order's `entry_ids` — declaration order is brief order for a
    sequential group — and says on stderr which entry it picked. The operator
    should not have to look up an id for work the group has not reached yet.

    **Delivered text instructs, it does not waive.** Every route appends the same
    standing instruction: follow the note within the brief's scope, escalate
    rather than guess if it conflicts with the brief or a gate, governance gates
    still apply, and record the note and what was done about it in the session
    log. A note is the one control that *adds* context, and it must not be
    readable as a gate waiver.

    **`notes-entry <entry-id>` reads the directory, not the queue.** It takes an
    id and never looks the entry up, so a discarded or completed entry's note
    history stays readable. `--json` reports `pending` and `delivered` counts and
    a `notes` array of `{note_id, state, sent_at, delivered_at, text}` — the
    pending-vs-delivered distinction the Task details header renders.

### Follow-ups (brief 6)

14. **Follow-up linkage.** `follow-up-entry <entry-id>` creates a new queue
    entry carrying `follow_up_of: <parent-entry-id>` and a reason. The link is a
    **single forward pointer on the child**; the parent carries no list of
    children. A back-pointer would have to be kept in sync by whoever creates
    the child, and the set of follow-ups is a query over the queue, not a fact
    the parent owns. A follow-up is an ordinary entry in every other respect —
    it has its own work order membership, its own branch and its own gates.

    **`follow-up-entry <parent-id> --brief <path>`.** `follow-up` is the short
    alias. The parent may be in **any** status — a completed parent is the
    common case, since its gaps are what the follow-up is for. The brief is
    **copied** to `briefs/followup-<parent-id>-<n>.md`, where `<n>` is the
    lowest free number for that parent. The filename is the human-readable half
    of the linkage: `ls briefs/` answers "what follows what" without parsing
    YAML, and the dequeue selector reads `<n>` back out of it to name a branch.
    Copying rather than referencing means an operator editing their draft
    afterwards cannot change what an already-queued entry will run. `<n>` counts
    existing brief *files*, not live entries, so a pruned sibling cannot free
    its number and cause a collision.

    The new entry **inherits** the parent's session type, project, milestone,
    work order, solo/push flags, permission profile and priority, each
    overridable by a flag. It is never auto-approved by inheritance:
    `--auto-approve` must be given explicitly, because a follow-up is new work
    and the operator approving the parent did not approve it.

    **A follow-up of a follow-up points at the entry it extends**, not at the
    head of the chain. Flattening would misreport the dependency: the dequeue
    guard asks "is *my* parent done", and that is the middle entry.

    **Where it runs is decided at dequeue, not at creation.** `follow-up-entry`
    leaves `branch` **empty on purpose**, and `_followup_resolve_branch` fills
    it in — at the last moment before the entry runs — then writes the answer
    back to the entry, so `show` reports the branch the session actually used
    and the runner reads `branch` the same way for every entry. The four-row
    table the brief posed collapses to one question:

    | Parent's branch | Follow-up runs on |
    |---|---|
    | Exists and is not yet an ancestor of `main` | that same branch |
    | Merged, sealed, or gone | new `follow-up/<parent-slug>-<n>` from `main` |

    Row 1 covers a parent that is queued, running, stopped *or*
    completed-but-unmerged: all four still have commits reachable only from
    that branch, and in every one of them the follow-up continues the line.
    This **errs toward continuing**: if `main` cannot be resolved,
    `--is-ancestor` fails and we cannot prove the work landed. Continuing a
    branch that turns out to be merged costs an empty rebase; starting from
    `main` when the parent's work has *not* landed costs the follow-up its
    entire premise.

    **A follow-up never overtakes its parent.** The dequeue selector skips it
    unless the parent is `completed` or `missing`. This is a separate obligation
    from the hold of clause 10, which only fires when something was actually
    *stopped*: a parent that is merely queued or running stops nothing, yet
    running its follow-up first would build on work that does not exist.
    `missing` releases the follow-up so a pruned parent cannot strand it
    forever; every other state holds, on the same reasoning as the release
    predicate — a wasted tick is cheaper than a session built on a premise that
    never landed.

    **Discarding a parent escalates its follow-ups.** `discard-entry` unions the
    entries it was holding (clause 10) with its direct follow-ups and writes one
    `parent-discarded` escalation each. The hold list alone does not reach them:
    `held_by` is only ever set while the parent is stopped, so the follow-up of
    a *completed* parent — the most likely one to exist — is unheld.

    **`follow-up-draft <parent-id>` queues nothing.** It prints a brief skeleton
    to stdout, assembled from four sources of evidence that the parent left
    something undone: unticked `- [ ]` items in the parent's brief; criteria the
    completeness gate recorded as `PARTIAL`, `INCONCLUSIVE` or `FAILED` in
    `docs/ai/governance/criteria-verdicts/<session-id>.yaml`; unresolved
    escalations naming the entry; and the entry's own `error_log`. The parent's
    title and goal come along as context. It stops at printing because those
    four are evidence of a gap, **not** agreement that the gap is worth another
    session — that judgement is the operator's, and the draft says so in place
    of the goal.

    **The runner adds a `## Parent task` section** to a follow-up's prompt:
    parent id, status, branch, title, brief path, the commit range it left
    (`main..<branch>`, when the branch still exists outside main), its recorded
    outcome and its goal. It is appended after the brief and before any operator
    notes, so the prompt reads brief → background → amendment. It is skipped on
    a resume, where the transcript already carries it. The section tells the
    agent the parent's result is a governed outcome and that a conflict with it
    is an escalation, not a thing to silently reverse.

    **`follow_up_of` is not operator-editable.** It is absent from `queue_edit`'s
    allowlist, like `held_by` but for the opposite reason: `held_by` is derived
    state, whereas `follow_up_of` is part of the entry's identity. Re-parenting
    would invalidate the generated brief filename and the `<n>` the branch name
    is built from.

    **`show --json` links both directions.** The child carries a flat
    `follow_up_of`; the parent reports `follow_ups: [{id, status}]`, which is a
    **scan of the queue, not a stored field** — which is exactly why it cannot
    disagree with the pointer. `list --json` carries the flat `follow_up_of`
    only: a list is a view of many entries and the reverse direction costs a
    whole-queue scan per row.

## Verified Capabilities

The design depends on four CLI/hook behaviours. All four were confirmed against
the published Claude Code documentation before any of it was built:

- `--session-id <uuid>` — "Use a specific session ID for the conversation (must
  be a valid UUID)". Hence clause 3's insistence on a well-formed UUID.
- `--resume <uuid>` with `-p` — resume a session by id headlessly.
- `PreToolUse` returning `{"continue": false, "stopReason": "..."}` — `continue`
  and `stopReason` are *universal* hook JSON fields, not PreToolUse-specific.
- `PostToolUse` returning `hookSpecificOutput.additionalContext` — delivered
  alongside the tool result. `UserPromptSubmit` has no equivalent field and uses
  plain stdout, which is why clause 13 names `PostToolUse` specifically.

One documented behaviour is **stronger** than the design assumed:
`{"continue": false}` stops Claude from processing further but does **not**
delete the session. The transcript remains resumable by id. Graceful stop is
therefore built directly on it — stop-then-resume needs exactly a run that ends
cleanly while the session survives.

## Implication

- An operator reading a session record can answer, for any running entry: which
  entry and work order is this, what session id resumes it, what process is
  running it, where is it running, and is it running or stopped. That is the
  Task details header's data source.
- Control is reachable from either root. A tool run inside a group worktree and
  one run from the main repo touch the same control directory, so a flag written
  in one place is seen in the other.
- Briefs 3–6 implement against this document. They are not expected to
  re-litigate the flag names, the directory layout, the note delivery contract
  or the linkage direction. The hold rule is the one exception: brief 4 widened
  clauses 9–11 from a sequential-group hold to a queue-wide hold with a
  four-part release proof, and the text above is the shipped rule, not the
  original sketch.
- Session records are removed at close by `unregister_session()`, so the control
  fields describe *live* entries only. Post-hoc history belongs in the session
  log and the review log, not here.

## Known Limitations

**`worktree` and `worktree_path` coexist.** `register_session()` already writes
`worktree_path` for full worktree sessions (Decision 0030). Clause 1 adds
`worktree`, written by the runner for *every* launched entry including
non-isolated ones, and meaning "the directory this entry was launched in". They
agree when both are present. They are not merged here because `worktree_path`
has existing readers and this brief does not own them; a later consolidation is
a reasonable follow-up.

**Two registry locations under worktree isolation.** `register_session()`
resolves its sessions directory through `_REPO_OS_ROOT`, so a worktree session
registers itself under the worktree while the runner's control record lives
under the main repo. The control record is the one the operator reads and the one
every accessor in clause 4 resolves to, so control works; but a worktree session
is described by two files rather than one. Routing `register_session()`,
`sweep_stale_sessions()` and `unregister_session()` through
`get_main_repo_root()` together would fix it and is deliberately out of scope
here — changing only the writer would leak records the sweeper could no longer
find.

**Graceful stop is tool-boundary granular, not instant.** An entry between tool
calls — mid-thinking, or streaming a long response — does not stop until its next
tool call. `--force` exists for operators who cannot wait. There is no mechanism
that interrupts a turn in flight without killing the process.

**Stop coverage is Bash and Agent tools only, pending an operator registration.**
The stop check lives in `.claude/hooks/operator-control.sh`, written so that
registering it as a `PreToolUse` hook with matcher `*` extends it to every tool.
That registration cannot be applied from inside a session: `.claude/settings.json`
is an immune path (`_mode-guard-helper.sh` `is_immune`) that no mode and no
override may edit — otherwise a session could dismantle its own hook chain.
Until an operator applies it, `pretooluse-permission.sh` delegates to the script
on its existing `Bash` and `Agent` matchers, which covers phase advances, git and
agent dispatch — where a governed session spends its tool calls. A session doing
only reads and edits is not covered; `stop_grace_seconds` (clause 7) is the
backstop for exactly that case. For the same reason the new hook file is mode
`644` rather than `755` — `chmod` is not on the headless Bash allowlist — so the
registration an operator applies must invoke it as `bash .claude/hooks/operator-control.sh`.

**The running-session note route is inert until an operator registers it.**
`.claude/hooks/operator-notes.sh` is written, tested and mode `644`, and it is
registered nowhere. It needs a `PostToolUse` entry with matcher `*` in
`.claude/settings.json` — an immune path — and `chmod +x`, neither of which a
session can do, for exactly the reasons given above for `operator-control.sh`.
Unlike the stop check there is **no delegation fallback**: the existing
`PostToolUse` hook could have been taught to call it, which is the same shape
brief 3 used for the stop check, but that route was deliberately not taken here
— registering a hook from inside a session by proxy is the hole the immune path
exists to close, and taking it once makes it precedent. So until an operator
applies both steps, routes 2 and 3 (prompt and resume message) work and route 1
does not. The hook is tested by direct invocation with a crafted payload in
`.claude/.automation/tests/test-operator-notes.sh`, the same technique the layer
suites use.

**Delivered notes are not written to the session log by the hook.** Clause 13
asks for the note to appear in the session log. The hook cannot safely write a
tracked file mid-session — it fires on every tool call and would race the
agent's own edits — so the audit trail is three weaker things instead:
`notes/delivered/` is durable and timestamped, `log_hook_event` and
`review_log_append` record each delivery, and the delivered text *asks the agent*
to log the note. The first two are mechanical and the third is not, so a session
that ignores the instruction leaves the note out of its log. A close-time hook
that folded `notes/delivered/` into the session log would close this; it belongs
with the brief that owns the close path.

**The phase chain does not survive a stop; the transcript does.** A stop runs the
normal close path, and `runner_external_cleanup()` calls `cleanup_session_files()`,
which removes `phase-state`. The resumed session therefore re-enters at `init`
even though its transcript, its `claude_session_id` and its `REPO_OS_SESSION_ID`
all continue. The resume message says so explicitly and asks the agent to
re-advance the phases from where its work actually stands. Preserving mid-phase
state across a stop would mean teaching the close path which closes are
terminal — a larger change than this brief owns.

**The hold errs toward holding, and says so.** Three of its inputs fail soft or
approximate, all in the same direction. `_branch_descends_from` approximates "was
cut from" as "is an ancestor of", so a branch cut from `main` while the stopped
branch is still at `main` also answers yes and is held. A brief with no
`scope_files` is held forever by any stopper ahead of it. And an entry whose
branch does not exist yet contributes no changed files, so only its declared
scope is compared. Holding an unrelated entry costs a tick; releasing a dependent
one costs a broken build — but an operator who sees a queue stall behind a
stopped entry should check `show --json`'s `hold` block before assuming a defect,
and reach for `independent: true` when the entry really is unrelated.

**The hold is not a group hold.** Clause 10 originally reasoned about the shared
branch and worktree of a sequential group (Decision 0054). As shipped it is a
property of dequeue order, not group membership: a stopped *parallel* brief
(Decision 0032), which has its own branch, still holds later entries until each
proves itself disjoint. The work-order condition in clause 11 is what keeps a
sequential group's siblings held unconditionally; everything else is released on
evidence.

**A follow-up of a `failed` parent waits indefinitely.** The dequeue guard
releases a follow-up only when its parent is `completed` or `missing`, so a
parent that ends `failed`, `blocked` or `review` holds its follow-up in the
queue with no timeout. This is deliberate — a follow-up extends work that
landed, and work that failed may not have landed at all — but it means the
queue can hold an entry with nothing scheduled to unblock it. There are three
exits and the operator must take one: fix and re-run the parent to
`completed`; `discard-entry` the parent, which escalates the follow-up as
`parent-discarded`; or `remove` the follow-up. Nothing surfaces the situation
on its own: `show --json` on the follow-up names its `follow_up_of`, but the
state is not called out as a stall the way a `held_by` is. A dequeue-tick
warning, or a `review` listing for follow-ups of non-completed parents, would
close this.

**The commit range disappears once the parent's branch is sealed.** The
`## Parent task` section reads `main..<branch>`, which is empty — and therefore
omitted — as soon as the branch is merged into `main`. That is precisely the
case where the follow-up gets a fresh branch from `main`, so the agent is told
what the parent *was* but not which commits it produced. Recording the parent's
final commit SHA on the entry at close would fix it; that field belongs with
the brief that owns the close path, not this one.

**`<n>` is a filename counter, not a sequence number.** `follow-up-entry`
picks the lowest free `followup-<parent-id>-<n>.md`, and the dequeue selector
reads `<n>` back out of that filename to build a branch name. Deleting a brief
file by hand therefore frees its number for the next follow-up, which can give
two different entries the same branch name at different times. Brief files are
not normally deleted (`prune` reports them rather than removing them), and the
alternative — a counter stored somewhere — is a second thing that can disagree
with the directory. Noted rather than guarded.

## Alternatives Considered

1. **Signal the child directly instead of writing flags.** Rejected for
   graceful stop: `SIGTERM` to a `claude` process is a force stop by another
   name — it cannot wait for a tool boundary, and a signal sent while the
   process is between launches is simply lost. Signals remain the mechanism for
   clause 7, where abruptness is the point.

2. **One shared control directory keyed by session id.** Rejected: the operator
   and Massimo both address work by *entry* id — it is the identifier on the
   queue, in the work order and in escalation filenames. Session ids are minted
   per launch, so a resumed entry would need its flags moved to a new directory.

3. **Store control state in the queue entry rather than the session record.**
   Rejected: the queue is the *plan* and changes at operator pace; the session
   record is the *runtime* and changes per launch. Writing `child_pid` into the
   queue would make every poll a queue mutation and put volatile data in a file
   whose schema is versioned and synced to child repos.

4. **Deliver operator notes as a new user turn via `--resume`.** Rejected:
   it costs a full relaunch per note, reorders the conversation around a
   mid-flight tool call, and cannot reach a session that is already running.
   `additionalContext` reaches a live session in place.

5. **A back-pointer list of follow-ups on the parent entry.** Rejected per
   clause 14 — two places to update, one of which is a historical record that
   should stop changing once its entry is terminal.

6. **An explicit operator-managed hold flag.** Rejected: a hold the operator
   sets is a hold the operator forgets to clear, and a wedged group is a worse
   failure than a group that resumes a little too eagerly. Deriving the hold
   from `control_state` makes clause 11 free. `independent: true` is the one
   surviving operator input, and it is an *exemption* rather than a hold — a
   forgotten exemption lets work run, which is the failure direction a stall is
   not.

7. **Holding only entries that provably conflict.** Rejected as the default, and
   it is worth being explicit about the inversion: clause 10 holds everything
   after a stopped entry and releases on proof, rather than holding nothing and
   acquiring on proof. Scope evidence is incomplete by construction — a brief may
   declare no `scope_files`, and a stopped branch's changed-file set is still
   growing — so "no proof of conflict" is not evidence of safety. The default has
   to fail in the direction that costs a tick, not a build.

## Falsification Signals

Revisit this decision if any of these happen:

- `claude_session_id` is routinely empty on launched entries — UUID generation
  is failing on a supported platform and resume is dead in practice.
- Operators reach for `--force` more often than graceful stop — the
  tool-boundary stop is too slow to be useful.
- Graceful stops routinely escalate via `stop_grace_seconds` rather than being
  honoured at a tool call — the Bash/Agent-only coverage above is too narrow in
  practice, and the `*` registration needs applying rather than documenting.
- The queue stalls with every entry resolved — the derived hold of clause 10 is
  not releasing, and clause 11's "nothing to clear by hand" promise is false.
- Operators routinely set `independent: true` to get work moving — the release
  proof of clause 11 is too strict in practice, or too many briefs ship without
  `scope_files` for it to be provable at all.
- Notes accumulate in `notes/` without reaching `notes/delivered/` — the
  `PostToolUse` drain is not firing, and notes are silently lost rather than
  queued.
- The control directory is found at two different paths in one investigation —
  a caller has used `_REPO_OS_ROOT`, and clause 4 is being bypassed.

## Override

`REPO_OS_RECOVER=1` already permits hand-editing `.claude/.state/`, which
includes writing control flags and session records directly; that remains the
break-glass path and is not a control mechanism. There is no flag that disables
operator control — the control directory being absent is indistinguishable from
no flags set, which is the inert default.

## Amendment 1 — The Two Hooks Are Executable (2026-10-24)

**Status:** Accepted

This decision states twice that the two new hooks ship mode `644`, and that the
exec bit is beyond a session's reach: once for `operator-control.sh` ("the new
hook file is mode `644` rather than `755` — `chmod` is not on the headless Bash
allowlist — so the registration an operator applies must invoke it as `bash
.claude/hooks/operator-control.sh`"), and once for `operator-notes.sh`
("written, tested and mode `644` ... It needs a `PostToolUse` entry ... and
`chmod +x`, neither of which a session can do"). Both are now wrong on the mode,
and the second overstates the constraint.

**What changed.** Both files are tracked `100755`. The constraint was real but
narrower than written: `chmod` is absent from the *headless* allowlist in
`_permission-allowlist.sh`, not from an interactive session. These hooks were
authored in headless brief sessions, where it genuinely could not be run; an
interactive session can, and did.

**Why this is not cosmetic.** `.claude/settings.json` registers every hook by
**bare path**, never as `bash <path>`. A registered `644` hook is therefore
inert — the registration succeeds and the hook never executes. The bare-path
invocation form quoted above is a workaround for a missing exec bit, not the
convention. (`pretooluse-permission.sh` does call `bash` on
`operator-control.sh`, but for an unrelated reason: it delegates mid-hook,
before any registration exists.) The mode was a precondition for the very
registration this decision asks the operator to apply, so shipping `644` left
that registration unable to work even once applied.

**What still holds.** Everything else in the "inert until an operator registers
it" sections. `.claude/settings.json` remains an immune path; the registration
is still the operator's action and no session may write it. `operator-notes.sh`
is still registered nowhere, so the note route remains inert — the exec bit
clears one of its two blockers, not both.

**Enforcement added.** `gate-conformance.sh`, section "invoked hooks are
executable", now fails when any non-underscore hook directly under
`.claude/hooks/` is not `100755` in the index, so a hook cannot ship inert this
way again. The rule is one-directional (underscore-prefixed sourced helpers are
unconstrained, and several are legitimately `100755`) and template-only, because
`template-sync-engine.sh` carries no file modes: a newly added hook lands at the
child's umask default, a gap tracked as a follow-up rather than closed here.

## Amendment 2 — The Hook-Mode Check Now Covers Children (2026-10-25)

**Status:** Accepted

Amendment 1 added the `gate-conformance.sh` check that every non-underscore hook
is `100755` in the index, and restricted it to a template checkout, recording the
reason as a deferred follow-up: `template-sync-engine.sh` materialised each
synced file by redirecting `git show` into it, which carries no mode, so a hook
added to the template after a child was scaffolded arrived `644` and the child
could not fix it. Failing children on that would have been a red with no remedy.

**The restriction is lifted.** The engine now carries the exec bit where the
template's mode is `100755`, one-directionally so a child's own bit is never
stripped (known-issue R37). The check runs everywhere.

**Lifted on evidence, not on the fix existing.** Amendment 1's condition was that
a real child be observed receiving an exec bit through a sync, because a scratch
template/child pair proves the code path and not the delivery. Measured on
2026-10-25: before the mode-carrying engine reached them,
`markpreston2/markpreston.co` held **6** and `n-co-studio/web-editor` held **8**
non-underscore hooks at `100644`; after one sync each, **both hold zero**. Note
the ordering that made this a two-step rollout — the sync that *delivers* the new
engine still runs the child's old copy, so the modes apply on the sync after
that.

A child that trips this check now has a hook it added itself non-executable,
which it can fix, and which would otherwise be registered by bare path and
silently never run.

## Amends

Nothing. Decisions 0013 (branch isolation and sealing), 0017 (operator
automation layer), 0028 (worktree state isolation and the two-root divergence),
0030 (per-session state directories), 0032 (parallel task group worktrees),
0053 (signal fidelity) and 0054 (task group worktree lifetime) remain binding
and unchanged. This decision adds a control surface on top of them; it does not
alter the branch, worktree or phase models they define.
