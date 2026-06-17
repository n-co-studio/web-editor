# NCO Studio Demo App

A minimal Vite + React task board, pre-wired with `@nco-studio/web-editor-plugin`. Use it as the editable target for the [QUICKSTART.md](../../QUICKSTART.md) walkthrough.

## Run

```sh
npm install
npm run dev
```

The dev server starts at `http://localhost:5173`.

With the NCO Studio Web Editor extension enabled, inspect any element in DevTools — you'll see `data-source-file` and `data-source-line` attributes injected by the plugin:

```html
<div data-source-file="src/components/TaskBoard.tsx" data-source-line="72" ...>
```

## Edit targets

The app is intentionally minimal with obvious token-driven edit targets:

| Token | CSS variable | Where visible |
|-------|-------------|---------------|
| Brand primary | `--color-primary` | Avatar backgrounds, tag borders, header logo |
| Accent | `--color-accent` | High-priority dots |
| Card padding | `--space-4` | Task card inner padding |
| Body-sm type | `--text-body-sm` | Task titles, legend labels |

Edit one with the extension → review in the queue panel → send to Claude Code.

## What is installed

| Package | Role |
|---------|------|
| `react` + `react-dom` | UI framework |
| `@vitejs/plugin-react` | JSX transform |
| `@nco-studio/web-editor-plugin` | Injects `data-source-*` attributes in dev |

## Follow the full quickstart

Once the server is running, follow [QUICKSTART.md](../../QUICKSTART.md) starting at Step 3 (install the extension).
