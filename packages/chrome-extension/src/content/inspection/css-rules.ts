// ---------------------------------------------------------------------------
// CSS rule matching engine
// ---------------------------------------------------------------------------

import type { MatchedRule, AccessLevel, MatchResult } from '../../shared/css-types';
import type { RuleSource } from '@frontend-editor/shared';
import { computeSpecificity, compareSpecificity } from './specificity';

const RULE_COUNT_CEILING = 5_000;
const ASYNC_CHUNK_SIZE = 500;

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
