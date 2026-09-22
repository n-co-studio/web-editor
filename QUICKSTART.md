# n'co studio Web Editor — Quickstart

Get from zero to your first visual edit in about five minutes.

## Prerequisites

- **Node 20+** — `node --version` should print `v20.x` or higher
- **Chrome 116+** — `chrome://version` to check
- **A JSX/TSX dev project** — any Vite + React app works. If you don't have one, use the included [demo app](examples/demo-app/README.md).
- **Claude Code with MCP support** — extension for VS Code, 1.0.0+

---

## Step 1 — Add the MCP server to Claude Code

Add the `nco-web-editor` server to `.mcp.json` at your project root:

```json
{
  "mcpServers": {
    "nco-web-editor": {
      "command": "npx",
      "args": ["--yes", "@nco-studio/web-editor-mcp@^0"],
      "type": "stdio"
    }
  }
}
```

**Verification:** Reload Claude Code. Open the MCP panel — `nco-web-editor` should appear with a green connected indicator.

> The `@^0` pin means Claude Code will auto-update within the `0.x` range. For locked environments use an exact version: `@nco-studio/web-editor-mcp@0.2.0`.

---

## Step 2 — Install the dev plugin

In your dev project:

```sh
npm install --save-dev @nco-studio/web-editor-plugin
```

Then add the plugin to `vite.config.ts`:

```ts
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { ncoWebEditor } from '@nco-studio/web-editor-plugin';

export default defineConfig({
  plugins: [
    react(),
    ncoWebEditor(),   // <-- add this line
  ],
});
```

The plugin runs in `dev` mode only — it is a no-op in production builds.

**Verification:** Start your dev server (`npm run dev`). Open DevTools and inspect any element. A React component's opening tag should carry `data-source-file` and `data-source-line` attributes, for example:

```html
<div data-source-file="src/App.tsx" data-source-line="12" class="card">
```

---

## Step 3 — Install the Chrome extension

Install **n'co studio Web Editor** from the Chrome Web Store. To install it manually instead, download `nco-studio-web-editor-0.2.0.zip` from the [latest release](https://github.com/n-co-studio/web-editor/releases/latest) and load it unpacked:

1. Unzip the archive
2. Open `chrome://extensions`
3. Enable **Developer mode** (toggle, top-right)
4. Click **Load unpacked** and select the unzipped folder
5. Pin the n'co studio Web Editor icon to your Chrome toolbar

**Verification:** The extension icon appears in the toolbar. Clicking it shows a popup with "Off" status.

---

## Step 4 — Make your first edit

1. Start your dev server: `npm run dev`
2. Open `http://localhost:5173` (or your configured port) in Chrome
3. Click the n'co studio Web Editor icon in the toolbar — a popup appears
4. Click **Extension** in the popup to toggle it **On** — the overlay activates
5. Hover over elements — a cyan highlight appears on hover
6. Click an element — the property panel opens at the bottom of the page
7. Adjust a property (e.g., change padding or a color) — the edit queues automatically

**Verification:** The badge on the toolbar icon shows a count. Click **Review changes** in the toolbar (or **Open Change Queue** in the popup) — your pending edit appears in the right-side panel with the source file and line number.

---

## Step 5 — Send the change to Claude Code

1. In the queue panel, review your edits
2. Click **Apply Changes** to dispatch the batch to the MCP server
3. Switch to VS Code — Claude Code processes the structured diff and applies the edit
4. The dev server hot-reloads and you see the change in the browser

**Verification:** The source file changed exactly as described. No manual prompt needed.

---

## Troubleshooting

### Extension toggle does not appear / popup is blank

- Check `chrome://extensions` — ensure the extension is enabled and has no errors
- Try reloading the extension (click the refresh icon on the extension card)
- Inspect the extension service worker: `chrome://extensions` → Details → Inspect views: service worker

### Elements do not show a hover highlight

- Confirm the dev server is running and `http://localhost` (not `https`) is open
- The extension activates on `localhost` and `127.0.0.1` origins only
- Ensure the extension toggle is **On** (not just installed)

### "No edit option" after clicking an element

- Verify `data-source-file` attributes are present in DevTools Elements panel
- If absent, the dev plugin may not be loaded — re-check `vite.config.ts`
- The plugin only runs in development mode — confirm you started with `npm run dev` (not `npm run build`)

### Changes are not applying in Claude Code

- Open the MCP panel in Claude Code and confirm `nco-web-editor` shows connected
- Check the MCP server output in Claude Code for connection errors
- Confirm the MCP server bound a port in the `7890`–`7899` range (the extension only scans that range)

### Port conflict

The MCP server binds the first free port from `7890` to `7899`, and the extension scans the same range, so a busy port is skipped automatically. If all ten ports are taken, free one up and restart the server.

`NCO_WEB_EDITOR_PORT` changes the port the server starts scanning from. The extension only looks in `7890`–`7899`, so keep any override inside that range:

```sh
NCO_WEB_EDITOR_PORT=7895 npx @nco-studio/web-editor-mcp@^0
```

---

## Next steps

- [COMPATIBILITY.md](COMPATIBILITY.md) — protocol version matrix, upgrade guidance
- [packages/mcp-server/README.md](packages/mcp-server/README.md) — MCP server configuration reference
- [packages/dev-plugin/README.md](packages/dev-plugin/README.md) — dev plugin options
- [SECURITY.md](SECURITY.md) — security model and responsible disclosure
- [CHANGELOG.md](CHANGELOG.md) — what changed in each version
