Bridge Peer Authentication (HACK-010) — Task Brief

Follow docs/ai/prompts/prompt-b-product-build.md.

## Task Brief: Authenticate the extension↔MCP-server WebSocket peer (HACK-010)

### Goal
Stop anything other than the real extension from driving the bridge. Today the only gate is an `Origin` header allowlist that accepts **any** `localhost`, `127.0.0.1` or `::1` origin on any port, plus **any** `chrome-extension://` origin. Script running on the developer's own dev page therefore passes it, as does any other installed browser extension, as does any local process willing to forge the header.

### Why this is not already fixed
`bridge.ts:539-553` carries a comment saying the allowlist "blocks drive-by connections from an arbitrary web page open in the same browser — such a page sends its own truthful Origin on the WS upgrade, which fails this check." That is true of `https://evil.com`. It is **not** true of `http://localhost:3000`, which is the page being edited and the one place untrusted content actually renders. The comment describes a protection the code does not provide, which is probably why it survived two prior security passes.

The extension cannot simply be given a distinct origin: the content script opens the socket from the page context (`websocket-client.ts:148`), so the browser sends the *page's* origin. Localhost origins must be allowed for the product to work at all as currently built. That coupling is the actual defect.

### Threat model
A dev server frequently renders content the developer did not author — a seeded database, a production dump, user-generated records, a compromised front-end dependency or third-party script. `docs/store-listing.md` already says so in the privacy section. Any script executing on that page can open `ws://127.0.0.1:7890` directly, without the extension being installed or active.

Four distinct actors, in descending order of real-world likelihood:
1. **Script on the dev page.** The main one. No extension needed.
2. **Another installed browser extension.** Any `chrome-extension://` origin passes; the ID is not pinned, although ours is known (`aifpecjojmlgdhgnkmkaobmfipdmppea`).
3. **Another local process or user.** `Origin` is only meaningful when a browser sets it; curl, node or python can send anything. Loopback is not user-isolated, so this matters on shared or lab machines and over forwarded ports. On a single-user laptop a local process can already read the project, so the marginal risk there is small.
4. **A squatter on the port.** The extension scans 7890–7899 and accepts the first peer sending a plausible `SERVER_HELLO`. It connects to `ws://localhost`, which may resolve to `::1`, while the server binds only `127.0.0.1` — so a process on `[::1]:7890` wins and receives every diff. The HACK-008 peer check is shape-only and its own comment admits the peer is spoofable.

### What has already been done, and what it leaves
Commit `fe59ab6` removed most of the *impact* without touching the *access*. A client that reaches the bridge today can no longer write a workflow file, an agent-config file or a `.php` into the project (HACK-011), crash the server (HACK-013), or steer the agent through `sourceFile` (HACK-012).

What reaching the bridge still gets: the full token registry and component registry — including `importPath`, so the project's file layout — returned on `EXTENSION_HELLO`; the ability to inject diffs into the agent's queue as untrusted-but-present work; bounded image/video writes into asset directories; and, by claiming another `tabId`, interception of that tab's `DIFF_APPLIED` pushes. That is information disclosure and nuisance rather than code execution, which is why this was separated from `fe59ab6` rather than rushed alongside it.

### Scope
- `packages/mcp-server/src/bridge.ts` — `isAllowedOrigin`, `handleConnection`, `handleExtensionHello`, and wherever the chosen mechanism is enforced per-message
- `packages/chrome-extension/src/content/websocket-client.ts` — connection establishment and the peer check
- `packages/shared/src/protocol.ts` — `PROTOCOL_VERSION`, and any new message or field
- possibly `packages/chrome-extension/src/popup/` and `service-worker/` depending on the option chosen
- **Estimated size:** large, cross-package

### Approach — two viable options, pick one in the plan phase

**Option A — move the socket into the service worker and pin the extension ID.**
The socket moves out of the page context, so the only legitimate `Origin` becomes `chrome-extension://aifpecjojmlgdhgnkmkaobmfipdmppea` and localhost origins can be dropped from the allowlist entirely.
- Closes actors 1 and 2. Does not close 3 or 4, since `Origin` is still only a header.
- Costs: page↔service-worker message plumbing for everything the content script currently sends directly; MV3 service workers terminate when idle, and while WebSocket traffic resets that timer in current Chrome, a quiet period still risks teardown and reconnection churn.

