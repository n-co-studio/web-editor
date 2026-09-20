# Decision t-0049 — Gate Exit-Code Contract and Fail-Closed Aborts

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/hooks/pre-commit-gates\.sh`
- path: `\.claude/hooks/pre-push-gates\.sh`
- path: `\.claude/hooks/tests/test-helpers\.sh`
- path: `\.claude/tools/gate-conformance\.sh`
- path: `\.claude/\.automation/git-hooks/`
- keywords: `exit 2, exit code, fail-closed, fail-open, errtrace, set -E, ERR trap, _gate_abort, assert_fail, assert_blocked, gate-conformance, conformance harness`

## Context

An audit of the enforcement layer found that `pre-commit-gates.sh` had been
fail-open: it detected violations, printed them, and let the commit through.

Every gate in that script records failure in `$FAILED` and defers to a single
`exit 2` at the end of the file. The script runs under `set -euo pipefail`. At
the A1 trigger-index staleness check it computed a digest with:

```bash
LC_ALL=C ls "$DECISIONS_DIR"/t-*.md "$DECISIONS_DIR"/0*.md 2>/dev/null | ...
```

`docs/ai/decisions/` contains only `t-*.md` files, so the `0*.md` glob never
matches and `ls` exits 1. With `pipefail` that failure propagated out of the
command substitution; with `errexit` it terminated the script — at a line
roughly 480 lines before the `exit 2`.

The termination status was **1**. The Claude Code hook protocol blocks a tool
call on **exit 2 only**; any other non-zero status is surfaced as a
non-blocking error and the tool call proceeds. So every gate in the file —
A4 secret scanning, the phase gate, A2 scope, A5 cohesion, A6 contracts, the
A1 trailer requirement, the KG schema gate — became advisory. Verified by
staging a real-format AWS key: the gate printed `GATE-RECOVERABLE: A4 —
possible secret in staged diff` and `git commit` returned 0 with the key
committed.

Three things kept this invisible:

1. **The same bug in the repair path.** `rebuild-trigger-index.sh` computed its
   digest with a byte-identical pipeline and aborted the same way, so the
   regenerate command that the gate's own warning recommended was a silent
   no-op returning 1. The stored digest could never be refreshed, which kept
   the mtime/digest staleness path permanently active — the precondition for
   reaching the crash.

2. **A test oracle that could not express the contract.** `assert_fail()` and
   `assert_blocked()` in `tests/test-helpers.sh` passed on *any* non-zero exit.
   A gate that crashed with exit 1 therefore scored green as "blocks the
   commit".

3. **A test sandbox shaped differently from production.** The `tests/` sandbox
   never created `docs/ai/decisions/`. `pre-commit-gates.sh` guards its entire
   A1 block with `[ -d "$DECISIONS_DIR" ]`, so the block containing the crash
   never executed under test.

No CI ran on `feature/**` branches, and the only git hook installed was a
`pre-push` that ends `exit 0 # Always exit 0 — never block the push`, so a
`git commit` outside Claude Code passed through no checks at all.

## Decision

### 1. The exit-code contract is explicit and asserted

Claude Code hooks block on exit **2**. Exit **0** allows. Every other status is
non-blocking. Gate scripts, test assertions and documentation state the exact
code; "non-zero" is never treated as equivalent to "blocked".

Git hooks use the opposite convention (any non-zero blocks). The two layers do
not share exit-code conventions, and `.claude/.automation/git-hooks/pre-commit`
carries a comment saying so.

### 2. Unexpected aborts fail closed

`pre-commit-gates.sh` and `pre-push-gates.sh` install an ERR trap that exits 2
with a diagnostic naming the line, and run under `set -eEuo pipefail`. The `-E`
(errtrace) flag is load-bearing: without it the trap is not inherited by shell
functions, and an abort inside a sourced helper would still exit 1 and fail
open.

**The trap must be scoped to the main shell.** errtrace also propagates into
subshells and command substitutions, and there an unguarded trap is wrong.
Gates deliberately capture failing statuses:

```bash
A33_OUTPUT=$(cd "$REPO_ROOT" && npx tsc --noEmit) || A33_EXIT=$?
```

The `||` protects the outer assignment from `errexit`, but the inner failure
fires ERR *inside the substitution's subshell*. An unguarded trap exits that
subshell with 2, so the gate reads the wrong status (a `tsc` failure of 1
arrives as 2), emits a spurious "gate defect" diagnostic, and logs a false
`gate_script_abort`. A plain type error or KG schema violation would then tell
the operator that the gate itself is broken.

The trap therefore returns early when `$BASHPID != $$`, failing closed in the
main shell (top level and functions, which share `$BASHPID`) and leaving
subshells to the caller's own handling; `errexit` still terminates the subshell
with its original status, which is what the `||` capture expects.

**`-E` is enabled conditionally, only when `$BASHPID` exists.** `$BASHPID` is a
bash 4.0+ feature and macOS ships bash 3.2.57, where it is unset *and* `$$`
reports the parent's PID inside a subshell — so there is no way to tell a
command substitution from the main shell, and the guard above silently
degrades to `$$ != $$`, which is never true. Enabling `-E` on bash 3.2 would
therefore hijack every deliberately-captured failure. On bash 3.2 the trap
still covers this script's top level, which is where the fail-open actually
occurred; aborts inside sourced helper functions remain exit-1 there. That is
a known, narrower gap, recorded rather than papered over.

An earlier revision of this decision claimed errtrace "introduces no new abort
points". That was wrong in exactly this case, and it shipped. The spurious
abort was visible in a *passing* Layer 3 run — `GATE-FINAL: ... aborted
unexpectedly` alongside `[npm run test exit=2]` when npm had exited 1 — and
went unread because the suite was green. The first attempted fix (`$BASHPID`
guard alone) was also a no-op on this machine for the version reason above,
and that too only surfaced by re-reading the output rather than the pass count.
Recorded because it is the same failure mode this decision exists to prevent:
trusting a summary over the output.

The trap is a backstop, not a licence to leave aborts unfixed. Each one is a
gate defect and is repaired at its source.

### 3. Verification is independent of the system under test

`.claude/tools/gate-conformance.sh` asserts exact hook exit codes against a
**production-shaped** sandbox: `t-*.md` decision records and no `0*.md` files,
a populated trigger index whose mtime is older than the decisions. It shares no
assertion code, fixtures or helpers with `.claude/hooks/tests/`, and is never
invoked by a hook.

**Invariant: nothing may be its own witness.** A change to the gate chain is
verified by a check that is red before the change and green after, run by
something outside that chain.

The `tests/` sandbox now scaffolds a production-shaped decisions directory so
the A1 block executes under test. It deliberately creates `t-*.md` only —
creating both prefixes would mask the class of defect it exists to catch.

### 4. Enforcement exists outside the agent harness

- `.claude/.automation/git-hooks/pre-commit` runs the shared A4 secret pattern
  at the git layer, binding every committer rather than only Claude Code
  sessions. It does not attempt to reproduce phase/state/evidence gates, which
  depend on session state a human committer does not have.
- `install-hooks.sh` gates per-hook rather than refusing to install anything
  outside template mode. `pre-push` (template→child sync) stays template-only;
  safety hooks install in every mode, because child repos need secret scanning
  at least as much as the template does.
- `.github/workflows/gate-conformance.yml` runs the conformance harness, a
  trigger-index freshness check and `bash -n` on every gate script, on the
  branches where work actually happens.

## Consequences

- Gates that were advisory for the duration of the fail-open are blocking again.
  Sessions that relied — knowingly or not — on commits passing while a gate
  objected will now be stopped.
- Aborts that previously passed silently now block with `GATE-FINAL: ... gate
  aborted unexpectedly at line N`. This is the intended direction; latent
  aborts surface as loud failures rather than silent bypasses.
- `git commit` outside Claude Code can now be blocked by the secret scan, with
  `--no-verify` as the deliberate escape hatch.

## Alternatives Considered

1. **Fix the `ls` glob only.** Repairs the instance, not the class. The script
   is ~1800 lines under `set -e`; any future unhandled non-zero would fail open
   the same way, silently.
2. **Drop `set -e` from the gate scripts.** Would stop aborting mid-chain but
   let a failed check be skipped without notice — trading a loud failure for a
   quiet one, in the wrong direction for a gate.
3. **Reuse `tests/test-helpers.sh` for the conformance harness.** Rejected: the
   harness exists because that suite's assertions encoded the wrong contract.
   Sharing them would reintroduce the blind spot.
4. **Reproduce the full gate chain in the git `pre-commit` hook.** Rejected:
   the phase/state/evidence gates depend on Claude Code session state that does
   not exist for a human committer. Simulating it would produce evidence that
   attests to nothing.
