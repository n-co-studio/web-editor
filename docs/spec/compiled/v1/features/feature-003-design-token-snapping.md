# Feature: Design Token Snapping

## Summary
When design tokens are loaded from the project, constrain all edits to valid token values. Visual feedback shows token stops on drag handles, palette constraints on color pickers, and token names alongside values.

## User Flow
1. Operator activates extension on a project with a design system
2. MCP server auto-discovers tokens from the project (priority order below)
3. Extension loads tokens via WebSocket and constrains all editing to valid token values
4. Spacing drag handles snap to token stops with visual ruler
5. Color picker shows only palette colors
6. Typography dropdown shows only type scale options
7. If operator needs a non-token value, they use the "custom value" escape hatch

### Token Discovery Priority
1. `tailwind.config.js` / `tailwind.config.ts` / `tailwind.config.mts` / `tailwind.config.cts` — parse theme. Note: the TS variants (`.ts`, `.mts`, `.cts`) are executable code. The MCP server uses esbuild to compile them before reading the theme — this executes user code in the server process (trust boundary documented in boundaries.md). The compile step uses esbuild `transform` (not `build`), so a TS config that imports sibling modules will fail to evaluate and degrade to no-tokens for that source; a single-file config is required for TS token discovery.
2. `tokens.json` / `design-tokens.json` — Style Dictionary format
3. `docs/spec/compiled/{active}/design-system.md` — parse markdown tables (repo-OS)
4. CSS custom properties (`--*`) in `src/**/*.css` files. Scan is scoped to `src/**/*.css` with standard exclusions (node_modules, dist, build, .cache). Maximum 200 CSS files; warn and truncate if exceeded.
5. **Page-inferred values (fallback tier — [feature-011](feature-011-page-value-inference.md)).** When sources 1–4 yield **nothing** (the `TokenStore` is empty), the extension harvests the values already in use on the live page (its colors, type scale, spacing, radii, shadows) and offers the most common ones as selectable defaults. This tier is **client-side only** (runtime DOM/CSSOM, not a server file scan), it is a **last-resort fallback beneath the design system — not a peer of it**, and its values are **observed reality, not design intent**: they are held in a separate `PageValueStore` (never the token registry / never `DesignToken`), they never populate `PropertyChange.toToken`, and they carry `fromPageInference: true`. Real tokens always win — if tokens later arrive over WebSocket, page-inferred values are dropped. See [feature-011](feature-011-page-value-inference.md) for the full contract.

### File Watcher
File watcher uses chokidar with 300ms debounce. Granularity: per-source rebuild (only the changed source type is re-parsed, not the full registry flush).

## UI States
- **Default**: Tokens loaded, editing constrained — token ruler visible on drag handles, palette shown in color picker
- **No Tokens**: No token sources found **and no page-inferred values available** (blank page, or every harvested value fell below the frequency floor) — freeform editing, no snapping, values sent as raw CSS. This is the bare freeform floor; when page values *are* harvestable, the **Page Defaults** state applies instead.
- **Page Defaults** ([feature-011](feature-011-page-value-inference.md)): No token sources found, **but** the extension harvested values already in use on the page. Editors show an **"On this page"** option group (the ranked page-inferred values) rendered **above** the freeform floor and **visually distinct** from real token swatches (an "observed" affordance, never the token treatment), so the operator can always tell a page value from a design token. Distinct from **No Tokens** (which has no shortlist) and from **Default** (real tokens): page-inferred selections emit a `PropertyChange` with `fromPageInference: true` and **no `toToken`**, are held in a separate `PageValueStore` (never `DesignToken`), and are **superseded and dropped** the moment real tokens arrive over WebSocket. The freeform escape hatch remains available beneath the shortlist. See [feature-011](feature-011-page-value-inference.md).
- **Snapped**: Value matched to a token — token name displayed next to value (e.g., `16px → space-4`). Token ruler renders as a linear track adjacent to the drag axis, with tick marks at token stops. Only the two nearest token labels are shown at any drag position to avoid overlap. Snapped state uses success color (#22c55e) on the handle.
- **Between Tokens**: Drag position falls between two token values — nearest two tokens shown, handle color changes to neutral during drag. On release, snaps to closest with 100-150ms ease transition so operator sees the snap.
- **Custom Override**: Operator explicitly chose a non-token value via escape hatch — value accepted, flagged in diff as custom

## Inputs
- `DesignToken[]` from MCP server (discovered at startup, rebuilt on file change)
- Current CSS property being edited (determines which token category applies)

## Outputs
- Token-resolved `PropertyChange` with `fromToken` and `toToken` fields populated when tokens match
- Custom-flagged `PropertyChange` when operator uses escape hatch (toToken absent, value is raw CSS)

## Edge Cases
- No tokens found → freeform editing, no snapping, values sent as raw CSS
- Value falls between two tokens → snap to nearest, show both options
- Operator wants a non-token value → "custom value" escape hatch, flagged in diff
- Multiple token sources found → merge in priority order, first match wins on name conflicts. Documented as explicit rule.
- Token file changes while extension is active → MCP server rebuilds registry, pushes update to extension. Token updates are applied between edits — if an edit is in progress (drag handle active), the update is queued and applied on commit.

## Acceptance Criteria
- [x] Tokens auto-discovered from tailwind.config.js/ts (TS variants `.ts`/`.mts`/`.cts` compiled via esbuild)
- [ ] Tokens auto-discovered from tokens.json / design-tokens.json (Style Dictionary format)
- [ ] Tokens auto-discovered from design-system.md markdown tables
- [ ] Tokens auto-discovered from CSS custom properties
- [ ] Spacing drag handles snap to token stops with visible ruler
- [ ] Color picker constrains to palette colors when tokens loaded
- [ ] Typography dropdown shows type scale options when tokens loaded
- [ ] "Custom value" escape hatch allows non-token values and flags them in the diff
- [ ] Graceful fallback to freeform editing when no tokens are found **and no page-inferred values are available** (bare "No Tokens" floor)
- [ ] When no tokens are found **but page values are harvestable**, the "Page Defaults" state applies: an "On this page" shortlist of page-inferred values renders above the freeform floor, visually distinct from token swatches, emitting `PropertyChange` with `fromPageInference: true` and no `toToken` (full contract in [feature-011](feature-011-page-value-inference.md))
- [ ] Snap-on-release behavior produces visible ease transition (100-150ms)
- [ ] Token ruler shows only two nearest labels to prevent overlap
- [ ] CSS custom property scan respects src/**/*.css scope with exclusions
