# Privacy Policy — Visual Web Editor for AI Agents

**Last updated:** 2026-09-21

## Summary

Visual Web Editor for AI Agents is a developer tool. It collects no personal data, transmits no data to any remote server, and requires no account.

---

## What the extension does

Visual Web Editor for AI Agents is a Chrome extension that overlays a visual editing interface on locally-running web pages (development servers at `localhost` / `127.0.0.1`). It lets developers select DOM elements, adjust visual properties, and send structured diffs to Claude Code via a locally-installed MCP server.

## Data collection

**None.** The extension does not collect, store, or transmit any personal information, browsing history, page content, or usage analytics to any external party.

## First-install onboarding

On first install, the extension opens the setup guide at https://nco.studio/web-editor/ in a new browser tab. This is a static informational page; the extension sends it no data.

## Network activity

All network communication is **strictly local**:

- The extension's content script opens a WebSocket connection to `ws://localhost:<port>` — the locally-installed `@nco-studio/web-editor-mcp` server running on your own machine.
- No data is sent to n'co studio servers, cloud services, third-party analytics platforms, or any remote endpoint.
- The extension loads **automatically** on `http://localhost/*`, `http://127.0.0.1/*` and `https://localhost/*` only — your own dev servers. It never loads itself into a site you are merely browsing.
- On any other page it runs only when you click the toolbar icon, on that tab alone. Wherever it runs, the extension itself talks only to your local MCP server and sends nothing anywhere else.

### What your agent sees

The extension never sends your data off your machine. Your **agent** is a separate matter, and worth being deliberate about.

Each edit you send carries, to your local MCP server, the following. This list is
maintained by hand and kept in sync whenever the payload changes, but the
binding definition is the `VisualDiff` type in
[`packages/shared/src/diff.ts`](https://github.com/n-co-studio/web-editor/blob/main/packages/shared/src/diff.ts)
— read it if you need certainty rather than a summary.

- **The page's full URL**, with every edit — including any account id, order number or token in its path or query string.
- **The element you edited**: its tag, a CSS selector for it, its text content, and *all* of its attributes — so a `data-customer-id` or a personalised `aria-label` goes too, even for a purely cosmetic change.
- **The before and after values** of the properties you changed.
- **A second element, in full**, when your edit requires one — some changes have to touch a parent or sibling to work (adding `isolation: isolate` to a parent, say). That element travels with the same detail as the one you edited: tag, selector, text and every attribute.
- **Any notes you typed**, verbatim, with the batch they belong to — along with the tag, selector and text of every element you attached them to. These are free text, so they contain whatever you wrote.
- **The source file and line** each element maps to, where your dev plugin supplied them, the served path of any image on it (so filenames travel), plus the element's position and size on the page and an opaque per-tab id.
- **Where the property you changed comes from** — the URL of the stylesheet that owns it, the CSS selector, its specificity, and any media query or cascade layer around it. Not only the rule in force: rules for *other* breakpoints are read and sent too, so CSS that only applies at screen sizes you are not looking at travels with the edit. On a live site that describes a real part of that site's CSS architecture.
- **The viewport size** and the breakpoint your edit was made at.
- **Full HTML of the element and everything inside it**, but only when you insert, duplicate or paste an element, or make a formatted-text edit. An ordinary spacing or colour change does not send subtree markup.
- **Neighbouring and container elements** — for reorder, insert, group and reparent edits, the selector, mapped source location and resolved asset path of the siblings and containers involved, which can be several elements you did not touch directly.
- **The component's name and import path**, when you insert one of your project's own components — a slice of your internal module naming.
- **CSS and behaviour the tool generated for you**, such as the rules written by the parallax editor. This is your own edit described back, not pre-existing page code.

Screenshots are the exception: they are stitched and saved in your browser and never go to the MCP server.

The MCP server runs on your machine, but your agent is the next step, and most agents send what they read to a model provider. Claude Code, for example, is a local program whose model calls go to Anthropic's API — so content you edit reaches Anthropic the same way any file you ask it to read does. That was already true on your dev server. What changed is that you can now point the editor at any page, including a production site you are logged into, so the choice of what to put in front of your agent is yours alone.

Practically: treat editing a logged-in or production page the way you would treat pasting that page into a chat with your agent. If a page holds personal data, customer records or anything you would not paste, do not edit it there.

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
| `scripting` | Inject the overlay into the page you are on when you click the toolbar icon. Injection is always something you initiate — the extension never injects itself into a page you are only visiting. |
| `http://localhost/*`, `http://127.0.0.1/*`, `https://localhost/*` | The only pages the editor loads on **automatically**, because they are your own dev servers. On any other site it loads only when you click the toolbar icon. |

## Data sharing

No data is shared with any third party. There are no analytics, advertising, or tracking integrations.

## Children's privacy

This extension is a developer tool intended for software developers. It is not directed at children and does not knowingly collect information from minors.

## Changes to this policy

If this policy changes in a material way, the updated version will be published at the extension's homepage. The "Last updated" date at the top of this page will reflect the most recent revision.

## Contact

Questions about this privacy policy may be directed to the project repository:
[github.com/n-co-studio/web-editor](https://github.com/n-co-studio/web-editor)
