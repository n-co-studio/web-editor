/**
 * Bounding rectangle — serializable alternative to DOMRect.
 * DOMRect is not structuredClone-able and does not exist in Node.js.
 */
export interface BoundingRect {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
  readonly top: number;
  readonly right: number;
  readonly bottom: number;
  readonly left: number;
}

/**
 * Identifies the DOM element that was visually edited.
 * sourceFile and sourceLine come from data-source-file / data-source-line
 * attributes injected by @nco-studio/web-editor-plugin.
 */
export interface ElementInfo {
  /**
   * Canonical diff-targeting key — the stable, per-instance element identity
   * read from the `data-fe-uid` attribute (feature-006 stamps it at build, the
   * content script assigns/repairs it at runtime). Unique per DOM instance: a
   * clone receives a *fresh* uid, so duplicate-then-edit no longer collides
   * (issue #27). Optional only for backward compatibility — absent for
   * `sourceVerified: false` nodes not yet lazily stamped and for pre-uid queued
   * payloads, where consumers degrade to `selector` targeting.
   * `sourceFile`/`sourceLine` are code-map hints, never identity.
   */
  readonly uid?: string;
  readonly selector: string;
  readonly tagName: string;
  readonly textContent?: string;
  readonly sourceFile: string;
  readonly sourceLine: number;
  readonly instanceIndex?: number;
  readonly attributes: Readonly<Record<string, string>>;
  readonly boundingRect: BoundingRect;
  /**
   * Resolved, public-relative served asset path (e.g. `/images/hero.jpg`) when
   * this element carries an asset — its `src` or inline `background-image`,
   * normalized through `resolvePublicSrc` (issue #29). Present **only** when an
   * asset actually resolves: absent for non-image carriers, and never a `data:`
   * or `blob:` URI (Brief 1 / #28 guarantees a served path, not inline bytes).
   * Lets a downstream agent map `uid → /images/<file>` from the payload alone,
   * with no working-tree correlation.
   */
  readonly assetPath?: string;
  /**
   * Short human label for the resolved asset — filename stem > `alt` > trimmed
   * text (≤40) > tagName (issue #29). Emitted **together with** `assetPath`
   * (both present or both absent).
   */
  readonly label?: string;
}

/**
 * Lightweight element reference for notes — subset of ElementInfo
 * without viewport-specific data (boundingRect, attributes).
 */
export interface NoteElementRef {
  readonly selector: string;
  readonly tagName: string;
  readonly textContent?: string;
  readonly sourceFile: string;
  readonly sourceLine: number;
  readonly instanceIndex?: number;
  /**
   * Resolved served asset path + short label for the referenced element (issue
   * #29). Same semantics as [ElementInfo.assetPath] / [ElementInfo.label]:
   * populated only when the referenced element resolves to a served asset, so a
   * numbering note over a gallery renders `N → /images/<file>` from the payload.
   */
  readonly assetPath?: string;
  readonly label?: string;
}

/** A note with optional element references. */
export interface NoteEntry {
  readonly text: string;
  readonly elements: readonly NoteElementRef[];
}

/**
 * Provenance for a CSS declaration that currently sets a property on an element.
 * Captures the cascade winner at the moment the edit was made so a downstream
 * agent can edit the existing rule in-place (preserving its @media / @layer /
 * @supports scope) instead of appending an override declaration.
 *
 * Absence of `source` on a PropertyChange means no existing rule sets the
 * property — the agent should write a new declaration at an appropriate site.
 */
export interface RuleSource {
  readonly selector: string;
  readonly sourceHref: string | null;
  readonly sourceIndex: number;
  readonly specificity: readonly [number, number, number];
  readonly isInline: boolean;
  readonly mediaQuery?: string;
  readonly layerName?: string;
}

/**
 * A RuleSource collected by the cross-breakpoint walk that captures rules
 * defined under viewport-bound `@media` blocks regardless of whether the
 * block currently matches the viewport. `matchesCurrentViewport` distinguishes
 * the active subset from the dormant subset so a downstream agent can reason
 * about responsive rules without switching viewports.
 *
 * `allBreakpointSources` is context-only. The active edit applies only to the
 * breakpoint identified by `PageContext.breakpoint` / `breakpointValue`; rules
 * at other breakpoints must not be modified unless the operator's instruction
 * explicitly requests it.
 */
export interface CrossBreakpointRuleSource extends RuleSource {
  readonly matchesCurrentViewport: boolean;
}

