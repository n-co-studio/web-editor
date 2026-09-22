# Chrome Web Store Listing — n'co studio Web Editor

This document contains all copy and metadata needed to submit n'co studio Web Editor to the Chrome Web Store, plus reviewer notes and asset specifications.

---

## Store Metadata

### Name
n'co studio Web Editor

### Short description (132 chars max)

Select elements on your localhost dev page, adjust them visually, and send structured diffs to Claude Code via a local MCP server.

> The store shows the `description` field from `manifest.json` as the summary; keep the two identical.

### Detailed description

**n'co studio Web Editor** is a developer productivity tool that closes the gap between visual intent and code. It overlays an inspection and editing UI directly on your locally-running web page, so you can point at any element, tweak its visual properties, and send a structured diff to Claude Code — all without leaving the browser.

**How it works:**

1. Start your dev server (`npm run dev` or equivalent).
2. Run the companion MCP server: `npx @nco-studio/web-editor-mcp@^0`
3. Open your project in Claude Code with the MCP server configured in `.mcp.json`.
4. Click the n'co studio Web Editor toolbar icon — a popup opens. Click **Extension** in the popup to toggle it **On** and activate the overlay.
5. Click any element to inspect it, adjust spacing/color/typography/layout visually — each edit queues automatically. Click **Review changes** in the toolbar (or **Open Change Queue** in the popup) to see your pending edits, then click **Apply Changes** — Claude Code receives a structured diff and writes the code changes.

**What you can edit:**

- Spacing, dimensions, and position
- Colors and backgrounds
- Typography (font family, size, weight, line-height)
- Flex and grid layout
- CSS visual effects (filter, mix-blend-mode, clip-path)
- Design token snapping (Tailwind, CSS variables)
- Element insertion, deletion, reorder, and reparenting

**Requirements:**

- `@nco-studio/web-editor-mcp` npm package running locally (free, open-source)
- Claude Code with the MCP server configured
- A locally-running dev server at `localhost` or `127.0.0.1`
- `@nco-studio/web-editor-plugin` (optional, enables source-file mapping)

**Architecture:**

All processing is local. The extension communicates with a WebSocket server running on your own machine — no data leaves your computer. The extension activates only on `localhost` pages; it never runs on public websites.

---

## Permission Justifications

These justifications are required for Chrome Web Store review. Copy them verbatim into the "Permission justification" fields on the Developer Dashboard.

### `activeTab`

> n'co studio Web Editor needs `activeTab` to read the current tab's DOM and URL in order to render the visual selection overlay and identify which elements the developer is inspecting. The overlay is only activated when the user explicitly clicks the toolbar icon on a localhost page — the extension does not access any tab automatically. `activeTab` also lets the extension capture the visible tab (`chrome.tabs.captureVisibleTab`) when the developer uses the full-page screenshot tool; the image is saved to the developer's own machine and never uploaded.

### `storage`

> The extension uses `chrome.storage.session` (session-scoped, automatically cleared when Chrome closes) to persist the pending diff queue across page reloads. This ensures that diffs generated before a hot-reload are not lost. No personal data is stored. The extension does not use `chrome.storage.sync` or `chrome.storage.local`.

### `scripting`

> The extension uses the `scripting` API to programmatically inject the overlay content script into the active localhost tab when the developer clicks the toolbar icon. Injection is always user-initiated; the extension does not inject scripts automatically or into non-localhost pages.

### Host permission: `http://localhost/*`, `http://127.0.0.1/*`, `https://localhost/*`

> These host matches are required for the content script to run on local development servers. The extension is a developer tool that operates exclusively on `localhost`/`127.0.0.1` — it never runs on public internet pages. The content script opens a WebSocket connection to a **locally-installed** MCP server process (`@nco-studio/web-editor-mcp`) running on the developer's own machine. No data leaves the machine. The WebSocket is opened by the **content script** (not the service worker) to avoid MV3 service-worker termination issues; this is a standard architecture for dev-tool extensions that need persistent WebSocket connections.

---

## Reviewer Notes

These notes help the Chrome Web Store review team understand how to test the extension.

### What this extension does

n'co studio Web Editor is a developer tool that overlays a visual inspection and editing UI on locally-running web pages. It requires a locally-installed companion MCP server. It does not work on public websites.

### How to test

**Prerequisites:**

