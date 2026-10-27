# Chrome Web Store Listing — AI Agent Visual Editor

This document contains all copy and metadata needed to submit AI Agent Visual Editor (published by n'co studio) to the Chrome Web Store, plus reviewer notes and asset specifications.

---

## Store Metadata

### Name
AI Agent Visual Editor

### Publisher
n'co studio

### Short description (132 chars max)

MCP visual editor for AI agents — adjust the real page, dispatch edits in batches, and your agent codes while you keep designing.

> The store shows the `description` field from `manifest.json` as the summary; keep the two identical.

### Detailed description

**AI Agent Visual Editor** connects to your AI coding agent over MCP. You adjust elements on the real page, queue a batch of changes, and dispatch them — your agent writes the code while you carry on designing.

Because the handoff is a protocol, both halves of the work run at the same time: you keep designing while the agent applies the batch you just sent.

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

**Without MCP:** the editor can also produce a copy-paste prompt describing your changes, for agents that don't connect over MCP.

**Requirements:**

- `@nco-studio/web-editor-mcp` npm package running locally (free, open-source)
- An AI coding agent that speaks MCP (built and tested with Claude Code)
- A locally-running dev server at `localhost` or `127.0.0.1`
- `@nco-studio/web-editor-plugin` (optional, enables source-file mapping)

**Architecture:**

All processing is local. The extension communicates with a WebSocket server running on your own machine, and neither the extension nor that server sends your data anywhere else. The extension activates only on `localhost` pages; it never runs on public websites.

One thing to be deliberate about: each edit carries the page's URL, the edited element's text and attributes, and your changed values to the local MCP server — and on to your agent, whose model provider then sees them, the same as any file you ask it to read. A dev server is not automatically harmless here: if yours is pointed at a seeded database or a production dump, that content goes with the edit. (Screenshots are the exception: they stay in the browser.)

---

## Permission Justifications

These justifications are required for Chrome Web Store review. Copy them verbatim into the "Permission justification" fields on the Developer Dashboard.

### `activeTab`

> AI Agent Visual Editor needs `activeTab` to read the current tab's DOM and URL in order to render the visual selection overlay and identify which elements the developer is inspecting. The overlay is only activated when the user explicitly clicks the toolbar icon on a localhost page — the extension does not access any tab automatically. `activeTab` also lets the extension capture the visible tab (`chrome.tabs.captureVisibleTab`) when the developer uses the full-page screenshot tool; the image is saved to the developer's own machine and never uploaded.

### `storage`

> The extension uses `chrome.storage.session` (session-scoped, automatically cleared when Chrome closes) to persist the pending diff queue across page reloads, and `chrome.storage.local` to remember your Light / Dark / System theme preference. No personal data is stored. The extension does not use `chrome.storage.sync`.

### `scripting`

> The extension uses the `scripting` API to programmatically inject the overlay content script into the active localhost tab when the developer clicks the toolbar icon. Injection is always user-initiated; the extension does not inject scripts automatically or into non-localhost pages.

### Host permission: `http://localhost/*`, `http://127.0.0.1/*`, `https://localhost/*`

> These host matches are required for the content script to run on local development servers. The extension is a developer tool that operates exclusively on `localhost`/`127.0.0.1` — it never runs on public internet pages. The content script opens a WebSocket connection to a **locally-installed** MCP server process (`@nco-studio/web-editor-mcp`) running on the developer's own machine — the extension opens no other connection, and neither it nor that server transmits anything off the machine. (The MCP server's purpose is to hand edits to the developer's own AI agent, which is where they go next.) The WebSocket is opened by the **content script** (not the service worker) to avoid MV3 service-worker termination issues; this is a standard architecture for dev-tool extensions that need persistent WebSocket connections.

---

## Reviewer Notes

These notes help the Chrome Web Store review team understand how to test the extension.

### What this extension does

This extension is a developer tool that overlays a visual inspection and editing UI on locally-running web pages. It requires a locally-installed companion MCP server. It does not work on public websites.

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
- The extension ID assigned by the Web Store will differ from the sideloaded dev-install ID. This is expected and acceptable for a new extension — no ID-dependent behavior is present. (Assigned on approval, 2026-10-15: `aifpecjojmlgdhgnkmkaobmfipdmppea` — listing at https://chromewebstore.google.com/detail/ai-agent-visual-editor/aifpecjojmlgdhgnkmkaobmfipdmppea)

### Known limitations

- The extension activates only on `localhost` and `127.0.0.1` pages. It will not activate on production or staging URLs.
- The companion MCP server must be running before the extension can connect. If the server is not running, the extension shows a "disconnected" status and retries automatically.
- Page reloads clear the active editing session; pending diffs are restored from `chrome.storage.session`.

---

## Screenshot Shot-list

The Web Store allows up to 5 screenshots at **1280×800** pixels (PNG or JPEG). Capture at device pixel ratio 1:1.

Four are shipped, not five. Each carries one claim, and the set leads on MCP,
because that is the part competitors do not have: they generate a prompt for
you to paste, while this dispatches a batch to your own MCP server so your
agent works while you keep designing. See `docs/store-assets/README.md` for
the files themselves.

| Frame | File | Caption |
|-------|------|---------|
| **Frame 1** — Batched changes over MCP | `01-batched-changes-over-mcp.png` | Send batched changes over MCP that map to your source code. |
| **Frame 2** — The editor itself | `02-drag-and-drop-editor.png` | Turn Chrome into a drag & drop editor with a full suite of tools. |
| **Frame 3** — Insert and extract | `03-sections-layouts-components.png` | Add new sections, layouts, and components to and from your code. |
| **Frame 4** — Token-aware edits | `04-edits-from-design-tokens.png` | All edits work from the design tokens established in your CSS. |

**Ground: `#2F2F2F`** with mint `#D2F2CB` caption type, replacing an earlier
white-ground set on 2026-10-19. The store page is itself white, so a
white-ground screenshot dissolves into it; a dark frame is what separates this
listing from the ones above and below it.

### Small promo tile — 440×280

**Required, not optional.** Chrome's dashboard docs list it among the assets
you "must provide", with only the marquee tile excepted. Even where a
submission goes through without one, Google states plainly: *"Extensions that
don't have a small promotional image will be shown after extensions that do."*

**Where it appears:** the Web Store homepage, category pages, and **search
results**. It is the thumbnail next to every competing extension when someone
browses or searches — not a listing-page decoration. It renders at roughly
220×140, so it is read at about half the size it is authored at.

**Hard constraints** (any of these is an outright rejection):

- Exactly 440×280. 439×280 is refused — check the export, some editors round.
- PNG (24-bit, **no alpha**) or JPEG. A transparent background is not accepted.
- Keep text inside the centre 70%; the edges get cropped in some placements.

**Content direction:**

- A single mark or illustration filling 40%+ of the tile. At 220px wide it gets
  about two seconds of attention, so it has to read at a glance rather than be
  parsed.
- No screenshot. Google is explicit: *"Don't just use a screenshot; your images
  should communicate the brand and appear professional."*
- Nothing that claims store status — no "Editor's Choice", no "#1".
- Author at 2× (880×560) and export at 1×, so it stays sharp on high-DPI.

**Ground: `#2F2F2F`.** Decided 2026-10-19, replacing both the original white
ground and the later split-band treatment. The screenshots and the store icon
were re-cut dark at the same time, so all three surfaces now agree without one
having to overrule another — which is the problem the split band existed to
work around.

| Role | Value | Why |
|------|-------|-----|
| Ground | `#2F2F2F` | `--color-display-ink`, the landing page's display colour |
| Type and mark | `#D2F2CB` | `--color-accent-mint`, the same token the landing page uses |
| Strapline bar | `#D2F2CB` fill, `#2F2F2F` ink | the same pair inverted |

Two colours, no third. They are the landing page's own tokens
(`examples/demo-app/src/tokens.css`), so the tile, the site and the product
resolve to one palette rather than three that merely resemble each other.

**On the accent.** Four accents exist across the project: the old icon's green
`#609D53`, the editor UI's cyan `#06b6d4`, the nco.studio site's orange
`#ff5c38`, and mint `#D2F2CB`. Mint leads here and on the landing page. The
site's orange deliberately does not appear — it belongs to nco.studio, not to
this product. Cyan stays inside the product UI, where the screenshots show it
in its own context.

**Tagline — as delivered:**

> **You design, agents code.**
>
> with MCP connection

Two lines of mint display type, with the strapline reversed out of a mint bar
beneath it.

It replaces "Design it. Don't describe it.", which replaced
"Point → Adjust → Generate". This is the first of the three to name the agent
rather than only the designer, and the strapline carries the differentiator:
MCP is the mechanism, and no competing visual editor has one.

The tagline deliberately does **not** restate the short description. In search
results the description sits directly beneath the tile, so the two do
different jobs: the description explains the mechanic, and the tagline names
the division of labour that makes anyone want it.

**Other content:** the sparkle-and-pencil mark above the type — one abstracted
gesture rather than a reproduction of the UI. At the ~220px this renders at,
real panels become texture, and the four screenshots below the tile are what
show the actual interface.

**Contrast, measured on `#2F2F2F`.** Mint `#D2F2CB` on the ground is
**11.03:1**; the strapline bar is the same pair inverted, so it measures
11.03:1 too. Both clear AAA at any size. It is the same measured pair the
landing page's stepper badges use — one pair, resolved once, used everywhere.

### Marquee promo tile — 1400×560

Genuinely optional. Only used if the item is picked for the rotating carousel
on the store homepage, and it cannot be picked without one. Worth producing
only if being featured is a goal.

---

## Support

- **Support URL:** https://github.com/n-co-studio/web-editor/issues
- **Support email:** hello@nco.studio
- **Homepage URL:** https://nco.studio/web-editor/

> The repository went public on 2026-10-12, so issues are the Support URL
> again: answers become searchable instead of living in one inbox. The email
> stays listed alongside it — not everyone has a GitHub account, and a support
> report about this tool often carries page content or internal URLs that
> someone will not post publicly.
>
> The guide's Troubleshooting tab still ends with a "Still stuck?" block
> mailing `hello@nco.studio`, which is the fallback when the public channel is
> itself the problem.

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
