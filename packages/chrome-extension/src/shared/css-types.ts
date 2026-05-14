// ---------------------------------------------------------------------------
// CSS inspection types — browser-only, not cross-package
// ---------------------------------------------------------------------------

/**
 * A CSS rule that matches a given element, with extracted declarations
 * and metadata for cascade resolution.
 */
export interface MatchedRule {
  readonly selectorText: string;
  readonly specificity: [number, number, number];
  readonly sourceHref: string | null;
  readonly sourceIndex: number;
  readonly declarations: Map<string, string>;
  readonly isInline: boolean;
  readonly mediaQuery?: string;
  readonly layerName?: string;
  /**
   * Set by `getAllBreakpointRules`: true when the enclosing viewport-bound
   * `@media` query currently matches the viewport, false when the rule is
   * surfaced for cross-breakpoint context only. Left undefined by the
   * existing `getMatchedRules` cascade path.
   */
  readonly matchesCurrentViewport?: boolean;
}

/**
 * How much of the page's CSS was readable.
 * - full: all sheets readable
 * - partial: some sheets threw SecurityError (cross-origin)
 * - none: no sheets readable (unlikely on localhost)
 */
export type AccessLevel = 'full' | 'partial' | 'none';

/** Result of matching CSS rules against an element. */
export interface MatchResult {
  readonly rules: MatchedRule[];
  readonly accessLevel: AccessLevel;
  readonly accessMessage?: string;
}
