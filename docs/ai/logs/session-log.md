# Session Log

Each session adds one entry. Keep entries high-signal and readable.

**Rotation:** Keep last 3 sessions here. Move older entries to `session-archive.md`.

---

<!-- Template: copy this block for each new session entry

## Session N — YYYY-MM-DD — Brief description

**Status:** in-progress | complete
**Decisions applied:** [comma-separated IDs]
**Commits:** [hash — message]

### Goal
- [What this session set out to accomplish]

### Plan Summary
- [Key steps taken]

### Changes Made
- `path/to/file` — [what changed]

### Verification (Gates Evidence)
- Commit gates: A1 [pass/n-a], A2 [pass/n-a], A3 [pass/n-a], A4 [pass/n-a], A5 [pass/n-a]
- Push gates: B1 [pass/n-a], B2 [pass/n-a], B3 [pass/n-a]

### Failed Attempts (Brief)
- [None / brief description]

### Known Issues Logged
- [None / reference to known-issues.md entry]

### Follow-ups
- [Items deferred or discovered]

-->

## Session 13 — 2026-02-21 — State Toggles, CSS Variables, Attributes & Accessibility

**Status:** complete
**Decisions applied:** 0001, 0002, 0008
**Commits:** pending

### Goal
- Implement Brief 3: element state simulation (:hover/:focus/:active/:visited), CSS variable resolution tooltips, read-only attribute display in DOM tree, and accessibility insights section.

### Plan Summary
1. Create `StateSimulator` engine (scans stylesheets, strips pseudo selectors, applies via `StatePreviewManager`)
2. Add `:hov` button + toggle strip to `CssGroupsSection`
3. Wire `StateSimulator` eagerly in `PropertiesPane`
4. Add status cluster (layout badge + orange dot) and collapsible attribute display to `DomTreePane`
5. Wire state simulator from `PropertiesPane` to `DomTreePane` via `DevToolsPanel`
6. Create `VariableResolver` (walks matched rules + ancestors, resolves var() chains)
7. Create `var-badge.ts` enrichment (purple badge + click-activated tooltip)
8. Wire `VariableResolver` lazily in `PropertiesPane.ensureRulesInitialized()`
9. Create `AccessibilitySection` (4 checks: ARIA role, accessible name, missing ARIA, contrast reference)
10. Mount accessibility section at bottom of Edit tab

### Changes Made
- `packages/chrome-extension/src/content/inspection/state-simulator.ts` — **New** (~456 lines): `StatePreviewManager` (standalone inline style tracker), `StateSimulator` (pseudo selector stripping, ancestor hover chains up to 5 levels, specificity-sorted declaration collection)
- `packages/chrome-extension/src/content/inspection/variable-resolver.ts` — **New** (~171 lines): walks matched rules + ancestors (20 levels), recursion depth 10, circular detection, `getComputedStyle` fallback, token cross-reference
- `packages/chrome-extension/src/content/selection/panes/enrichments/var-badge.ts` — **New** (~235 lines): purple `var` badge, click-activated tooltip with resolution chain, source links, AbortController-based cleanup
- `packages/chrome-extension/src/content/selection/panes/accessibility-section.ts` — **New** (~451 lines): collapsible (collapsed by default), computed ARIA role (implicit/explicit), accessible name, missing ARIA warnings, contrast reference with scroll-to-property
- `packages/chrome-extension/src/content/selection/panes/css-groups-section.ts` — `:hov` button + toggle strip, `findWinningRule()` shared helper, var badge integration with tooltip, `setVariableResolver(null)` disposal, `dismissRoot` for shadow DOM
- `packages/chrome-extension/src/content/selection/panes/dom-tree-pane.ts` — Status cluster consolidation (layout badge + orange state dot), collapsible attribute detail section (priority-ordered, click-to-copy with green flash)
- `packages/chrome-extension/src/content/selection/panes/properties-pane.ts` — Eager `StateSimulator`, lazy `VariableResolver` (stored + disposed), `AccessibilitySection`, shadow root dismiss wiring, scroll-to-rule callback
- `packages/chrome-extension/src/content/selection/devtools-panel.ts` — Wires state simulator from properties pane to DOM tree pane

### Verification (Gates Evidence)
- Commit gates: A1 pass (0001/0002/0008 followed), A2 pass (plan documented, 8 files ~1780 lines — scope advisory noted), A3 pass (`tsc --build` + `tsc --noEmit` → 0 errors), A4 pass (no secrets), A5 pass (Critic cohesion: initial review found 3 criticals + 6 advisories; fixed 3 criticals + 2 advisories; re-run found 1 new critical (tooltip listener leak) + 2 advisories; fixed critical; build verified clean)
- Push gates: B1 pending, B2 pending, B3 pending

