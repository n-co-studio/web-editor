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
 * A single CSS property change.
 * Property is always a CSS longhand name — shorthand expansion
 * happens at the extension layer before diff creation.
 */
export interface PropertyChange {
  readonly property: string;
  readonly fromValue: string;
  readonly toValue: string;
  readonly fromToken?: string;
  readonly toToken?: string;
  readonly unit?: string;
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
 * An insert operation — creates a new element within a container.
 * Stored as a parallel array on VisualDiff (separate from PropertyChange[]).
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
