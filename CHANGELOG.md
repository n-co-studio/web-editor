# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.1] - 2026-10-12

Renames the product to **AI Agent Visual Editor**, and fixes the editing panels — several colour controls in the shipped 0.2.0 build did nothing at all when clicked.

### Added

- **Border radius panel** — radius gets the same panel treatment as every other tool: an "All corners" row plus a 2×2 grid for per-corner control.
- **"No colour" in the colour picker** — clearing a colour no longer depends on the project having design tokens; the option is present either way and commits `transparent`.
- **Queue entries highlight what they change** — hovering a row in the Change Request Queue highlights the corresponding element on the page.
- **Copy-prompt buttons in the hosted guide**, including a watch-loop prompt that returns the agent to watching until told otherwise.
- **Light / Dark / System theme toggle** — the toolbar-icon popup now has a three-way theme control (Light / Dark / System). The preference persists via `chrome.storage.local` and applies live without reloading the overlay. System mode follows the OS `prefers-color-scheme` setting and is the default.
- **Two-column toolbar** — the floating toolbar lays its sections out in two columns, 608px tall instead of 978px, so it fits an ordinary viewport with every section open instead of auto-collapsing to cope.

### Fixed

- **Colour controls were dead across the whole product.** Panels build their subtree and attach it to the shadow root last, so the popover resolved its host while the swatch was still detached and was never inserted into any document. Opening it set `display` on an orphan: nothing appeared and nothing threw. A second fault sat behind it — shadow-DOM event retargeting made a `pointerdown` inside the popover look like an outside click, dismissing it before the selection could land. Both are covered by regression tests that reproduce the real topology.
- **Non-colour values no longer reach the colour picker**, and the Typography colour control no longer offers a dropdown of things that aren't colours.
- **Three panels clipped their contents** (Typography, Spacing, Position) — two distinct CSS causes: a bare `1fr` track resolving to `minmax(auto, 1fr)`, and range inputs asserting a content-based minimum width.
- **Apply Changes failed contrast in light mode.** `--fe-primary` was darkened to sit on white as text, then reused as a button fill with hardcoded black text. Fill and text roles now carry opposite foregrounds via `--fe-on-primary`; the same mistake was found and fixed in two other places.
- **The inline text toolbar no longer flickers** — it is pinned and positioned from the selection rather than hidden and re-shown as the cursor moves.
- **White colour swatches share one outline** regardless of fill, so a white swatch is visible against a white panel.
- **Toolbar can no longer be stranded off-screen** — a position restored from a larger window, or a window resized after the toolbar was placed, could leave it entirely outside the viewport with no way to reach it short of a reload. It is now re-pinned inside the viewport on restore and on resize, including while collapsed.

### Changed

- **Privacy and security documentation now describes the agent boundary.** The extension and MCP server still send your data nowhere, but "no data leaves your machine" was never true of the *agent* the server hands edits to — most agents forward what they read to a model provider. `docs/privacy-policy.md` gains a "What your agent sees" section enumerating what an edit carries, and SECURITY.md, both READMEs, the store listing and the hosted guide say so plainly. No behaviour change.

## [0.2.0] - 2026-09-21

First public release: Chrome Web Store extension 0.2.0 and both npm packages at 0.2.0.

### Added

- **First-install onboarding** — the extension opens the setup guide at https://nco.studio/web-editor/ once on first install
- **Popup setup guide link** — "Setup guide" link in the toolbar popup opens the hosted guide in a new tab
- **Inline text styling** — style ranges of text inside an edited element; changes travel as `TextChange` diffs
- **Structural editing** — auto-layout aware insert, reorder, and reparent, plus a toolbar-anchored drag-to-reorder list panel
- **Parallax editor** — detect, adopt, and tune existing parallax effects across four mechanisms
- **Page-value inference** — when no design tokens are loaded, controls offer values already used on the page ("On this page"), with freeform color input as the final fallback
- **Stable element identity** — `data-fe-uid` anchors diffs and inserts; every element reference carries a resolved asset path and label
- **Batch identity** — each dispatch is grouped under a `batchId` surfaced through the MCP tools
- **Notes** — a new note auto-attaches the whole current selection
- **Toolbar** — per-section collapse with viewport-height auto-fit
- **MCP server instructions** — the server describes its workflow to agents that have no project-specific guidance
- Token discovery from `tailwind.config.ts` / `.mts` / `.cts`
- Guidance for Chrome's Local Network Access prompt: the Review changes panel explains the permission when nothing has ever connected, and the quickstart, store reviewer notes and guide troubleshooting cover it
- Localhost-only activation is now enforced in code, not just declared: the popup refuses to inject into non-local pages and the content script refuses to activate on them (the public web-embed demo is exempt by design)

