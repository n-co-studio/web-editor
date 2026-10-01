# Chrome Web Store Listing — Visual Web Editor for AI Agents

This document contains all copy and metadata needed to submit Visual Web Editor for AI Agents (published by n'co studio) to the Chrome Web Store, plus reviewer notes and asset specifications.

---

## Store Metadata

### Name
Visual Web Editor for AI Agents

### Publisher
n'co studio

### Short description (132 chars max)

Design on the real page — adjust any element visually and your AI coding agent applies the change in your source files.

> The store shows the `description` field from `manifest.json` as the summary; keep the two identical.

### Detailed description

**Visual Web Editor for AI Agents** is for designers who work with AI coding agents. You design on the page itself — point at any element in your running app, adjust spacing, colour, type and layout by eye — and your agent turns those adjustments into real code changes in the right files. No screenshots to annotate, no describing a change in prose and hoping the result matches, no hunting for the component that owns a style.

Your edits snap to the design tokens your project already defines, so what you change stays inside your system instead of drifting into one-off values.

**How it works:**

1. Start your dev server (`npm run dev` or equivalent).
2. Run the companion MCP server: `npx @nco-studio/web-editor-mcp@^0`
3. Open your project in your AI coding agent (Claude Code) with the MCP server configured in `.mcp.json`.
4. Click the toolbar icon — a popup opens. Click **Extension** in the popup to toggle it **On** and activate the overlay.
5. Click any element to inspect it, adjust spacing/color/typography/layout visually — each edit queues automatically. Click **Review changes** in the toolbar (or **Open Change Queue** in the popup) to see your pending edits, then click **Apply Changes** — your agent receives a structured diff — file paths, line numbers, the exact change — and writes it into your source.

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
- An AI coding agent that speaks MCP (built and tested with Claude Code)
- A locally-running dev server at `localhost` or `127.0.0.1`
- `@nco-studio/web-editor-plugin` (optional, enables source-file mapping)

**Architecture:**

All processing is local. The extension communicates with a WebSocket server running on your own machine, and neither the extension nor that server sends your data anywhere else.

One thing to be deliberate about: each edit carries the page's URL, the edited element's text and attributes, and your changed values to the local MCP server — and on to your agent, whose model provider then sees them, the same as any file you ask it to read. Point the editor at a page you are happy for your agent to see. (Screenshots are the exception: they stay in the browser.)

The editor loads **automatically** only on `localhost` and `127.0.0.1`, your own dev servers. On any other page it loads only when you click the toolbar icon. There you can still inspect and adjust anything — useful for reviewing a live site or trying an idea against production — but the changes stay in the browser: writing them back to source needs the build-time tags the dev plugin adds, which a deployed page does not have.

---

## Permission Justifications

These justifications are required for Chrome Web Store review. Copy them verbatim into the "Permission justification" fields on the Developer Dashboard.

### `activeTab`

> Visual Web Editor for AI Agents needs `activeTab` to read the current tab's DOM and URL in order to render the visual selection overlay and identify which elements the developer is inspecting. The overlay is activated only when the developer explicitly clicks the toolbar icon, and `activeTab` scopes that access to the tab they invoked it on — the extension does not access any tab automatically, and requests no host permissions for the pages a developer merely browses. `activeTab` also lets the extension capture the visible tab (`chrome.tabs.captureVisibleTab`) when the developer uses the full-page screenshot tool; the image is saved to the developer's own machine and never uploaded.

### `storage`

> The extension uses `chrome.storage.session` (session-scoped, automatically cleared when Chrome closes) to persist the pending diff queue across page reloads, and `chrome.storage.local` to remember your Light / Dark / System theme preference. No personal data is stored. The extension does not use `chrome.storage.sync`.

### `scripting`

> The extension uses the `scripting` API to inject the overlay into the active tab when the developer clicks the toolbar icon. Injection is always user-initiated, under `activeTab`, and scoped to the tab the developer invoked it on — the extension never injects itself into pages the user is merely browsing. Automatic injection is declared separately and narrowly in `content_scripts.matches`, which covers `localhost` and `127.0.0.1` only.

### Host permission: `http://localhost/*`, `http://127.0.0.1/*`, `https://localhost/*`

> These host matches are what the extension loads on **automatically** — the developer's own local servers, where the editing loop it exists for actually works. No broad host permissions are requested: on any other page the overlay runs only when the developer clicks the toolbar icon, under `activeTab`, for that tab alone. The content script opens a WebSocket connection to a **locally-installed** MCP server process (`@nco-studio/web-editor-mcp`) running on the developer's own machine — the extension opens no other connection, and neither it nor that server transmits anything off the machine. (The MCP server's purpose is to hand edits to the developer's own AI agent, which is where they go next.) The WebSocket is opened by the **content script** (not the service worker) to avoid MV3 service-worker termination issues; this is a standard architecture for dev-tool extensions that need persistent WebSocket connections.

---

## Reviewer Notes

These notes help the Chrome Web Store review team understand how to test the extension.

### What this extension does

This extension is a developer tool that overlays a visual inspection and editing UI on a web page. It loads automatically only on the developer's own local servers (`content_scripts.matches`); on any other page it loads only when the developer clicks the toolbar icon, under `activeTab`, for that tab alone.

Its full loop — visual edits written back into source files — requires a locally-installed companion MCP server and build-time tags added by the developer's dev plugin. On a page without those, the overlay still inspects and adjusts, but the changes stay in the browser and are never written anywhere.

On first install, the extension opens the setup guide at https://nco.studio/web-editor/ in a new tab. This is a static page; no data is sent to it. Subsequent installs (update, reinstall) do not open a tab.

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
3. Click the extension's icon in the Chrome toolbar — a small popup appears with two buttons: **Extension** (toggle On/Off) and **Open Change Queue**.
4. Click **Extension** in the popup to toggle it **On** — the overlay activates. You should see a cyan selection highlight as you hover over elements.
   - Chrome asks to allow access to other devices and apps on your local network. **Click Allow.** This is Chrome's Local Network Access permission (Chrome 142+, extended to WebSockets in 147); the extension needs it to reach the MCP server on `ws://localhost`. If it is denied, the extension cannot connect and will appear inert.
5. Click an element to inspect it. The properties panel appears at the bottom of the viewport.
6. Adjust a spacing or color value — the live preview updates instantly and the edit queues automatically.
7. Click **Apply Changes** to send the diff to the MCP server.

`chrome.tabs.query` and `chrome.tabs.sendMessage` are called only from the user-opened popup (to read the active tab's state and toggle the overlay), and `chrome.tabs.captureVisibleTab` is called only when the developer explicitly triggers a screenshot — both are scoped to the active tab via `activeTab`, so no `tabs` permission is requested.

**Protocol version safety:**

If the extension and MCP server versions are incompatible, a persistent red banner is shown at the top of the page with remediation instructions. To test this: modify the MCP server's protocol version field and restart it — the banner should appear.

**Architecture notes for reviewers:**

- The WebSocket connection is opened by the **content script** (`content.js`), not the service worker. This is intentional: MV3 service workers are terminated after ~30 seconds of inactivity, which would break a persistent WebSocket. The content script remains alive as long as the page is open.
- All WebSocket traffic goes to `ws://localhost:<port>` — the locally-installed MCP server. No external network calls are made.
- Because that WebSocket targets a loopback address, Chrome's Local Network Access permission prompt appears on first connect. Allowing it is required for the extension to function; it grants access to the developer's own machine only, and the extension makes no requests beyond `localhost`.
- The extension uses a Shadow DOM overlay to avoid style conflicts with the host page. All extension UI is isolated inside the shadow root.
- The extension ID assigned by the Web Store will differ from the sideloaded dev-install ID. This is expected and acceptable for a new extension — no ID-dependent behavior is present.

### Known limitations

- The editor loads automatically only on `localhost` and `127.0.0.1`. On other pages it loads when the toolbar icon is clicked, and edits cannot be written back to source — that requires the build-time tags the dev plugin adds, so on a deployed page the changes stay in the browser.
- Chrome's own pages (`chrome://`, the Web Store), `file:` URLs and other extensions' pages cannot host the overlay; the popup says so rather than failing silently.
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
- **Homepage URL:** https://nco.studio/web-editor/

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
