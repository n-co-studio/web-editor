import type {
  VisualDiff,
  ElementInfo,
  PropertyChange,
  AttributeChange,
  TextChange,
  ReorderChange,
  InsertChange,
  RemoveChange,
  GroupChange,
  ReparentChange,
  RelatedChange,
  StylesheetChange,
  ScriptBehaviorChange,
  PageContext,
  RuleSource,
  CrossBreakpointRuleSource,
} from '@nco-studio/shared';
import type { TokenStore } from '../tokens/store';

/**
 * Resolves the cascade-winning rule that currently sets a property on an
 * element. Returns undefined if no rule sets it (e.g. computed default,
 * UA stylesheet, or property being introduced fresh).
 */
export type RuleSourceResolver = (
  element: Element,
  property: string,
) => RuleSource | undefined;

/**
 * Resolves rules at non-active viewport breakpoints that declare a property
 * on an element. Returns undefined or an empty array when no such rules
 * exist (or when the resolver cannot run, e.g. CORS-tainted sheets).
 */
export type CrossBreakpointSourcesResolver = (
  element: Element,
  property: string,
) => readonly CrossBreakpointRuleSource[] | undefined;

/**
 * Assembles complete VisualDiff objects from editing results.
 * Handles UUID generation, timestamp, PageContext, sourceVerified flag,
 * client-side token resolution for fromToken/toToken fields, and source
 * provenance (which CSS rule currently owns each property — including
 * @media / @layer context).
 *
 * Source provenance is best-effort: when no resolver is configured or the
 * caller doesn't pass the live element, the `source` field is simply
 * omitted (signaling "no known owning rule") rather than failing the build.
 */
export class DiffBuilder {
  constructor(
    private readonly tabId: string,
    private readonly tokenStore: TokenStore,
    private readonly resolveRuleSource?: RuleSourceResolver,
    private readonly resolveCrossBreakpointSources?: CrossBreakpointSourcesResolver,
  ) {}

  /** Build a VisualDiff from an element and its property changes. */
  build(
    elementInfo: ElementInfo,
    changes: PropertyChange[],
    element?: Element,
  ): VisualDiff {
    return {
      id: crypto.randomUUID(),
      timestamp: new Date().toISOString(),
      element: elementInfo,
      changes: changes.map((c) => this.enrich(c, element)),
      context: this.buildPageContext(),
      status: 'pending',
      sourceVerified: Boolean(elementInfo.sourceFile),
    };
  }

  /** Build a VisualDiff for a reorder operation (no CSS property changes). */
  buildReorder(elementInfo: ElementInfo, reorderChange: ReorderChange): VisualDiff {
    return {
      id: crypto.randomUUID(),
      timestamp: new Date().toISOString(),
      element: elementInfo,
      changes: [],
      reorderChanges: [reorderChange],
      context: this.buildPageContext(),
      status: 'pending',
      sourceVerified: Boolean(elementInfo.sourceFile),
    };
  }

  /** Build a VisualDiff for an insert operation (no CSS property changes). */
  buildInsert(elementInfo: ElementInfo, insertChange: InsertChange): VisualDiff {
    return {
      id: crypto.randomUUID(),
      timestamp: new Date().toISOString(),
      element: elementInfo,
      changes: [],
      insertChanges: [insertChange],
      context: this.buildPageContext(),
      status: 'pending',
      sourceVerified: Boolean(elementInfo.sourceFile),
    };
  }

  /** Build a VisualDiff for a remove operation (no CSS property changes). */
  buildRemove(elementInfo: ElementInfo, removeChange: RemoveChange): VisualDiff {
    return {
      id: crypto.randomUUID(),
      timestamp: new Date().toISOString(),
      element: elementInfo,
      changes: [],
      removeChanges: [removeChange],
      context: this.buildPageContext(),
      status: 'pending',
      sourceVerified: Boolean(elementInfo.sourceFile),
    };
  }

  /**
   * Build a VisualDiff for an in-place element replacement (e.g. parallax:
   * <img> → parallax block). Carries both the remove of the old element and the
   * insert of the new one (with full outerHTML) in a single diff, so it has one
   * id for queue/undo and serializes as a coherent replace instruction.
   *
   * `extras` carries the document-level stylesheet rules (@keyframes,
   * @supports, @media) and the declarative script behavior that some parallax
   * mechanisms need (feature-009) — scroll-driven emits stylesheetChanges, and
   * js-scroll emits scriptChanges; every CSS mechanism emits the mandatory
   * prefers-reduced-motion zeroing rule. Omitted arrays are left off the diff.
   */
  buildReplace(
    elementInfo: ElementInfo,
    removeChange: RemoveChange,
    insertChange: InsertChange,
    extras?: {
      changes?: readonly PropertyChange[];
      stylesheetChanges?: readonly StylesheetChange[];
      scriptChanges?: readonly ScriptBehaviorChange[];
    },
  ): VisualDiff {
    return {
      id: crypto.randomUUID(),
      timestamp: new Date().toISOString(),
      element: elementInfo,
      changes: extras?.changes ?? [],
      removeChanges: [removeChange],
      insertChanges: [insertChange],
      ...(extras?.stylesheetChanges?.length ? { stylesheetChanges: extras.stylesheetChanges } : {}),
      ...(extras?.scriptChanges?.length ? { scriptChanges: extras.scriptChanges } : {}),
      context: this.buildPageContext(),
      status: 'pending',
      sourceVerified: Boolean(elementInfo.sourceFile),
    };
  }

