---
title: "Structural Auto-Layout Contract"
scope_modules:
  - compiled-spec/data-contracts
  - compiled-spec/boundaries
  - compiled-spec/features
  - packages/shared/src/layout.ts
  - packages/shared/src/diff.ts
  - chrome-extension-content
  - mcp-server-apply
keywords:
  - data-fe-layout
  - layoutRole
  - editable-list
  - nested-group-as-peer
  - LayoutContainerDescriptor
  - childUids
  - containerUid
  - structural-boundary
  - flat-data-group
  - auto-layout
spec_type: feature
---

# Feature Brief: Structural Auto-Layout Contract

> **Ratification brief (1 of 2 in the `structural-auto-layout-contract` task group).** This brief **ratifies the contract** in the compiled specs; it writes no product code. The build brief (2 of 2) implements the runtime editable-list signal, nested-group detection, the additive-optional schema wiring, the shared `packages/shared/src/layout.ts` module, and the first conformance migration against this ratified contract. Same spec-first split as [`brief-stable-element-identity`](brief-stable-element-identity.md) (issue #27).

## What

A bounded, ratified structural model — **list / item / group** — for the visual editor's DOM ⇄ visual-diff ⇄ source round-trip. It defines four things:

1. **The editable-list signal** — how the editor decides a container's direct children form a reorderable/groupable peer list: an explicit, **runtime-assigned/opt-in** `data-fe-layout="flex|grid"` attribute is authoritative; a **thresholded computed-style heuristic** is the fallback.
2. **The item taxonomy `layoutRole: flow | absolute | group`** — how each direct child of an editable list is classified: an in-flow reorderable item (`flow`), a visible-but-excluded positioned peer (`absolute` — the parallax case), or a nested container exposed as a first-class peer (`group`).
3. **The nested-group-as-peer wire shape** — an additive-optional `layoutContainers[]` descriptor array on `VisualDiff` (with explicit `childUids[]`), plus `containerUid` on `ReorderChange` and `source/targetContainerUid` on `ReparentChange`, so a nested flex/grid container round-trips as an opaque peer without a recursive tree on the wire.
4. **The conformance requirement** — a group is only representable when it has a **real structural boundary** (a container element in JSX and/or a nested data sub-array). This governs the **data shape**, not only JSX, and is the acceptance-defining constraint (the "flat-data group problem").

The authoritative schema for the change types this model extends lives in [`data-contracts.md`](../data-contracts.md); this feature is the model's conceptual home and the home of the agent-facing **code-gen convention**. The machine-checkable form of the contract is the shared module `packages/shared/src/layout.ts` (named here, built in Brief 2).

## Why

Reorder, group, and reparent already exist as change types ([`ReorderChange`](../data-contracts.md#reorderchange), [`GroupChange`](../data-contracts.md#groupchange), [`ReparentChange`](../data-contracts.md#reparentchange) in `diff.ts`), but the editor has **no agreed model for what a "list" is**. Today it infers a reorderable container from `display:flex|grid` alone, which mis-fires on incidental flex wrappers (a nav bar, a button row, an icon cluster are all `display:flex` but are not editable lists). It has **no notion of a nested group as a peer** — a two-column sub-layout inside a gallery is invisible to the reorder model. And it has **no rule for the flat-data case** — a "group" that exists only as an array entry with an implicit `width:"half"`, with no container in DOM or source, cannot round-trip losslessly.

The model is read by **three independent consumers**: the extension capture layer (classifies containers/children), the MCP diff stream (carries the descriptors), and the agent applier / code-gen (writes conforming source). As with `stable-element-identity`, ratifying the shape **before** implementation prevents the build brief from coding against an unratified contract, and forces the non-trivial undecided semantics (the flat-data group problem, the runtime-created-container uid case, grid-reorder) to be settled first.

## Prior Art

- **[`brief-stable-element-identity`](brief-stable-element-identity.md) (issue #27)** — the two-brief spec-first precedent this brief mirrors, and the source of the `data-fe-uid` / `uid` identity every descriptor here keys on.
- **[`feature-009-parallax-editor.md`](feature-009-parallax-editor.md)** — the enum-bounding pattern this brief mirrors for v1 scope, and the owner of the `position:absolute` parallax elements that this model classifies as `layoutRole: absolute` (never diff-hidden, never a reorder target).
- **Existing change types** — `ReorderChange` (incl. the `containerDirection` `"row wrap"` suffix, issue #30), `GroupChange`, `ReparentChange`, `SiblingAnchor` (incl. `uid` + `assetPath`/`label`, issues #27/#29) in `diff.ts`.
- **Root case (Levantine modal)** — `markpreston2/markpreston.co @ live-editor-26`: a gallery modal whose two-up "group" exists only as a flat `projects.json` array + implicit `width:"half"`. This is the acceptance-defining flat-data case (see [The flat-data group problem](#the-flat-data-group-problem-acceptance-defining)); its migration is a Brief-2 deliverable.

## What It Touches

- [x] UI / Design System / User Flows — reorder/group affordances read the editable-list model (feature-001, feature-004)
- [ ] Auth / Sessions / Permissions
- [ ] Database / Schema / Migrations
- [x] API Contracts / Data Models — `VisualDiff` structural shapes (`ReorderChange`, `GroupChange`, `ReparentChange`, new `layoutContainers[]`)
- [x] Real-time / WebSockets / Streaming — descriptors ride the diff payload over WS (additive-optional, no protocol bump)
- [ ] Large Datasets / Media / File Processing
- [ ] Payments / Billing / Financial
- [ ] External Integrations / Third-party APIs
- [ ] Performance-Critical Paths

## The Model

### 1. Editable list — the `data-fe-layout` signal

An **editable list** is a container whose direct element children form a reorderable / groupable peer set. Two detection paths, in priority order:

| Priority | Source | Rule | Authority |
|---|---|---|---|
| 1 | **Explicit signal** | `data-fe-layout="flex"` or `data-fe-layout="grid"` on the container | **Authoritative.** The container IS an editable list of the named layout kind. Runtime-assigned or opt-in authored — never overridden by the heuristic. |
| 2 | **Thresholded heuristic** (fallback, only when no explicit signal) | `getComputedStyle(el).display ∈ {flex, grid}` **AND** direct-element-child-count ≥ 2 **AND** child tag/uid homogeneity | Best-effort. Suppresses incidental flex wrappers (nav/button/icon rows) that are `display:flex` but not editable lists. |

**Homogeneity gate (heuristic path).** The children are homogeneous when they share a `tagName` **or** a common source origin — the same `.map()` family, whose canonical key is defined in [data-contracts → the editable-list signal](../data-contracts.md#structural-auto-layout-data-fe-layout--layoutrole) as **the same `data-source-file` + `data-source-line` pair** (a `.map()`-rendered set whose per-instance `uid`s share one build-time origin). A container of mixed one-off elements (e.g. `<button><svg><span>` in a toolbar) fails the gate and is **not** exposed as an editable list. The threshold constants and the homogeneity predicate are encoded in `packages/shared/src/layout.ts` (Brief 2) so capture and any convention validation share one definition.

**Why runtime / opt-in, never a build-time stamp.** The dev-plugin (feature-006) AST pass runs at build and **cannot compute `display`** — the layout lives in CSS modules / Tailwind classes that only resolve at runtime. A build-time `data-fe-layout` would therefore be a guess, not a fact. So `data-fe-layout` is **stamped at runtime** by the content script (from live computed style + the thresholded gate) or **authored opt-in** by a developer who wants to mark a container authoritative. This mirrors the [`data-fe-uid` stamping lifecycle](../data-contracts.md#stamping-lifecycle) split: the dev-plugin owns what it can compute statically (identity, source location); the runtime owns what only exists live (layout, per-instance identity for `.map()` fan-out).

> The `data-fe-layout` attribute value is the layout **kind** (`flex` / `grid`) — it is **not** a duplicate of `display` (which also carries `block`/`inline`/etc.) and is present only on containers the editor treats as editable lists. Absence of the attribute is not "not a list" — it means "fall back to the thresholded heuristic."

### 2. Item taxonomy — `layoutRole: flow | absolute | group`

Every **direct child** of an editable list is classified with a `layoutRole`:

| `layoutRole` | Applies to | Reorderable? | In gap-math? | Diff-hidden? | Notes |
|---|---|---|---|---|---|
| `flow` | A normal in-flow child (the default). | **Yes** | **Yes** | No | The ordinary reorder/group target. |
| `absolute` | A child with `position: absolute` or `position: fixed`, **and** an explicitly-placed grid child (one with `grid-area` / `grid-column` / `grid-row` placement). | **No** | **No** | **No — a visible peer** | The **parallax case**. The child is a first-class visible peer in the list (it is never hidden from the diff), but it is **excluded from reorder index math and from gap-math**, because it is taken out of normal flow. This preserves feature-009's selector-anchored `ScriptBehaviorChange` contract: the parallax element stays addressed by its selector and is never swept into a `ReorderChange`'s `fromIndex`/`toIndex`. |
| `group` | A direct child that is **itself** an editable-list container (a nested flex/grid). | Reorderable **as an opaque peer** at the parent's level | Yes (as one peer) | No | Exposed as a first-class peer; its internal children are one level down, described by a `LayoutContainerDescriptor` (see §3). Bounded to **one nesting level** in v1 (see [`boundaries.md`](../boundaries.md)). |

`layoutRole` is an **additive-optional** field wherever a child is described (its normative carrier and default are specified in [`data-contracts.md`](../data-contracts.md#layoutrole-item-classification)). A consumer that ignores it sees the pre-existing flat behavior — every child treated as `flow` — which is the current (pre-contract) behavior, so absence is a clean degrade.

> **Why `absolute` is a visible peer and not diff-hidden.** An earlier alternative hid positioned children from the peer list entirely. Rejected: the parallax banner is a real, selectable element the operator edits (feature-009); hiding it from the structural model would make it un-addressable in a reorder context and would contradict feature-009's contract. `absolute` keeps it **visible and selectable** but **out of the reorder/gap computation** — the exact semantics the layout needs.

### 3. Nested-group-as-peer — the wire shape

A `layoutRole: group` child is a nested editable-list container. On the wire it appears twice, additively:

- As **one opaque peer** in its parent's `childUids[]` / sibling list (so a reorder at the parent level treats the whole group as a single movable item).
- As **its own `LayoutContainerDescriptor`** in the diff's `layoutContainers[]` array (so the group's internal structure is self-describing without a recursive tree).

The ratified shape (leading candidate — **`layoutContainers[]` on `VisualDiff`** with explicit `childUids[]`) is defined authoritatively in [`data-contracts.md` → LayoutContainerDescriptor](../data-contracts.md#layoutcontainerdescriptor). Summary of the fields:

- `uid` — the container's own `data-fe-uid`.
- `layout: 'flex' | 'grid'` and `direction` — the layout kind and `containerDirection` (incl. the `"row wrap"` suffix, issue #30).
- `childUids: string[]` — the container's direct children, **in visual order**, keyed by `uid`. The parallel-array convention (idiomatic to `siblingSelectors`/`siblingAnchors`) — lower agent parse cost than a recursive tree.
- `parentUid?` — the enclosing editable-list container's `uid` (absent for the top-level container). This is the single edge that makes the flat `layoutContainers[]` array reconstruct the (one-level) nesting.
- `role?` — `group` when this container is nested as a peer inside another; absent/`flow` for the top-level container.
- `signalSource: 'explicit' | 'heuristic'` — how the list was detected, so the applier knows whether `data-fe-layout` is already authoritative on the element or must be stamped on codegen.

Plus the two container-identity additions to the existing change types (additive-optional, defined in `data-contracts.md`):

- **`ReorderChange.containerUid?`** — the editable-list container the reorder happened in, keyed by `uid` (parallel to the existing selector-based `containerSelector`).
- **`ReparentChange.sourceContainerUid?` / `targetContainerUid?`** — the source and target container `uid`s for a cross-container move (parallel to the existing `sourceContainerSelector` / `targetContainerSelector`).

**Considered alternative — recursive `leaf | group` union on `childSnapshot`.** A discriminated tree where each `childSnapshot` entry is either a leaf or a group node carrying its own children. **Rejected** in favor of the flat `layoutContainers[]` descriptor with explicit `childUids[]`: the flat form has lower agent parse cost (no recursion), matches the existing parallel-array convention, and — because nesting is bounded to one level in v1 — a single `parentUid` edge is sufficient to reconstruct the hierarchy. The recursive union is the natural extension point if multi-level nesting is ever admitted (see `boundaries.md` Future Considerations).

### 4. `uid → source` — the runtime-created-container case

Grouping mints a **new container that does not yet exist in source**. This is a new row in the [uid → source mapping](../data-contracts.md#uid--source-mapping) (case **(d)**, defined authoritatively there):

- The content script wraps the selected siblings in a **runtime-created** wrapper element and mints it a **fresh `uid`** (no build-time origin). The `GroupChange` carries this fresh `wrapperUid` and stamps `data-fe-layout` on the wrapper.
- The applier **creates new source** for the wrapper — a JSX container element (with the `data-fe-layout` signal and the conforming flex/grid styles) wrapping the source nodes of the grouped children — anchored via the group's `prevSibling`/`nextSibling` anchors, exactly as `stable-element-identity` case (c) creates source at an anchor.
- **The round-trip gap.** After apply + hot-reload, the dev-plugin re-processes the new JSX and stamps a **build-time `uid`** on the wrapper — which differs from the runtime fresh `uid`. The applier / reconciliation re-associates the two by the **stable child-uid set** carried on `GroupChange.wrappedUids`: the container whose `childUids[]` is a **superset of** `wrappedUids` is the same logical container even under a new wrapper `uid` (superset, not exact-match, so a child inserted/removed inside the group before the reload does not defeat re-association). Re-association is attempted on the first post-reload `MutationObserver` tick; failing a superset match, the wrapper is keyed by its build-time `uid` as a new anonymous container. (The children keep their identities across the wrap — grouping moves existing nodes, it does not re-mint them.) The [`data-fe-uid` reconciliation aids](../data-contracts.md#stamping-lifecycle) (lazy-uid walk + optional `WeakMap<Element, uid>` sidecar) are the runtime mechanism that recovers the wrapper's identity across the reload; the child-uid set is the **key** that survives the uid swap.

## The flat-data group problem (acceptance-defining)

**A group is only representable when it has a real structural boundary.** In the Levantine modal, the two-up "group" exists only as a flat `projects.json` array where two entries carry an implicit `width:"half"` — there is **no container in the DOM and none in the source**. There is nothing for a `LayoutContainerDescriptor` to key on, nothing for the applier to wrap, and no `data-fe-layout` carrier.

The contract therefore states, normatively:

> **Conforming grouping requires a real structural boundary.** A group must be backed by **both**:
> 1. a **container element** in the rendered JSX (a real DOM node that carries `data-fe-uid` and, when authored/stamped, `data-fe-layout`), **and**
> 2. where the items are data-driven, a **nested data sub-array** (the grouped items live in their own array/object, not as sibling entries distinguished only by a presentational flag like `width:"half"`).

This means the **code-gen convention governs the data shape, not only the JSX**. When the applier is asked to create a group over data-driven items that are currently flat siblings, it must (a) introduce a nested sub-array in the data source and (b) render a real container element over it — not emit a container that wraps a `.map()` slice by index, which would desynchronize on the next data edit. Migrating the Levantine modal to satisfy this — `projects.json` gains a nested sub-array for the two-up, and `page.tsx` renders a real container element with `data-fe-layout` — is the first conformance example (Brief 2).

An editor that encounters a would-be group with **no** structural boundary (flat data, no container) must **not** synthesize a phantom group; it surfaces the item as ungroupable (or offers to create the structural boundary via the convention). Silently grouping by index is the failure mode this rule forbids.

## Shared source of truth + code-gen convention

The machine-checkable form of this contract is **`packages/shared/src/layout.ts`** (named here, **created in Brief 2**). It is the single module both the capture layer and any convention validation compile against, and it exports:

- `DATA_FE_LAYOUT_ATTR = 'data-fe-layout'` — the attribute name constant.
- `LayoutContainerDescriptor` — the interface in §3.
- `LayoutRole` — the `'flow' | 'absolute' | 'group'` union.
- `parseLayoutSignal(el: Element): LayoutContainerDescriptor | null` — resolves a container to its descriptor (explicit signal first, thresholded heuristic second), returning `null` for non-lists.
- The heuristic threshold constants (min child count = 2) and the homogeneity predicate.

### Code-gen convention (agent-facing) — normative

This is the convention the applier / code-gen follows to write **conforming source** from a structural diff. It is a **spec section, not a floating doc**, precisely so it cannot drift silently from the schema in `layout.ts`:

1. **An editable list is a real container element** with the conforming `display:flex|grid` styling and, when the list was authored/marked authoritative, a `data-fe-layout="flex|grid"` attribute. Do not represent a list as bare sibling elements distinguished only by a presentational flag.
2. **Reorder writes source order.** A `flow` child reorder is applied by re-ordering the corresponding source nodes (JSX siblings or the backing data-array entries) — never by injecting `order:` CSS, which would desync source order from visual order.
3. **Group creates a structural boundary, over `flow` children only.** Grouping targets `layoutRole: flow` peers — never `absolute` (positioned/parallax) children. Per [the flat-data rule](#the-flat-data-group-problem-acceptance-defining): a real container element **and**, for data-driven items, a nested data sub-array. Stamp `data-fe-layout` on the created container.
4. **`absolute` children are never reordered or gap-adjusted.** A `layoutRole: absolute` peer (parallax / explicitly-placed) keeps its selector-anchored representation (feature-009); the applier never rewrites its position from a reorder index.
5. **Grid reorder is bounded.** Only auto-placed grid children (source-order = visual-order) reorder in v1, committed as source-order changes exactly like flex. Explicitly-placed grid children are `layoutRole: absolute` and are not reorder targets — the applier rejects a grid reorder that would require rewriting explicit `grid-area` placement rather than guessing (see [`boundaries.md`](../boundaries.md)).
6. **Everything keys on `uid`.** `containerUid`, `childUids[]`, `wrapperUid`, and the grouped children all resolve via the [`uid → source mapping`](../data-contracts.md#uid--source-mapping), including the runtime-created-container case (d).

## Constraints

- Spec-writing brief — **no product code changes** in this brief (1 of 2). Child mode permits editing `docs/spec/compiled/`.
- All schema deltas are **additive-optional**: no existing required field is redefined, and there is **no `WS_PROTOCOL_VERSION` bump** (stays `0.4.0`) — same treatment as `reorderChanges` / `uid` / `assetPath` before it. Pre-contract consumers ignore the new fields and degrade to `selector` targeting + flat (all-`flow`) behavior.
- Must not break the #27 (`data-fe-uid`) identity contract or the #28/#29 asset model already ratified in `data-contracts.md`.
- **Bounded** (mirrors feature-009's enum-bounding): one nesting level; flex + wrap covered; grid detected with grid-reorder enumerated-or-deferred; parallax stays feature-009's contract. This is **not** a universal layout IR — see the explicit OUT list in [`boundaries.md`](../boundaries.md).
- Decision 0035 (selective spec loading); Decision 0014 (phase model); Decision 0038 (handoff bundle). Assumes `manifest.json` active = `v1`.

## Open Questions

- **Grid explicit-placement reorder** — deferred in v1 (see `boundaries.md`). Whether v1.1 admits `grid-area` swap vs. source-order-plus-auto-placement is enumerated but not decided; both are recorded so the build brief does not have to re-derive them.
- **`data-fe-layout` value granularity** — v1 carries only the layout **kind** (`flex`/`grid`). Whether it should also carry direction (`row`/`column`) is deferred; direction is already available at runtime via `containerDirection`, so duplicating it on the attribute is not required in v1.
- **Multi-level nesting** — bounded to one level in v1; the recursive `leaf | group` union (the rejected alternative in §3) is the extension point if it is ever admitted.

## Acceptance Criteria

- [ ] `data-contracts.md` defines the **`data-fe-layout` editable-list signal**: runtime/opt-in explicit authority **plus** the thresholded computed-style heuristic (`display:flex|grid` ∧ child-count ≥ 2 ∧ tag/uid homogeneity) **plus** the `position:absolute|fixed` (and explicitly-placed grid) exclusion.
- [ ] `data-contracts.md` defines **`layoutRole: flow | absolute | group`** with the reorderable / gap-math / diff-hidden semantics in §2, and states its additive-optional default (`flow`).
- [ ] `data-contracts.md` defines the **nested-group-as-peer wire shape** — `LayoutContainerDescriptor` with explicit `childUids[]` on `VisualDiff.layoutContainers[]` — and documents the recursive-union alternative as considered/rejected.
- [ ] `data-contracts.md` adds **`containerUid?` to `ReorderChange`** and **`sourceContainerUid?` / `targetContainerUid?` to `ReparentChange`**, all additive-optional, **no `WS_PROTOCOL_VERSION` bump**.
- [ ] `data-contracts.md` `uid → source` mapping gains the **runtime-created-container case (d)** with the child-uid-set re-association after hot-reload.
- [ ] `data-contracts.md` closes the pre-existing gap with **formal base tables for `ReorderChange`, `GroupChange`, and `RemoveChange`** (previously footnoted to `diff.ts` only), so the new fields layer onto a contracted schema.
- [ ] feature-010 states the **flat-data group requirement** (structural boundary in **data + JSX**) and names it acceptance-defining.
- [ ] **`packages/shared/src/layout.ts`** is named as the shared source of truth (built in Brief 2), and the **agent-facing code-gen convention lives as this feature-010 section**, not a floating doc.
- [ ] `boundaries.md` records the v1 bound (one nesting level; flex + wrap; grid detected, grid-reorder enumerated-or-deferred; parallax unchanged) and an explicit **OUT** list.
- [ ] Cross-reference links resolve from feature-001 / feature-004 / feature-008 / feature-009 to feature-010, and feature-010 is registered in `manifest.json` `featureFiles`.
- [ ] spec-compiled governance evidence updated.

## Internal Design
<!-- Spec-first ratification brief — the contract IS the deliverable. Detailed
     component/interface design lives in the build brief (2 of 2). The design
     decisions ratified here: -->

### Components
- **Shared layout module** (`packages/shared/src/layout.ts`, Brief 2) — `DATA_FE_LAYOUT_ATTR`, `LayoutRole`, `LayoutContainerDescriptor`, `parseLayoutSignal`, threshold constants + homogeneity predicate.
- **Diff payload schema** (`packages/shared/src/diff.ts`, Brief 2) — `layoutRole?` on the per-child context shapes `SiblingAnchor` and `ChildSnapshotEntry`; `layoutContainers?: LayoutContainerDescriptor[]` on `VisualDiff`; `containerUid?` on `ReorderChange`; `sourceContainerUid?`/`targetContainerUid?` on `ReparentChange`; `wrapperUid?` **and** `wrappedUids?` on `GroupChange`.
- **Content script** (feature-001/004 editing, Brief 2) — runtime `data-fe-layout` stamp + thresholded heuristic; per-child `layoutRole` classification; positioned-child exclusion; runtime-created-container fresh uid on group.
- **Applier / code-gen** (Claude Code apply path, Brief 2) — uid → source resolution incl. case (d); the code-gen convention above; the flat-data structural-boundary rule.

### Key Interfaces
Defined authoritatively in `data-contracts.md`: `LayoutContainerDescriptor`, `LayoutRole`, `ReorderChange.containerUid`, `ReparentChange.sourceContainerUid`/`targetContainerUid`, `VisualDiff.layoutContainers`, and the `uid → source` case (d). Shared runtime form: `packages/shared/src/layout.ts`.

### Data Flow
Build (dev-plugin stamps `data-fe-uid`/`data-source-*`) → runtime (content script observes containers, applies the editable-list signal — explicit `data-fe-layout` wins, else thresholded heuristic; classifies each child's `layoutRole`; mints `data-fe-layout` + fresh `uid` on runtime-created group wrappers) → capture (leveled reorder/group/insert diffs carrying `containerUid` + `layoutContainers[]` peer descriptors + `assetPath`/`label`) → WS (additive-optional, `0.4.0`) → MCP queue → applier (uid → source incl. case (d); writes conforming flex/grid source + `data-fe-layout` per the convention; grid-reorder bounded).

### Error Handling
- **Signal absent** (`data-fe-layout` / `containerUid` / `layoutContainers` missing): degrade to the computed-style gate + `containerSelector` + flat (all-`flow`) behavior — no regression vs. today.
- **Incidental flex wrapper** (nav/button/icon row): fails the child-count / homogeneity gate → not exposed as an editable list.
- **`absolute` child** (parallax / explicitly-placed): never enters reorder index math or gap-math; stays selector-anchored (feature-009).
- **Runtime-created-container uid mismatch after hot-reload**: resolved via case (d) child-uid-set re-association + the #27 lazy-uid / `WeakMap` reconciliation.
- **Flat-data would-be group** (no structural boundary): the editor does not synthesize a phantom group; it surfaces the item as ungroupable or offers to create the structural boundary per the convention.
- **Grid reorder beyond the ratified bound** (explicit `grid-area` placement): rejected, not guessed.
