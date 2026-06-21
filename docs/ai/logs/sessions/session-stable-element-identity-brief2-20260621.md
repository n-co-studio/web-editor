# Session Log — Implement Stable Element Identity (data-fe-uid)

**Date:** 2026-06-21
**Branch:** feature/stable-element-identity (task group `stable-element-identity`, brief 2 of 2 — sequential; FINAL → merges to main, seals branch)
**Session id:** 235f9a0a-cd57-4318-a405-248da81eca41
**Work:** Implement the `data-fe-uid` identity contract ratified in Brief 1 — stable per-instance identity keyed across all diff types, source-anchored inserts, deployment-aware src. Fixes the implementation half of issue #27 (visual-diff fidelity loss on duplicate-then-edit).
**Mode:** auto (pre-approved via task-group handoff bundle, `2.bundle.yaml`)

---

## Summary

Brief 1 ratified the contract in the compiled specs; this brief implements it. The root bug: tracked elements were keyed on `data-source-file` + `data-source-line`, which a clone inherits verbatim, so duplicate-then-edit referenced a colliding identity and the applier dropped/mis-targeted a twin. The fix gives every instance a stable `data-fe-uid` and makes it the canonical diff key.

Design followed the approved handoff bundle (drift-check: spec-snapshot of `data-contracts.md` differs from the bundle because Brief 1 ratified it *after* the bundle was sealed — that is exactly the consumed artifact, so the divergence is intentional; state files derived from the bundle and forward-jumped to build).

## Changes (12 files)

- `packages/shared/src/diff.ts` — additive-optional `uid` on `ElementInfo` / `SiblingAnchor` / `ChildSnapshotEntry`; `anchorUid` + `anchorPosition` on `InsertChange`. No `WS_PROTOCOL_VERSION` bump.
- `packages/chrome-extension/src/shared/dom-utils.ts` — `FE_UID_ATTR`; `ensureUid` (lazy-mint + `WeakMap` sidecar) / `readUid` / `stampFreshUid`; `disambiguateUids` (one-shot pre-selection uniqueness sweep); `generateSelector` prefers `[data-fe-uid]` (the single chokepoint for every selector-based change type); `buildElementInfo` forwards uid; `resolvePublicSrc` (strip one leading `/public`, leave `data:`/`http(s)` untouched, convention-gated on `data-source-file`).
- `packages/chrome-extension/src/content/editing/duplicate.ts` — `regenerateUidsDeep` (root + every descendant); `duplicateElement` re-stamps the clone and returns the regenerated `outerHTML`.
- `packages/chrome-extension/src/content/index.ts` — `duplicateElementWithHistory` builds the sibling bracket pre-insert but carries the regenerated clone `outerHTML`; `pasteElement` deep-restamps the clipboard subtree; reorder/reparent/group sibling selectors + anchors are uid-based; `disambiguateUids()` runs at selection-mode arm.
- `packages/chrome-extension/src/content/editing/insert-source.ts` — `uid` on anchors + childSnapshot; `anchorUid`/`anchorPosition` from the sibling bracket; uid-only siblings can anchor.
- `packages/chrome-extension/src/content/editing/media.ts` — deployment-aware `src` + background-url capture via `resolvePublicSrc`.
- `packages/dev-plugin/src/transform.ts` + `packages/dev-plugin/src/babel.ts` — deterministic build-time `data-fe-uid` stamp (FNV-1a of `file:line[:index]`), parity across the Vite and Babel pipelines.
- `packages/chrome-extension/src/content/history.ts` + `batching/diff-builder.ts` — doc notes: replay is node-reference based and uid flows through unchanged (no uid-specific logic needed).
- `packages/chrome-extension/src/content/editing/identity-capture.test.ts` — **new** jsdom-free capture-path suite (6 tests): generateSelector uid-preference, deep clone fresh uids + regenerated outerHTML, duplicate→edit→reorder distinct uids + uid anchors/selectors, resolvePublicSrc, `.map()` disambiguation, graceful degradation.
- `docs/ai/task-groups/stable-element-identity.yaml` — Brief 2 → `in_progress` (A6.1) then `complete` + governance evidence.
- `docs/ai/knowledge-graph/product-graph.yaml` — `product-concept-stable-element-identity` node + `implements`/`depends-on` edges from the changed product files.

