# Schema Changelog

## Deprecation Policy

Schemas follow a 2-version support window:
- **Deprecated in N**: Schema field or structure marked deprecated. Runners must handle both old and new forms.
- **Removed in N+2**: Deprecated field/structure removed. Runners using old form will fail.

Breaking changes (field removal, type change, required field addition) increment the major version. Additive changes (new optional fields) increment the minor version.

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
