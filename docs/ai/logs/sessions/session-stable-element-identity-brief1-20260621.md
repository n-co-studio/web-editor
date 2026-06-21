# Session Log — Ratify Stable Element Identity (data-fe-uid)

**Date:** 2026-06-21
**Branch:** feature/stable-element-identity (task group `stable-element-identity`, brief 1 of 2 — sequential; non-final, no merge/seal)
**Session id:** cb46b909-a7cd-4b78-962f-421fa04931d6
**Work:** Spec-first ratification of the per-instance element-identity contract (`data-fe-uid`) in the compiled specs, ahead of implementation. Fixes the spec half of issue #27 (visual diffs lose fidelity on duplicate-then-edit because identity is keyed on `data-source-line`, which collides for clones).
**Mode:** auto (pre-approved via task-group handoff bundle)

---

## Summary

Issue #27: every tracked element is identified by `data-source-file` + `data-source-line`. A **duplicate** is a DOM copy that inherits the origin's `data-source-line`, so the two instances are indistinguishable in the diff payload. A single duplication is recoverable; the **second** operation on either twin references the shared identity and the applier mis-targets — one twin is dropped, ordering breaks. `.map()` runtime instances carry the same latent collision.

This brief ratified the fix contract in the compiled specs (no product code — that is Brief 2):

1. **`uid` is the canonical diff-targeting key** on `ElementInfo`, `SiblingAnchor`, `ChildSnapshotEntry` (read from `data-fe-uid`). `data-source-*` demoted to code-map hints — they locate source, never establish identity.
2. **Source-anchored `InsertChange`** — `anchorUid` (a sibling `uid`) + `anchorPosition` (`before`|`after`), parallel to `ReparentChange`; positional `nth-of-type` becomes the fallback. Normative anchor table added.
3. **uid -> source mapping** — three cases: (a) existing element -> `sourceFile`+`sourceLine` hint, edit in place; (b) clone -> fresh uid + `outerHTML` + origin `sourceLine` hint, applier *creates* new source near origin (origin untouched); (c) fresh insert -> `anchorUid` + position + `outerHTML`.
4. **Stamping lifecycle** — build-time dev-plugin stamp primary (survives React reconciliation); runtime fresh-uid on clone/paste (deep subtree); runtime lazy uid for `.map()` instances and `sourceVerified:false` nodes; WeakMap-sidecar option for reconciliation resilience; pre-observation-window note.
5. **Deployment-aware src normalization** — strip a single leading `/public`; leave `data:`/`http(s)` untouched; framework-scoped (Next.js/Vite-default), convention-gated.
6. **Protocol compatibility** — `uid`/`anchorUid`/`anchorPosition` are additive-optional -> no `WS_PROTOCOL_VERSION` bump (stays `0.4.0`); pre-uid consumers degrade to selector targeting.

## Changes

- `docs/spec/compiled/v1/data-contracts.md` — `ElementInfo.uid`; new `## Stable Element Identity (data-fe-uid)` section (SiblingAnchor/ChildSnapshotEntry uid tables, uid->source mapping, stamping lifecycle, src normalization, protocol-compat); `InsertChange` anchor fields + normative anchor table; `ReparentChange` sibling-identity note; cross-link from the feature-009 protocol note.
- `docs/spec/compiled/v1/features/brief-stable-element-identity.md` — **new** feature brief (identity model, lifecycle, source-anchored insert, alternatives considered).
- `docs/spec/compiled/v1/features/feature-006-dev-plugin.md` — `data-fe-uid` Output + 3 acceptance criteria (build-stamped, HMR-preserved, fresh-uid-on-clone).
- `docs/spec/compiled/v1/features/feature-001-element-selection.md` — `data-fe-uid` as identity input; `data-source-*` clarified as location hints; 2 acceptance criteria.
- `docs/ai/governance/spec-compiled.yaml` — feature-brief entry + 3 contract-change entries.
- `docs/ai/task-groups/stable-element-identity.yaml` — **new** task-group contract; brief 1 -> `complete` + governance evidence.

## Governance

- **Gates:** A1-pass A2-pass(large-scope) A3-n/a(docs-only) A4-pass A5-pass A6-pass / B1-pass B2-n/a B3-n/a.
- **Review:** Critic combined mode BLOCKED once on a CRITICAL (a dangling `Alternatives Considered` reference into the brief); fixed by adding the section; re-run APPROVED both `## Cohesion Brief` and `## Diff-Review Brief`. QA APPROVED. PM advisory: 0 critical, 3 recommendations (manifest registration deferred to Brief 2; `src` framework-scope + `.map()` pre-observation timing folded into the spec).
- **Override:** `REPO_OS_ALLOW_REINIT=1` at init — re-initialized over stale `taskdef-brief` phase-state left by the Prompt T session that produced the handoff bundle (same session-id reused; legitimate new Prompt B session). Logged in overrides.log.
- **State hygiene:** stale per-session gate files (`cohesion-reviewed`/`diff-review-complete`/`qa-verified`) from the prior parallax session sharing this session-id were cleared at build entry so this brief regenerated them.
- **Knowledge graph:** attempted at close, no-op — the brief changed only compiled-spec docs (no product source files), and the product graph models product source files only; nothing to add that fits the graph's scope (Decision 0034 Amendment 3: attempt made, nothing to write).

## Verification

- Critic + QA both APPROVED against the staged diff (6 files, +346/-12).
- Feature-009 parallax content in `data-contracts.md` (`StylesheetChange`/`ScriptBehaviorChange`/`scrollSource`) confirmed intact — the uid sections are strictly additive, no overlap.
- Cross-session (`git log --oneline -10`): compatible with recent parallax sessions; no scope-file conflict.
- No product code, no build/test surface in scope (Brief 2 implements against this contract).

## Handoff to Brief 2

Brief 2 ("Implement stable element identity — applier + runtime") consumes this ratified contract:
- Add `uid?` to `ElementInfo`/`SiblingAnchor`/`ChildSnapshotEntry` and `anchorUid?`/`anchorPosition?` to `InsertChange` in `packages/shared/src/diff.ts`.
- Implement the stamping lifecycle (dev-plugin build stamp; content-script runtime fresh/lazy uid; optional WeakMap), deployment-aware `src` normalization, and applier uid->source resolution for the three cases.
- Update the stale `RemoveChange` JSDoc in `diff.ts` (still calls selector+source identity primary).
- Consider registering `brief-stable-element-identity.md` in `manifest.json` (deferred discoverability follow-up).
