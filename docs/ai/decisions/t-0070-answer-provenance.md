# Decision t-0070 — Answers to headless questions: guarded path, recorded provenance

**Status:** Accepted
**Date:** 2026-11-17
**Amends:** Decision t-0068 § 3 (who may write an answer, and what the operator sees at
resume); reduces known issue R51(c) and the t-0064 Known limit it widened.
`.claude/hooks/write-guard.sh` (Questions-Guard), `.claude/.automation/queue-cli.sh`
(`answer`, `resume-entry`, `show --json`), `lib/question-channel.sh` (`qc_stamp_answer`,
`qc_answer_field`).

## Triggers

- type: file
- path: `\.claude/\.automation/lib/question-channel\.sh`
- keywords: `answered_via, answered_session, qc_stamp_answer, Questions-Guard, questions_path_protected`

## Context

A parked question (t-0068) waits as long as the operator takes, and the first answer file wins:
`queue-cli.sh answer` never replaces one. Anything that could write
`.claude/.automation/questions/q-<id>.answer.yaml` first could therefore answer for the operator,
and the resumed session would take it as theirs. Before this decision:

- In child and autonomous modes the mode guard already refused agent Edit/Write and Bash writes
  there; template mode carves out `.claude/.automation/*`, so it did not.
- `queue-cli.sh answer` run by an agent is its own process, so no guard saw that write — one
  headless entry could answer another's question.
- The file's `operator:` is `$USER`, and nothing showed the operator an answer already on file
  before `resume-entry` delivered it.

## Decision

### 1. Questions-Guard

`write-guard.sh` refuses, in every mode, any Edit/Write path or Bash write target under
`.claude/.automation/questions/` (`GATE-FINAL`, override `REPO_OS_RECOVER=1`), mirroring the
Queue-Guard. Records come from `ask-user-deny.sh` and answers from `queue-cli.sh`, both their
own processes, so no tool write belongs there.

- Edit/Write paths are matched after `resolve_path`, as Bash targets already were, so `.` and
  `//` segments (`.claude/./.automation/questions/`) hide nothing. This applies to the State-
  and Queue-Guard paths too, which had the same raw-text match.
- Queue and questions paths count under the session's root **or** the main repo's
  (`get_main_repo_root`): both directories are shared through the main repo (t-0064), so a
  worktree session reaches them by an absolute path outside its own root.

### 2. `queue-cli.sh answer`

- Refused when `CLAUDE_HEADLESS=1`: questions are answered by the operator.
- The published file carries `answered_via: "queue-cli"` and `answered_session:` — the
  `CLAUDE_CODE_SESSION_ID` of the Claude session that ran it, empty outside Claude Code (an
  interactive session the operator asked to relay an answer shows here). Any such lines in a
  `--file` are replaced: only `queue-cli` stamps.

### 3. Provenance is shown, not required

Readers are unchanged: the live-wait hook and the resume deliver a valid answer whether or not it
is stamped. A stamp is a string any writer can produce, so requiring it would add no protection
against a deliberate forger while stranding legitimate answers. Instead `resume-entry` on a parked
entry prints the answer it is about to deliver with `operator`, `answered_at`, `answered_via` and
`answered_session` (`none` when `queue-cli` ran outside Claude Code); a file that did not come
from `queue-cli` shows `answered_via: not recorded`. With `--json`, `resume-entry` prints
nothing extra: the fields are in `show --json`.
`show --json`'s `question` block passes `answered_via` and `answered_session` through.

## Known limits

- **The headless refusal reads an environment variable.** A session that clears
  `CLAUDE_HEADLESS` (e.g. `env -u`) is not refused; in headless runs the permission allowlist is
  the backstop. It stops the accident and the casual forgery, not a determined one (t-0004).
- **An interactive agent can still run `queue-cli.sh answer`.** That is how an operator asks a
  session to relay an answer, so it is allowed; the result carries a real stamp and that
  session's id. This is the cheapest forgery route left. The operator's check is the
  `answered_session` shown at resume, against sessions they know they asked.
- **The guard sees the write targets `extract_write_targets` finds**: redirects, `tee`, and the
  last argument of `cp`/`mv`. `dd of=`, `sed -i`, `install`, a target held in a variable, a
  write through a symlink and an interpreter (`python -c`) are not seen. Paths are compared as
  text after `.`/`..`/`//` normalisation, not symlink resolution, so a main repo reached through
  a symlinked prefix is not matched from a worktree. The match is case-sensitive, so on a
  case-insensitive filesystem (macOS default) `.Claude/.Automation/Questions/` is not matched.
  The same holds for the State- and Queue-Guard.
- **`REPO_OS_RECOVER=1` or a recover signal turns the guard off**, as it does the State- and
  Queue-Guard. It is the operator's override.
- **The stamp is forgeable.** A process that gets past the Questions-Guard (any of the routes
  above, or a script — see t-0069 Known limits) can write `answered_via: "queue-cli"` itself. The
  stamp tells the operator where an answer claims to come from; it is not proof.
- **The live wait shows nothing.** An answer that arrives during the live wait is delivered by
  the hook at once; only a parked resume prints it first.

R51(c) is reduced, not closed: a forged first answer now has to get past the Questions-Guard and
the headless refusal, and a parked one is shown to the operator before it is delivered.
