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

## Scope Clarifications

- **CSS visual effects editing is in scope**: Editing CSS `filter`, `mix-blend-mode`, and basic `clip-path` shapes (`circle()`, `inset()`) via the extension overlay is supported. These produce standard `PropertyChange` objects in the diff pipeline.
- **Asset-level image processing is out of scope**: Pixel-level manipulation (crop, resize, color correction on image files) is deferred to the desktop app. The extension edits CSS properties applied to elements, not the underlying asset data.
- **Complex clip-path shapes are out of scope for v1**: `polygon()` and SVG-based `clip-path` editing require vertex manipulation UI unsuitable for an overlay. Deferred to desktop app.

## Future Considerations

These are out of scope for v1 but may be revisited in later versions:

- **JavaScript behavior changes** — click handlers, state, logic (v1 is visual/CSS properties only)
- **Browser support beyond Chrome** — Firefox, Safari
- **Mobile app companion** — dedicated app for editing mobile app UIs
- **Multi-editor support beyond Claude Code** (Cursor, Windsurf — MCP protocol already compatible)
- **MCP resources for design tokens** (currently exposed as tools only)

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
