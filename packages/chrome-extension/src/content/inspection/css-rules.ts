// ---------------------------------------------------------------------------
// CSS rule matching engine
// ---------------------------------------------------------------------------

import type { MatchedRule, AccessLevel, MatchResult } from '../../shared/css-types';
import type { RuleSource, CrossBreakpointRuleSource } from '@nco-studio/shared';
import { computeSpecificity, compareSpecificity } from './specificity';

const RULE_COUNT_CEILING = 5_000;
const ASYNC_CHUNK_SIZE = 500;

/**
 * Separate ceiling for the cross-breakpoint walk. Smaller than the active
 * cascade ceiling because the dormant walk visits rules that would normally
 * be skipped by matchMedia, so total rule count is typically higher on a
 * Tailwind-style design system.
 */
export const DORMANT_MEDIA_RULE_CEILING = 2_000;

/**
 * Find all CSS rules that match a given element.
 *
 * Iterates document.styleSheets and document.adoptedStyleSheets,
 * handles cross-origin SecurityError gracefully, recurses into
 * @media/@supports/@layer nested rules, and caps at 5,000 rules.
 *
 * @param el - The element to match rules against
 * @param excludeSheets - StyleSheets to skip (e.g., ToggleManager's override sheet)
 * @param excludeHost - Skip sheets whose ownerNode is inside this element's subtree
 */
export function getMatchedRules(
  el: Element,
  excludeSheets?: Set<CSSStyleSheet>,
  excludeHost?: Element,
): MatchResult {
  const matched: MatchedRule[] = [];
  let accessLevel: AccessLevel = 'full';
  let accessMessage: string | undefined;
  let totalRuleCount = 0;
  let sourceIndex = 0;
  let hitCeiling = false;

  const allSheets = collectStyleSheets(excludeSheets, excludeHost);

  for (const sheet of allSheets) {
    if (hitCeiling) break;

    let rules: CSSRuleList;
    try {
      rules = sheet.cssRules;
    } catch {
      // Cross-origin SecurityError
      accessLevel = accessLevel === 'none' ? 'none' : 'partial';
      continue;
    }

    const result = processRuleList(
      rules,
      el,
      sheet.href,
      sourceIndex,
      totalRuleCount,
      undefined,
      undefined,
    );

    matched.push(...result.matched);
    totalRuleCount = result.totalCount;
    sourceIndex = result.nextSourceIndex;

    if (totalRuleCount >= RULE_COUNT_CEILING) {
      hitCeiling = true;
      accessLevel = 'partial';
      accessMessage = `Large stylesheet — showing first ${RULE_COUNT_CEILING} rules`;
    }
  }

  // Add inline styles as a synthetic rule (always wins by position)
  const inlineRule = buildInlineRule(el, sourceIndex);
  if (inlineRule) {
    matched.push(inlineRule);
  }

  // Set access level based on what we could read
  if (allSheets.length === 0 && !inlineRule) {
    accessLevel = 'none';
  }

  return {
    rules: matched,
    accessLevel: hitCeiling ? 'partial' : accessLevel,
    accessMessage,
  };
}

/**
 * Async variant for pages approaching the rule ceiling.
 * Processes rules in chunks via requestIdleCallback.
 */
export function getMatchedRulesAsync(
  el: Element,
  excludeSheets?: Set<CSSStyleSheet>,
  excludeHost?: Element,
): Promise<MatchResult> {
  return new Promise((resolve) => {
    const allSheets = collectStyleSheets(excludeSheets, excludeHost);
    const matched: MatchedRule[] = [];
    let accessLevel: AccessLevel = 'full';
    let accessMessage: string | undefined;
    let totalRuleCount = 0;
    let sourceIndex = 0;
    let hitCeiling = false;

    // Collect all rules from all sheets into a flat list for chunked processing
    const allRules: Array<{ rule: CSSRule; href: string | null }> = [];

    for (const sheet of allSheets) {
      let rules: CSSRuleList;
      try {
        rules = sheet.cssRules;
      } catch {
        accessLevel = accessLevel === 'none' ? 'none' : 'partial';
        continue;
      }
      for (let i = 0; i < rules.length; i++) {
        allRules.push({ rule: rules[i], href: sheet.href });
      }
    }

    let ruleIndex = 0;

    function processChunk(deadline: IdleDeadline): void {
      const chunkEnd = Math.min(ruleIndex + ASYNC_CHUNK_SIZE, allRules.length);

      while (ruleIndex < chunkEnd && !hitCeiling) {
        const { rule, href } = allRules[ruleIndex];
        const result = processSingleRule(
          rule,
          el,
          href,
          sourceIndex,
          totalRuleCount,
          undefined,
          undefined,
        );
        matched.push(...result.matched);
        totalRuleCount = result.totalCount;
        sourceIndex = result.nextSourceIndex;
        ruleIndex++;

        if (totalRuleCount >= RULE_COUNT_CEILING) {
          hitCeiling = true;
          accessLevel = 'partial';
          accessMessage = `Large stylesheet — showing first ${RULE_COUNT_CEILING} rules`;
        }
      }

      if (ruleIndex >= allRules.length || hitCeiling) {
        // Done — add inline styles and resolve
        const inlineRule = buildInlineRule(el, sourceIndex);
        if (inlineRule) matched.push(inlineRule);
        if (allSheets.length === 0 && !inlineRule) accessLevel = 'none';
        resolve({
          rules: matched,
          accessLevel: hitCeiling ? 'partial' : accessLevel,
          accessMessage,
        });
      } else {
        requestIdleCallback(processChunk);
      }
    }

    if (allRules.length === 0) {
      const inlineRule = buildInlineRule(el, sourceIndex);
      if (inlineRule) matched.push(inlineRule);
      resolve({ rules: matched, accessLevel, accessMessage });
    } else {
      requestIdleCallback(processChunk);
    }
  });
}

