# Session Log — Guide Deploy Command

**Date:** 2026-09-22
**Branch:** feature/deploy-guide-script (solo merge to main, seals branch)
**Session id:** 9772a09d-50ca-4b17-bc9f-2fc087fd02bc
**Work:** One command to publish the guide page to the nco.studio site repo.
**Mode:** auto (operator approval "Approve — auto")

---

## Summary

The guide (`examples/demo-app`) is now the product homepage at https://nco.studio/web-editor/. The site is a hand-written static repo at `~/Developer/nco-studio-site` (DigitalOcean App Platform, auto-deploys on push to main) that already carries `web-editor/privacy/`. Until now the publish step was a manual `cp` of the build output.

`scripts/deploy-guide.mjs` (root script `npm run deploy:site`) runs `build:site` (base `/web-editor/`) and syncs the build output into `<site>/web-editor/`. It mirrors the existing `packages/chrome-extension/scripts/copy-web-embed.mjs` pattern: a hardcoded operator path with an env override (`NCO_SITE_DIR`), clear failures when the site dir or build output is missing, and no git commands in the site repo — committing and pushing stays the operator's decision, since a push deploys.

Two Critic rounds shaped it. The first BLOCKED on RELEASING.md ordering (the guide-publish step sat after the store upload while its own text required the reverse) and flagged a hardcoded three-file list that would silently drift from `examples/demo-app/public/`. The loop now iterates the build output itself with a `PROTECTED = ['privacy']` guard, so a new public file ships without touching the script, and `privacy/` can never be written or pruned. An empty-but-set `NCO_SITE_DIR` previously resolved to the current directory; it now falls back to the default path. The second round approved both briefs with two doc-drift notes (the file header and the RELEASING wording still described the fixed three-file list), both fixed.

## Verification

- Isolated run against a throwaway `NCO_SITE_DIR`: a `PRIVACY-SENTINEL` under `web-editor/privacy/` survived; `index.html`, `assets/`, `favicon.svg` landed; a stale `assets/old-DEADBEEF.js` was pruned; a temporary `examples/demo-app/public/robots.txt` synced through automatically (then removed).
- `NCO_SITE_DIR=""` from another working directory uses the default path, not the cwd.
- The real site repo's `git status` was byte-for-byte unchanged across every test.
- typecheck clean; all workspaces build; chrome-extension tests 134/134; `node --check` on the script; `npm audit --audit-level=high` exit 0.
- Pragmatist APPROVED (0 findings). Critic combined: BLOCKED → APPROVED. QA APPROVED (A1–A6, B1–B3).

## Notes

- The operator's site repo has unrelated uncommitted work (landing page, 404, favicon, privacy edits). Untouched by this session.
- RELEASING.md now orders the guide publish before the store upload, because the extension opens the guide on first install.
