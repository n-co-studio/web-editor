// ---------------------------------------------------------------------------
// CSS Variable Resolver — walks matched rules + ancestor chain to resolve var()
// ---------------------------------------------------------------------------

import type { MatchedRulesCache } from './matched-rules-cache';
import type { TokenStore } from '../tokens/store';
import type { MatchedRule } from '../../shared/css-types';

const MAX_ANCESTOR_LEVELS = 20;
const MAX_RECURSION_DEPTH = 10;
const MAX_DISPLAY_CHAIN = 3;

// Regex to extract var() references: var(--name) or var(--name, fallback)
const VAR_RE = /var\(\s*(--[a-zA-Z0-9_-]+)\s*(?:,\s*([^)]+))?\)/;

export interface ResolutionStep {
  variableName: string;
  value: string;
  source: string;          // selector text or "inline" or "computed"
  sourceHref: string | null;
  isComputed: boolean;     // true when resolved via getComputedStyle fallback
  tokenName?: string;
}

export interface ResolutionResult {
  chain: ResolutionStep[];
  finalValue: string;
  circular: boolean;
  truncated: boolean;
  totalDepth: number;
}

/**
 * Resolves CSS custom properties by walking matched rules on the element
 * and its ancestors, following var() references recursively.
 */
export class VariableResolver {
  constructor(
    private readonly rulesCache: MatchedRulesCache,
    private readonly tokenStore: TokenStore,
    private readonly getExcludeSheets: () => Set<CSSStyleSheet>,
    private readonly excludeHost?: Element,
  ) {}

  /**
   * Resolve a CSS variable starting from the given element.
   * Returns the full resolution chain, final computed value, and metadata.
   */
  resolve(element: Element, variableName: string): ResolutionResult {
    const visited = new Set<string>();
    const chain: ResolutionStep[] = [];
    let circular = false;
    let totalDepth = 0;

    const finalValue = this.resolveRecursive(
      element, variableName, visited, chain, 0,
      (depth) => { totalDepth = depth; },
      () => { circular = true; },
    );

    return {
      chain: chain.slice(0, MAX_DISPLAY_CHAIN),
      finalValue,
      circular,
      truncated: chain.length > MAX_DISPLAY_CHAIN,
      totalDepth: totalDepth + 1,
    };
  }

  private resolveRecursive(
    element: Element,
    varName: string,
    visited: Set<string>,
    chain: ResolutionStep[],
    depth: number,
    setDepth: (d: number) => void,
    setCircular: () => void,
  ): string {
    setDepth(depth);

    // Circular reference detection
    if (visited.has(varName)) {
      setCircular();
      return 'circular';
    }
    if (depth >= MAX_RECURSION_DEPTH) {
      return 'max depth';
    }
    visited.add(varName);

    // Walk the element + ancestors looking for the custom property definition
    const definition = this.findDefinition(element, varName);

    if (definition) {
      // Check for token cross-reference
      const tokenResult = this.tokenStore.resolveValue(varName, definition.value);

      chain.push({
        variableName: varName,
        value: definition.value,
        source: definition.source,
        sourceHref: definition.sourceHref,
        isComputed: false,
        tokenName: tokenResult.token,
      });

      // If the value itself contains var(), recurse
      const innerVar = VAR_RE.exec(definition.value);
      if (innerVar) {
        return this.resolveRecursive(
          definition.element, innerVar[1], visited, chain, depth + 1,
          setDepth, setCircular,
        );
      }

      return definition.value;
    }

    // Fallback: getComputedStyle
    const computed = getComputedStyle(element).getPropertyValue(varName).trim();
    if (computed) {
      const tokenResult = this.tokenStore.resolveValue(varName, computed);
      chain.push({
        variableName: varName,
        value: computed,
        source: 'computed',
        sourceHref: null,
        isComputed: true,
        tokenName: tokenResult.token,
      });
      return computed;
    }

    return 'unresolved';
  }

  /**
   * Search for a custom property definition starting from the element
   * and walking up to MAX_ANCESTOR_LEVELS ancestors.
   * Returns the highest-specificity definition on the closest ancestor.
   */
  private findDefinition(
    startElement: Element,
    varName: string,
  ): { value: string; source: string; sourceHref: string | null; element: Element } | null {
    const excludeSheets = this.getExcludeSheets();
    let current: Element | null = startElement;

    for (let level = 0; current && level < MAX_ANCESTOR_LEVELS; level++) {
      const result = this.rulesCache.get(current, excludeSheets, this.excludeHost);
      // Search rules in reverse specificity order (highest first) for the property
      const rules = [...result.rules].reverse();

      for (const rule of rules) {
        const value = rule.declarations.get(varName);
        if (value !== undefined) {
          return {
            value,
            source: rule.isInline ? 'inline' : rule.selectorText,
            sourceHref: rule.sourceHref,
            element: current,
          };
        }
      }

      current = current.parentElement;
    }

    return null;
  }
}
