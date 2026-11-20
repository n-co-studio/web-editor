# Decision t-0077 — An operator STOP denies the call it interrupts; a child writes its own contract

**Status:** Accepted
**Date:** 2026-11-20
**Amends:** Decision t-0055 clause 6 (graceful stop) and Decision 0012 (child-mode carve-outs).
`.claude/hooks/operator-control.sh`, `.claude/hooks/_mode-guard-helper.sh`.

## Triggers

- type: file
- path: `\.claude/hooks/operator-control\.sh`
- keywords: `permissionDecision, operator stop, child task contract, task-contract.yaml child`

## Context

**STOP.** t-0055 has `operator-control.sh` end a headless entry with `{"continue": false}` from a
PreToolUse hook, promising the run ends "at a tool boundary — no partial edit". The first live
`claude -p` check (`.claude/tools/smoke-claude-continue-false.sh`, run by the operator on
2026-11-20, claude 2.1.328) showed the run does end there — but the Bash call the hook fired on
still executed first. The question park adds `hookSpecificOutput.permissionDecision: "deny"` to the
same output, and its call did not run (R61).

**Child contract.** The web-editor child reported (2026-11-13, three runs since) that a headless
queue run in child mode cannot write `.claude/local/task-contract.yaml`, which Prompt B requires
before `drift_check`: `is_carved_out`'s `template)` case lists the path, its `child)` case does not,
so the mode guard refused it. The run then either stopped with no edits or carried on without a
contract — and the A6 scope gate skips when the file is absent, so scope went unenforced silently.
Pre-seeding cannot help: the run works in its own worktree.

## Decision

1. **A STOP is also a deny.** `operator-control.sh` prints the park's shape for STOP and FORCE:
   `continue: false` with `hookSpecificOutput {hookEventName: PreToolUse, permissionDecision: deny,
   permissionDecisionReason}`. The interrupted call does not run; the run still ends. Exit 0 as
   before — the stop is carried by the JSON, not by exit 2.
2. **A child repo may write its task contract**: `is_carved_out`'s `child)` case gains the single
   fixed path `.claude/local/task-contract.yaml`, as in template mode. The rest of `.claude/local/`
   stays protected (Decision 0012: no `.claude/local/*`).
3. **Not decided here:** whether A6 should fail, rather than skip, when a session that ran from a
   queue brief has no contract (the handoff's optional item 3). It changes every queue brief; it
   waits until the carve-out has been seen working in a child run (known-issues R62).

## Known limits

- The STOP fix is verified against `claude -p` by the operator's live smoke run on the branch, not
  by an agent (t-0076: agents cannot launch `claude`). Done 2026-11-20 (claude 2.1.328): 7/7 PASS,
  operator-stop `first-command-ran=no`, `terminal_reason=hook_stopped`.
- The contract a child writes is still the agent's own file; t-0072's approval binding applies only
  where `plan-approval.sh` records the approval — headless runs carry the runner's approval, which
  has no `contract_sha` (R58).
