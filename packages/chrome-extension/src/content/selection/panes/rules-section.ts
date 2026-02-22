// ---------------------------------------------------------------------------
// Rules section — CSS cascade view with toggle checkboxes
// ---------------------------------------------------------------------------

import type { MatchedRule, MatchResult } from '../../../shared/css-types';
import { compareSpecificity } from '../../inspection/specificity';
import type { MatchedRulesCache } from '../../inspection/matched-rules-cache';
import type { ToggleManager } from '../../inspection/toggle-manager';
import { createElement, createText } from '../../../shared/ui-utils';
import { OVERLAY } from '../../../shared/constants';

const DEBOUNCE_MS = 150;
const PAGE_SIZE = 50;
const LARGE_RULE_THRESHOLD = 100;

type ToggleChangeCb = (el: Element, property: string, toggled: boolean) => void;

/**
 * Rules section — renders matched CSS rules in specificity order.
 * Shows cascade/specificity ordering, overridden property detection,
 * filter support, pagination, and toggle checkboxes for exploration.
 */
export class RulesSection {
  private container: HTMLDivElement | null = null;
  private contentArea: HTMLDivElement | null = null;
  private currentElement: Element | null = null;
  private toggleChangeCb: ToggleChangeCb | null = null;
  private debounceTimer: ReturnType<typeof setTimeout> | null = null;
  private currentFilter = '';
  private visibleRuleCount = PAGE_SIZE;
  private excludeSheets: Set<CSSStyleSheet> | null = null;
  private excludeHost: Element | null = null;

  constructor(
    private readonly cache: MatchedRulesCache,
    private readonly toggleManager: ToggleManager,
  ) {}

  /** Set sheets and host to exclude from rule matching. */
  configure(excludeSheets: Set<CSSStyleSheet>, excludeHost?: Element): void {
    this.excludeSheets = excludeSheets;
    this.excludeHost = excludeHost ?? null;
  }

  mount(container: HTMLDivElement): void {
    this.container = container;
    this.contentArea = createElement('div', {}, {
      padding: '0',
    });
    container.appendChild(this.contentArea);
  }

  updateElement(el: Element): void {
    this.currentElement = el;
    this.visibleRuleCount = PAGE_SIZE;

    // Debounce to avoid redundant matching during rapid element switching
    if (this.debounceTimer) clearTimeout(this.debounceTimer);
    this.debounceTimer = setTimeout(() => {
      this.render();
    }, DEBOUNCE_MS);
  }

