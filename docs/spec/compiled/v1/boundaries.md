# Boundaries & Exclusions

## What This Product Does NOT Do

- Does not create or delete DOM elements/components — except via scoped insert and delete operations (see Boundary Expansions)
- Does not work on production builds (dev-plugin is dev-only)
- Does not access cross-origin iframe content
- Does not modify closed Shadow DOM content
- Does not modify source files directly — it delegates all code changes to Claude Code via structured diffs
- Does not require or manage user accounts or authentication
- Does not communicate with any remote server — all traffic is localhost
- Does not support non-JSX/TSX projects for deterministic source mapping in v1 (Vue SFCs, Svelte, plain HTML fall back to 'source unverified' mode)

## Boundary Expansions

These expand specific boundary restrictions for well-scoped operations:

- **DOM node relocation for reorder**: `insertBefore`/`moveBefore` is permitted for reorder operations within the same parent container. This relocates an existing element without creating or deleting nodes.
- **DOM element creation for insert**: `document.createElement` + `insertBefore`/`appendChild` is permitted for insert operations within a scoped parent container. The new element is empty and styled via the standard visual diff pipeline.
- **DOM element removal for delete**: `element.remove()` is permitted for delete operations on existing elements. Already implemented in the content script.
- **DOM element reparenting for group**: `document.createElement` + `insertBefore` + `moveBefore`/`appendChild` is permitted for group operations that wrap sibling elements within the same parent into a new container element.
- **DOM node relocation for reparent**: `moveBefore`/`insertBefore` is permitted for reparent operations that move an element from one flex/grid container to a different flex/grid container. This relocates an existing element without creating or deleting nodes. Non-layout containers are not valid drop targets.
- **Scroll-driven and JS-scroll parallax (constrained)**: Two parallax mechanisms that the blanket "no JavaScript behavior / CSS-only" exclusion would otherwise forbid are **in scope for the parallax editor (feature-009) only**, via the dedicated diff change types in `data-contracts.md`:
  - **Pure-CSS scroll-driven parallax** — `@keyframes` + `animation-timeline: scroll()` carried as a `StylesheetChange`. This is CSS, but it crosses the "element-inline `PropertyChange` only" assumption, so it is scoped explicitly here.
  - **JS scroll-listener parallax** — a single enumerated behavior (`behavior: "parallax-scroll"`) carried as a `ScriptBehaviorChange` descriptor (intent + parameters, never literal JS).

  **Limits (all REQUIRE-level):**
  1. **Parallax-only.** The `ScriptBehaviorChange.behavior` enum admits exactly one value (`"parallax-scroll"`) in v1. This allowance does **not** reopen general JavaScript behavior editing (see Future Considerations) — any other behavior value is invalid.
  2. **Reproducible-to-source.** Both mechanisms must round-trip to maintainable project source (CSS rules / an idempotent, reviewable scroll handler), per "Source Rewrite Semantics" in `data-contracts.md`. No runtime-only patches.
  3. **Dev-only.** Same dev-mode constraint as the rest of the product — the dev-plugin and editor never touch production builds.
  4. **Chrome target.** `animation-timeline: scroll()` is not Baseline (no Firefox by default); the scroll-driven mechanism MUST ship an `@supports not (animation-timeline: scroll())` fallback to the CSS-3D mechanism. The JS-scroll mechanism is the universal fallback.
  5. **Accessibility mandatory.** Every parallax edit (all four mechanisms) MUST emit `prefers-reduced-motion: reduce` zeroing — as a `StylesheetChange` `@media` rule for the CSS mechanisms, and as a `matchMedia` short-circuit for the JS mechanism (WCAG 2.3.3).

## Scope Clarifications

- **CSS visual effects editing is in scope**: Editing CSS `filter`, `mix-blend-mode`, and basic `clip-path` shapes (`circle()`, `inset()`) via the extension overlay is supported. These produce standard `PropertyChange` objects in the diff pipeline.
- **Asset-level image processing is out of scope**: Pixel-level manipulation (crop, resize, color correction on image files) is deferred to the desktop app. The extension edits CSS properties applied to elements, not the underlying asset data.
- **Complex clip-path shapes are out of scope for v1**: `polygon()` and SVG-based `clip-path` editing require vertex manipulation UI unsuitable for an overlay. Deferred to desktop app.
- **Project-local component awareness is in scope**: The MCP server may discover the target project's local React components (JSX/TSX under `src/components/**`, `src/ui/**`, `components/**`, or operator-configured roots) and surface them as insertable elements in the insert panel. The extension does not author components — it only references existing project components via workspace-relative import paths in `InsertChange.componentInsert` descriptors. See feature-008.

## Future Considerations

These are out of scope for v1 but may be revisited in later versions:

- **General JavaScript behavior changes** — click handlers, state, application logic (v1 is visual/CSS properties only). **Exception:** the single `parallax-scroll` script behavior is constrained-in-scope for feature-009 (see Boundary Expansions → "Scroll-driven and JS-scroll parallax"). That carve-out is bounded by an enum of exactly one value and does not generalize — all other JS behavior editing remains deferred.
- **Browser support beyond Chrome** — Firefox, Safari
- **Mobile app companion** — dedicated app for editing mobile app UIs
- **Multi-editor support beyond Claude Code** (Cursor, Windsurf — MCP protocol already compatible)
- **MCP resources for design tokens** (currently exposed as tools only)
- **Prop editing for inserted components** — surface prop schemas and token-snap prop values (deferred to feature-008.1). v1 emits empty `props: []` on every `ProjectComponent` and `ComponentInsertDescriptor`; the `PropDefault` shape lives in v1 data contracts so feature-008.1 can land without schema migration.
- **External library component discovery (shadcn, Radix, MUI)** — gated behind `source: 'npm'` filter on `ProjectComponent` (deferred to v2). v1 only discovers project-local components (`source: 'local'`); the `'npm'` reservation is an extension hook with no v1 surface.

## Accepted Limitations

These are known limitations documented as explicit design choices:

- **Page reload clears in-progress edits**: A frontend page reload reinitializes the content script. Pending changes are restored from `chrome.storage.session`, but any edit actively in progress (mid-drag) is lost.
- **MCP server crash recovery depends on Claude Code**: The MCP server restart-on-crash behavior is a dependency on Claude Code's MCP client implementation. If Claude Code does not auto-restart, the operator must restart manually.
- **Token discovery executes user code**: Parsing `tailwind.config.ts` requires compiling and evaluating the config file via esbuild. This executes arbitrary user code in the MCP server process. Acceptable because the MCP server already runs in the project's trust context.

## Protected Areas

- The target project's source files are never modified by Frontend Editor directly — only Claude Code writes to source
- The dev-plugin never modifies source files — it transforms build output only
- Production builds must have zero trace of dev-plugin annotations

## Assumptions: NONE
<!--
  This section must remain empty.
  If you find yourself writing assumptions here, you have a gap in your spec.
  Go back to the relevant spec file and fill it in, or ask the operator.
-->
