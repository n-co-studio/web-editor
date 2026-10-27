# Compatibility Matrix

AI Agent Visual Editor uses a typed WebSocket protocol (`WS_PROTOCOL_VERSION`) between the Chrome extension and the MCP server. This document maps protocol versions to minimum package versions and explains what happens when they do not match.

---

## Current versions

| Component | Current version | npm package |
|-----------|----------------|-------------|
| Protocol | **0.4.0** | (defined in `@nco-studio/shared`) |
| MCP server | **0.3.0** | `@nco-studio/web-editor-mcp` |
| Chrome extension | **0.3.0** | (Chrome Web Store / manual install) |
| Dev plugin | **0.3.0** | `@nco-studio/web-editor-plugin` |

---

## Protocol version matrix

| `WS_PROTOCOL_VERSION` | Min extension version | Min mcp-server version | Notes |
|-----------------------|-----------------------|------------------------|-------|
| `0.4.0` | 0.2.0 | 0.2.0 | Current — component awareness, status protocol |
| `0.3.x` | 0.1.x | 0.0.x | Token push, TOKEN_UPDATE messages |
| `0.2.x` | 0.1.x | 0.0.x | Keepalive, error messages |
| `0.1.x` | 0.1.x | 0.0.x | Initial VISUAL_DIFF_BATCH protocol |

---

## What the mismatch banner means

When the protocol version sent by the extension in `EXTENSION_HELLO` does not match the protocol version the MCP server expects, the extension displays a persistent banner at the top of the page. The banner heading and detail text read:

> **AI Agent Visual Editor — Protocol Version Mismatch**
>
> Extension expects protocol {clientVersion} but the MCP server sent {serverVersion}. The WebSocket connection has been closed to prevent data corruption.

The banner also shows a fix hint: `npx --yes @nco-studio/web-editor-mcp@latest`.

**What to do:**

1. **Extension is older than server** — update the Chrome extension via Chrome Web Store or by downloading the latest package from Releases
2. **Server is older than extension** — run `npx @nco-studio/web-editor-mcp@^0` (the `@^0` pin auto-updates within the `0.x` range)

Do not ignore the banner — a mismatched protocol means some features may silently not work.

---

## The `@^0` pin rationale

The quickstart and MCP server config use the semver range `@^0`:

```json
"args": ["--yes", "@nco-studio/web-editor-mcp@^0"]
```

This means:
- **Patch updates** (`0.1.0` → `0.1.1`): auto-applied — bug fixes only
- **Minor updates** (`0.1.x` → `0.2.x`): auto-applied — backwards-compatible new features
- **Major version bumps** (`0.x` → `1.x` or later): NOT auto-applied — update explicitly

A major version bump signals a breaking protocol change. At that point you will also need to update the Chrome extension. When the package reaches `1.0.0` (stable release), update the pin to `@^1`.

---

## Upgrade guidance

Within `0.x`, nothing here is required — see "Do I need to do anything?" below.
These steps are for pinned setups, or for the eventual `1.0.0` bump.

### Upgrading the MCP server

With the recommended `@^0` pin, there is nothing to do: the next `npx`
resolution picks up the newest `0.x`. If you pinned an exact version, update it
in `.mcp.json`:

```json
"args": ["--yes", "@nco-studio/web-editor-mcp@0.3.0"]
```

To force a refresh of a cached `npx` resolution, run it once directly:

```sh
npx --yes @nco-studio/web-editor-mcp@latest
```

### Upgrading the dev plugin

```sh
npm install --save-dev @nco-studio/web-editor-plugin@^0
```

Restart the Vite dev server afterwards — the plugin is a build-time transform,
so a running server keeps the old one.

### Upgrading the extension

Chrome updates it from the [Chrome Web Store](https://chromewebstore.google.com/detail/ai-agent-visual-editor/aifpecjojmlgdhgnkmkaobmfipdmppea)
automatically, usually within a few hours. To take it immediately, open
`chrome://extensions`, enable Developer mode and press **Update**. If you
installed unpacked, download the new `.zip` from the
[latest release](https://github.com/n-co-studio/web-editor/releases/latest)
and re-load it.

### Do I need to do anything?

For **0.2.1 → 0.3.0, no.** `WS_PROTOCOL_VERSION` is unchanged at `0.4.0`, so a
`0.2.1` server and a `0.3.0` extension talk to each other normally and no
mismatch banner appears. There is no stored-settings migration. The MCP server
updates itself under the `@^0` pin, and the dev plugin is version-independent.

---

## Dev plugin compatibility

The dev plugin (`@nco-studio/web-editor-plugin`) only injects `data-source-*` attributes and does not participate in the WebSocket protocol. It is version-independent of the extension and MCP server — any `0.x` version of the plugin works with any `0.x` version of the extension.

The plugin is a build-time transform only. It has no runtime state. Updating the plugin requires restarting the Vite dev server.

---

## Known limitations

- **Protocol version checking** is advisory only in `0.x` — the extension displays the mismatch banner but does not block editing. Breaking checks will be enforced starting in `1.0.0`.
- **CSS-only projects** (no JSX): the dev plugin cannot inject `data-source-*` attributes into plain HTML or CSS. Source location is resolved by Claude Code heuristically.
- **Non-Vite bundlers** (Webpack, esbuild): the dev plugin is Vite-only. A standalone Babel plugin for Webpack projects is planned but not yet shipped.
