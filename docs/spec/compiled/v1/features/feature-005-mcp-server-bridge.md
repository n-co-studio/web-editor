# Feature: MCP Server Bridge

## Summary
Local Node.js process that bridges the Chrome extension to Claude Code. Runs a WebSocket server for the extension and exposes MCP tools for Claude Code. Handles token discovery from project files and pushes token data to the extension. Content script owns the WebSocket connection (not the service worker) to avoid MV3 termination risk.

## User Flow
1. Operator adds MCP server to `.mcp.json` at the project root
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
- `NCO_WEB_EDITOR_PORT` environment variable (optional, default 7890)

## Outputs
- MCP tools exposed to Claude Code:
  - `get_pending_visual_changes` — returns queued diffs (`changes`), operator notes (`notes`), and a lightweight batch summary index (`batches`); accepts optional `batchId` filter
  - `acknowledge_visual_change` — marks diff as applied
  - `reject_visual_change` — rejects a diff and removes it from the queue
  - `get_design_tokens` — returns parsed tokens
  - `resolve_to_token` — maps CSS value to nearest token
  - `get_token_drift_report` — returns a report of design token drift across pending diffs
  - `get_queue_status` — returns lightweight queue status including `latest_batch_id`
  - `export_session` — exports the current session state (pending queue, token registry) to a file
  - `import_session` — restores session state from a previously exported file
  - `get_project_components` — returns the project-local component registry (feature-008; editor-agnostic)
- Token data pushed to extension via WebSocket on connect and on file change
- Component registry pushed to extension via WebSocket on connect (`COMPONENT_DATA`) and on file change (`COMPONENT_UPDATE`) — feature-008

## Error Isolation
Token discovery and parsing are wrapped in try/catch. A parse failure in any token source (e.g., malformed tailwind.config.ts) degrades to "no tokens" mode for that source without crashing the WebSocket server or MCP transport. The server logs the error and includes it in the TokenSourceStatus array pushed to the extension.

TS-config failures are surfaced explicitly: a compile error, an evaluation throw, or a 5s timeout on config evaluation (the dynamic-import step, which bounds a config with a hanging top-level `await`) propagates to the source parser and is recorded as `status: 'error'` in TokenSourceStatus, so the operator can diagnose a broken TS config. JS-config import failures preserve the pre-existing behavior of degrading to `status: 'parsed'` with zero tokens (the source is reported as parsed but empty). This asymmetry is intentional — the TS path is new and favors operator diagnosability; the JS path is unchanged for backward compatibility.

## Edge Cases
- Port already in use → try next port, log the actual port
- Server not yet started when extension tries to connect → extension retries with exponential backoff (1s, 2s, 4s, 8s, 16s cap, max 5 attempts). After 5 failures: persistent "Server not found — ensure MCP server is running" message with manual Retry button.
- On reconnect: extension sends EXTENSION_HELLO with current pending diff IDs. Server responds with SERVER_HELLO containing known IDs. Extension sends only missing diffs (prevents duplicates and ensures consistency).
- Multiple Chrome tabs → all connect, diffs tagged with source tab/URL
- Claude Code not running → diffs queue in server memory, delivered when Claude Code connects
- Token source file changes while running → rebuild token registry, push update to all connected extensions
- Server process crashes → Claude Code's MCP client restarts it on next tool call (dependency on Claude Code behavior — documented assumption). Pending queue restored from `.nco-web-editor/pending-queue.json` on restart.
- Page reload → extension content script reinitializes, restores pending queue from chrome.storage.session, reconnects WebSocket, sends EXTENSION_HELLO for reconciliation

## Batch Identity Handling

The bridge is the authoritative point for `batchId` ingest and correlation:

