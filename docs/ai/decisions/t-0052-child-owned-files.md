# Decision t-0052 — Child-Owned Files

## Status
Accepted

## Triggers

- type: file
- path: `\.claude/\.automation/lib/template-sync-engine\.sh`
- path: `\.templatesyncignore`
- path: `\.templatesyncignore\.local`
- path: `\.claude/tools/sync-conformance\.sh`
- keywords: `child-owned, templatesyncignore.local, child claim, product README, template sync, withdrawn file sweep`

## Context

Decision t-0051 §1 made the template's `.templatesyncignore` authoritative:
`_load_syncignore_patterns()` reads it from the template ref and falls back to
the child's copy only when the template has none. That closed a real hole — a
child without the file excluded nothing, so its first sync overwrote its
`.gitignore`, session logs and compiled specs wholesale.

It also, unremarked, removed the child's ability to protect anything the
template does not already exclude. t-0051's Consequences section lists five
outcomes and this is not among them, which is how it reached production
unnoticed.

**The cost was both children's product README.** The template ships a
`README.md` describing Repo OS. From the sync of 2026-09-25, `web-editor` and
`markpreston.co` both carried that file as their own public README —
`web-editor` days from a Chrome Web Store launch, its repo opening "# Repo OS —
AI-native project governance for Claude Code", with no mention of the product,
its npm packages or the store.

**The guardrail existed and was removed by the same mechanism.** `web-editor`
had `README.md` in its own `.templatesyncignore`, committed in `b9b5589` and
present on origin. The sync overwrote `.templatesyncignore` itself, dropping
the entry, and then overwrote the file that entry protected. The line is still
in the child's copy today; it is simply never read.

**A naive union would have been worse than the bug.** Exclusion and the
withdrawn-file sweep are coupled through `machinery-manifest.txt`, which is
generated against the template's list. `README.md` was line 189 of it. Had the
child merely excluded a path the manifest still listed as delivered, the day
the template withdrew its copy the sweep would have found it in the previous
manifest, absent from the incoming one, and deleted the child's file. Verified
by mutation: with the sweep guard below removed, the conformance suite's
child-claimed fixture is deleted outright (2 assertions fail).

## Decision

### 1. A child claims a path in `.templatesyncignore.local`

`_load_syncignore_patterns()` loads the template's list as t-0051 specifies,
then appends the child's `.templatesyncignore.local` if present. Claims **add**
to the template's policy and never subtract from it, so the first-sync hole
t-0051 closed stays closed: a child with no claims file is exactly a t-0051
child.

`.templatesyncignore.local` is itself excluded from sync. Delivering the
template's copy would erase the claims on precisely the sync that needs them.

### 2. A claim binds the sweep as well as the copy

Claims are tracked in `_CHILD_CLAIM_PATTERNS` as well as merged into
`_SYNCIGNORE_PATTERNS`, and `sweep_withdrawn_files()` skips any candidate
matching a claim. Exclusion alone would have produced the deletion described
above. `is_child_claimed()` mirrors `is_excluded()`'s matching rules exactly so
a claim and an exclusion behave identically — one dialect, not two.

The invariant, asserted directly in `sync-conformance.sh`: **a file the child
has claimed is never overwritten by sync and never removed by the sweep,
including after the template withdraws its own copy.**

### 3. `README.md` is excluded template-side, not left to each child

A child's README describes the child's product; the template's describes the
template. No child wants ours. Excluding it in the template's own
`.templatesyncignore` — rather than requiring every child to claim it — also
drops it from the machinery manifest, so sync and sweep continue to reason
about the same file set. A per-child claim would leave the two disagreeing,
which is the condition §2 exists to make safe but which is better avoided
outright where the template can simply stop shipping the file.

`rebuild-machinery-manifest.sh` was re-run: 303 entries → 292, `README.md`
among those removed.

## Consequences

- A child can protect its own files again, and the protection survives the sync
  that delivers it.
- Claims cannot weaken the template's policy, only extend it.
- A claimed path is permanently the child's: if the template later withdraws it,
  the child keeps its copy rather than losing it to the sweep.
- `README.md` is no longer delivered to any child. Children already damaged are
  **not** repaired retroactively — the sweep does not restore files, and both
  existing children needed their README restored from history by hand.
- Any future file the template ships that a child would reasonably own
  (`CONTRIBUTING.md`, `LICENSE`, `.editorconfig`) is now a claim away from being
  safe, rather than unprotectable.

## Alternatives Considered

**Add `README.md` to each child's `.templatesyncignore`.** Does not work — that
file is no longer read. This was the first instinct and checking it against the
engine is what surfaced the deeper gap.

**Union the template's and child's lists, and stop there.** Unsafe. It converts
the overwrite into a deletion the first time the template withdraws a claimed
file, which is silent and worse. Rejected on the mutation result.

**Revert t-0051 §1 and read the child's list again.** Reopens the first-sync
hole that cost children their `.gitignore` and compiled specs. Rejected.

**Let the sweep skip anything whose content differs from the template's.**
Content-based ownership is ambiguous — a child with an unmodified copy of a
genuinely withdrawn file would keep it forever. Ownership should be declared,
not inferred.