/**
 * A single CSS property change.
 * Property is always a CSS longhand name — shorthand expansion
 * happens at the extension layer before diff creation.
 *
 * `source` identifies the existing rule (if any) that currently sets this
 * property, including its `@media` / `@layer` context. Downstream agents
 * should edit the source rule in-place when present to avoid CSS bloat.
 */
export interface PropertyChange {
  readonly property: string;
  readonly fromValue: string;
  readonly toValue: string;
  readonly fromToken?: string;
  readonly toToken?: string;
  readonly unit?: string;
  readonly source?: RuleSource;
  readonly allBreakpointSources?: readonly CrossBreakpointRuleSource[];
}

/**
 * Structural classification of a direct child of an editable list (feature-010).
 * `flow` — a normal in-flow reorder/group target (the default when absent, so a
 * consumer that ignores the field sees the pre-contract flat behavior). `absolute`
 * — a `position: absolute|fixed` child (the parallax case) or an explicitly-placed
 * grid child: a visible, selectable, never-diff-hidden peer that is nonetheless
 * excluded from reorder index math and gap-math. `group` — a child that is itself
 * an editable-list container, exposed as an opaque peer at its parent's level.
 * See data-contracts.md → Structural Auto-Layout.
 */
export type LayoutRole = 'flow' | 'absolute' | 'group';

/**
 * A self-describing descriptor for one editable-list container (feature-010),
 * carried on the additive-optional `VisualDiff.layoutContainers[]` array. A
 * `layoutRole: group` child appears twice, additively: once as an opaque peer in
 * its parent's `childUids[]` (so a parent-level reorder moves the whole group as
 * one item), and once as its own descriptor here (so the group's internals are
 * self-describing without a recursive tree on the wire). Bounded to one nesting
 * level in v1 — a single `parentUid` edge reconstructs the hierarchy from the flat
 * array. See data-contracts.md → LayoutContainerDescriptor.
 */
export interface LayoutContainerDescriptor {
  /** The container's own `data-fe-uid`. */
  readonly uid: string;
  /** Layout kind, from `data-fe-layout` (explicit) or resolved computed style (heuristic). */
  readonly layout: 'flex' | 'grid';
  /**
   * The container's `containerDirection` — primary axis, with the ` wrap` suffix
   * for wrapped containers (`"row wrap"`, issue #30). First token is always the axis.
   */
  readonly direction: string;
  /**
   * `data-fe-uid`s of the container's direct children, in visual order — all of
   * them (flow + absolute + group), so a non-flow peer (parallax) is never hidden
   * from the structural model. A child that is itself a group appears here as its
   * `uid` and has its own descriptor entry elsewhere in `layoutContainers[]`.
   */
  readonly childUids: readonly string[];
  /**
   * `data-fe-uid` of the enclosing editable-list container. Absent for the
   * top-level container. The single edge that reconstructs the (one-level) nesting.
   */
  readonly parentUid?: string;
  /**
   * This descriptor's role in its parent list — `group` when nested as a peer
   * inside another editable list; absent/`flow` for the top-level container.
   * Deliberately omits `absolute` (a container is never a positioned peer).
   */
  readonly role?: 'flow' | 'group';
  /**
   * How the list was detected — `explicit` when `data-fe-layout` is authoritative
   * on the element, `heuristic` when detected from computed style. Tells the
   * applier whether it must stamp `data-fe-layout` on codegen.
   */
  readonly signalSource: 'explicit' | 'heuristic';
}

/**
 * A reorder operation — moves a child element within the same parent container.
 * Stored as a parallel array on VisualDiff (separate from PropertyChange[]).
 */
export interface ReorderChange {
  readonly type: 'reorder';
  readonly fromIndex: number;
  readonly toIndex: number;
  readonly siblingSelectors: string[];
  /**
   * Per-sibling anchors parallel to `siblingSelectors`, each carrying `uid`
   * plus a resolved `assetPath`/`label` when the sibling is an asset (issue
   * #29). This is what makes a gallery reorder actionable from the payload
   * alone — `N → /images/<file>` per reordered image. Additive-optional:
   * `siblingSelectors` stays the canonical, always-present list, so consumers
   * that ignore `siblingAnchors` are unaffected; it may also be absent or
   * shorter than `siblingSelectors` when siblings carry no asset context.
   */
  readonly siblingAnchors?: readonly SiblingAnchor[];
  readonly containerSelector: string;
  readonly containerDirection: string;
  /**
   * Editable-list container identity (feature-010) — `data-fe-uid` of the
   * container the reorder happened in, the `uid`-keyed peer of `containerSelector`.
   * When present, the applier resolves the container to source by `uid` (stable
   * across re-render/reorder) instead of the positional selector. Additive-optional;
   * absent for pre-feature-010 payloads and containers with no `uid`, where the
   * applier falls back to `containerSelector`. The reorder targets are the
   * container's `layoutRole: flow` peers only — `absolute` children (parallax /
   * explicitly-placed) are excluded from `fromIndex`/`toIndex` math.
   */
  readonly containerUid?: string;
}

