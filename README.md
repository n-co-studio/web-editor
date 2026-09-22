# n'co studio Web Editor

**Point at an element. Adjust it visually. Get a precise code change — no hunting through files, no manual prompting.**

A Chrome extension + local MCP server that closes the loop between browser inspection and source code. Operators make visual adjustments live; Claude Code receives structured diffs with exact file paths and line numbers and applies them in seconds.

---

## The loop

```
Browser (you)                   Extension              Claude Code
────────────────────────────────────────────────────────────────────
Click the toolbar icon    →  Popup opens
Toggle "Extension" On     →  Overlay activates
Click an element          →  Select + show panel
Drag a value              →  Snap to design token
                          →  Edit queues automatically
Click "Review changes"    →  Review queue panel opens
Click "Apply Changes"     →  WebSocket → MCP server  →  Apply the edit
                                                         ↓
                         Hot-reload ←───────────────── Done
```

**Design → source in under 30 seconds.** Deterministic source mapping — the right file, the right line, every time.

---

## What you get

Three pieces, all local, all open-source:

| Component | Package | What it does |
|-----------|---------|--------------|
| Chrome extension | Chrome Web Store / Releases | Overlay UI, property panel, change queue |
| MCP server | `@nco-studio/web-editor-mcp` | stdio MCP + WebSocket relay to Claude Code |
| Dev plugin | `@nco-studio/web-editor-plugin` | Vite plugin — injects `data-source-file` / `data-source-line` for deterministic source mapping |

---

## Install

See **[QUICKSTART.md](QUICKSTART.md)** for the full step-by-step guide. In brief:

### 1. MCP server — one entry in `.mcp.json`

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

The MCP server listens on a WebSocket port in the `7890`–`7899` range; the extension scans the same range automatically.

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

Install **n'co studio Web Editor** from the Chrome Web Store, or download the latest `.zip` from [Releases](https://github.com/n-co-studio/web-editor/releases/latest) and load it unpacked.

---

## Try it

The hosted guide at **https://nco.studio/web-editor/** doubles as a live practice target. You can also run it locally:

Clone this repo and run the demo app — a guide page pre-wired with design tokens and live editing, ready to practice on:

```sh
cd examples/demo-app
npm install
npm run dev
```

Open `http://localhost:5173` in Chrome with the extension enabled. Click the toolbar icon, toggle **Extension** On, click any card element, drag a value, then click "Review changes" and "Apply Changes".

---

## What you can edit

- Spacing, dimensions, and position
- Colors and backgrounds
- Typography (font family, size, weight, line-height)
- Flex and grid layout
- CSS visual effects (filter, mix-blend-mode, clip-path)
- Design token snapping (Tailwind, CSS variables)
- Element insertion, deletion, reorder, and reparenting
- Inline text styling
- Parallax effects

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
  ↓ WebSocket (ws://localhost:7890–7899)
MCP server (@nco-studio/web-editor-mcp)
  ↓ MCP stdio transport
Claude Code
  ↓ file edit
Dev server hot-reload
```

The protocol version (`WS_PROTOCOL_VERSION = 0.4.0`) is checked on connection. A version mismatch shows a persistent banner. See [COMPATIBILITY.md](COMPATIBILITY.md).

All processing is local — no data leaves your machine.

---

## Known limitations

- **Dev tooling only** — do not install on production pages
- **Chrome 116+** — uses MV3 service worker
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
| [Privacy Policy](https://nco.studio/web-editor/privacy) | Data handling policy |
| [packages/mcp-server/README.md](packages/mcp-server/README.md) | MCP server config, port, env vars |
| [packages/dev-plugin/README.md](packages/dev-plugin/README.md) | Plugin options |

---

## Contributing and support

- **Bug reports:** [GitHub Issues](https://github.com/n-co-studio/web-editor/issues) — include extension version, Chrome version, MCP server version
- **Questions and ideas:** [GitHub Discussions](https://github.com/n-co-studio/web-editor/discussions)
- **Security issues:** See [SECURITY.md](SECURITY.md) for the responsible disclosure process

For contributors: governance and session workflow are documented in [AI.md](AI.md).

---

## License

MIT — see [LICENSE](LICENSE).
