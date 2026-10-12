import type { VisualDiff } from '@nco-studio/shared';
import { createElement, createText } from '../../../shared/ui-utils';
import { OVERLAY } from '../../../shared/constants';
import { getComputedProperty, generateSelector, createStyleSnapshot, snapshotGet } from '../../../shared/dom-utils';
import type { ComputedStyleSnapshot } from '../../../shared/dom-utils';
import type { TokenStore } from '../../tokens/store';
import type { PendingQueue } from '../../batching/queue';
import type { ToggleManager } from '../../inspection/toggle-manager';
import type { MatchedRulesCache } from '../../inspection/matched-rules-cache';
import type { StateSimulator, PseudoState } from '../../inspection/state-simulator';
import { PSEUDO_STATES } from '../../inspection/state-simulator';
import { InlineEditor } from './inline-editor';
import { createColorSwatch } from './enrichments/color-swatch';
import { checkInactive, applyInactiveStyles } from './enrichments/inactive-css';
import { findPendingChange, applyPendingDot } from './enrichments/pending-indicator';
import { computeContrast, createContrastBadge } from './enrichments/contrast-badge';
import { createVarBadge, createVarTooltip, cleanupVarTooltip } from './enrichments/var-badge';
import type { VariableResolver } from '../../inspection/variable-resolver';

type PropertyChangeCb = (property: string, fromValue: string, toValue: string, token?: string) => void;
type MultiPropertyChangeCb = (changes: Array<{ element: Element; property: string; fromValue: string; toValue: string; token?: string }>) => void;
type ScrollToRuleCb = (selectorText: string) => void;

const PROPERTY_GROUPS: Array<{ label: string; props: string[] }> = [
  { label: 'Dimensions', props: ['width', 'height', 'min-width', 'min-height', 'max-width', 'max-height'] },
  { label: 'Spacing', props: ['padding-top', 'padding-right', 'padding-bottom', 'padding-left', 'margin-top', 'margin-right', 'margin-bottom', 'margin-left'] },
  { label: 'Typography', props: ['font-family', 'font-size', 'font-weight', 'font-style', 'line-height', 'letter-spacing', 'text-align', 'text-decoration', 'text-transform', 'white-space', 'word-break', 'color'] },
  { label: 'Background', props: ['background-color', 'background-image', 'background-size', 'background-position', 'background-repeat'] },
  { label: 'Position', props: ['position', 'top', 'right', 'bottom', 'left', 'z-index'] },
  { label: 'Border', props: ['border-radius', 'border-width', 'border-style', 'border-color', 'border-top-width', 'border-right-width', 'border-bottom-width', 'border-left-width'] },
  { label: 'Appearance', props: ['opacity', 'box-shadow', 'outline-style', 'outline-width', 'outline-color', 'outline-offset', 'cursor', 'visibility'] },
  { label: 'Effects', props: ['filter', 'backdrop-filter', 'mix-blend-mode', 'clip-path'] },
  { label: 'Display & Overflow', props: ['display', 'overflow', 'overflow-x', 'overflow-y'] },
  { label: 'Transform', props: ['transform', 'transform-origin'] },
  { label: 'Transition', props: ['transition-property', 'transition-duration', 'transition-timing-function', 'transition-delay'] },
];

/**
 * CSS groups section — renders property groups for the Edit tab.
 * Supports both single-select (snapshot-based) and multi-select (per-element) modes.
 * Uses enriched property row structure with indicator, badge, and annotation slots.
 * Enrichments: color swatches, inactive CSS indicators, pending-change dots, contrast badges.
 */
export class CssGroupsSection {
  private propChangeCb: PropertyChangeCb | null = null;
  private multiPropChangeCb: MultiPropertyChangeCb | null = null;
  private currentElement: Element | null = null;
  private inlineEditor: InlineEditor;
  private toggleManager: ToggleManager | null = null;
  private rulesCache: MatchedRulesCache | null = null;
  private stateSimulator: StateSimulator | null = null;
  private hovToggleOpen = false;
  private stateRefreshCb: (() => void) | null = null;
  private variableResolver: VariableResolver | null = null;
  private activeVarTooltip: HTMLDivElement | null = null;
  private scrollToRuleCb: ScrollToRuleCb | null = null;
  private dismissRoot: EventTarget | null = null;