/** Identifies a sibling element adjacent to an insert position. */
export interface SiblingAnchor {
  /**
   * Canonical anchor identity — `data-fe-uid` of the sibling. When present,
   * insert/reparent/group anchors resolve by `uid` (stable across re-render and
   * reorder); when absent, `selector` + the `sourceFile`/`sourceLine` hints are
   * used. This is the value `InsertChange.anchorUid` references. (issue #27)
   */
  readonly uid?: string;
  readonly selector: string;
  readonly sourceFile: string;
  readonly sourceLine: number;
  readonly instanceIndex?: number;
  /**
   * Resolved served asset path + short label for the anchor element (issue
   * #29). Same both-or-neither semantics as [ElementInfo.assetPath]: an
   * insert/reparent/group anchored to a gallery image carries its
   * `/images/<file>` so the anchor is identifiable without DOM correlation.
   */
  readonly assetPath?: string;
  readonly label?: string;
  /**
   * Structural classification of this anchored child within its editable list
   * (feature-010). `flow` (default when absent) / `absolute` (positioned peer,
   * excluded from reorder & gap-math) / `group` (nested container peer). This is
   * the per-child carrier of the child's role — a `flow`/`group` peer records it
   * here; a `group` child's role is additionally recoverable via its own
   * `LayoutContainerDescriptor`. Additive-optional.
   */
  readonly layoutRole?: LayoutRole;
}

/** Snapshot of an existing child in the target container (for context). */
export interface ChildSnapshotEntry {
  /**
   * Per-instance identity (`data-fe-uid`) of the snapshotted child. Two clones
   * in a childSnapshot previously shared one `sourceLine`; with `uid` each entry
   * is distinct so the applier can tell the original from the duplicate (issue
   * #27). Optional for backward compatibility.
   */
  readonly uid?: string;
  readonly tagName: string;
  readonly selector: string;
  readonly sourceFile: string;
  readonly sourceLine: number;
  readonly instanceIndex?: number;
  /**
   * Resolved served asset path + short label for the snapshotted child (issue
   * #29). Same both-or-neither semantics as [ElementInfo.assetPath]: an image
   * child in the target container carries its `/images/<file>` so the applier
   * can reason about sibling assets from the snapshot alone.
   */
  readonly assetPath?: string;
  readonly label?: string;
  /**
   * Structural classification of the snapshotted child within its editable list
   * (feature-010). `flow` (default when absent) / `absolute` / `group`.
   * Additive-optional — see [LayoutRole].
   */
  readonly layoutRole?: LayoutRole;
}

/** Describes a child element to create as part of a compound insert. */
export interface CompoundChildDescriptor {
  readonly tagName: string;
  readonly textContent?: string;
  /** Inline styles applied to this child (e.g. flex weights for layout presets). */
  readonly styles?: readonly { property: string; value: string }[];
  readonly children?: readonly CompoundChildDescriptor[];
}

/**
 * A group operation — wraps 2+ sibling elements in a new flex container.
 * Stored as a parallel array on VisualDiff (separate from PropertyChange[]).
 * Natural inverse is ungroup (unwrap).
 */
