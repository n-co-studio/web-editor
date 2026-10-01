# Session Log — Editing on Any Site Restored

**Date:** 2026-09-27
**Branch:** fix/allow-any-site (solo merge to main, seals branch)
**Session id:** a0fc7f01-d693-4d21-8929-6d67170ec4a6
**Work:** Revert the localhost-only gate, and rewrite the claims that caused it.
**Mode:** auto

---

## What this reverses, and why it was wrong

Commit `a2ff026` — `fix(security): enforce localhost-only activation in code` — found that the store listing and privacy policy claimed the extension "never runs on public websites" while the popup would inject anywhere, and resolved the contradiction by narrowing the code to match the claims.

That was the wrong resolution, and the operator was right to push back. Editing a site you are not synced to is a capability the product has on purpose. The copy was mine; I let my own documentation overrule a deliberate feature, without asking which of the two was wrong. Labelling it `fix(security)` made a product decision look like a safety fix and therefore unarguable.

It was also wrong on the merits. `activeTab` exists precisely for "the user invoked this tool on this tab" and is granted on the click that opens the popup. Click-to-run on any site never needed a new permission, so the gate protected nothing.

## The shape now

- **Automatic injection stays narrow.** `content_scripts.matches` is untouched: localhost and `127.0.0.1` only. Nothing loads into a site you are merely browsing, and no `host_permissions` are requested. The manifest is byte-identical — verified by an empty `git diff` on it, because the whole permission story rests on that.
- **Click-to-run works anywhere.** `isInjectableUrl()` (new, tested) refuses only what Chrome itself refuses: `chrome:`, `chrome-extension:`, `devtools:`, `about:`, `view-source:`, `file:`, `data:`, `blob:`, other browsers' schemes, and the extension galleries. The popup's message changed from "open a localhost dev page" to "Chrome does not allow extensions to run on this page", which is the true reason.
- **`activate()` no longer checks the page.** The content script arrives either by manifest match or by user-invoked injection; both are already the user's decision.
- **`is-local-host.ts` survives, demoted from gate to hint.** It decides whether the popup tells you source-mapped sync is unavailable.

Verified in a browser against the built popup with `chrome.*` stubbed: localhost and public sites both enable the buttons with the right hint; `chrome://extensions` and the Web Store disable them with the Chrome-blocked message.

## The documentation, which was the bulk of the work

The Critic blocked this **five times**, and every block was a real finding. The pattern is worth recording: each round I corrected the claims I knew about, and it found another thing that genuinely crosses the wire.

1. Stale claims in `docs/privacy-policy.md`, and in the store listing's **reviewer notes** and **`activeTab` permission justification** — the two places a store reviewer reads verbatim.
2. `docs/spec/compiled/v1/architecture.md`, the root `frontend-editor-repo-os-spec.md`, and — most importantly — `SetupGuide.tsx`, the hosted onboarding page the privacy policy itself points users at.
3. `SECURITY.md` and `README.md` still carried an unqualified "No data leaves your machine" beside sections describing the new behaviour.
4. My replacement copy was itself inaccurate: it said only the edited element's markup and text travel, omitting `PageContext.url` — the full page URL, ids and tokens included — which accompanies every diff.
5. Then operator notes (free text, verbatim), then CSS rule provenance including rules for breakpoints you are not viewing, sibling and container elements, component names and import paths.

## The structural lesson

After the fifth block I stopped adding bullets and changed the frame. A hand-maintained prose enumeration of a growing type will keep going stale — five rounds is the proof. The section now gives a substantial summary, commits to keeping it in sync, and names the `VisualDiff` type in `packages/shared/src/diff.ts` as the binding definition, linked.

A privacy policy pointing at source is unusual. I judged it more honest than re-asserting a completeness the document has repeatedly failed to hold, and both the Critic and Security agreed on review. It is the operator's call and trivial to change.

## The disclosure that did not exist before

Security's advisory, and the reason the doc work mattered: before this change, the only page content that could reach the MCP server — and from there an agent's model provider — came from the developer's own dev server. Now the user chooses the page, and it may be one they are logged into. The extension's own network behaviour is unchanged (localhost WebSocket only, handshake-gated, screenshots never leave the browser), but the trust boundary moved, and no document said so.

`docs/privacy-policy.md` now has a "What your agent sees" section naming what each edit carries, and stating plainly that Claude Code is a local program whose model calls go to Anthropic. `SECURITY.md`, `README.md`, the store listing, the hosted guide and the MCP server's README all scope their "stays local" language to the extension and server's own traffic and point onward to the agent boundary.

## Verification

- `tsc --noEmit` clean; 160/160 tests (153 + 7 new for `isInjectableUrl`); all four extension bundles and the demo app build.
- `git diff -- packages/chrome-extension/manifest.json` empty; `permissions` is exactly `["activeTab","storage","scripting"]`, no `host_permissions`.
- Gates: Pragmatist APPROVED; Critic combined APPROVED after five substantive BLOCKs; QA APPROVED; Security APPROVED.

## Note for the operator

The scope advisory is real and expected: 16 files, because one behaviour change required correcting claims in many documents. That fan-out is itself the finding — the claims had spread further than the code.
