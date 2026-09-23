# Session Log — Product Rename

**Date:** 2026-09-23
**Branch:** feature/product-rename (solo merge to main, seals branch)
**Session id:** 9772a09d-50ca-4b17-bc9f-2fc087fd02bc
**Work:** Rename the product to "Visual Web Editor for AI Agents" and reframe user-facing copy designer-first.
**Mode:** auto (operator approval "Approve — auto")

---

## Summary

A Chrome Web Store search showed a crowded field of generic "Web Editor" extensions and none positioned for AI work. Since v0.2.0 is built but unpublished on both npm and the store, the rename costs nothing now and would be expensive later (the store name is what search matches).

Operator decisions: the store name carries no brand — "Visual Web Editor for AI Agents" (31 chars) — with n'co studio remaining the publisher, and the copy speaks to designers who direct AI coding agents rather than to "operators". The manifest description is now "Design on the real page — adjust any element visually and your AI coding agent applies the change in your source files." (119 chars, limit 132).

Renamed: manifest name/description/default_title; popup title and header; the unavailable-page hint; the protocol-mismatch banner heading; the diff prompt header; shadow-host and service-worker comments; store listing (name, publisher, short and detailed description, reviewer notes); README, QUICKSTART, COMPATIBILITY, SECURITY, privacy policy, CHANGELOG, both package READMEs and descriptions, the demo app's title, byline and token comment; and the compiled spec (product, architecture, boundaries, integrations, design-system, feature-001, feature-006).

Deliberately unchanged: npm package names (`@nco-studio/web-editor-mcp`, `@nco-studio/web-editor-plugin`), the CLI binary `nco-web-editor-mcp`, the MCP key `nco-web-editor`, `NCO_WEB_EDITOR_PORT`, DOM ids and data attributes, `GUIDE_URL`, the store zip filename, log prefixes, and the historical files. Those are machine-facing and namespaced to the publisher, so the Pragmatist judged the split proportionate rather than confusing. Status-icon tooltips keep the short "Web Editor — connected" form for length.

The store listing's detailed description was rewritten to lead with the designer story (design on the page; the agent writes the code; edits snap to your existing tokens) and now says "an AI coding agent that speaks MCP (built and tested with Claude Code)" rather than implying agent-agnosticism that hasn't been tested. The guide page's hero and steps were left alone — the operator is writing that copy.

## Verification

- typecheck clean; all workspaces build; chrome-extension tests 134/134; smoke 15/15; publish-dry-run 13/13
- Store zip rebuilt: manifest name 31 chars, description 119 chars
- Grep: no user-facing file still calls the product "n'co studio Web Editor"; every preserved identifier (`nco-web-editor-mcp`, `nco-web-editor`, `@nco-studio/`, `NCO_WEB_EDITOR_PORT`, `data-nco-web-editor`, `nco-web-editor-overlay`) intact
- Pragmatist APPROVED (0 findings; confirmed the naming split is proportionate). Critic combined APPROVED/APPROVED with 4 consistency recommendations, all applied: a stale " - Repo OS" suffix in product.md and integrations.md, a project-structure directory label, and the README's "Operators" positioning line. QA APPROVED (A1–A6, B1–B3).

## Notes

- Chrome shows ERR_FILE_NOT_FOUND for an unpacked extension whose folder is gone; the automation's worktrees are deleted when work completes, so reload from `packages/chrome-extension/dist`.
- Adobe Fonts no longer uses a domain allowlist (their Domains help page: web projects need no domain list), so the earlier launch-checklist item about registering nco.studio was wrong and is dropped.