  constructor(
    private readonly tokenStore: TokenStore,
    private readonly pendingQueue: PendingQueue,
  ) {
    this.inlineEditor = new InlineEditor(tokenStore);
  }

  /** Set inspection dependencies (lazily provided by PropertiesPane on first Rules tab activation). */
  setInspectionDeps(toggleManager: ToggleManager, cache: MatchedRulesCache): void {
    this.toggleManager = toggleManager;
    this.rulesCache = cache;
    this.inlineEditor.setToggleManager(toggleManager);
  }

  /** Set the state simulator for :hov toggles (eagerly provided by PropertiesPane). */
  setStateSimulator(sim: StateSimulator): void {
    this.stateSimulator = sim;
  }

  /** Register callback to refresh the Edit tab when state toggles change. */
  onStateToggleRefresh(cb: () => void): void {
    this.stateRefreshCb = cb;
  }

  /** Set the variable resolver (lazily provided on first Rules tab activation). Null clears it. */
  setVariableResolver(resolver: VariableResolver | null): void {
    this.variableResolver = resolver;
  }

  /** Register callback to scroll to a rule in the Rules tab. */
  onScrollToRule(cb: ScrollToRuleCb): void {
    this.scrollToRuleCb = cb;
  }

  /** Set the event target root for click-outside dismiss (shadow root). */
  setDismissRoot(root: EventTarget): void {
    this.dismissRoot = root;
  }

  onPropertyChange(cb: PropertyChangeCb): void {
    this.propChangeCb = cb;
  }

  onMultiPropertyChange(cb: MultiPropertyChangeCb): void {
    this.multiPropChangeCb = cb;
  }

  // ---------------------------------------------------------------------------
  // Single-select
  // ---------------------------------------------------------------------------

  buildSingle(el: Element, snapshot: ComputedStyleSnapshot, excludeGroups: string[] = []): HTMLDivElement {
    this.currentElement = el;
    const wrapper = createElement('div', {}, {});
    wrapper.appendChild(this.buildClassesSection(el));
    wrapper.appendChild(this.buildCssPropertiesSection(el, snapshot, excludeGroups));
    return wrapper;
  }

  // ---------------------------------------------------------------------------
  // Multi-select
  // ---------------------------------------------------------------------------

