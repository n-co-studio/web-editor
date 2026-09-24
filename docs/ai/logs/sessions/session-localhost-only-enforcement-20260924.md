# Session Log — Localhost-Only Enforcement

**Date:** 2026-09-24
**Branch:** fix/localhost-only-enforcement (solo merge to main, seals branch)
**Session id:** 9772a09d-50ca-4b17-bc9f-2fc087fd02bc
**Work:** Make the extension's documented localhost-only behaviour true in code.
**Mode:** auto (operator approval "Approve — auto")

---

## Summary

A Critic pass on the setup-guide copy found that the extension only *claimed* to be localhost-only. The manifest's `content_scripts.matches` covered automatic injection, but `popup.ts`'s `sendToTab` caught a failed `chrome.tabs.sendMessage` and called `chrome.scripting.executeScript({ files: ['content.js'] })` on whatever tab was active, with no hostname check in the popup or in `content/index.ts`. `renderUnavailable()` only fired when injection or messaging threw, i.e. `chrome://`-class pages. Opening the popup on any public site therefore injected and ran the editor — contradicting three shipped claims:

- `docs/privacy-policy.md`: "It does not run on public websites."
- `docs/store-listing.md`: "The extension activates only on `localhost` and `127.0.0.1` pages."
- The `scripting` permission justification: "the extension does not inject scripts … into non-localhost pages."

Since these are privacy claims on a store listing, the product was changed to match them rather than the claims softened.

`packages/chrome-extension/src/shared/is-local-host.ts` is a new pure module: `isLocalDevHost(hostname)` accepts `localhost`, `*.localhost` (RFC 6761 reserves the TLD), `127.0.0.1` and IPv6 loopback in bracketed or bare form, case-insensitively and tolerating a trailing FQDN dot; `isLocalDevUrl(url)` adds an http/https scheme check. It matches the *name*, not the resolved address, so a public host that happens to resolve to loopback is still rejected. Look-alikes (`localhost.evil.com`, `notlocalhost`, `my-localhost.com`) and LAN addresses are rejected, with tests for each.

Two enforcement points, because the claims are two: the popup now resolves the active tab and refuses to message or inject unless its URL is local (backing "does not inject into non-localhost pages"), and `activate()` refuses on a non-local page via `isSupportedPage()` (backing "does not run on public websites") so the guarantee survives any future injection path. The web-embed bundle is the deliberate exception — it runs on the public marketing site by design, where demo mode already shims `chrome.*` and disables MCP submission, so `isSupportedPage()` returns true when `isDemoMode()` does. The ordering is safe: `web-embed.ts` imports `demo-bootstrap` before `index`, and the check runs when `activate()` is called.

Also fixed: `examples/demo-app/src/components/HowToUse.tsx` still described the pre-popup one-click activation; it now matches the popup toggle. CHANGELOG 0.2.0 records the enforcement.

## Verification

- 140/140 chrome-extension tests (6 new); typecheck clean; all workspaces build; store zip verifies; smoke 15/15; publish-dry-run 13/13
- The guard string is present in both `dist/content.js` and `dist/web-embed.js`
- `getActiveTabId` has no remaining callers; every `sendToTab` call site takes its id from `getLocalDevTabId()` with a null guard, so `executeScript` is unreachable for a non-local tab
- `git diff packages/chrome-extension/manifest.json` is empty — no permission or match-pattern drift
- Pragmatist APPROVED (0 findings; confirmed both guards are warranted, one per claim, and that the demo-mode seam already exists). Critic combined APPROVED/APPROVED, COMPLETENESS 3/3, with two recommendations: trailing-dot hostnames (fixed, with a test) and a manifest/predicate asymmetry (see below). QA APPROVED (A1–A6, B1–B3).

## Noted, not changed

The manifest's `content_scripts.matches` omits `https://127.0.0.1/*` while `isLocalDevUrl` accepts it. The asymmetry predates this work and is fail-safe: automatic injection stays narrower than the popup's guarded path. Widening the matches would change the declared host access on a listing that is about to be submitted, so it is left for the operator to decide after launch.
