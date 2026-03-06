# Session Log

Each session adds one entry. Keep entries high-signal and readable.

**Rotation:** Keep last 3 sessions here. Move older entries to `session-archive.md`.

---

<!-- Template: copy this block for each new session entry

## Session N — YYYY-MM-DD — Brief description

**Status:** in-progress | complete
**Decisions applied:** [comma-separated IDs]
**Commits:** [hash — message]

### Goal
- [What this session set out to accomplish]

### Plan Summary
- [Key steps taken]

### Changes Made
- `path/to/file` — [what changed]

### Verification (Gates Evidence)
- Commit gates: A1 [pass/n-a], A2 [pass/n-a], A3 [pass/n-a], A4 [pass/n-a], A5 [pass/n-a]
- Push gates: B1 [pass/n-a], B2 [pass/n-a], B3 [pass/n-a]

### Failed Attempts (Brief)
- [None / brief description]

### Known Issues Logged
- [None / reference to known-issues.md entry]

### Follow-ups
- [Items deferred or discovered]

-->

## Session 25 — 2026-03-05 — Typography Shortcut + Shadow DOM Input Guard Fix

**Status:** complete
**Commits:** 7088ac3 — feat(shortcuts): add 't' key shortcut for typography tool, 0bb3372 — fix(shortcuts): use composedPath() to detect inputs inside Shadow DOM

### Goal
- Add plain 't' key shortcut for typography tool
- Fix shortcuts firing while typing in extension UI inputs (notes, etc.)

### Changes Made
- `packages/chrome-extension/src/content/index.ts` — Added 't' key handler in no-modifiers block; replaced `e.target` with `e.composedPath()[0]` in text field guard to pierce Shadow DOM boundary

### Verification (Gates Evidence)
- Commit gates: A1 pass, A2 pass, A3 pass (build clean), A4 pass (no secrets)

### Follow-ups
- None

---

## Session 23 — 2026-03-05 — Keyboard Shortcuts

**Status:** complete
**Commits:** 6567c22 — feat(editor): add keyboard shortcuts for tools, copy/paste, and actions, ee7816b — fix(editor): change notes shortcut to plain 'n', add text field guard

### Goal
- Add comprehensive keyboard shortcuts to the visual editor for faster workflow

### Changes Made
- `packages/chrome-extension/src/content/index.ts` — Added `elementClipboard` state, `pasteElement()` helper, 13 shortcut handlers in `handleGlobalKeydown` (N, Cmd+R/S/C/P, V, Delete/Backspace, 1-0 tool keys, G, D), text field guard to disable shortcuts during typing
- `packages/chrome-extension/src/content/toolbar.ts` — Added public `toggle()` and `isCollapsed()` methods
- `packages/chrome-extension/src/content/batching/review-panel.ts` — Added public `triggerSend()` method

### Verification (Gates Evidence)
- Commit gates: A1 pass, A2 pass, A3 pass (typecheck + build clean), A4 pass (no secrets)

### Follow-ups
- Consider visual shortcut hints on toolbar button tooltips (e.g. "Notes (N)")
- Consider shortcut help overlay (e.g. "?" key shows all shortcuts)

---

## Session 22 — 2026-03-05 — Media Tool + Attribute Change Pipeline + Asset Extraction

**Status:** complete
**Commits:** c10b978 — feat(media): add media editing tool with attribute change tracking, 2e9a708 — feat(mcp-server): extract data URL images to files before queuing diffs

### Goal
- Add a media editing tool to the floating toolbar for image/video properties
- Track HTML attribute changes (src, alt) through the full diff pipeline
- Implement server-side data URL extraction so agents receive file paths instead of base64