/**
 * Return the cascade-winning rule that currently sets `property` on the
 * matched-rule list, or null if no rule sets it.
 *
 * Cascade order (CSS spec):
 *   1. !important > normal — encoded by the trailing " !important" suffix on
 *      the value extracted by `extractDeclarations` (priority within layers
 *      and cascade origins is approximated; this is good enough for author
 *      stylesheets, which is the editing target).
 *   2. Specificity (a, b, c) — higher wins.
 *   3. Source order — later in the document wins (higher `sourceIndex`).
 *
 * Inline styles (isInline=true) carry specificity [Infinity, 0, 0] so they
 * win unconditionally.
 */
export function findOwningRule(
  rules: readonly MatchedRule[],
  property: string,
): MatchedRule | null {
  let winner: MatchedRule | null = null;
  let winnerImportant = false;

  for (const rule of rules) {
    const value = rule.declarations.get(property);
    if (value == null) continue;

    const important = / !important$/.test(value);

    if (winner == null) {
      winner = rule;
      winnerImportant = important;
      continue;
    }

    // !important beats normal regardless of specificity.
    if (important && !winnerImportant) {
      winner = rule;
      winnerImportant = true;
      continue;
    }
    if (!important && winnerImportant) continue;

    const cmp = compareSpecificity(rule.specificity, winner.specificity);
    if (cmp > 0 || (cmp === 0 && rule.sourceIndex >= winner.sourceIndex)) {
      winner = rule;
      winnerImportant = important;
    }
  }

  return winner;
}

/**
 * Convert a MatchedRule into the cross-package RuleSource shape that flows
 * through the diff queue and out to the MCP server.
 *
 * Specificity is JSON-serialized; CSSOM inline rules use Infinity which
 * collapses to null on the wire. Cap inline at a sentinel finite value so
 * the receiving agent sees a real number tuple.
 */
export function toRuleSource(rule: MatchedRule): RuleSource {
  const [a, b, c] = rule.specificity;
  const finiteA = Number.isFinite(a) ? a : 10000;
  return {
    selector: rule.selectorText,
    sourceHref: rule.sourceHref,
    sourceIndex: rule.sourceIndex,
    specificity: [finiteA, b, c] as const,
    isInline: rule.isInline,
    mediaQuery: rule.mediaQuery,
    layerName: rule.layerName,
  };
}

/**
 * Viewport-bound media-query allow-list: include only queries that gate on
 * a viewport dimension. Implemented as a substring match on `width:`,
 * `height:`, or `aspect-ratio:` as feature keys (the trailing colon
 * disambiguates from incidental occurrences inside selectors or values).
 *
 * This naturally excludes:
 *   - `print` (media type, no feature key)
 *   - `(hover: ...)`, `(any-hover: ...)`, `(pointer: ...)`, `(any-pointer: ...)`
 *   - `(prefers-color-scheme: ...)`, `(prefers-reduced-motion: ...)`, other `prefers-*`
 *   - `(forced-colors: ...)`
 *   - `(orientation: portrait|landscape)`
 *
 * Compound queries like `screen and (min-width: 768px)` are included because
 * they contain `width:`. Compound queries mixing viewport + non-viewport
 * features (e.g. `(min-width: 768px) and (hover: hover)`) are also included
 * — they still scope to a viewport range.
 */