export interface GroupChange {
  readonly type: 'group';
  readonly wrapperTagName: string;
  readonly wrapperInitialStyles: readonly PropertyChange[];
  readonly containerSelector: string;
  readonly insertIndex: number;
  readonly wrappedSelectors: readonly string[];
  readonly prevSibling: SiblingAnchor | null;
  readonly nextSibling: SiblingAnchor | null;
  /**
   * Runtime-created-container identity (feature-010) — the **fresh** `data-fe-uid`
   * minted for the wrapper at group time (the wrapper has no build-time origin).
   * Carries the wrapper's identity into the diff so the applier can key the created
   * source node and reconcile it after hot-reload via the child-uid-set
   * re-association (uid → source mapping case (d)). When authored/authoritative,
   * the applier also stamps `data-fe-layout` on the created container.
   * Additive-optional.
   */
  readonly wrapperUid?: string;
  /**
   * `data-fe-uid`s of the wrapped children, positionally parallel to
   * `wrappedSelectors` (feature-010). The stable child-`uid` set the
   * runtime-created-container round-trip (case (d)) keys re-association on: after
   * hot-reload the container whose `childUids[]` is a superset of `wrappedUids`
   * is identified as the same logical container even under a new build-time
   * wrapper `uid`. Additive-optional; the applier falls back to the created
   * container's `LayoutContainerDescriptor.childUids[]`, else to `wrappedSelectors`.
   */
  readonly wrappedUids?: readonly string[];
}

/**
 * A reparent operation — moves an element from one container to another.
 * Stored as a parallel array on VisualDiff (separate from PropertyChange[]).
 * Natural inverse is reparent back to the source container at the original index.
 */
export interface ReparentChange {
  readonly type: 'reparent';
  readonly sourceContainerSelector: string;
  readonly sourceIndex: number;
  readonly targetContainerSelector: string;
  readonly targetIndex: number;
  readonly siblingSelectors: readonly string[];
  readonly prevSibling: SiblingAnchor | null;
  readonly nextSibling: SiblingAnchor | null;
  /**
   * Source editable-list container identity (feature-010) — `data-fe-uid` of the
   * source container, the `uid`-keyed peer of `sourceContainerSelector`. The
   * applier falls back to the selector when absent. Additive-optional.
   */
  readonly sourceContainerUid?: string;
  /**
   * Target editable-list container identity (feature-010) — `data-fe-uid` of the
   * target container, the `uid`-keyed peer of `targetContainerSelector`. The
   * applier falls back to the selector when absent. Additive-optional.
   */
  readonly targetContainerUid?: string;
}

/**
 * A prop's default value extracted from a component's signature.
 * v1 always emits an empty array on ComponentInsertDescriptor; PropDefault is
 * reserved for the v1.1 prop editor and shipped now to avoid a contract migration.
 */
export interface PropDefault {
  readonly name: string;
  readonly type: 'string' | 'number' | 'boolean' | 'string-union' | 'unknown';
  readonly defaultValue?: string;
  readonly unionValues?: readonly string[];
  readonly tokenCategory?: TokenCategory;
}

/**
 * Descriptor for inserting a project-local React component instead of a plain
 * HTML element. The receiving agent uses `componentName` + `importPath` to add
 * the JSX usage and the matching import at the source insertion point.
 */
export interface ComponentInsertDescriptor {
  readonly componentName: string;
  readonly importPath: string;
  readonly props: readonly PropDefault[];
}

/**
 * An insert operation — creates a new element within a container.
 * Stored as a parallel array on VisualDiff (separate from PropertyChange[]).
 *
 * When `componentInsert` is present, the insert refers to a project-local
 * React component; `tagName` carries the phantom DOM placeholder (typically
 * `'div'`) and the receiving agent inserts the component identified by
 * `componentInsert` instead of a literal element.
 */
export interface InsertChange {
  readonly type: 'insert';
  readonly tagName: string;
  readonly insertIndex: number;
  readonly containerSelector: string;
  readonly prevSibling: SiblingAnchor | null;
  readonly nextSibling: SiblingAnchor | null;
  readonly sameSiblingSource: boolean;
  readonly crossFileInsertion: boolean;
  readonly initialStyles: readonly PropertyChange[];
  readonly childSnapshot?: readonly ChildSnapshotEntry[];
  readonly compoundChildren?: readonly CompoundChildDescriptor[];
  readonly componentInsert?: ComponentInsertDescriptor;
  /**
   * Full serialized HTML of the inserted element, including its entire subtree.
   * Carried for clone/paste/duplicate inserts where the new element reproduces
   * an existing element verbatim — the receiving agent recreates the exact
   * markup rather than an empty `<tagName>`. For clone/paste inserts this markup
   * carries *freshly regenerated* `data-fe-uid`s (root + every descendant), so
   * the inserted instance is independently addressable (issue #27).
   */
  readonly outerHTML?: string;
  /**
   * Source-anchored insert addressing (issue #27). The `uid` of the existing
   * sibling the new element is positioned relative to — equal to the chosen
   * `prevSibling`/`nextSibling` `SiblingAnchor.uid`. Replaces fragile positional
   * `nth-of-type` resolution. Optional/all-or-nothing with `anchorPosition`:
   * when absent, the applier falls back to `insertIndex` + sibling selectors +
   * `containerSelector`.
   */
  readonly anchorUid?: string;
  /**
   * Side of `anchorUid` the new element occupies. Required when `anchorUid` is
   * present; ignored otherwise. `"after"` mirrors a `prevSibling`-anchored
   * insert, `"before"` a `nextSibling`-anchored insert.
   */
  readonly anchorPosition?: 'before' | 'after';
}

