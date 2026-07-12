# @nco-studio/web-editor-mcp

MCP server bridge for [n'co studio Web Editor](https://github.com/markpreston2/frontend-editor). Connects Claude Code to your browser via a local WebSocket, enabling visual UI editing directly in your running dev server.

## How It Fits the Loop

```
Browser (Chrome Extension)
        ↕  WebSocket (localhost)
  @nco-studio/web-editor-mcp   ← this package
        ↕  MCP stdio transport
      Claude Code
        ↕  file edits
  Your source files
```

1. You visually select an element in your browser.
2. Drag to adjust spacing, color, size, etc.
3. The change is sent to the MCP server and queued.
4. Claude Code calls `get_pending_visual_changes`, reads the structured diff, and applies it to your source code.

## Installation

### Option A — npx (no install, slower cold start)

Add to your project's `.claude/settings.json`:

```json
{
  "mcpServers": {
    "nco-web-editor": {
      "command": "npx",
      "args": ["--yes", "@nco-studio/web-editor-mcp@^1"]
    }
  }
}
```

### Option B — global install (recommended for daily use)

```bash
npm install -g @nco-studio/web-editor-mcp
```

Then in `.claude/settings.json`:

```json
{
  "mcpServers": {
    "nco-web-editor": {
      "command": "nco-web-editor-mcp",
      "args": []
    }
  }
}
```

> **Why global install?** The MCP server has a deep transitive dependency tree (react-docgen, Babel). A cold `npx` run can take 15-30 seconds. Global install eliminates this; the process starts in under a second. MCP hosts time out slow-starting servers — the early stderr banner mitigates this for npx, but global install is the reliable path.

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `NCO_WEB_EDITOR_PORT` | `7890` | WebSocket port. Server tries 7890-7899 and uses the first available. |

## MCP Tools

| Tool | Description |
|---|---|
| `get_pending_visual_changes` | Returns queued visual diffs from the Chrome extension |
| `acknowledge_visual_change` | Marks a diff as applied, removes it from the queue |
| `reject_visual_change` | Rejects a diff and removes it from the queue |
| `get_design_tokens` | Returns parsed design tokens from project files |
| `resolve_to_token` | Maps a CSS value to the nearest design token |
| `get_token_drift_report` | Reports design token drift across pending diffs |
| `export_session` | Exports session state (queue + token registry) to a file |
| `import_session` | Restores session state from a previously exported file |
| `get_project_components` | Returns the project-local React component registry |

## Persistence

The server writes the pending queue to `.nco-web-editor/pending-queue.json` on each queue update. The file is deleted when the queue is empty. On crash and restart, the queue is restored from this file.

**Add `.nco-web-editor/` to your `.gitignore`:**

```
.nco-web-editor/
```

## Security Note

Token discovery parses `tailwind.config.ts` (and similar config files) by compiling and evaluating them via esbuild. This executes project code inside the MCP server process. The server runs in your project's trust context, so this is the same trust level as running `vite` or `next dev`. No data leaves your machine — all communication is localhost-only. See [SECURITY.md](../../SECURITY.md) for the full disclosure.

## Known Limitations

- **Page reload clears in-progress edits.** A frontend page reload reinitializes the content script. Pending changes are restored from `chrome.storage.session`, but any edit actively in progress (mid-drag) is lost.
- **MCP crash recovery depends on Claude Code.** The MCP server restart-on-crash behavior is a dependency on Claude Code's MCP client implementation. If Claude Code does not auto-restart, restart manually.
- **Token discovery executes user code.** Parsing `tailwind.config.ts` requires compiling and evaluating the config file via esbuild. This executes arbitrary user code in the MCP server process.
- **v1 supports JSX/TSX only.** Vue SFCs, Svelte components, and plain HTML fall back to "source unverified" mode for element selection.

## Links

- [Repository](https://github.com/markpreston2/frontend-editor)
- [Issues](https://github.com/markpreston2/frontend-editor/issues)
- [Chrome Extension](../../packages/chrome-extension)
- [Dev Plugin](../dev-plugin)