function isViewportBoundMediaQuery(conditionText: string): boolean {
  return /\b(width|height|aspect-ratio)\s*:/i.test(conditionText);
}

/**
 * Sibling to `getMatchedRules` for cross-breakpoint context. Walks the same
 * stylesheets but recurses into `@media` bodies regardless of whether the
 * query currently matches the viewport. Each emitted rule carries
 * `matchesCurrentViewport: boolean` so the consumer can distinguish the
 * active subset from the dormant subset.
 *
 * Filters:
 *   - Only viewport-bound `@media` blocks (see `isViewportBoundMediaQuery`)
 *   - `@container` blocks are explicitly skipped (deferred — `matchMedia`
 *     cannot evaluate container queries; surfacing them as cross-breakpoint
 *     context would be misleading without ancestor-size evaluation)
 *   - Non-`@media` top-level rules are NOT collected (the cascade path
 *     already covers them and they have no breakpoint scope)
 *
 * CORS handling mirrors `getMatchedRules`: cross-origin sheets contribute
 * to `accessLevel: 'partial'`. Ceiling is `DORMANT_MEDIA_RULE_CEILING`.
 */
export function getAllBreakpointRules(
  el: Element,
  opts?: {
    ceiling?: number;
    excludeSheets?: Set<CSSStyleSheet>;
    excludeHost?: Element;
  },
): MatchResult {
  const ceiling = opts?.ceiling ?? DORMANT_MEDIA_RULE_CEILING;
  const matched: MatchedRule[] = [];
  let accessLevel: AccessLevel = 'full';
  let accessMessage: string | undefined;
  let totalRuleCount = 0;
  let sourceIndex = 0;
  let hitCeiling = false;

  const allSheets = collectStyleSheets(opts?.excludeSheets, opts?.excludeHost);

  for (const sheet of allSheets) {
    if (hitCeiling) break;

    let rules: CSSRuleList;
    try {
      rules = sheet.cssRules;
    } catch {
      accessLevel = accessLevel === 'none' ? 'none' : 'partial';
      if (!accessMessage) {
        accessMessage = 'One or more cross-origin stylesheets could not be inspected';
      }
      continue;
    }

    const result = processDormantRuleList(
      rules,
      el,
      sheet.href,
      sourceIndex,
      totalRuleCount,
      ceiling,
      undefined,
      undefined,
      undefined,
    );

    matched.push(...result.matched);
    totalRuleCount = result.totalCount;
    sourceIndex = result.nextSourceIndex;

    if (totalRuleCount >= ceiling) {
      hitCeiling = true;
      accessLevel = 'partial';
      accessMessage = `Large stylesheet — cross-breakpoint walk truncated at ${ceiling} rules`;
    }
  }

  if (allSheets.length === 0) {
    accessLevel = 'none';
  }

  return {
    rules: matched,
    accessLevel: hitCeiling ? 'partial' : accessLevel,
    accessMessage,
  };
}

interface DormantProcessResult {
  matched: MatchedRule[];
  totalCount: number;
  nextSourceIndex: number;
}

function processDormantRuleList(
  rules: CSSRuleList,
  el: Element,
  href: string | null,
  sourceIndex: number,
  totalCount: number,
  ceiling: number,
  mediaQuery: string | undefined,
  layerName: string | undefined,
  matchesCurrentViewport: boolean | undefined,
): DormantProcessResult {
  const matched: MatchedRule[] = [];

  for (let i = 0; i < rules.length; i++) {
    if (totalCount >= ceiling) break;

    const result = processDormantSingleRule(
      rules[i],
      el,
      href,
      sourceIndex,
      totalCount,
      ceiling,
      mediaQuery,
      layerName,
      matchesCurrentViewport,
    );
    matched.push(...result.matched);
    totalCount = result.totalCount;
    sourceIndex = result.nextSourceIndex;
  }

  return { matched, totalCount, nextSourceIndex: sourceIndex };
}

