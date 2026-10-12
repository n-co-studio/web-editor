# Privacy Policy — AI Agent Visual Editor

**Last updated:** 2026-09-21

## Summary

AI Agent Visual Editor is a developer tool. It collects no personal data, transmits no data to any remote server, and requires no account.

---

## What the extension does

AI Agent Visual Editor is a Chrome extension that overlays a visual editing interface on locally-running web pages (development servers at `localhost` / `127.0.0.1`). It lets developers select DOM elements, adjust visual properties, and send structured diffs to Claude Code via a locally-installed MCP server.

## Data collection

**None.** The extension does not collect, store, or transmit any personal information, browsing history, page content, or usage analytics to any external party.

## First-install onboarding

On first install, the extension opens the setup guide at https://nco.studio/web-editor/ in a new browser tab. This is a static informational page; the extension sends it no data.

## Network activity

All network communication is **strictly local**:

- The extension's content script opens a WebSocket connection to `ws://localhost:<port>` — the locally-installed `@nco-studio/web-editor-mcp` server running on your own machine.
- No data is sent to n'co studio servers, cloud services, third-party analytics platforms, or any remote endpoint.
- The extension operates on `http://localhost/*`, `http://127.0.0.1/*`, and `https://localhost/*` only. It does not run on public websites.

### What your agent sees

The extension never sends your data off your machine. Your **agent** is a separate matter, and worth being deliberate about.

Each edit you send carries, to your local MCP server, the following. The list
is maintained by hand and kept in sync whenever the payload changes. The
authoritative definition is the `VisualDiff` type in the extension's source;
that source is not public yet, so if you need certainty rather than a summary,
email [hello@nco.studio](mailto:hello@nco.studio) and we will tell you exactly
what a given edit contains.

- **The page's full URL**, with every edit — including any account id, order number or token in its path or query string.
- **The element you edited**: its tag, a CSS selector for it, its text content, and *all* of its attributes — so a `data-customer-id` or a personalised `aria-label` goes too, even for a purely cosmetic change.
- **The before and after values** of the properties you changed.
- **A second element, in full**, when your edit requires one — some changes have to touch a parent or sibling to work (adding `isolation: isolate` to a parent, say). That element travels with the same detail as the one you edited: tag, selector, text and every attribute.
- **Any notes you typed**, verbatim, with the batch they belong to — along with the tag, selector and text of every element you attached them to. These are free text, so they contain whatever you wrote.
- **The source file and line** each element maps to, where your dev plugin supplied them, the served path of any image on it (so filenames travel), plus the element's position and size on the page and an opaque per-tab id.
- **Where the property you changed comes from** — the URL of the stylesheet that owns it, the CSS selector, its specificity, and any media query or cascade layer around it. Not only the rule in force: rules for *other* breakpoints are read and sent too, so CSS that only applies at screen sizes you are not looking at travels with the edit.
- **The viewport size** and the breakpoint your edit was made at.
- **Full HTML of the element and everything inside it**, but only when you insert, duplicate or paste an element, or make a formatted-text edit. An ordinary spacing or colour change does not send subtree markup.
- **Neighbouring and container elements** — for reorder, insert, group and reparent edits, the selector, mapped source location and resolved asset path of the siblings and containers involved, which can be several elements you did not touch directly.
- **The component's name and import path**, when you insert one of your project's own components — a slice of your internal module naming.
- **CSS and behaviour the tool generated for you**, such as the rules written by the parallax editor. This is your own edit described back, not pre-existing page code.

Screenshots are the exception: they are stitched and saved in your browser and never go to the MCP server.

The MCP server runs on your machine, but your agent is the next step, and most agents send what they read to a model provider. Claude Code, for example, is a local program whose model calls go to Anthropic's API — so content you edit reaches Anthropic the same way any file you ask it to read does.

Practically: a dev server is not automatically harmless. Local environments are often pointed at a seeded database, a staging copy or a production dump, and the page you are editing may hold real customer records. Treat editing a page the way you would treat pasting that page into a chat with your agent — because in substance that is what it is.

## The local MCP server

The extension requires a companion MCP server process (`@nco-studio/web-editor-mcp`) that the developer installs and runs locally via `npx`. This server process:

- Runs entirely on your machine.
- May read project configuration files (e.g., `tailwind.config.ts`, `package.json`) to discover design tokens and component definitions. Compiling and evaluating them happens entirely on your machine; the server sends nothing anywhere. What your agent then reads from the server is covered above.
- Does not connect to any remote service.

## Permissions used

| Permission | Purpose |
|------------|---------|
| `activeTab` | Read the current tab's URL and DOM structure to enable element selection on the active developer page, and capture the visible tab when you use the screenshot tool. Screenshots are saved to your machine only. |
| `storage` | Persist the pending diff queue locally across page reloads using `chrome.storage.session` (session-scoped, cleared when Chrome closes), and remember your Light / Dark / System theme preference using `chrome.storage.local`. |
| `scripting` | Inject the overlay content script into localhost pages when the extension is activated. |
| `http://localhost/*`, `http://127.0.0.1/*`, `https://localhost/*` | Restrict all extension activity to local development servers only. The extension never activates on production or public websites. |

## Data sharing

This extension shares no data with any third party. There are no analytics, advertising, or tracking integrations, and it transmits nothing beyond the localhost WebSocket described above.

The one onward path is the one you create: the MCP server exists to hand your edits to your own AI agent, and most agents send what they read to their model provider. That provider is your agent's, chosen by you, under your agreement with them — this extension has no relationship with it and sends it nothing directly. See "What your agent sees" above for what an edit contains.

## Children's privacy

This extension is a developer tool intended for software developers. It is not directed at children and does not knowingly collect information from minors.

## Changes to this policy

If this policy changes in a material way, the updated version will be published at the extension's homepage. The "Last updated" date at the top of this page will reflect the most recent revision.

## Contact

Questions about this privacy policy may be directed to the project repository:
[hello@nco.studio](mailto:hello@nco.studio)
