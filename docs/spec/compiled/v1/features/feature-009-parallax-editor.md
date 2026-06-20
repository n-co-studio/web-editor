---
title: "Parallax Editor"
scope_modules:
  - packages/chrome-extension/src/content/editing/parallax.ts
  - packages/chrome-extension/src/content/editing/media.ts
  - packages/chrome-extension/src/content/index.ts
  - packages/shared/src/diff.ts
keywords:
  - parallax
  - background-attachment
  - perspective
  - translateZ
  - animation-timeline
  - scroll-driven
  - prefers-reduced-motion
  - StylesheetChange
  - ScriptBehaviorChange
spec_type: feature
---

# Feature Brief: Parallax Editor

## What
A "Parallax" control on the Media/Effects panel that converts an image (or banner element) into a parallax effect and exposes a single **strength dial** plus a **mechanism selector**. Four mechanisms are supported — `background-attachment: fixed`, a CSS 3D-transform depth effect, pure-CSS scroll-driven animation, and a JS scroll-listener — each producing the appropriate diff payload so Claude Code can reproduce it as project source. The mechanism is persisted on the element via `data-parallax-type` and the strength via `data-parallax-strength`; the canonical `--parallax-strength` custom property drives every mechanism through per-mode `calc()` derivation. Every mechanism emits a mandatory `prefers-reduced-motion: reduce` zeroing (WCAG 2.3.3).

## Why
Parallax already exists in code (`parallax.ts` converts an `<img>` to a fixed-background `<div>`) but is unspecced and limited to the single `background-attachment: fixed` mechanism — which has no true depth and is unsupported on iOS Safari. Operators want richer, accessible parallax with a tunable strength, and the build needs authoritative, gateable acceptance criteria before adding the three additional mechanisms. Two of the four mechanisms require new diff change types and a boundary expansion that must be agreed before implementation (this brief, 1 of 2).

## Prior Art
Existing code: `packages/chrome-extension/src/content/editing/parallax.ts` (image ↔ fixed-background-block toggle, `data-parallax*` markers, `outerHTML`-based replace via `makeParallaxCommit` in `index.ts`). Closest spec analog: `feature-007-css-visual-effects.md` (Effects panel conventions, live preview, floating-panel pattern). No experiment brief.

## What It Touches
- [x] UI / Design System / User Flows
- [ ] Auth / Sessions / Permissions
- [ ] Database / Schema / Migrations
- [x] API Contracts / Data Models
- [ ] Real-time / WebSockets / Streaming
- [ ] Large Datasets / Media / File Processing
- [ ] Payments / Billing / Financial
- [ ] External Integrations / Third-party APIs
- [x] Performance-Critical Paths

## Mechanism Taxonomy

All four mechanisms are **in scope** (operator decision — the two-modes-only alternative was rejected). Each has a CSS/representation form and a diff-pipeline carrier:

| Mechanism | `data-parallax-type` | Representation | Diff carrier | Strength maps to | Browser support |
|---|---|---|---|---|---|
| `background-attachment: fixed` | `fixed` | Inline declarations on the converted block (`background-attachment: fixed`, `background-size`, `background-position`) | `PropertyChange[]` + `StylesheetChange` (reduced-motion `@media`) | `background-size` zoom ratio (no true depth) | **Not iOS Safari** — surface warning |
| CSS 3D transform | `transform-3d` | `perspective` + `overflow` on an outer wrapper; `translateZ` + compensatory `scale` on the inner — emitted as a wrapper+inner replacement | `removeChanges[]` (the `<img>`) + `insertChanges[]` with `InsertChange.outerHTML` (wrapper+inner), assembled by `diffBuilder.buildReplace()` + `StylesheetChange` (reduced-motion `@media`) | `translateZ` depth with compensatory `scale = (perspective − distance) / perspective` | Baseline (widely supported) |
| Pure-CSS scroll-driven | `scroll-driven` | `@keyframes` translate range + element `animation-name` / `animation-timeline: scroll()`, the element wiring guarded by `@supports (animation-timeline: scroll())` | **`StylesheetChange`** (new) + `elementChanges: PropertyChange[]` (+ reduced-motion `@media`) | `@keyframes` translate range | **Not Baseline** — no Firefox default; requires `@supports not(...)` fallback to `transform-3d` |
| JS scroll listener | `js-scroll` | `requestAnimationFrame`-batched scroll handler authored as source by Claude Code | **`ScriptBehaviorChange`** (new); reduced-motion handled by a `matchMedia` short-circuit in the handler | scroll multiplier factor (`params.strengthFactor`) | Universal (perf-gated; Chrome target) |

