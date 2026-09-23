# Session Log — Local Network Access Guidance

**Date:** 2026-09-23
**Branch:** feature/local-network-access-guidance (solo merge to main, seals branch)
**Session id:** 9772a09d-50ca-4b17-bc9f-2fc087fd02bc
**Work:** Explain Chrome's Local Network Access prompt in-product and in the launch docs.
**Mode:** auto (operator approval "Approve — auto")

---

## Summary

The operator hit Chrome's Local Network Access prompt ("… wants to access other devices and apps on your network") when activating the extension on Chrome 153. It fires because the content script opens `ws://localhost:<port>` to reach the MCP server. Chrome shipped the permission in 142 and extended it to WebSockets around 147, so every user and the Chrome Web Store reviewer will see it.

The failure mode mattered: a denied prompt looks exactly like a missing server. `scanPorts` exhausts 7890–7899, `scheduleRetry` backs off, and the Review-changes panel asserted the wrong cause ("check that Claude Code is running").

`WebSocketClient` now records whether an MCP handshake has ever completed in this page session (`everConnected`, set in `confirmHandshake`, exposed as `hasEverConnected`, deliberately never reset). When nothing has ever connected and the panel is not in demo mode, the existing connection warning gains one extra line pointing at the permission and telling the user to allow it in site settings and reload. After a successful connection, a later drop keeps the old wording, since the cause is then the server. Chrome reports a denied local-network permission as an ordinary WebSocket error, so "never connected" is the only signal available — hence a hedged hint rather than an asserted diagnosis.

Docs: a QUICKSTART troubleshooting section; the store listing's reviewer test steps now include the prompt and say to click Allow (with a matching architecture note explaining that the WebSocket targets loopback); a symptom/cause/fix entry in the demo guide's Troubleshooting tab; a CHANGELOG 0.2.0 line.

## Deferred

Chrome 154 adds a `targetAddressSpace` option on the WebSocket constructor for declaring a loopback target. It cannot be tested on Chrome 153, so no code was written for it. Worth adopting behind a feature check once 154 is available.

## Verification

- typecheck clean; all workspaces build; chrome-extension tests 134/134; smoke 15/15; publish-dry-run 13/13
- Store zip rebuilds and verifies; the new hint string is present in both `dist/content.js` and the zipped `content.js`
- Diff confined to the flag plus the conditional hint: `retryNow()` byte-identical, scanning/retry/handshake paths untouched
- Pragmatist APPROVED (0 findings; judged the "never connected" heuristic proportionate and documentation-only insufficient, since the panel actively misdiagnosed). Critic combined APPROVED/APPROVED with three recommendations, all applied: the hint now says to reload, a JSDoc comment my insertion had displaced was restored above `retryNow()`, and the Troubleshooting module's "all trace back to one rule" framing was softened. QA APPROVED (A1–A6, B1–B3).
