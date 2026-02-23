import type {
  VisualDiff,
  ElementInfo,
  PropertyChange,
  ReorderChange,
  InsertChange,
  PageContext,
} from '@frontend-editor/shared';
import type { TokenStore } from '../tokens/store';

/**
 * Assembles complete VisualDiff objects from editing results.
 * Handles UUID generation, timestamp, PageContext, sourceVerified flag,
 * and client-side token resolution for fromToken/toToken fields.
 */
export class DiffBuilder {
  constructor(
    private readonly tabId: string,
    private readonly tokenStore: TokenStore,
  ) {}

  /** Build a VisualDiff from an element and its property changes. */
  build(elementInfo: ElementInfo, changes: PropertyChange[]): VisualDiff {
    return {
      id: crypto.randomUUID(),
      timestamp: new Date().toISOString(),
      element: elementInfo,
      changes: changes.map((c) => this.resolveTokens(c)),
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

  // -----------------------------------------------------------------------
  // Internals
  // -----------------------------------------------------------------------

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
