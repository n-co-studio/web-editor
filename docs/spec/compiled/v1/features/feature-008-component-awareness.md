# Feature: Component Awareness

## Summary
Discover the target project's local React components (JSX/TSX) and surface them as insertable elements in the insert panel. The MCP server scans convention-gated source roots, parses component signatures (name, import path, prop schema), and pushes the resulting registry to the extension over WebSocket. When the operator picks a project component from the insert panel, the resulting `InsertChange` carries a `componentInsert` descriptor — Claude Code resolves the descriptor into a JSX usage with the correct import. v1 scope is discovery + insert only; prop UI and token-snapping for prop values are deferred to feature-008.1.

## User Flow
1. Operator activates extension on a project with local components under conventional roots (`src/components/**`, `src/ui/**`, `components/**`, or operator-configured roots via `nco-web-editor.componentRoots` in the target project's `package.json`)
2. MCP server scans the configured roots at startup, parses each component, and assembles a `ProjectComponent[]` registry
3. MCP server pushes `COMPONENT_DATA` to the extension over the existing WebSocket
4. Operator opens the insert panel — a new "Project Components" section appears above the standard HTML element catalog
5. Each project component lists its display name and (always) its workspace-relative import path beneath the name to disambiguate same-name components from different files
6. Operator picks a project component and a drop target — the extension produces an `InsertChange` whose `componentInsert` field carries `{ componentName, importPath, props: [] }` (v1 emits empty `props`)
7. The new element renders in the DOM as a placeholder (a phantom `<div>` tagged with `tagName` = `'div'` for the in-page render) until Claude Code applies the source-level insert
8. On file change inside any watched root, the MCP server rebuilds its registry and pushes a fresh `COMPONENT_UPDATE` payload to all connected extensions (full registry resend; per-file delta deferred). `COMPONENT_DATA` is reserved for the initial push on extension connect.

### Discovery Roots (Priority Order)
Same convention-gated, project-scoped scan pattern as token discovery (feature-003):
1. `src/components/**` (highest priority)
2. `src/ui/**`
3. `components/**`

The set can be overridden in the target project's `package.json` via:
```json
{
  "nco-web-editor": {
    "componentRoots": ["src/blocks", "app/components"]
  }
}
```
When `componentRoots` is provided, it replaces the defaults entirely. Paths are resolved relative to the target project root. Standard exclusions apply (`node_modules`, `dist`, `build`, `.cache`).

### Parser
- JSX/TSX only in v1. Same parser toolchain family as the existing token pipeline (`@babel/parser` + `@babel/traverse`). v1 uses **react-docgen v6** for prop extraction — it reuses the existing Babel toolchain and avoids the TypeScript program cost (chosen over react-docgen-typescript per Exploration #1).
- Component identity: each exported component (named or default) within a file produces one `ProjectComponent` entry. Files with no exported components are skipped.
- Import path: workspace-relative path from the target project root (e.g., `src/components/Button.tsx`). No alias resolution in v1 — the raw relative path is emitted; Claude Code resolves to the project's import alias on application.

### File Watcher
File watcher uses chokidar with 300ms debounce. Granularity: per-source rebuild (only the file that changed is re-parsed; surviving entries from other files are retained). Error isolation per file — a parse failure on one file degrades that file's entry to "skipped" without affecting other entries or the WebSocket transport.

## UI States
- **No components found**: Insert panel shows only the standard HTML catalog. No "Project Components" section is rendered.
- **Components loaded**: Insert panel renders a "Project Components" section above the HTML catalog. Each entry shows: display name (component name), workspace-relative import path (always visible, secondary text), and a generic component glyph.
- **Component scan in progress**: Section header shows "Project Components — scanning…" (initial scan only; subsequent file-change rebuilds happen silently in the background).
- **Component scan partial failure**: Section header shows "Project Components (N failed)" when `failedCount > 0`. Failed files are silently omitted from the registry; successful entries remain selectable.
- **Inserted**: Operator picks a project component → drop target accepts → phantom `<div>` renders at the drop target with a `data-nco-web-editor-pending-component="<componentName>"` attribute. The pending changes panel shows the entry as a component insert with the import path.

## Inputs
- Target project file tree (read from disk by the MCP server)
- Target project `package.json` `nco-web-editor.componentRoots` (optional)
- `COMPONENT_DATA` / `COMPONENT_UPDATE` payloads (extension-side)
- Operator's drop target (container + insert index) from the insert panel
- Selected `ProjectComponent` from the insert panel (extension-side)

## Outputs
- `ProjectComponent[]` registry maintained by the MCP server, pushed to the extension on connect and on file change
- `InsertChange` with optional `componentInsert: ComponentInsertDescriptor` populated when the source of the insert is a project component (rather than an HTML element)
- `get_project_components` MCP tool result for Claude Code consumption — returns the same registry with optional name filtering

## Edge Cases
- No project components found (no matching files, or all parse failures) → "Project Components" section is suppressed; standard HTML catalog still works. Insert panel behavior is unchanged.
- Component file deleted while extension is active → MCP server's chokidar watcher removes the entry from the registry, pushes `COMPONENT_UPDATE` with the new full registry; extension re-renders the insert panel.
- Component file added while extension is active → MCP server adds entry, pushes `COMPONENT_UPDATE`. Extension re-renders.
- Component renamed mid-session → treated as delete + add. No identity tracking across renames in v1.
- Two components with the same display name but different files (e.g., `src/ui/Button.tsx` and `src/components/Button.tsx`) → both appear in the panel. The import path beneath the name disambiguates them (Critic CRITICAL #5).
- Parse failure on a single file → that file's entries are dropped from the registry; other entries are preserved (error isolation per file). `failedCount` in the registry payload increments. Server logs the error.
- Components using `forwardRef`, generics, derived prop types (`Omit<…>`), or styled-component exports (`` styled.button`…` ``) may not produce a usable prop schema — react-docgen v6 may return `props: []`. The component **still appears** in the panel and inserts correctly; only the (v1.1) prop editor is degraded.
- Default export with no detectable name (e.g., `export default () => …`) → fall back to the file basename (PascalCased) as `componentName`.
- Component with no exported declaration (file-internal helper only) → skipped (not enumerable).
- Cycle / re-export barrel files (`src/components/index.ts` re-exporting concrete components) → re-exports are not followed; only files that contain a component declaration produce an entry. Avoids double-counting.
- Multi-tab extensions: `COMPONENT_DATA` and `COMPONENT_UPDATE` are broadcast to all connected extensions (same fanout as `TOKEN_DATA` / `TOKEN_UPDATE`).
- Component file changes during an in-progress insert drag → the registry update is queued and applied on commit (same pattern as token updates during a drag).
- Protocol mismatch: extensions on `WS_PROTOCOL_VERSION < 0.4.0` reject the connection during the existing `EXTENSION_HELLO` / `SERVER_HELLO` handshake (same enforcement as today; v1 simply bumps the version).

## Acceptance Criteria
- [ ] MCP server auto-discovers project components from `src/components/**`, `src/ui/**`, and `components/**` at startup
- [ ] `nco-web-editor.componentRoots` in target project's `package.json` overrides default roots
- [ ] `ProjectComponent` entries include `componentName`, `importPath` (workspace-relative), `exportType` (`'named' | 'default'`), `props: []` (v1 always empty), and `source: 'local'`
- [ ] `get_project_components` MCP tool returns `{ components, sourceCount, failedCount }` over JSON-RPC 2.0 stdio, with optional `nameFilter` input
- [ ] WebSocket `COMPONENT_DATA` is pushed on extension connect with the full current registry
- [ ] WebSocket `COMPONENT_UPDATE` is pushed on every registry change with the full updated registry (per-file delta deferred)
- [ ] `WS_PROTOCOL_VERSION` is bumped to `0.4.0`; extensions on prior versions are rejected at handshake
- [ ] File watcher uses chokidar with 300ms debounce and per-file rebuild granularity
- [ ] Parse failure on one file does not affect other entries or crash the WebSocket / MCP transport
- [ ] Insert panel renders a "Project Components" section when the registry is non-empty
- [ ] Each "Project Components" entry shows the workspace-relative import path beneath the component name
- [ ] Operator can drop a project component into a valid container → an `InsertChange` is produced with `componentInsert: { componentName, importPath, props: [] }`
- [ ] Phantom DOM render uses `tagName: 'div'` with `data-nco-web-editor-pending-component` attribute for inspection
- [ ] No `data-source-*` attributes are required on the existing target element to perform a component insert (the descriptor itself locates the component)

## Accepted Limitations
- **No source-mapping for elements inside a freshly inserted component**: An `InsertChange` with `componentInsert` adds a phantom node to the live DOM but no real component instance until Claude Code applies the source-level insert and the dev-plugin re-annotates after rebuild. Subsequent edits inside an inserted component (before the host project re-builds) fall back to "source unverified" mode. Documented from Critic CRITICAL #6.
- **Limited prop schema extraction**: Components using `forwardRef`, generics, derived prop types, or `styled.button` exports may parse with `props: []`. The component still appears in the panel and inserts correctly — the v1.1 prop editor degrades to "no props detected" for these cases.
- **No prop editing in v1**: `PropDefault` exists in data contracts so the v1.1 prop editor lands without schema migration, but v1 always emits `props: []` and renders no prop UI. Prop editing and token-snapping-for-prop-values are scoped to feature-008.1.
- **Compilation failures after import injection are out of scope**: If Claude Code's source-level insert injects an import that fails to compile (missing dependency, alias misconfiguration), the diff lifecycle does not recover. The operator relies on Claude Code's standard recovery path.
- **JSX/TSX only**: Vue SFCs, Svelte components, and plain HTML projects are out of scope (matches the v1 boundary set by feature-006-dev-plugin.md).
- **No external library discovery in v1**: Only project-local components (`source: 'local'`) are discovered. External library components (shadcn, Radix, MUI, etc.) are explicitly deferred — the `source` field reserves `'npm'` as a v2 extension hook without schema migration.
- **Editor-agnostic MCP tool**: `get_project_components` uses only generic working-directory contracts. No Claude Code-specific or VS Code-specific assumptions, preserving compatibility with other MCP-capable editors (Cursor, Windsurf — see boundaries.md Future Considerations).
- **Barrel-file re-exports are not followed**: `index.ts` / `index.tsx` files that only re-export components from other files are skipped. Only files containing component declarations produce registry entries. Operators who organise components under a barrel-file pattern will see individual component files listed, not the barrel path.

## Cross-References
- [feature-003-design-token-snapping.md](feature-003-design-token-snapping.md) — discovery + watcher + error-isolation pattern this feature mirrors
- [feature-005-mcp-server-bridge.md](feature-005-mcp-server-bridge.md) — MCP tool contract patterns and WebSocket transport
- [feature-006-dev-plugin.md](feature-006-dev-plugin.md) — JSX/TSX scope precedent
- [../data-contracts.md](../data-contracts.md) — `ProjectComponent`, `ComponentInsertDescriptor`, `PropDefault`, extended `InsertChange.componentInsert`
- [../boundaries.md](../boundaries.md) — boundary expansion for project-local component inserts; future considerations for prop editing and external libraries
