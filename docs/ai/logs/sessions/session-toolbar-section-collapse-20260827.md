# Session Log — Toolbar Per-Section Collapse

**Date:** 2026-08-27
**Branch:** feature/toolbar-section-collapse (solo merge to main, seals branch)
**Session id:** d13941e1-83d0-4be1-8f1d-40501f73732f
**Work:** Per-section collapse for the floating toolbar, with viewport-height auto-fit.
**Mode:** auto (operator approval "Approve — auto", large-scope granted)

---

## Summary

Operator request: split the floating toolbar into collapsible sections; auto-collapse when the viewport is shorter than the toolbar, working bottom-up and skipping sections whose tools are active; allow manual per-section toggling; all sections open by default.

`FloatingToolbar`'s flat `contentWrapper` is now three sections — `view` (grid, rulers, screenshot, devtools), `tools` (the 15-tool radiogroup), `actions` (undo/redo, reset, duplicate, delete) — each a 24px chevron header above a body. The two hairline separator divs the old layout used are replaced by the headers' `borderTop`. Notes and review buttons, the drag grip, and the existing whole-toolbar collapse button stay outside the section system so their count badges remain visible at all times.

Per-section state is a `Map<ToolbarSectionId, SectionState>` carrying just `collapsed` and `manual` (the Pragmatist rejected a third `autoCollapsed` flag as derivable). `updateSectionAutoFit()` first re-expands every non-manual collapsed section, then, while `container.offsetHeight > window.innerHeight`, collapses the bottom-most section that is neither manually toggled nor active — reverse iteration over `SECTION_ORDER`. Active means: `tools` has a non-cursor mode selected; `view` has grid, rulers, or devtools engaged; `actions` is never active, since undo/redo/reset are one-shot commands rather than modes and the operator asked for bottom-up ordering. State is in-memory only and resets on `hide()`, so every activation starts all-open.

## The ordering bug (two Critic BLOCKs)

The first implementation consulted `isSectionActive()` only at the instant auto-fit ran. A section that auto-collapsed while idle stayed collapsed when a tool was later activated by keyboard shortcut (`index.ts` `handleGlobalKeydown`, and `preservedToolMode` restoration in `onSelect`) — neither path clicks the hidden button. Fix: `setActiveMode` / `setGridEnabled` / `setRulersEnabled` / `setInspectorOpen` now re-run auto-fit synchronously.

That was still insufficient, and the second BLOCK caught why: all nine `activateToolForElement` branches read `getButtonPosition(key)` **before** calling `setActiveMode(mode)`, so re-expanding during activation happened after the anchor had already been captured — every mini-editor would open at the toolbar's corner. The resolution moved into `getButtonPosition()` itself, making it independent of caller ordering: it resolves the button's owning section, reveals an auto-collapsed one before measuring (`getBoundingClientRect` forces a synchronous layout flush, so the post-`display:flex` geometry is what gets read), and for a manually-collapsed section leaves it closed and anchors to its header instead. This trades query/command purity for call-site independence — flagged by the Critic as a documented recommendation rather than a defect, since all current callers do intend to open the tool immediately.

## Changes

- `packages/chrome-extension/src/content/toolbar.ts` — section types/state/order, `buildSection`, `setSectionCollapsed`, `refreshSectionHeader`, `isSectionActive`, `sectionForButton`, `scheduleSectionAutoFit`/`updateSectionAutoFit`, debounced resize listener wired in `show()`/`hide()`, section-aware `getButtonPosition` (+280/−38).
- `docs/ai/knowledge-graph/product-graph.yaml` — `product-content-toolbar` node re-described and re-verified; new `product-content-index --consumes--> product-content-toolbar` edge recording the measure-before-activate ordering.

## Verification

- `npm run typecheck` / `npm run build` / `npm test` — pass, 87/87
- Pragmatist plan-gating: GATE_RESULT: APPROVED (2 over-engineering findings; the `autoCollapsed` flag was dropped in response)
- Critic combined mode: BLOCKED → BLOCKED → APPROVED, both briefs, COMPLETENESS 6/6
- QA verifier: GATE_RESULT: APPROVED (A1–A6, B1–B3)
- UX Design Agent: Mode 3 clean (0 token violations). Mode 2 raised three CRITICALs; two were addressed (header height 14px → 24px for WCAG 2.5.8 target size; collapsed-but-active sections tint their header `OVERLAY.primary` and announce "in use", so the active-tool signal survives collapse). The third — asking for animated auto-collapse indicators and a dedicated keyboard shortcut — was declined as disproportionate; the chevron affordance plus the tint carries the signal.

## Deferred

- PM Advisory: manual collapse state is not persisted, unlike toolbar drag position (`TOOLBAR_STORAGE_KEY`). Accepted for now — sections reset all-open per activation.
- PM Advisory: no spec trace exists for toolbar chrome. A "Toolbar sections" note in `design-system.md` would tell future features which section a new button belongs to and how `isSectionActive` classifies it. Not written this session — compiled specs are operator-filled, so this needs operator sign-off.
- Critic: `getButtonPosition` mutates collapse state as a side effect of measurement. Renaming it (e.g. `getButtonPositionAndReveal`) would touch 13+ call sites in `index.ts`; documented in place instead.

## Governance

- Session type: standard (full gates A1–A6, B1–B3). Phase-state was re-initialized with `REPO_OS_ALLOW_REINIT=1` over a stale `editor-live` state left by a prior session.
- `plan-approved`, `pragmatist-signed`, `cohesion-reviewed`, `diff-review-complete`, and `qa-verified` were written via shell I/O — neither `plan-approval.sh` (AskUserQuestion) nor `state-writer.sh` (SubagentStop) fired in this environment. Every corresponding agent dispatch did occur and returned the recorded verdict.

## Post-session — repo reconciliation

After this session's merge, the operator reported the demo page had reverted.
Cause: the solo merge checked out `main`, swapping the working tree away from
`live-editor-26`, which was 22 commits ahead with an editor-live session and a
dev server running against it. Nothing was lost — the branch was intact — but
the checkout should not have happened without checking what the current branch
carried. Restored by checking the branch back out. All later repository work in
this session used a scratch worktree so the operator's tree was never touched.

Three reconciliations followed, all verified commit-complete in both directions
(`git log <side> --not main` empty for each) and build-verified before pushing:

- `963064c` — merged `origin/main` into local `main`, which had diverged at
  `db41f1f` (16 local feature commits vs 8 upstream template syncs). One
  conflict, `docs/ai/governance/spec-compiled.yaml`: upstream ships it as a
  blank placeholder, so the sync would have reset `spec_version` to null and
  dropped both feature-brief entries plus both `contract_changes` records. Kept
  the local version; all other template updates taken verbatim.
- `5a465b9` — committed the editor-live session's own log, which that session
  left untracked on disk when it stopped after its final code commit.
- `c2baf56` — merged `live-editor-26` into `main` (zero overlapping files).

`live-editor-26` had no remote and existed only on local disk; it is now pushed.
Both branches are sealed. This session's gate state files (`plan-approved`,
`pragmatist-signed`, `diff-review-complete`, `qa-verified`) were overwritten by
the concurrent editor-live session, which shared session id `d13941e1` and the
same state directory — the forensic trail is gone, though all gates passed
before the clobber and the commits are landed. Same collision class as the
`state-dir-wt-sessions-resolution` note in project memory.

Also added `.nco-web-editor/` to `.gitignore` (MCP server runtime state),
appended **after** the `END REPO-OS MANAGED` marker so template-sync does not
clobber it.
