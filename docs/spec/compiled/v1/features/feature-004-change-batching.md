# Feature: Change Batching

## Summary
Collect multiple edits before applying changes. Review panel lists all pending changes with before/after values and token names. Operator can review, remove unwanted changes, and send the full batch at once.

> **Related — Structural Auto-Layout (feature-010).** Structural edits in a batch — reorder, group, reparent — reference their editable-list container by `uid` ([`ReorderChange.containerUid`](../data-contracts.md#reorderchange), [`ReparentChange.sourceContainerUid`/`targetContainerUid`](../data-contracts.md#reparentchange)) and may carry [`LayoutContainerDescriptor`](../data-contracts.md#layoutcontainerdescriptor) peers on `VisualDiff.layoutContainers[]`. These are additive-optional and ride the same batch envelope (no `WS_PROTOCOL_VERSION` bump). See [feature-010](feature-010-structural-contract.md).

## User Flow
1. Operator makes edits (each added to pending queue via feature-002)
2. Pending count badge appears on extension icon
3. Operator opens the review panel — via the toolbar-icon popup ("Open Change Queue") or the in-page toolbar button — it docks full-height to the right edge, showing changes grouped by element
4. Each change shows: element selector, property, before → after, token names
5. Operator can remove individual changes
6. "Apply Changes" dispatches the batch via WebSocket

> **Note:** There is no separate immediate-send mode. All changes flow through the batch queue. A single edit can be sent immediately by clicking "Apply Changes" with one item in the queue.

## Extension Icon Behavior
Clicking the browser toolbar icon opens a small popup menu with two actions:
- **Toggle extension on/off** — activates/deactivates the editing overlay (replaces the former one-click toggle; MV3 suppresses `chrome.action.onClicked` once a `default_popup` is set).
- **Open/Close Change Queue** — shows/hides the right-docked review panel (activating the extension first if it is currently off).

The pending-count badge still overlays the toolbar icon. The popup reflects live state (extension active/inactive, queue open/closed) and falls back gracefully on pages where the content script cannot run.

## UI States
- **Default**: No pending changes — review panel empty, badge hidden, send button disabled
- **Collecting**: Edits accumulating — badge shows count on extension icon
- **Reviewing**: Panel open — docked full-height to the right edge; changes listed grouped by element, each with property/before/after/token details
- **Sending**: Batch dispatched — spinner on apply button, changes locked (no removal during send)
- **Sent**: Confirmation shown — items transition to the persistent "Sent to Server" lifecycle section in the review panel; the pending section clears; badge resets to reflect remaining unsent items. Panel shows connection status indicator (e.g., "Applied via Claude Code" or "Queued — waiting for Claude Code"). The queue is **not** cleared on send — sent items remain visible in the "Sent to Server" section for operator reference (`getSent()` in `queue.ts`; rendered at `review-panel.ts:290`).
- **Error**: WebSocket disconnected — queue retained in memory, warning banner shown, send button disabled until reconnect

## Batch Identity

### batchId Generation
At the moment the operator clicks "Apply Changes", the content script mints a **single `batchId`** for that click and stamps it on **every `VisualDiff` in the dispatch**. The `batchId` uniquely identifies one logical apply-click.

**Format:** `batch-YYYYMMDD-HHMMSS-xxxx`
- `YYYYMMDD` — UTC date of the click
- `HHMMSS` — UTC time of the click
- `xxxx` — 4-character lowercase hex random suffix (collision buffer within the same second)

Example: `batch-20260621-143052-a3f7`

**Invariant — one Apply-Changes click = one batchId.** All diffs dispatched by a single click share the same `batchId`, regardless of how many WebSocket messages are required to send them (see >100-diff handling in Edge Cases). A reconnect retry re-sends the same diffs with the **same** `batchId` — membership rides on the diff, not on the transient send envelope.

**Rationale for readable (not raw UUID):** The operator communicates batch references verbally to the agent and reads the id in the review panel. A human-readable date-time string serves both purposes at negligible cost.

### Batch Identity in Review Panel
The persistent "Sent to Server" and "Applied" sections of the review panel group items by batch using a nested **Batch → Element → Property** layout:

```
▼ Sent to Server (3)
  ┌──────────────────────────────────────────────┐
  │ batch-20260621-143052-a3f7  ·  2m ago        │  ← batch header
  │  ▸ div.hero-section                           │
  │    color: #fff → var(--color-primary)         │
  │  ▸ h1.headline                                │
  │    font-size: 32px → 40px                     │
  └──────────────────────────────────────────────┘
  ┌──────────────────────────────────────────────┐
  │ batch-20260621-135840-c2b1  ·  28m ago  ⚠ stale │
  │  ▸ …                                          │
  └──────────────────────────────────────────────┘
```

- **Nesting:** Batch → Element → Property. Each batch header shows the readable `batchId` + a relative timestamp ("2m ago").
- **Stale indicator:** staleness is now **batch-level**: a batch whose oldest sent diff has `sentAt` older than 24 h shows a stale warning icon on the batch header (rather than per-item stale notices).
- **Applied section:** same Batch → Element → Property grouping; batch headers use the same format.

## Inputs
- `PropertyChange` objects from feature-002 visual editing
- `ElementInfo` for grouping changes by element

## Outputs
- Batched `VisualDiff[]` sent via WebSocket to MCP server (consumed by feature-005) — assembled by content script with uuid, timestamp, PageContext, sourceVerified flag, and `batchId`. Every diff in a single Apply-Changes click carries the same `batchId`.

## Edge Cases
- Multiple edits to same property on same element → collapse to latest value (only final before/after sent)
- Send with no changes → send button disabled, no action
- WebSocket disconnected during collection → queue retained in memory, warning shown, send disabled until reconnect
- WebSocket disconnects mid-send → retry once on reconnect, re-send remaining un-acknowledged diffs with the **same `batchId`** (membership is on the diff, not the transient envelope)
- **>100-diff dispatch (`MAX_DIFFS_PER_BATCH = 100`):** When an Apply-Changes click has more than 100 active diffs, the content script **loop-sends** all diffs under the single click's `batchId` in sequential WebSocket messages of up to 100 diffs each, waiting for acknowledgement before sending the next segment. The invariant "one Apply-Changes click = one `batchId`" is preserved — the logical batch is never silently split across different identifiers. The `VISUAL_DIFF_BATCH` envelope carries the shared `batchId` on every segment.
- Page reload during active session → pending queue restored from chrome.storage.session, badge count preserved

## Review Panel Layout
- Element group header: selector truncated at 40 chars, full selector in tooltip on hover
- Property rows: `property: [token-badge] before → after [token-badge]` in monospace font
- Full-height panel docked to the right edge of the viewport; resizable via a left-edge handle (width persisted via `chrome.storage.session`, default 340px, min 260px, max 50% of viewport width); the change list scrolls internally while the header and action bar stay pinned
- Removed items go to a "Removed" section (collapsed by default) — items can be restored from there

## Error Message Content
- **WebSocket disconnected**: "Not connected to MCP server — check that Claude Code is running with the nco-web-editor MCP configured (port 7890). [Retry]" — uses warning token (#f59e0b), not destructive
- **Source unverified edits in batch**: "Some changes have unverified source mapping — install the dev-plugin for precise file targeting. Changes will be sent with CSS selector only." — inline warning, not modal
- Manual retry button attempts immediate reconnect outside the backoff schedule

## Acceptance Criteria
- [ ] Badge count accurately reflects number of pending changes
- [ ] Changes are grouped by element in the review panel
- [ ] Individual changes can be removed from the batch
- [ ] Duplicate property edits on the same element collapse to the latest value
- [ ] Batch sends the complete set of VisualDiff objects via WebSocket
- [ ] Sent items transition to the persistent "Sent to Server" lifecycle section (queue is NOT cleared on send)
- [ ] Badge resets to reflect remaining unsent items after send
- [ ] Queue is retained when WebSocket is disconnected
- [ ] Send button is disabled when queue is empty or WebSocket is disconnected
- [ ] Page reload preserves pending queue via chrome.storage.session
- [ ] Removed items appear in collapsed "Removed" section and can be restored
- [ ] "Apply Changes" button works for single-item and multi-item batches
- [ ] Every diff in a single Apply-Changes click carries the same `batchId`
- [ ] `batchId` format is `batch-YYYYMMDD-HHMMSS-xxxx` (UTC date + time + 4-char hex suffix)
- [ ] Reconnect retry re-sends diffs with the original `batchId` (not a new one)
- [ ] >100-diff dispatches loop-send all diffs under one `batchId` (multiple WS messages, same id)
- [ ] "Sent to Server" and "Applied" sections group items by batch (Batch → Element → Property)
- [ ] Batch header shows readable `batchId` + relative timestamp; batches older than 24 h show stale indicator

## Future Considerations

### Deferred: Batch-Level Lifecycle Tools
Agent tools for batch-level acknowledgement and rejection (`acknowledge_batch` / `reject_batch`) and supersede markers (marking a batch as superseded by a later one) are **intentionally out of scope for v1**. The `batchId` field on each `VisualDiff` is the designed extension point — per-diff lifecycle tools (`acknowledge_visual_change`, `reject_visual_change`) operate on individual diffs and agents can already group by `batchId` to process a full batch. Batch-level tools are deferred until usage patterns confirm their value.
