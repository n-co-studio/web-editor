# Automation Blocker Playbook

Known failure patterns in headless automation sessions and their resolutions.
Referenced by escalation reports for operator recovery guidance.

---

## 1. Sealed Branch (Task Group)

**Symptom:** Gate 5 blocks edits with "branch appears in closed-branches ledger" for a task group brief that should reuse the branch.

**Root Cause:** A non-final task group brief sealed the branch at session close. The `record_closed_branch` call was not guarded by task group finality check.

**Resolution:**
1. Remove the branch from `.claude/local/closed-branches`
2. Re-queue the blocked brief: `queue-cli.sh add --brief <path> --branch <branch> --auto-approve --solo`
3. Verify the branch is no longer in the closed-branches ledger before running

**Prevention:** `_is_final_taskgroup_entry()` guard in `runner.sh` prevents non-final task group briefs from sealing the branch. Only the final brief (no pending/approved siblings remain) triggers `record_closed_branch`.

---

## 2. Permission Stall (Headless)

**Symptom:** Headless session hangs or exits with timeout. No progress after initial Bash commands. Permission dialog would have appeared but no operator is present.

**Root Cause:** `claude -p` was invoked without `--permission-mode bypassPermissions`. PermissionRequest hooks do not fire in `-p` mode, but the default permission mode still prompts for unknown tools/commands, causing a stall with no interactive operator.

**Resolution:**
1. The session will eventually timeout. No manual intervention needed for the stalled session.
2. Verify `runner.sh` includes `--permission-mode bypassPermissions` in the `claude -p` invocation.
3. Re-queue the entry: `queue-cli.sh add --brief <path> --auto-approve --solo`

**Prevention:** `--permission-mode bypassPermissions` flag on all `claude -p` invocations. Safety is provided by `--disallowedTools` (primary gate) and `pretooluse-permission.sh` (belt-and-suspenders PreToolUse hook that fires in headless mode).

---

## 3. Work Order Deferral Loop

**Symptom:** Entry is repeatedly deferred and re-dequeued without executing. Review log shows many `entry-deferred` events for the same entry. Work order has an escalated sibling that is never resolved.

**Root Cause:** A sibling entry in the work order failed or was escalated. The deferral guard correctly prevents execution of dependent entries, but without a deferral cap, the entry loops indefinitely between `running/` and `approved/`.

**Resolution:**
1. If the entry is now `blocked` (cap exceeded): resolve the root cause of the sibling failure, then reopen: `queue-cli.sh reopen-wo <work-order-id>`
2. If still looping (pre-cap): resolve the escalated sibling first. The deferred entry will automatically resume on the next poll cycle.
3. To check work order status: `queue-cli.sh --json list --status blocked` and `queue-cli.sh --json list --status review`

**Prevention:** `max_deferral_cycles` config (default: 3) caps deferral loops. Exceeded entries transition to `blocked` with an escalation file. `reopen-wo` CLI command resets the work order and clears defer counts. At the cap the entry AND its approved siblings are blocked together with one `esc-wo-blocked-<wo>` escalation, so unrelated entries are not starved behind them.

**Rebase conflicts (`failed:group-worktree-rebase-conflict`, `failed:branch-rebase-conflict`):** the runner aborts the rebase, verifies the worktree, escalates naming the conflicting files and stops before launching a session. These are terminal and do not count against the circuit breaker. To resume a group: resolve by hand (`git -C .worktrees/tg-<group> rebase main`) or discard with `queue-cli.sh reset-group-worktree <group> [--yes]` (refuses unless the work order is failed/escalated; prints what it discards; never run by the daemon), then `queue-cli.sh reopen-wo <work-order-id>`.

---

## 4. Brief Path Outside Repo Silently Rejected

**Symptom:** Headless session runs but produces no code changes. Prompt contains "No brief content available" instead of the task brief. No error in review log.

