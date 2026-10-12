# @nco-studio/web-editor-plugin

Vite and Babel plugin for [AI Agent Visual Editor](https://github.com/n-co-studio/web-editor). Injects `data-source-file` and `data-source-line` attributes onto every rendered DOM element during development — enabling the Chrome extension to map visual selections back to precise source file locations.

This is a standalone source-mapping primitive. AI Agent Visual Editor is a first-party consumer; you can use it independently in any Vite or Babel project that needs element-to-source mapping.

## Installation

```bash
npm install -D @nco-studio/web-editor-plugin
```

## Usage

### Vite

```ts
// vite.config.ts
import { ncoWebEditor } from '@nco-studio/web-editor-plugin'
import { defineConfig } from 'vite'

export default defineConfig({
  plugins: [ncoWebEditor()]
})
```

Works with both `@vitejs/plugin-react` (Babel transform) and `@vitejs/plugin-react-swc` (SWC transform). The plugin uses Vite's `transform` hook with its own `@babel/parser` + `@babel/traverse` + `magic-string` pipeline, independent of the target project's JSX transform.

### Babel (non-Vite)

```ts
// babel.config.ts
import ncoWebEditorBabel from '@nco-studio/web-editor-plugin/babel'

export default {
  plugins: [ncoWebEditorBabel]
}
```

Or in CommonJS:

```js
const ncoWebEditorBabel = require('@nco-studio/web-editor-plugin/babel')

module.exports = {
  plugins: [ncoWebEditorBabel]
}
```

## What It Does

In development mode, the plugin visits every JSX/TSX element in the AST and injects two attributes:

- `data-source-file` — relative path from the project root (e.g. `src/components/Button.tsx`)
- `data-source-line` — line number in the source file

These attributes appear in the transpiled output, not in your source files. They are invisible in the browser UI but readable by the Chrome extension.

In production (`NODE_ENV=production` or Vite `mode !== 'development'`), the plugin is a complete no-op. Zero overhead. No attributes in production output.

## Dual ESM / CJS Output

The package ships both formats:

- `dist/index.js` — ESM (for Vite and modern bundlers)
- `dist/index.cjs` — CommonJS (for Babel, Jest, and CJS consumers)
- `dist/babel.js` / `dist/babel.cjs` — same, for the `./babel` subpath

Import and require both work:

```ts
// ESM
import { ncoWebEditor } from '@nco-studio/web-editor-plugin'

// CJS
const { ncoWebEditor } = require('@nco-studio/web-editor-plugin')
```

## Supported Configurations

| Setup | Supported |
|---|---|
| Vite + `@vitejs/plugin-react` | Yes |
| Vite + `@vitejs/plugin-react-swc` | Yes |
| Babel (non-Vite) | Yes (`./babel` subpath) |
| Vue SFCs | No (v1 — falls back to "source unverified") |
| Svelte | No (v1 — falls back to "source unverified") |
| Plain HTML | No (v1) |

## Zero Production Overhead Guarantee

The plugin exits early when `NODE_ENV === 'production'` (Babel path) or when Vite's `mode` is not `'development'` (Vite path). Your production bundle contains no `data-source-*` attributes and no plugin code.

## Links

- [Repository](https://github.com/n-co-studio/web-editor)
- [Issues](https://github.com/n-co-studio/web-editor/issues)
- [MCP Server](../mcp-server)