1. Node.js 20+ installed.
2. Run the MCP server:
   ```
   npx @nco-studio/web-editor-mcp@^0
   ```
   The server listens on a local WebSocket port (default port 7890; falls back through 7899).

3. A simple demo app to test against — any local dev server will do:
   ```
   npx create-next-app@latest demo-app && cd demo-app && npm run dev
   ```
   Open `http://localhost:3000` in Chrome.

**Testing the extension:**

1. Load the extension as an unpacked extension from the `dist/` directory (or install from the store).
2. Navigate to `http://localhost:3000` (or your local dev server).
3. Click the n'co studio Web Editor icon in the Chrome toolbar — a small popup appears with two buttons: **Extension** (toggle On/Off) and **Open Change Queue**.
4. Click **Extension** in the popup to toggle it **On** — the overlay activates. You should see a cyan selection highlight as you hover over elements.
5. Click an element to inspect it. The properties panel appears at the bottom of the viewport.
6. Adjust a spacing or color value — the live preview updates instantly and the edit queues automatically.
7. Click **Apply Changes** to send the diff to the MCP server.

`chrome.tabs.query` and `chrome.tabs.sendMessage` are called only from the user-opened popup (to read the active tab's state and toggle the overlay), and `chrome.tabs.captureVisibleTab` is called only when the developer explicitly triggers a screenshot — both are scoped to the active tab via `activeTab`, so no `tabs` permission is requested.

**Protocol version safety:**

If the extension and MCP server versions are incompatible, a persistent red banner is shown at the top of the page with remediation instructions. To test this: modify the MCP server's protocol version field and restart it — the banner should appear.

**Architecture notes for reviewers:**

- The WebSocket connection is opened by the **content script** (`content.js`), not the service worker. This is intentional: MV3 service workers are terminated after ~30 seconds of inactivity, which would break a persistent WebSocket. The content script remains alive as long as the page is open.
- All WebSocket traffic goes to `ws://localhost:<port>` — the locally-installed MCP server. No external network calls are made.
- The extension uses a Shadow DOM overlay to avoid style conflicts with the host page. All extension UI is isolated inside the shadow root.
- The extension ID assigned by the Web Store will differ from the sideloaded dev-install ID. This is expected and acceptable for a new extension — no ID-dependent behavior is present.

### Known limitations

- The extension activates only on `localhost` and `127.0.0.1` pages. It will not activate on production or staging URLs.
- The companion MCP server must be running before the extension can connect. If the server is not running, the extension shows a "disconnected" status and retries automatically.
- Page reloads clear the active editing session; pending diffs are restored from `chrome.storage.session`.

---

## Screenshot Shot-list

The Web Store requires up to 5 screenshots at **1280×800** pixels (PNG or JPEG). Capture at device pixel ratio 1:1.

| Frame | Subject | Notes |
|-------|---------|-------|
| **Frame 1** — Live Edit Loop | Cyan selection ring around a card component; properties panel open at bottom showing spacing controls; a visible `--fe-primary` token snap indicator; "Apply Changes" button visible. | Captures the core value prop: point → inspect → adjust → send. |
| **Frame 2** — Change Request Queue | Queue side-panel open on the right showing 2–3 queued diffs with descriptions; toolbar icon showing orange badge; "Review" and "Send All" buttons visible. | Shows the batching / zero-setup workflow. |
| **Frame 3** — Architecture / Zero-Setup | Split view: browser with overlay active on the left, terminal showing `npx @nco-studio/web-editor-mcp@^0` output on the right. | Shows the one-command setup and local-only architecture for reviewers and skeptical users. |

### Promo tile

- **Size:** 440×280 pixels (PNG)
- **Content:** n'co studio wordmark / logo on a dark background (`rgba(0,0,0,0.9)`); tagline "Point → Adjust → Generate"; cyan accent (`#06b6d4`) for the arrow glyphs.
- **Note:** Producing the actual image files is an operator step. This document specifies the content.

---

## Support

- **Support URL:** https://github.com/n-co-studio/web-editor/issues
- **Homepage URL:** https://github.com/n-co-studio/web-editor

## Category and Tags

- **Category:** Developer Tools
- **Language:** English
- **Tags:** developer tools, CSS editor, visual editor, Claude Code, MCP, design tokens, Tailwind

---

## Privacy Policy URL

```
https://nco.studio/web-editor/privacy
```

Content source: `docs/privacy-policy.md`. The page is hosted on the n'co studio website and must remain live for as long as the extension is available on the store.
