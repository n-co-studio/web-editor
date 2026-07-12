# Compatibility Matrix

n'co studio Web Editor uses a typed WebSocket protocol (`WS_PROTOCOL_VERSION`) between the Chrome extension and the MCP server. This document maps protocol versions to minimum package versions and explains what happens when they do not match.

---

## Current versions

| Component | Current version | npm package |
|-----------|----------------|-------------|
| Protocol | **0.4.0** | (defined in `@nco-studio/shared`) |
| MCP server | **0.1.0** | `@nco-studio/web-editor-mcp` |
| Chrome extension | **0.2.0** | (Chrome Web Store / manual install) |
| Dev plugin | **0.1.0** | `@nco-studio/web-editor-plugin` |

---

## Protocol version matrix

| `WS_PROTOCOL_VERSION` | Min extension version | Min mcp-server version | Notes |
|-----------------------|-----------------------|------------------------|-------|
| `0.4.0` | 0.2.0 | 0.1.0 | Current — component awareness, status protocol |
| `0.3.x` | 0.1.x | 0.0.x | Token push, TOKEN_UPDATE messages |
| `0.2.x` | 0.1.x | 0.0.x | Keepalive, error messages |
| `0.1.x` | 0.1.x | 0.0.x | Initial VISUAL_DIFF_BATCH protocol |

---

## What the mismatch banner means

When the protocol version sent by the extension in `EXTENSION_HELLO` does not match the protocol version the MCP server expects, the extension displays a banner at the top of the page:

> **n'co studio: Protocol mismatch.** Extension is version X.Y.Z, server expects A.B.C. Update one or both to resolve.

**What to do:**

1. **Extension is older than server** — update the Chrome extension via Chrome Web Store or by downloading the latest package from Releases
2. **Server is older than extension** — run `npx @nco-studio/web-editor-mcp@^0` (the `@^1` pin auto-updates within the `1.x` range)

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

### Upgrading the MCP server

Update the pin in `.claude/settings.json`:

```json
"args": ["--yes", "@nco-studio/web-editor-mcp@^2"]
```

Or pin to a specific version:

```json
"args": ["@nco-studio/web-editor-mcp@2.0.0"]
```

### Upgrading the dev plugin

```sh
npm install --save-dev @nco-studio/web-editor-plugin@^2
```

### Upgrading the extension

Download the new version from the [Releases page](../../releases) and follow the install steps in [QUICKSTART.md](QUICKSTART.md#step-3--install-the-chrome-extension).

---

## Dev plugin compatibility

The dev plugin (`@nco-studio/web-editor-plugin`) only injects `data-source-*` attributes and does not participate in the WebSocket protocol. It is version-independent of the extension and MCP server — any `0.x` version of the plugin works with any `0.x` version of the extension.

The plugin is a build-time transform only. It has no runtime state. Updating the plugin requires restarting the Vite dev server.

---

## Known limitations

- **Protocol version checking** is advisory only in `0.x` — the extension displays the mismatch banner but does not block editing. Breaking checks will be enforced starting in `1.0.0`.
- **CSS-only projects** (no JSX): the dev plugin cannot inject `data-source-*` attributes into plain HTML or CSS. Source location is resolved by Claude Code heuristically.
- **Non-Vite bundlers** (Webpack, esbuild): the dev plugin is Vite-only. A standalone Babel plugin for Webpack projects is planned but not yet shipped.
