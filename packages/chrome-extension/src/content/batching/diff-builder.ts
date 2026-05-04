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
  PageContext,
  RuleSource,
} from '@frontend-editor/shared';
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
   */
  private enrich(change: PropertyChange, element: Element | undefined): PropertyChange {
    const tokenResolved = this.resolveTokens(change);
    if (tokenResolved.source != null || element == null || this.resolveRuleSource == null) {
      return tokenResolved;
    }
    const source = this.resolveRuleSource(element, change.property);
    return source ? { ...tokenResolved, source } : tokenResolved;
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