**Cross-cutting:** Every mechanism additionally emits a `StylesheetChange` `@media (prefers-reduced-motion: reduce)` rule that zeroes the effect (for `js-scroll`, the handler short-circuits on `matchMedia` instead — `respectsReducedMotion: true`). A `@media` rule cannot be inline, so even the `fixed` and `transform-3d` mechanisms carry one `StylesheetChange` for accessibility.

### Per-mode representation detail

- **`fixed`** — extends the current `toParallaxBlock()` output. Inline `PropertyChange`s for `background-attachment`, `background-size`, `background-position`, plus `height` (banner). No depth; strength only scales `background-size`.
- **`transform-3d`** — outer wrapper gets `perspective: <P>px`, `overflow: hidden`, fixed `height`; inner gets `transform: translateZ(<depth>) scale(<scale>)` and `transform-origin`. Carried as a single replace: a `RemoveChange` for the original element (in `removeChanges[]`) plus an `InsertChange` whose `outerHTML` is the wrapper containing the inner (in `insertChanges[]`), assembled by `diffBuilder.buildReplace()`. This is the same structured-diff path `makeParallaxCommit` already uses today for the image↔block toggle (`buildReplace(oldInfo, removeChange, insertChange)` with `InsertChange.outerHTML`) — no new diff infrastructure is required for this mechanism, only the wrapper/inner builder.
- **`scroll-driven`** — canonical rule structure (`StylesheetChange.rules`, in order):
  1. An unconditional `@keyframes <name>` block whose translate range is derived from strength.
  2. An `@supports (animation-timeline: scroll())` block that applies the element wiring (`animation-name`, `animation-timeline: scroll()`, `animation-duration: auto`, `animation-fill-mode: both`, `animation-timing-function: linear`) — so the scroll animation only engages where `animation-timeline` is supported. (`StylesheetChange.elementChanges` carries the same longhands for in-place rule editing; the positive `@supports` guard is what scopes them.)
  3. An `@supports not (animation-timeline: scroll())` block carrying the `transform-3d` fallback for unsupporting browsers (notably Firefox).

  This positive-guard-plus-negative-fallback pairing is the single canonical form — the element wiring is **never** unconditional, so unsupporting browsers fall through cleanly to the 3D fallback rather than running a broken time-based animation.
- **`js-scroll`** — `ScriptBehaviorChange` with `behavior: "parallax-scroll"`, `targetSelector`, `params: { axis: "y", strengthFactor, throttle: "raf" }`, `respectsReducedMotion: true`, and a `descriptor` describing the intent. No literal JS crosses the wire.

## Strength Model

A single canonical custom property — **`--parallax-strength`** — is the dial output (range `0`–`1`, default `0.3`). Each mechanism derives its concrete value from it via `calc()`, so mechanisms are interchangeable without re-prompting the operator:

| Mechanism | Derivation |
|---|---|
| `fixed` | `background-size: calc((1 + var(--parallax-strength) * 0.5) * 100%)` — strength zooms the background (apparent-depth proxy only) |
| `transform-3d` | `--p-depth: calc(var(--parallax-strength) * -300px);` `--p-scale: calc((var(--p-perspective) - var(--p-depth)) / var(--p-perspective));` applied as `transform: translateZ(var(--p-depth)) scale(var(--p-scale))` |
| `scroll-driven` | `@keyframes` translate range: `to { transform: translateY(calc(var(--parallax-strength) * -240px)); }` |
| `js-scroll` | `params.strengthFactor = --parallax-strength` — a **direct 1:1 mapping** of the dial value (`0`–`1`) to the px-of-offset-per-px-scrolled multiplier. This is intentional: the dial range is calibrated so `0.3` (default) ≈ subtle and `1.0` ≈ strong. No additional scaling is applied. |