  buildMulti(elements: Element[]): HTMLDivElement {
    this.currentElement = elements[0] ?? null;
    const wrapper = createElement('div', {}, {});

    // Multi-select header with count badge
    const header = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      padding: '6px 10px',
      borderBottom: `1px solid ${OVERLAY.border}`,
      background: 'rgba(59, 130, 246, 0.08)',
      gap: '6px',
    });
    const badge = createElement('span', {}, {
      background: OVERLAY.infoFill,
      color: OVERLAY.onInfo,
      padding: '1px 6px',
      borderRadius: '10px',
      fontSize: '10px',
      fontFamily: OVERLAY.monoFamily,
      fontWeight: '600',
      flexShrink: '0',
    });
    badge.textContent = `${elements.length}`;
    header.appendChild(badge);

    const title = createText('span', 'elements selected', 'heading');
    title.style.fontSize = '12px';
    title.style.flex = '1';
    header.appendChild(title);

    wrapper.appendChild(header);
    wrapper.appendChild(this.buildMultiCssPropertiesSection(elements));
    return wrapper;
  }

  // ---------------------------------------------------------------------------
  // Classes & ID section
  // ---------------------------------------------------------------------------

  private buildClassesSection(element: Element): HTMLDivElement {
    const section = createElement('div', {}, {
      padding: '6px 10px',
      borderBottom: `1px solid ${OVERLAY.border}`,
      display: 'flex',
      flexWrap: 'wrap',
      gap: '4px',
      alignItems: 'center',
    });

    const id = element.id;
    const classes = Array.from(element.classList);

    if (!id && classes.length === 0) {
      const empty = createText('span', 'No classes or ID', 'mono');
      empty.style.color = OVERLAY.textMuted;
      empty.style.fontSize = '10px';
      section.appendChild(empty);
      return section;
    }

    if (id) {
      const pill = createElement('span', {}, {
        background: 'rgba(245, 158, 11, 0.15)',
        border: '1px solid rgba(245, 158, 11, 0.4)',
        borderRadius: '3px',
        padding: '1px 5px',
        fontSize: '10px',
        fontFamily: OVERLAY.monoFamily,
        color: OVERLAY.warning,
        lineHeight: '1.4',
        whiteSpace: 'nowrap',
      });
      pill.textContent = `#${id}`;
      section.appendChild(pill);
    }

    for (const cls of classes) {
      const pill = createElement('span', {}, {
        background: OVERLAY.hover,
        border: `1px solid ${OVERLAY.border}`,
        borderRadius: '3px',
        padding: '1px 5px',
        fontSize: '10px',
        fontFamily: OVERLAY.monoFamily,
        color: OVERLAY.text,
        lineHeight: '1.4',
        whiteSpace: 'nowrap',
      });
      pill.textContent = `.${cls}`;
      section.appendChild(pill);
    }

    // :hov toggle button
    if (this.stateSimulator) {
      const hasActive = this.stateSimulator.hasActiveStates(element);
      const hovBtn = createElement('button', {
        title: 'Simulates CSS pseudo-class styles. Some effects may not be captured.',
      }, {
        background: hasActive ? 'rgba(6, 182, 212, 0.12)' : OVERLAY.hover,
        border: `1px solid ${hasActive ? 'rgba(6, 182, 212, 0.4)' : OVERLAY.border}`,
        borderRadius: '3px',
        padding: '1px 5px',
        fontSize: '10px',
        fontFamily: OVERLAY.monoFamily,
        color: hasActive ? OVERLAY.primary : OVERLAY.textMuted,
        lineHeight: '1.4',
        whiteSpace: 'nowrap',
        cursor: 'pointer',
        pointerEvents: 'auto',
        marginLeft: 'auto',
        flexShrink: '0',
      });
      hovBtn.textContent = ':hov';
      hovBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        this.hovToggleOpen = !this.hovToggleOpen;
        this.renderToggleStrip(section, element);
      });
      section.appendChild(hovBtn);

      if (this.hovToggleOpen) {
        this.renderToggleStrip(section, element);
      }
    }

    return section;
  }

  // ---------------------------------------------------------------------------
  // State toggle strip
  // ---------------------------------------------------------------------------

  private renderToggleStrip(parent: HTMLDivElement, element: Element): void {
    const existing = parent.querySelector('[data-state-toggles]');
    existing?.remove();

    if (!this.hovToggleOpen || !this.stateSimulator) return;

    const strip = createElement('div', {}, {
      display: 'flex',
      gap: '4px',
      flexBasis: '100%',
      padding: '4px 0 0 0',
    });
    strip.setAttribute('data-state-toggles', '');

    for (const state of PSEUDO_STATES) {
      const isActive = this.stateSimulator.isActive(element, state);
      const chip = createElement('button', {}, {
        background: isActive ? 'rgba(6, 182, 212, 0.12)' : 'transparent',
        border: `1px solid ${isActive ? 'rgba(6, 182, 212, 0.4)' : OVERLAY.border}`,
        borderRadius: '3px',
        padding: '1px 6px',
        fontSize: '10px',
        fontFamily: OVERLAY.monoFamily,
        color: isActive ? OVERLAY.primary : OVERLAY.textMuted,
        cursor: 'pointer',
        pointerEvents: 'auto',
        transition: 'background 0.1s, border-color 0.1s',
      });
      chip.textContent = state;
      chip.addEventListener('click', (e) => {
        e.stopPropagation();
        if (this.stateSimulator!.isActive(element, state)) {
          this.stateSimulator!.deactivate(element, state);
        } else {
          this.stateSimulator!.activate(element, state);
        }
        this.stateRefreshCb?.();
      });
      strip.appendChild(chip);
    }

    parent.appendChild(strip);
  }

  // ---------------------------------------------------------------------------
  // Single-select CSS properties
  // ---------------------------------------------------------------------------

  private buildCssPropertiesSection(
    element: Element,
    snapshot: ComputedStyleSnapshot,
    excludeGroups: string[],
  ): HTMLDivElement {
    const section = createElement('div', {}, {
      padding: '8px 10px',
    });

    const elementSelector = generateSelector(element);
    const activeDiffs = this.pendingQueue.getActive();

    for (const group of PROPERTY_GROUPS) {
      if (excludeGroups.includes(group.label)) continue;

      const groupLabel = createText('div', group.label, 'heading');
      groupLabel.setAttribute('data-group-label', group.label);
      groupLabel.style.marginTop = '8px';
      groupLabel.style.marginBottom = '4px';
      groupLabel.style.fontSize = OVERLAY.monoSize;
      groupLabel.style.color = OVERLAY.textMuted;
      groupLabel.style.textTransform = 'uppercase';
      groupLabel.style.letterSpacing = '0.5px';
      section.appendChild(groupLabel);

      const propsGrid = createElement('div', {}, {
        display: 'grid',
        gridTemplateColumns: 'repeat(auto-fill, minmax(180px, 1fr))',
        gap: '0 16px',
      });
      for (const prop of group.props) {
        const value = snapshotGet(snapshot, prop);
        propsGrid.appendChild(
          this.buildPropertyRow(prop, value, element, snapshot, elementSelector, activeDiffs),
        );
      }
      section.appendChild(propsGrid);
    }

    return section;
  }

  // ---------------------------------------------------------------------------
  // Multi-select CSS properties
  // ---------------------------------------------------------------------------

  private buildMultiCssPropertiesSection(elements: Element[]): HTMLDivElement {
    const section = createElement('div', {}, {
      padding: '8px 10px',
    });

    const snapshot = createStyleSnapshot(elements[0]);

    for (const group of PROPERTY_GROUPS) {
      const groupLabel = createText('div', group.label, 'heading');
      groupLabel.setAttribute('data-group-label', group.label);
      groupLabel.style.marginTop = '8px';
      groupLabel.style.marginBottom = '4px';
      groupLabel.style.fontSize = OVERLAY.monoSize;
      groupLabel.style.color = OVERLAY.textMuted;
      groupLabel.style.textTransform = 'uppercase';
      groupLabel.style.letterSpacing = '0.5px';
      section.appendChild(groupLabel);

      const propsGrid = createElement('div', {}, {
        display: 'grid',
        gridTemplateColumns: 'repeat(auto-fill, minmax(180px, 1fr))',
        gap: '0 16px',
      });
      for (const prop of group.props) {
        const values = elements.map((el) => getComputedProperty(el, prop));
        const allSame = values.every((v) => v === values[0]);
        const displayValue = allSame ? (values[0] ?? '') : 'Mixed';
        propsGrid.appendChild(
          this.buildMultiPropertyRow(prop, displayValue, !allSame, elements, snapshot),
        );
      }
      section.appendChild(propsGrid);
    }

    return section;
  }

  // ---------------------------------------------------------------------------
  // Enriched property row — single select
  // ---------------------------------------------------------------------------

  private buildPropertyRow(
    name: string,
    value: string,
    element: Element,
    snapshot: ComputedStyleSnapshot,
    elementSelector: string,
    activeDiffs: VisualDiff[],
  ): HTMLDivElement {
    const row = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      padding: '2px 0',
    });
    row.setAttribute('data-prop-row', '');
    row.setAttribute('data-prop-name', name);
    row.setAttribute('data-prop-value', value);

    // Main line: [indicator-slot] [property-name] [value-container with badge-slot]
    const mainLine = createElement('div', {}, {
      display: 'flex',
      justifyContent: 'space-between',
      alignItems: 'center',
      gap: '8px',
    });

    // Indicator slot (4px)
    const indicatorSlot = createElement('span', {}, {
      width: '4px',
      flexShrink: '0',
      display: 'inline-block',
    });
    mainLine.appendChild(indicatorSlot);

    const nameEl = createText('span', name, 'mono');
    nameEl.style.color = OVERLAY.textMuted;
    nameEl.style.flexShrink = '0';
    mainLine.appendChild(nameEl);

    // Enrichment: pending-change indicator (indicator-slot)
    const pendingFrom = findPendingChange(activeDiffs, elementSelector, name);
    if (pendingFrom) {
      applyPendingDot(indicatorSlot, pendingFrom);
    }

    // Enrichment: inactive CSS indicator (skip if pending — user explicitly set this value)
    if (!pendingFrom) {
      const inactiveReason = checkInactive(name, snapshot);
      if (inactiveReason) {
        applyInactiveStyles(row, nameEl, indicatorSlot, inactiveReason);
      }
    }

    // Value container with badge slot
    const valueContainer = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '4px',
      overflow: 'hidden',
      cursor: 'pointer',
      pointerEvents: 'auto',
    });

    const valueEl = createText('span', value, 'mono');
    valueEl.style.textOverflow = 'ellipsis';
    valueEl.style.overflow = 'hidden';
    valueEl.style.whiteSpace = 'nowrap';
    valueContainer.appendChild(valueEl);

    // Enrichment: color swatch (badge-slot, before other badges)
    const openEditor = () => {
      this.inlineEditor.openSingle(
        row,
        valueContainer,
        name,
        value,
        (property, fromValue, toValue, tokenName) => {
          this.propChangeCb?.(property, fromValue, toValue, tokenName);
        },
        element,
      );
    };

    const swatch = createColorSwatch(name, value, openEditor);
    if (swatch) {
      valueContainer.appendChild(swatch);
    }

    // Enrichment: contrast ratio badge (badge-slot, for color property)
    const contrast = computeContrast(name, snapshot, element);
    if (contrast) {
      valueContainer.appendChild(createContrastBadge(contrast));
    }

    // Badge slot — token badge (existing behavior)
    const token = this.inlineEditor.resolveToken(name, value);
    if (token) {
      const badgeEl = createElement('span', {}, {
        background: 'rgba(6, 182, 212, 0.2)',
        color: OVERLAY.primary,
        padding: '1px 4px',
        borderRadius: '2px',
        fontSize: '10px',
        fontFamily: OVERLAY.monoFamily,
        whiteSpace: 'nowrap',
        flexShrink: '0',
      });
      badgeEl.textContent = token.name;
      valueContainer.appendChild(badgeEl);
    }

    // Enrichment: var badge (badge-slot, when authored value contains var())
    if (this.variableResolver) {
      const winningRule = this.findWinningRule(name, element);
      if (winningRule && winningRule.authoredValue.includes('var(')) {
        const varBadge = createVarBadge(winningRule.authoredValue, () => {
          this.showVarTooltip(varBadge!, winningRule!.authoredValue, element);
        });
        if (varBadge) {
          valueContainer.appendChild(varBadge);
        }
      }
    }

    valueContainer.addEventListener('click', openEditor);

    valueContainer.addEventListener('mouseenter', () => {
      valueEl.style.textDecoration = 'underline';
      valueEl.style.textDecorationStyle = 'dotted';
    });
    valueContainer.addEventListener('mouseleave', () => {
      valueEl.style.textDecoration = '';
    });

    mainLine.appendChild(valueContainer);
    row.appendChild(mainLine);

    // Annotation slot — rule source annotation (progressive enhancement: only when cache populated)
    const annotationSlot = createElement('div', {}, {
      display: 'none',
      paddingLeft: '12px',
      fontSize: '10px',
      color: OVERLAY.textMuted,
      fontFamily: OVERLAY.monoFamily,
    });
    this.populateAnnotation(annotationSlot, name, value, element);
    row.appendChild(annotationSlot);

    return row;
  }

  // ---------------------------------------------------------------------------
  // Winning rule lookup (shared by annotation and var badge)
  // ---------------------------------------------------------------------------

  private findWinningRule(
    property: string,
    element: Element,
  ): { selectorText: string; sourceHref: string | null; authoredValue: string } | null {
    if (!this.rulesCache || !this.rulesCache.has(element)) return null;

    const excludeSheets = new Set<CSSStyleSheet>();
    const toggleSheet = this.toggleManager?.getSheet();
    if (toggleSheet) excludeSheets.add(toggleSheet);

    const result = this.rulesCache.get(element, excludeSheets);
    if (!result || result.rules.length === 0) return null;

    const seenProps = new Set<string>();
    let winner: { selectorText: string; sourceHref: string | null; authoredValue: string } | null = null;

    const sorted = [...result.rules].sort((a, b) => {
      if (a.isInline && !b.isInline) return -1;
      if (!a.isInline && b.isInline) return 1;
      const s0 = b.specificity[0] - a.specificity[0];
      if (s0 !== 0) return s0;
      const s1 = b.specificity[1] - a.specificity[1];
      if (s1 !== 0) return s1;
      const s2 = b.specificity[2] - a.specificity[2];
      if (s2 !== 0) return s2;
      return b.sourceIndex - a.sourceIndex;
    });

    for (const rule of sorted) {
      if (rule.declarations.has(property)) {
        const val = rule.declarations.get(property)!;
        const isImportant = val.endsWith('!important');
        if (!seenProps.has(property) || isImportant) {
          winner = {
            selectorText: rule.selectorText,
            sourceHref: rule.sourceHref,
            authoredValue: val.replace(/\s*!important$/, ''),
          };
          if (!isImportant) seenProps.add(property);
          else break;
        }
        seenProps.add(property);
      }
    }

    return winner;
  }

  // ---------------------------------------------------------------------------
  // Annotation slot — rule source cross-reference
  // ---------------------------------------------------------------------------

  private populateAnnotation(
    slot: HTMLDivElement,
    property: string,
    computedValue: string,
    element: Element,
  ): void {
    const winningRule = this.findWinningRule(property, element);
    if (!winningRule || winningRule.selectorText === 'element.style') return;

    const source = winningRule.sourceHref
      ? winningRule.sourceHref.split('/').pop() ?? winningRule.sourceHref
      : 'inline';

    let annotationText = `from ${winningRule.selectorText} in ${source}`;

    const authored = winningRule.authoredValue.trim();
    const computed = computedValue.trim();
    if (authored !== computed && authored) {
      if (authored.includes('var(')) {
        annotationText += ` \u00b7 ${authored}`;
      } else {
        annotationText += ` \u00b7 authored: ${authored}`;
      }
    }

    const textEl = createText('span', `\u25b8 ${annotationText}`, 'mono');
    textEl.style.fontSize = '10px';
    textEl.style.color = OVERLAY.textMuted;
    textEl.style.cursor = 'default';
    slot.appendChild(textEl);
    slot.style.display = 'block';
    slot.style.padding = '1px 0 1px 12px';
  }

  // ---------------------------------------------------------------------------
  // Variable resolution tooltip
  // ---------------------------------------------------------------------------

  private showVarTooltip(badge: HTMLSpanElement, authoredValue: string, element: Element): void {
    this.dismissVarTooltip();
    if (!this.variableResolver) return;

    // Extract the variable name from the authored value
    const varMatch = authoredValue.match(/var\(\s*(--[a-zA-Z0-9_-]+)/);
    if (!varMatch) return;

    const result = this.variableResolver.resolve(element, varMatch[1]);

    const tooltip = createVarTooltip(
      result,
      (selectorText) => {
        this.dismissVarTooltip();
        this.scrollToRuleCb?.(selectorText);
      },
      () => this.dismissVarTooltip(),
      this.dismissRoot ?? undefined,
    );

    // Position below the badge
    badge.style.position = 'relative';
    tooltip.style.top = '100%';
    tooltip.style.left = '0';
    tooltip.style.marginTop = '4px';
    badge.appendChild(tooltip);
    this.activeVarTooltip = tooltip;
  }

  private dismissVarTooltip(): void {
    if (this.activeVarTooltip) {
      cleanupVarTooltip(this.activeVarTooltip);
      this.activeVarTooltip.remove();
    }
    this.activeVarTooltip = null;
  }

  // ---------------------------------------------------------------------------
  // Enriched property row — multi select
  // ---------------------------------------------------------------------------

  private buildMultiPropertyRow(
    name: string,
    value: string,
    isMixed: boolean,
    elements: Element[],
    snapshot: ComputedStyleSnapshot,
  ): HTMLDivElement {
    const row = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      padding: '2px 0',
    });
    row.setAttribute('data-prop-row', '');
    row.setAttribute('data-prop-name', name);
    row.setAttribute('data-prop-value', value);

    // Main line: [indicator-slot] [property-name] [value-container with badge-slot]
    const mainLine = createElement('div', {}, {
      display: 'flex',
      justifyContent: 'space-between',
      alignItems: 'center',
      gap: '8px',
    });

    // Indicator slot (4px)
    const indicatorSlot = createElement('span', {}, {
      width: '4px',
      flexShrink: '0',
      display: 'inline-block',
    });
    mainLine.appendChild(indicatorSlot);

    const nameEl = createText('span', name, 'mono');
    nameEl.style.color = OVERLAY.textMuted;
    nameEl.style.flexShrink = '0';
    mainLine.appendChild(nameEl);

    // Enrichment: inactive CSS indicator (from first element's snapshot)
    const inactiveReason = checkInactive(name, snapshot);
    if (inactiveReason) {
      applyInactiveStyles(row, nameEl, indicatorSlot, inactiveReason);
    }

    const valueContainer = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '4px',
      overflow: 'hidden',
      cursor: 'pointer',
      pointerEvents: 'auto',
    });

    const valueEl = createText('span', value, 'mono');
    valueEl.style.textOverflow = 'ellipsis';
    valueEl.style.overflow = 'hidden';
    valueEl.style.whiteSpace = 'nowrap';
    if (isMixed) {
      valueEl.style.fontStyle = 'italic';
      valueEl.style.color = OVERLAY.textMuted;
    }
    valueContainer.appendChild(valueEl);

    // Enrichment: color swatch (only when values are uniform)
    const openEditor = () => {
      this.inlineEditor.openMulti(
        row,
        valueContainer,
        name,
        value,
        elements,
        (property, toValue, els, tokenName) => {
          const changes: Array<{ element: Element; property: string; fromValue: string; toValue: string; token?: string }> = [];
          for (const el of els) {
            const fromValue = getComputedProperty(el, property);
            (el as HTMLElement).style.setProperty(property, toValue);
            changes.push({ element: el, property, fromValue, toValue, token: tokenName });
          }
          this.multiPropChangeCb?.(changes);
        },
      );
    };

    if (!isMixed) {
      const swatch = createColorSwatch(name, value, openEditor);
      if (swatch) {
        valueContainer.appendChild(swatch);
      }
    }

    // Badge slot — token badge (only when values are uniform)
    if (!isMixed) {
      const token = this.inlineEditor.resolveToken(name, value);
      if (token) {
        const badgeEl = createElement('span', {}, {
          background: 'rgba(6, 182, 212, 0.2)',
          color: OVERLAY.primary,
          padding: '1px 4px',
          borderRadius: '2px',
          fontSize: '10px',
          fontFamily: OVERLAY.monoFamily,
          whiteSpace: 'nowrap',
          flexShrink: '0',
        });
        badgeEl.textContent = token.name;
        valueContainer.appendChild(badgeEl);
      }
    }

    valueContainer.addEventListener('click', openEditor);

    valueContainer.addEventListener('mouseenter', () => {
      valueEl.style.textDecoration = 'underline';
      valueEl.style.textDecorationStyle = 'dotted';
    });
    valueContainer.addEventListener('mouseleave', () => {
      valueEl.style.textDecoration = '';
    });

    mainLine.appendChild(valueContainer);
    row.appendChild(mainLine);

    // Annotation slot (hidden)
    const annotationSlot = createElement('div', {}, {
      display: 'none',
      paddingLeft: '12px',
      fontSize: '10px',
      color: OVERLAY.textMuted,
      fontFamily: OVERLAY.monoFamily,
    });
    row.appendChild(annotationSlot);

    return row;
  }
}
