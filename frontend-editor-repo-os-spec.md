# Frontend Editor - Repo OS — Starting Spec Reference

> **What this is:** Pre-researched answers for Prompt 0 (Spec Builder).
> When you create a new repo from the repo-OS template for this project,
> paste Prompt 0 and reference this document when answering the interview questions.
> This gives Prompt 0 everything it needs to fill the spec files accurately.

---

## For: product.md

**Product Name:** Frontend Editor - Repo OS

**One-Line Description:** Chrome extension + local MCP server that lets operators visually edit live front-end UI and feed deterministic change requests back to Claude Code in VS Code.

**Problem Statement:** Operators working on projects inspect the front end and identify visual adjustments — spacing, font sizes, colors, layout shifts. Translating those observations into code changes requires manually describing them in a prompt or hunting through source files. This breaks flow and loses precision. Frontend Editor - Repo OS closes the loop: point, adjust, apply — with deterministic source mapping so changes land in the right file every time.

**Target Users:**
- **Operator (repo-OS user)**: Wants to make visual tweaks in the browser and have them reflected in source code without writing CSS by hand or describing changes in natural language
- **AI agent (Claude Code)**: Receives structured visual diffs with exact file paths and line numbers, applies precise edits

**Core User Flows:**

### Flow 1: Visual Edit → Code Change
1. Operator opens their project's dev server in Chrome
2. Activates Frontend Editor - Repo OS extension (toolbar icon or keyboard shortcut)
3. Overlay appears — elements become selectable on hover
4. Operator clicks an element → selection highlight + property panel appears
5. Operator adjusts a property (drag to resize, pick a color, change font size)
6. Extension snaps value to nearest design token and shows token name
7. Operator clicks "Send to Claude Code" (or queues for batch)
8. Extension sends structured diff (file, line, property, old value, new value, token) via WebSocket
9. MCP server exposes diff to Claude Code
10. Claude Code applies the precise edit to the source file
11. Dev server hot-reloads → operator sees the update in browser

### Flow 2: Batch Edits
1. Operator makes multiple visual edits across different elements
2. Each edit appears in a "pending changes" panel with before/after values
3. Operator reviews the batch, removes any unwanted changes
4. Operator sends the full batch at once
5. Claude Code applies all changes sequentially

### Flow 3: Token-Aware Editing
1. Operator activates extension on a project with a design system
2. MCP server auto-discovers tokens from the project (Tailwind config, design-system.md, or tokens.json)
3. Extension loads tokens and constrains all editing to valid token values
4. Spacing drag handles snap to token stops with visual ruler
5. Color picker shows only palette colors
6. Typography dropdown shows only type scale options

**Success Metrics:**
- Visual edit → source code update completes in under 30 seconds (including Claude Code processing)
- Source file and line number are correct 100% of the time (deterministic, not fuzzy)
- Token snapping resolves correctly for 95%+ of edits when tokens are available
- Works with Tailwind, plain CSS, and CSS Modules without project-specific configuration
- Zero configuration in the target project beyond one MCP server entry in settings.json

**What This Product Is NOT:**
- Not a full design tool (no artboards, no asset creation, no prototyping)
- Not a browser DevTools replacement
- Not a CSS editor — generates structured change requests, not raw stylesheets
- Not a component library or design system manager
- Not a hosted service — everything runs locally
- Not for production use — dev tooling only
- Does not handle JavaScript behavior changes — visual/CSS properties only
- Does not create or delete components — only edits existing elements

---

## For: architecture.md

**Tech Stack:**
- **Frontend (Chrome Extension)**: TypeScript, Chrome Extension Manifest V3
- **Extension UI**: Shadow DOM overlay (avoids style conflicts with host page)
- **Backend (MCP Server)**: Node.js, TypeScript
- **Database**: N/A — stateless (pending changes held in memory)
- **Auth**: N/A — fully local, no accounts
- **Hosting**: N/A — Chrome Web Store (extension) + npm registry (MCP server)

