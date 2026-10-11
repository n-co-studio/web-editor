# Security Policy

## Supported Versions

| Version | Supported |
|---|---|
| 0.x (latest minor) | Yes |

## Security Model

Visual Web Editor for AI Agents is a **fully local tool**. It has no external network communication of its own, no telemetry, no user accounts, and no cloud services.

- All communication between the Chrome extension and the MCP server is via **localhost WebSocket only**.
- Neither the extension nor the MCP server sends your data anywhere else.
- The MCP server does not listen on any external interface.

**Your agent is the boundary.** The MCP server exists to hand edits to an AI agent, and most agents send what they read to a model provider. So while nothing leaves your machine *by way of this tool*, the content of an edit does reach your agent's provider — as any file you ask it to read would. Note that a local dev server is not automatically harmless: it is often pointed at a seeded database, a staging copy or a production dump, so the page you edit may hold real records. See [docs/privacy-policy.md](docs/privacy-policy.md) for exactly what each edit carries.

## Known Design Decisions With Security Implications

### Token Discovery Executes Project Code

The MCP server discovers design tokens from project configuration files (`tailwind.config.ts`, `tailwind.config.js`, `tokens.json`, CSS custom properties, and `design-system.md`). For TypeScript-based config files (e.g. `tailwind.config.ts`), the server compiles and evaluates the file using **esbuild** in the same process.

**What this means:**
- Code inside your `tailwind.config.ts` is executed inside the MCP server process.
- This includes any side effects the config file may have (file I/O, network calls, etc.).
- The MCP server runs in your project's trust context — the same trust level as running `vite`, `next dev`, or `npx tsx`.

**Mitigation:**
- This is only a risk if you run the MCP server in a project you do not trust.
- Do not run the MCP server against untrusted third-party projects.

### Chrome Extension Content Script

The Chrome extension injects a content script into every browser tab matching the manifest's `content_scripts.matches` — `http://localhost/*`, `http://127.0.0.1/*` and `https://localhost/*`. No broader host permissions are requested, so the script is never injected into a site you are merely browsing. The script:
- Reads and observes DOM structure
- Intercepts pointer events on selected elements
- Sends structured visual diffs (CSS property changes) to the MCP server via WebSocket

The content script does not read form data, passwords, cookies, or localStorage of target pages.

## Reporting a Vulnerability

If you discover a security vulnerability, please report it privately:

- **Email:** hello@markpreston.co
- **GitHub:** Open a [GitHub issue](https://github.com/n-co-studio/web-editor/issues) with the label `security` for low-severity issues, or use GitHub's private vulnerability reporting for higher-severity issues.

Please include:
1. A description of the vulnerability
2. Steps to reproduce
3. Potential impact assessment
4. Any suggested mitigations

We will respond within 7 business days. We do not have a formal bug bounty program at this time.