### Changed

- MCP setup guidance now uses `.mcp.json` at the project root (Claude Code reads project MCP servers from there) and pins `@^0`
- Image sources in diffs resolve to project paths; base64 payloads are no longer embedded
- Accessibility: radio-group tool semantics, modal focus trap, keyboard resizers, tab/region semantics
- Repository moved to `github.com/n-co-studio/web-editor`

### Fixed

- Rule-assigned spacing values (including pseudo-class rules) now appear in the spacing panel
- Clicks inside a text element being edited place the caret instead of reselecting
- Popup on/off indicator updates in real time
- Service worker `onMessage` no longer holds a reply channel open for unrecognized message types; `return true` (async-wait) is now scoped only to `CAPTURE_VIEWPORT`, which is the sole asynchronous branch

### Security

- WebSocket bridge hardened: the extension confirms the MCP peer before disclosing identifiers, and asset writes are confined to the project
- Untrusted markup is sanitized and runtime messages are authenticated in the extension
- Resolved 13 transitive dependency advisories (8 high, 4 moderate, 1 low) via `npm audit fix`; no behavior change. One remaining low-severity finding in tsup's nested esbuild (Windows dev-server only) is escalated — not fixable without `--force` or a major tsup upgrade that does not yet exist.
- MCP bridge security tests: `isAllowedOrigin`, `confineToProject`, and `resolveAssetDir` rejection paths are now covered by automated tests (look-alike hosts, path traversal, absolute-outside-project, and empty/missing origin)
- Tailwind config loader writes compiled configs to a private per-process directory created by `mkdtemp` (mode 0700), preventing TOCTOU races on the previously predictable shared temp path; files within the directory are written with the `wx` flag so a content-hash collision is treated as a safe cache hit

## [0.1.0] - 2026-06-17

Initial public release of AI Agent Visual Editor.

### Packages

- `@nco-studio/web-editor-mcp` — MCP server bridge connecting Claude Code to the Chrome extension via localhost WebSocket
- `@nco-studio/web-editor-plugin` — Vite and Babel plugin that injects `data-source-file` and `data-source-line` attributes for deterministic element-to-source mapping

### Features

**Visual Editing Loop**
- Select any element in your browser dev server and visually adjust CSS properties (spacing, color, typography, dimensions, layout, effects)
- Changes are queued as structured diffs and delivered to Claude Code via MCP tools
- Claude Code applies diffs to source files; no manual prop-hunting

**MCP Tools**
- `get_pending_visual_changes` — fetch queued diffs
- `acknowledge_visual_change` / `reject_visual_change` — manage the queue
- `get_design_tokens` — parsed tokens from tailwind.config, tokens.json, CSS custom properties
- `resolve_to_token` — snap CSS values to nearest design token
- `get_token_drift_report` — audit token drift across pending diffs
- `export_session` / `import_session` — persist and restore queue + token registry
- `get_project_components` — project-local React component registry for insert operations

**Dev Plugin**
- Vite plugin (works with `@vitejs/plugin-react` and `@vitejs/plugin-react-swc`)
- Babel plugin for non-Vite setups (`./babel` subpath)
- Dual ESM/CJS output — import and require both work
- Zero production overhead (complete no-op when `NODE_ENV=production`)

**Design Token Discovery**
- Auto-discovers tokens from `tailwind.config.*`, `tokens.json`, CSS custom properties, and `design-system.md`
- Token registry rebuilds on file change (chokidar watch)
- Parse failures degrade gracefully — no server crash

**Component Registry**
- Discovers project-local React components under `src/components/**`, `src/ui/**`, `components/**`, and operator-configured roots
- Surfaced to the extension for insert-element workflows

### Accepted Limitations (Documented Behavior)

- **Page reload clears in-progress edits.** A frontend page reload reinitializes the Chrome extension content script. Pending changes are restored from `chrome.storage.session`, but any edit actively mid-drag is lost.
- **MCP crash recovery depends on Claude Code.** Auto-restart behavior is a dependency on Claude Code's MCP client. If Claude Code does not auto-restart on crash, the operator must restart manually.
- **Token discovery executes user code.** Parsing `tailwind.config.ts` requires compiling and evaluating the config file via esbuild. This runs in the project's trust context.
- **v1 supports JSX/TSX only.** Vue SFCs, Svelte components, and plain HTML fall back to "source unverified" mode for element-to-source mapping.

[0.2.0]: https://github.com/n-co-studio/web-editor/releases/tag/v0.2.0
[0.1.0]: https://github.com/n-co-studio/web-editor/releases/tag/v0.1.0