/**
 * A remove operation — deletes an element from its container.
 * Stored as a parallel array on VisualDiff (separate from PropertyChange[]).
 * The target element is identified by VisualDiff.element (selector + sourceFile + sourceLine).
 */
export interface RemoveChange {
  readonly type: 'remove';
  readonly tagName: string;
  readonly containerSelector: string;
  readonly removedIndex: number;
}

/**
 * Metadata for a locally-picked asset whose bytes are deliberately NOT inlined
 * into the diff (issue #28). The media file picker emits a blob URL for live
 * preview and carries this side-channel instead of a multi-MB `data:` URI, so
 * the bridge can name/dedup the persisted asset from the original filename
 * rather than inferring it. Additive-optional — no `WS_PROTOCOL_VERSION` bump.
 */
export interface PendingUpload {
  /** The picked file's name (e.g. `hero.jpg`) — used to name/dedup the persisted asset. */
  readonly filename: string;
  /** The picked file's MIME type (e.g. `image/jpeg`). */
  readonly mimeType: string;
  /** The picked file's size in bytes — lets the server reason about the per-asset size cap. */
  readonly sizeBytes: number;
}

/**
 * An HTML attribute change (e.g. src, alt) on the target element.
 * Stored as a parallel array on VisualDiff (separate from CSS PropertyChange[]).
 */
export interface AttributeChange {
  readonly type: 'attribute';
  readonly attribute: string;
  readonly fromValue: string;
  readonly toValue: string;
  /**
   * Metadata for a file-picker-selected asset (issue #28). When present, the
   * asset was picked locally and its bytes were never inlined: `toValue` is a
   * provisional served path (`/images/<filename>`), and the bridge persists /
   * dedups the asset server-side using `pendingUpload.filename`, rewriting
   * `toValue` to the final `/images/<name>`. Additive-optional — no protocol bump.
   */
  readonly pendingUpload?: PendingUpload;
  /**
   * Set by the server when an asset exceeded the per-asset size cap and could
   * not be resolved to a served path: `toValue` is emptied rather than carrying
   * a multi-MB inline blob (issue #28). The applier should treat the attribute
   * as unresolved (leave the existing reference in place / surface to the
   * operator) rather than writing an empty `src`. Additive-optional — no bump.
   */
  readonly assetTruncated?: boolean;
}

/**
 * A text content change — modifies the textContent of an element.
 * Stored as a parallel array on VisualDiff (separate from CSS PropertyChange[]).
 */
export interface TextChange {
  readonly type: 'text';
  readonly fromText: string;
  readonly toText: string;
}

/**
 * A single CSS rule block carried inside a StylesheetChange. `cssText` is the
 * authoritative, ready-to-write rule text; the structured fields let a
 * downstream agent place, dedupe, or rewrite the rule without re-parsing it.
 * Introduced by feature-009 (parallax editor) for scroll-driven animations
 * and the mandatory prefers-reduced-motion zeroing rule.
 */
export interface StylesheetRule {
  readonly ruleType: 'keyframes' | 'supports' | 'media';
  /** For ruleType 'keyframes', the @keyframes identifier (unique per edit). */
  readonly name?: string;
  /** For ruleType 'supports' / 'media', the parenthesized condition. */
  readonly condition?: string;
  /** Full rule text including the at-rule header and braces. */
  readonly cssText: string;
}

/**
 * A change that adds one or more document-level CSS rules that cannot be
 * expressed as element-inline declarations (@keyframes, @supports, @media).
 * Stored as a parallel array on VisualDiff (separate from PropertyChange[]).
 */
export interface StylesheetChange {
  readonly type: 'stylesheet';
  /** Document-level rules to add. Order is significant. */
  readonly rules: readonly StylesheetRule[];
  /**
   * Element-level longhands that wire the target element to the rules
   * (animation-name, animation-timeline, etc.). Always present — an empty
   * array is valid (e.g. a standalone reduced-motion rule); an absent array
   * is a protocol error.
   */
  readonly elementChanges: readonly PropertyChange[];
  readonly reason: string;
}

