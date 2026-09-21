# Session Log — v0.2.0 Store Release Prep

**Date:** 2026-09-21
**Branch:** feature/store-release-prep (solo merge to main, seals branch)
**Session id:** 9772a09d-50ca-4b17-bc9f-2fc087fd02bc (flat `.session-id` carried over from an earlier window; harness session a0fc7f01-d693-4d21-8929-6d67170ec4a6)
**Work:** Make the Chrome extension and the two npm packages submittable as the first public release, v0.2.0.
**Mode:** auto (operator approval "Approve — auto")

---

## Summary

Operator asked for a due-diligence pass on Chrome Web Store publishing, picking up the June 17–18 `nco-studio-launch` operator guide. State found: nothing published; the `@nco-studio` npm org exists; the June prepublish GO report predates three months of feature work; dist stale; no store zip. Operator since moved the repo to `github.com/n-co-studio/web-editor` (private for now), registered the Chrome developer account, and logged in to npm (`lordmark`). Decisions: version 0.2.0 everywhere; privacy policy at `https://nco.studio/web-editor/privacy` (site to be built separately).

Defects fixed:

- **Store hard blocker:** manifest `description` was 216 chars (limit 132) → 130.
- **Install breaker (regression):** `@nco-studio/shared` was back in mcp-server `dependencies`; registry installs 404 because shared is never published. Moved to `devDependencies` (tsup `noExternal` inlines it). The smoke test caught this — E404 before, 15/15 after. The June Brief 6 fix had been undone by a later commit.
- **Unresolvable pin:** `@nco-studio/web-editor-mcp@^1` in CLI help, mcp-server README, demo-app SetupGuide → `@^0`.
- **Wrong config file:** user docs and CLI help said `.claude/settings.json`; Claude Code reads project MCP servers from `.mcp.json`. Compiled spec (product, integrations, feature-005) updated to match (PM advisory CRITICAL).
- **Wrong ports:** store-listing reviewer notes said 3700–3710 and QUICKSTART said 3742 with a nonexistent `-p` flag; actual is 7890–7899, and the extension only scans that range.
- **Dead URLs:** everything pointed at `github.com/nco-studio/web-editor` (no such org) → `n-co-studio`; privacy URL was a 404 GitHub Pages URL.
- Versions 0.2.0 across all packages + MCP server info; CHANGELOG 0.2.0; COMPATIBILITY, SECURITY supported-versions (`1.x` → `0.x`), RELEASING (first npm publish must be manual — Trusted Publisher needs an existing package; no `--provenance` locally; first tag's workflow publish fails harmlessly); QUICKSTART zip filename; store-listing Node 20+, support URLs, `captureVisibleTab` justification; `.gitignore` `dist-zip/`.

## Verification

- typecheck clean (all workspaces); build all workspaces; chrome-extension tests 87/87; mcp-server 5/5
- `scripts/smoke-test.mjs` 15/15; `scripts/publish-dry-run.mjs` 13/13
- `package-extension.mjs` → `packages/chrome-extension/dist-zip/nco-studio-web-editor-0.2.0.zip` (20 files, no `.map`, no `web-embed.js`, manifest 0.2.0, description 130 chars)
- Pragmatist plan-gating: APPROVED (0 findings)
- Critic combined: cohesion BLOCKED (COMPATIBILITY `@^1` wording, SECURITY `1.x`) → BLOCKED (QUICKSTART port 3742) → APPROVED ×3; diff-review APPROVED throughout. The final recommendation (unpinned snippet in feature-005 spec) was applied after the recorded approval — a one-token `@^0` addition.
- PM advisory: spec drift on `.mcp.json` (applied), Node version mismatch (applied), support URL (applied); `mvp-scope.yaml` idea deferred.
- QA verifier: APPROVED (A1–A5, B1–B3; A6 n/a). A2 advisory: 23 files / +135 lines under `large-scope: false` — uniform docs/metadata change.
- UX Design Agent not dispatched: the only UI-file change is a version-pin string inside a code sample in `SetupGuide.tsx`.

## Governance

- `state-writer.sh` discarded 5 of 9 governance verdicts (`no_sentinel`): subagents deliver their report via SubagentHandback, then close with a short "Report delivered." line, which is what `last_assistant_message` carries. Captures succeeded only when the agent's closing message repeated the full report. Resolved without forging: the final Critic and QA dispatches were told to make their closing message, after the hand-back, a verbatim copy of the report ending in `GATE_RESULT`. Both captured. Each discarded verdict left a `verdict-rejected-*` escalation in `.claude/.automation/escalations/` (unresolved).
- drift-check fell through to the legacy plan path (no brief_id; operator-conversation task).

## Deferred / operator actions

- Store icons (`assets/icons/icon-16/48/128.png`) are a flat cyan placeholder. Operator chose to generate them from the brand mark in `/icon` as a separate follow-up change.
- Privacy page at `https://nco.studio/web-editor/privacy` (content: `docs/privacy-policy.md`) — operator building the site.
- Make the repo public before npm publish (provenance, listing homepage/support links); then manual `npm publish --access public` for both packages; screenshots + promo tile; store upload.
