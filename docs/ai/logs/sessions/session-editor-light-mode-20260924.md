# Session Log — Editor Light Mode

**Date:** 2026-09-24
**Branch:** feature/editor-light-mode (worktree daemon-20260924-193418-42449; solo merge to main)
**Session id:** daemon-20260924-193418-42449
**Work:** Add Light/Dark/System theme toggle for the Visual Web Editor's panel chrome.
**Mode:** auto (operator pre-approved headless runner)

---

## Summary

Implemented a three-way theme preference (Light / Dark / System) for the editor's shadow-DOM panel chrome, switchable from the toolbar-icon popup and persisted via `chrome.storage.local`. Changes apply live without tearing down the overlay or losing selection/queue state.

### Architecture

- **`shared/theme.ts`** — pure, testable module: `ThemePreference`, `ResolvedTheme`, `resolveTheme()`, `isThemePreference()`, `THEME_STORAGE_KEY = 'nco:theme'`.
- **`shadow-host.ts`** — dark palette gains `--fe-hover`, `--fe-active`, `--fe-bg-raised`, `--fe-text-inverse` tokens. New `:host([data-fe-theme="light"])` block with WCAG AA-verified light values (`--fe-primary: #0e7490` 5.33:1, `--fe-text: #18181b` 16.6:1, etc.). No `prefers-color-scheme` in CSS — attribute is the single mechanism.
- **`constants.ts`** — all OVERLAY chrome-color tokens migrated to `var(--fe-*)` CSS custom properties. New `SELECTION.ring = '#06b6d4'` for on-page selection indicators (fixed cyan, not themed).
- **`content/index.ts`** — `initTheme()` reads storage, stamps `data-fe-theme`, subscribes to `chrome.storage.onChanged` and `matchMedia('(prefers-color-scheme: dark)')`. `applyThemeToHost()` only sets host attribute and triggers ruler canvas redraw. `teardownTheme()` cleans up listeners.
- **`popup.html` + `popup.ts`** — Light/Dark/System radio group (`role="radiogroup"`, `aria-checked`, keyboard arrow-key navigation selects immediately via `next.click()`). Theme row stays enabled when extension is unavailable on non-localhost pages.
- **`web-env.ts`** — `chrome.storage.local` and `onChanged` no-op stubs for demo/web-embed mode.
- **`ruler-overlay.ts`** — `getCanvasColors()` reads `--fe-text-muted` and `--fe-border` from `getComputedStyle(host)` at draw time; canvas `fillStyle` never receives a `var()` reference.
- **20+ editing/selection panel files** — `rgba(255,255,255,0.08)` hover wash replaced with `OVERLAY.hover`; `rgba(255,255,255,0.06)` subtle background replaced with `OVERLAY.hover`; `ui-utils.ts createButton()` hover migrated; `BOX_MODEL.borderFill` migrated to `OVERLAY.active`.

### On-page vs panel chrome separation

`OVERLAY.primary` was used in both panel chrome (accents, now themed) and on-page selection indicators (must stay fixed). Resolved by introducing `SELECTION.ring = '#06b6d4'` for on-page uses (`hover.ts`, `handles.ts`, `move.ts`). Guide hover in `ruler-overlay.ts` uses literal `'#0891b2'` (on-page indicator).

## Verification

- Tests: 153/153 pass (includes new `theme.test.ts`)
- Typecheck: clean (`tsc --noEmit`)
- Build: clean (4 bundles)
- Critic (combined mode): GATE_RESULT APPROVED, 0 critical findings. 3 recommendations found and fixed (ui-utils.ts hover literal, BOX_MODEL.borderFill literal, popup arrow-key-selects gap)
- QA: all gates A1–A6, B1–B3 pass

## Commit

`df179da` feat(theme): add Light/Dark/System theme toggle to editor panel chrome
