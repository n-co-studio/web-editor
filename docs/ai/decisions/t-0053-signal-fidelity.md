# Decision t-0053 — Signal Fidelity: Read the Artefact, Consume on Fulfilment

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/hooks/pre-commit-gates\.sh`
- path: `\.claude/hooks/_commit-message-helper\.sh`
- path: `\.claude/tools/gate-conformance\.sh`
- keywords: `commit trailer, Decisions trailer, recover-signal, COMMIT_CMD, commit message, one-shot signal, proxy`

## Context

Two defects in `pre-commit-gates.sh`, found in production use, turned out to be
the same mistake wearing different clothes: **the gate reasoned over a proxy for
the thing it actually depended on, and the proxy could diverge from that thing
without the gate noticing.**

**Defect 1 — the command string is not the commit message.** `COMMIT_CMD` is the
Bash command from the PreToolUse payload. Three gates grepped it for trailers:
A1's `Decisions:` (blocking), `Changes: EC-` and `Overrides:` (both advisory).
For `git commit -m "…"` the command string contains the message, so the grep
worked. For `git commit -F <file>` it does not, and A1 blocked commits whose
trailer was perfectly correct — three times in a row in a child repo before the
cause was found.

Two things made this durable. `gate-conformance.sh` covered the A1 trailer at
C7 and C8, but **both cases used `-m`**, so the suite only ever exercised the
form that works. And nothing in the prompts prescribes an invocation form: they
specify what the trailer must contain, while a multi-line message naturally
wants `-F`. The gate's correctness was silently contingent on a convention
nobody had written down.

**Defect 2 — a file's presence is not the fulfilment of the intent behind it.**
`.claude/.state/.recover-signal` is a one-shot operator bypass. It was deleted
at the top of the hook, on sight. But it only sets `SKIP_STATE=true`, which
suppresses *state-dependent* gates; A1 runs regardless and can still block. So
the token was spent on a commit that never happened, with nothing saying so.

Compounding it, PreToolUse fires before the command runs, so
`touch .claude/.state/.recover-signal && git commit …` can never work — the hook
checks for the file before the `touch` executes. Each retry is therefore two
separate tool calls, and a wrong guess burns the token again.

## Decision

### 1. Searched text is a superset of the command string, never a replacement

`resolve_commit_text()` (in `_commit-message-helper.sh`) returns the command
string **plus** the contents of a `-F`/`--file` argument when that path is
present and readable. The three trailer gates search that union.

Additive, deliberately. The obvious alternative — parse git's flags and resolve
the message properly — was reviewed and rejected: reimplementing git's flag
grammar in bash makes `-am`, `-aF`, `--message=` and heredocs each a parser
case, and a miss on any one silently breaks a form that works today. Resolving
`-C`/`--amend` would need `git log -1 --format=%B`, which exits non-zero in a
repo with no commits and, under `set -euo pipefail`, aborts the whole gate
chain — the exact failure class t-0049 exists to prevent, self-inflicted inside
its own fix.

**The file lookup is anchored to commands with no inline message.** The first
implementation searched for a `-F <token>` shape anywhere in the command string,
which also matched text *inside* a quoted message: `git commit -m "see -F
notes"` read a file named `notes` and let its contents satisfy a trailer gate.
Review caught it and it was reproduced before being fixed. git refuses to
combine `-m` with `-F`, so when an inline message is present any `-F`-shaped
substring belongs to that message and is ignored.

The first attempt at that anchor was itself too narrow — it enumerated `-m`,
`-am` and `-ma` with trailing spaces, and review showed `git commit -sm "see -F
notes"` walked straight through. A finite list of surface forms is not a rule.
Then the long-option side turned out to have the same disease. git accepts any
unambiguous abbreviation, so `--m`, `--me`, `--mes` and `--mess` all set a
message — verified against real git — and a literal `--message` check missed
every one of them. The anchor now matches **any** short-option cluster
containing `m` (`-m`, `-sm`, `-qm`, `-am"…"`, `-ma`) and **any** long option
beginning `--m`, which is exactly the unambiguous set since no other `git
commit` long option starts with `m`.

The same correction applies to the extraction side: `--fil` is accepted
alongside `--file`, that being the shortest form git allows (`--fi` and `--f`
are rejected outright as ambiguous with `--fixup`). The accepted forms are
spelled out rather than derived from an optional group: written as
`[Ff](ile|il)?` the pattern also accepted bare `--f` and lowercase `-f`, neither
of which git has — the code claimed a narrower contract than it kept, which is
the same failure in miniature as everything else in this decision. Both patterns moved to
`sed -E` — BSD basic regex has no `\|` alternation, and using BRE silently
matched nothing on macOS, which the tests caught.

