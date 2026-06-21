---
title: "Stable Element Identity (data-fe-uid)"
scope_modules:
  - compiled-spec/data-contracts
  - compiled-spec/features
  - dev-plugin
  - chrome-extension-content
  - shared-diff
  - mcp-server-apply
keywords:
  - data-fe-uid
  - uid
  - element-identity
  - duplicate
  - clone
  - source-anchored-insert
  - issue-27
spec_type: feature
---

# Feature Brief: Stable Element Identity (data-fe-uid)

## What
A stable, unique, per-instance element identity — `data-fe-uid` — that is the **canonical diff-targeting key** for every visual-diff change type (insert / reorder / attribute / text / reparent / remove). The diff payload surfaces it as `uid` on `ElementInfo`, `SiblingAnchor`, and `ChildSnapshotEntry`, and uses it to express **source-anchored inserts** (`InsertChange.anchorUid` + `anchorPosition`). `data-source-file` / `data-source-line` / `data-source-index` are demoted to **code-map hints** — they locate source, they never establish identity.

This brief (1 of 2 in the `stable-element-identity` task group) **ratifies the contract** in the compiled specs. It writes no product code. The build brief (2 of 2) implements the stamping lifecycle and the applier's uid→source resolution against this ratified contract.

## Why
The extension identifies tracked elements by `data-source-file` + `data-source-line`. When an operator **duplicates** an element, the clone is a DOM copy that inherits the **same `data-source-line`** as the original, so the two instances are indistinguishable in the diff payload (issue #27, reproduced in isolation at the capture layer — no agent/codegen involved). A single duplication is recoverable from `outerHTML` + `sameSiblingSource` + `prevSibling`, but the **second** operation on either twin can only reference the shared identity, so on replay the applier mis-targets and drops one twin: *"the image I duplicated first was deleted"*, *"the ordering is wrong."* `.map()` runtime instances carry the same latent collision (N nodes share one JSX line+index).

Ratifying the identity model **before** implementation matters because the uid→source mapping semantics are non-trivial and currently undefined, and the contract is read by the downstream applier. Spec-first prevents the build brief from coding against an unspecified contract (Architect / PM / Critic concurred at Prompt T).

## Prior Art
None (no prototype). Root cause confirmed from a real Repo OS editor-live capture (2026-06-21), extension web-embed `0.3.0`, Next.js dev with `@frontend-editor/dev-plugin/babel`. Source: GitHub issue #27.

## What It Touches
- [x] UI / Design System / User Flows — element selection surfaces identity (feature-001)
- [ ] Auth / Sessions / Permissions
- [ ] Database / Schema / Migrations
- [x] API Contracts / Data Models — `VisualDiff` identity shapes (`ElementInfo`, `SiblingAnchor`, `ChildSnapshotEntry`, `InsertChange`)
- [x] Real-time / WebSockets / Streaming — diff payload over WS (additive-optional, no protocol bump)
- [ ] Large Datasets / Media / File Processing
- [ ] Payments / Billing / Financial
- [ ] External Integrations / Third-party APIs
- [ ] Performance-Critical Paths

## Key Requirements
- `uid` is the canonical diff-targeting key on `ElementInfo`, `SiblingAnchor`, and `ChildSnapshotEntry`. `data-source-*` are code-map hints, never identity.
- A clone/duplicate/paste receives a **fresh** uid (deep — root and every descendant). The fresh uid is minted at creation, so the *next* operation already has stable identity.
- `InsertChange` carries a normative source-anchored model: `anchorUid` (a sibling `uid`) + `anchorPosition` (`before` | `after`), parallel to `ReparentChange`'s `prevSibling`/`nextSibling` anchors. Positional `nth-of-type` resolution is the fallback only.
- The applier resolves `uid` → source for three cases: **(a)** existing element → `sourceFile`+`sourceLine` hint, edit in place; **(b)** clone → fresh uid + `outerHTML` + origin `sourceLine` hint, applier *creates* new source near the origin (origin untouched); **(c)** fresh insert → `anchorUid` + position + `outerHTML`, applier creates source at the anchor.
- Stamping lifecycle: **build-time** dev-plugin stamp is primary (survives React reconciliation); **runtime** fresh-uid on clone/paste (deep subtree); **runtime** lazy uid for `.map()` runtime instances and `sourceVerified: false` nodes. A `WeakMap<Element, uid>` sidecar is an allowed reconciliation-resilience aid (attribute stays wire-format source of truth).
- Deployment-aware `src` normalization at capture: strip a single leading `/public` segment from root-relative paths; leave `data:` and `http(s)://` untouched.
- All new fields are **additive optional** — no `WS_PROTOCOL_VERSION` bump; pre-uid consumers degrade to `selector` targeting.

## Constraints
- This brief is **spec/docs only** — no product code. (Implementation is the build brief.)
- Keep the schema additive: do not redefine existing required fields in a way that breaks current payloads (`sourceFile`/`sourceLine` remain present and required; they are merely re-scoped as hints).
- Child mode permits editing `docs/spec/compiled/` (confirmed).

## Open Questions
- **WeakMap sidecar vs. attribute-only** for reconciliation resilience — ratified as an *option* the build brief may adopt; not mandated here.
- **uid value format** (deterministic build-time hash of `file:line[:index]` vs. opaque random runtime id) — the lifecycle requires per-instance uniqueness regardless of format; the exact scheme is a build-brief implementation choice, constrained only by "clones and `.map()` instances must be unique."

## Alternatives Considered
- **Pure build-time uid (hash of `file:line[:index]`).** Stamp a deterministic uid entirely at build, no runtime assignment. *Rejected as insufficient alone:* one JSX line inside a `.map()` renders N runtime nodes that would share a single hash, so build-time-only identity re-collides exactly where the bug lives. The lifecycle therefore keeps build-time as the *primary* (reconciliation-stable) source but layers runtime per-instance assignment for `.map()` fan-out, clones, and `sourceVerified:false` nodes. This is the reasoning behind the *"Why both build-time and runtime"* note in [data-contracts § Stamping lifecycle](../data-contracts.md#stamping-lifecycle).
- **Inline the spec update into the build brief (single brief).** The minimal path — the field delta is additive, so a single brief could amend `diff.ts` and the spec together. *Rejected for spec-first:* the contract is read by the downstream applier and the uid→source mapping semantics (three cases) are non-trivial and currently undefined. Ratifying first prevents the build brief from coding against an unsettled contract (Architect / PM / Critic concurred at Prompt T).
- **Keep `data-source-line` as identity, add a disambiguating counter.** *Rejected:* a counter layered on a source coordinate is still anchored to source location, not instance, and breaks again under reorder/reconciliation. Per-instance identity must be intrinsic to the instance (`data-fe-uid`), independent of where it maps in source.
- **Attribute-only vs. `WeakMap` sidecar for reconciliation resilience.** Ratified as an *option* (not mandated) — the attribute is the wire-format source of truth; a `WeakMap<Element, uid>` is an allowed runtime durability aid the build brief may adopt if reconciliation is observed to drop the attribute.

## Acceptance Criteria
- [ ] `data-contracts.md` defines `uid` on `ElementInfo`, `SiblingAnchor`, and `ChildSnapshotEntry`, and a normative `InsertChange` anchor table (`anchorUid` + `anchorPosition`).
- [ ] `data-contracts.md` contains a uid→source mapping section covering the existing / clone / fresh-insert cases.
- [ ] `data-contracts.md` documents the stamping lifecycle (build-time primary, runtime clone, runtime lazy for `.map()`/`sourceVerified:false`, WeakMap option) and deployment-aware `src` normalization.
- [ ] `feature-006` and `feature-001` reflect `data-fe-uid`; the protocol-compatibility note is updated (additive-optional, no version bump).
- [ ] spec-compiled governance evidence updated.

## Internal Design
<!-- Spec-first ratification brief — the contract IS the deliverable. Detailed
     component/interface design lives in the build brief (2 of 2). The design
     decisions ratified here: -->

### Components
- **Diff payload schema** (`packages/shared/src/diff.ts`, build brief) — `uid?` on `ElementInfo` / `SiblingAnchor` / `ChildSnapshotEntry`; `anchorUid?` + `anchorPosition?` on `InsertChange`.
- **Dev-plugin** (feature-006, build brief) — build-time `data-fe-uid` stamp.
- **Content script** (feature-001, build brief) — runtime fresh-uid on clone, lazy uid for `.map()`/unstamped nodes, optional `WeakMap` sidecar, deployment-aware `src` normalization at capture.
- **Applier** (Claude Code apply path, build brief) — uid→source resolution for the three cases.

### Key Interfaces
- `ElementInfo.uid?: string`, `SiblingAnchor.uid?: string`, `ChildSnapshotEntry.uid?: string`.
- `InsertChange.anchorUid?: string`, `InsertChange.anchorPosition?: 'before' | 'after'`.
- DOM contract: `data-fe-uid` attribute on every tracked element.

### Data Flow
Build (dev-plugin stamps `data-fe-uid`) → runtime (content script repairs/mints uids: lazy for `.map()`/unstamped, fresh-deep for clones) → capture (`ElementInfo.uid` + anchored `InsertChange`; `src` normalized) → WS (additive-optional, `0.4.0`) → MCP queue → applier (uid→source: edit existing / create-from-clone / create-at-anchor).

### Error Handling
- **uid absent** (pre-stamp `sourceVerified:false`, pre-uid consumer): degrade to `selector` targeting + positional insert — no regression vs. today.
- **Clone reuses origin uid** (the bug): forbidden by the fresh-deep mint rule; the build brief's clone path must walk the whole subtree.
- **Reconciliation drops the attribute**: optional `WeakMap` sidecar re-stamps; attribute remains source of truth.
- **`src` over-stripping**: only a single leading `/public` is stripped; `data:` and `http(s)://` are never touched.
