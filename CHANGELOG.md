# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

Initial public release of n'co studio Web Editor.

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
