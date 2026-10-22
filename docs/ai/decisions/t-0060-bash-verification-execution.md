# Decision t-0060 — Executing repo-controlled verification scripts headlessly

**Status:** Accepted
**Date:** 2026-10-22
**Amends:** the Bash permission allowlist in `.claude/hooks/_permission-allowlist.sh`.
No session type, phase sequence or gate definition changes.

## Triggers

- type: file
- path: `\.claude/hooks/_permission-allowlist\.sh`
- keywords: `_PERMISSION_ALLOW_BASH, is_bash_allowed, bash tests, headless verification, suite execution`

## Context

`_PERMISSION_ALLOW_BASH` permits `npm`, `npx`, `node`, `python3`, `tsc`, `eslint`,
`prettier`, `jest`, `vitest` and `bun` — the toolchain of a Node/TypeScript child repo.
It had no entry for `bash`. This template is bash-only: every test suite it owns is a
bash script under `.claude/hooks/tests/` or `.claude/.automation/tests/`.

Bare `bash ` is **not** in `_PERMISSION_DENY_BASH`. It was simply absent from the allow
list, so it fell through to the permission dialog — and a headless session is
fail-closed. The consequence was not a slow path but an impossible one: **every queued
brief whose acceptance criteria say "all suites pass" was unachievable headlessly**, and
the only way an agent could exercise suite code was `source`, which runs it in the
current shell with no subprocess isolation and no exit status of its own.

This sat behind the same class of failure as Decision t-0059: a governance mechanism
that silently made correct work impossible rather than reporting that it was blocked.

## Decision

Four end-anchored patterns are added, permitting execution of repo-controlled
verification scripts and nothing else:

```
bash \.claude/hooks/tests/([A-Za-z0-9_-]+/)?[A-Za-z0-9_-]+\.sh([ ][A-Za-z0-9=._/-]+)*$
bash \.claude/\.automation/tests/([A-Za-z0-9_-]+/)?[A-Za-z0-9_-]+\.sh([ ][A-Za-z0-9=._/-]+)*$
bash \.claude/tools/([A-Za-z0-9_-]+/)?[A-Za-z0-9_-]+\.sh([ ][A-Za-z0-9=._/-]+)*$
bash -n \.claude/[A-Za-z0-9_/-]+\.sh$
```

`is_bash_allowed` matches `grep -qE "^${pat}"` and appends no terminator, so each
pattern supplies its own `$`.

### How much new capability this actually grants

For two of the three directories, none. `source .claude/hooks/` (line 119) and
`source .claude/.automation/` (line 123) are **already** allow entries and are a strict
superset of the corresponding new patterns: `source` executes arbitrary repo script
content in the *current* shell, with no subprocess boundary.

For `.claude/tools/` that is **not** true, and an earlier draft of this record wrongly
claimed it was. There is no `source .claude/tools/` entry and no prior `tools/` entry
anywhere in the file, so **the `tools/` pattern is a genuine new capability** — including
execution of `kg-seed.sh` and `kg-merge-deltas.sh`, which are writers rather than
verifiers. What makes it acceptable is not a `source` superset but that `node ` and
`python3 ` (lines 38 and 40) are already allowed and are unrestricted execution of
arbitrary code; a bounded list of repo-tracked shell scripts is a smaller grant than
either. The QA verifier caught the misattributed justification.

This also rests on an assumption worth stating: these paths are "repo-controlled" only
while an agent cannot author a script into them and then run it. The Write and Edit
guards cover that today. If those guards ever stop covering `.claude/hooks/tests/`,
`.claude/.automation/tests/` or `.claude/tools/`, these patterns become arbitrary
execution and must be revisited.

### Scope boundary

- Path segments use `[A-Za-z0-9_-]`, which excludes `.`. `..` therefore cannot appear in
  a segment, so **the script path** cannot escape its directory. Verified against `..`,
  `//`, a leading dot, `x.sh.sh`, extra subdirectory levels, and `-x` / `-c` forms.
- **Arguments are deliberately not path-bounded, and this is the loosest part of the
  change.** The argument class `[A-Za-z0-9=._/-]` admits `.` and `/`, so
  `bash .claude/tools/x.sh ../../../etc/passwd` matches. The directory bound applies to
  the script being executed, *not* to what that script is handed. The exposure is any
  script in those directories that sources, executes or writes a path it receives as an
  argument. Arguments cannot start a new command — `;`, `|`, `>`, backtick and `$(` are
  all outside the class and refused — so this is a path-argument question, not a shell
  injection one. Bounding arguments further would break suites that legitimately take
  fixture paths; it is pinned by a test instead.
- One optional subdirectory level is permitted, because suites exist at
  `tests/drift-check/` and `tests/headless/`.
- The `$` anchor means a same-line chain — `bash <suite> && git push --force` — does not
  match, and falls through to the dialog rather than riding along on the prefix.
- Executing a hook itself (`bash .claude/hooks/state-writer.sh`) is **not** permitted.
  Only the two test directories and `tools/`.
- `-n` parses without executing, so the syntax-check pattern grants no execution at all.

