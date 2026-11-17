# Decision t-0064 — A headless session that needs an operator decision asks and waits; it does not guess

**Status:** Accepted — amended by Decision t-0068 (2026-11-16): an unanswered question now parks the entry (or, opt-in, the agent decides) instead of expiring; `reason: expired` is no longer written. § 2, § 3, § 4 (TTL), § 5 (close reasons) and § 6 are superseded where they conflict.
**Date:** 2026-10-28
**Supersedes:** Decision t-0017 § Automated Choices row 6 (AskUserQuestion — Blocked) and the
paragraph under that table ("sessions that encounter ambiguity must escalate … rather than
prompting interactively").
**Amends:** `.claude/hooks/ask-user-deny.sh`, `.claude/.automation/runner.sh`,
`lib/permission-profiles.sh`, `lib/prompt-assembler.sh`, `config.yaml`. Adds
`lib/question-channel.sh`. No queue-schema change.

## Triggers

- type: file
- path: `\.claude/hooks/ask-user-deny\.sh`
- path: `\.claude/\.automation/lib/question-channel\.sh`
- keywords: `headless question, AskUserQuestion headless, question record, answer record, awaiting-answer, question_timeout_seconds, question channel, paused session`

## Context

`ask-user-deny.sh` read the `AskUserQuestion` payload into `/dev/null`, denied the call and
told the agent to "proceed with best judgment per the task brief". The question was lost, the
agent guessed, and a session that really needed a decision died later at an operator-tagged
phase with the reason for the stop nowhere on disk.

The hook could not even have done better: `AskUserQuestion` was in `--disallowedTools` for
every runner permission profile, and the headless prompt said "Do NOT use AskUserQuestion".
Claude Code removes a disallowed tool before any PreToolUse hook runs, so the hook was
unreachable from a runner session. Both are changed here (operator-approved scope addition,
2026-10-28).

## Decision

### 1. Capture, wait, answer — in the same session

In headless mode (`CLAUDE_HEADLESS=1`) the hook writes the question to disk, waits for an
answer file, and denies the call with exit 2 and a reason that carries the answer. Exit 2
feeds stderr back to the agent, which continues **in the same Claude session, the same
`REPO_OS_SESSION_ID` and the same worktree**: nothing is relaunched. A deny is used rather
than an allow because there is no operator UI to render the tool in `claude -p`; the deny
reason is the only channel back into the conversation.

Interactive sessions are unchanged. The fast-exit (`CLAUDE_HEADLESS` unset or not `1` →
exit 0, nothing read, nothing written) stays the first statement of the hook.

### 2. The timeout contract

- **Enforced in the hook, not by the operator and not by the runner.** A paused brief in a
  sequential task group holds the group's shared worktree and its single-occupancy lock
  (t-0054). The bound on that hold has to live in the process that is holding it.
- **Clock.** Starts when the question record is written. The hook polls every 5 seconds with
  `date +%s` and `sleep`; there is no `timeout` binary on macOS.
- **Effective wait** = `min(runner.question_timeout_seconds, runner.question_hook_timeout_seconds − 30)`.
  `question_hook_timeout_seconds` mirrors the `timeout` set on this hook in
  `.claude/settings.json` (Claude Code's default for a command hook is 600 seconds). The
  30-second margin exists because **a PreToolUse command hook that Claude Code kills on its
  own timeout fails open**: the call proceeds as if the hook had allowed it, which would let
  an unanswered agent carry on. The hook therefore always returns first. Setting
  `"onFailure": "block"` on the hook entry closes the same hole from the other side.
  `settings.json` is an immune path; changing it is an operator action, and the two values
  must be raised together.
- **Values.** Absent, empty or non-numeric → the default (`question_timeout_seconds` 14400,
  `question_hook_timeout_seconds` 600). `question_timeout_seconds: 0` → time out immediately,
  which is the pre-t-0064 behaviour plus a recorded question: a kill switch that needs no
  code change.
- **On timeout** the hook:
  1. writes a close marker `q-<id>.closed` (`reason: expired`). An answer that arrives later
     is ignored;
  2. writes an `ambiguity` escalation for the entry to the main repo's escalations directory
     (`get_escalations_dir`, schema `schemas/escalation.yaml`), so the entry is classified
     `review:escalation` by `detect_outcome` regardless of what the agent does next. Before
     t-0064 the agent was asked to write that file; now the hook writes it, because a
     model-mediated escalation is the path that silently did not happen;
  3. denies with exit 2 and a stop instruction: do not guess, do not continue the task,
     summarise and end.
- **After the session** nothing is new. The runner's post-session path is t-0062 exactly:
  a patch of any uncommitted work under `reports/`, its path in `error_log`, then
  `remove_session_worktree`. A task-group worktree is kept per t-0054 and its lock released
  at session end, which is the release the timeout guarantees.

### 3. Paused versus wedged

- **Paused**: the session's child process is alive **and** the entry has an open question —
  a record with no valid answer, no close marker, and a deadline still in the future.
- **Wedged**: anything else that is alive and not progressing. This decision does not add a
  wedge detector; it only guarantees that a paused session is never taken for one.

Consequences:

- **Health.** While an entry is paused, the runner's heartbeat writes `status: awaiting-answer`
  to `.automation/.health` instead of `running`. It is neither `idle` nor a failure.
- **Circuit breaker.** A paused session that is ended from outside — the TTL watchdog, a
  crash — is not counted against the breaker, beside the existing FORCE-HALT and
  rebase-conflict exemptions. The operator not answering is not a repo failure. A normal
  timeout ends in `review`, which never touched the breaker.
- **After exit** the runner closes any question still open for the entry
  (`q-<id>.closed`, `reason: abandoned`), so a retry of the same entry is not reported as
  paused on a question nobody is waiting on any more.

### 4. FORCE-HALT and STOP

- **FORCE-HALT** is unchanged and authoritative: the in-session watcher kills the child on its
  next poll. The hook checks on every poll that its parent process is alive and exits when it
  is not, so a killed session leaves no orphaned poller. The question record stays on disk;
  the runner's post-exit close marks it `abandoned`.
- **Graceful STOP (t-0055)** is answered by a PreToolUse hook, and none runs while the agent
  is blocked inside this one. A STOP during a pause therefore waits out `stop_grace_seconds`
  and is escalated to FORCE by the stop watcher. With `stop_grace_seconds: 0` (never
  escalate) a STOP is not honoured at all until the question is answered or times out.
  Stated limit, not fixed here.
- **Session TTL** still applies and the pause counts toward it. `question_timeout_seconds`
  should stay well below `session_max_ttl_seconds`.

### 5. The file format is a published contract (`format_version: 1`)

Read and written by an interface outside this repo's sessions, so it is versioned and
changes to it are breaking changes recorded here.

Directory: `<main repo>/.claude/.automation/questions/` (gitignored; resolved through
`get_main_repo_root` so a worktree session and the operator see the same files).

| File | Writer | Contents |
|------|--------|----------|
| `q-<id>.payload.json` | hook | The PreToolUse stdin, byte for byte. Authoritative copy of the question. |
| `q-<id>.yaml` | hook | `format_version`, `question_id`, `session_id`, `entry_id`, `phase`, `created_at`, `created_epoch`, `deadline_epoch`, `parsed`, then `questions:` — per question `question`, `header`, `multi_select`, `options:` (`label`, `description`, in payload order). Strings are JSON-encoded (double-quoted, valid YAML). `parsed: false` when jq is unavailable; the payload file is then the only copy. |
| `q-<id>.answer.yaml` | operator interface | `format_version: 1`, `question_id`, `answers:` — per question `question_index`, `selected:` (labels), `free_text`; plus `operator`, `answered_at`. |
| `q-<id>.closed` | hook or runner | `reason: expired` or `reason: abandoned`, `closed_at`. |

- `<id>` is a zero-padded monotonic sequence number from `questions/.seq`. An id is claimed by
  creating its payload file with noclobber (O_EXCL), which only one process can win, and an id
  that already has a record, answer or close file is skipped. Uniqueness therefore does not
  depend on the mkdir lock around the counter, which only keeps the counter orderly. Two
  sessions asking at once get two ids; each writes only its own files.
- Every file is written to a temporary name and moved into place. **An answer writer must do
  the same.**
- An answer file that is absent, partial, unparseable, of another `format_version`, or names
  a different `question_id`, is **no answer**. The hook keeps waiting; it never aborts under
  `set -euo pipefail` because of an answer file.
- Answers are returned verbatim. The hook does not validate selected labels against the
  options: the operator is the authority on the answer.
- **The answer reader is line-based, not a YAML parser.** It accepts exactly this shape
  (two-space `- question_index:`, selections as `      - "label"` lines or `selected: [ … ]`,
  `free_text` double-quoted):

  ```yaml
  format_version: 1
  question_id: "q-000001"
  answers:
    - question_index: 0
      selected:
        - "Option label"
      free_text: ""
  operator: "name"
  answered_at: "2026-10-28T12:00:00Z"
  ```

  Other valid YAML spellings (an unindented sequence, single-quoted or bare `free_text`) are
  read as no answer, and the session waits out its timeout. The `queue-cli.sh answer`
  follow-up removes the hand-writing that makes this easy to hit.

### 6. No instruction to guess

"Proceed with best judgment" and every equivalent is removed. The three outcomes the agent can
see are: the operator's answer; a stop instruction on timeout; a stop instruction when the
question could not be recorded at all (unwritable directory). The last one also writes the
escalation, so a broken channel degrades to the pre-t-0064 escalation, not to a guess.

### 7. Tool access

`AskUserQuestion` is removed from `--disallowedTools` in the `build`, `strict` and `default`
profiles. It stays blocked in `audit` (read-only, no operator in the loop) and `judge`
(eval scoring must not pause a study). The headless prompt now says when to ask and what
happens, instead of forbidding it, and in `audit` and `judge` says the tool is not available.

**Eval cells** are enqueued with the `build` profile (`lib/eval-conductor.sh`), so a cell
under measurement can now ask and wait. That is a behaviour change for studies: a cell that
asks holds the study for up to the effective wait and the pause counts in its wall time. A
study that must not pause sets `runner.question_timeout_seconds: 0` in `config.local.yaml`
for the run, which records the question and stops at once. A dedicated eval-cell profile is
not added here.

## Known limits

- **The agent can answer its own question.** `questions/` is not write-protected, the agent
  runs with `bypassPermissions`, and ids are predictable, so a session could write
  `q-<id>.answer.yaml` itself (or before asking). Nothing distinguishes that from an operator
  answer; `operator:` is a claim, not a credential. Same class as the queue write-protection
  gap (RUNNER-PARITY row 31). The compensating control is that the record, the payload and the
  answer stay on disk for review. Protecting the directory in `write-guard.sh` / `bash-guard.sh`
  is a follow-up.
- **The hook timeout is mirrored, not read.** If `settings.json` and
  `question_hook_timeout_seconds` drift apart, the hook can be killed before it returns, and a
  killed PreToolUse hook fails open unless `onFailure: "block"` is set. The suite asserts the
  shipped values agree; it cannot see an operator's later edit to one of them.

## Deliberately not done

- **No `queue-cli.sh answer` command.** Until the external interface exists the operator
  writes the answer file by hand to the format above. A follow-up brief.
- **No hook-side read of `settings.json`.** The hook timeout is mirrored into `config.yaml`
  instead; parsing an immune JSON file from a bash 3.2 hook was more fragile than one number
  the operator sets beside it.
- **No wedge detector.** Distinguishing paused from wedged is what the brief needs; detecting
  a wedge is a separate feature.
- **No STOP handling inside the wait.** See § 4.

## Verification

`.claude/hooks/tests/test-question-channel.sh`, against a sandbox; never the real queue or
questions directory. Pristine evidence:
`docs/ai/governance/pristine-evidence/headless-question-pause.yaml` (t-0063).

## References

- `docs/ai/decisions/t-0017-operator-automation-layer.md` — superseded row 6
- `docs/ai/decisions/t-0054-task-group-worktree-lifetime.md` — why the hook bounds the wait
- `docs/ai/decisions/t-0055-operator-session-control.md` — STOP/FORCE control
- `docs/ai/decisions/t-0062-preserve-uncommitted-work.md` — the unchanged timeout aftermath
- `docs/ai/decisions/t-0063-mechanism-change-verifies-itself.md` — evidence requirement
- `.claude/.automation/RUNNER-PARITY.md` row 72
