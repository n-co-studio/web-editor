# Feature: Dev Plugin (Source Mapping)

## Summary
Build plugin that injects `data-source-file` and `data-source-line` attributes onto every rendered DOM element during development. This is the deterministic source mapping layer that enables precise file:line references in visual diffs. Published as a standalone source-mapping primitive — Frontend Editor is a first-party consumer.

## User Flow
1. Operator installs `@nco-studio/web-editor-plugin` as a devDependency
2. Operator adds plugin to their build config (Vite or Babel)
3. Dev server starts — plugin activates in development mode
4. At build time, plugin visits every JSX/TSX element in the AST
5. Adds `data-source-file` (relative path from project root) and `data-source-line` (line number in source)
6. Attributes appear in transpiled output, not in source files
7. In production mode (`NODE_ENV=production` or `mode !== 'development'`), the plugin is a no-op

> **Vite compatibility:** Works with both `@vitejs/plugin-react` (Babel) and `@vitejs/plugin-react-swc` (SWC) — the dev-plugin uses Vite's transform hook with `@babel/parser` + `@babel/traverse` + `magic-string`, independent of the target project's JSX transform pipeline.

### Installation
```bash
npm install -D @nco-studio/web-editor-plugin
```

```ts
// vite.config.ts
import { ncoWebEditor } from '@nco-studio/web-editor-plugin'
export default defineConfig({
  plugins: [ncoWebEditor()]
})
```

> **Non-Vite Babel setups:** In non-Vite Babel setups, production exclusion uses `NODE_ENV` check as an inline guard at plugin entry (not reliant on build tool to exclude).

## UI States
N/A — build-time plugin, no UI. Effects are visible as `data-source-*` attributes in the DOM inspector.

## Inputs
- JSX/TSX source files processed during build
- Build mode (development vs production)

## Outputs
- Transpiled output with `data-source-file`, `data-source-line`, and `data-source-index` attributes on every DOM element
- `data-source-index` is added for repeated sibling elements sharing the same source line (e.g., inside `.map()` calls)
- Zero output in production mode

## Edge Cases
- Fragment shorthand (`<>...</>`) → skip (no DOM element to annotate)
- Component wrappers that don't render a DOM element → attribute lands on first DOM child
- Dynamic JSX (`React.createElement`) → Babel plugin handles; Vite plugin may miss non-JSX patterns
- SSR / Server Components → only annotate client-rendered elements
- Repeated elements inside `.map()` calls → plugin detects sibling JSX elements at the same source line and injects `data-source-index` for disambiguation
- v1 scope: JSX/TSX files only. Vue SFCs, Svelte components, and plain HTML are not supported. Source mapping falls back to "source unverified" for non-JSX projects.

## Acceptance Criteria
- [ ] Vite plugin injects correct `data-source-file` and `data-source-line` on every JSX element
- [ ] Babel plugin injects correct `data-source-file` and `data-source-line` on every JSX element
- [ ] `data-source-file` contains relative path from project root
- [ ] `data-source-line` contains correct line number in source
- [ ] Production builds contain zero trace of dev-plugin annotations
- [ ] Fragment shorthand elements are skipped without error
- [ ] Per-file HMR transform time adds less than 1% overhead relative to Vite's base transform time for the same file (measured on a 500-node JSX file)
- [ ] Plugin is a complete no-op in production mode
- [ ] `data-source-index` correctly disambiguates repeated sibling elements
- [ ] Plugin works with both `@vitejs/plugin-react` and `@vitejs/plugin-react-swc` Vite configurations