**Option B — a pairing secret.**
The server mints a secret at startup and prints it; the user enters it once in the popup; every message after the handshake carries it.
- Closes all four actors. It is the only option that does, because it does not rely on a header the peer controls.
- Costs: a protocol change on both sides, a new first-run step, and the product stops being zero-setup — which is currently a selling point in the store listing.

Whichever is chosen, also **bind both loopback families** (or have the extension connect to `127.0.0.1` explicitly rather than `localhost`) so the `::1` squat in actor 4 disappears. That part is cheap and independent.

### Risks & Assumptions
- **Backward compatibility is the crux, exactly as it was for HACK-008.** The extension updates through the Chrome Web Store and the server through `npx @^0`; they move independently, so all four skew combinations must be reasoned through. Under Option A a new server that rejects localhost origins refuses the shipped 0.2.1 extension outright. Under Option B a new server that demands a secret refuses it too. Neither can simply be switched on.
- A grace period keyed on `PROTOCOL_VERSION` is the likely answer: accept the old path, warn, and require the new one after a stated version. That decision belongs in the plan, not here.
- Assumes the extension ID is stable. It is, for the published listing, but unpacked development builds get a different ID — the allowlist needs a development escape hatch that does not become a production hole.

### Constraints
- All traffic is localhost; no remote servers (`boundaries.md`).
- Do not regress HACK-001 (loopback bind + origin allowlist), HACK-008 (identifiers withheld until the peer is confirmed), or `fe59ab6`.
- High-risk: security boundary plus external integration. Expect Reviewer and Security sign-off.
- If Option B is chosen, the store listing and the guide both claim zero-setup and will need rewording.

### Verification
- [ ] A page on `http://localhost:<port>` cannot open a usable bridge connection — test with a plain `new WebSocket()` from the dev page console.
- [ ] Another `chrome-extension://` origin is rejected.
- [ ] Under Option B: a forged `Origin` from curl is rejected.
- [ ] `::1` squatting no longer wins the port scan.
- [ ] All four extension/server skew combinations connect, or fail safely with a clear message, without deadlock.
- [ ] `tabId` cannot be claimed by a second client to intercept another tab's pushes.
- [ ] `tsc --noEmit` and builds clean for `mcp-server`, `chrome-extension` and `shared`; regression tests added for each rejected actor.

### Dependencies
Builds on HACK-001 and HACK-008. Independent of `fe59ab6`, which reduced impact only.

### Spec References
- `docs/spec/compiled/v1/boundaries.md` — "all traffic is localhost"; the no-auth framing needs revisiting here
- `docs/spec/compiled/v1/integrations.md` — MCP connection + `NCO_WEB_EDITOR_PORT`
- `docs/spec/compiled/v1/features/feature-005-mcp-server-bridge.md` — bridge protocol
- `docs/ai/logs/known-issues.md` — KL-4

### Task Contract

```yaml
brief_id: "20261027-013000-bridge-peer-authentication"
goal: "Authenticate the WebSocket peer so that only the real extension can drive the bridge, closing the path from script on the developer's own dev page to the local MCP server."
scope_files:
  - "packages/mcp-server/src/bridge.ts"
  - "packages/chrome-extension/src/content/websocket-client.ts"
  - "packages/shared/src/protocol.ts"
scope_modules:
  - "mcp-server bridge"
  - "chrome-extension websocket client"
  - "shared protocol"
risk: high
requires_signoff:
  - reviewer
  - security
verification:
  - "a script on http://localhost:<port> cannot establish a usable bridge connection"
  - "a chrome-extension:// origin other than the pinned extension is rejected"
  - "::1 squatting cannot win the port scan"
  - "all four extension/server version-skew combinations connect or fail safely without deadlock"
  - "tsc --noEmit and builds clean across mcp-server, chrome-extension and shared"
```
