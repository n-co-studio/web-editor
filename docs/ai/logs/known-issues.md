# Known Issues

Structured index of resolved debugging issues. Populated by the HVST Record step after 2+ failed cycles.

Checked automatically when HVST failures reach threshold. Do not delete entries — they prevent repeat debugging.

| Symptom | Root Cause | Fix | Session |
|---------|-----------|-----|---------|

## Known Limitations

Deferred findings from review phases that are out of the current brief's scope and need a follow-up brief.

### KL-1 — `buildPageContext` strips unit from breakpoint token values and unconditionally appends `px`
- **File:** `packages/chrome-extension/src/content/batching/diff-builder.ts` (method `buildPageContext`, lines ~250–270)
- **Symptom:** Projects defining breakpoint tokens in `em` or `rem` (e.g. `48em`, `60rem`) produce a wrong `PageContext.breakpointValue` (e.g. `"48px"` instead of `"48em"`). The matching comparison `window.innerWidth >= bp.value` also fails because `parseFloat('48em') = 48` and `window.innerWidth` is in CSS px — the largest breakpoint always matches.
- **Discovered:** Session 149 diff-review (Brief 2 of breakpoint-awareness). Code is pre-existing on `main` (commit `dfd7a68 feat(diff): carry owning-rule provenance through to MCP`) and is not modified by this brief.
- **Scope:** A correct fix requires unit-aware breakpoint matching (`em`/`rem` → CSS px conversion using the document root font-size). Out of scope for the breakpoint-awareness task group.
- **Follow-up:** Open a dedicated brief for unit-aware breakpoint resolution in `buildPageContext`.