### Cohesion Findings & Resolutions
**Initial review (3 criticals):**
1. `onToggleChange` callback arity mismatch (pre-existing) — fixed: `(el)` → `(el, _property, _toggled)`
2. `VariableResolver` not stored/disposed — fixed: added field, stored in `ensureRulesInitialized()`, cleared in `dispose()`
3. `document.addEventListener` for tooltip dismiss incompatible with shadow DOM — fixed: added `dismissRoot` parameter, wires `shadowHost.shadowRoot`

**Re-run (1 critical):**
4. Tooltip click handler leaks on programmatic dismiss — fixed: AbortController pattern, `cleanupVarTooltip()` exported and called in `dismissVarTooltip()`

**Also fixed (advisories):**
5. Dead variables in `splitByCombinators` — removed
6. Accessibility double-fire warnings for form inputs — reordered checks with `isFormInput` guard

**Remaining advisories (non-blocking):**
- Redundant null-check on varBadge (harmless defensive code)
- DomTreePane stale simulator reference between dispose/remount (replaced synchronously before use)
- AccessibilitySection.scrollTarget not cleared (same contentArea element, safe)
- Multi-var authored values only partially resolved in tooltip (spec gap, not error)

### Failed Attempts (Brief)
- None (all issues found via cohesion review, fixed before commit)

### Known Issues Logged
- None

### Follow-ups
- `findWinningRule()` omits `excludeHost` parameter (advisory — shadow-host CSS leakage risk is low)
- Multi-var tooltip resolution covers only first var() in compound values
- CDP upgrade path deferred per brief recommendation

---

## Session 12 — 2026-02-21 — CSS Rules Display & Property Toggle

**Status:** complete
**Decisions applied:** 0001, 0002, 0008
**Commits:** pending

### Goal
- Build CSS rule matching engine with cache and graceful cross-origin degradation
- Activate Rules tab with specificity-ordered authored declarations
- Add property toggle checkboxes for cascade exploration
- Cross-reference authored values back into Edit tab annotations
- Implement ToggleManager for temporary CSS overrides via Constructable StyleSheet

### Plan Summary
- Phase 1: Create foundation types (`css-types.ts`) and specificity calculator (`specificity.ts`)
- Phase 2: Create rule matching engine (`css-rules.ts`) and WeakMap cache with MutationObserver invalidation (`matched-rules-cache.ts`)
- Phase 3: Create toggle manager (`toggle-manager.ts`) using Constructable StyleSheet API
- Phase 4: Create rules section renderer (`rules-section.ts`), activate Rules tab in `properties-pane.ts`
- Phase 5: Add Edit tab annotations and InlineEditor toggle coordination
- Phase 6: Verification — tsc, cohesion review (Critic), fix criticals, re-verify

### Changes Made
- `packages/chrome-extension/src/shared/css-types.ts` — **New** (~25 lines): `MatchedRule`, `AccessLevel`, `MatchResult` interfaces
- `packages/chrome-extension/src/content/inspection/specificity.ts` — **New** (~160 lines): CSS specificity calculator with `:where`, `:is`, `:not`, `:has`, pseudo-element support
- `packages/chrome-extension/src/content/inspection/css-rules.ts` — **New** (~350 lines): rule matching engine — iterates `document.styleSheets` + `adoptedStyleSheets`, handles cross-origin SecurityError, recurses into `@media`/`@supports`/`@layer`, 5000-rule ceiling, async chunked variant
- `packages/chrome-extension/src/content/inspection/matched-rules-cache.ts` — **New** (~190 lines): WeakMap + LRU(50) cache with document-level + element-level MutationObservers, exclusion-aware cache validation
- `packages/chrome-extension/src/content/inspection/toggle-manager.ts` — **New** (~155 lines): Constructable StyleSheet toggle with element-scoped `unset !important` rules, key-based index tracking (no browser selectorText readback)
- `packages/chrome-extension/src/content/selection/panes/rules-section.ts` — **New** (~520 lines): Rules tab renderer — specificity ordering, overridden detection, toggle checkboxes, pagination(50), filter, access banner
- `packages/chrome-extension/src/content/selection/devtools-panel.ts` — Passes `shadow.host` to PropertiesPane constructor
- `packages/chrome-extension/src/content/selection/panes/properties-pane.ts` — Lazy Rules tab activation (ToggleManager, MatchedRulesCache, RulesSection), tab switching with scroll preservation, eager idle indexing, toggle change callback, full dispose cleanup
- `packages/chrome-extension/src/content/selection/panes/css-groups-section.ts` — `setInspectionDeps()` for toggle/cache injection, `populateAnnotation()` with winning rule source + authored value display, excludeSheets-aware cache access
- `packages/chrome-extension/src/content/selection/panes/inline-editor.ts` — `setToggleManager()`, clears toggle when editing starts on toggled property

