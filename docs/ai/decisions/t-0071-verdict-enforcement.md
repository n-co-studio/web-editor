# Decision t-0071 — A review counts only if it checked something, and a block binds

**Status:** Accepted
**Date:** 2026-11-18
**Amends:** the A5 completeness check (Decision 0020 / t-0048) and the A4 high-risk sign-off;
closes item 2 of brief `20260901-state-writer-verdict-loss`.
`.claude/hooks/pre-commit-gates.sh`, `.claude/hooks/state-writer.sh`,
`.claude/hooks/_cleanup-helper.sh`.

## Triggers

- type: file
- path: `\.claude/hooks/state-writer\.sh`
- keywords: `verdict-discarded, A5_completeness_unscored, signoff_not_approved, GUARD_PATH_PATTERN, _bg_is_state_removal`

## Context

The operator asked whether reviews were again reporting "verified" while nothing was checked.
In the t-0070 unit (2026-11-18) four ways for that to happen were found, each in live evidence:

- The Critic was dispatched without the task contract, scored `COMPLETENESS: 0/0`, and reported
  `COMPLETENESS_GATE: APPROVED`. A5 blocked only on `NEEDS_WORK`, so 0/0 passed although the
  contract listed four verification items.
- `state-writer.sh` writes `reviewer-signed` / `security-signed` for BLOCKED verdicts too, and the
  high-risk gate checked only that the files existed: a BLOCKED security review counted as signed.
- Outside high-risk, a Reviewer or Security verdict did not reach the gate at all. The change was
  to `write-guard.sh`, a security guard, which the path/keyword classifier did not recognise.
- Reviewer and Security dispatched from `review` instead of `verify` were discarded as
  `phase_mismatch` — a security BLOCK among them. The only trace was an escalation file; five such
  files from two days sat unread. The brief's item 2 ("a discarded verdict must eventually change
  an outcome") had been open since 2026-09-01.

## Decision

1. **Completeness is scored against the contract.** When `.claude/local/task-contract.yaml` has a
   `verification:` list of N > 0 items, `cohesion-reviewed` must carry `COMPLETENESS: k/M` with
   M ≥ N, and the `COMPLETENESS_GATE:` line must be present. 0/0, no score, no gate line, or
   M < N blocks (`A5_completeness_unscored`). Items marked `[deferred]` are not counted — the
   Critic scores them N/A and leaves them out of M (critic.md). An inline list
   (`verification: [a, b]`) is counted like a block list. Without a contract, or with an empty
   list, nothing changes.
2. **A Reviewer or Security verdict binds.** A session-valid `reviewer-signed` or
   `security-signed` whose `GATE_RESULT` is not APPROVED blocks every commit, high-risk or not
   (`signoff_not_approved`). The high-risk sign-off requires APPROVED from this session, not a file.
