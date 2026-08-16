# Session pseudo-class-spacing-hotfix — Rule-assigned spacing values in the spacing panel

## Identity
- **Branch:** `hotfix/pseudo-class-spacing-rules` (from main) · **Date:** 2026-08-16 · **Type:** hotfix (Prompt H) · **Mode:** auto after plan approval.
- **Brief:** operator report — margin/padding assigned via pseudo-class selectors (`:nth-child`, `:first-child`, also `::before`/`::after`) not surfaced in the toolbar spacing panel; expected as selectable dropdown entries with the panel's existing UI conventions.

## Diagnosis (parallel dispatch: Explore + architect + exploration)
Two distinct mechanisms behind one symptom:
1. **Pseudo-class rules are matched but never shown.** `el.matches(rule.selectorText)` (`inspection/css-rules.ts:638`) handles structural pseudo-classes correctly; the gap was that `SpacingEditor` never consulted matched rules at all — its dropdown was tokens + computed value (or the feature-011 page-value datalist). No rule provenance for any selector; plain-selector values sneak in via computed value/page harvest, making the gap look pseudo-specific.
2. **Pseudo-element rules are invisible engine-wide.** `el.matches('li::before')` silently returns `false` (spec behavior — pseudo-element selectors can never match an element), so `::before`/`::after` rules never enter `MatchedRule[]` anywhere (Rules tab, provenance, diff `RuleSource`).

KG relevance (direct invocation per Decision 0034 expedited profile) surfaced `product-tokens-page-value-store` and `product-src-diff` as adjacent — both respected (datalist merge; no wire-format change).

## Decision: scope
Pragmatist (plan-gating): **GATE_RESULT FAIL** on the bundled two-part plan — Part B (pseudo-element strip-and-match + disabled dropdown options) flagged as scope inflation / premature infrastructure (visibility without an editing story). Operator approved **Part A only, Auto**. Pseudo-element surfacing deferred to a follow-up feature brief that should scope visibility + editing + `MatchedRule`/`RuleSource` schema together (a `::before` margin styles a generated box and must not compete in the element's own cascade via `findOwningRule`).

## Fix (3 files, +127/−18; commit b153787)
- **`editing/token-select.ts`** — new `RuleValueOption {value, selector, isOwning}`; `buildTokenSelect` gains optional `ruleOptions` (default `[]`, so LayoutEditor call sites unchanged). The current-value option is now labeled `value (selector)` when an assigning rule is known and explicitly `selected` (previously nothing was selected and the browser fell back to `auto` — a small pre-existing misrepresentation). Rule-assigned values not covered by auto/current/token are appended as `value (selector)` options, deduped by value.
- **`editing/spacing.ts`** — `SpacingEditor` gains optional `matchedRulesFor` ctor accessor; `render()` resolves matched rules once (try/catch → `[]`) and threads them through `buildGroup` → `buildPropertyCell`; new `ruleOptionsFor()` (cascade winner first via `findOwningRule`, inline rules skipped, ` !important` stripped, dedupe by value); freeform-input datalist lists rule options (with `label` = selector) ahead of page-inferred values; dashed "observed" border stays tied to page-inference only.
- **`content/index.ts`** — `SpacingEditor` constructed with `(el) => activeRulesFor(el).rules`, reusing the diff path's per-element memo and shadow-host exclusion, so panel provenance and diff attribution agree by construction.

## Verification
From `packages/chrome-extension`: `npm run typecheck` exit 0 · `npm run build` → dist produced · `npm test` 69/69 pass. QA Verifier: **APPROVED** — A1 pass, A2 relaxed (127/18 across 3 files), A3 pass (A3.4 in-browser spot-check advisory: select an element matched by an `:nth-child` spacing rule and confirm the labeled option appears), A4 pass, A5 correctly skipped (hotfix), A6 n/a. Mechanical diff review confirmed all callers of changed signatures updated.

## Follow-ups
- Feature brief: pseudo-element (`::before`/`::after`) rule surfacing + editing (strip-and-match attribution, `pseudoElement` field on `MatchedRule`/`RuleSource`, cascade segregation, generated-box editing story).
- `css-rules.test.ts` element double auto-matches any selector — tighten when the pseudo-element path lands.

## Knowledge graph
Edge added: `product-editing-spacing` → `product-inspection-css-rules` (consumes; matchedRulesFor/findOwningRule wiring).

## Session mechanics notes
- `init_phase`/`advance_phase` require `_analytics-helper.sh` sourced before `_phase-helper.sh` (bare source produced `get_session_state_dir: command not found`).
- Close-phase KG + session-log writes performed via shell I/O (write-guard blocks Edit/Write outside build/verify/commit for hotfix sessions).
- Two `runner.sh --daemon` processes were running but belonged to other repos (template repo + a /tmp eval sandbox) — no Decision 0036 conflict for this working tree.
