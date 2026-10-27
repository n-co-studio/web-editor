# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-10-26

Rebuilds the hosted guide around what actually makes this different — MCP — hardens the MCP server against a hostile page, and clears a critical dependency advisory. Also fixes a set of contrast and theming faults in the editing panels, including three the theme audit introduced itself.

### Added

- **Install button in the hosted guide**, linking straight to the Chrome Web Store listing.
- **Shared step component** behind the setup and how-to tabs, so a step looks the same wherever it appears. The completed step is announced to screen readers, which it previously was not — an `aria-label` on a bare `<span>` has no role to attach to and most readers drop it.

### Changed

- **The guide leads on MCP.** Every visual editor can claim "design on the real page". The difference here is that others generate a prompt for you to paste, while this dispatches a batch to your own MCP server so your agent writes code while you keep designing. The page, the store listing and the screenshot captions all say that now, instead of describing the editing in isolation.
- **Store listing is dark.** Four screenshots on `#2F2F2F` with mint captions, replacing five on white, with the promo tile and store icon re-cut to match. The store page is itself white, so a white-ground screenshot dissolved into it. The tile is built from the same two tokens as the guide — `#2F2F2F` and `#D2F2CB`, 11.03:1 against each other — so the listing and the site read as one thing.
- **Typography is consistent across the guide tabs.** Bold weight no longer varies between tabs, and the hero palette follows the logo's own spectrum.

### Fixed

- **Several editing-panel controls were hard to see in light mode.** The insert panel's active tab underline and selected-item borders used a green that measures 2.54:1 on the light panel, below the 3:1 a non-text indicator needs. A token swatch lost its border permanently after the first hover, because the hover-out handler wrote a raw colour over the themed one. A log separator in the console pane was invisible on a light background.
- **On-page measurement colours no longer change with the panel theme.** The measure overlay and multi-select outlines had been switched to a themed colour, so the same measurement drew differently depending on a panel setting, and the distance label fell to 2.54:1 in dark mode. Both now use a fixed colour, with the label on a darker ground at 6.7:1.
- **Critical dependency advisory cleared** — `proxy-addr` (GHSA-jqcg-44mw-7w3h), reached through the MCP SDK and express. Production-path advisories went from six to one. The remaining one (`zod`, availability only) needs a major upgrade the MCP SDK does not yet support, and is tracked in `docs/ai/logs/known-issues.md` as KL-3.

### Security

An adversarial review of this release, and three review rounds on the fixes themselves, closed a set of issues in the MCP server. All of them are present in 0.2.1 — none is a regression — and none requires anything of you beyond updating.

The one that mattered: **a page could get files written into your project.** A dev server often renders content you did not author (a seeded database, a production dump, user-generated records, a compromised front-end dependency), and script on such a page could reach the local bridge and choose both the directory and the file extension of an asset write. `.github/workflows/*.yml` runs on push with your repository secrets; `.claude/` and `.cursor/` files are read as agent instructions in a later session. Writes are now image and video only — the extension is derived from the declared type, the bytes must match it, and dot-directories are refused.

- **Asset writes are confined.** Type, extension and content must agree; symlinks can no longer carry a write out of the project; `export_session` takes a `.json` name outside dot-directories and will not overwrite an existing file.
- **The server no longer dies on a malformed message**, and a single bad entry in a batch no longer discards the rest of it. A diff that would have broken the change queue permanently — surviving restarts — is now rejected on the way in.
- **Page-derived values are screened before they reach your agent.** A `data-source-file` attribute set by page content can no longer point the agent at a file outside the project or carry free text into a field the agent acts on, and the tool result now states in-band that the change data is untrusted page content.
- **SVG assets are refused over the bridge** (KL-5). It is the one asset type that is a script-capable document, and an SVG written into `public/` is served from your dev origin. Screening it with pattern matching does not work, so it is refused until it can be parsed properly. Add SVGs to the repo directly.

Still open and scheduled for 0.3.1, both recorded in `docs/ai/logs/known-issues.md`: the bridge still authenticates its peer by `Origin` alone, which the dev page itself satisfies (KL-4), and notes carry a page-built element reference that the server cannot fully separate from the designer's own words (KL-6). With the above in place, reaching the bridge yields information disclosure and nuisance rather than code execution.

### Note

The on-page indicators — the selection ring, the spacing handles, the drop and insert markers — are deliberately *not* themed. They draw over pages whose colours are unknown, and each hue identifies an edit mode, so they stay fixed while the panels follow the theme.

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
