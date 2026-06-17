// ---------------------------------------------------------------------------
// Element state simulator — :hover, :focus, :active, :visited simulation
// ---------------------------------------------------------------------------

import { computeSpecificity, compareSpecificity } from './specificity';

export type PseudoState = ':hover' | ':focus' | ':active' | ':visited';
export const PSEUDO_STATES: readonly PseudoState[] = [':hover', ':focus', ':active', ':visited'];

const MAX_ANCESTOR_LEVELS = 5;

// Regex to detect pseudo-class tokens in selectors
const PSEUDO_RE = /:(hover|focus|active|visited)(?![a-zA-Z-])/g;

// ---------------------------------------------------------------------------
// StatePreviewManager — tracks original inline styles for state simulation
// ---------------------------------------------------------------------------

/**
 * Standalone preview manager for state simulation.
 * Independent from PreviewManager (CSS editing) and OrderPreview (reorder).
 * Tracks original inline style values and applies/reverts declarations.
 */
export class StatePreviewManager {
  private original = new Map<string, string>();
  private target: HTMLElement | null = null;

  begin(element: HTMLElement): void {
    this.revert();
    this.target = element;
    this.original.clear();
  }

  apply(property: string, value: string): void {
    if (!this.target) return;
    if (!this.original.has(property)) {
      this.original.set(property, this.target.style.getPropertyValue(property));
    }
    this.target.style.setProperty(property, value);
  }

  revert(): void {
    if (!this.target) return;
    for (const [prop, val] of this.original) {
      if (val) {
        this.target.style.setProperty(prop, val);
      } else {
        this.target.style.removeProperty(prop);
      }
    }
    this.original.clear();
    this.target = null;
  }

  isActive(): boolean {
    return this.target !== null;
  }
}

// ---------------------------------------------------------------------------
// StateSimulator — scans stylesheets, strips pseudo selectors, applies styles
// ---------------------------------------------------------------------------

interface CollectedDeclaration {
  property: string;
  value: string;
  specificity: [number, number, number];
  sourceIndex: number;
}

type ChangeCb = (el: Element) => void;

/**
 * Simulates CSS pseudo-class states by scanning stylesheets for rules
 * containing pseudo-class selectors, stripping the pseudo tokens, testing
 * if the stripped selector matches the target element, and applying the
 * resulting declarations via StatePreviewManager.
 */
export class StateSimulator {
  private activeStates = new Map<Element, Set<PseudoState>>();
  private previewManagers = new Map<Element, StatePreviewManager>();
  private changeCbs: ChangeCb[] = [];

  constructor(
    private readonly getExcludeSheets: () => Set<CSSStyleSheet>,
    private readonly excludeHost?: Element,
  ) {}

  /** Activate a pseudo-state for an element. */
  activate(el: Element, state: PseudoState): void {
    let states = this.activeStates.get(el);
    if (!states) {
      states = new Set();
      this.activeStates.set(el, states);
    }
    if (states.has(state)) return;
    states.add(state);
    this.recomputeAndApply(el);
    this.notify(el);
  }

  /** Deactivate a specific pseudo-state for an element. */
  deactivate(el: Element, state: PseudoState): void {
    const states = this.activeStates.get(el);
    if (!states || !states.has(state)) return;
    states.delete(state);
    if (states.size === 0) {
      this.activeStates.delete(el);
      const pm = this.previewManagers.get(el);
      pm?.revert();
      this.previewManagers.delete(el);
    } else {
      this.recomputeAndApply(el);
    }
    this.notify(el);
  }

  /** Deactivate all pseudo-states for an element (or all elements). */
  deactivateAll(el?: Element): void {
    if (el) {
      this.activeStates.delete(el);
      const pm = this.previewManagers.get(el);
      pm?.revert();
      this.previewManagers.delete(el);
      this.notify(el);
    } else {
      const elements = [...this.activeStates.keys()];
      for (const element of elements) {
        const pm = this.previewManagers.get(element);
        pm?.revert();
      }
      this.activeStates.clear();
      this.previewManagers.clear();
      for (const element of elements) {
        this.notify(element);
      }
    }
  }

  /** Check if any state is active for an element. */
  hasActiveStates(el: Element): boolean {
    const states = this.activeStates.get(el);
    return states != null && states.size > 0;
  }

  /** Get active states for an element. */
  getActiveStates(el: Element): ReadonlySet<PseudoState> {
    return this.activeStates.get(el) ?? new Set();
  }

  /** Check if a specific state is active. */
  isActive(el: Element, state: PseudoState): boolean {
    return this.activeStates.get(el)?.has(state) ?? false;
  }

  /** Register a callback for state changes. */
  onChange(cb: ChangeCb): void {
    this.changeCbs.push(cb);
  }

  dispose(): void {
    this.deactivateAll();
    this.changeCbs.length = 0;
  }