With that anchor, the searched text is a superset of the command string and
nothing else: no working invocation regresses, and no new evasion path opens.

### 2. A one-shot signal is consumed when its purpose is fulfilled

The recovery signal is no longer deleted on sight. `_finish()` consumes it, and
`_finish()` is called from every success exit — the experiment branch, the
editor-live loop, and the end of the gate chain. There is no single `exit 0` in
this script, which is why "move the delete to the bottom" would have been wrong.

Block exits call `_blocked()`, which leaves the token armed and says so, naming
the gates that still stand in the way and reminding the operator that the signal
covers state-dependent checks only.

`_gate_abort` (the ERR trap) deliberately does neither. A crash in the gate
script is a defect, not a verdict; burning the operator's bypass for a reason
unrelated to what they were recovering from would be the same mistake again.

### 3. The general rule

A gate must read the artefact its outcome depends on, not a value that is
usually correlated with it. A one-shot token must be consumed at the moment its
purpose is confirmed fulfilled, not at the moment its presence is observed.

Where the artefact genuinely cannot be read, say so and fall back to the
previous behaviour — do not guess, and do not silently skip.

## Consequences

- **A behaviour change arrives with the next template sync.** Commits whose
  trailer lives in a `-F` file now have that trailer seen. Where such a commit
  previously slipped past A1 because the check was inert, it will now be
  evaluated properly — and will block if the trailer is genuinely absent. This
  is A1 working as designed for the first time on that path, not a new
  restriction, but it is a visible change and operators should know why.
- `.claude/hooks/tests/layer0-commit-message-helper.sh` pins the resolution
  rules as unit tests (30 assertions), including the cases that must NOT fire: a
  `-F` or `--file=` shape inside an `-m` message must never cause a file read.
- `gate-conformance.sh` grows from 19 to 21 assertions: a `-F` trailer is
  honoured, a `-F` file without a trailer still blocks, the unreadable-file
  limit is pinned, and the signal survives a block while being consumed on
  success. Both fixes were mutation-checked — reverting either makes exactly one
  new assertion fail.

## Known limits, recorded rather than papered over

- **A `-F` file written by the same command line is unreadable.**
  `build-msg > m.txt && git commit -F m.txt` presents a file that does not exist
  when the hook runs. Such a commit falls back to searching the command string
  alone, exactly as before this decision. Asserted as case C8c so it stays a
  known property rather than becoming a surprise.
- **A quoted `-F` path containing spaces is never read.** `-F "my file.txt"` is
  captured only to the first space, fails the readability test, and falls back
  to searching the command string alone. Safe, but silently inert — do not
  assume such a commit's file was examined.
- **The self-filter is a literal substring match on `git commit`** (line ~150).
  A shell wrapper or alias — `gc() { git commit "$@"; }; gc -m …` — contains no
  such text and bypasses the entire gate chain, not merely the trailer checks.
  Orthogonal to these two defects and not fixed here, but it is the same proxy
  problem a third time and should be treated as open.
- **Governance state follows the session's repo, not the repo being edited.**
  Work done in the template from a session rooted in a child repo writes
  `plan-approved` and the agent verdicts into the *child's* state directory, so
  the template's own gates cannot be satisfied from there. Noted while landing
  this decision; not addressed here.

## Alternatives Considered

**Parse git's flag grammar and resolve the message exactly.** Rejected — see §1.
Large surface, silent regressions on forms that work today, and a `git log`
call that crashes on an empty repository.

**Move the trailer check to a `commit-msg` git hook, where git hands over the
real message.** Architecturally tempting and genuinely the only way to see the
final text. Rejected for now: the template ships no git hooks and enforces
against the agent's tool calls, so this would add a second enforcement surface
that can drift from the first, and it fires after the Bash tool call has already
begun. Worth revisiting if the proxy problem recurs a fourth time.

**Never delete the recovery signal; leave it to the operator.** Rejected — it
removes the one-shot property, and a forgotten signal silently bypasses state
checks on a later, unrelated commit.

**Widen the signal to suppress every gate, not just state-dependent ones.**
Rejected — it would also suppress A4 secret scanning and the knowledge-graph
schema gate, which have nothing to do with the recovery scenario the signal
exists for.
