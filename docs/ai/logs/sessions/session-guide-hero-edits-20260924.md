# Session Log — Guide Hero Edits (operator change request)

**Date:** 2026-09-24
**Branch:** feature/guide-hero-edits (solo merge to main, seals branch)
**Session id:** a0fc7f01-d693-4d21-8929-6d67170ec4a6
**Work:** Apply a change request produced by the extension itself against the hosted guide.
**Mode:** auto

---

## Summary

The operator used the Visual Web Editor on http://localhost:5173 and submitted four pending diffs. This is the first change request in this repo authored through the product rather than written by hand, so the source mapping (`data-source-file` / `data-source-line`) is what located every edit.

Applied:

1. **Hero eyebrow** (`Hero.tsx`) — `font-family` mono → serif. The diff arrived token-snapped (`toToken: font-serif`), so the edit is `var(--font-mono)` → `var(--font-serif)`; no literal entered the source.
2. **Hero headline text** (`Hero.tsx`) — "Design directly on the page, / AI builds in the background." → "Setup your new AI design tool!". The `<br />` goes with it; the new headline is a single clause.
3. **Hero headline width** (`Hero.tsx`) — see divergence below.
4. **Steps row removed** — see divergence below.

## Two divergences from a literal reading of the diff

**Width: `width: 733.05859375px` applied as `maxWidth: '733px'`.** The captured value is a drag result, and the element already carried `maxWidth: '24ch'`. Taken literally, a fixed `width` would have overflowed the content column on any viewport narrower than 733px, because a block element does not shrink below an explicit width. The operator's intent is legible from the text change that preceded it: the new, shorter headline should not wrap. `max-width` delivers exactly that at full size while still reflowing on narrow screens. Sub-pixel precision dropped as capture noise.

**Removal applied at the call site.** The diff removes the `.nco-steps-grid` div from its parent section. Doing that inside `StepsRow.tsx` would have left a `<section>` with nothing in it but a bottom margin. The component is the section, so the faithful equivalent is to stop rendering `<StepsRow />` in `App.tsx`. `StepsRow.tsx` is left in place, and `examples/demo-app/README.md` moves it into the documented "not rendered" list alongside `Faq`, `Benefits`, `Walkthrough` and `SiteFooter`.

## Verification

- `tsc --noEmit && vite build` clean (37 modules, down from 38 — StepsRow no longer in the graph).
- Live check over CDP against the dev server: headline text is "Setup your new AI design tool!", its computed `max-width` is `733px`, the eyebrow resolves to `minion-3-display, "Playfair Display", Georgia, serif`, and `document.querySelectorAll('.nco-steps-grid').length` is 0.
- Full-page screenshot reviewed: the headline sits on one line, the steps row is gone, the masthead and the tabbed guide are untouched.

## Note for the operator

Repo-side only. nco.studio/web-editor/ still shows the previous page until `npm run deploy:site` runs and the site repo is committed and pushed.