### Changes Made
- `packages/shared/src/diff.ts` — Added `AttributeChange` interface, `attributeChanges?` on `VisualDiff`
- `packages/shared/src/index.ts` — Re-exported `AttributeChange`
- `packages/chrome-extension/src/content/editing/media.ts` — **New**: `MediaEditor` class with src/alt/object-fit/object-position/aspect-ratio/background controls, File System Access API picker with IndexedDB directory persistence
- `packages/chrome-extension/src/content/toolbar.ts` — Media icon, label, tool order
- `packages/chrome-extension/src/shared/types.ts` — Added `'media'` to `EditMode`
- `packages/chrome-extension/src/content/index.ts` — Media editor wiring, `commitAttributeEdit()`, `MediaEditor.restoreHandle()`
- `packages/chrome-extension/src/content/batching/diff-builder.ts` — `buildAttribute()` method
- `packages/chrome-extension/src/content/batching/queue.ts` — Attribute change dedup in `collapseExisting()`
- `packages/chrome-extension/src/content/batching/review-panel.ts` — Attribute change rendering (amber "attr" badge), `truncateValue()` for data URLs
- `packages/chrome-extension/src/content/history.ts` — `AttributeHistoryEntry` with undo/redo
- `packages/mcp-server/src/bridge.ts` — `extractDataUrls()`: decodes data URL attribute changes, saves as files, replaces with project-relative paths; `resolveAssetDir()` infers save directory from original src
- `packages/mcp-server/src/server.ts` — Updated tool description for `attributeChanges` and asset extraction behavior

### Verification (Gates Evidence)
- Commit gates: A1 pass, A2 pass, A3 pass (typecheck + build clean for shared + chrome-extension + mcp-server), A4 pass (no secrets)

### Follow-ups
- End-to-end test: pick image via Browse, verify file saved to project, verify agent sees path in diff
- Consider configurable asset directory (currently inferred from fromValue or fallback to public/images/)

---

## Session 21 — 2026-02-23 — Group Elements Phase 2 (UI, Shortcut, Wiring, Server, Boundary)

**Status:** complete
**Decisions applied:** 0001, 0002, 0008
**Commits:** 9bc0b1b — feat: group elements phase 2 — UI, shortcut, wiring, server, boundary, cd7186d — merge: resolve conflict in prompt-t-task-definition.md

### Goal
- Wire Group operation into user-facing UI: Group button in MultiSelectToolbar, Cmd+G keyboard shortcut, makeGroupCommit() orchestrator helper, MCP server description, review panel rendering, boundary expansion

### Plan Summary
1. Add Group button to `multi-select-toolbar.ts` with block-reason guard, tooltip, dashed bounding-box hover preview
2. Add `makeGroupCommit()` to `index.ts` following reorder/insert commit pattern
3. Wire `multiSelectToolbar.onGroup()` callback and Cmd+G / Ctrl+G shortcut
4. Update MCP server tool description to document `groupChanges`
5. Add group change rendering to `review-panel.ts`
6. Add boundary expansion to `boundaries.md`
7. Fix cohesion findings: prompt-serializer group section + Cmd+G preventDefault ordering

### Changes Made
- `packages/chrome-extension/src/content/editing/multi-select-toolbar.ts` — Added `ShadowRoot` param, `onGroup` callback, `buildGroupSection()`, dashed bounding-box preview overlay
- `packages/chrome-extension/src/content/index.ts` — `makeGroupCommit()`, `multiSelectToolbar.onGroup()` wiring, Cmd+G/Ctrl+G shortcut
- `packages/mcp-server/src/server.ts` — Extended `get_pending_visual_changes` description with `groupChanges`
- `packages/chrome-extension/src/content/batching/review-panel.ts` — Group change rendering (purple "wrap" badge), `groupChanges` in removed count
- `packages/chrome-extension/src/content/batching/prompt-serializer.ts` — Group changes collection + "## Group Changes" prompt section
- `docs/spec/compiled/v1/boundaries.md` — "DOM element reparenting for group" boundary expansion
- `docs/ai/task-groups/group-elements.yaml` — Phase 2 marked complete, session 21 decisions

