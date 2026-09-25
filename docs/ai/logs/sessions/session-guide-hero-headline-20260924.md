# Session Log — Guide Hero Headline

**Date:** 2026-09-24
**Branch:** feature/guide-hero-headline (solo merge to main, seals branch)
**Session id:** a0fc7f01-d693-4d21-8929-6d67170ec4a6
**Work:** Third operator change request from the Visual Web Editor against the hosted guide.
**Mode:** auto

---

## Summary

1. **Standfirst removed** — the paragraph beginning "The Web Editor lets AI-native designers…". The hero is now the headline alone.
2. **Headline reworded** — "Setup your new AI design tool" → "Get to know your new AI design tool."
3. **Headline measure narrowed** — from 733px to 472px, so the longer sentence breaks over two lines instead of running the width of the column.

With the standfirst gone, the hero is a single `<h1>`. The section's `padding-bottom: var(--space-16)` now provides the whole gap down to the tabs, which is why that value was kept inline when `.nco-section` was dropped in the previous change.

## Divergence from a literal reading of the diff

As with the earlier request, the captured `width: 471.546875px` is applied as `maxWidth: '472px'`. A fixed `width` does not shrink, so it would overflow the content column on any viewport narrower than 472px; `max-width` gives the same two-line break at full size and still reflows on a phone. Sub-pixel precision dropped as capture noise. This is now the second time a dragged width has been translated this way — if fixed widths are ever actually wanted, say so and I will stop converting them.

## Verification

- `tsc --noEmit && vite build` clean.
- Live check over CDP: the `<h1>` reads "Get to know your new AI design tool."; the page no longer contains the standfirst text.
- Screenshot reviewed: the headline breaks after "your", giving two balanced lines, and the tabs sit directly beneath.

## Note for the operator

Repo-side only. nco.studio/web-editor/ still shows the previous page until `npm run deploy:site` runs and the site repo is committed and pushed.
