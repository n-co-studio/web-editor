# Session Log — Step 2 Reorder

**Date:** 2026-09-24
**Branch:** feature/guide-step2-order (solo merge to main, seals branch)
**Session id:** a0fc7f01-d693-4d21-8929-6d67170ec4a6
**Work:** Put the copy-prompt route first in step 2, with the button above the prompt block.
**Mode:** auto

---

## Summary

Step 2 now reads: intro and agent selector → "Easiest way — let {agent} set itself up. Copy this and paste it in:" → **Copy prompt** button → the prompt block → "Or add it yourself, to {configPath}:" → the MCP JSON block → the npx note.

The hand-edit route is demoted, not removed: it sits directly below, so a reader whose agent cannot write files, or who would rather not have an agent editing config, loses nothing but a little scrolling.

Two sentences were reworded because the old ones encoded the old order. The prompt was introduced with "Or let {agent} do it", which reads as an afterthought when it comes first. The npx note said "There is nothing to install first" while sitting under the manual route only; it now says "Either way", because it follows both.

## Review findings acted on

Both reviewers caught the same class of problem — text that points at a position rather than naming a thing.

- **Pragmatist:** the clipboard-failure message read "Copy failed — select the text above". Moving the button above the block made "above" point at the lead paragraph instead of the prompt. Now: "select the prompt text and copy it manually".
- **Critic:** the comment I wrote alongside that fix said "Position-independent: this button sits above the prompt block" — asserting position-independence while hardcoding the position, which would go stale on the next reorder exactly as the old string did. The comment now explains the principle (name the thing, do not point at it) and records what it used to say.

The Critic also noted that "Either way" relies on the reader having retained that there were two routes, with no textual anchor back to them. Left as-is: the two routes are adjacent and short, and a phrase like "whichever you used" reads heavier than the sentence needs.

## Verification

- `tsc --noEmit && vite build` clean; chrome-extension untouched and still 153/153.
- Live CDP read of step 2's DOM order returns exactly the sequence above — the order was confirmed in the rendered page, not inferred from the JSX.
- `grep` confirms "select the text above" is gone from `examples/demo-app/src`.
- Gates: Pragmatist APPROVED, Critic combined APPROVED, QA APPROVED.

## Note for the operator

Repo-side only. nco.studio/web-editor/ still shows the previous page until `npm run deploy:site` runs and the site repo is committed and pushed.
