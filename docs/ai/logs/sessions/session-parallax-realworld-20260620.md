# Session Log — Parallax editor: real-world hardening + detect/adopt

**Date:** 2026-06-20
**Branches (sequential, all merged to main):** feature/parallax-editor (Brief 2 build) -> fix/parallax-height-collapse -> feature/parallax-adopt-existing
**Work:** Make the feature-009 parallax editor behave correctly against real pages, matching a hand-built reference, and let it detect/adopt parallaxes authored outside the tool.
**Mode:** operator-directed, iterative (live-tested each round)

---

## Summary

After landing feature-009 (Brief 2), live testing against a real target app (the markpreston project, a nested-scroll SPA) surfaced a series of real-world gaps the static gates could not catch. Fixed them in sequence, each Critic+QA gated and merged:

1. **Height collapse** — the converted `<div>` (replacing an `<img>`) collapsed to 0 in flex containers. Root cause: flex-shrink ate the explicit height. Fix: `flex-shrink: 0` (+ `display:block`); later removed the interim `min-height` floor so the banner height drags freely. Height preserved across mechanism/strength rebuilds.
2. **Scroll source** — effects assumed page/window scroll, but content lived in a nested scroll container (inner overlay). Added `ParallaxScrollSource` (auto/page/container) + `resolveScrollContainer`/`effectiveScroller`, a "Scroll source" UI control, and `ScriptBehaviorParams.scrollSource` (shared + data-contracts + mcp apply guidance). The JS scan uses capture-phase window scroll, which catches inner scrollers regardless.
3. **Wrong effect** — initial mechanisms translated the whole element instead of scanning the image. Reworked to the **background-scan** model after reading the operator's working reference (`markpreston/src/app/portfolio/page.tsx` + `page.module.css`): a clip box + inner layer; the runtime cover-sizes the inner to the viewport and counter-translates it (`translate3d(base - boxRect)*strength`) so the image is viewport-pinned and the box reveals a fixed slice. Made this the default mechanism (`js-scroll`).
4. **Mechanism lineup** (operator chose "keep all, make 3D work"): **Background scan (JS)** default; **Scroll-driven (CSS)** reworked to an oversized-inner (250%) `animation-timeline: view()` scan (sensitive, strength-scaled to ~70% of box); **3D depth** made scroll-linked (same CSS scan + perspective/`translateZ` depth); **Fixed** kept as the page-only lightweight option (honest note).
5. **Detect & adopt** — `detectExternalParallaxUnit` recognises a clip box + absolutely-positioned inner background layer with no tool markers (the operator's hand-built parallax); a "Parallax (detected)" Adopt affordance converts it into a tool-managed block (preserving image/height/identity) so it becomes tunable.
6. **Selection priority** — a click on a parallax selects the banner box first; a quick second click drills into the background layer (`parallaxBoxForInner` + click-timing).

## Changes (across the three branches)

- `packages/chrome-extension/src/content/editing/parallax.ts` — scroll-source model + resolvers; `ParallaxRuntime` (viewport-pin JS scan via capture scroll; CSS scan via `animation-timeline: view()`); `buildScanBlock`/`buildCssScanBlock` (box+inner, depth variant for 3D); detect/adopt (`detectExternalParallaxUnit`, `adoptExternalParallax`, `parallaxBoxForInner`); `setAuthoritativeHeight` (flex-shrink:0, no floor); per-mechanism default strength.
- `editing/media.ts` — "Scroll source" control; Adopt section; reordered/relabelled mechanisms with honest notes; focus rings.
- `content/index.ts` — scroll-source threaded through commit/update; `makeParallaxAdopt`; banner-first selection + double-click drill-in.
- `packages/shared/src/diff.ts` (+ index.ts) + `docs/spec/compiled/v1/data-contracts.md` — `ScriptBehaviorParams.scrollSource`.
- `packages/mcp-server/src/server.ts` — apply guidance for scrollSource; corrected reduced-motion prose (CSS mechanisms emit the StylesheetChange; js-scroll uses the handler matchMedia short-circuit).

## Governance

- Three gated merges to main: `fix/parallax-height-collapse` (Critic blocked on a reduced-motion doc contradiction; fixed; re-APPROVED; QA APPROVED) and `feature/parallax-adopt-existing` (Critic APPROVED both sections, 2 cheap rec fixes applied; QA APPROVED). All tsc (3 pkgs) + build + 35/35 tests green at each merge.
- Knowledge graph: no new file nodes (only existing parallax/media/index files edited); the feature-009 product-graph edges remain current — close-time KG write was a no-op (Decision 0034 Amendment 3: attempted, nothing to add).

## Verification

- `tsc --noEmit` clean for shared, chrome-extension, mcp-server; `npm run build` produces dist/content.js; `npm test` 35/35.
- Operator-verified live: scan matches the reference; scroll-driven sensitive; 3D scans with depth; detect/adopt works on the existing Levantine banner; selection and height-drag behave as expected.

## Hard stops honored

No store upload. Operator explicitly authorized the merge to main and push to origin at session close.
