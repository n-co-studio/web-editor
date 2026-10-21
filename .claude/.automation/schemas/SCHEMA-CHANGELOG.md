# Schema Changelog

## Deprecation Policy

Schemas follow a 2-version support window:
- **Deprecated in N**: Schema field or structure marked deprecated. Runners must handle both old and new forms.
- **Removed in N+2**: Deprecated field/structure removed. Runners using old form will fail.

Breaking changes (field removal, type change, required field addition) increment the major version. Additive changes (new optional fields) increment the minor version.

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