- **Preservation on ingest:** When the bridge receives a `VISUAL_DIFF_BATCH` message, it reads `batchId` from the envelope payload and stamps it onto any diff in `diffs[]` that is missing it (belt-and-suspenders — the extension stamps diffs at source, but the envelope `batchId` is the fallback).
- **batchNote correlation:** When the envelope carries both `batchNote` and `batchId`, the stored `PendingNote` records both fields (`{ text: batchNote, batchId, receivedAt }`), re-associating the operator note with its batch.
- **latest_batch_id tracking:** The bridge tracks the `batchId` of the most recently ingested batch and exposes it via `get_queue_status.latest_batch_id`.
- **batches summary:** The bridge derives the `batches` summary index on demand (for `get_pending_visual_changes`) by scanning the pending queue for unique `batchId` values, aggregating `{ batchId, batchNote?, createdAt, diffCount }`. Ordered newest-first by `createdAt` (earliest diff timestamp in the batch).
- **batchId filter:** When `get_pending_visual_changes` is called with `batchId?`, the bridge filters `changes` to diffs matching that `batchId` before returning.
- **Legacy diffs (no batchId):** Diffs in the pending queue that predate batch identity have no `batchId`. These are passed through in `changes` unchanged and are omitted from the `batches` index (not grouped as a synthetic legacy entry at the bridge level — consumers handle absent `batchId` gracefully).

## Persistence
MCP server writes pending queue to `.nco-web-editor/pending-queue.json` on each queue update (add/acknowledge/reject). File is deleted when queue is empty. On crash and restart, queue is restored from this file. `batchId` rides on each persisted `VisualDiff` and on each `PendingNote` automatically — no migration is needed. Extension persists queue to chrome.storage.session — survives page reloads and service worker suspension, cleared on browser close.

## Configuration

```json
{
  "mcpServers": {
    "nco-web-editor": {
      "command": "npx",
      "args": ["--yes", "@nco-studio/web-editor-mcp@^0"]
    }
  }
}
```

> **Alternative:** `npm install -g @nco-studio/web-editor-mcp` for faster startup (avoids npx registry check)

## Acceptance Criteria
- [ ] WebSocket server accepts connections from the Chrome extension
- [ ] MCP tools return correct data over JSON-RPC 2.0 stdio transport
- [ ] Protocol version handshake on connect (EXTENSION_HELLO / SERVER_HELLO)
- [ ] EXTENSION_HELLO reconciliation prevents duplicate diffs after reconnect or page reload
- [ ] `get_pending_visual_changes` returns `{ changes, notes, batches }` — flat changes + preserved notes + batches summary index
- [ ] `get_pending_visual_changes` accepts optional `batchId` filter and returns only matching diffs
- [ ] `acknowledge_visual_change` removes diff from queue
- [ ] `reject_visual_change` rejects a diff and removes it from the queue
- [ ] `get_queue_status` returns `latest_batch_id` (absent when no batches received)
- [ ] Bridge stamps `batchId` from envelope onto any diff missing it on ingest
- [ ] Bridge correlates `batchNote` to `batchId` in stored `PendingNote`
- [ ] `batches` index is ordered newest-first and omits diffs without `batchId`
- [ ] Legacy diffs (no `batchId`) pass through in `changes` without causing errors
- [ ] `export_session` and `import_session` tools correctly serialize and restore session state
- [ ] `get_design_tokens` returns parsed tokens, filterable by category
- [ ] `resolve_to_token` maps CSS values to nearest token with exactMatch flag
- [ ] Tokens auto-discovered at startup and pushed to extension
- [ ] Token registry rebuilds on file change
- [ ] Token parse failures degrade gracefully (error isolation — no server crash)
- [ ] Port fallback works when default port is in use
- [ ] Multiple tabs supported with diffs tagged by source tab/URL
- [ ] Diffs queue in memory when Claude Code is not connected
- [ ] Pending queue persisted to `.nco-web-editor/pending-queue.json` and restored on crash/restart
- [ ] Page reload recovery: content script reinitializes, restores queue, reconnects, and reconciles via EXTENSION_HELLO