### Known gap, stated rather than papered over

`is_bash_allowed` pipes through `grep`, which matches **per line**. A multi-line command
whose first line is an allowed suite invocation and whose second line is anything at all
will match. This is pre-existing, is shared by every prefix entry in the array, and is
already recorded in the anchoring notes in that file ("Newline-separated commands — grep
operates per-line; caught by bash-guard"). Closing it would mean rejecting multi-line
commands in `is_bash_allowed` generally, which is a separate change with its own blast
radius.

Stated precisely, because "neither introduces nor worsens it" would be too comfortable:
the gap's *shape* is unchanged, but `bash <suite>` is a **new first line that can qualify
a multi-line command**, so the set of commands able to ride along does grow. Two things
bound it: `is_bash_denied` also greps per line, so a deny-listed second line is still
denied regardless of the first; and `bash-guard` remains in the chain. Only a second line
in neither list rides along.

An earlier draft of this record claimed the `$` anchor prevents chaining outright. It
does not: it prevents *same-line* chaining. The Pragmatist review caught the overclaim.

## What was considered and rejected

- **Allow only the two suite runners** (`run-phase-tests.sh`, `run-automation-tests.sh`).
  Rejected: briefs and agents routinely run one suite directly — `layer3-hook-integration.sh`
  is the normal way to exercise a single layer — so a runners-only allow would leave those
  acceptance criteria just as unachievable. It also needs editing whenever a suite is added,
  and buys little, since `source` is already a superset.
- **Drop `.claude/tools/`, allow only `gate-conformance.sh`.** Raised by the Pragmatist as
  scope beyond the stated problem, noting `kg-seed.sh` and `kg-merge-deltas.sh` are writers
  rather than verifiers. Kept, because the gates need three distinct scripts from that
  directory headlessly — `gate-conformance.sh` (the documented gate verifier), and
  `kg-cover.sh` / `kg-validate.sh` for the KG Update Gate's COVERAGE and FRESHNESS checks.
  The Pragmatist's own falsifier for the finding was "a brief requires several different
  tools/ scripts", which holds. The writers in that directory are reachable by `source`
  today regardless.
- **Omit `bash -n`.** Also raised as unrequired. Kept: it executes nothing, and the
  inability to syntax-check a hook has been a recorded friction in headless work.

## Consequences

- Briefs with "all suites pass" criteria become achievable headlessly. This unblocks the
  queue generally rather than any single brief.
- The permission surface grows by one command form, bounded to three directories.
- Agents gain a real exit status for suite runs, instead of `source` side effects.

## Verification

`layer3-hook-integration.sh` gains a 21-case section — the **first test coverage of
`_permission-allowlist.sh` anywhere in the repo**. That total absence of coverage is why
a missing entry on a security boundary survived unnoticed until it blocked the queue.
**304/304** in that suite.

Cases split into three kinds, which are not equivalent evidence:

- **8 fail-first cases** — the positive ones. Verified red against the unmodified library
  by sourcing `git show HEAD:.claude/hooks/_permission-allowlist.sh` from a scratch copy
  and driving `is_bash_allowed` over the same inputs. The live file was deliberately not
  overwritten for this check: the allowlist governs the session's own Bash calls, so
  replacing it would have revoked the very permission needed to run the suite.
- **11 guard cases** — the negative ones (`..` traversal out of each of the three
  directories, a same-line chain after each of the three, out-of-tree path, out-of-tree
  `-n`, executing a hook itself, bare `bash`, command substitution in an argument). These
  are green both before and after, by construction: they assert the widening did not
  over-reach. Reporting them as fail-first would be dishonest.
- **2 ordering cases** confirm a chained deny-listed command is still denied, and that the
  chain does not match the allow list either — so the safety does not rest on
  deny-before-allow ordering alone, though both callers do check deny first
  (`permission-request.sh:137`, `pretooluse-permission.sh:136`).

The guard cases are deliberately applied **per pattern rather than once**. QA found the
first draft tested traversal and chaining only on `hooks/tests/`, which meant dropping the
`$` anchor or admitting `.` into a segment of the `.automation/tests/` or `tools/` pattern
would have gone undetected. Each of the three directory patterns now carries its own
traversal and chain negative.

One case asserts the **argument looseness** described under Scope boundary — that a
traversing path *is* accepted as an argument. It is pinned by a test so the looseness is
visible as behaviour rather than only as prose, and so narrowing it later is a deliberate
change to a recorded expectation.

The change additionally evidences itself: the command `bash .claude/hooks/tests/layer3-hook-integration.sh`
that runs this suite is itself only permitted by the patterns under test.

## References

- `.claude/hooks/_permission-allowlist.sh` — `_PERMISSION_ALLOW_BASH`, `is_bash_allowed`
- `.claude/hooks/permission-request.sh`, `.claude/hooks/pretooluse-permission.sh` — callers
- `.claude/hooks/tests/layer3-hook-integration.sh` — the t-0060 section
- `docs/ai/decisions/t-0059-directional-dispatch-phase.md` — same class of silent blocker
