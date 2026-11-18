# Decision t-0067 — Draft-first queue intake for Prompt T

**Status:** Accepted
**Date:** 2026-11-12
**Amends:** `docs/ai/prompts/prompt-t-task-definition.md` (Brief mode Step 4 and Rules),
`.claude/.automation/queue-cli.sh` (`add`, `approve`, new `approve-wo`, `draft-status`,
`draft-wait`), `.claude/hooks/_phase-helper.sh` (`taskdef-brief` write phases, new
`record_draft`, `accept_draft_approval`, `discard_draft`), `.claude/hooks/write-guard.sh`
(taskdef-brief gate), `.claude/hooks/bash-guard.sh` (draft self-approval guard).
**Related:** 0029 (taskdef-brief `approval` phase and `plan-approved`), 0038 / t-0043
(handoff bundles; `drift_check` as a second `plan-approved` provenance), 0017 (queue).

## Triggers

- type: file
- path: `docs/ai/prompts/prompt-t-task-definition\.md|\.claude/\.automation/queue-cli\.sh`
- keywords: `draft, pending-review, accept_draft_approval, discard_draft, record_draft, approve-wo, draft-wait, REPO_OS_TASKDEF_DRAFT`

## Context

Massimo, a desktop app that drives Repo OS, treats a task as a Draft until the operator
presses Submit, and Submit is the operator's approval of the brief as written. A Draft is a
queue entry in `pending-review`; Submit runs `queue-cli.sh approve <id>`. Prompt T Brief mode
had only one shape: everything waited on an in-session `AskUserQuestion`, and "Approve &
queue" wrote the brief and queued it already approved. There was no entry to show while the
brief was still being shaped, and no way for an approval made outside the session to release
it.

## Decision

1. **Draft intake.** In draft mode — the operator picks "Draft to queue" in Step 4, or the
   session starts with `REPO_OS_TASKDEF_DRAFT=1` — the session writes the brief, sidecar
   contract and bundle to `.claude/.automation/briefs/` right after Step 3 (Synthesize) with
   the existing naming, runs `queue-cli.sh add --brief <path>` without `--auto-approve` (the
   entry lands in `pending-review`, `auto_mode: false`), never starts the daemon, binds the
   entry to the session with `record_draft <entry_id>`, and reports the entry id.

2. **Revise in place.** While the entry is in `pending-review` the session edits the same
   files in place. The entry stores only `brief_path` and the runner reads the brief at
   dequeue, so the edited brief is what runs; the entry id never changes. There is no second
   copy of the brief.

3. **External approval.** Approval comes from outside the session: `queue-cli.sh approve <id>
   [--mode review|auto]`, or `approve-wo <wo-id> [--mode …]` for a task group. `--mode` sets
   the entry's existing `auto_mode` before the transition; without it the entry keeps the
   draft's `review`. The session learns of it through a background `queue-cli.sh draft-wait`
   (Claude Code gives the session a turn when a background command exits) and a
   `draft-status` check at the start of each operator turn. It then calls
   `accept_draft_approval`, which:
   - requires a `taskdef-brief` session in `synthesize` or `approval` with entries bound by
     `record_draft`, and every bound entry present and out of `pending-review`;
   - writes `plan-approved` with the fields `plan-approval.sh` writes (timestamp,
     question_hash — here a hash of the brief files —, large-scope, mode, session_id) plus
     `source: queue-draft` and `draft_entry_ids`, the third provenance after the
     AskUserQuestion hook and `drift_check` (0038);
   - takes the mode from the entries: `auto` only if every bound entry has `auto_mode: true`;
   - sets the phase mode and advances `approval` → `output`. The session then rewrites the
     bundle's `mode`, prints the summary and closes without asking again.
   `plan-approval.sh` is unchanged: the in-session gate works exactly as before.

4. **Discard.** If every bound entry is removed (`queue-cli.sh remove <id>`) while in draft,
   the session calls `discard_draft`, which deletes the files it bound — the brief, its
   sidecar contract and bundle under `.claude/.automation/briefs/`, plus any task-group
   bundles passed to `record_draft --also` under `.claude/local/task-groups/` — and ends with
   no output. Rule chosen: **clean up**, not "mark abandoned". `queue-cli.sh remove` itself
   still never deletes briefs: that is shared semantics for every queue consumer. A draft
   removed after its session has ended leaves its files in `briefs/` (known issue).

5. **The agent cannot approve its own draft.** In a `taskdef-brief` session, bash-guard blocks
   `queue-cli.sh approve`, `approve-wo`, and `add` / `follow-up` with `--auto-approve` until
   `plan-approved` exists
   — that is, until the operator approved in-session. The CLI paths are unaffected: "Approve
   & queue" runs after the AskUserQuestion approval, and a CLI operator who drafted first and
   then approves in-session approves the existing entry instead of adding a new one.

6. **CLI behaviour kept.** `Approve — *` and `Approve & queue (*)` are unchanged. "Draft to
   queue" is an extra Step 4 option. Its label contains no approval word, so
   `plan-approval.sh` does not treat it as an approval.

7. **Task groups.** Every brief is drafted as a `pending-review` entry in one work order:
   the first `add` creates it, the rest pass `add --work-order <wo-id>` (parallel content
   briefs would otherwise get a work order each). `approve-wo` approves every pending child
   under one queue lock, so the group is approved together. Task-group and parallel rules
   are otherwise as before — the final brief (or the merge brief) alone is `--solo`.

8. **Write phases.** `taskdef-brief` writes are allowed in `synthesize` (draft and revise) and
   `output` (the in-session queue intake), only under `.claude/.automation/briefs/`.

9. **No `..` in a write path.** `write-guard.sh` refuses any Edit/Write whose path has a `..`
   segment, in every session type. Its guards match path text, so
   `briefs/../../.state/<sid>/plan-approved` matched none of the protected prefixes and then
   passed the briefs/ allow — a Brief session could have written its own `plan-approved`
   (security review, reproduced in a sandbox; the state-guard half predates this decision and
   applied to every session type). Edit and Write take absolute paths, so no honest write needs
   one.

The self-approval guard (5) prevents the agent approving by accident or shortcut; it is not a
defence against deliberate obfuscation (indirection, sourcing the queue library), which is no
weaker than the agent's existing ability to call the helpers that write state.

No queue-entry field is added, so `queue-entry.yaml` is not bumped.

## Consequences

- A Massimo Draft exists from the moment the brief is first synthesized and stays attached
  to the session that wrote it until it is submitted or removed.
- Approval provenance is recorded: `source: queue-draft` in `plan-approved`.
- `queue-cli.sh approve` without `--mode` leaves `auto_mode` as it was, so existing callers
  see no change.
