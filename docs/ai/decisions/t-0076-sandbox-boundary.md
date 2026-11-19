# Decision t-0076 — Gate evidence sits behind the Bash sandbox

**Status:** Accepted
**Date:** 2026-11-19
**Amends:** Decision t-0073 (its text guard stays as a first line; this is the boundary behind it).
Completes the operator's three-step plan with t-0074 (forging helpers removed) and t-0075 (a
verdict counts only for its approval). `.claude/hooks/_cleanup-helper.sh`, the two test runners,
`test-question-channel.sh`, `test-question-park.sh`.

## Triggers

- type: file
- path: `\.claude/hooks/tests/run-phase-tests\.sh`
- keywords: `sandbox, denyWrite, allowWrite, REPO_OS_TEST_SKIP_LOG, SKIPPED (sandbox)`

## Context

t-0073's guard reads command text, so an interpreter, a sourced function or a split verb writes a
verdict file without naming it. The operator chose an OS-level boundary instead: Claude Code's
Bash sandbox (macOS Seatbelt). It applies to every Bash command and everything it starts; hooks
run outside it, so they still record verdicts; Write and Edit stay under `write-guard.sh`.

## Decision

1. **The boundary is the operator's setting, not template code.** It lives in the operator's
   `.claude/settings.local.json` (never synced, never agent-writable):

   ```json
   "sandbox": {
     "enabled": true,
     "allowUnsandboxedCommands": false,
     "filesystem": {
       "allowWrite": ["/private/var/folders", "/private/var/tmp",
                      "<home>/.local/state/repo-os", "<home>/.local/share/repo-os-analytics"],
       "denyWrite": ["<repo>/.claude/.state/.recover-signal",
                     "<repo>/.claude/.state/**/cohesion-reviewed",
                     "<repo>/.claude/.state/**/diff-review-complete",
                     "<repo>/.claude/.state/**/qa-verified",
                     "<repo>/.claude/.state/**/reviewer-signed",
                     "<repo>/.claude/.state/**/security-signed",
                     "<repo>/.claude/.state/**/verdict-discarded-*"]
     }
   }
   ```

   Absolute paths; `**` matches every session directory. `allowWrite` covers system temp (where
   the suites' `mktemp` lands) and the two repo-os folders helpers log to. `allowUnsandboxedCommands:
   false` makes Claude Code ignore `dangerouslyDisableSandbox`.
2. **What it stops (probe, 2026-11-19).** Writing any denied file was refused by the OS through a
   redirect, a sourced shell function, Python, `cp`, `mv` onto the name, a write through a symlink,
   and a hard link created *into* a denied name; so was creating the recover signal. `plan-approved`
   and phase files stayed writable, as intended. On a verdict a hook had written (this unit's
   Critic `cohesion-reviewed`, so hooks still write denied files): a zero-byte append, a hard link
   *from* it to an allowed name (the path-based bypass a Seatbelt rule might miss) and a rename away
   were all refused, and the file was unchanged. Deleting one is refused too (tested on a
   `reviewer-signed` probe the operator created from a terminal — auto mode rightly would not let the
   agent try it on real evidence), so the file itself cannot be deleted. The same refusal is why
   `init_phase` cannot clear the previous unit's verdicts, which t-0075 makes harmless. **But its
   folder can be renamed away** (tested on the probe folder, then moved back): the rules match file
   paths, not what sits under a renamed parent — see Known limits.
3. **A worktree check that the sandbox exposed is fixed.** `remove_group_worktree` refused removal
   from inside the worktree by comparing `$PWD` as text; reached through a symlink (macOS `/tmp` →
   `/private/tmp`, where the sandbox puts temp), the strings differ and the tree was removed from
   under its caller. It now also compares physical paths. A real bug outside the sandbox too.
4. **What cannot run in the sandbox is shown, not passed.** The sandbox blocks `ps`, so the
   FORCE-HALT cases (the question hook noticing it was orphaned) cannot run there; real hooks run
   outside it, where `ps` works, so the hook is unchanged (Pragmatist). Those cases print
   `SKIPPED (sandbox): …` — neither `ok` nor `not ok` — and append to `REPO_OS_TEST_SKIP_LOG`; both
   runners list every skipped case, and their closing line says "All run tests passed — N case(s)
   SKIPPED (sandbox), not run here" instead of "All tests passed".

## Known limits

- **A verdict's folder can be renamed away** (Security; tested 2026-11-19). Moving a session's
  state folder makes every verdict in it vanish, a BLOCKED one included. It cannot produce an
  approval: the folder also holds `plan-approved`, and the moved-away Critic and QA verdicts cannot
  be recreated (their names stay denied), so the commit stays blocked until a real Critic and QA
  approve again. What it can drop is a Reviewer/Security block (or a discarded-verdict marker) on a
  change that is not high-risk, which nothing then makes the agent re-run. A fix needs blocks
  recorded where an agent cannot rename them — e.g. a hook-written ledger under a denied directory
  outside the repo (R60).
- **`plan-approved` and `pragmatist-signed` are not covered** (R58): their agent-side writers
  decide from agent-writable inputs, and `init_phase` must still clear them.
- **Repo-side evidence is not covered:** `docs/ai/governance/criteria-verdicts/*.yaml` and
  `pristine-evidence/*.yaml` are committed files the agent writes and the commit gate reads
  (pristine evidence: R36(b)). "Gate evidence" here means the state-directory verdicts.
- **`allowWrite` is wider than this session's temp:** `/private/var/folders` and `/private/var/tmp`
  are every app's per-user temp and cache roots, so an agent command can write into other apps'
  caches. Accepted as a convenience — the suites' `mktemp` lands there; nothing in the gate chain
  reads it. Narrow it to the session `$TMPDIR` path if that matters more.
- **A shadowed `ps` turns FORCE-HALT into a skip.** An agent that puts a failing `ps` first on PATH
  gets `SKIPPED (sandbox)` instead of a run; it is shown, never a pass, and gates do not parse runner
  output, but a reader must not take a skip as coverage.
- **Verified by the operator, not here:** that the FORCE-HALT cases still run and pass where `ps`
  works. Every agent in a sandboxed session shares the sandbox; run the two suites from a plain
  terminal after any change to the question hook. Done for this change on 2026-11-19: the
  operator ran both from a terminal — `test-question-channel` 117/0 (FORCE-HALT cases 98–103 ran
  and passed) and `test-question-park` 162/0 (cases 158–162), no `SKIPPED` line in either. Inside
  the sandbox, and with a failing `ps` first on PATH, the same cases print `SKIPPED (sandbox)`,
  are counted as neither `ok` nor `not ok`, and the suite exits 0.
- **Agent-made worktrees of a repo with `.claude/agents` fail:** Claude Code's own protection
  refuses writes to `.claude/agents/*` from sandboxed commands, even inside `.worktrees/`. The
  runner (outside the sandbox) is unaffected.
- **`ps` and `pgrep` are refused for agent commands.** Hooks are unaffected.
- **child-sync after an agent's push** runs inside that `git push`, so it cannot pull the
  operator's local clones (children still update on GitHub). Run it from a terminal, or push from one.
- **The mode guard refuses `$TMPDIR` write targets** (unresolved variable) while the sandbox says
  to use `$TMPDIR`; use the literal path (`/tmp/claude-<uid>`).
- **Write and Edit are outside the sandbox.** They are governed by `write-guard.sh` and Claude
  Code's permission rules, not by this boundary.
- **Still text-only:** a `cd` in a Bash call moves the session's working directory, and the
  hooks are registered by relative path, so they stop resolving until the agent `cd`s back.