  clear(): void {
    this.currentElement = null;
    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = null;
    }
    if (this.contentArea) {
      this.contentArea.innerHTML = '';
      const empty = createText('div', 'No element selected', 'mono');
      empty.style.color = OVERLAY.textMuted;
      empty.style.padding = '8px';
      this.contentArea.appendChild(empty);
    }
  }

  dispose(): void {
    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = null;
    }
    this.container = null;
    this.contentArea = null;
    this.currentElement = null;
    this.toggleChangeCb = null;
    this.excludeSheets = null;
    this.excludeHost = null;
  }

  setFilter(query: string): void {
    this.currentFilter = query.toLowerCase().trim();
    this.applyFilter();
  }

  onToggleChange(cb: ToggleChangeCb): void {
    this.toggleChangeCb = cb;
  }

  // ---------------------------------------------------------------------------
  // Rendering
  // ---------------------------------------------------------------------------

  private render(): void {
    if (!this.contentArea || !this.currentElement) return;
    this.contentArea.innerHTML = '';

    const result = this.cache.get(
      this.currentElement,
      this.excludeSheets ?? undefined,
      this.excludeHost ?? undefined,
    );

    // Access level banner
    if (result.accessLevel === 'partial' || result.accessLevel === 'none') {
      this.contentArea.appendChild(this.buildAccessBanner(result));
    }

    // Sort rules: highest specificity first, source order tiebreaker
    const sorted = this.sortRules(result.rules);

    // Determine overridden declarations
    const overridden = this.computeOverridden(sorted);

    // Inline styles block first (if any)
    const inlineRules = sorted.filter((r) => r.isInline);
    const matchedRules = sorted.filter((r) => !r.isInline);

    for (const rule of inlineRules) {
      this.contentArea.appendChild(
        this.buildRuleBlock(rule, overridden, true),
      );
    }

    // Pagination
    const totalMatched = matchedRules.length;
    const visibleRules = matchedRules.slice(0, this.visibleRuleCount);

    for (const rule of visibleRules) {
      this.contentArea.appendChild(
        this.buildRuleBlock(rule, overridden, false),
      );
    }

    // "Show more" button
    if (totalMatched > this.visibleRuleCount) {
      const remaining = totalMatched - this.visibleRuleCount;
      this.contentArea.appendChild(this.buildShowMoreButton(remaining));
    }

    // Footer: toggles disclaimer
    if (sorted.length > 0) {
      this.contentArea.appendChild(this.buildToggleDisclaimer());
    }

    // Apply filter if active
    if (this.currentFilter) {
      this.applyFilter();
    }
  }

  // ---------------------------------------------------------------------------
  // Access banner
  // ---------------------------------------------------------------------------

  private buildAccessBanner(result: MatchResult): HTMLDivElement {
    const banner = createElement('div', {}, {
      padding: '6px 10px',
      background: 'rgba(245, 158, 11, 0.1)',
      borderBottom: `1px solid ${OVERLAY.border}`,
      fontSize: '10px',
      fontFamily: OVERLAY.monoFamily,
      color: OVERLAY.warning,
      lineHeight: '1.4',
    });
    banner.textContent = result.accessMessage
      ?? 'Some stylesheets could not be read (cross-origin). Rules may be incomplete.';
    return banner;
  }

  // ---------------------------------------------------------------------------
  // Rule block
  // ---------------------------------------------------------------------------

  private buildRuleBlock(
    rule: MatchedRule,
    overridden: Set<string>,
    isInlineBlock: boolean,
  ): HTMLDivElement {
    const block = createElement('div', {}, {
      borderBottom: `1px solid ${OVERLAY.border}`,
      padding: '6px 10px',
    });
    block.setAttribute('data-rule-block', '');

    // Header line: selector + source + specificity
    const header = createElement('div', {}, {
      display: 'flex',
      justifyContent: 'space-between',
      alignItems: 'center',
      gap: '8px',
      marginBottom: '4px',
    });

    const selectorEl = createText('span', rule.selectorText, 'mono');
    selectorEl.style.color = OVERLAY.primary;
    selectorEl.style.fontWeight = '500';
    selectorEl.style.flex = '1';
    selectorEl.style.overflow = 'hidden';
    selectorEl.style.textOverflow = 'ellipsis';
    selectorEl.style.whiteSpace = 'nowrap';
    selectorEl.setAttribute('data-rule-selector', rule.selectorText);
    header.appendChild(selectorEl);

    // Source origin (right-aligned)
    if (rule.sourceHref) {
      const basename = rule.sourceHref.split('/').pop() ?? rule.sourceHref;
      const sourceEl = createText('span', basename, 'mono');
      sourceEl.style.color = OVERLAY.textMuted;
      sourceEl.style.fontSize = '10px';
      sourceEl.style.flexShrink = '0';
      header.appendChild(sourceEl);
    }

    // Specificity badge (not for inline styles — they're always highest)
    if (!isInlineBlock && isFinite(rule.specificity[0])) {
      const specBadge = createElement('span', {}, {
        background: 'rgba(255, 255, 255, 0.08)',
        border: `1px solid ${OVERLAY.border}`,
        borderRadius: '3px',
        padding: '0 4px',
        fontSize: '9px',
        fontFamily: OVERLAY.monoFamily,
        color: OVERLAY.textMuted,
        whiteSpace: 'nowrap',
        flexShrink: '0',
      });
      specBadge.textContent = `(${rule.specificity[0]},${rule.specificity[1]},${rule.specificity[2]})`;
      header.appendChild(specBadge);
    }

    block.appendChild(header);

    // Media query indicator
    if (rule.mediaQuery) {
      const mediaEl = createText('div', `@media ${rule.mediaQuery}`, 'mono');
      mediaEl.style.color = OVERLAY.textMuted;
      mediaEl.style.fontSize = '10px';
      mediaEl.style.fontStyle = 'italic';
      mediaEl.style.marginBottom = '2px';
      block.appendChild(mediaEl);
    }

    // Layer indicator
    if (rule.layerName) {
      const layerEl = createText('div', `@layer ${rule.layerName}`, 'mono');
      layerEl.style.color = OVERLAY.textMuted;
      layerEl.style.fontSize = '10px';
      layerEl.style.fontStyle = 'italic';
      layerEl.style.marginBottom = '2px';
      block.appendChild(layerEl);
    }

    // Declarations
    const declList = createElement('div', {}, {
      paddingLeft: '12px',
    });

    for (const [prop, val] of rule.declarations) {
      const overriddenKey = `${prop}|||${rule.selectorText}|||${rule.sourceIndex}`;
      const isOverridden = overridden.has(overriddenKey);

      declList.appendChild(
        this.buildDeclarationRow(prop, val, rule, isOverridden),
      );
    }

    block.appendChild(declList);
    return block;
  }

  // ---------------------------------------------------------------------------
  // Declaration row with toggle checkbox
  // ---------------------------------------------------------------------------

  private buildDeclarationRow(
    property: string,
    value: string,
    rule: MatchedRule,
    isOverridden: boolean,
  ): HTMLDivElement {
    const row = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '6px',
      padding: '1px 0',
      opacity: isOverridden ? '0.5' : '1',
    });
    row.setAttribute('data-rule-prop', property);

    // Toggle checkbox
    const checkbox = createElement('span', {}, {
      width: '12px',
      height: '12px',
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: '2px',
      display: 'inline-flex',
      alignItems: 'center',
      justifyContent: 'center',
      cursor: 'pointer',
      flexShrink: '0',
      fontSize: '9px',
      lineHeight: '1',
      pointerEvents: 'auto',
      background: 'transparent',
    });

    const el = this.currentElement;
    const isOff = el ? this.toggleManager.isToggledOff(el, property) : false;
    this.renderCheckbox(checkbox, !isOff);

    checkbox.addEventListener('click', (e) => {
      e.stopPropagation();
      if (!el) return;

      if (this.toggleManager.isToggledOff(el, property)) {
        this.toggleManager.toggleOn(el, property);
        this.renderCheckbox(checkbox, true);
        this.toggleChangeCb?.(el, property, true);
      } else {
        this.toggleManager.toggleOff(el, property);
        this.renderCheckbox(checkbox, false);
        this.toggleChangeCb?.(el, property, false);
      }
    });

    row.appendChild(checkbox);

    // Property name
    const nameEl = createText('span', property, 'mono');
    nameEl.style.color = OVERLAY.textMuted;
    nameEl.style.flexShrink = '0';
    row.appendChild(nameEl);

    // Colon separator
    const colonEl = createText('span', ':', 'mono');
    colonEl.style.color = OVERLAY.textMuted;
    colonEl.style.marginRight = '4px';
    row.appendChild(colonEl);

    // Value
    const valueEl = createText('span', value, 'mono');
    valueEl.style.flex = '1';
    valueEl.style.overflow = 'hidden';
    valueEl.style.textOverflow = 'ellipsis';
    valueEl.style.whiteSpace = 'nowrap';
    if (isOverridden) {
      valueEl.style.textDecoration = 'line-through';
    }
    row.appendChild(valueEl);

    return row;
  }

  private renderCheckbox(el: HTMLElement, checked: boolean): void {
    if (checked) {
      el.textContent = '\u2713'; // checkmark
      el.style.background = 'rgba(6, 182, 212, 0.3)';
      el.style.borderColor = OVERLAY.primary;
      el.style.color = OVERLAY.primary;
    } else {
      el.textContent = '';
      el.style.background = 'transparent';
      el.style.borderColor = OVERLAY.border;
      el.style.color = '';
    }
  }

  // ---------------------------------------------------------------------------
  // Overridden detection
  // ---------------------------------------------------------------------------

  /**
   * Determine which declarations are overridden in the cascade.
   * Returns a set of keys "property|||selectorText|||sourceIndex" for overridden entries.
   */
  private computeOverridden(sortedRules: MatchedRule[]): Set<string> {
    const overridden = new Set<string>();
    const winners = new Map<string, { selectorText: string; sourceIndex: number; important: boolean }>();

    // Process in specificity order (highest first). First occurrence of each property wins,
    // unless a later !important overrides a non-important.
    for (const rule of sortedRules) {
      for (const [prop, val] of rule.declarations) {
        const isImportant = val.endsWith('!important');
        const existing = winners.get(prop);

        if (!existing) {
          // First (highest specificity) declaration wins
          winners.set(prop, { selectorText: rule.selectorText, sourceIndex: rule.sourceIndex, important: isImportant });
        } else if (isImportant && !existing.important) {
          // !important overrides normal regardless of specificity
          const existingKey = `${prop}|||${existing.selectorText}|||${existing.sourceIndex}`;
          overridden.add(existingKey);
          winners.set(prop, { selectorText: rule.selectorText, sourceIndex: rule.sourceIndex, important: isImportant });
        } else {
          // This declaration is overridden
          const key = `${prop}|||${rule.selectorText}|||${rule.sourceIndex}`;
          overridden.add(key);
        }
      }
    }

    return overridden;
  }

  // ---------------------------------------------------------------------------
  // Sort rules
  // ---------------------------------------------------------------------------

  private sortRules(rules: MatchedRule[]): MatchedRule[] {
    return [...rules].sort((a, b) => {
      // Inline styles always first
      if (a.isInline && !b.isInline) return -1;
      if (!a.isInline && b.isInline) return 1;

      // Higher specificity first
      const specCmp = compareSpecificity(b.specificity, a.specificity);
      if (specCmp !== 0) return specCmp;

      // Later source order first (higher index = later in cascade)
      return b.sourceIndex - a.sourceIndex;
    });
  }

  // ---------------------------------------------------------------------------
  // Pagination
  // ---------------------------------------------------------------------------

  private buildShowMoreButton(remaining: number): HTMLDivElement {
    const wrapper = createElement('div', {}, {
      padding: '8px 10px',
      textAlign: 'center',
    });

    const btn = createElement('button', {}, {
      background: 'rgba(255, 255, 255, 0.08)',
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusSm,
      padding: '4px 12px',
      color: OVERLAY.primary,
      fontSize: '11px',
      fontFamily: OVERLAY.monoFamily,
      cursor: 'pointer',
      pointerEvents: 'auto',
    });
    btn.textContent = `Show ${Math.min(remaining, PAGE_SIZE)} more rules\u2026`;
    btn.addEventListener('click', () => {
      this.visibleRuleCount += PAGE_SIZE;
      this.render();
    });

    wrapper.appendChild(btn);
    return wrapper;
  }

  // ---------------------------------------------------------------------------
  // Toggle disclaimer footer
  // ---------------------------------------------------------------------------

  private buildToggleDisclaimer(): HTMLDivElement {
    const footer = createElement('div', {}, {
      padding: '8px 10px',
      fontSize: '10px',
      fontFamily: OVERLAY.monoFamily,
      color: OVERLAY.textMuted,
      fontStyle: 'italic',
      borderTop: `1px solid ${OVERLAY.border}`,
    });
    footer.textContent = 'Toggles are temporary previews. Use the Edit tab to make persistent changes.';
    return footer;
  }

  // ---------------------------------------------------------------------------
  // Filter
  // ---------------------------------------------------------------------------

  private applyFilter(): void {
    if (!this.contentArea) return;
    const q = this.currentFilter;

    const ruleBlocks = this.contentArea.querySelectorAll('[data-rule-block]');

    if (!q) {
      ruleBlocks.forEach((b) => ((b as HTMLElement).style.display = ''));
      return;
    }

    ruleBlocks.forEach((block) => {
      const el = block as HTMLElement;
      const selectorEl = el.querySelector('[data-rule-selector]');
      const selector = selectorEl?.getAttribute('data-rule-selector') ?? '';
      const propRows = el.querySelectorAll('[data-rule-prop]');

      let matchesSelector = selector.toLowerCase().includes(q);
      let anyPropMatch = false;

      propRows.forEach((row) => {
        const prop = row.getAttribute('data-rule-prop') ?? '';
        if (prop.toLowerCase().includes(q)) {
          anyPropMatch = true;
          (row as HTMLElement).style.display = '';
        } else if (!matchesSelector) {
          (row as HTMLElement).style.display = 'none';
        }
      });

      el.style.display = matchesSelector || anyPropMatch ? '' : 'none';
    });
  }
}
