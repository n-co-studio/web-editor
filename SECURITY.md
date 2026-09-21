# Security Policy

## Supported Versions

| Version | Supported |
|---|---|
| 0.x (latest minor) | Yes |

## Security Model

n'co studio Web Editor is a **fully local tool**. It has no external network communication, no telemetry, no user accounts, and no cloud services.

- All communication between the Chrome extension and the MCP server is via **localhost WebSocket only**.
- No data leaves your machine.
- The MCP server does not listen on any external interface.

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

The Chrome extension injects a content script into every browser tab that matches `http://localhost:*`. The script:
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
