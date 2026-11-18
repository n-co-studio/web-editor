# Decision t-0068 — An unanswered headless question parks the entry; it does not expire

**Status:** Accepted
**Date:** 2026-11-16
**Amends:** Decision t-0064 § 2 (the timeout contract), § 3 (after exit), § 4 (session TTL),
§ 5 (close reasons — a format change) and § 6 (the outcomes the agent can see).
`.claude/hooks/ask-user-deny.sh`, `lib/question-channel.sh`, `runner.sh`, `queue-cli.sh`
(new `answer`, `resume-entry --force`, `show --json` `question` block),
`lib/prompt-assembler.sh`, `config.yaml`, `schemas/runner-config.yaml`,
`schemas/queue-entry.yaml` (v1.13.0).
**Related:** t-0055 (operator stop, resume, hold-the-line), t-0054 (task-group worktree),
t-0062 (worktree aftermath).

## Triggers

- type: file
- path: `\.claude/hooks/ask-user-deny\.sh`
- path: `\.claude/\.automation/lib/question-channel\.sh`
- keywords: `parked, question_on_timeout, agent-decides, queue-cli answer, stopped_mode question, REPO_OS_SESSION_DEADLINE_EPOCH`

## Context

Under t-0064 a question nobody answered within `question_timeout_seconds` (4 hours) expired:
the hook closed it as `expired`, wrote a blocking escalation and told the agent to stop. The
entry went to `review`, its worktree was removed (t-0062) and its Claude session was gone. A
late answer was ignored. In practice the operator is often away for longer than any wait the
hook can afford to hold — the hook timeout, the session TTL and, in a task group, the shared
worktree all bound it — so a real question usually became lost work and a re-run.

t-0055 already provides everything a long wait needs: an entry can end its run at a tool
boundary with `{"continue": false}`, sit in `stopped/` with its worktree and Claude session
kept, hold the briefs queued behind it, and be resumed in the same session.

## Decision

### 1. Configuration

- `runner.question_timeout_seconds` default **1800** (was 14400). It is now only the
  *live wait*: the window in which an answer reaches the still-running session. The cap
  `min(question_timeout_seconds, question_hook_timeout_seconds − 30)` is unchanged.
- New `runner.question_on_timeout: pause | agent-decides`. Absent, empty or anything else →
  `pause`: an unreadable setting must never become "carry on without the operator".
- Massimo writes both keys.

### 2. pause (default) — park

When the live wait ends unanswered, the hook:

1. closes the question with `q-<id>.closed` **`reason: parked`**. The question stays
   answerable: an answer written later is valid and is delivered on resume;
2. prints `{"continue": false, "stopReason": …, "hookSpecificOutput": {"permissionDecision":
   "deny", …}}` and exits 0. This ends the run exactly as an operator graceful stop does
   (t-0055), and still denies the tool call itself;
3. writes **no** escalation.

After the child exits the runner looks for a question of this entry closed as `parked`
**and created during this launch** (`created_epoch ≥` the launch time — a resumed entry
reuses its `REPO_OS_SESSION_ID`, so an earlier park of the same entry must not count). If one
exists the entry's stop mode is **`question`**. Precedence is FORCE > question > STOP: a FORCE
killed the child whatever else happened; a pending graceful STOP did not end the run, the
park did.

`stopped:question` takes the t-0055 stop path unchanged: `queue_stop` to `stopped/`,
`resume.yaml` written (now with `question_id`), worktree kept, no retry consumed, circuit
breaker untouched, no patch, no `remove_session_worktree`. A task-group worktree is also
not snapshotted for a park — no later brief can reset it, because:

**Task groups.** Later briefs do not start until the parked brief is answered and finishes.
Two existing rules do this together: while parked, t-0055 hold-the-line holds every later
entry (a stopped entry is a holder, and work-order siblings are never released by the scope
predicate); once resumed, the brief is back in `approved/` and Decision 0017 sequencing holds
brief N until every lower brief has left `approved/` and `running/`.

No separate marker file is written: the close marker already says what happened, and a
second file would be one more thing to disagree with it.

### 3. Answer and resume

`queue-cli.sh answer <entry-id> --question <q-id> (--file <answer.yaml> | --text TEXT …)`:

- checks, before writing anything, that the question exists, was asked by that entry, has no
  answer yet, and is either in its live wait (`qc_is_open`) or the question the stopped
  entry is parked on. Any other state (agent-decided, abandoned, an entry that moved on) is
  refused: nothing would read the answer;
- `--text` is given once per question, in order, and becomes `free_text` (quotes and
  backslashes escaped, line breaks flattened). `--file` is a full `format_version: 1` answer;