- **Persistence:** mechanism on `data-parallax-type`, strength on `data-parallax-strength` (alongside the existing `data-parallax`, `data-parallax-src`, `data-parallax-alt` markers). `--parallax-strength` is written as an inline custom property so the rendered effect and the persisted dial value stay in sync.
- **Panel re-read:** on (re)selecting a parallax block, the panel reads the current value via `getComputedStyle(el).getPropertyValue('--parallax-strength')` (falling back to `data-parallax-strength`) to repopulate the dial and mechanism selector — no separate state store.

## Editable Attributes
Standard `PropertyChange` (no new contract needed):
- **Banner height** (`height`) — via the existing dimensions tool.
- **Background size / zoom** (`background-size`) — also the strength target for `fixed`.
- **Background position** (`background-position`).

## Accessibility (mandatory)
- Every parallax edit emits `@media (prefers-reduced-motion: reduce)` that zeroes motion (WCAG 2.3.3 — Three Flashes / motion). For CSS mechanisms this is a `StylesheetChange` `@media` rule (`animation: none` / `transform: none` / `background-attachment: scroll`); for `js-scroll` the generated handler short-circuits when `matchMedia('(prefers-reduced-motion: reduce)').matches`.
- **Mode availability and browser support are surfaced in the UI:** the `fixed` mechanism shows an "Not supported on iOS Safari" warning; `scroll-driven` shows a "Requires Chrome 115+ (falls back to 3D transform elsewhere)" note. The panel does not silently pick an unsupported mechanism.

## User Flow
1. Operator selects an image or banner element (feature-001).
2. Operator opens the Media/Effects panel and the **Parallax** section (the existing toggle, extended).
3. Operator picks a **mechanism** (default `transform-3d` — best depth/support trade-off) and adjusts the **strength dial**.
4. Live preview applies the effect via inline styles / a transient stylesheet so the operator sees it immediately.
5. On confirm, the edit is added to the pending queue as a single reversible history entry (mirroring `makeParallaxCommit`), carrying the correct change payload(s) for the chosen mechanism plus the mandatory reduced-motion rule.
6. Reselecting the block repopulates the dial/selector from `getComputedStyle` / `data-*`. Reverting returns the original `<img>` (existing `fromParallaxBlock`).

## UI States
- **Default:** image/banner selected — "Convert to parallax" available (existing reason gate `getParallaxBlockReason`).
- **Active:** mechanism selector + strength dial visible; current values reflected; support warning shown when applicable.
- **Preview:** effect applied live, not yet committed.
- **Committed:** pending count increments; block reselectable.
- **Revert:** parallax block → original `<img>`.

## Constraints
- Spec-writing brief — **no product code changes** in this brief (1 of 2).
- Chrome target (Manifest V3); dev-only.
- `animation-timeline: scroll()` is not Baseline → `scroll-driven` requires an `@supports not (animation-timeline: scroll())` fallback to `transform-3d`.
- **Reproducible-to-source is mandatory** — both `StylesheetChange` and `ScriptBehaviorChange` must round-trip to maintainable project source per "Source Rewrite Semantics" in `data-contracts.md`. No runtime-only patches.
- **Accessibility is mandatory** — the `prefers-reduced-motion: reduce` zeroing is a REQUIRE-level boundary condition (WCAG 2.3.3), not optional. Every mechanism must emit it.
- Decision 0035 (selective spec loading); Decision 0014 (phase model). Assumes `manifest.json` active = `v1`.

