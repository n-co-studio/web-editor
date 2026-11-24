# Decision t-0086 — The hook writes the Gates-A line; queue runs take their contract from the brief

**Status:** Accepted
**Date:** 2026-11-23
**Files:** `.claude/hooks/pre-commit-gates.sh`, `.claude/.automation/git-hooks/commit-msg`,
`.claude/.automation/lib/gates-a-trailer.sh`, `.claude/.automation/lib/queue-manager.sh`,
`.claude/.automation/runner.sh`, the queue-run templates and prompts (B, F, H, T), `AI.md`.

## Triggers

- type: file
- path: `\.claude/\.automation/lib/gates-a-trailer\.sh|\.claude/\.automation/git-hooks/commit-msg`
- keywords: `gates-a-result, gates-a-trailer, runner_install_brief_contract, queue_entry_contract_ok`

## Context

Two limits recorded by Decisions t-0072 and t-0078:

- **The `Gates-A:` trailer was the agent's word.** The commit gate runs A1–A6 and blocks on a
  failure, but the line saying which checks passed was typed by the agent. It could say `pass`
  for a check that did not run or did not apply, which is what happened with A6 (t-0078).
- **A queue run's contract was the agent's file (R58).** Nothing wrote
  `.claude/local/task-contract.yaml` for a queue run except the agent, and nothing stopped it
  editing the file afterwards. t-0072's binding of the contract to plan approval never ran
  headless, because the runner's pre-written `plan-approved` has no `contract_sha`. The scope
  gate's out-of-scope message told the agent to add the file to the contract, and its escalation
  had an empty entry id, so the runner never saw it.

The operator decided that the hook writes the result line, and that queue-run contracts come
from briefs: always ask when one is missing, and never let the agent widen its scope.

## Decision

### Part 1 — the Gates-A line

1. **The gate records outcomes.** `pre-commit-gates.sh` tracks each A check as it runs:
   - `pass`: it ran and passed.
   - `n/a`: it does not apply here. Examples are A5 for a session type with no review phase or on
     a hotfix branch, A6 outside a task group, and A1 when nothing is staged.
   - `skip`: it would apply but did not run. Examples are `REPO_OS_RECOVER` or the recovery
     signal, an experiment branch or an editor-live loop commit, `SKIP_CONTRACT_CHECK`, and A3
     with none of its parts configured.
   - `advisory`: it ran without blocking power, or failed where it only advises. Examples are A1
     without the `.a1-triggers-enforced` sentinel, and the A3 grep fallback or an interactive
     A3.4 failure.

   A3 is `pass` only when at least one of its parts actually ran (token check, tsc, package
   scripts). A4 is always `pass` on an allowed commit. The reasons for a skip are printed with
   the gate's output, as before.
2. **The gate saves a record on every commit it allows.** It writes the record from `_finish` to
   `.claude/.state/gates-a-result`, holding the staged tree (`git write-tree`) and the line.
   `.claude/.state` is already closed to agent writes (t-0071, t-0073), so the record is the
   gate's word. A blocked commit writes no record.
3. **The `commit-msg` git hook writes the trailer.** It calls the synced script
   `.claude/.automation/lib/gates-a-trailer.sh`, so later changes need no reinstall. The script
   removes every `Gates-A:` line from the message, then works as follows:
   - **The record's tree equals the tree being committed:** it adds `Gates-A: <the record's
     line>`. `write-tree` honours `GIT_INDEX_FILE`, so `git commit -a` is compared correctly.
   - **No record, or a record for another tree, in an agent commit (`CLAUDECODE=1`):** it adds
     `Gates-A: unchecked`. This is what a `git add` chained into the commit call, or `commit -a`,
     produces, because the gate ran before those staged anything.
   - **No matching record in a human commit:** the message is left alone.
   - **A record line that is not the gate's exact format:** it is treated as no record.
   - **Any failure:** the message stays as it was. The script never blocks.

   There is no clock and no consumption. The sandbox cannot delete under `.claude/.state`, and
   the tree already ties the record to exactly the content the gate checked, so a repeat commit
   of the same tree carries the same true line.
4. **The agent stops writing `Gates-A`.** The templates, Prompts B, F and H, and the workflow
   docs say so. `Gates-B` is unchanged. The t-0078 `A6-pass` refusal stays as a backstop for a
   child that has not reinstalled the hook yet.

### Part 2 — contracts from briefs

5. **Which runs, and where the contract comes from.** Queue entries of session type `standard`,
   `hotfix` or `taskgroup` need a file list. It comes from the first fenced YAML block of the
   brief's `### Task Contract` section, the block Prompt T already writes, and it must list at
   least one `scope_files` path.
   - Other session types (spec, finish-loop, governance closes) have no file scope and are
     unchanged.
   - The `.contract.yaml` sidecar is not read: nothing in code ever read it, and the embedded
     block is what `_parse_brief_scope_files` uses.