### Verification (Gates Evidence)
- Commit gates: A1 pass, A2 pass, A3 pass (typecheck + build clean), A4 pass, A5 pass (cohesion: C1 fixed, R4 fixed, R2/R3 deferred), A6 pass (contract updated)

### Failed Attempts (Brief)
- None

### Known Issues Logged
- PR #11 diff was ~14k lines because `feature/reorder-phase-1` branch accumulated commits from sessions 10–21 (reorder, insert, MCP resilience, group). Future task groups should branch from main to keep PRs scoped.

### Follow-ups
- Cohesion R2: `refreshGroupAfterHistoryChange` not needed today (no active group overlay)
- Cohesion R3: bridge drift tracking skips structural change styles (consistent with reorder/insert)
- Create fresh branches per task group to avoid bloated PRs

### Post-commit
- Created PR #11, resolved merge conflict in `docs/ai/prompts/prompt-t-task-definition.md` (kept phased-brief instructions from feature branch), merged to main
- Fixed `.gitignore` — added missing `node_modules/`, `dist/`, `*.tsbuildinfo` entries that caused 5k+ untracked files in VS Code source control

---

## Session 20 — 2026-02-23 — Group Elements Phase 1 (Types, Diff, History, DOM Logic)

**Status:** complete
**Decisions applied:** 0001, 0002, 0008
**Commits:** 39d8cc8 — feat: group elements phase 1 — types, diff builder, history, DOM logic

### Goal
- Define shared types, diff builder method, history entry, and core DOM mutation for Group operation (wrapping 2+ sibling elements in a flex container)
- Build foundational layer for Phase 2 UI wiring

### Plan Summary
1. Add `GroupChange` interface to `packages/shared/src/diff.ts`, add `groupChanges` to `VisualDiff`, re-export from `index.ts`
2. Add `buildGroup()` to `diff-builder.ts` following `buildReorder()`/`buildInsert()` pattern
3. Add `GroupHistoryEntry` to `history.ts` with undo (reverse iteration), redo (wrapper before first element), and resetAll cases
4. Create `editing/group.ts` with `groupElements()` (DOM mutation) and `getGroupBlockReason()` (guard)
5. Create task group contract at `docs/ai/task-groups/group-elements.yaml`

### Changes Made
- `packages/shared/src/diff.ts` — Added `GroupChange` interface (type, wrapperTagName, wrapperInitialStyles, containerSelector, insertIndex, wrappedSelectors, prevSibling, nextSibling), added `groupChanges` to `VisualDiff`
- `packages/shared/src/index.ts` — Re-exported `GroupChange`
- `packages/chrome-extension/src/content/batching/diff-builder.ts` — Added `buildGroup()` method
- `packages/chrome-extension/src/content/history.ts` — Added `GroupHistoryEntry` with reverse-iteration undo/resetAll and correct redo wrapper positioning
- `packages/chrome-extension/src/content/editing/group.ts` — **New**: `getGroupBlockReason()` guard + `groupElements()` DOM mutation with moveBefore/appendChild fallback
- `docs/ai/task-groups/group-elements.yaml` — **New**: task group contract for group-elements briefs 1+2

### Verification (Gates Evidence)
- Commit gates: A1 pass (0001/0002/0008), A2 pass (plan documented, 6 files ~68 net lines), A3 pass (`tsc --noEmit` clean, `npm run build` clean for shared + chrome-extension), A4 pass (no secrets), A5 pass (cohesion: 0 critical after fixes — C1 redo refNode fixed, W1 reverse iteration fixed), A6 pass (contract created)

### Failed Attempts (Brief)
- None

### Known Issues Logged
- None