### Verification (Gates Evidence)
- Commit gates: A1 pass (0001/0002/0008 followed), A2 pass (plan documented, 10 files), A3 pass (`npx tsc --noEmit` → 0 errors, no lint/format tooling), A4 pass (no secrets), A5 pass (Critic cohesion: initial review found 4 criticals + 6 recs; all 4 criticals fixed; re-review found 0 criticals, 4 recs (pre-existing design limitations))
- Push gates: B1 pending, B2 pending, B3 pending

### Failed Attempts (Brief)
- Cohesion review found `rebuildIndexMap()` in ToggleManager read back browser-normalized `selectorText` which could differ from `generateSelector()` keys — fixed by sorting existing map entries and reassigning indices.
- Cohesion review found `onToggleChange` callback never registered — fixed by wiring in `ensureRulesInitialized()`.
- Cohesion review found cache served stale results when queried with different exclusion params — fixed by storing `excludeSheetsCount`/`hasExcludeHost` in cache entries and validating on hit.
- Cohesion review found `populateAnnotation` called cache without excludeSheets, leaking toggle sheet into annotations — fixed by building and passing excludeSheets from toggleManager.

### Known Issues Logged
- None

### Follow-ups
- Toggle → annotation refresh chain is incomplete (annotations re-render on tab switch, not live during Rules tab toggle) — acceptable as progressive enhancement
- `getMatchedRulesAsync` is exported but has no callers — available for future use on large pages
- Annotations only appear after Rules tab is opened (lazy init) — acceptable as progressive enhancement

---

## Session 11 — 2026-02-21 — Properties Panel Decomposition & Foundation

**Status:** complete
**Decisions applied:** 0001, 0002, 0008
**Commits:** pending

### Goal
- Decompose monolithic ~1530-line `DevToolsPanel` into composable pane modules with typed contracts
- Introduce `ComputedStyleSnapshot` for batched style reads (single `getComputedStyle` call per update)
- Design enriched property row structure with indicator/badge/annotation slots for future briefs
- Add tab bar with disabled "Rules" placeholder
- Pure refactor — zero user-visible changes except greyed-out Rules tab

### Plan Summary
- Add `ComputedStyleSnapshot` interface + `createStyleSnapshot()` + `snapshotGet()` to dom-utils.ts
- Extract 6 pane modules: ConsolePane, SourcePane, DomTreePane, InlineEditor, CssGroupsSection, PropertiesPane
- Rewrite DevToolsPanel shell as thin coordinator (~513 lines, down from 1530)
- Update product.md and boundaries.md specs
- Verify public API compatibility (index.ts unchanged, all 45 call sites intact)

### Changes Made
- `packages/chrome-extension/src/shared/dom-utils.ts` — Added `ComputedStyleSnapshot` (39 properties), `createStyleSnapshot()`, `snapshotGet()` helper
- `packages/chrome-extension/src/content/selection/panes/console-pane.ts` — **New** (~94 lines): log entries, clear button, browser console mirror
- `packages/chrome-extension/src/content/selection/panes/source-pane.ts` — **New** (~60 lines): source file:line + CSS selector display
- `packages/chrome-extension/src/content/selection/panes/dom-tree-pane.ts` — **New** (~230 lines): collapsible tree, expand/collapse, select/hover callbacks
- `packages/chrome-extension/src/content/selection/panes/inline-editor.ts` — **New** (~316 lines): token dropdown + freeform input, single/multi select
- `packages/chrome-extension/src/content/selection/panes/css-groups-section.ts` — **New** (~444 lines): 6 property groups, enriched row structure, token badges
- `packages/chrome-extension/src/content/selection/panes/properties-pane.ts` — **New** (~208 lines): tab bar (Edit/Rules), scroll persistence, delegates to CssGroupsSection
- `packages/chrome-extension/src/content/selection/devtools-panel.ts` — **Rewritten** (1530→513 lines): thin shell, delegates to 4 panes
- `docs/spec/compiled/v1/product.md` — Updated DevTools panel description
- `docs/spec/compiled/v1/boundaries.md` — Removed CSS rule location limitation

### Verification (Gates Evidence)
- Commit gates: A1 pass (0001/0002/0008 followed), A2 pass (plan documented, 10 files), A3 pass (`npx tsc --noEmit` → 0 errors, no lint/format tooling configured), A4 pass (no secrets), A5 pass (Critic cohesion: 1 critical (DomTreePane dispose/callback lifecycle) + 7 recommendations; fixed critical by documenting lifecycle contract; re-verified clean)
- Push gates: B1 pending, B2 pending, B3 pending