6. **Ask when missing, twice.**
   - `queue-cli.sh approve`, which also covers `approve-wo`, refuses such an entry whose brief
     lists no `scope_files`, naming the brief.
   - The runner checks again just before starting an entry. This covers auto-approved entries,
     entries approved before this rule, and briefs edited since approval. An entry that fails is
     moved to `blocked` with the same reason, and no session starts.
7. **The runner writes and binds the contract.** Before launch it writes the block, under a
   two-line header, to the run's `.claude/local/task-contract.yaml`. That is the worktree's, and a
   previous brief's contract in a reused task-group worktree is overwritten. It then sets
   `contract_sha` in the run's `plan-approved` to the digest `plan-approval.sh` would record. The
   existing t-0072 check at the commit gate refuses any commit once the contract no longer
   matches.
   - In a queue run that refusal tells the agent to stop, not to re-approve.
   - It writes an escalation carrying the entry id, so the entry goes to `review`.
8. **A file outside the list stops and asks.**
   - In a queue run, the scope gate's out-of-scope block tells the agent not to edit the contract
     but to stop and end the session.
   - Its escalation now carries the entry id, so the outcome detector reports
     `review:scope-deviation`. The operator adds the file to the brief and approves again, or
     declines.
   - In a queue run a file in the same folder as a listed one is out of scope too. Interactively
     such a file is still only advisory ("unbriefed-in-scope").
   - Interactive sessions keep the old message.
   - The runner never installs an unbound contract: with no `plan-approved` to bind it to, or an
     empty one, the install is refused. It also refuses a symlinked `.claude/local`, and replaces
     a contract path left as a symlink rather than writing through it.
   - t-0078's block on a queue-run commit with no contract now covers hotfix and taskgroup as well
     as standard, so a contract that failed to install never leaves a run unchecked.
   - The out-of-scope file name written into an escalation has quotes, backslashes and control
     characters removed, so a crafted file name cannot add YAML keys.
9. **Prompt T** says every queued brief, task-group briefs included, needs a `### Task Contract`
   block with `scope_files`.

## Consequences

- A child needs `.claude/.automation/lib/install-hooks.sh` run once to get the new `commit-msg`.
  Until then its commits carry whatever the agent writes, and t-0078's backstop still refuses a
  false `A6-pass`.
- Briefs written by hand with a prose **Scope:** and no Task Contract block can no longer run in
  the queue as standard, hotfix or taskgroup entries. That is the point: the operator is asked
  first.
- Tests:
  - `test-gates-a-trailer.sh`: the script and real commits through the installed hook.
  - `test-brief-contract.sh`: the brief readers, approve, the runner's install and binding, and
    the runner wiring by position, because `runner.sh` cannot be sourced.
  - layer3: the record's outcomes, the queue-run scope and contract refusals, and the
    escalations.
  - gate-conformance: the real gate followed by the real `commit-msg`.

## Known limits

- The runner wiring is checked by line position, not by running the daemon loop.
- A human commit with no matching record keeps whatever `Gates-A` line its author wrote.
- `unchecked` says the gate did not check exactly these staged files. It does not say which
  checks would have failed.
- `Gates-B` is still the agent's word.
- The agent controls its own environment. A commit with `CLAUDECODE` cleared and files staged
  after the gate ran looks like a human commit, so its own `Gates-A` line survives.
  `git commit --no-verify` skips the `commit-msg` hook altogether. Both are visible in the
  transcript, but not in the commit.
- The scope check reads added, copied, modified and renamed files. A deletion is not checked
  against the list.
- An agent can still edit the contract on disk. It cannot commit afterwards, and the run goes to
  `review`.
