# Session Log — Guide Setup Steps

**Date:** 2026-09-24
**Branch:** feature/guide-setup-steps (solo merge to main, seals branch)
**Session id:** a0fc7f01-d693-4d21-8929-6d67170ec4a6
**Work:** Store link, step-1 image placeholder, agent selector with a copyable MCP prompt, and two correctness fixes.
**Mode:** auto

---

## Summary

1. **Store link.** "Install from the Chrome Web Store" is now an anchor using the existing `.nco-link` treatment. The URL lives in one constant, `CHROME_STORE_URL`. See the open issue below.
2. **Image placeholder, step 1 only** (the operator narrowed this mid-task). A dashed box at `aspect-ratio: 1280/800` — the Chrome Web Store screenshot size, so one capture serves both the listing and this page. Deliberately dashed so it reads as a gap rather than as a design element. Inlined rather than extracted to a component, per a Pragmatist finding: a single call site does not earn an abstraction.
3. **Step 2 rebuilt** as a stateful `ConnectYourAgent`. A four-option radiogroup (Claude Code / Cursor / Windsurf / Any MCP client) drives both the config path named in the prose and a generated agent prompt, with a Copy button. The underline-tab styling matches `GuideTabs`, the guide's own tab strip.

## Two correctness fixes found while reading

- **Step 3 never said to install the plugin.** It showed `import { ncoWebEditor } from '@nco-studio/web-editor-plugin'` with no `npm install`, so anyone following the hosted guide would hit module-not-found. `README.md:64` and `QUICKSTART.md:41` both had the install line; only the guide was missing it.
- **Step 2 never said where the MCP server comes from.** Added: nothing to install first, because `npx` fetches it on the agent's first launch and reuses the cached copy. This was the operator's own question — the guide could not answer it.

## Review findings acted on

The Pragmatist approved with two over-engineering findings. I took the second (inlined the placeholder) and declined the first (replacing the selector with four static copy buttons): the alternative hides the prompt text until it is pasted, and `GuideTabs.tsx` already establishes this exact stateful underline-tab pattern in the app.

The Critic approved with four recommendations; three are fixed:

- **Radiogroup keyboard support.** `role="radio"` tells assistive tech that arrow keys move the selection, and nothing implemented them — all four options also sat in the Tab order, which a real radiogroup does not do. Now: arrow keys move selection and focus with wrapping, and `tabIndex` roves so the group is a single Tab stop. Verified over CDP with dispatched key events, not by reading the code: selection, focus and tabindex all follow, and it wraps at both ends. Note the same gap still exists in `GuideTabs.tsx` for its `role="tab"` buttons — not touched here, but it is real.
- **Windsurf's config is global.** `~/.codeium/windsurf/mcp_config.json` sits outside the project and applies to every workspace, and sandboxed agents often cannot write to `$HOME` without asking. The generated prompt now says so, so the disclosure reaches the agent rather than only the reader.
- **Timer leak.** The Copy button's 2-second reset is now held in a ref and cleared on re-copy and on unmount — `GuideTabs` unmounts this step on a tab switch, so the timer could fire against a dead component.

## Open issue for the operator

`CHROME_STORE_URL` points at a Chrome Web Store **search**, because the extension is not published and no item URL exists. The link text promises an install. Until submission, a visitor who clicks it lands on a search that will not find the extension. It is one line to change, and it is the only place the store is linked from — but the page is live now, so the promise is ahead of the product.

## Verification

- `tsc --noEmit && vite build` clean; chrome-extension untouched and still 153/153.
- Live CDP checks: store link href and text; exactly one `<figure>`; `aria-checked` moving across all four options; the prompt's named file changing from `.mcp.json` to `~/.codeium/windsurf/mcp_config.json` on selection; both new lines present in rendered text.
- Arrow-key navigation exercised with real `Input.dispatchKeyEvent` calls.
- Gates: Pragmatist APPROVED, Critic combined APPROVED on re-review (3/3 fixes verified), QA APPROVED.

## Note for the operator

Repo-side only. nco.studio/web-editor/ still shows the previous page until `npm run deploy:site` runs and the site repo is committed and pushed.