**Project Structure:**
```
visual-bridge/
├── packages/
│   ├── chrome-extension/
│   │   ├── manifest.json
│   │   ├── src/
│   │   │   ├── content/           # Content script — overlay, selection, editing
│   │   │   ├── service-worker/    # Background — WebSocket client, message relay
│   │   │   ├── ui/                # Shadow DOM overlay components
│   │   │   └── shared/            # Types, constants
│   │   └── assets/                # Icons, popup HTML
│   ├── mcp-server/
│   │   ├── src/
│   │   │   ├── server.ts          # MCP server entry, tool definitions
│   │   │   ├── bridge.ts          # WebSocket server, extension communication
│   │   │   ├── tokens.ts          # Design token parser and resolver
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

**API Style:** N/A — communication is WebSocket (extension ↔ server) + MCP JSON-RPC 2.0 (server ↔ Claude Code)

**Key Patterns:**
- Monorepo with npm workspaces (4 packages: extension, mcp-server, dev-plugin, shared)
- Deterministic source mapping via build-time `data-source-file` / `data-source-line` attributes injected by dev-plugin
- Shadow DOM isolation for all extension overlay UI
- WebSocket keepalive every 20s (prevents MV3 service worker suspension)
- MCP server auto-discovers design tokens at startup
- All inter-package communication uses typed protocol definitions from shared package
- Dev-plugin is automatically disabled in production builds

**Deployment Target:**
- Chrome extension → Chrome Web Store (public listing)
- MCP server → npm registry (`@visual-bridge/mcp-server`, invoked via `npx`)
- Dev plugin → npm registry (`@visual-bridge/dev-plugin`, installed as devDependency)
- No CI/CD for runtime — these are developer tools with manual publish

**Constraints:**
- Chrome only (Manifest V3) — no Firefox/Safari
- Dev mode only — assumes localhost or dev server URLs
- Extension UI must not conflict with any host page styles (Shadow DOM enforced)
- WebSocket port must be configurable (default: 7890) to avoid conflicts
- MCP server must work with Claude Code's stdio transport
- Dev-plugin must add zero overhead to production builds

---

## For: design-system.md

Frontend Editor - Repo OS itself does not have a user-facing design system in the traditional sense. The extension overlay UI should be minimal and utility-focused:

- **Source:** Defaults — internal tool UI, not a branded product
- **Colors:** Use a neutral dark overlay theme (semi-transparent dark backgrounds, white text, blue accent for selection highlights) to contrast with any host page
- **Typography:** System UI font stack at small sizes (12-14px) — the overlay should be unobtrusive
- **Spacing:** 4px base unit (consistent with repo-OS defaults)

The design system *integration feature* (reading the target project's tokens) is a product feature, not this project's own design system. That's covered in the features section.

---

## For: data-contracts.md

### Entities

#### VisualDiff

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | string (uuid) | yes | Unique diff identifier |
| timestamp | string (ISO 8601) | yes | When the edit was made |
| element | ElementInfo | yes | Identifies the edited element |
| changes | PropertyChange[] | yes | List of property changes |
| context | PageContext | yes | Page URL, viewport, breakpoint |
| status | "pending" \| "applied" \| "rejected" | yes | Processing state |

**Relationships:** Contains ElementInfo, PropertyChange[], PageContext

#### ElementInfo

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| selector | string | yes | CSS selector (most specific available) |
| tagName | string | yes | HTML tag name |
| textContent | string | no | First 80 chars (for identification) |
| sourceFile | string | yes | Absolute path from data-source-file attribute |
| sourceLine | number | yes | Line number from data-source-line attribute |
| attributes | Record<string, string> | yes | class, id, data-*, aria-* |
| boundingRect | DOMRect | yes | Position and size at time of edit |

#### PropertyChange

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| property | string | yes | CSS property name (e.g., "font-size") |
| fromValue | string | yes | Computed value before edit |
| toValue | string | yes | New value after edit |
| fromToken | string | no | Resolved token name for original value |
| toToken | string | no | Resolved token name for new value |
| unit | string | yes | px, rem, em, %, etc. |

#### PageContext

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| url | string | yes | Page URL at time of edit |
| viewport | { width, height } | yes | Viewport dimensions |
| breakpoint | string | no | Matched breakpoint name if tokens loaded |

#### DesignToken

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| name | string | yes | Token name (e.g., "space-4", "text-lg") |
| category | string | yes | spacing, typography, colors, radii, shadows, breakpoints |
| value | string | yes | Resolved value (e.g., "16px", "#3b82f6") |
| cssProperties | string[] | no | Which CSS properties this token applies to |
| source | string | yes | File the token was parsed from |

### API Endpoints

N/A — no HTTP API. Communication uses:
1. **WebSocket** (extension ↔ MCP server) — typed messages per protocol.ts
2. **MCP tools** (server ↔ Claude Code) — JSON-RPC 2.0 over stdio

### MCP Tool Definitions

#### get_pending_visual_changes
- **Purpose**: Returns all visual diffs queued by the extension
- **Parameters**: none
- **Returns**: `{ changes: VisualDiff[] }`

#### acknowledge_visual_change
- **Purpose**: Marks a diff as applied (removes from pending queue)
- **Parameters**: `{ diffId: string }`
- **Returns**: `{ success: boolean }`

#### get_design_tokens
- **Purpose**: Returns the project's parsed design tokens
- **Parameters**: `{ category?: string }` (optional filter)
- **Returns**: `{ tokens: DesignToken[] }`

#### resolve_to_token
- **Purpose**: Maps a CSS value to the nearest design token
- **Parameters**: `{ property: string, value: string }`
- **Returns**: `{ token?: string, exactMatch: boolean, nearestValue: string }`

### State Management
- **Approach**: In-memory state in MCP server process (no persistence needed)
- **Key state shapes:**
  - Pending changes queue: `VisualDiff[]` — cleared when acknowledged
  - Token registry: `Map<string, DesignToken[]>` — rebuilt on file change
  - Connection state: WebSocket client tracking

---

## For: features/

### feature-001-element-selection.md

**Summary:** Select any visible element on the page via click. Display a highlight overlay with bounding box, tag name, source file, line number, and key computed properties (dimensions, spacing, font, color). Read `data-source-file` and `data-source-line` attributes for deterministic source mapping.

**User Flow:**
1. Operator activates extension
2. Hovering over elements shows a light highlight with tag name tooltip
3. Clicking an element selects it — full highlight with property panel
4. Property panel shows: tag, source file:line, computed dimensions, spacing, typography, colors
5. If tokens are loaded, panel shows resolved token names next to computed values
6. Clicking elsewhere or pressing Escape deselects

**Edge Cases:**
- Element has no `data-source-*` attributes (dev-plugin not installed) → show warning, still allow editing but flag diff as "source unverified"
- Element is inside Shadow DOM (open) → traverse into shadow root
- Element is inside Shadow DOM (closed) → not selectable, skip
- Element is in a cross-origin iframe → not selectable, skip
- Overlapping elements → use the topmost element at click position

### feature-002-visual-property-editing.md

**Summary:** Edit CSS properties via direct manipulation on the selected element. Drag handles for spacing and dimensions. Dropdowns and pickers for typography and colors.

**Editing modes:**
- **Spacing**: Drag handles on padding/margin edges
- **Dimensions**: Drag corner/edge handles for width/height
- **Typography**: Dropdown for font-size, weight toggle, line-height slider
- **Colors**: Color picker (constrained to palette when tokens loaded)
- **Border radius**: Corner drag handles

**Edge Cases:**
- Flexbox/Grid children: flag that parent may need editing, include parent info in diff
- Percentage-based values: maintain unit type, don't convert to px
- Responsive: changes apply to current viewport only, breakpoint is recorded in diff context

### feature-003-design-token-snapping.md

**Summary:** When design tokens are loaded from the project, constrain all edits to valid token values. Visual feedback shows token stops.

**Token discovery priority:**
1. `tailwind.config.js` / `tailwind.config.ts` — parse theme
2. `tokens.json` / `design-tokens.json` — Style Dictionary format
3. `docs/spec/compiled/{active}/design-system.md` — parse markdown tables (repo-OS)
4. CSS custom properties (`--*`) in `*.css` files

**Edge Cases:**
- No tokens found → freeform editing, no snapping, values sent as raw CSS
- Value falls between two tokens → snap to nearest, show both options
- Operator wants a non-token value → "custom value" escape hatch, flagged in diff

### feature-004-change-batching.md

**Summary:** Collect multiple edits before sending to Claude Code. Review panel lists all pending changes with before/after values and token names.

**User Flow:**
1. Operator makes edits (each added to pending queue)
2. Pending count badge appears on extension icon
3. Operator opens review panel — sees list of changes grouped by element
4. Each change shows: element selector, property, before → after, token names
5. Operator can remove individual changes
6. "Send to Claude Code" dispatches the batch via WebSocket

### feature-005-mcp-server-bridge.md

**Summary:** Local Node.js process that bridges the Chrome extension to Claude Code. Runs a WebSocket server for the extension and exposes MCP tools for Claude Code.

**User Flow:**
1. Operator adds MCP server to `.claude/settings.json`
2. Claude Code starts → MCP server starts automatically
3. MCP server opens WebSocket on configurable port (default 7890)
4. Chrome extension connects on page load
5. Visual diffs flow: extension → WebSocket → MCP server → Claude Code
6. Token data flows: MCP server → WebSocket → extension

**Edge Cases:**
- Port already in use → try next port, log the actual port
- Extension connects before server → retry with exponential backoff (max 5 attempts)
- Multiple Chrome tabs → all connect, diffs tagged with source tab/URL
- Claude Code not running → diffs queue in server memory, delivered when Claude Code connects

### feature-006-dev-plugin.md

**Summary:** Build plugin that injects `data-source-file` and `data-source-line` attributes onto every rendered DOM element during development. This is the deterministic source mapping layer.

**Supported build tools:**
- Vite (via Vite plugin API)
- Webpack/Babel (via Babel plugin)
- Other (SWC plugin — future consideration)

**How it works:**
1. At build time, the plugin visits every JSX/TSX element in the AST
2. Adds `data-source-file` (relative path from project root) and `data-source-line` (line number in source)
3. Attributes are added to the transpiled output, not the source files
4. In production mode (`NODE_ENV=production` or `mode !== 'development'`), the plugin is a no-op

**Installation in a target project:**
```bash
npm install -D @visual-bridge/dev-plugin
```

```ts
// vite.config.ts
import { visualBridge } from '@visual-bridge/dev-plugin'
export default defineConfig({
  plugins: [visualBridge()]
})
```

**Edge Cases:**
- Fragment shorthand (`<>...</>`) → skip (no DOM element to annotate)
- Component wrappers that don't render a DOM element → attribute lands on first DOM child
- Dynamic JSX (`React.createElement`) → Babel plugin handles; Vite plugin may miss non-JSX patterns
- SSR / Server Components → only annotate client-rendered elements

---

## For: integrations.md

### Third-Party Services

None. Frontend Editor - Repo OS is fully local with no external service dependencies.

### MCP Connections

#### Frontend Editor - Repo OS MCP Server (this project)

- **Purpose**: Bridge between Chrome extension and Claude Code
- **Server**: `@visual-bridge/mcp-server` (npm package)
- **Configuration in target project's `.claude/settings.json`**:
```json
{
  "mcpServers": {
    "visual-bridge": {
      "command": "npx",
      "args": ["@visual-bridge/mcp-server"]
    }
  }
}
```

### Environment Variables

| Variable | Purpose | Required |
|----------|---------|----------|
| VISUAL_BRIDGE_PORT | WebSocket port for extension connection | no (default: 7890) |

---

## For: boundaries.md

**What This Product Does NOT Do:**
- Does not support browsers other than Chrome (Firefox, Safari — future consideration)
- Does not handle JavaScript behavior changes (click handlers, state, logic)
- Does not create or delete DOM elements/components
- Does not work on production builds (dev-plugin is dev-only)
- Does not access cross-origin iframe content
- Does not modify closed Shadow DOM content
- Does not persist changes itself — it delegates all code changes to Claude Code
- Does not require or manage user accounts or authentication
- Does not communicate with any remote server — all traffic is localhost

**Protected Areas:**
- The target project's source files are never modified by Frontend Editor - Repo OS directly — only Claude Code writes to source
- The dev-plugin never modifies source files — it transforms build output only
- Production builds must have zero trace of dev-plugin annotations

**Assumptions: NONE**
<!-- This section must remain empty per repo-OS convention -->

---

## Architecture Diagram

```
Target Project (any repo-OS project)
  │
  │  vite.config.ts includes @visual-bridge/dev-plugin
  │  └── injects data-source-file / data-source-line at build time
  │
  ▼