/** Parameters a source author needs to reproduce a script behavior deterministically. */
export interface ScriptBehaviorParams {
  readonly axis: 'x' | 'y';
  /** Scroll multiplier derived from --parallax-strength. Range 0–1. */
  readonly strengthFactor: number;
  readonly throttle: 'raf';
  /**
   * Which element's scrolling drives the effect. `'window'` for page/viewport
   * scroll; otherwise a CSS selector for the scroll container (e.g. an inner
   * overlay/`<main>` that scrolls while `body` does not). The generated handler
   * must attach its scroll listener to this source, not assume `window`.
   */
  readonly scrollSource: string;
}

/**
 * A declarative descriptor for a bounded, reproducible-to-source JS behavior.
 * Carries intent + parameters, never literal JS. v1 admits exactly one
 * behavior — 'parallax-scroll' (feature-009). Stored as a parallel array on
 * VisualDiff.
 */
export interface ScriptBehaviorChange {
  readonly type: 'script-behavior';
  readonly behavior: 'parallax-scroll';
  readonly targetSelector: string;
  readonly sourceFile: string;
  readonly params: ScriptBehaviorParams;
  /** Always true in v1 — generated handler short-circuits under reduced-motion. */
  readonly respectsReducedMotion: boolean;
  readonly descriptor: string;
  readonly reason: string;
}

/** Page state at the time of edit. */
export interface PageContext {
  readonly url: string;
  readonly viewport: Readonly<{ width: number; height: number }>;
  readonly breakpoint?: string;
  readonly breakpointValue?: string;
  readonly tabId: string;
}

export type DiffStatus = 'pending' | 'applied' | 'rejected';

/**
 * A property change on a related element required by the primary edit.
 * E.g., adding `isolation: isolate` to a parent when blend mode is applied.
 */
export interface RelatedChange {
  readonly element: ElementInfo;
  readonly changes: readonly PropertyChange[];
  readonly reason: string;
}

/**
 * A complete visual diff — the primary data unit flowing from
 * Chrome extension → MCP server → Claude Code.
 */
export interface VisualDiff {
  readonly id: string;
  readonly timestamp: string;
  /**
   * Batch identity — minted once per Apply-Changes click, shared by every
   * diff dispatched in that logical batch. Additive-optional: absent for
   * diffs created before batch identity was introduced; consumers degrade
   * gracefully to flat-pool processing. No WS_PROTOCOL_VERSION bump.
   */
  readonly batchId?: string;
  readonly element: ElementInfo;
  readonly changes: readonly PropertyChange[];
  readonly reorderChanges?: readonly ReorderChange[];
  readonly insertChanges?: readonly InsertChange[];
  readonly removeChanges?: readonly RemoveChange[];
  readonly groupChanges?: readonly GroupChange[];
  readonly reparentChanges?: readonly ReparentChange[];
  readonly attributeChanges?: readonly AttributeChange[];
  readonly textChanges?: readonly TextChange[];
  readonly relatedChanges?: readonly RelatedChange[];
  readonly stylesheetChanges?: readonly StylesheetChange[];
  readonly scriptChanges?: readonly ScriptBehaviorChange[];
  /**
   * Editable-list container descriptors (feature-010) referenced by any structural
   * change in this diff — the self-describing shape for the container a reorder /
   * group happened in and, for a nested group, its own descriptor. `childUids[]`
   * enumerates every direct child in visual order (so a `layoutRole: absolute`
   * peer is visible, never diff-hidden). Additive-optional: absent for
   * pre-feature-010 payloads, where consumers degrade to `containerSelector`
   * targeting and flat (all-`flow`) behavior. No `WS_PROTOCOL_VERSION` bump.
   */
  readonly layoutContainers?: readonly LayoutContainerDescriptor[];
  readonly context: PageContext;
  readonly status: DiffStatus;
  readonly sourceVerified: boolean;
}

export type TokenCategory =
  | 'spacing'
  | 'typography'
  | 'colors'
  | 'radii'
  | 'shadows'
  | 'breakpoints';

/** A design token parsed from the target project's design system. */
export interface DesignToken {
  readonly name: string;
  readonly category: TokenCategory;
  readonly value: string;
  readonly cssProperties: readonly string[];
  readonly source: string;
}