3. **A discarded verdict changes an outcome.** When `state-writer.sh` discards a verdict (wrong
   phase, no sentinel) that has a `GATE_RESULT:` line saying anything but APPROVED, it also
   writes `verdict-discarded-<agent>` in the session state dir. The commit gate blocks while one
   exists (`verdict_discarded`), on any staged change. The next accepted verdict from that agent
   removes it; re-init and close clear it. Output with no `GATE_RESULT:` line leaves none: it may
   never have been a verdict (the Critic's hypothesis mode has no sentinel) and nothing re-run
   could clear it (reviewer finding). A discarded APPROVED leaves none either: the sign-off it
   would have written is simply missing, and the gates that need it already say so.
4. **The guards are high-risk by name.** The high-risk path scan also matches `write-guard`,
   `bash-guard`, `pre-commit-gates`, `pre-push-gates`, `state-writer`, `pretooluse-permission`,
   `permission-request`, `agent-git-guard`, `ask-user-deny`, `_mode-guard-helper`,
   `_permission-allowlist` (`.claude/hooks/*.sh`) and `.claude/settings.json` — staged, deleted,
   or renamed away (`--no-renames --diff-filter=D`; `STAGED_FILES` names a rename by its
   destination only). Other mechanism changes keep relying on pristine evidence (t-0063).
   Pragmatist cut: a blanket rule for every mechanism path would add two dispatches to most
   commits in this repo.
5. **State files cannot be deleted or moved by an agent command.** Points 2 and 3 are the first
   checks that block on a file being *present*, so deleting it would undo them (security
   finding: the Bash state guard saw only write targets). `bash-guard.sh` now refuses a command
   that runs `rm`, `unlink`, `rmdir`, `truncate`, `shred`, `mv`, `find … -delete` or `git clean`
   and names a `.state` path (`state_removal_protected`, `GATE-FINAL`, override
   `REPO_OS_RECOVER=1`). Its three early exits for commands with no write target ask this first.
   The hooks and the runner remove state files as processes, not agent commands, so are unaffected.
   Operator-approved amendment, 2026-11-18. Widened by Decision t-0073 to every mutation of a
   state path (touch, ln, install, dd of=, in-place editors) and to the headless approval helper.

The parked-question hint text (`ask-user-deny.sh`, `runner.sh`) now says the operator runs
`queue-cli.sh answer`, which t-0070 refuses in a headless session.

## Known limits

- **The score is the Critic's own count, and only its denominator is checked.** M ≥ N proves the
  Critic said it scored every item, not that each verdict is right, and `k` (items met) is not
  compared — a Critic routinely leaves a runtime criterion to QA. The per-criterion rows in
  `criteria-verdicts` are the record to read.
- **The removal check is text-based.** It needs a verb and a `.state` path in the same command
  (a path-qualified or quoted verb — `/bin/rm`, `'rm'` — counts). Not seen (R2's class): an
  interpreter (`python3 -c "os.remove(…)"`); a path built in a variable, split by quotes
  (`.sta''te`) or globbed (`.claude/.st*`); a symlink into `.state`; removing a parent without
  naming `.state` (`rm -r .claude`, `find .claude … -delete`, `git clean -fdx` with no path,
  `git stash -u`); other movers (`rsync --remove-source-files`, `trash`,
  `git checkout -- .claude/.state`); a backslash inside the verb (`r\m`). Side effects: an agent can no longer hand-remove a stuck
  task-group lock under `.claude/.state/` (session-type-task-group.md step 4 — the operator does
  it from a terminal), and one command mixing an unrelated `rm`/`mv` with a `.state` read — or
  writing text that mentions both, e.g. a heredoc session log or a `git commit -m` message — is
  refused and must be split, or the text written with the Write tool and committed with `-F`.
- **Some verdicts are lost before state-writer can mark them.** A subagent run with worktree
  isolation (`worktree_blocked`) or one whose hand-back is empty (`no_message`) exits before any
  rejection is recorded, so a BLOCKED there neither binds nor leaves a marker.
- **The guard list is not the whole mechanism.** `_phase-helper.sh`, `_analytics-helper.sh`,
  `_cleanup-helper.sh`, `session-close-check.sh`, `plan-approval.sh`, `runner.sh` and the agent
  prompts (`critic.md`, `reviewer.md`, `security-privacy.md`) can weaken a review without being
  high-risk; they rely on pristine evidence and the Critic.
- **An all-APPROVED re-run that is then rejected clears the marker.** The marker is removed once a
  verdict passes the phase check; a combined Critic output whose sections all say APPROVED but
  fail the sentinel shape is then rejected without re-writing it. The agent's latest word was
  APPROVED and its state files are not written, so the A5 gates still need a well-formed run.
- **The marker binds this session only.** It lives in the session state dir: a session that ends
  and is not re-initialised leaves it with the rest of its evidence.
- **Verdict files are still written by a hook the agent could imitate** (t-0012 §9, R2). These
  checks read what the files say; they do not attest who wrote them.