  /** Build a VisualDiff for attribute changes (src, alt, etc.) with optional CSS changes. */
  buildAttribute(
    elementInfo: ElementInfo,
    attributeChanges: AttributeChange[],
    cssChanges?: PropertyChange[],
    element?: Element,
  ): VisualDiff {
    return {
      id: crypto.randomUUID(),
      timestamp: new Date().toISOString(),
      element: elementInfo,
      changes: cssChanges ? cssChanges.map((c) => this.enrich(c, element)) : [],
      attributeChanges,
      context: this.buildPageContext(),
      status: 'pending',
      sourceVerified: Boolean(elementInfo.sourceFile),
    };
  }

  /** Build a VisualDiff for a group operation (wrapping siblings in a flex container). */
  buildGroup(elementInfo: ElementInfo, groupChange: GroupChange): VisualDiff {
    return {
      id: crypto.randomUUID(),
      timestamp: new Date().toISOString(),
      element: elementInfo,
      changes: [],
      groupChanges: [groupChange],
      context: this.buildPageContext(),
      status: 'pending',
      sourceVerified: Boolean(elementInfo.sourceFile),
    };
  }

  /** Build a VisualDiff for a reparent operation (cross-container move). */
  buildReparent(elementInfo: ElementInfo, reparentChange: ReparentChange): VisualDiff {
    return {
      id: crypto.randomUUID(),
      timestamp: new Date().toISOString(),
      element: elementInfo,
      changes: [],
      reparentChanges: [reparentChange],
      context: this.buildPageContext(),
      status: 'pending',
      sourceVerified: Boolean(elementInfo.sourceFile),
    };
  }

  /** Build a VisualDiff for a text content change (no CSS property changes). */
  buildText(elementInfo: ElementInfo, textChange: TextChange): VisualDiff {
    return {
      id: crypto.randomUUID(),
      timestamp: new Date().toISOString(),
      element: elementInfo,
      changes: [],
      textChanges: [textChange],
      context: this.buildPageContext(),
      status: 'pending',
      sourceVerified: Boolean(elementInfo.sourceFile),
    };
  }

  /** Build a VisualDiff with related changes on other elements (e.g., parent isolation for blend mode). */
  buildWithRelatedChanges(
    elementInfo: ElementInfo,
    changes: PropertyChange[],
    relatedChanges: RelatedChange[],
    element?: Element,
  ): VisualDiff {
    return {
      id: crypto.randomUUID(),
      timestamp: new Date().toISOString(),
      element: elementInfo,
      changes: changes.map((c) => this.enrich(c, element)),
      relatedChanges,
      context: this.buildPageContext(),
      status: 'pending',
      sourceVerified: Boolean(elementInfo.sourceFile),
    };
  }

  // -----------------------------------------------------------------------
  // Internals
  // -----------------------------------------------------------------------

  /**
   * Resolve tokens and stamp source provenance onto a property change.
   * Source resolution is best-effort: silently skipped if the resolver is
   * absent, the element is absent, or the caller already supplied a source.
   * Cross-breakpoint sources are resolved independently and attached as
   * additive context when present.
   */
  private enrich(change: PropertyChange, element: Element | undefined): PropertyChange {
    const tokenResolved = this.resolveTokens(change);
    if (element == null) return tokenResolved;

    const next: { source?: RuleSource; allBreakpointSources?: readonly CrossBreakpointRuleSource[] } = {};

    if (tokenResolved.source == null && this.resolveRuleSource != null) {
      const source = this.resolveRuleSource(element, change.property);
      if (source) next.source = source;
    }

    if (tokenResolved.allBreakpointSources == null && this.resolveCrossBreakpointSources != null) {
      const cross = this.resolveCrossBreakpointSources(element, change.property);
      if (cross && cross.length > 0) next.allBreakpointSources = cross;
    }

    if (next.source == null && next.allBreakpointSources == null) return tokenResolved;
    return { ...tokenResolved, ...next };
  }

  /** Resolve fromToken and toToken using the client-side token store. */
  private resolveTokens(change: PropertyChange): PropertyChange {
    const from = this.tokenStore.resolveValue(change.property, change.fromValue);
    const to = this.tokenStore.resolveValue(change.property, change.toValue);

    // Only override if we found tokens — preserve any existing values
    if (!from.token && !to.token) return change;

    return {
      ...change,
      fromToken: from.token ?? change.fromToken,
      toToken: to.token ?? change.toToken,
    };
  }

  /** Assemble PageContext from the current browser state. */
  private buildPageContext(): PageContext {
    const context: PageContext = {
      url: window.location.href,
      viewport: {
        width: window.innerWidth,
        height: window.innerHeight,
      },
      tabId: this.tabId,
    };

    // Resolve breakpoint from project tokens if available
    const breakpointTokens = this.tokenStore.getForCategory('breakpoints');
    if (breakpointTokens.length > 0) {
      // Find the largest breakpoint that the current viewport exceeds
      const sorted = breakpointTokens
        .map((t) => ({ name: t.name, value: parseFloat(t.value) }))
        .filter((t) => !isNaN(t.value))
        .sort((a, b) => b.value - a.value);

      for (const bp of sorted) {
        if (window.innerWidth >= bp.value) {
          return {
            ...context,
            breakpoint: bp.name,
            breakpointValue: `${bp.value}px`,
          };
        }
      }
    }

    return context;
  }
}
