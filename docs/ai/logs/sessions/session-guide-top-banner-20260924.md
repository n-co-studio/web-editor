# Session Log — Guide Top Banner

**Date:** 2026-09-24
**Branch:** feature/guide-top-banner (solo merge to main, seals branch)
**Session id:** 9772a09d-50ca-4b17-bc9f-2fc087fd02bc
**Work:** Masthead strip at the top of the hosted guide, carrying the nco.studio background and its hover effect.
**Mode:** auto (operator approval "Approve — auto")

---

## Summary

Operator-specified from Figma node 79:549: a strip above the guide reading "Welcome to the setup guide for:" / "Visual Web Editor for AI Agents" / "Created by" + the n'co wordmark, with the wordmark linking to nco.studio. Figma's flat `#2b2d2c` is replaced by the landing page's live background, and the logo link reproduces the landing page's blob dispersal on hover.

`LavaBackground.tsx` gained the scatter behaviour, ported from `~/Developer/nco-studio-site/assets/lava.js`: optional `scatterInsetMin`/`scatterInsetMax`/`scatterScale`/`scatterEase`, plus `rollScatterTargets` (each blob goes to its nearest edge, at a random position along it, re-rolled per hover) and `applyEdgeTargets` (inset held in CSS pixels, converted at apply time so a resize slides targets rather than reshuffling them). The frame loop eases `scatter` toward its target, smoothsteps the blend, and lerps the radius toward `scatterScale`. The operator chose the shared component over a banner-local copy, so the maths cannot drift from the site's.

Listeners attach only when `scatterEase > 0` **and** the field sits inside a `[data-lava-scope]` ancestor, watching `[data-lava-scatter]` within that scope for pointer enter/leave and focus/blur. The page's own field passes no scatter config and has no scope ancestor, so nothing attaches for it — the guide's existing background behaves exactly as before.

`TopBanner.tsx` renders its own field with `SITE_LAVA` (the site's forest greens on black, `blend: 'darken'`), the Figma copy on the demo app's type tokens, and the wordmark inside an anchor to nco.studio.

## Accessibility (both raised as CRITICAL by the Critic, both fixed)

- **Duplicate `<h1>`.** The banner first rendered the product name as an `h1`, competing with Hero's. The strip is now a `<header>` landmark whose product name is an `<h2>`, so Hero keeps the page's single top-level heading while heading navigation still reaches the product name.
- **Contrast.** `#cacaca` over the palette's lightest green (`#40916C`) computes to 2.3:1, and white to 3.8:1 — both below AA for normal-weight text, and the blobs drift under the text continuously rather than rarely. A 35% black scrim now sits between field and content, taking the grey to 4.6:1 and white to 7.5:1 while keeping the Figma colours exactly. This is a deliberate divergence from the landing page (which has no scrim, but far less type over its field) and is documented at the top of the component.

## Verification

- Real browser over CDP: hovering the logo moved the banner's mean blob spread 30 → 49 and back to 30 on leave; the page's own field stayed at ~28 throughout, confirming scope isolation. Re-run after the semantic changes with the same result.
- Screenshot of the rendered strip compared against the Figma frame, and against a screenshot of the live landing page — the two greens read as one surface.
- Contrast ratios computed against the composited scrim rather than estimated.
- typecheck clean; all workspaces build; `build:site` still produces the `/web-editor/` build; chrome-extension 140/140 (untouched); exactly one `<h1>` on the page.
- Pragmatist APPROVED with two advisory notes (shared-component scatter — the operator's explicit choice; two animation loops on one page — acceptable, with `active` available as a lever if it ever matters). Critic combined: BLOCKED on the two accessibility defects → APPROVED, then two follow-up recommendations (heading semantics, stale doc comment) also applied. QA APPROVED.

## Note for the operator

The banner is in the repo's demo app; the hosted page updates when `npm run deploy:site` is run and the site repo is committed and pushed.
