# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-06-17

Initial public release of NCO Studio Web Editor.

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

[1.0.0]: https://github.com/markpreston2/frontend-editor/releases/tag/v1.0.0