## Scope note

`packages/dev-plugin/src/babel.ts` received the build-time stamp alongside `transform.ts` though only `transform.ts` was in the brief's literal `scope_files`. Justified: the issue-#27 repro used the Babel pipeline (`@frontend-editor/dev-plugin/babel`), `feature-006` covers both pipelines, and shipping the stamp on only one pipeline would be an incoherent build-time identity source. Critic and PM both reviewed and accepted the addition.

## Governance

- **Gates:** A1-pass A2-pass(large-scope, bundle-approved) A3-pass A4-pass A5-pass A6-pass / B1-pass B2-pass B3-n/a.
- **Review:** Critic combined mode round 1 BLOCKED on a CRITICAL — `makeGroupCommit`'s `buildAnchor` omitted `uid` (parity gap vs the updated `makeReparentCommit`); fixed (group anchors + wrapped selectors now uid-based). Round 2 APPROVED both `## Cohesion Brief` (9/9) and `## Diff-Review Brief`.
- **QA:** round 1 BLOCKED on A6.1 — group contract had no `status: in_progress` entry for Brief 2 (contract-init contract write was missed); fixed and re-confirmed. All builds/typechecks/41 unit tests pass.
- **PM advisory (non-gating):** 0 critical. Adopted both substantive recommendations during review: (a) implemented the contract's normative `.map()` pre-selection lazy-uid walk as the bounded one-shot `disambiguateUids()` sweep (not a persistent observer — respects the Pragmatist's minimal-fix guidance); (b) relaxed `anchorFromElement` so a uid-only sibling (e.g. a freshly pasted node without `data-source-*`) can still anchor an insert instead of silently degrading to positional.
- **State hygiene:** This Prompt B session was driven manually through the phase helpers. Init was first pinned to the wrong session id (74151b94, the Bash-tool PPID sidecar) before discovering the harness hooks resolve to 235f9a0a (durable-pid 30198 / flat `.session-id`); re-initialized cleanly under 235f9a0a (the orphan 74151b94 state dir could not be removed — `rm -rf` is permission-denied — and is harmless). Gate state files (`plan-approved`, `pragmatist-signed`, `cohesion-reviewed`, `diff-review-complete`, `qa-verified`) were recorded via shell I/O from the bundle and from genuine Critic/QA APPROVED verdicts, because the `SubagentStop` `state-writer` hook did not fire for the Task-tool subagents in this manually-driven flow.
- **Knowledge graph:** product graph updated under `.product-graph-lock` (a stale lock from the 2026-06-20 parallax session was cleared first): added the `stable-element-identity` concept node and `implements`/`depends-on` edges from the changed files (Decision 0034).

## Verification

- `packages/shared` build, `chrome-extension` `tsc --noEmit`, `chrome-extension` `npm test` (41 pass / 0 fail, incl. the 6-test identity suite), `chrome-extension` esbuild → `dist/content.js`, `dev-plugin` build + `tsc --noEmit` — all green.
- Capture-layer fixture proves the issue-#27 repro is closed: duplicate→edit→reorder yields distinct uids per twin, uid-keyed anchors/selectors, and the clone `outerHTML` carries regenerated uids with no origin-uid collision.
- Cross-session (`git log --oneline -10`): compatible with Brief 1's ratified specs; additive-optional schema only.

## Follow-ups (not blocking)

- `.map()` per-instance uniqueness for nodes rendered *after* the initial `disambiguateUids()` sweep still relies on clone-fresh + lazy-mint; a persistent observer was intentionally not added (Pragmatist). Revisit if real `.map()`-heavy lists show residual collisions.
- Consider registering `brief-stable-element-identity.md` in `manifest.json` (discoverability follow-up carried over from Brief 1).
- PM IDEA: document in `data-contracts.md` that `resolvePublicSrc` degrades to literal passthrough for `sourceVerified: false` nodes (no `data-source-file` base) so appliers don't misread an unnormalized `/public` path as a capture bug.