### Follow-ups
- Phase 2: Wire group into toolbar, keyboard shortcut (Cmd+G), multi-select integration, `EditMode` union
- Cohesion W3 (deferred): `GroupHistoryEntry.originalPositions` type is defined inline rather than importing `OriginalPosition` from `group.ts` — intentional to keep history.ts import-free from editing/
- Cohesion I5/I6: `EditMode` does not include 'group' yet, no `refreshGroupAfterHistoryChange` — both Phase 2 scope

---

## Session 19 — 2026-02-23 — MCP Connection Resilience Phases 3–4

**Status:** complete
**Decisions applied:** 0001, 0002, 0008
**Commits:** 8827b46 — feat: MCP connection resilience — lifecycle tracking + clipboard reconciliation

### Goal
- Phase 3: Implement diff lifecycle tracking (`pending → sent → applied`) instead of hard-deleting on DIFF_ACK
- Phase 4: Clipboard reconciliation — track which diffs were copied via "Copy as Prompt"

### Plan Summary
**Phase 3 — Lifecycle Tracking:**
1. Extend `PendingEdit` with `lifecycleStatus` and `sentAt` fields
2. Rewrite `queue.acknowledge()` to transition to 'sent' instead of hard-delete
3. Add lifecycle methods: `markApplied`, `updateFromServerStatus`, `getLifecycleStatus`, `clearStale`, `clearApplied`, `clearPending`
4. Split `ServerHelloPayload` from `knownDiffIds` → `pendingDiffIds` + `appliedDiffIds`
5. Update bridge SERVER_HELLO construction
6. Add `peekUndo()` to EditHistory, wire undo guard in index.ts
7. Wire `onDiffApplied`, `onStatusResponse` callbacks in index.ts
8. Add lifecycle badges, "Check Status" button, stale/applied sections in review panel

**Phase 4 — Clipboard Reconciliation:**
9. Add `copiedToClipboard` + `copiedAt` to PendingEdit
10. Add `markCopied()` + `isCopied()` to queue
11. Wire "Copy as Prompt" callback to mark diffs, show "Copied" badge in review panel

### Changes Made
- `packages/chrome-extension/src/shared/types.ts` — Added `DiffLifecycle` type, `lifecycleStatus?`, `sentAt?`, `copiedToClipboard?`, `copiedAt?` to `PendingEdit`
- `packages/chrome-extension/src/content/batching/queue.ts` — Lifecycle transitions in `acknowledge()`, new methods (`markApplied`, `updateFromServerStatus`, `getLifecycleStatus`, `clearStale`, `clearApplied`, `clearPending`, `getSent`, `getApplied`, `markCopied`, `isCopied`), `pendingCount` getter, updated `getActive()`, `collapseExisting()`, `reconcile()`
- `packages/shared/src/protocol.ts` — Split `ServerHelloPayload` into `pendingDiffIds` + `appliedDiffIds`
- `packages/mcp-server/src/bridge.ts` — Updated SERVER_HELLO to construct split IDs from `pendingQueue` + `processedIds`
- `packages/chrome-extension/src/content/history.ts` — Added `peekUndo()` method
- `packages/chrome-extension/src/content/index.ts` — Wired lifecycle callbacks (`onDiffApplied`, `onStatusResponse`), undo guard via `tryUndo()`, badge uses `pendingCount`, reset uses `clearPending()`
- `packages/chrome-extension/src/content/batching/review-panel.ts` — Lifecycle badges (sent/applied/copied), "Sent to Server" and "Applied" sections, "Check Status" button, stale notice, "Clear applied" link, clipboard marking on copy

### Verification (Gates Evidence)
- Commit gates: A1 pass (0001/0002/0008), A2 pass (plan documented, 7 files), A3 pass (`tsc --noEmit` clean, `npm run build` clean for shared + chrome-extension + mcp-server), A4 pass (no secrets), A5 pending

### Failed Attempts (Brief)
- protocol.ts and history.ts had been modified by concurrent Session 17 — required re-reads before edits

### Known Issues Logged
- None

### Follow-ups
- A5 cohesion review deferred


