import type {
  DesignToken,
  TokenCategory,
  TokenSourceStatus,
} from '@frontend-editor/shared';

/**
 * Client-side token registry. Receives tokens from the MCP server
 * via WebSocket (TOKEN_DATA / TOKEN_UPDATE) and provides indexed
 * lookups for the editing and snapping systems.
 */
export class TokenStore {
  private tokens: DesignToken[] = [];
  private byCategory = new Map<TokenCategory, DesignToken[]>();
  private byProperty = new Map<string, DesignToken[]>();
  private sources: TokenSourceStatus[] = [];
  private updateCallbacks: Array<() => void> = [];
  private _locked = false;

  get loaded(): boolean {
    return this.tokens.length > 0;
  }

  /** Replace the entire token set (called on TOKEN_DATA). */
  setAll(
    tokens: readonly DesignToken[],
    sources: readonly TokenSourceStatus[],
  ): void {
    if (this._locked) {
      this._pendingUpdate = { tokens, sources };
      return;
    }
    this.tokens = [...tokens];
    this.sources = [...sources];
    this.rebuildIndexes();
    this.notify();
  }

  /** Merge delta updates (called on TOKEN_UPDATE). */
  update(
    tokens: readonly DesignToken[],
    sources?: readonly TokenSourceStatus[],
  ): void {
    if (this._locked) {
      this._pendingUpdate = { tokens, sources };
      return;
    }

    // Replace tokens from the same source, keep others
    const updatedSources = new Set(tokens.map((t) => t.source));
    this.tokens = [
      ...this.tokens.filter((t) => !updatedSources.has(t.source)),
      ...tokens,
    ];

    if (sources) {
      for (const s of sources) {
        const idx = this.sources.findIndex((existing) => existing.file === s.file);
        if (idx >= 0) this.sources[idx] = s;
        else this.sources.push(s);
      }
    }

    this.rebuildIndexes();
    this.notify();
  }

  /** Get all tokens. */
  getAll(): DesignToken[] {
    return [...this.tokens];
  }

  /** Get tokens for a specific CSS property. */
  getForProperty(cssProperty: string): DesignToken[] {
    return this.byProperty.get(cssProperty) ?? [];
  }

  /** Get tokens for a category. */
  getForCategory(category: TokenCategory): DesignToken[] {
    return this.byCategory.get(category) ?? [];
  }

  /**
   * Resolve a CSS value to its nearest design token.
   * Mirrors the server-side resolveToToken logic for instant client feedback.
   */
  resolveValue(
    property: string,
    value: string,
  ): { token?: string; exact: boolean } {
    const candidates = this.getForProperty(property);
    if (candidates.length === 0) return { exact: false };

    // Exact string match
    const exact = candidates.find((t) => t.value === value);
    if (exact) return { token: exact.name, exact: true };

    // Normalize hex colors for comparison
    const normValue = normalizeHexColor(value);
    if (normValue !== value) {
      const colorMatch = candidates.find(
        (t) => normalizeHexColor(t.value) === normValue,
      );
      if (colorMatch) return { token: colorMatch.name, exact: true };
    }

    // Numeric proximity for dimensional values
    const numValue = parseFloat(value);
    if (!isNaN(numValue)) {
      let closest: DesignToken | null = null;
      let closestDist = Infinity;

      for (const token of candidates) {
        const tokenNum = parseFloat(token.value);
        if (isNaN(tokenNum)) continue;
        const dist = Math.abs(tokenNum - numValue);
        if (dist < closestDist) {
          closestDist = dist;
          closest = token;
        }
      }

      if (closest && closestDist < 2) {
        return { token: closest.name, exact: closestDist === 0 };
      }
    }

    return { exact: false };
  }

  /** Register a callback for token updates (UI refresh). */
  onUpdate(cb: () => void): void {
    this.updateCallbacks.push(cb);
  }

  // -----------------------------------------------------------------------
  // Edit locking — buffers updates during active drags
  // -----------------------------------------------------------------------

  private _pendingUpdate: {
    tokens: readonly DesignToken[];
    sources?: readonly TokenSourceStatus[];
  } | null = null;

  /** Lock the store during an active edit. Token updates are queued. */
  lock(): void {
    this._locked = true;
  }

  /** Unlock and apply any queued token update. */
  unlock(): void {
    this._locked = false;
    if (this._pendingUpdate) {
      const { tokens, sources } = this._pendingUpdate;
      this._pendingUpdate = null;
      if (sources) {
        this.setAll(tokens, sources);
      } else {
        this.update(tokens);
      }
    }
  }

  // -----------------------------------------------------------------------
  // Internals
  // -----------------------------------------------------------------------

  private rebuildIndexes(): void {
    this.byCategory.clear();
    this.byProperty.clear();

    for (const token of this.tokens) {
      // Index by category
      const catList = this.byCategory.get(token.category);
      if (catList) catList.push(token);
      else this.byCategory.set(token.category, [token]);

      // Index by CSS property
      for (const prop of token.cssProperties) {
        const propList = this.byProperty.get(prop);
        if (propList) propList.push(token);
        else this.byProperty.set(prop, [token]);
      }
    }
  }

  private notify(): void {
    for (const cb of this.updateCallbacks) cb();
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Normalize a hex color to lowercase 6-digit form. */
function normalizeHexColor(value: string): string {
  const trimmed = value.trim().toLowerCase();
  if (!trimmed.startsWith('#')) return trimmed;

  const hex = trimmed.slice(1);
  if (hex.length === 3) {
    return `#${hex[0]}${hex[0]}${hex[1]}${hex[1]}${hex[2]}${hex[2]}`;
  }
  return trimmed;
}
