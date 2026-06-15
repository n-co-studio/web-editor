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
 * attributes injected by @frontend-editor/dev-plugin.
 */
export interface ElementInfo {
  readonly selector: string;
  readonly tagName: string;
  readonly textContent?: string;
  readonly sourceFile: string;
  readonly sourceLine: number;
  readonly instanceIndex?: number;
  readonly attributes: Readonly<Record<string, string>>;
  readonly boundingRect: BoundingRect;
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
 * A reorder operation — moves a child element within the same parent container.
 * Stored as a parallel array on VisualDiff (separate from PropertyChange[]).
 */
export interface ReorderChange {
  readonly type: 'reorder';
  readonly fromIndex: number;
  readonly toIndex: number;
  readonly siblingSelectors: string[];
  readonly containerSelector: string;
  readonly containerDirection: string;
}

/** Identifies a sibling element adjacent to an insert position. */
export interface SiblingAnchor {
  readonly selector: string;
  readonly sourceFile: string;
  readonly sourceLine: number;
  readonly instanceIndex?: number;
}

/** Snapshot of an existing child in the target container (for context). */
export interface ChildSnapshotEntry {
  readonly tagName: string;
  readonly selector: string;
  readonly sourceFile: string;
  readonly sourceLine: number;
  readonly instanceIndex?: number;
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
   * markup rather than an empty `<tagName>`.
   */
  readonly outerHTML?: string;
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
 * An HTML attribute change (e.g. src, alt) on the target element.
 * Stored as a parallel array on VisualDiff (separate from CSS PropertyChange[]).
 */
export interface AttributeChange {
  readonly type: 'attribute';
  readonly attribute: string;
  readonly fromValue: string;
  readonly toValue: string;
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