### Failed Attempts (Brief)
- Cohesion review found DomTreePane callbacks survive `dispose()` as an invisible contract — if dispose ever nulls callbacks, second show cycle breaks silently. Fixed by documenting the lifecycle contract (pane instances are long-lived, dispose is DOM cleanup only).

### Known Issues Logged
- None

### Follow-ups
- Brief 1B: Enrichment — populate indicator/annotation slots with rule source data
- Brief 2: Rules tab content implementation
- Brief 3: Additional property badges

---

## Session 14 — 2026-02-21 — Design Guide System + Ruler/Grid Enhancements

**Status:** complete
**Decisions applied:** 0001, 0002, 0008
**Commits:** ce77439 — feat: add Design Guide System, 5fd44c9 — fix: ruler overlay enhancements

### Goal
- Build Design Guide System: ruler bars with draggable guide lines for arbitrary alignment references
- Fix guide snap (HVST: sub-pixel grid spacing dominating edge snap)
- Add canvas-based pixel ruler bars, scroll-aware grid/guides, snap exclusivity, edge highlighting

### Plan Summary
1. Add guide color + z-index constants to constants.ts
2. Create `guide-snap.ts` pure snap function
3. Create `RulerOverlay` class (ruler bars, guide CRUD, snap, persistence)
4. Integrate guide snap into `DragHandleManager` (handles.ts)
5. Add toolbar ruler toggle button
6. Wire lifecycle in index.ts (toolbar, collapse, escape, scroll)
7. HVST: validate snap failure (gridSpacing 0.2px), fix with minimum threshold
8. Fix axis swap (top ruler → horizontal guides, left ruler → vertical guides)
9. Canvas-based rulers with pixel tick marks (1/5/10/50/100px intervals + labels)
10. Horizontal guides scroll with page (page coords), grid vertical scroll
11. Snap exclusivity: grid on → grid snap only; grid off → edge snap + 3px highlight

### Changes Made
- `packages/chrome-extension/src/shared/constants.ts` — Added `guide: '#8b5cf6'` to OVERLAY, `GUIDE_LINE_Z`, `RULER_BAR_Z`, `GUIDE_SNAP_THRESHOLD = 8`, `MAX_GUIDES_PER_PAGE`
- `packages/chrome-extension/src/content/editing/guide-snap.ts` — **New** (~22 lines): pure `snapToGuides()` function
- `packages/chrome-extension/src/content/ruler-overlay.ts` — **New then rewritten** (~870 lines): canvas rulers (DPR-aware), page-coord horizontal guides, EdgeEntry-based snap with highlight, grid/edge exclusivity, `chrome.storage.session` persistence
- `packages/chrome-extension/src/content/editing/handles.ts` — Added `guideGetter` param, viewport-to-CSS coordinate conversion for guide snap, `getEdgePosition()` helper
- `packages/chrome-extension/src/content/toolbar.ts` — Ruler toggle button + callbacks (same pattern as grid)
- `packages/chrome-extension/src/content/index.ts` — Full lifecycle wiring: RulerOverlay instantiation with `isGridVisible` callback, hover suppressor, collapse save/restore, escape ladder, scroll handler
- `packages/chrome-extension/src/content/grid-overlay.ts` — Added `refreshScroll()` method + initial `backgroundPositionY` in render

### Verification (Gates Evidence)
- Commit gates: A1 pass (0001/0002/0008 followed), A2 pass (plan documented), A3 pass (`tsc --noEmit` clean, build clean), A4 pass (no secrets), A5 pass (cohesion review on commit 1: 3 criticals found and fixed — null-deref in guideGetter, keyboard on shadow instead of document, coordinate space mismatch)
- Push gates: B1 pending, B2 pending, B3 pending

### HVST Cycles
1. **Snap not working (axis swap)**: H: axes swapped. V: user confirmed top ruler creates vertical lines. S: swap axis args + cursors. T: visual confirmation.
2. **Snap invisible (sub-pixel spacing)**: H: grid snap dominating with 0.2px spacing. V: debug log confirmed gridSpacing=0.2, bestDist=0.02. S: add `gridSpacing >= 4` guard. T: edge snap now triggers.
3. **Grid exclusivity not verified**: H: `isGridVisible()` may return wrong value. V: debug log added (pending operator validation). S: TBD based on validation.

### Failed Attempts (Brief)
- Initial snap threshold of 3px too tight — increased to 8px
- `isInsideRuler` checked wrong ruler bar for each axis — fixed in rewrite

### Known Issues Logged
- Grid snap exclusivity not fully validated (operator reported issue, debug log added but session closing)

### Follow-ups
- Validate grid snap exclusivity with debug log output (HVST cycle 3)
- Grid snap with tiny baseSpacing (0.2px) produces no visible snap even when grid is shown — may need to use majorSpacing or external settings

