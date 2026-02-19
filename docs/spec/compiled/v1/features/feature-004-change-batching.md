# Feature: Change Batching

## Summary
Collect multiple edits before applying changes. Review panel lists all pending changes with before/after values and token names. Operator can review, remove unwanted changes, and send the full batch at once.

## User Flow
1. Operator makes edits (each added to pending queue via feature-002)
2. Pending count badge appears on extension icon
3. Operator opens review panel — sees list of changes grouped by element
4. Each change shows: element selector, property, before → after, token names
5. Operator can remove individual changes
6. "Apply Changes" dispatches the batch via WebSocket

> **Note:** There is no separate immediate-send mode. All changes flow through the batch queue. A single edit can be sent immediately by clicking "Apply Changes" with one item in the queue.

## UI States
- **Default**: No pending changes — review panel empty, badge hidden, send button disabled
- **Collecting**: Edits accumulating — badge shows count on extension icon
- **Reviewing**: Panel open — changes listed grouped by element, each with property/before/after/token details
- **Sending**: Batch dispatched — spinner on apply button, changes locked (no removal during send)
- **Sent**: Confirmation shown — queue cleared, badge resets, panel shows "Changes applied" with connection status indicator (e.g., "Applied via Claude Code" or "Queued — waiting for Claude Code")
- **Error**: WebSocket disconnected — queue retained in memory, warning banner shown, send button disabled until reconnect

## Inputs
- `PropertyChange` objects from feature-002 visual editing
- `ElementInfo` for grouping changes by element

## Outputs
- Batched `VisualDiff[]` sent via WebSocket to MCP server (consumed by feature-005) — assembled by content script with uuid, timestamp, PageContext, and sourceVerified flag

## Edge Cases
- Multiple edits to same property on same element → collapse to latest value (only final before/after sent)
- Send with no changes → send button disabled, no action
- WebSocket disconnected during collection → queue retained in memory, warning shown, send disabled until reconnect
- WebSocket disconnects mid-send → retry once on reconnect, surface error if retry fails
- Very large batch (50+ changes) → show count in confirmation dialog before send. Maximum 100 VisualDiffs per batch.
- Page reload during active session → pending queue restored from chrome.storage.session, badge count preserved

## Review Panel Layout
- Element group header: selector truncated at 40 chars, full selector in tooltip on hover
- Property rows: `property: [token-badge] before → after [token-badge]` in monospace font
- Max panel height with overflow scroll
- Removed items go to a "Removed" section (collapsed by default) — items can be restored from there

## Error Message Content
- **WebSocket disconnected**: "Not connected to MCP server — check that Claude Code is running with the frontend-editor MCP configured (port 7890). [Retry]" — uses warning token (#f59e0b), not destructive
- **Source unverified edits in batch**: "Some changes have unverified source mapping — install the dev-plugin for precise file targeting. Changes will be sent with CSS selector only." — inline warning, not modal
- Manual retry button attempts immediate reconnect outside the backoff schedule

## Acceptance Criteria
- [ ] Badge count accurately reflects number of pending changes
- [ ] Changes are grouped by element in the review panel
- [ ] Individual changes can be removed from the batch
- [ ] Duplicate property edits on the same element collapse to the latest value
- [ ] Batch sends the complete set of VisualDiff objects via WebSocket
- [ ] Queue clears on successful send and badge resets
- [ ] Queue is retained when WebSocket is disconnected
- [ ] Send button is disabled when queue is empty or WebSocket is disconnected
- [ ] Page reload preserves pending queue via chrome.storage.session
- [ ] Removed items appear in collapsed "Removed" section and can be restored
- [ ] "Apply Changes" button works for single-item and multi-item batches
