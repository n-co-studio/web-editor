# Architecture & Tech Stack

## Tech Stack

- **Frontend**: TypeScript, Chrome Extension Manifest V3
- **Styling**: Shadow DOM overlay (avoids style conflicts with host page)
- **Backend**: Node.js, TypeScript (MCP Server)
- **Database**: N/A — light file-based persistence for crash recovery (.nco-web-editor/pending-queue.json)
- **Auth**: N/A — fully local, no accounts
- **Hosting**: N/A — Chrome Web Store (extension) + npm registry (MCP server)

## Project Structure

```
nco-studio-web-editor/
├── packages/
│   ├── chrome-extension/
│   │   ├── manifest.json
│   │   ├── src/
│   │   │   ├── content/           # Content script — overlay, selection, editing, WebSocket client
│   │   │   ├── service-worker/    # Background — extension lifecycle, message relay
│   │   │   ├── ui/                # Shadow DOM overlay components
│   │   │   └── shared/            # Types, constants
│   │   └── assets/                # Icons, popup HTML
│   ├── mcp-server/
│   │   ├── src/
│   │   │   ├── server.ts          # MCP server entry, tool definitions
│   │   │   ├── bridge.ts          # WebSocket server, extension communication
│   │   │   ├── tokens.ts          # Design token parser and resolver
│   │   │   ├── components.ts      # Project-local component discovery and registry (feature-008)
│   │   │   └── types.ts           # Visual diff schema
│   │   ├── bin/
│   │   │   └── cli.ts             # npx entry point
│   │   └── package.json
│   ├── dev-plugin/
│   │   ├── src/
│   │   │   ├── vite.ts            # Vite plugin — injects data-source-* attributes
│   │   │   ├── babel.ts           # Babel plugin (for non-Vite setups)
│   │   │   ├── transform.ts       # Shared AST transform logic
│   │   │   └── types.ts
│   │   └── package.json
│   └── shared/
│       └── src/
│           ├── protocol.ts        # WebSocket message format
│           └── diff.ts            # VisualDiff type definitions
├── package.json                   # Monorepo root (npm workspaces)
└── tsconfig.json
```

## API Style

N/A — communication is WebSocket (extension ↔ server) + MCP JSON-RPC 2.0 (server ↔ Claude Code)

## Key Patterns

- Monorepo with npm workspaces (4 packages: extension, mcp-server, dev-plugin, shared)
- Deterministic source mapping via build-time `data-source-file` / `data-source-line` attributes injected by dev-plugin
- Shadow DOM isolation for all extension overlay UI
- Content script owns the WebSocket connection (not the service worker) — avoids MV3 service worker termination risk. Keepalive ping every 20s.
- MCP server auto-discovers design tokens at startup
- MCP server auto-discovers project components from convention-gated paths (`src/components/**`, `src/ui/**`, `components/**`, configurable via `nco-web-editor.componentRoots` in the target project's `package.json`) — see feature-008
- All inter-package communication uses typed protocol definitions from shared package
- Dev-plugin is automatically disabled in production builds
- Error isolation: token discovery/parsing wrapped in try/catch — failures degrade to 'no tokens' mode without crashing WebSocket or MCP transport
- Protocol versioning: extension sends protocolVersion on connect, server rejects or warns on mismatch. Current `WS_PROTOCOL_VERSION` is `0.4.0` (bumped in feature-008 to introduce `COMPONENT_DATA` / `COMPONENT_UPDATE`).
- Dev-plugin published as a standalone source-mapping primitive — Frontend Editor is a first-party consumer

## Shared Package Scope

Types that cross the WebSocket boundary (used by both extension and MCP server) live in the root `shared` package: VisualDiff, ElementInfo, PropertyChange, PageContext, DesignToken, ProjectComponent, ComponentInsertDescriptor, PropDefault, WebSocket message types. Types used only within the extension (overlay components, UI state) live in `chrome-extension/src/shared/`. Types used only within the MCP server (internal queue management, file watcher state) live in `mcp-server/src/types.ts`.

## Shadow DOM Constraints

- z-index on shadow host: 2147483647 (max 32-bit int), appended to document.body
- pointer-events toggle: overlay sets pointer-events:none when not intercepting, re-enables on activation
- Keyboard events attached to shadow root (document.activeElement does not pierce Shadow DOM)
- CSS reset: shadow root applies `all: initial` then re-declares overlay tokens using px values (not rem) to prevent host page inheritance affecting overlay typography
- Fonts: system fonts only inside Shadow DOM (no custom font loading required)

## Deployment Target

- Chrome extension → Chrome Web Store (public listing)
- MCP server → npm registry (`@nco-studio/web-editor-mcp`, invoked via `npx`). Invocation should use `npx --yes @nco-studio/web-editor-mcp` to skip install prompts. Alternative: `npm install -g @nco-studio/web-editor-mcp` for faster startup.
- Dev plugin → npm registry (`@nco-studio/web-editor-plugin`, installed as devDependency)
- No CI/CD for runtime — these are developer tools with manual publish

## Constraints

- Chrome only (Manifest V3) — no Firefox/Safari
- Dev mode only — assumes localhost or dev server URLs
- Extension UI must not conflict with any host page styles (Shadow DOM enforced)
- WebSocket port must be configurable (default: 7890) to avoid conflicts
- WebSocket port discovery: extension tries ports 7890-7899, uses first that accepts
- Minimum Chrome version: 116+ (required for chrome.offscreen API availability as fallback)
- MCP server must work with Claude Code's stdio transport
- Dev-plugin must add zero overhead to production builds

## Supported Vite Configurations

The dev-plugin uses Vite's `transform` hook with `@babel/parser` + `@babel/traverse` + `magic-string` for AST-level JSX annotation. This works regardless of whether the target project uses `@vitejs/plugin-react` (Babel) or `@vitejs/plugin-react-swc` (SWC). No dependency on the target project's JSX transform pipeline. For non-Vite setups, a standalone Babel plugin is provided.