  // ---------------------------------------------------------------------------
  // Core simulation logic
  // ---------------------------------------------------------------------------

  private recomputeAndApply(el: Element): void {
    const states = this.activeStates.get(el);
    if (!states || states.size === 0) return;

    // Revert previous preview before recomputing
    let pm = this.previewManagers.get(el);
    pm?.revert();

    // Collect all declarations from matching pseudo-stripped rules
    const declarations = this.collectDeclarations(el, states);
    if (declarations.length === 0) return;

    // Sort by specificity ascending, then source index — last wins
    declarations.sort((a, b) => {
      const specCmp = compareSpecificity(a.specificity, b.specificity);
      if (specCmp !== 0) return specCmp;
      return a.sourceIndex - b.sourceIndex;
    });

    // Cascade: later entries override earlier for the same property
    const winning = new Map<string, string>();
    for (const decl of declarations) {
      winning.set(decl.property, decl.value);
    }

    if (winning.size === 0) return;

    // Apply via StatePreviewManager
    if (!pm) {
      pm = new StatePreviewManager();
      this.previewManagers.set(el, pm);
    }
    pm.begin(el as HTMLElement);
    for (const [prop, val] of winning) {
      pm.apply(prop, val);
    }
  }

  private collectDeclarations(
    el: Element,
    activeStates: Set<PseudoState>,
  ): CollectedDeclaration[] {
    const declarations: CollectedDeclaration[] = [];
    const excludeSheets = this.getExcludeSheets();
    const sheets = this.collectStyleSheets(excludeSheets);
    let sourceIndex = 0;

    for (const sheet of sheets) {
      let rules: CSSRuleList;
      try {
        rules = sheet.cssRules;
      } catch {
        continue; // Cross-origin
      }

      sourceIndex = this.processRuleList(
        rules, el, activeStates, sheet.href, sourceIndex, declarations,
      );
    }

    return declarations;
  }

  private processRuleList(
    rules: CSSRuleList,
    el: Element,
    activeStates: Set<PseudoState>,
    href: string | null,
    sourceIndex: number,
    out: CollectedDeclaration[],
  ): number {
    for (let i = 0; i < rules.length; i++) {
      const rule = rules[i];

      if (rule instanceof CSSStyleRule) {
        const selectorText = rule.selectorText;

        // Check if this selector contains any of the active pseudo-states
        if (!this.containsActivePseudo(selectorText, activeStates)) {
          sourceIndex++;
          continue;
        }

        // Try direct match: strip pseudo from selector, test el.matches()
        const stripped = this.stripPseudos(selectorText, activeStates);
        if (stripped) {
          try {
            if (el.matches(stripped)) {
              const specificity = computeSpecificity(selectorText);
              this.extractDeclarations(rule.style, specificity, sourceIndex, out);
            }
          } catch {
            // Invalid selector after stripping — skip
            console.debug('[nco-web-editor] Skipped invalid stripped selector:', stripped, '(from:', selectorText, ')');
          }
        }

        // Try ancestor hover chains (up to MAX_ANCESTOR_LEVELS)
        this.checkAncestorChains(el, selectorText, activeStates, rule, sourceIndex, out);

        sourceIndex++;
      } else if (rule instanceof CSSMediaRule) {
        if (window.matchMedia(rule.conditionText).matches) {
          sourceIndex = this.processRuleList(
            rule.cssRules, el, activeStates, href, sourceIndex, out,
          );
        }
      } else if (rule instanceof CSSSupportsRule) {
        sourceIndex = this.processRuleList(
          rule.cssRules, el, activeStates, href, sourceIndex, out,
        );
      } else if ('cssRules' in rule) {
        // CSSLayerBlockRule or similar
        sourceIndex = this.processRuleList(
          (rule as CSSRule & { cssRules: CSSRuleList }).cssRules,
          el, activeStates, href, sourceIndex, out,
        );
      }
    }

    return sourceIndex;
  }

