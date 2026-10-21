# Session Type: Queue Triage

Prompt Q provides a conversational interface for reviewing and managing the automation queue. The operator speaks naturally; the agent translates intent into `queue-cli.sh` invocations and presents results conversationally.

Queue triage sessions are ephemeral — no files written, no session log entries, no commits. No gates. The session exists purely to inspect and act on queue state through conversation.

## Phase Initialization (Required)

Queue triage sessions MUST call `init_phase` at session start:

```bash
source .claude/hooks/_analytics-helper.sh && source .claude/hooks/_phase-helper.sh && init_phase 'queue-triage'
```

Phase sequence: `init → conversation → close`.

This is required so that:
1. The stop hook identifies the session as ephemeral and skips blocking close checks (Decision 0013)
2. The `pretooluse-permission.sh` hook has valid phase-state (fail-closed without it — Decision 0027)

Phase-state writes use shell I/O, which bypasses write-guard (Decision 0014).

## Constraints

- **No product code changes.** Prompt Q never writes application code, tests, specs, or documentation.
- **No session log entries.** Queue triage is ephemeral — zero-change by design.
- **Bash restricted to queue operations.** Only `queue-cli.sh` invocations and reading escalation/report files under `.claude/.automation/`.
- **Destructive commands require confirmation.** `approve`, `remove`, `edit`, `halt`, `force-halt`, `resume`, `reset-breaker`, `reopen-wo`, `reopen-entry`, `prune` — ask the operator before executing.
- **No in-session execution.** If the operator wants to act on a brief (e.g., "run this one"), redirect: "Copy the brief and open a new Prompt B session."

## Governance

- Decision 0014 (phase-aware flow model)
- Decision 0017 (automation layer governance)
- Decision 0027 (pretooluse fail-closed enforcement)
