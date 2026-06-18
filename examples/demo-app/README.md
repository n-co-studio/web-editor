# NCO Studio Demo App

A Vite + React **guide** for the NCO Studio Web Editor. The content is built from the editor's own **built-in walkthrough** (the six-step tour shown when you launch the live demo): what the toolbar does, how to toggle it, inspect/DevTools, the edit modes, review & submit, and "have a go" — plus a deeper **setup** section.

The design follows the **Mark Preston** brand system: two Adobe Typekit faces — `minion-3-display` (serif, display) and `hero-new` (sans, body) loaded via kit `ivy7roo` — thin/light weights, **monochrome** ink-on-paper (`#0f0f0f` / `#767676` / `#ffffff`), **sharp corners** (no border-radius), **no shadows**, generous whitespace and hairline dividers.

The page **owns its own design tokens** in [`src/tokens.css`](src/tokens.css): the MCP server discovers those CSS custom properties and snaps edits to them — there is no separate "default" token set to override (see `packages/mcp-server/src/tokens.ts`). Edit a token here and it *is* what the tool offers. The NCO Studio wordmark ([`src/components/Logo.tsx`](src/components/Logo.tsx)) inherits `currentColor`, so it sits in both the header (ink) and footer (paper-on-ink).

## Run

```sh
npm install
npm run dev
```

The dev server starts at `http://localhost:5173`.

With the NCO Studio Web Editor extension enabled, inspect any element in DevTools — you'll see `data-source-file` and `data-source-line` attributes injected by the plugin:

```html
<div data-source-file="src/components/Walkthrough.tsx" data-source-line="..." ...>
```

## Edit targets

Token-driven edit targets, spread across the sections (full set in `src/tokens.css`):

| Token | CSS variable | Where visible |
|-------|-------------|---------------|
| Ink | `--color-ink` | Headings, logo, buttons, step badges, footer field |
| Secondary text | `--color-secondary` | Body copy, captions, nav |
| Dividers / borders | `--color-divider`, `--color-border` | Hairline section rules, edit-mode grid |
| Serif display | `--font-serif` + `--fw-thin` | Hero headline, section headings, step numerals |
| Sans body | `--font-sans` + `--fw-book` | Body copy, nav, buttons |
| Spacing | `--space-8` / `--space-16` / `--space-20` | Step padding, section rhythm |
| Display size | `--text-display` | Hero headline |

Edit one with the extension → review in the panel → send to Claude Code.

## Sections

`Hero` · `HowItWorks` (the loop) · `Walkthrough` (the six tour steps + edit-mode grid) · `SetupGuide` · `SiteFooter` — each a separate component under `src/components/`, plus `Logo`. The `data-source-file` mapping points at a focused file per section.

## What is installed

| Package | Role |
|---------|------|
| `react` + `react-dom` | UI framework |
| `@vitejs/plugin-react` | JSX transform |
| `@nco-studio/web-editor-plugin` | Injects `data-source-*` attributes in dev |

## Follow the full quickstart

Once the server is running, follow [QUICKSTART.md](../../QUICKSTART.md) starting at Step 3 (install the extension).