## Open Questions
- Default mechanism: `transform-3d` is proposed (depth + support). Operator may prefer `fixed` for continuity with current behavior. (Non-blocking — build can default to `transform-3d`.) Note: `fixed` is retained for backward compatibility with existing `background-attachment: fixed` parallax blocks (the current `parallax.ts` behavior), not because it is the recommended default — it has no true depth and is unsupported on iOS Safari.
- Whether `--parallax-strength` should snap to a token category (`filters`-style). Deferred — strength is geometric, not token-aligned (consistent with feature-007's stance on filter values).

## Acceptance Criteria
- [ ] Parallax section offers a **mechanism selector** with all four values (`fixed`, `transform-3d`, `scroll-driven`, `js-scroll`) and a **strength dial** bound to `--parallax-strength`.
- [ ] Selecting `fixed` produces `PropertyChange[]` for `background-attachment` / `background-size` / `background-position`, and surfaces the **iOS-unsupported** warning.
- [ ] Selecting `transform-3d` produces a `RemoveChange` + `InsertChange.outerHTML` replacement (perspective wrapper + inner) with `translateZ` depth and compensatory `scale = (perspective − distance) / perspective`.
- [ ] Selecting `scroll-driven` produces a `StylesheetChange` whose `rules` carry, in order: an unconditional `@keyframes` rule, an `@supports (animation-timeline: scroll())` block applying the element `animation-*` wiring (also in `elementChanges`), **and** an `@supports not (animation-timeline: scroll())` block carrying the `transform-3d` fallback. The element wiring is never unconditional.
- [ ] Selecting `js-scroll` produces a `ScriptBehaviorChange` with `behavior: "parallax-scroll"`, `params.strengthFactor` derived from `--parallax-strength`, `params.throttle: "raf"`, and `respectsReducedMotion: true`.
- [ ] **Every** mechanism emits a `prefers-reduced-motion: reduce` zeroing (a `StylesheetChange` `@media` rule for CSS mechanisms; a `matchMedia` short-circuit for `js-scroll`).
- [ ] Mechanism persists on `data-parallax-type` and strength on `data-parallax-strength`; the dial reflects strength on reselection via `getComputedStyle`.
- [ ] The strength dial drives the rendered effect for each mechanism via the documented `calc()` derivation (a single dial change re-derives the active mechanism's value).
- [ ] Reverting a parallax block restores the original `<img>` (existing `fromParallaxBlock` behavior preserved).
- [ ] `data-contracts.md` `StylesheetChange` and `ScriptBehaviorChange` are the carriers used; `VisualDiff.stylesheetChanges` / `scriptChanges` are populated only for the mechanisms that need them.
- [ ] Each diff round-trips to maintainable source per "Source Rewrite Semantics" (CSS rules / idempotent scroll handler) — no runtime-only patch.

## Internal Design
<!-- Pre-approved contract/boundary design produced by this spec brief (1 of 2). Build brief (2 of 2) executes against it. -->

### Components
- `parallax.ts` (extended) — pure builders per mechanism (`toParallaxBlock` already covers `fixed`; add `transform-3d` wrapper/inner builder, `scroll-driven` stylesheet-rule builder, `js-scroll` descriptor builder; strength `calc()` derivations).
- `media.ts` (extended) — mechanism selector + strength dial UI in the Parallax section.
- `index.ts` (extended) — `makeParallaxCommit` assembles the right diff payload(s) per mechanism + the mandatory reduced-motion `StylesheetChange`.
- `packages/shared/src/diff.ts` (extended in Brief 2) — `StylesheetChange`, `StylesheetRule`, `ScriptBehaviorChange`, `ScriptBehaviorParams`; new optional arrays on `VisualDiff`.

### Key Interfaces
Defined authoritatively in `data-contracts.md`: `StylesheetChange` / `StylesheetRule`, `ScriptBehaviorChange` / `ScriptBehaviorParams`, and `VisualDiff.stylesheetChanges` / `VisualDiff.scriptChanges`.

### Data Flow
Operator dial/selector → mechanism builder in `parallax.ts` → `makeParallaxCommit` assembles `VisualDiff` (`changes` / `outerHTML` / `stylesheetChanges` / `scriptChanges` + reduced-motion rule) → pending queue → feature-005 MCP bridge → Claude Code reproduces as source per Source Rewrite Semantics.

### Error Handling
- Unsupported-mechanism guard: `scroll-driven` always pairs with an `@supports` fallback; `fixed` warns on iOS. The panel never commits a mechanism without its fallback/warning.
- `ScriptBehaviorChange.behavior` is validated against the single-value enum on the consumer side; any other value is rejected.
- Revert path unchanged (`fromParallaxBlock`); reduced-motion rule is idempotent (deduped by `@keyframes` name / selector on re-apply).
