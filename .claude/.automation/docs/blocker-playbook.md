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

**Prevention:** `max_deferral_cycles` config (default: 3) caps deferral loops. Exceeded entries transition to `blocked` with an escalation file. `reopen-wo` CLI command resets the work order and clears defer counts.

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

**Root Cause:** The headless session produced all expected code changes but never committed them. Possible causes: max-turns exhaustion before reaching the commit phase, permission issue during `git commit` (pre-commit hook failure), or phase enforcement blocking the commit.

**Resolution:**
1. Check the branch for uncommitted changes: `git stash list && git status`
2. If changes are present: review them manually, commit, and merge
3. If the branch is clean but no commits: the session may have failed silently — check `queue-cli.sh log` and escalation files
4. Re-queue if needed: `queue-cli.sh add --brief <path> --branch <branch> --auto-approve --solo`

**Prevention:** Root cause requires investigation per case. Common mitigations: ensure `max-turns` is sufficient (default 200), verify pre-commit gates pass for headless sessions, check for `GATE-RECOVERABLE` messages in daemon logs (`logs/daemon.log`).

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

**Symptom:** Daemon stops processing entries. Health status shows `idle` but approved entries exist in queue.

**Root Cause:** Three consecutive global failures triggered the circuit breaker. Daemon sleeps 60s between checks during pause.

**Resolution:**
1. Check recent failures: `queue-cli.sh log --lines 20`
2. Resolve the underlying failure cause
3. The circuit breaker resets automatically on the first successful session
4. To force immediate processing: restart the daemon with `queue-cli.sh halt && queue-cli.sh resume && queue-cli.sh start-daemon`

**Prevention:** Fix the root cause of repeated failures. Common causes: invalid session type, broken brief content, infrastructure issues (git, npm).

---

## 9. Daemon Unstoppable During Active Session

**Symptom:** HALT file created and/or SIGTERM sent, but daemon continues running. Health file shows `running` with stale timestamp. `ps aux | grep runner.sh` confirms the process is alive.

**Root Cause:** The daemon is executing a `claude -p` subprocess. Both HALT file checks and SIGTERM graceful shutdown only take effect between entries (in the main daemon loop). During active `claude -p` execution, the daemon is blocked waiting for the subprocess to exit.

**Resolution:**
1. Find the `claude` child process: `pgrep -P <daemon-pid>`
2. Send SIGTERM to the `claude` subprocess: `kill <child-pid>`
3. The daemon will detect the subprocess exit, process the failure, and then honor the HALT file on the next loop iteration
4. If the child PID cannot be found: the session may be stuck in a sleep — wait for poll_interval to expire

**Prevention:** Use `queue-cli.sh force-halt` for immediate stop — creates a `FORCE-HALT` file that sends SIGTERM to the active `claude -p` subprocess, waits up to 10 seconds for exit, then sends SIGKILL if still alive. The daemon then exits cleanly. HALT remains available for graceful shutdown (finish current entry first). Use `queue-cli.sh resume` to clear both HALT and FORCE-HALT files before restarting.

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
