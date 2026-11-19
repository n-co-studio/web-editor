# Decision t-0072 — The task contract is the one the operator approved

**Status:** Accepted
**Date:** 2026-11-18
**Amends:** Decision 0020 / t-0020 (who may change the task contract, and when).
`.claude/hooks/plan-approval.sh`, `.claude/hooks/pre-commit-gates.sh`,
`docs/ai/prompts/prompt-b-product-build.md`.

## Triggers

- type: file
- path: `\.claude/hooks/plan-approval\.sh`
- keywords: `contract_sha, contract_previous_sha, contract_changed_since_approval`

## Context

`.claude/local/task-contract.yaml` holds the `scope_files` the commit gate checks staged files
against and the `verification` items the Critic must score (t-0071). In template mode the agent
may write it (`_mode-guard-helper.sh` carve-out; t-0020 has the agent write it at init), so an
agent could widen its own scope and criteria and the gates would check against what it wrote.

On 2026-11-18 the operator asked why each contract was being installed with `cp`. Checking showed
no hook or decision required it: the agent had been stating "I'm not allowed to widen my own
scope" as if it were a rule. The operator chose to make it real — once the plan is approved, a
change to the contract needs the operator's approval. What follows enforces that against the
agent's normal tools; Known limits lists the routes it does not cover.

A write-guard was rejected: the headless bundle path writes `plan-approved` from `drift_check`
before the agent seeds the contract from the bundle, and `write-guard.sh` is immune. Binding the
contract to the approval needs neither (Pragmatist review).

## Decision

1. **The approval records the contract.** When `plan-approval.sh` records an approval it writes
   `contract_sha:` — the first 16 hex of the SHA-256 of `.claude/local/task-contract.yaml`, or
   `absent`. It is computed when the answer arrives, so a write between question and answer is
   covered.
2. **A changed contract is said out loud.** When the approval replaces one that bound a different
   contract, `plan-approval.sh` also writes `contract_previous_sha:`, logs `contract_rebound`, and
   says on stderr that a changed contract was bound.
3. **The commit gate checks it.** When `plan-approved` carries `contract_sha`, the contract on disk
   must hash to it; a changed contract, or one created after an `absent` approval, blocks
   (`contract_changed_since_approval`, GATE-RECOVERABLE, override `REPO_OS_RECOVER=1`). The fix
   is a new approval, which re-binds.
4. **The flow.** The agent writes the contract **before** the plan question and shows its
   `scope_files` and `verification` items in the question (prompt-b). No `cp` hand-off. An
   amendment is a rewritten contract and a new approval.

Rider: `session-type-task-group.md` step 4 now says the operator removes a stuck lock under
`.claude/.state/` — t-0071's bash-guard refuses an agent's `rm` there.

## Known limits

This makes a changed contract **visible and blocking**; it does not make it impossible. It stops
an unprompted drift and an agent that edits the contract with its normal tools. It does not stop a
determined agent that edits state files by routes the guards do not see (below, and R2).

- **`plan-approved` itself is editable in place.** `sed -i` / `perl -i` on
  `.claude/.state/…/plan-approved` can rewrite `contract_sha` to match a widened contract, or delete
  the line so the check skips. Neither is a write target, so neither guard refuses it, and nothing
  is logged (security review, 2026-11-18). The same route edits any state file — a BLOCKED
  sign-off to APPROVED — so it undercuts t-0071 too. R2's class; recorded as R56. **Since
  t-0073** bash-guard refuses `sed -i`/`perl -i` (and other mutation verbs) on a state path;
  interpreters and variable-built paths remain.
- **Only `plan-approval.sh` binds, and other writers replace the file.** `plan-approved` written by
  `drift_check` / `bundle_to_plan_approved` (handoff bundle), `accept_draft_approval` (queued
  draft), `_headless-plan-approve.sh`, or the runner's `state-manager.sh` (every headless task)
  has no `contract_sha`, so the check is skipped — headless automation is outside it. Each replaces
  the whole file, so one that runs after an interactive approval drops the binding silently.
  `_headless-plan-approve.sh` has no `CLAUDE_HEADLESS` guard and can be sourced from an
  interactive agent's Bash call, which both drops the binding and self-approves the plan (the
  latter predates t-0072). Recorded as R56; **since t-0073** bash-guard refuses any agent command
  that sources or runs it, and **since t-0074** it is deleted.
- **The block outlives the plan-gate skip.** `REPO_OS_SKIP_PLAN_GATE=1` does not lift it (it is
  outside that `elif` chain); `REPO_OS_RECOVER=1` does.
- **Re-approval is not free.** An approval resets the phase, so after one Critic and QA must be
  earned again — cheaper to write the contract before the plan question, as Prompt B requires.
- **Re-approval re-binds.** An agent that rewrites the contract and asks a plan question gets the
  new contract bound when the operator says yes. The question is required to show the contract and
  the hook flags the change, but nothing checks that the question showed it.
- **The override is not only the operator's.** `REPO_OS_RECOVER=1` lifts the block, and an
  environment prefix on an agent's Bash call does not reach the hook (the gate reads its own
  environment; a daemon-launched session may carry it from the operator). But the recover signal
  (`.claude/.state/.recover-signal`) is reachable: `touch` is not a write target, and neither
  bash-guard nor write-guard refuses `touch .claude/.state/.recover-signal` (checked 2026-11-18;
  a redirect or the Write tool is refused). The signal lifts every state gate for the next guarded
  call, and two gate messages told the agent to create it (R13 recovery). This predates t-0072 and
  applies to every state gate — known-issue R55. **Since t-0073** bash-guard refuses `touch` (and
  any mutation) of a state path, and the messages send the operator.
- **An unreadable contract** hashes to `unreadable`, which the gate never treats as a match — even
  against an approval that recorded `unreadable` — so it blocks.
- **Task groups are not covered.** Their contract lives in the task-group contract YAML.