Browser (Chrome, localhost dev server)
  │
  │  @visual-bridge/chrome-extension
  │  ├── Content script: overlay, selection, editing, token snapping
  │  ├── Shadow DOM: all UI isolated from host page
  │  └── Service worker: WebSocket client
  │
  │  WebSocket (localhost:7890)
  │
  ▼
@visual-bridge/mcp-server (local Node.js process)
  ├── WebSocket server ← receives VisualDiff from extension
  ├── Token parser ← reads project's design tokens on startup
  ├── MCP tools ← exposes get_pending_visual_changes, etc.
  │
  │  MCP (JSON-RPC 2.0 over stdio)
  │
  ▼
Claude Code (VS Code)
  ├── Reads VisualDiff → knows exact file, line, property, old/new value
  ├── Opens source file → applies precise edit
  └── Dev server hot-reloads → operator sees update in browser
```

---

## Key Design Decision: Deterministic Source Mapping

Frontend Editor - Repo OS does NOT use AI/fuzzy matching to locate source files. Instead:

1. The **dev-plugin** injects `data-source-file` and `data-source-line` onto every DOM element at build time
2. The **Chrome extension** reads these attributes when an element is selected
3. The **visual diff** includes exact file path and line number
4. **Claude Code** receives a precise edit instruction — no searching or guessing

This means:
- Source mapping is 100% accurate (not probabilistic)
- Claude Code uses fewer tokens (no codebase search needed)
- The dev-plugin adds <1% overhead in dev builds, zero in production
- Projects must install the dev-plugin for full functionality (graceful degradation without it)

This approach is proven by LocatorJS and Click to Component, which use the same build-time annotation pattern for click-to-source navigation.
