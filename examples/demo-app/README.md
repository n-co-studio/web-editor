# n'co studio Demo App

A Vite + React **guide** for the Visual Web Editor for AI Agents: a hero, a three-step "how it works" row, and a tabbed guide covering setup, day-to-day use, and troubleshooting.

The design follows the **Mark Preston** brand system: two Adobe Typekit faces — `minion-3-display` (serif, display) and `hero-new` (sans, body) loaded via kit `ivy7roo` — thin/light weights, **sharp corners** (no border-radius), **no shadows**, generous whitespace and hairline dividers. The guide itself is ink on white paper (a faint dot grid, `.nco-paper`). The one dark surface is the masthead strip at the top ([`src/components/TopBanner.tsx`](src/components/TopBanner.tsx)), which carries the nco.studio landing page's animated green lava field ([`src/components/LavaBackground.tsx`](src/components/LavaBackground.tsx)) — scoped to the strip, not behind the page.

The page **owns its own design tokens** in [`src/tokens.css`](src/tokens.css): the MCP server discovers those CSS custom properties and snaps edits to them — there is no separate "default" token set to override (see `packages/mcp-server/src/tokens.ts`). Edit a token here and it *is* what the tool offers.

## Run

```sh
npm install
npm run dev
```

## Publish

This page is also the hosted guide at https://nco.studio/web-editor/. From the repo root, `npm run deploy:site` builds it for that sub-path and syncs the output into the nco.studio site repo; commit and push there to deploy.

The dev server starts at `http://localhost:5173`. There is a single page — no router.

With the Visual Web Editor for AI Agents extension enabled, inspect any element in DevTools — you'll see `data-source-file` and `data-source-line` attributes injected by the plugin:

```html
<div data-source-file="src/components/StepsRow.tsx" data-source-line="..." ...>
```

## Sections

Rendered from [`src/App.tsx`](src/App.tsx), in order:

| Component | Role |
|-----------|------|
| [`TopBanner`](src/components/TopBanner.tsx) | Masthead strip — product name, nco.studio credit, and the lava field |
| └ [`LavaBackground`](src/components/LavaBackground.tsx) | Decorative animated canvas field, scoped to the strip |
| [`Hero`](src/components/Hero.tsx) | Headline and subhead |
| [`GuideTabs`](src/components/GuideTabs.tsx) | Tab shell for the three guide panels below |
| ├ [`SetupGuide`](src/components/SetupGuide.tsx) | "Set it up" — install, connect the agent, run |
| ├ [`HowToUse`](src/components/HowToUse.tsx) | "How to use" — the editing loop |
| └ [`Troubleshooting`](src/components/Troubleshooting.tsx) | Connection resets, port conflicts, duplicate config |

`Logo.tsx` is used by `TopBanner`. `StepsRow.tsx`, `Faq.tsx`, `Benefits.tsx`, `Walkthrough.tsx`, and `SiteFooter.tsx` remain in `src/components/` but are **not rendered** — they are leftovers from earlier versions of the page, kept for reference.

## Edit targets

Token-driven edit targets, spread across the sections (full set in `src/tokens.css`):

| Token | CSS variable | Where visible |
|-------|-------------|---------------|
| Ink | `--color-ink` | Headings, step titles |
| Secondary text | `--color-secondary` | Body copy, step numerals |
| Dividers / borders | `--color-divider`, `--color-border` | Hairline rules, tab underline |
| Serif display | `--font-serif` + `--fw-light` | Hero headline, step titles |
| Sans body | `--font-sans` | Body copy, step numerals, tabs |
| Spacing | `--space-3` / `--space-12` / `--space-20` | Section rhythm, steps grid |
| Display size | `--text-display` | Hero headline |
| Heading size | `--text-h2` | Step titles |

Edit one with the extension → review in the panel → send to your AI coding agent over MCP.

## What is installed

| Package | Role |
|---------|------|
| `react` + `react-dom` | UI framework |
| `@vitejs/plugin-react` | JSX transform |
| `@nco-studio/web-editor-plugin` | Injects `data-source-*` attributes in dev |

## Follow the full quickstart

Once the server is running, follow [QUICKSTART.md](../../QUICKSTART.md) starting at Step 3 (install the extension).
