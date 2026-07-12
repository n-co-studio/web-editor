# Privacy Policy — n'co studio Web Editor

**Last updated:** 2026-06-17

## Summary

n'co studio Web Editor is a developer tool. It collects no personal data, transmits no data to any remote server, and requires no account.

---

## What the extension does

n'co studio Web Editor is a Chrome extension that overlays a visual editing interface on locally-running web pages (development servers at `localhost` / `127.0.0.1`). It lets developers select DOM elements, adjust visual properties, and send structured diffs to Claude Code via a locally-installed MCP server.

## Data collection

**None.** The extension does not collect, store, or transmit any personal information, browsing history, page content, or usage analytics to any external party.

## Network activity

All network communication is **strictly local**:

- The extension's content script opens a WebSocket connection to `ws://localhost:<port>` — the locally-installed `@nco-studio/web-editor-mcp` server running on your own machine.
- No data is sent to n'co studio servers, cloud services, third-party analytics platforms, or any remote endpoint.
- The extension operates on `http://localhost/*`, `http://127.0.0.1/*`, and `https://localhost/*` only. It does not run on public websites.

## The local MCP server

The extension requires a companion MCP server process (`@nco-studio/web-editor-mcp`) that the developer installs and runs locally via `npx`. This server process:

- Runs entirely on your machine.
- May read project configuration files (e.g., `tailwind.config.ts`, `package.json`) to discover design tokens and component definitions. This evaluation is local and no project data leaves your machine.
- Does not connect to any remote service.

## Permissions used

| Permission | Purpose |
|------------|---------|
| `activeTab` | Read the current tab's URL and DOM structure to enable element selection on the active developer page. |
| `storage` | Persist the pending diff queue locally across page reloads using `chrome.storage.session` (session-scoped, cleared when Chrome closes). |
| `scripting` | Inject the overlay content script into localhost pages when the extension is activated. |
| `http://localhost/*`, `http://127.0.0.1/*`, `https://localhost/*` | Restrict all extension activity to local development servers only. The extension never activates on production or public websites. |

## Data sharing

No data is shared with any third party. There are no analytics, advertising, or tracking integrations.

## Children's privacy

This extension is a developer tool intended for software developers. It is not directed at children and does not knowingly collect information from minors.

## Changes to this policy

If this policy changes in a material way, the updated version will be published at the extension's homepage. The "Last updated" date at the top of this page will reflect the most recent revision.

## Contact

Questions about this privacy policy may be directed to the project repository:
[github.com/nco-studio/web-editor](https://github.com/nco-studio/web-editor)
