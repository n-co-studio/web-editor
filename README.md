# NCO Studio Web Editor

**Point at an element. Adjust it visually. Get a precise code change — no hunting through files, no manual prompting.**

A Chrome extension + local MCP server that closes the loop between browser inspection and source code. Operators make visual adjustments live; Claude Code receives structured diffs with exact file paths and line numbers and applies them in seconds.

---

## The loop

```
Browser (you)                Extension              Claude Code
─────────────────────────────────────────────────────────────────
Click an element     →  Select + show panel
Drag a value         →  Snap to design token
Click "Add to Queue" →  Enqueue with source loc
Click "Send"         →  WebSocket → MCP server  →  Apply the edit
                                                    ↓
                    Hot-reload ←─────────────────── Done
```

**Design → source in under 30 seconds.** Deterministic source mapping — the right file, the right line, every time.

---

## Problem → Solution

| Without NCO Studio | With NCO Studio |
|--------------------|-----------------|
| Open DevTools, find the element | Click the element in your running app |
| Guess which file and line | `data-source-file` + `data-source-line` are injected by the dev plugin |
| Write a description: "make the card padding larger" | Drag the padding handle; value snaps to the nearest token |
| Copy-paste the result into a Claude Code prompt | Click Send — structured diff flows directly via MCP |
| Wait for Claude to find and edit the file | Claude Code applies the precise edit, dev server reloads |

---

## Install

### 1. MCP server — one line in `.claude/settings.json`

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

### 2. Dev plugin — one line in `vite.config.ts`

```sh
npm install --save-dev @nco-studio/web-editor-plugin
```

```ts
import { ncoWebEditor } from '@nco-studio/web-editor-plugin';

export default defineConfig({
  plugins: [react(), ncoWebEditor()],
});
```

### 3. Chrome extension

Download `nco-web-editor-v0.2.0.zip` from [Releases](../../releases/latest), unzip, and load unpacked in `chrome://extensions`. Enable **Developer mode** first.

---

## Try it

Clone this repo and run the demo app — it is a minimal token-driven task board, pre-wired and ready to edit:

```sh
cd examples/demo-app
npm install
npm run dev
```

Open `http://localhost:5173` in Chrome with the extension enabled. Click any card, drag a value, send it.

The app has obvious edit targets:

| What to edit | Token | CSS variable |
|-------------|-------|-------------|
| Brand color on avatars | `--color-primary` | `var(--color-primary)` |
| Card inner spacing | `--space-4` | `var(--space-4)` |
| Task title size | `--text-body-sm` | `var(--text-body-sm)` |

### In-page demo (portfolio / CI)

The extension requires Chrome and a real dev server, so a fully interactive hosted demo is not possible. However, the overlay UI can be embedded in any web page via the `web-embed.js` IIFE:

```html
<script>
  async function loadEditor() {
    await import('/web-embed.js');
    window.addEventListener('nco-web-editor:ready', () => {
      window.__ncoWebEditor.mount();
    }, { once: true });
  }
</script>
<button onclick="loadEditor()">Try the overlay</button>
```

`web-embed.js` bundles a Chrome shim so the overlay renders outside the extension context. Source mapping and MCP features are disabled — it is a visual demo only.

---

## Architecture

```
packages/
  chrome-extension/    Chrome extension (MV3 service worker + Shadow DOM overlay)
  mcp-server/          @nco-studio/web-editor-mcp — stdio MCP server + WebSocket relay
  dev-plugin/          @nco-studio/web-editor-plugin — Vite plugin (JSX transform)
  shared/              Protocol types + design tokens (bundled into mcp-server, not published)
examples/
  demo-app/            Vite + React demo, pre-wired with the dev plugin
```

**Data flow:**

```
Extension (content.js)
  ↓ WebSocket (ws://localhost:3742)
MCP server (nco-web-editor-mcp)
  ↓ MCP stdio transport
Claude Code
  ↓ file edit
Dev server hot-reload
```

The protocol version (`WS_PROTOCOL_VERSION = 0.4.0`) is checked on connection. A version mismatch shows an in-page banner. See [COMPATIBILITY.md](COMPATIBILITY.md).

---

## Known limitations

- **Dev tooling only** — do not install on production pages
- **Chrome 116+ only** — uses MV3 service worker + Side Panel API
- **Vite projects with JSX/TSX** — the dev plugin is Vite-only; source mapping is not available for Webpack or plain CSS projects
- **Visual properties only** — spacing, color, typography, layout. JavaScript behavior changes are out of scope.
- **Localhost only** — the extension activates on `localhost` and `127.0.0.1` origins

---

## Documentation

| Doc | Contents |
|-----|---------|
| [QUICKSTART.md](QUICKSTART.md) | Step-by-step: MCP server → dev plugin → extension → first edit |
| [COMPATIBILITY.md](COMPATIBILITY.md) | Protocol version matrix, mismatch banner, upgrade guidance |
| [CHANGELOG.md](CHANGELOG.md) | What changed in each version |
| [SECURITY.md](SECURITY.md) | Security model, scope, responsible disclosure |
| [packages/mcp-server/README.md](packages/mcp-server/README.md) | MCP server config, port, env vars |
| [packages/dev-plugin/README.md](packages/dev-plugin/README.md) | Plugin options, Babel config |

---

## Contributing and support

- **Bug reports:** [GitHub Issues](.github/ISSUE_TEMPLATE/bug_report.yml) — include extension version, Chrome version, MCP server version
- **Questions and ideas:** GitHub Discussions (enable in repo Settings → Features)
- **Security issues:** See [SECURITY.md](SECURITY.md) for the responsible disclosure process

---

## License

MIT — see [LICENSE](LICENSE).
