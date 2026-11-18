# Decision t-0066 — Pushing main to origin is opt-in

**Status:** Accepted
**Date:** 2026-11-11
**Amends:** `.claude/hooks/session-close-check.sh` (`advisory_push_to_remote`),
`.claude/.automation/runner.sh` (the post-merge push in `_solo_merge_if_needed`).
**Related:** t-0047 (Stop/SessionEnd split), t-0057 (PR close path).

## Triggers

- type: file
- path: `\.claude/hooks/session-close-check\.sh|\.claude/\.automation/runner\.sh`
- keywords: `push, push_on_complete, advisory push, push_main_on_session_end, origin main, git push`

## Context

Two places pushed `main` to `origin` after a merge, and neither asked whether anyone wanted it:

- **The SessionEnd hook.** `advisory_push_to_remote` ran `git push origin main` after every
  agent merge and every hook merge, whenever the repo was not in template mode and had an
  `origin`. It ran in interactive and headless sessions alike.
- **The runner.** After a solo merge it pushed with `-u` when the entry's `push_on_complete`
  was true, and otherwise fell through to an "advisory" push of its own. So the queue's
  `--push` flag decided which push command ran, not whether one ran.

A child repo found it (GT-3, from `web-editor`): a brief that forbade pushing, queued without
`--push`, still pushed `main` to `origin` when it finished. Leaving out `--push` could not stop
it, because either path pushed regardless. Pushing publishes work outside the machine; it
should happen because someone chose it.

## Decision

### 1. One owner per kind of session

- **Headless** (`REPO_OS_SESSION_ID` set): the SessionEnd hook never pushes, whatever the
  setting below says. The runner owns the push, because only the runner knows the entry's
  `push_on_complete`.
- **Interactive**: the SessionEnd hook pushes `main` only when the operator has set
  `runner.push_main_on_session_end: true`. It reads `config.local.yaml` first, then
  `config.yaml`, from the main repo root (so a worktree session sees the gitignored local file).
  The default is `false`: the operator pushes by hand, as with any other git work.

### 2. The runner pushes only when asked

After a solo merge the runner pushes `main` only when `push_on_complete` is true; otherwise it
records the close step as `push skipped: push_on_complete false`. The fallback push is
removed. The decision and the push live in one function, `_push_main_after_merge`, so there is
one place in the runner that can publish `main`.

### 3. A skipped push is recorded

When the hook decides not to push it logs `push_skipped_no_opt_in` (interactive) or
`push_skipped_headless`, and prints a one-line notice naming the command to run. SessionEnd's
stderr is usually not seen, so the hook log is the reliable record.

Template mode and a repo with no `origin` still skip, as before. With `push_on_complete` true
the runner pushes in template mode too, as it did before.

## Not changed

- The PR close path (t-0057) and the non-solo branch push: both already push only when
  `push_on_complete` is true.
- `template-sync-engine.sh`, which pushes in the sync workflow on purpose.

## Consequences

- A child repo that relied on SessionEnd publishing `main` must set
  `runner.push_main_on_session_end: true` in `config.local.yaml`, or push by hand.
- Headless entries that should publish need `--push`, which is what the flag always said.

## Verification

`.claude/hooks/tests/test-push-opt-in.sh` runs both functions against a local bare origin and
checks statically that neither file pushes `main` anywhere else. Pristine evidence:
`docs/ai/governance/pristine-evidence/push-opt-in.yaml` (t-0063).