**Root Cause:** The brief path in the queue entry resolves to a location outside REPO_ROOT (e.g., an absolute path from the operator's home directory). `prompt-assembler.sh` silently rejected the path and assembled a prompt without brief content.

**Resolution:**
1. Check the queue entry's `brief_path` field: `queue-cli.sh show <entry-id>`
2. Copy the brief file into the repo: `cp /absolute/path/to/brief.md .claude/.automation/briefs/`
3. Re-queue with the relative path: `queue-cli.sh add --brief .claude/.automation/briefs/brief.md --auto-approve --solo`

**Prevention:** `queue-cli.sh add` now validates that the brief path resolves to a location inside REPO_ROOT at intake time, rejecting with a clear error before the entry is created. `prompt-assembler.sh` now writes a `gate-failure` escalation on path rejection for diagnostic visibility.

---

## 5. Uncommitted Changes on Session Exit

**Symptom:** Headless session completes all code changes but the entry shows `completed` with no commits. Branch has uncommitted working tree changes. Review log shows `entry-completed` but `git log` shows no new commits on the branch.

**Root Cause:** The headless session produced all expected code changes but never committed them. Possible causes: a permission issue during `git commit` (pre-commit hook failure), or phase enforcement blocking the commit.

**Note:** turn-budget exhaustion used to present this way too, and no longer does — since 2026-10-21 it classifies as `review:turn-budget-exhausted` and the entry goes to `review/`, never to `completed`. If you are here because an entry shows `completed` with no commits, exhaustion is **not** the cause; see §14 for that one.

**The worktree is gone — look for the patch, not the tree.** The runner removes a session's worktree when the session ends. Since Decision t-0062 it first writes a patch of the working tree (tracked changes, deletions, binaries **and untracked non-ignored files**) whenever the session made no commits and left the tree dirty. This applies to the normal exit path, a FORCE-HALT and a runner crash. Before t-0062 the work was simply destroyed (2026-10-21: four files lost from a `review:dirty-noop` entry).

**Resolution:**
1. Find the patch. `queue-cli.sh show <entry-id>` — the `error_log` contains `uncommitted work preserved as a patch ... : .claude/.automation/reports/preserved-work-<entry-id>-<timestamp>.patch`. This holds for every outcome, including a `review:dirty-noop` entry (a session that left only new files — before R34, 2026-10-25, such a session showed `completed:clean-noop`, so older `completed` entries may carry a patch too) and a force-halted one (finalised through the normal failure path). `queue-cli.sh review` prints `error_log` too. If `error_log` was cleared by `reopen-entry`, list `.claude/.automation/reports/preserved-work-<entry-id>-*.patch`; the file is named by entry id and survives the reopen.
2. Read the header (`#` lines): entry, outcome, branch, base sha, capture time, and the `git status --short` at capture. It is a raw snapshot — **not reviewed and not gate-checked**.
3. Inspect: `git apply --stat <patch>`. Check it applies: `git apply --check <patch>` from a checkout of the `base (HEAD)` sha in the header.
4. Recover: `git checkout -b recover/<entry-id> <base sha> && git apply <patch>`, then review, test and commit through the normal gates. Applying the patch does not make it part of the entry; it is your work from that point.
5. No patch and no commits: the tree was clean, or the session failed silently — check `queue-cli.sh log` and escalation files. If a commit exists on the session branch, the work is on the branch (a session that committed is never patched).
6. Re-queue if needed: `queue-cli.sh add --brief <path> --branch <branch> --auto-approve --solo`

**Limits:** a patch is only written when the session made **no** commits. If it committed and then left more files dirty, only the committed work survives. If `reports/` was unwritable, the runner warns on stderr (`work-preserver: ... NOT preserved`, visible in `logs/daemon.log`) and removes the tree anyway — the close is never blocked. Patches are reaped after `report_days` (default 90) like other reports. Task-group worktrees are kept (Decision 0054); the normal exit path snapshots them as well, while crash cleanup and the loop-top FORCE-HALT handler just leave them in place. Group worktrees removed by `remove_group_worktree` (after a seal or by the sweep) are outside this mechanism.

**Prevention:** Root cause requires investigation per case. Common mitigations: ensure the turn budget is sufficient (`runner.session_max_turns`, default 400 — it was a hardcoded 200 until 2026-10-21), verify pre-commit gates pass for headless sessions, check for `GATE-RECOVERABLE` messages in daemon logs (`logs/daemon.log`).

---

## 6. Lock Acquisition Failure

**Symptom:** Escalation file with type `gate-failure` and message "Lock acquisition failed after 3 attempts during outcome transition."

**Root Cause:** The queue lock file (`.claude/.automation/.queue-lock`) was held by another process for too long, or a stale lock was not cleaned up.

**Resolution:**
1. Check if another runner/CLI process is running: `ps aux | grep runner.sh`
2. If no process holds the lock: `rm -f .claude/.automation/.queue-lock`
3. Check entry state — it may have transitioned despite the lock failure (transitions proceed unlocked as a safety measure)
4. If entry is orphaned in `running/`: `queue-cli.sh prune` will recover it

**Prevention:** Lock operations use 5-second timeout with 3-attempt retry. Startup crash recovery cleans stale locks. The stale-running scanner is the secondary safety net.

---

## 7. Dirty Working Tree Between Entries

**Symptom:** Entry fails immediately with file conflicts or unexpected state. Previous entry left uncommitted changes.

**Root Cause:** A prior session crashed or failed without cleaning up. The dirty-tree guard (`git checkout -- . && git clean -fd`) should clean this, but if it fails, subsequent entries inherit the dirty state.

**Resolution:**
1. Manually clean the working tree: `git checkout -- . && git clean -fd`
2. Check for any important uncommitted changes before cleaning
3. Re-queue the failed entry

**Prevention:** The daemon runs `git checkout -- . && git clean -fd` before each entry. If this fails, the entry proceeds with dirty state (logged as WARNING). Consider checking if the failure is due to a locked file or permissions issue.

---

## 8. Circuit Breaker Pause

**Symptom:** Daemon stops processing entries while approved entries exist in the queue. Health status shows **`circuit-breaker`** — this is a first-class status the runner writes on every tripped cycle, so if you see `idle` instead, this is not your section (try §10 multiple daemons, or §6).

**Root Cause:** Three consecutive global failures triggered the circuit breaker. Daemon sleeps 60s between checks during pause.

**Resolution:**
1. Confirm it with `queue-cli.sh status` — the `circuit breaker:` line reports the failure count and prints `TRIPPED` when the breaker is set. `--json status` carries the same as `circuit_breaker_state` / `circuit_breaker_tripped`. Read it as "count >= 3", not as a prediction: past its cooldown the breaker still allows one probe entry.
2. Check recent failures: `queue-cli.sh log --lines 20`
3. Resolve the underlying failure cause
4. Clear the breaker: `queue-cli.sh reset-breaker`. This is the sanctioned reset — a successful session clears the counter, but the breaker itself prevents any session from starting, so waiting for one is not a recovery path.
5. If the cause is transient, the breaker also expires on its own: once `circuit_breaker_cooldown_seconds` (default 1800) has elapsed since the last failure, the daemon attempts **one** probe entry. The failure count is deliberately left at 3, so if that probe fails the breaker re-trips for another full window. That is one attempt per window, not a retry loop.
6. **A breaker file written before 2026-10-20 never expires.** Self-expiry reads `last_failure_epoch`, which older runners did not write, and a missing or unparseable value stays tripped by design (it fails closed rather than expiring on a value it cannot read). That path is silent, so waiting out the window will not help — check for the field with `cat .claude/.automation/queue/.circuit-breaker`, and if it is absent use `reset-breaker`.
7. Restarting the daemon does **not** clear the breaker — the counter lives in `.circuit-breaker` under the queue directory, not in daemon memory.

> Before 2026-10-20 a tripped breaker had no exit at all: nothing read the timestamp, there was no reset command, and the only reset ran on a successful session the breaker was blocking. Recovery meant deleting `.circuit-breaker` by hand.

**Prevention:** Fix the root cause of repeated failures. Common causes: invalid session type, broken brief content, infrastructure issues (git, npm).

---

## 9. Daemon Unstoppable During Active Session

**Symptom:** HALT file created and/or SIGTERM sent, but daemon continues running. Health file shows `running` with stale timestamp. `ps aux | grep runner.sh` confirms the process is alive.

**Root Cause:** The daemon is executing a `claude -p` subprocess. `HALT` is checked only in the main daemon loop — at the top, and again after an entry is dequeued and before it launches — never during a session, so a graceful halt cannot interrupt a running session — that is by design. `FORCE-HALT` is now watched *during* the session: since 2026-10-20 each entry launches a watcher that polls for the flag every 5s and signals the `claude` child directly (SIGTERM, then SIGKILL after 10s). If force-halt appears not to work, suspect a stale flag or a watcher that was never started rather than the old between-entries-only limitation.

**Resolution:**
1. Find the `claude` child process: `pgrep -P <daemon-pid>`
2. Send SIGTERM to the `claude` subprocess: `kill <child-pid>`
3. The daemon will detect the subprocess exit, process the failure, and then honor the HALT file on the next loop iteration
4. If the child PID cannot be found: the session may be stuck in a sleep — wait for poll_interval to expire

**Prevention:** Use `queue-cli.sh force-halt` for immediate stop — the in-session watcher sends SIGTERM to the active `claude -p` subprocess, waits up to 10 seconds, then sends SIGKILL. The watcher deliberately leaves the flag in place so the daemon loop still sees it, sweeps the worktree and stops. Two things to know about a force-halted entry: it gets **no escalation artifact** (the loop-top handler that writes one only runs between entries, and the entry has already been finalised by the normal failure path), and the halt **consumes one of its retries** — repeatedly force-halting the same entry can walk it to terminal `failed/`. The kill itself is not counted against the circuit breaker. HALT remains available for graceful shutdown (finish current entry first). Use `queue-cli.sh resume` to clear both flags before restarting. A leftover FORCE-HALT ends the next daemon start at the top of its loop, before any session launches; the handler then deletes the flag, so the start after that proceeds — which makes "it stopped once for no reason" the signature of a flag nobody cleared. `resume` is hygiene that removes the surprise, not protection against a persistent flag.

---

## 10. Multiple Daemon Instances

**Symptom:** Multiple `runner.sh --daemon` processes visible in `ps aux`. Queue entries may be processed out of order or concurrently, causing conflicts.

**Root Cause:** PID file guard has a race window. If the daemon is started multiple times in rapid succession (e.g., by multiple `intake.sh` calls or manual `start-daemon` invocations), the PID file check may not prevent all duplicates. The `start-daemon` subcommand in `queue-cli.sh` includes a brief `sleep 1` verification, but concurrent launches can slip through.

**Resolution:**
1. Identify all daemon processes: `ps aux | grep "runner.sh --daemon" | grep -v grep`
2. Kill all but the most recent: `kill <older-pids>`
3. Verify only one remains: `cat .claude/.automation/runner.pid`

**Prevention:** `runner.sh` now uses a flock-based atomic daemon lock (`.daemon-lock`) that eliminates the race window — only one daemon can hold the lock at a time. On systems without flock (some macOS), falls back to mkdir-based atomic lock. Always use `queue-cli.sh start-daemon` rather than launching `runner.sh --daemon` directly.

---

## 11. Queue Validator Not Called at Intake

**Symptom:** Invalid entries accepted into the queue — oversized briefs (>50KB), empty briefs (via `queue-cli.sh add`), or entries with malformed branch names. Issues only surface at dequeue/execution time.

**Root Cause:** `validate_queue_entry()` from `queue-validator.sh` is sourced by both `queue-cli.sh` and `runner.sh` but never called in production code paths. The validator is only invoked in test files. Brief size limit (50KB), branch name sanitization, and HMAC validation are dead code in production.

**Resolution:**
1. If an oversized brief was queued: `queue-cli.sh remove <id>` and re-queue with a trimmed brief
2. If an empty brief was queued via `queue-cli.sh add`: remove and re-queue via `intake.sh` which rejects empty briefs

**Prevention:** `validate_queue_entry()` is now called in both `queue-cli.sh add` and `intake.sh` after entry creation. Invalid entries are removed before approval. Validation covers: required fields (id, status, session_type), session type against Decision 0014 enum, brief content non-empty and max 50KB, branch name sanitization to `[a-zA-Z0-9/_-]` max 100 chars. Additionally, `queue-cli.sh add` rejects empty brief files before entry creation with a clear error message.

---

## 12. Dirty-Tree Escalation Missing Schema Fields

**Symptom:** Escalation file in `escalations/esc-dirty-tree-*.yaml` contains only `type`, `severity`, `message`, `created_at`, and `resolved` — missing `id`, `queue_entry_id`, `phase_at_exit`, `tag_at_exit`, `context`, and `resolution` required by the escalation schema.

**Root Cause:** The `runner_external_cleanup()` function in `state-manager.sh` writes a minimal dirty-tree escalation (lines 77-84) without populating all required schema fields. The entry_id and phase context are not available at the point where the escalation is written.

**Resolution:** These escalations are advisory — the operator can safely resolve by checking the branch for uncommitted changes and committing or discarding them.

**Prevention:** `runner_external_cleanup()` now accepts entry_id and phase_at_exit arguments. All call sites in `runner.sh` pass these values. The dirty-tree escalation includes all schema-required fields: `id`, `queue_entry_id`, `phase_at_exit`, `tag_at_exit`, `context` (list of uncommitted files), and `resolution`.

---

## 13. Retried Entry Loses Prompt History

**Symptom:** A failed entry is moved back to `approved/` for retry with `retry_count` incremented, but the `prompt` field is empty. Operator reviewing the entry cannot see what prompt was assembled for the previous attempt.

**Root Cause:** The prompt is assembled at dequeue time and written to the entry file in `running/`. When the retry mechanism transitions the entry back to `approved/`, the prompt field is not preserved — it is either cleared or the entry is rewritten from the approved/ copy.

**Resolution:** Check the blocker report (if generated) for execution context. Daemon logs (`logs/daemon.log`) may contain outcome details from the failed attempt.

**Prevention:** `queue_fail()` now copies the assembled prompt to `last_prompt` in the entry YAML before clearing the active `prompt` field. This preserves the previous attempt's prompt for diagnostic review. Additionally, `write_blocker_report()` includes the first 500 characters of the prompt in the report's `prompt_context` field. Use `queue-cli.sh show <id>` to view the `last_prompt` field on retried or failed entries.

---

## 14. Session Ran Out of Turns (`review:turn-budget-exhausted`)

**Symptom:** A queue entry lands in `review` with outcome detail `turn-budget-exhausted`. The
session ran for a long time — tens of minutes — and the stderr or stdout tail contains
`Reached max turns (N)`. It may have committed nothing, or committed partial work.

**Root Cause:** The headless session hit its `--max-turns` budget. The brief was larger than
the budget allowed, or the budget is set too low for the brief shape.

**Why this outcome exists:** a session that exhausts its turn budget exits **zero**. Before
2026-10-21 that meant a session which had done nothing and left a clean tree was recorded
`completed:clean-noop` — the entry left the queue as though the work were done, silently
dropping approved work. Two briefs were lost that way on 2026-10-21. The detector now checks
for the max-turns banner ahead of every success branch, including ahead of the new-commits
branch: partial commits followed by exhaustion is the case that most resembles success.

**Resolution — pick one, they are not alternatives so much as a diagnosis:**
1. Read the brief. If it bundles several concerns, **split it** into single-concern briefs and
   re-queue those. This is usually the right answer; a budget is a backstop, not a sizing
   policy.
2. If the brief is genuinely one concern and simply large, raise `runner.session_max_turns` in
   `config.yaml` (or `config.local.yaml`, which wins) and re-queue.
3. Return the entry to the queue with **`queue-cli.sh reopen-entry <id>`**. It resets the retry
   budget, clears the deferral counter, keeps the prompt that ran as `last_prompt`, and reopens
   the parent work order — without that last part the daemon would defer the entry three times
   into `blocked/`. Do this *after* step 1 or 2, not instead of them.

   For a **task group** entry it will decline to reopen the group if another brief is still in
   `review`, `blocked` or `failed`, print which ones, and tell you to use `reopen-wo <id>`
   instead. That is deliberate: reopening the group would un-gate siblings the deferral guard is
   holding back, and erase the pointer to the brief that actually failed.

`reopen-entry` exists because of this outcome: `approve` only handles `pending-review`,
`recover-entry` only handles `running`, and `reopen-wo` only resets `blocked`/`failed`
siblings — so before 2026-10-21 **no** `review:*` outcome had any CLI transition out of
`review/`, and the only exit was re-adding the brief as a fresh entry and losing the
original's history. It applies to every review outcome, not just this one.

**Do not** simply reopen the same brief against the same budget: it will run for the same
duration and land back here. Two such runs cost roughly 80 minutes on 2026-10-21.

**Prevention:** size briefs to one concern. If a brief has three numbered parts, it is three
briefs. `session_max_turns` is daemon-global, so raising it for one oversized brief raises it
for every session.
