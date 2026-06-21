# Feature: Element Selection

## Summary
Select any visible element on the page via click. Display a highlight overlay with bounding box, tag name, source file, line number, and key computed properties (dimensions, spacing, font, color). Read `data-source-file` and `data-source-line` attributes for deterministic source mapping. Extension activation includes a dropdown toggle from the extension toolbar icon.

## User Flow
1. Operator activates Frontend Editor from the extension toolbar dropdown (toggle on/off). Alternatively: keyboard shortcut.
2. Hold Alt to temporarily pause element inspection and interact with the host page (e.g., open a dropdown, navigate to a state to inspect)
3. Hovering over elements shows a light highlight with tag name tooltip
4. Clicking an element selects it — full highlight with property panel
5. Property panel shows: tag, source file:line, computed dimensions, spacing, typography, colors
6. If tokens are loaded, panel shows resolved token names next to computed values
7. Clicking elsewhere or pressing Escape deselects

## UI States
- **Default**: Extension active, no element selected — cursor changes to crosshair, elements highlight on hover. Extension toolbar dropdown provides on/off toggle.
- **Hover**: Light highlight overlay on hovered element with tag name tooltip (e.g., `<div>`, `<button>`)
- **Paused**: Alt held — pointer events pass through to host page, overlay temporarily hidden
- **Selected**: Full highlight with bounding box and property panel appears as a movable floating panel on the right side of the viewport (default position). Panel can be dragged to reposition.
- **Stale Selection**: Selected element was removed from DOM (SPA navigation, React re-render) — panel shows 'Element no longer in DOM' warning, allows dismissal
- **Warning**: Element has no `data-source-*` attributes — property panel shows warning banner, editing still allowed but diff flagged as "source unverified"
- **Empty**: Extension active on a page with no selectable elements (e.g., blank page) — no interaction

## Panel Specification
- Max width: 300px
- Max height: viewport height with internal scroll
- Positioning cascade: right side of viewport (default), user-draggable to any position
- Position persisted in `chrome.storage.session` for the tab session

## Inputs
- DOM elements on the host page
- `data-fe-uid` attribute (the **stable per-instance element identity** — the canonical diff-targeting key; see [data-contracts § Stable Element Identity](../data-contracts.md#stable-element-identity-data-fe-uid)). Build-stamped by the dev-plugin (feature-006); the content script lazily assigns a fresh uid to any tracked node that lacks a unique one (`.map()` runtime instances, `sourceVerified: false` nodes) and mints fresh uids for cloned/pasted subtrees.
- `data-source-file` and `data-source-line` attributes (injected by dev-plugin) — **code-map location hints only, never identity.** They locate the originating source; clones inherit their origin's `data-source-line`, so they are non-unique and must not key a diff (issue #27). Identity comes from `data-fe-uid`.
- Design tokens from MCP server (if loaded) for token name resolution

## Outputs
- Selected element's `ElementInfo` object (passed to property editing feature and diff creation), including its `uid` from `data-fe-uid` as the canonical identity

## Edge Cases
- Element has no `data-source-*` attributes (dev-plugin not installed) → show warning, still allow editing but flag diff as "source unverified"
- Element is inside Shadow DOM (open) → traverse into shadow root
- Element is inside Shadow DOM (closed) → not selectable, skip
- Element is in a cross-origin iframe → not selectable, skip
- Overlapping elements → use the topmost element at click position
- Selected element removed from DOM (SPA navigation, re-render) → show 'stale selection' warning, allow dismissal
- Alt+click passes through to host page without selecting

## Focus Management
- On extension activation: save the currently focused host page element
- On deactivation or final Escape: restore focus to the saved element
- Tab is trapped within the property panel while it is open (ARIA dialog pattern)
- Progressive Escape ladder: first Escape cancels active edit → second dismisses property panel → third deactivates extension

## Acceptance Criteria
- [ ] Hover highlight renders within one animation frame (requestAnimationFrame-gated, ~16ms at 60fps). Mousemove handler uses rAF gating to prevent layout thrashing.
- [ ] Property panel displays correct source file and line number from `data-source-*` attributes
- [ ] Token names displayed next to computed values when tokens are loaded
- [ ] Warning shown when `data-source-*` attributes are missing
- [ ] Open Shadow DOM elements are selectable
- [ ] Closed Shadow DOM and cross-origin iframe elements are skipped without error
- [ ] Escape key and click-elsewhere both deselect cleanly
- [ ] Property panel appears as a movable floating panel, default position right side of viewport
- [ ] Panel never fully obscures the selected element's bounding box
- [ ] Alt key pauses inspection and passes pointer events to host page
- [ ] Stale selection detected and warned when selected element leaves the DOM
- [ ] `ElementInfo.uid` is populated from `data-fe-uid` as the canonical identity; a tracked node lacking a unique uid (`.map()` instance, `sourceVerified: false`) is lazily assigned a fresh uid on first observation
- [ ] `data-source-*` are surfaced as location hints, not used to distinguish element instances
