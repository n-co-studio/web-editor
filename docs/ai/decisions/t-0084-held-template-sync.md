# Decision t-0084 — A child can hold template updates for the operator to apply

**Status:** Accepted
**Date:** 2026-11-23
**Amends:** the direct-to-main sync model the engine cites as Decision 0015, and t-0051 (what
the engine does after staging). Files: `.claude/.automation/lib/template-sync-engine.sh`,
`.claude/tools/template-sync-held.sh`, `.templatesyncignore`,
`.claude/.automation/templates/template-sync-with-cleanup.yml`, `AI.md`.

## Triggers

- type: file
- path: `\.claude/tools/template-sync-held\.sh|\.claude/template-sync-mode`
- keywords: `template-sync-held, template-sync-mode, template-sync/held, hold mode`

## Context

A child's Template Sync workflow commits every template update straight to the child's main
and pushes it. The operator learns what changed only by reading the commit afterwards, and
cannot take an update later or not at all.

The child app Massimo shows the operator template updates and lets them apply one when they
choose. It needs the update held somewhere other than main, with its list of changed files
(Massimo request R7).

## Decision

1. **The mode is the child's.** `.claude/template-sync-mode` holds `direct` or `hold`: the
   first line that is not blank or a `#` comment, trimmed. A child with no file gets `direct`,
   exactly today's behaviour. The engine reads the file before it changes anything, and any
   other value stops the run with exit 1, naming the value. The file is listed in
   `.templatesyncignore`, so the template never ships, overwrites or sweeps it.

2. **Hold mode changes only where the update goes.** Everything up to staging runs as in
   direct mode: the file copy, the withdrawn-file sweep, the `.gitignore` merge, the decision
   cleanup and the A1 index rebuild. Then, if anything is staged, the engine:
   - makes `template-sync/held` fresh from the current main, carrying the staged update;
   - commits it with a message that lists every change as an `A`, `M` or `D` line followed
     by the path. The existing secret-pattern scan covers this message too;
   - pushes that branch alone, and switches the checkout back to main;
   - appends the same list to `$GITHUB_STEP_SUMMARY` when it is set, so it shows on the
     Actions run page.

   main is neither committed nor pushed in hold mode.

3. **The held branch is rebuilt on every run.** It is therefore always one commit on top of
   the main it was made from, never a pile of partial updates. Replacing it needs a forced
   push. The lease is the branch's value read from origin just before (empty when it does not
   exist), so a branch moved by anyone else during the run is not overwritten. This is the
   only branch the engine ever forces; main still never is.

4. **A held branch that nothing is waiting on is deleted.** When a hold-mode run finds
   nothing to commit, main already matches the template, which is what applying the update
   leads to. If a held branch exists then, the engine deletes it, under the same lease.

5. **The operator reads and applies it with `.claude/tools/template-sync-held.sh`:**
   - `status` prints the held commit's date and its change list. With no held branch it
     prints "No held template update."
   - `apply` needs main checked out with a clean tree. It fast-forwards main to the held
     commit, so main gets the same sync commit direct mode would have made. It does not
     push; it prints the push command.
   - If main has moved since the update was held, `apply` refuses and says to run the
     Template Sync workflow again, which rebuilds the held branch from the new main. There
     is no merge and no conflict handling.

   Exit codes are 0 done (or nothing held), 1 refused or failed, 2 usage.

## Consequences

- A child's workflow file needs no change: the mode lives in a synced-around file the child
  commits, and the engine it runs is the synced copy.
- `.claude/.automation/tests/test-template-sync-hold.sh` runs the real engine and tool against
  a real template, child and bare origin. It covers:
  - direct mode unchanged;
  - the held branch, its message and the step summary;
  - a rebuild;
  - an unknown mode changing nothing;
  - every `apply` refusal;
  - apply itself;
  - the deletion after the update is pushed.

  `sync-conformance.sh` checks that the real template excludes the mode file.

## Known limits

- The engine a child runs is its own synced copy. The sync that first delivers this engine
  therefore runs the old one, which ignores the mode file and commits to main. A child that
  wants that update held too must add the mode file after that sync.
- An operator who commits to `template-sync/held` by hand loses that commit at the next
  run. The branch belongs to the sync.
- An update that is never applied stays held. Each run replaces it with the newest template.
  An `apply` refused because main moved needs a workflow run before it can succeed.