function processDormantSingleRule(
  rule: CSSRule,
  el: Element,
  href: string | null,
  sourceIndex: number,
  totalCount: number,
  ceiling: number,
  mediaQuery: string | undefined,
  layerName: string | undefined,
  matchesCurrentViewport: boolean | undefined,
): DormantProcessResult {
  const matched: MatchedRule[] = [];

  if (rule instanceof CSSStyleRule) {
    // Only collect style rules nested inside a viewport-bound @media — the
    // cascade path (getMatchedRules) already covers non-@media rules.
    if (mediaQuery !== undefined) {
      totalCount++;
      try {
        if (el.matches(rule.selectorText)) {
          matched.push({
            selectorText: rule.selectorText,
            specificity: computeSpecificity(rule.selectorText),
            sourceHref: href,
            sourceIndex,
            declarations: extractDeclarations(rule.style),
            isInline: false,
            mediaQuery,
            layerName,
            matchesCurrentViewport: matchesCurrentViewport === true,
          });
        }
      } catch {
        // Invalid selector — skip
      }
      sourceIndex++;
    }
  } else if (rule instanceof CSSMediaRule) {
    // Recurse into viewport-bound media queries regardless of current match.
    // Compose nested condition with parent for accurate matchMedia evaluation.
    const condition = rule.conditionText || '';
    if (!isViewportBoundMediaQuery(condition)) {
      return { matched, totalCount, nextSourceIndex: sourceIndex };
    }
    const composed = mediaQuery
      ? `${mediaQuery} and ${condition}`
      : condition;
    let matches: boolean;
    try {
      matches = window.matchMedia(composed).matches;
    } catch {
      // Unparseable condition — surface the rule with matchesCurrentViewport: false
      // rather than skipping, since the condition string itself is still informative.
      matches = false;
    }
    const nested = processDormantRuleList(
      rule.cssRules,
      el,
      href,
      sourceIndex,
      totalCount,
      ceiling,
      composed,
      layerName,
      matches,
    );
    matched.push(...nested.matched);
    totalCount = nested.totalCount;
    sourceIndex = nested.nextSourceIndex;
  } else if (rule instanceof CSSSupportsRule) {
    // @supports is orthogonal to viewport — recurse, preserving outer media state.
    const nested = processDormantRuleList(
      rule.cssRules,
      el,
      href,
      sourceIndex,
      totalCount,
      ceiling,
      mediaQuery,
      layerName,
      matchesCurrentViewport,
    );
    matched.push(...nested.matched);
    totalCount = nested.totalCount;
    sourceIndex = nested.nextSourceIndex;
  } else if (isContainerRule(rule)) {
    // container queries deferred — see Risks. matchMedia cannot evaluate
    // them; surfacing them here without ancestor-size evaluation would be
    // misleading. A follow-on brief should add `containerQuery` to RuleSource.
    return { matched, totalCount, nextSourceIndex: sourceIndex };
  } else if ('name' in rule && 'cssRules' in rule) {
    // CSSLayerBlockRule — recurse, preserving outer media state.
    const layerRule = rule as CSSRule & { name: string; cssRules: CSSRuleList };
    const nested = processDormantRuleList(
      layerRule.cssRules,
      el,
      href,
      sourceIndex,
      totalCount,
      ceiling,
      mediaQuery,
      layerRule.name || layerName,
      matchesCurrentViewport,
    );
    matched.push(...nested.matched);
    totalCount = nested.totalCount;
    sourceIndex = nested.nextSourceIndex;
  }

  return { matched, totalCount, nextSourceIndex: sourceIndex };
}

/**
 * `CSSContainerRule` may not be present in older lib.dom typings. Duck-type
 * via the union of properties unique to container rules.
 */
function isContainerRule(rule: CSSRule): boolean {
  const ctor = (globalThis as { CSSContainerRule?: { prototype: object } }).CSSContainerRule;
  if (ctor && rule instanceof (ctor as unknown as { new (): CSSRule })) return true;
  return (
    'containerName' in rule &&
    'containerQuery' in rule &&
    'cssRules' in rule
  );
}

/**
 * Build the `allBreakpointSources` set for a PropertyChange: filter the
 * cross-breakpoint walk to rules that declare the same property, drop the
 * cascade winner (already carried in `source`), and convert to the
 * cross-package shape.
 */
export function toCrossBreakpointSources(
  dormantRules: readonly MatchedRule[],
  property: string,
  owning: MatchedRule | null,
): CrossBreakpointRuleSource[] {
  const out: CrossBreakpointRuleSource[] = [];
  for (const rule of dormantRules) {
    if (!rule.declarations.has(property)) continue;
    if (owning && isSameRule(rule, owning)) continue;
    out.push({
      ...toRuleSource(rule),
      matchesCurrentViewport: rule.matchesCurrentViewport === true,
    });
  }
  return out;
}

