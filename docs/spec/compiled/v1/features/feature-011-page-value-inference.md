---
title: "Page-Value Inference"
scope_modules:
  - chrome-extension/content/tokens
  - chrome-extension/content/editing
  - compiled-spec/features
keywords:
  - page-value-inference
  - PageValueStore
  - InferredOption
  - fromPageInference
  - page-defaults
  - fallback-tier
  - harvest
  - getComputedStyle
  - cssom
  - cross-origin
  - observed-reality
spec_type: feature
---

# Feature: Page-Value Inference

## Summary

When a project has **no discoverable design tokens** (token discovery sources 1–4 in [feature-003](feature-003-design-token-snapping.md#token-discovery-priority) all yield nothing, so the extension's `TokenStore` is empty), the editor still dead-ends into raw freeform entry with no suggestions. Page-Value Inference is a **last-resort fallback tier** that harvests the CSS values **already in use on the live page** — its colors, font sizes, families, weights, line-heights, spacing, radii, and shadows — and offers the most common ones as selectable defaults ("On this page") in the editing controls.

Page-inferred values are **observed reality, not design intent.** They are held in a **separate `PageValueStore` of `InferredOption` records — never `DesignToken`s** — they never enter the token registry, they never populate `PropertyChange.toToken` / `fromToken`, and every page-inferred edit carries `fromPageInference: true` so the design-token trust chain (drift reporting, token snapping) stays authoritative. This tier is a fallback **beneath** the design system and **above** the raw freeform floor from [feature-003 "No Tokens"](feature-003-design-token-snapping.md#ui-states); it is **not a peer** of the design system.

> **Thesis tension (framed, not resolved by parity).** The product is token-first ("constrain edits to the design system"), but a page with no tokens still wants to "match what's already there." Page inference serves the second goal **without** compromising the first: it is explicitly a fallback tier that **evaporates the instant real tokens arrive.** Real tokens always win. See [Precedence & Activation](#precedence--activation).

## Why

[feature-003](feature-003-design-token-snapping.md) promised a graceful "No Tokens → freeform editing" fallback, and [the freeform-no-token-fallback build](feature-003-design-token-snapping.md#ui-states) made every color/typography control editable via raw input when no tokens load. But raw freeform is a blank slate: on a real page with no formal design system, the operator re-types values that the page **already uses**, guessing at the site's actual palette and type scale. The page itself is the most relevant source of "what values belong here" when no design system exists.

Harvesting those in-use values turns the blank freeform floor into a curated shortlist grounded in the page's observed reality — the same ergonomic win token snapping gives a tokenized project, delivered for the un-tokenized case. The hard requirement is that this convenience **must not** contaminate token semantics: a downstream agent (Claude Code) reasoning over the diff must always be able to tell *"the operator picked a design token"* (design intent) from *"the operator picked a value the page happened to use"* (observed reality). That separation is the spine of this feature. It also **upgrades the diff's semantic density for Claude Code**: `fromPageInference: true` marks a *grounded* custom — a value the page already uses — which is a weaker signal than a token match but a stronger one than an arbitrary freeform value the agent has no context for. The agent can reason "reuse a value already in the page" rather than "apply a value from nowhere."

## Prior Art

- **[feature-003 — Design Token Snapping](feature-003-design-token-snapping.md)** — owner of the four token discovery sources, the `TokenStore`, the "No Tokens" freeform floor, and the `resolve_to_token` / drift contract this tier must not pollute. Amended by this task group with a fifth "Page-inferred values" source tier and the "Page Defaults" UI state.
- **[feature-005 — MCP Server Bridge](feature-005-mcp-server-bridge.md)** — owner of `TOKEN_DATA` / `TOKEN_UPDATE` (the supersession trigger) and `get_token_drift_report` (which must never count page-inferred edits as token matches).
- **[`inspection/css-rules.ts`](../../../../packages/chrome-extension/src/content/inspection/css-rules.ts)** — the existing content-script pass that iterates `document.styleSheets` + `document.adoptedStyleSheets` and wraps `sheet.cssRules` access in a per-sheet `try/catch` for cross-origin `SecurityError`. The CSSOM harvest pass **replicates this exact pattern**.
- **Data contract** — [`DesignToken`](../data-contracts.md#designtoken) (and its `TokenCategory` category union, defined on `DesignToken` in `data-contracts.md` / `packages/shared/src/diff.ts`) and [`PropertyChange`](../data-contracts.md#propertychange) — the shapes `InferredOption` deliberately parallels-but-does-not-become — plus the [`get_token_drift_report` return schema](../data-contracts.md#get_token_drift_report) (`summary.tokenMatches` / `customValues`) this tier must never register a token match in.

## What It Touches

- [x] UI / Design System / User Flows — editors gain an "On this page" option group; feature-003 gains a "Page Defaults" state
- [ ] Auth / Sessions / Permissions
- [ ] Database / Schema / Migrations
- [x] API Contracts / Data Models — `PropertyChange.fromPageInference` (additive-optional); a new extension-local `InferredOption` type (not a wire type)
- [x] Real-time / WebSockets / Streaming — `TOKEN_DATA` / `TOKEN_UPDATE` arrival is the supersession trigger (no new messages, **no `WS_PROTOCOL_VERSION` bump**)
- [x] Large Datasets / Media / File Processing — bounded DOM sampling (~500 elements) + `requestIdleCallback` chunking
- [ ] Payments / Billing / Financial
- [ ] External Integrations / Third-party APIs
- [x] Performance-Critical Paths — harvest runs on idle over a live DOM; must never block the UI thread

## Precedence & Activation

Page inference is the **fifth source tier**, strictly below the four token-discovery sources. It is a **client-side (extension) tier only** — unlike sources 1–4 it does **not** run in the MCP server, does **not** read project files, and does **not** enter the server token registry or ride any WebSocket message.

| Tier | Source | Locus | Trust class |
|---|---|---|---|
| 1 | `tailwind.config.{js,ts,mts,cts}` | MCP server | design token |
| 2 | `tokens.json` / `design-tokens.json` | MCP server | design token |
| 3 | `design-system.md` tables | MCP server | design token |
| 4 | CSS custom properties in `src/**/*.css` | MCP server | design token |
| **5** | **Values in use on the live page (this feature)** | **extension (runtime)** | **page-inferred (observed reality)** |

**Activation predicate — empty token store only.** The harvester runs **only when `TokenStore` is empty** (`tokens.length === 0`; i.e. sources 1–4 produced no tokens). When any token exists, page inference does not run and its store stays empty.

**Real tokens always win (supersession).** If tokens arrive **after** a page harvest — the MCP server discovers a config later, or a file-watcher rebuild pushes `TOKEN_DATA` / `TOKEN_UPDATE` with a non-empty token set — the `PageValueStore` is **cleared** and dropped from the editor UI, and token snapping takes over. Supersession is **one-way and terminal for the session's page values**: once real tokens exist, page inference does not re-activate unless a **later `TOKEN_DATA` / `TOKEN_UPDATE` leaves the `TokenStore` empty again** (e.g. every token source subsequently errored or was removed on a file-watcher rebuild) — that empty-store transition re-arms the [activation predicate](#precedence--activation) and a fresh harvest may run. Absent such a transition, page inference stays dormant for the session. A page-inferred value that happens to equal a later-arriving token is **not** retroactively re-labeled a token match in already-committed diffs; going forward the token UI supplies that value with token provenance.

**Relationship to the freeform floor.** The precedence an editor control applies is: **token (sources 1–4) → page-inferred (tier 5) → raw freeform.** Page Defaults sits *between* tokens and the [feature-003 "No Tokens" freeform floor](feature-003-design-token-snapping.md#ui-states): it never suppresses freeform (the operator can always type an arbitrary value), it only pre-populates the shortlist above it.

## Data Model

### `InferredOption` (extension-local — **not** a `DesignToken`, **not** a wire type)

A harvested, normalized, page-observed value offered as an editor default. It intentionally **parallels** [`DesignToken`](../data-contracts.md#designtoken) in shape (so editors can render it beside the token path) while being a **distinct type** that never crosses into the token registry or the WebSocket protocol.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| value | string | yes | The normalized, ready-to-apply CSS value (e.g. `#3b82f6`, `16px`, `"Inter", sans-serif`). Normalized per [Normalization & Dedup](#normalization--dedup). |
| category | TokenCategory | yes | Reuses the existing `TokenCategory` union (`spacing` \| `typography` \| `colors` \| `radii` \| `shadows` \| `breakpoints`) so editors bucket page values exactly as they bucket tokens. `breakpoints` is not harvested in v1 (see [Harvest Scope](#harvest-scope)). Because `typography` spans four distinct properties (font-size / font-family / font-weight / line-height), editors resolve page values **by property** via `getForProperty` (filtered on `cssProperties`) — the coarse `getForCategory('typography')` bucket returns all four mixed, exactly as it does for `DesignToken`s, so property-level lookup is the intended consumer path. |
| cssProperties | string[] | yes | Which CSS longhands this option applies to — mirrors `DesignToken.cssProperties` so an editor can filter by the property being edited before offering the option. |
| frequency | number | yes | How many sampled elements / declarations exhibited this normalized value. The ranking key; also drives the frequency floor. |
| origin | "computed" \| "cssom" \| "custom-property" | yes | Which harvest pass surfaced the value. `custom-property` (a `:root --*` declaration) is treated as higher-confidence and is **exempt from the frequency floor** (a declared custom property is intentional, even if used once). |
| **`fromPageInference`** | `true` | yes | **Provenance discriminant — always `true`.** The literal marker that this option is observed reality, not a design token. Carried through to the emitted `PropertyChange` (below). |
| label | string | no | Optional short human label (e.g. `rgb→hex` note, or the raw pre-normalization form) for display; never used as identity. |

> `InferredOption` is deliberately **not** assignable to `DesignToken`: it has no `name` and no `source` file, and it adds `frequency` / `origin` / `fromPageInference`. This type-level distinction is a first line of defense against a page value being fed into a token-only code path.

### `PageValueStore` (extension-local, parallel to `TokenStore`)

A client-side registry parallel to [`TokenStore`](../../../../packages/chrome-extension/src/content/tokens/store.ts) but holding `InferredOption[]` indexed by CSS property and category. It is **never** the `TokenStore` and **never** merges into it. Contract surface (detailed signatures land in Brief 2):

- `load(options: InferredOption[])` — replace the store from a completed harvest.
- `getForProperty(cssProperty): InferredOption[]` — property-indexed lookup, ranked by `frequency` desc (parallel to `TokenStore.getForProperty`).
- `getForCategory(category): InferredOption[]` — category lookup.
- `clear()` — drop all page values (called on token supersession).
- `onUpdate(cb)` / `loaded` — change subscription + emptiness, so editors re-render on harvest completion or supersession.

### `PropertyChange` semantics (the trust-chain guarantee)

A page-inferred selection emits a [`PropertyChange`](../data-contracts.md#propertychange) that is, by construction, a **custom (raw-CSS) change** — never a token match:

- `toValue` = the chosen `InferredOption.value` (raw CSS).
- `toToken` — **absent. Never set from a page value.** (Same for `fromToken`.)
- **`fromPageInference: true`** — a new **additive-optional** `PropertyChange` field marking the change's provenance as page-inferred. Absent on all pre-feature-011 diffs and on token / arbitrary-freeform edits; a consumer that ignores it sees an ordinary custom (no-`toToken`) change — a clean degrade. **No `WS_PROTOCOL_VERSION` bump** (additive-optional, same treatment as `reorderChanges` / `uid` / `layoutContainers`).

**`get_token_drift_report` interaction.** Because a page-inferred change carries **no `toToken`**, [`get_token_drift_report`](../data-contracts.md#get_token_drift_report) (return schema `{ escapes, summary: { totalEdits, tokenMatches, customValues } }`, defined in data-contracts.md; surfaced by [feature-005](feature-005-mcp-server-bridge.md#outputs)) never counts it in `summary.tokenMatches` — that guarantee holds from the `toToken`-absence alone. `fromPageInference: true` additionally lets the report (and any downstream agent) **distinguish a page-inferred custom from a truly arbitrary custom**: a page-inferred edit is a *grounded* escape (the operator chose a value the page already uses), not a design-system violation to flag. v1 keeps page-inferred edits inside the existing `customValues` tally (they are raw CSS with no token) but the flag is available so a future report can separate the two populations without a schema change.

## Harvest Scope

Categories harvested and the representative CSS longhands read for each (bucketed under the existing `TokenCategory` union):

| Category | Harvested CSS properties (representative) |
|---|---|
| `colors` | `color`, `background-color`, `border-color` (per-side longhands), `outline-color`, `fill`, `stroke` |
| `typography` — font-size | `font-size` |
| `typography` — font-family | `font-family` |
| `typography` — font-weight | `font-weight` |
| `typography` — line-height | `line-height` |
| `spacing` | `margin-*`, `padding-*`, `gap` / `row-gap` / `column-gap` |
| `radii` | `border-radius` (per-corner longhands) |
| `shadows` | `box-shadow` |

`breakpoints` are **out of scope** for page harvesting in v1 (a breakpoint is a media-query authoring fact, not a per-element computed value; it has no meaningful "in use on the page" reading). `background-image`, gradients, and transitions/animations are out of scope in v1.

## Harvest Strategy

Three passes, run in order on activation (guarded by the [empty-token-store predicate](#precedence--activation)) and scheduled on idle:

1. **`:root` custom-property pre-pass (highest confidence).** Read `--*` custom-property declarations from the `:root` / `document.documentElement` rule via the CSSOM (and computed style). These are the page author's **declared** design values; each becomes an `InferredOption` with `origin: 'custom-property'`, **exempt from the frequency floor**, categorized by heuristic on the value shape (a color-valued custom property → `colors`, a length → `spacing`/`radii` by property-name hints when bound, etc.). This pre-pass overlaps in spirit with token source 4 but runs **client-side at runtime over the live CSSOM**, not server-side over `src/**/*.css` files — so it also captures custom properties from third-party/runtime stylesheets that source 4 never sees.

2. **Bounded, chunked `getComputedStyle` over visible elements.** Walk the visible DOM (skip `display:none`, zero-area, and off-screen-collapsed nodes), calling `getComputedStyle` per element and reading the [in-scope properties](#harvest-scope). **Capped at ~500 sampled elements** ([Performance](#performance)); work is split into chunks scheduled with `requestIdleCallback` (fallback `setTimeout`) so a large DOM never blocks the main thread. Computed values are same-origin-safe (they read the element's resolved style, not a foreign stylesheet), so this pass works even when every stylesheet is cross-origin. Each observed value increments its `InferredOption.frequency`; `origin: 'computed'`.

3. **CSSOM declared-value pass.** Iterate `document.styleSheets` **and** `document.adoptedStyleSheets`; for each sheet, access `sheet.cssRules` inside a **per-sheet `try/catch` that swallows the cross-origin `SecurityError`** and continues (the exact pattern in [`inspection/css-rules.ts`](../../../../packages/chrome-extension/src/content/inspection/css-rules.ts)). From readable rules, collect declared in-scope values (`origin: 'cssom'`). This captures authored values that may not appear on any currently-visible element. Cross-origin sheets are skipped silently and recorded as a partial-harvest signal (see [UI States](#ui-states) / [Edge Cases](#edge-cases)).

The three passes are unioned, then normalized, deduped, floored, and capped before `PageValueStore.load`.

## Normalization & Dedup

- **Value normalization (canonical form per category):**
  - **Colors:** `rgb()` / `rgba()` → lowercase hex (`#rrggbb`, or `#rrggbbaa` when alpha < 1); named colors and `hsl()` → hex; collapse equivalent forms so `rgb(59,130,246)` and `#3B82F6` dedupe to one option.
  - **Lengths (spacing / radii / font-size):** trim, lowercase units; keep the authored unit (`px` / `rem` / `em`) rather than forcing `px`, since the page's own unit is the value "in use"; normalize `0px`/`0rem` → `0` for dedup.
  - **font-family:** collapse whitespace, normalize quoting, preserve the full stack as one option.
  - **font-weight / line-height:** numeric normalization (`normal` → `400` for weight; unitless line-heights preserved).
  - **box-shadow:** whitespace-normalize the layer list, layer order preserved. **Visual-equivalence dedup is explicitly out of scope for v1** — two shadows that render identically but differ in authored form (shorthand expansion, layer reordering, unit form) may survive as separate options. Shadows are the noisiest category and the natural first cut for v1.1 if harvest quality needs tightening; Brief 2 should not over-engineer shadow normalization beyond whitespace-normalization.
- **Dedup:** within a category, options with the same **normalized `value`** collapse to one, summing `frequency` and taking the highest-confidence `origin` (`custom-property` > `cssom` > `computed`).
- **Frequency floor:** discard `origin: 'computed'` / `'cssom'` options whose summed `frequency` is below a floor (default **≥ 2** occurrences) to suppress one-off / incidental values. `origin: 'custom-property'` options are **exempt** (declared intent counts even at frequency 1).
- **Per-category top-N caps:** after ranking by `frequency` desc (deterministic tiebreak on normalized `value` sort), keep at most **N per category** (defaults: colors 12, font-size 8, font-family 6, font-weight 6, line-height 6, spacing 10, radii 6, shadows 6). Dropped counts are recorded for the partial/"showing top N" affordance.

## Performance

- **Element cap ~500.** If the visible DOM exceeds the cap, sample deterministically (document-order first-N in v1; the dropped remainder is counted and surfaced, never silently ignored — see [Edge Cases](#edge-cases)).
- **`requestIdleCallback` chunking.** The `getComputedStyle` walk is chunked across idle callbacks (fallback `setTimeout(…, 0)`), yielding to the main thread between chunks. Harvest never runs synchronously on selection.
- **Runs on idle, once per harvest trigger** — on activation (empty token store) and on SPA re-harvest, never per keystroke or per element selection.
- **SPA re-harvest.** A **debounced `MutationObserver`** (default ~750 ms debounce, observing `childList` + `subtree` on `document.body`) re-runs the harvest when the DOM changes **substantially** — defined concretely as a debounced batch whose net added-or-removed **element** count exceeds a threshold (default **≥ 25** added/removed elements, so incremental hover/focus mutations do not trigger a re-harvest while a route swap does). Re-harvest is a no-op when tokens are present (supersession already fired). Re-harvest replaces the store atomically so the editor never reads a half-built store.

## UI States

feature-011 owns the **"Page Defaults"** family of states; feature-003 is amended with the corresponding **"Page Defaults"** UI state (distinct from "No Tokens"). See [feature-003 § UI States](feature-003-design-token-snapping.md#ui-states).

- **Page Defaults (active):** No tokens found, but page values were harvested. Editors show an **"On this page"** option group of the ranked `InferredOption`s (swatches for colors, a value list for type/spacing/radii/shadows), rendered **above** the freeform floor and **visually distinct** from real token swatches (page-inferred styling — e.g. a dashed/"observed" affordance and an "On this page" heading — never the token treatment), so the operator can always tell a page value from a design token. Freeform entry remains available beneath it.
- **Harvesting / partial:** Harvest in progress, or completed but degraded (some stylesheets were cross-origin and skipped). Show the available subset with a subtle "showing values found on this page" / "some styles couldn't be read" affordance; never block editing on harvest.
- **Superseded by tokens:** Real tokens arrived → `PageValueStore.clear()`, the "On this page" group disappears, and the standard token-snapping UI ([feature-003 Default / Snapped states](feature-003-design-token-snapping.md#ui-states)) takes over.
- **Empty page inference:** No tokens **and** nothing harvested (blank page, or everything below the frequency floor) → fall through to the [feature-003 "No Tokens" freeform floor](feature-003-design-token-snapping.md#ui-states) unchanged. Page Defaults adds a shortlist when it can; it never removes the freeform escape.

## User Flow

1. Operator activates the extension on a page whose project has **no discoverable tokens** (sources 1–4 empty → `TokenStore` empty).
2. The harvester runs on idle: `:root` custom-property pre-pass → bounded chunked `getComputedStyle` over visible elements → CSSOM pass (cross-origin sheets skipped).
3. Values are normalized, deduped, frequency-floored, and top-N capped, then `PageValueStore.load(...)`.
4. Operator opens a color / typography / spacing control. The editor queries **`TokenStore.getForProperty` first (empty)**, then **`PageValueStore.getForProperty`**, and renders the **"On this page"** group above the freeform floor.
5. Operator picks a page value → the extension emits a `PropertyChange` with `toValue` = the value, **`fromPageInference: true`**, and **no `toToken` / `fromToken`.** The change commits like any custom edit.
6. If the MCP server later discovers real tokens and pushes `TOKEN_DATA` / `TOKEN_UPDATE`, the store clears, the "On this page" group vanishes, and token snapping takes over. Already-committed page-inferred diffs are unchanged (they remain grounded customs, not token matches).

## Inputs

- **Live DOM** — visible elements' `getComputedStyle` for the [in-scope properties](#harvest-scope).
- **CSSOM** — `document.styleSheets` + `document.adoptedStyleSheets` (cross-origin sheets skipped via per-sheet `try/catch`), and the `:root` custom-property declarations.
- **Activation signal** — `TokenStore` emptiness (`tokens.length === 0`), i.e. token sources 1–4 produced nothing.
- **Supersession signal** — `TOKEN_DATA` / `TOKEN_UPDATE` over WebSocket carrying a non-empty token set.
- **DOM-mutation signal** — debounced `MutationObserver` for SPA re-harvest.

## Outputs

- **`PageValueStore`** — `InferredOption[]` indexed by property/category, ranked by frequency. Extension-local; never serialized to the wire or the server registry.
- **Editor "On this page" option groups** — rendered from the store, visually distinct from token swatches.
- **`PropertyChange`** with **`fromPageInference: true`** and **no `toToken` / `fromToken`** for every page-inferred selection.
- **No new WebSocket messages, no new MCP tools, no server token-registry entries, and no `WS_PROTOCOL_VERSION` bump.** Page inference is entirely extension-side; the only wire-visible artifact is the additive-optional `PropertyChange.fromPageInference` flag on emitted diffs.

## Edge Cases

- **No visible elements / blank page** → nothing harvested → empty store → [feature-003 freeform floor](feature-003-design-token-snapping.md#ui-states) unchanged.
- **All stylesheets cross-origin** → CSSOM pass yields nothing (each sheet's `SecurityError` is caught and skipped), but `getComputedStyle` still harvests resolved values → **partial** harvest, surfaced as such; never an uncaught error.
- **Huge DOM (> ~500 visible elements)** → deterministic sampling to the cap; the dropped-element count is recorded and surfaced ("showing values found on a sample of this page"), never silently truncated.
- **Tokens arrive mid-session / mid-edit** → store cleared and UI superseded. If an edit is in progress when supersession fires, the in-flight control resolves against the arriving tokens on its next render (mirrors feature-003's queued-update-on-commit behavior); the committed page-inferred change (if any) keeps its `fromPageInference` provenance.
- **Page uses only inline styles / no `:root` vars** → the `getComputedStyle` pass still harvests; the pre-pass simply contributes nothing.
- **Token source 4 failed + `:root` pre-pass overlap (degraded design system).** A project that *should* have tokens but whose server-side source 4 (CSS custom properties in `src/**/*.css`) failed or truncated (TS-config transform failure, or the 200-file scan cap) leaves the `TokenStore` empty — so page inference activates and the `:root` pre-pass may re-surface the project's *own* `--*` variables as page-inferred values. The trust chain stays intact (`fromPageInference: true`, no `toToken`), but the operator sees a **degraded view of their own design system** presented as observed reality, with no signal that a token source failed. This is a product-clarity risk, not a data-integrity one: Brief 2 SHOULD consider a "these look like your project's design variables — a token source may have failed to load" affordance (e.g. keyed off a non-empty `TokenSourceStatus` `status: 'error'` arriving alongside an empty token set) rather than silently labeling them page-inferred.
- **Frequency ties** → deterministic tiebreak (normalized-value sort) so ranking and the top-N cut are reproducible.
- **SPA route change** → debounced `MutationObserver` re-harvests; no-op when tokens are present.
- **A page-inferred value equals a later-arriving token value** → the token wins on supersession; the value is thereafter offered with **token** provenance. Already-committed page-inferred diffs are **not** retroactively relabeled as token matches.
- **A page value is visually indistinguishable from a token in the UI** → forbidden. Page-inferred options MUST render with a distinct treatment and the "On this page" heading so provenance is always legible (this is an acceptance criterion, not a nicety).

## Non-Token Semantics (normative)

The following invariants are **normative** and are the acceptance spine of this feature:

1. Page-inferred values are **observed reality, not design intent.** They MUST NOT enter the `TokenStore`, the server token registry, `TOKEN_DATA` / `TOKEN_UPDATE`, or any `DesignToken`.
2. A page-inferred selection's `PropertyChange` MUST carry **`fromPageInference: true`** and MUST NOT set **`toToken`** or **`fromToken`**.
3. `get_token_drift_report` MUST NOT count a page-inferred change as a **token match** (guaranteed by `toToken` absence; the flag additionally lets it be told apart from an arbitrary custom).
4. Page inference activates **only** when `TokenStore` is empty and is **superseded (cleared)** whenever real tokens exist. Real tokens always win.
5. Page-inferred UI MUST be **visually distinct** from token UI, so the operator always knows which they picked.

## Alternatives Considered

- **Fold page values into `TokenStore` as synthetic `DesignToken`s** (Exploration's first sketch — give each harvested value a synthetic `name`/`source` and inject it into the registry so editors "just work"). **Rejected** by Critic / Architect: it corrupts the token/drift contract at its root — synthetic tokens would populate `toToken`, be counted as token matches by `get_token_drift_report`, and be indistinguishable from real design tokens to Claude Code, collapsing the observed-reality-vs-design-intent boundary that this feature exists to preserve. A **parallel `PageValueStore`** keeps the server-token trust chain authoritative and makes the non-token semantics enforceable by type and by the `fromPageInference` discriminant.
- **Server-side harvesting** (have the MCP server infer page values). **Rejected:** the values "in use on the page" are a **runtime DOM/CSSOM** fact the server cannot see; the extension is the only vantage point, and keeping the tier client-side avoids any server-registry contamination.
- **Suppress freeform when Page Defaults is active.** **Rejected:** page inference is a convenience shortlist, not a constraint; the freeform escape from feature-003 must always remain.

## Acceptance Criteria

- [ ] **Fifth tier registered:** [feature-003](feature-003-design-token-snapping.md) documents a fifth "Page-inferred values" source tier and a distinct **"Page Defaults"** UI state (separate from "No Tokens"); feature-011 is registered in `manifest.json` `featureFiles`.
- [ ] **Precedence — activation:** page inference activates **only** when `TokenStore` is empty (token sources 1–4 yielded nothing) and never runs while any token exists.
- [ ] **Precedence — supersession:** when non-empty tokens arrive over `TOKEN_DATA` / `TOKEN_UPDATE`, the `PageValueStore` is cleared and the "On this page" UI is replaced by token snapping; real tokens always win.
- [ ] **Supersession timing (mid-harvest):** if non-empty tokens arrive **while a harvest is in progress** (mid-`requestIdleCallback` chain), the harvest either aborts immediately or runs to completion and then clears — in either case the `PageValueStore` is empty and no page-inferred values are visible to editors by the time supersession is observable to the UI.
- [ ] **Non-token data model:** page values are held in a **separate `PageValueStore` of `InferredOption`** records — never `DesignToken`, never in the token registry, never on the WebSocket protocol.
- [ ] **Non-token diff semantics:** a page-inferred selection emits a `PropertyChange` with **`fromPageInference: true`** and **no `toToken` / `fromToken`**; `get_token_drift_report` does not count it as a token match. `fromPageInference` is additive-optional with **no `WS_PROTOCOL_VERSION` bump**.
- [ ] **Harvest scope:** colors, font-size, font-family, font-weight, line-height, spacing, radii, and shadows are harvested (bucketed under the existing `TokenCategory` union); breakpoints are out of scope.
- [ ] **Harvest strategy:** a `:root` custom-property pre-pass, a bounded chunked `getComputedStyle` pass over visible elements, and a CSSOM pass are all specified; the CSSOM pass wraps per-sheet `cssRules` access in a `try/catch` that swallows cross-origin `SecurityError` (the `inspection/css-rules.ts` pattern) and degrades to a partial harvest.
- [ ] **Cross-origin handling:** a page whose stylesheets are all cross-origin produces **no uncaught error** and still harvests via `getComputedStyle`.
- [ ] **Dedup / normalization / caps:** values are normalized (rgb→hex, unit-normalized), deduped by normalized value, subjected to a frequency floor (custom-property origin exempt), and capped per category with a deterministic ranking + tiebreak.
- [ ] **Performance:** harvest is bounded to ~500 sampled elements, chunked via `requestIdleCallback` (never blocking the UI thread), runs on idle (not per selection), and re-harvests on a debounced `MutationObserver` for SPA navigation (re-harvest fires only when a debounced mutation batch nets ≥ 25 added/removed elements, so incremental UI mutations do not).
- [ ] **Provenance legibility:** page-inferred options render **visually distinct** from token swatches under an "On this page" heading, and never suppress the freeform floor.
- [ ] **Cross-session:** compatible with the current spec base (`git log --oneline -10`) — in particular the freeform "No Tokens" fallback this tier builds on.

## Internal Design

<!-- Spec-first brief (1 of 2). The contract IS the deliverable here; detailed
     component/interface design lands in the build brief (2 of 2). The design
     decisions ratified here: -->

### Components

- **`page-harvester.ts`** (Brief 2, `content/tokens/`) — the three-pass scan (`:root` pre-pass → bounded chunked `getComputedStyle` → CSSOM pass), plus normalize / dedup / frequency-floor / top-N-cap / categorize.
- **`page-value-store.ts`** (Brief 2, `content/tokens/`) — the `PageValueStore` holding `InferredOption[]`, parallel to `TokenStore`; `load` / `getForProperty` / `getForCategory` / `clear` / `onUpdate` / `loaded`.
- **`content/index.ts`** (Brief 2) — instantiate the harvester + store; gate activation on `TokenStore` emptiness; wire `TOKEN_DATA` / `TOKEN_UPDATE` → `PageValueStore.clear()`; own the debounced `MutationObserver`.
- **Editors** (`colors.ts`, `typography.ts`, `layout-editor.ts` / spacing, Brief 2) — consult `PageValueStore` when `TokenStore.getForProperty` is empty; render the "On this page" group above the freeform floor; emit `fromPageInference: true` / no-`toToken` changes.
- **`PropertyChange`** (`packages/shared/src/diff.ts`, Brief 2) — additive-optional `fromPageInference?: true`.

### Key Interfaces

- `InferredOption` (extension-local type; fields per [Data Model](#data-model)).
- `PageValueStore.load(options: InferredOption[])`, `.getForProperty(cssProperty): InferredOption[]`, `.getForCategory(category): InferredOption[]`, `.clear()`, `.onUpdate(cb)`, `.loaded`.
- `harvestPageValues(): InferredOption[]` (or an idle-scheduled async equivalent returning the harvested set).
- `PropertyChange.fromPageInference?: true` (additive-optional wire field).

### Data Flow

Activate (extension) → `TokenStore` empty? → `harvestPageValues()` scans DOM/CSSOM on idle → normalize/dedup/floor/cap → `PageValueStore.load()` → editors query `TokenStore` first, `PageValueStore` as fallback → operator picks → `PropertyChange { fromPageInference: true, no toToken }` → batched/committed like any diff. Parallel path: `TOKEN_DATA`/`TOKEN_UPDATE` (non-empty) → `PageValueStore.clear()` → token snapping resumes.

### Error Handling

- `harvestPageValues` wrapped in `try/catch`; a total failure leaves the store empty and editors fall through to the freeform floor (no regression).
- CSSOM cross-origin `SecurityError` caught **per sheet**; harvest continues and is marked partial.
- Oversized DOM → deterministic sampling to the ~500 cap; dropped count surfaced, never silently ignored.
- Supersession (`clear()`) is idempotent and safe to call when the store is already empty.