- publishes `q-<id>.answer.yaml` with `qc_write_answer`: validated against the t-0064 § 5
  reader **before** it becomes visible, from a `mktemp` file, then by hard link (`ln` fails
  when the target exists, so of two concurrent writers exactly one publishes). An existing
  answer file — valid, invalid or a symlink — is never replaced or written through; a
  refusal names the existing answer's `operator` and `answered_at`;
- **the park transition.** The hook re-reads the answer once more *after* writing the
  `parked` marker; an answer that beat the close is delivered and the marker removed. An
  answer that arrives after that, while the runner has not yet moved the entry to `stopped/`,
  is accepted (`action: answered-parking`) and the operator resumes with `resume-entry` once
  the entry shows stopped — the answer exists, so the refusal below does not apply;
- for a parked entry, then resumes it exactly as `resume-entry` does (flags cleared,
  `queue_resume`, holds released), in the same Claude session. During the live wait it only
  writes the file; the hook picks it up on its next poll.

On resume the runner's first message is the answer in **the hook's own wording**
(`OPERATOR ANSWER to <q-id> (AskUserQuestion is answered through the question channel in
headless mode; the tool itself does not run): … Continue the task using this answer.`),
followed by the existing phase-reset sentence. The agent cannot tell a late answer from a
prompt one.

`resume-entry` on a parked entry with no answer is refused and points to `answer`.
`resume-entry --force` resumes anyway, and the first message says no answer was given and
tells the agent to choose and state its assumption — the operator's explicit decision.

`show --json` gains a `question` member: `id`, `waiting` (`open` during the live wait,
`parked` when stopped on it, else empty), `parked`, `answered`, `summary`.

### 4. agent-decides

When the operator sets `question_on_timeout: agent-decides`, the hook instead closes the
question as **`reason: agent-decided`**, writes an `ambiguity` escalation with
**`severity: advisory`** recording the question and its options, and denies with exit 2 and
an instruction: choose the option that fits the brief, state the choice and the reason as an
explicit assumption in the next reply and the session log, and continue. The session is not
stopped. The escalation still routes the entry to `review` at the end (`detect_outcome`
counts every escalation), so the operator sees what was decided.

**Limit.** The hook cannot record the assumption itself: the agent forms it after the hook
returns. The escalation records the question and says where the assumption is written; the
assumption is model-mediated.

### 5. TTL

The live wait counts toward `session_max_ttl_seconds`; parked time does not (the session
has ended, and a resume is a new launch with a fresh TTL). The runner exports
`REPO_OS_SESSION_DEADLINE_EPOCH` (launch + TTL) and the hook ends its live wait 60 seconds
before it, so a long wait parks instead of being killed by the TTL watchdog. The runner warns
at launch when `question_timeout_seconds ≥ session_max_ttl_seconds`.

### 6. Paths that keep working

- **FORCE-HALT** during a live wait kills the session as before; the hook stops polling when
  its parent dies; the runner closes the question as `abandoned`.
- **Graceful STOP** during a live wait is still escalated to FORCE after `stop_grace_seconds`
  (t-0064 § 4).
- **A crash** during a live wait still closes the question as `abandoned` and keeps the
  entry off the circuit breaker.
- **`question_timeout_seconds: 0`** parks immediately (pause) or decides immediately
  (agent-decides). Eval studies that must not pause should set `agent-decides` or keep using
  the `judge`/`audit` profiles: a parked cell stops the study until answered.

### 7. Format change (t-0064 § 5)

`q-<id>.closed` reasons are now `parked | agent-decided | abandoned`. **`expired` is no longer
written by any path**; readers must still accept it in records written before this decision.
`format_version` stays 1: the record and answer files are unchanged, and every existing
reader treats an unknown close reason as closed. The queue entry's `stopped_mode` gains
`question` (schema v1.13.0).

## Known limits

- **The agent can still answer its own question** (t-0064 Known limits). A parked question
  widens the window: the answer file can now be written at any time before the operator's.
  `queue-cli.sh answer` refuses a second answer, so a forged first one would win.
- **`continue: false` ends the run without a summary turn.** The parked session writes no
  closing message; the resume continues mid-task.

## Amendment — Answer provenance (2026-11-17, Decision t-0070)

§ 3 is amended: `queue-cli.sh answer` is refused in a headless session and stamps
`answered_via`/`answered_session`; `write-guard.sh` refuses agent writes under `questions/`;
`resume-entry` shows an answer on file and its provenance before delivering it. Readers still
accept an unstamped answer. See t-0070.