function isSameRule(a: MatchedRule, b: MatchedRule): boolean {
  return (
    a.selectorText === b.selectorText &&
    a.sourceHref === b.sourceHref &&
    a.mediaQuery === b.mediaQuery &&
    a.layerName === b.layerName &&
    a.isInline === b.isInline
  );
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

function collectStyleSheets(
  excludeSheets?: Set<CSSStyleSheet>,
  excludeHost?: Element,
): CSSStyleSheet[] {
  const sheets: CSSStyleSheet[] = [];

  for (const sheet of document.styleSheets) {
    if (excludeSheets?.has(sheet)) continue;
    if (excludeHost && sheet.ownerNode && excludeHost.contains(sheet.ownerNode as Node)) continue;
    sheets.push(sheet);
  }

  for (const sheet of document.adoptedStyleSheets) {
    if (excludeSheets?.has(sheet)) continue;
    sheets.push(sheet);
  }

  return sheets;
}

interface ProcessResult {
  matched: MatchedRule[];
  totalCount: number;
  nextSourceIndex: number;
}

function processRuleList(
  rules: CSSRuleList,
  el: Element,
  href: string | null,
  sourceIndex: number,
  totalCount: number,
  mediaQuery: string | undefined,
  layerName: string | undefined,
): ProcessResult {
  const matched: MatchedRule[] = [];

  for (let i = 0; i < rules.length; i++) {
    if (totalCount >= RULE_COUNT_CEILING) break;

    const result = processSingleRule(
      rules[i],
      el,
      href,
      sourceIndex,
      totalCount,
      mediaQuery,
      layerName,
    );
    matched.push(...result.matched);
    totalCount = result.totalCount;
    sourceIndex = result.nextSourceIndex;
  }

  return { matched, totalCount, nextSourceIndex: sourceIndex };
}

function processSingleRule(
  rule: CSSRule,
  el: Element,
  href: string | null,
  sourceIndex: number,
  totalCount: number,
  mediaQuery: string | undefined,
  layerName: string | undefined,
): ProcessResult {
  const matched: MatchedRule[] = [];

  if (rule instanceof CSSStyleRule) {
    totalCount++;
    try {
      if (el.matches(rule.selectorText)) {
        matched.push({
          selectorText: rule.selectorText,
          specificity: computeSpecificity(rule.selectorText),
          sourceHref: href,
          sourceIndex,
          declarations: extractDeclarations(rule.style),
          isInline: false,
          mediaQuery,
          layerName,
        });
      }
    } catch {
      // Invalid selector — skip
    }
    sourceIndex++;
  } else if (rule instanceof CSSMediaRule) {
    // Only include currently-active media rules
    if (window.matchMedia(rule.conditionText).matches) {
      const nested = processRuleList(
        rule.cssRules,
        el,
        href,
        sourceIndex,
        totalCount,
        rule.conditionText,
        layerName,
      );
      matched.push(...nested.matched);
      totalCount = nested.totalCount;
      sourceIndex = nested.nextSourceIndex;
    }
  } else if (rule instanceof CSSSupportsRule) {
    const nested = processRuleList(
      rule.cssRules,
      el,
      href,
      sourceIndex,
      totalCount,
      mediaQuery,
      layerName,
    );
    matched.push(...nested.matched);
    totalCount = nested.totalCount;
    sourceIndex = nested.nextSourceIndex;
  } else if ('name' in rule && 'cssRules' in rule) {
    // CSSLayerBlockRule — may not be in all TS type defs yet
    const layerRule = rule as CSSRule & { name: string; cssRules: CSSRuleList };
    const nested = processRuleList(
      layerRule.cssRules,
      el,
      href,
      sourceIndex,
      totalCount,
      mediaQuery,
      layerRule.name || layerName,
    );
    matched.push(...nested.matched);
    totalCount = nested.totalCount;
    sourceIndex = nested.nextSourceIndex;
  }

  return { matched, totalCount, nextSourceIndex: sourceIndex };
}

function extractDeclarations(style: CSSStyleDeclaration): Map<string, string> {
  const declarations = new Map<string, string>();
  for (let i = 0; i < style.length; i++) {
    const prop = style[i];
    const val = style.getPropertyValue(prop);
    const priority = style.getPropertyPriority(prop);
    declarations.set(prop, priority ? `${val} !important` : val);
  }
  return declarations;
}

function buildInlineRule(el: Element, sourceIndex: number): MatchedRule | null {
  const htmlEl = el as HTMLElement;
  if (!htmlEl.style || htmlEl.style.length === 0) return null;

  const declarations = new Map<string, string>();
  for (let i = 0; i < htmlEl.style.length; i++) {
    const prop = htmlEl.style[i];
    const val = htmlEl.style.getPropertyValue(prop);
    const priority = htmlEl.style.getPropertyPriority(prop);
    declarations.set(prop, priority ? `${val} !important` : val);
  }

  if (declarations.size === 0) return null;

  return {
    selectorText: 'element.style',
    specificity: [Infinity, 0, 0],
    sourceHref: null,
    sourceIndex,
    declarations,
    isInline: true,
  };
}
