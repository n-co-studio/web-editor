# Session Log — Setup Guide First Step

**Date:** 2026-09-24
**Branch:** feature/setup-guide-first-step (solo merge to main, seals branch)
**Session id:** 9772a09d-50ca-4b17-bc9f-2fc087fd02bc
**Work:** Make pinning and switching on the first thing the hosted setup guide teaches.
**Mode:** auto (operator approval "Approve — auto")

---

## Summary

The demo app is the hosted guide at nco.studio/web-editor — the first thing a store installer reads — but it never mentioned pinning the toolbar icon, even though that icon is the only way to switch the editor on, and Chrome hides a freshly installed extension behind the puzzle-piece menu. Its activation step was also stale, predating the popup toggle.

Step 1 is now "Install and pin the extension" (store install, pin via the puzzle-piece menu, the icon is the switch, built for localhost/127.0.0.1 dev servers; the unpacked instructions stay for people working on the extension itself). Step 4 is now "Switch it on" (open your dev server, click the pinned icon, click **Extension** in the popup to toggle **On**, allow Chrome's local-network prompt, plus the existing version-mismatch banner note). Steps 2, 3 and 5 are untouched.

Full activation cannot literally be step 1, since it needs a running dev server; the operator chose to pin in step 1 and switch on in step 4.

## Finding raised to the operator (separate work)

The Critic blocked the first pass on a copy line asserting that the extension only runs on localhost. Verified against the code: it does not enforce that. `popup.ts`'s `sendToTab` catches a failed `chrome.tabs.sendMessage` and calls `chrome.scripting.executeScript({ files: ['content.js'] })` on whatever tab is active, and neither `popup.ts` nor `content/index.ts` checks the hostname. `renderUnavailable()` only fires when injection or messaging throws, which is `chrome://`-class pages. So on an ordinary public site, opening the popup injects and runs the editor.

Three shipped claims are therefore untrue today, independent of this diff:
- `docs/privacy-policy.md`: "It does not run on public websites."
- `docs/store-listing.md`: "The extension activates only on `localhost` and `127.0.0.1` pages."
- The `scripting` permission justification: "the extension does not inject scripts ... into non-localhost pages."

This diff's copy was revised to state scope and rationale rather than enforcement. The fix (a hostname guard in the popup and a self-guard in the content script, so the product matches the claims) is the operator's call and is out of scope here. Also carried to that work: `examples/demo-app/src/components/HowToUse.tsx` still describes the pre-popup one-click activation flow.

## Verification

- typecheck clean across workspaces; demo app builds; chrome-extension tests 134/134 (informational — untouched)
- `git diff --stat`: one file, 23 insertions / 7 deletions
- Every UI label the copy names ("Extension", "Open Change Queue", "Review changes", "Apply Changes") confirmed verbatim in packages/chrome-extension/src
- Pragmatist APPROVED (0 findings). Critic combined: BLOCKED on the enforcement claim → APPROVED after the revision. QA APPROVED (A1–A6, B1–B3).
