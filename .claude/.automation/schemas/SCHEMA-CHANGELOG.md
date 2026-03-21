# Schema Changelog

## Deprecation Policy

Schemas follow a 2-version support window:
- **Deprecated in N**: Schema field or structure marked deprecated. Runners must handle both old and new forms.
- **Removed in N+2**: Deprecated field/structure removed. Runners using old form will fail.

Breaking changes (field removal, type change, required field addition) increment the major version. Additive changes (new optional fields) increment the minor version.

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
