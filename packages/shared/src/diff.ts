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
 * A complete visual diff — the primary data unit flowing from
 * Chrome extension → MCP server → Claude Code.
 */
export interface VisualDiff {
  readonly id: string;
  readonly timestamp: string;
  readonly element: ElementInfo;
  readonly changes: readonly PropertyChange[];
  readonly reorderChanges?: readonly ReorderChange[];
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
