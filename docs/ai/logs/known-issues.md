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

### KL-2 — Root `tsc --noEmit` type-checks nothing outside `packages/shared` (hollow A3.3 signal)
- **File:** `tsconfig.json` (repo root)
- **Symptom:** The root config has `"files": []` and `references: [{ "path": "packages/shared" }]`, so `npx tsc --noEmit` at the repo root exits 0 **unconditionally** regardless of the state of `packages/chrome-extension`, `packages/mcp-server`, or `packages/dev-plugin`. It reports success on code containing hard type errors.
- **Discovered:** Session `notes-multi-attach-20260816`. A dangling `this.anchoredElementRef` reference (TS2339, a field deleted earlier in the same diff) survived a root `npx tsc --noEmit` that exited 0; it was caught by the Critic, not by the build. Empirically confirmed both ways: with the offending line reinstated, `cd packages/chrome-extension && npm run typecheck` exits 2; with it removed, exits 0. The root command exits 0 in both cases.
- **Impact on gates:** Gate A3.3 (`tsc --noEmit --incremental`) is specified against the repo root. If the hook runs it from the root, A3.3 provides **no** type safety for any product package — the gate passes vacuously. This is a silent-false-negative class of gate failure, not a crash.
- **Workaround:** Type-check per package: `cd packages/<pkg> && npm run typecheck`. (`npx tsc --build` at root also traverses references correctly.) Note the root `package.json` likewise has no `test` script — tests are per-package.
- **Scope:** Fixing this means either adding the remaining packages to the root `references` array (and making them composite projects) or changing gate A3.3 to iterate packages. Both are outside a UI-behaviour brief.
- **Follow-up:** Open a dedicated brief to make root typecheck cover all packages and to align gate A3.3 with it.
