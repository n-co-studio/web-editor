# Feature: MCP Server Bridge

## Summary
Local Node.js process that bridges the Chrome extension to Claude Code. Runs a WebSocket server for the extension and exposes MCP tools for Claude Code. Handles token discovery from project files and pushes token data to the extension. Content script owns the WebSocket connection (not the service worker) to avoid MV3 termination risk.

## User Flow
1. Operator adds MCP server to `.claude/settings.json`
2. Claude Code starts → MCP server starts automatically
3. MCP server opens WebSocket on configurable port — extension tries ports 7890–7899, uses first that accepts
4. Chrome extension content script connects directly on page load (not via service worker relay)
5. Visual diffs flow: extension → WebSocket → MCP server → Claude Code
6. Token data flows: MCP server → WebSocket → extension

## UI States
N/A — headless server process. Status is communicated to the extension via WebSocket messages:
- **Connected**: Extension receives confirmation, ready to send diffs
- **Disconnected**: Extension shows disconnected warning, retries with backoff
- **Error**: Extension shows error banner with details (e.g., port conflict)

## Inputs
- `VisualDiff[]` from Chrome extension via WebSocket
- Project files for token discovery (tailwind.config, tokens.json, design-system.md, CSS files)
- `FRONTEND_EDITOR_PORT` environment variable (optional, default 7890)

## Outputs
- MCP tools exposed to Claude Code:
  - `get_pending_visual_changes` — returns queued diffs
  - `acknowledge_visual_change` — marks diff as applied
  - `reject_visual_change` — rejects a diff and removes it from the queue
  - `get_design_tokens` — returns parsed tokens
  - `resolve_to_token` — maps CSS value to nearest token
  - `get_token_drift_report` — returns a report of design token drift across pending diffs
  - `export_session` — exports the current session state (pending queue, token registry) to a file
  - `import_session` — restores session state from a previously exported file
  - `get_project_components` — returns the project-local component registry (feature-008; editor-agnostic)
- Token data pushed to extension via WebSocket on connect and on file change
- Component registry pushed to extension via WebSocket on connect (`COMPONENT_DATA`) and on file change (`COMPONENT_UPDATE`) — feature-008

## Error Isolation
Token discovery and parsing are wrapped in try/catch. A parse failure in any token source (e.g., malformed tailwind.config.ts) degrades to "no tokens" mode for that source without crashing the WebSocket server or MCP transport. The server logs the error and includes it in the TokenSourceStatus array pushed to the extension.

## Edge Cases
- Port already in use → try next port, log the actual port
- Server not yet started when extension tries to connect → extension retries with exponential backoff (1s, 2s, 4s, 8s, 16s cap, max 5 attempts). After 5 failures: persistent "Server not found — ensure MCP server is running" message with manual Retry button.
- On reconnect: extension sends EXTENSION_HELLO with current pending diff IDs. Server responds with SERVER_HELLO containing known IDs. Extension sends only missing diffs (prevents duplicates and ensures consistency).
- Multiple Chrome tabs → all connect, diffs tagged with source tab/URL
- Claude Code not running → diffs queue in server memory, delivered when Claude Code connects
- Token source file changes while running → rebuild token registry, push update to all connected extensions
- Server process crashes → Claude Code's MCP client restarts it on next tool call (dependency on Claude Code behavior — documented assumption). Pending queue restored from `.frontend-editor/pending-queue.json` on restart.
- Page reload → extension content script reinitializes, restores pending queue from chrome.storage.session, reconnects WebSocket, sends EXTENSION_HELLO for reconciliation

## Persistence
MCP server writes pending queue to `.frontend-editor/pending-queue.json` on each queue update (add/acknowledge/reject). File is deleted when queue is empty. On crash and restart, queue is restored from this file. Extension persists queue to chrome.storage.session — survives page reloads and service worker suspension, cleared on browser close.

## Configuration

```json
{
  "mcpServers": {
    "frontend-editor": {
      "command": "npx",
      "args": ["--yes", "@frontend-editor/mcp-server"]
    }
  }
}
```

> **Alternative:** `npm install -g @frontend-editor/mcp-server` for faster startup (avoids npx registry check)

## Acceptance Criteria
- [ ] WebSocket server accepts connections from the Chrome extension
- [ ] MCP tools return correct data over JSON-RPC 2.0 stdio transport
- [ ] Protocol version handshake on connect (EXTENSION_HELLO / SERVER_HELLO)
- [ ] EXTENSION_HELLO reconciliation prevents duplicate diffs after reconnect or page reload
- [ ] `get_pending_visual_changes` returns all queued diffs
- [ ] `acknowledge_visual_change` removes diff from queue
- [ ] `reject_visual_change` rejects a diff and removes it from the queue
- [ ] `export_session` and `import_session` tools correctly serialize and restore session state
- [ ] `get_design_tokens` returns parsed tokens, filterable by category
- [ ] `resolve_to_token` maps CSS values to nearest token with exactMatch flag
- [ ] Tokens auto-discovered at startup and pushed to extension
- [ ] Token registry rebuilds on file change
- [ ] Token parse failures degrade gracefully (error isolation — no server crash)
- [ ] Port fallback works when default port is in use
- [ ] Multiple tabs supported with diffs tagged by source tab/URL
- [ ] Diffs queue in memory when Claude Code is not connected
- [ ] Pending queue persisted to `.frontend-editor/pending-queue.json` and restored on crash/restart
- [ ] Page reload recovery: content script reinitializes, restores queue, reconnects, and reconciles via EXTENSION_HELLO
