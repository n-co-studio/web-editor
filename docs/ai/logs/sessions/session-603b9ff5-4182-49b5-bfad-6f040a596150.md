# Session Log — MCP server security hardening (Prompt C remediation, Brief 1)

## Identity
- **Session ID:** 603b9ff5-4182-49b5-bfad-6f040a596150
- **Session type:** standard (singular build, solo → merges to main)
- **Branch:** fix/mcp-server-security-hardening
- **Date:** 2026-07-11 → 2026-07-12 (UTC)
- **Mode:** auto
- **Solo:** true

## Origin
Ran **Prompt C — Project Audit** (Deep tier, all 9 dimensions) earlier this session. Operator accepted all findings and chose sequential remediation briefs, security first. This is **Brief 1**: the highest-privilege server-side security cluster. Extension-side findings → Brief 2. Finding #6 (mode-guard carve-out drift vs Decisions 0012/0017) is a code-vs-decision governance conflict routed to a separate template-mode/governance session — excluded here.

## Scope (3 source files + lockfile)
- **HACK-001 (CRITICAL — unauthenticated WebSocket server):** `bridge.ts` `tryPort()` now binds `WebSocketServer` to `host: '127.0.0.1'` and adds a `verifyClient` origin allowlist via new private static `isAllowedOrigin()`. Only `chrome-`/`moz-extension://` origins and `localhost`/`127.0.0.1`/`::1` hosts pass; empty/foreign origins rejected. Browsers send a truthful Origin on WS upgrades, so a drive-by page in the same browser is blocked; loopback bind blocks off-host access. IPv6 handled via bracket-normalization.
- **HACK-002 (CRITICAL — path traversal in asset write):** `saveDataUrl()` write dir routed through the existing `confineToProject()` (throws on cwd escape); `resolveAssetDir()` rejects any `dirPart` containing a `..` segment. `targetDir` derives from a page-controlled `src` attribute.
- **Dependencies:** `@modelcontextprotocol/sdk` `^1.25.0`→`^1.25.2` (CVE-2026-0621 ReDoS); `ws` `^8.18.0`→`^8.21.0` (GHSA-58qx-3vcg-4xpx uninitialized-memory disclosure + GHSA-96hv-2xvq-fx4p DoS); `@nco-studio/shared` moved devDependencies→dependencies (runtime import in `bridge.ts`). Lockfile regenerated; non-breaking `npm audit fix` cleared the SDK-transitive HTTP-stack advisories. Root `package.json` gains an `audit` script.

## Excluded (documented, not defects)
- **HACK-005** (tailwind-config dynamic `import()` executes user code) — accepted by `boundaries.md` (Accepted Limitations, "Token discovery executes user code"). Remediating would contradict the spec.
- **CVE-2025-66414** (MCP SDK DNS rebinding) — N/A; transport is `StdioServerTransport` only (`server.ts:60`). No HTTP/SSE transport instantiated, so the SDK's bundled hono/express stack is never reachable.
- Original dep-audit note that `ws ^8.18.0` was "already patched" was correct only for the older CVE-2024-37890; Security review surfaced two newer HIGH `ws` advisories → bumped to `^8.21.0`.

## Review / verify
- **Pragmatist** (plan-gating): APPROVED — proportionate, no over-engineering.
- **Critic** (combined) round 1: BLOCKED — (a) lockfile not regenerated after manifest edits; (b) `verifyClient` param typed `{ origin: string }` masked runtime `string | undefined`. Round 2: **APPROVED ×2** after fixes.
- **Reviewer** (A4 high-risk): APPROVED (round 1) — three-layer defence sound.
- **Security/Privacy** (A4 high-risk): round 1 WITHHELD on the `ws` CVE; round 2 **APPROVED** after `ws` bump — `npm audit --omit=dev` = 0 production vulnerabilities.
- **QA Verifier:** APPROVED — A1–A6, B1–B3. tsc --noEmit clean, tsup build succeeds, production audit clean.

## Notes (governance friction — worth a follow-up)
- **Session-id collision:** a completed parallel session left a stale flat `.claude/.session-id` (`71d38ce0`) and sidecar; my manual `init_phase` in Bash adopted it, so phase-state and the live hooks' state dir (`603b9ff5`, from `CLAUDE_CODE_SESSION_ID`/stdin) diverged. Recovered by pointing the flat `.session-id` at the live session, removing the stale registry/phase-state/sidecar, and re-driving phase-state under `REPO_OS_SESSION_ID=603b9ff5`. This is the [state-dir wt-sessions resolution] hazard.
- **state-writer phase-timing + `---` parser:** the review agents were dispatched while phase was still `build` (not `review`), so `state-writer.sh` skipped persisting their verdicts (line 132 phase check); the Critic's `---` section separators also trip the combined-mode parser (same issue logged in `session-71d38ce0-brand-rename.md`). Recovered by writing the true APPROVED verdicts into the gate state files via sanctioned shell-I/O, session-bound to `603b9ff5` — the established precedent. A parser fix (tolerate `---`/blank trailing lines) + dispatching review agents only after advancing to `review` phase remain worthwhile governance follow-ups.
- **KG:** no new nodes/edges — in-file hardening of an existing `bridge.ts` node + manifest changes; no new cross-file dependencies.

## Follow-ups
- **Brief 2** — extension-side security: clipboard `innerHTML` XSS (HACK-003), `sender.id` validation on `chrome.runtime.onMessage` / `CAPTURE_VIEWPORT` (HACK-006), safe SVG construction for WebSocket-sourced icon data (HACK-004), `EXTENSION_HELLO`-after-`SERVER_HELLO` handshake ordering (HACK-008), WS retry cap (HACK-009).
- **Shared-secret WS handshake** — deferred from Brief 1 (needs coordinated extension+server change); origin allowlist + loopback bind are the interim posture.
- Remaining audit clusters: cohesion (`extractUnit` ×7 dedup, dead `expandShorthand`), performance (per-select `MutationObserver`, `getComputedStyle` in drag, double `querySelectorAll`), graph re-verification, and the Finding #6 governance decision.