  /**
   * Check ancestor hover chain patterns like `.parent:hover .child`.
   * Walk up to MAX_ANCESTOR_LEVELS, testing if an ancestor matches the
   * pseudo-stripped portion while the original element matches the rest.
   */
  private checkAncestorChains(
    el: Element,
    selectorText: string,
    activeStates: Set<PseudoState>,
    rule: CSSStyleRule,
    sourceIndex: number,
    out: CollectedDeclaration[],
  ): void {
    // Split selector by combinators to find ancestor-descendant patterns
    // Look for patterns where the pseudo is on an ancestor part
    const parts = this.splitByCombinators(selectorText);
    if (parts.length < 2) return;

    // For each split point, check if the left side (with pseudo stripped)
    // matches an ancestor and the right side matches the target element
    for (let splitAt = 0; splitAt < parts.length - 1; splitAt++) {
      const ancestorParts = parts.slice(0, splitAt + 1);
      const descendantParts = parts.slice(splitAt + 1);

      const ancestorSelector = ancestorParts.map(p => p.selector).join('');
      const descendantSelector = descendantParts.map(p => p.selector).join('');

      // Check if the ancestor portion contains the pseudo
      if (!this.containsActivePseudo(ancestorSelector, activeStates)) continue;

      const strippedAncestor = this.stripPseudos(ancestorSelector, activeStates);
      if (!strippedAncestor) continue;

      // Check if descendant selector (without pseudo) matches the target element
      // We need to construct a full selector: strippedAncestor + combinator + descendant
      // and test if el matches it
      const lastCombinator = ancestorParts[ancestorParts.length - 1].trailingCombinator ?? ' ';
      const fullSelector = `${strippedAncestor}${lastCombinator}${descendantSelector}`;

      // Walk ancestors and test
      let ancestor: Element | null = el.parentElement;
      for (let depth = 0; ancestor && depth < MAX_ANCESTOR_LEVELS; depth++) {
        try {
          if (ancestor.matches(strippedAncestor) && el.matches(fullSelector)) {
            const specificity = computeSpecificity(selectorText);
            this.extractDeclarations(rule.style, specificity, sourceIndex, out);
            return; // Found a match, no need to continue
          }
        } catch {
          // Invalid selector — skip
        }
        ancestor = ancestor.parentElement;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Selector parsing helpers
  // ---------------------------------------------------------------------------

  private containsActivePseudo(selector: string, activeStates: Set<PseudoState>): boolean {
    for (const state of activeStates) {
      const token = state.slice(1); // Remove leading ':'
      if (new RegExp(`:${token}(?![a-zA-Z-])`).test(selector)) return true;
    }
    return false;
  }

  private stripPseudos(selector: string, activeStates: Set<PseudoState>): string | null {
    let stripped = selector;
    for (const state of activeStates) {
      const token = state.slice(1);
      stripped = stripped.replace(new RegExp(`:${token}(?![a-zA-Z-])`, 'g'), '');
    }

    // Clean up artifacts: empty selectors, dangling colons
    stripped = stripped.replace(/:(?=[\s,>+~{]|$)/g, '').trim();
    if (!stripped || stripped === '>' || stripped === '+' || stripped === '~') return null;

    return stripped;
  }

  /** Split a selector into parts by combinators (space, >, +, ~). */
  private splitByCombinators(selector: string): Array<{ selector: string; trailingCombinator?: string }> {
    const parts: Array<{ selector: string; trailingCombinator?: string }> = [];
    let depth = 0;

    // Simple split respecting parentheses
    const chars = [...selector];
    let current = '';
    let i = 0;

    while (i < chars.length) {
      const ch = chars[i];
      if (ch === '(') { depth++; current += ch; i++; continue; }
      if (ch === ')') { depth--; current += ch; i++; continue; }
      if (ch === '[') { depth++; current += ch; i++; continue; }
      if (ch === ']') { depth--; current += ch; i++; continue; }

      if (depth === 0 && (ch === ' ' || ch === '>' || ch === '+' || ch === '~')) {
        // Found a combinator
        const trimmed = current.trim();
        if (trimmed) {
          // Consume the combinator (including surrounding whitespace)
          let comb = '';
          while (i < chars.length && (chars[i] === ' ' || chars[i] === '>' || chars[i] === '+' || chars[i] === '~')) {
            if (chars[i] !== ' ') comb = chars[i];
            i++;
          }
          parts.push({ selector: trimmed, trailingCombinator: comb || ' ' });
          current = '';
          continue;
        }
      }

      current += ch;
      i++;
    }

    const finalTrimmed = current.trim();
    if (finalTrimmed) {
      parts.push({ selector: finalTrimmed });
    }

    return parts;
  }

  private extractDeclarations(
    style: CSSStyleDeclaration,
    specificity: [number, number, number],
    sourceIndex: number,
    out: CollectedDeclaration[],
  ): void {
    for (let i = 0; i < style.length; i++) {
      const prop = style[i];
      const val = style.getPropertyValue(prop);
      const priority = style.getPropertyPriority(prop);
      out.push({
        property: prop,
        value: priority ? `${val}` : val, // strip !important for inline application
        specificity,
        sourceIndex,
      });
    }
  }

  private collectStyleSheets(excludeSheets: Set<CSSStyleSheet>): CSSStyleSheet[] {
    const sheets: CSSStyleSheet[] = [];
    for (const sheet of document.styleSheets) {
      if (excludeSheets.has(sheet)) continue;
      if (this.excludeHost && sheet.ownerNode && this.excludeHost.contains(sheet.ownerNode as Node)) continue;
      sheets.push(sheet);
    }
    for (const sheet of document.adoptedStyleSheets) {
      if (excludeSheets.has(sheet)) continue;
      sheets.push(sheet);
    }
    return sheets;
  }

  private notify(el: Element): void {
    for (const cb of this.changeCbs) cb(el);
  }
}
