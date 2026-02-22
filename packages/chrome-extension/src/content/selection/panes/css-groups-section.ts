import type { VisualDiff } from '@frontend-editor/shared';
import { createElement, createText } from '../../../shared/ui-utils';
import { OVERLAY } from '../../../shared/constants';
import { getComputedProperty, generateSelector, createStyleSnapshot, snapshotGet } from '../../../shared/dom-utils';
import type { ComputedStyleSnapshot } from '../../../shared/dom-utils';
import type { TokenStore } from '../../tokens/store';
import type { PendingQueue } from '../../batching/queue';
import { InlineEditor } from './inline-editor';
import { createColorSwatch } from './enrichments/color-swatch';
import { checkInactive, applyInactiveStyles } from './enrichments/inactive-css';
import { findPendingChange, applyPendingDot } from './enrichments/pending-indicator';
import { computeContrast, createContrastBadge } from './enrichments/contrast-badge';

type PropertyChangeCb = (property: string, fromValue: string, toValue: string, token?: string) => void;
type MultiPropertyChangeCb = (changes: Array<{ element: Element; property: string; fromValue: string; toValue: string; token?: string }>) => void;

const PROPERTY_GROUPS: Array<{ label: string; props: string[] }> = [
  { label: 'Dimensions', props: ['width', 'height'] },
  { label: 'Spacing', props: ['padding-top', 'padding-right', 'padding-bottom', 'padding-left', 'margin-top', 'margin-right', 'margin-bottom', 'margin-left'] },
  { label: 'Typography', props: ['font-family', 'font-size', 'font-weight', 'line-height', 'color'] },
  { label: 'Background', props: ['background-color'] },
  { label: 'Position', props: ['position', 'top', 'right', 'bottom', 'left'] },
  { label: 'Border', props: ['border-radius', 'border-color', 'border-width'] },
];

/**
 * CSS groups section — renders the 6 property groups for the Edit tab.
 * Supports both single-select (snapshot-based) and multi-select (per-element) modes.
 * Uses enriched property row structure with indicator, badge, and annotation slots.
 * Enrichments: color swatches, inactive CSS indicators, pending-change dots, contrast badges.
 */
export class CssGroupsSection {
  private propChangeCb: PropertyChangeCb | null = null;
  private multiPropChangeCb: MultiPropertyChangeCb | null = null;
  private currentElement: Element | null = null;
  private inlineEditor: InlineEditor;

  constructor(
    private readonly tokenStore: TokenStore,
    private readonly pendingQueue: PendingQueue,
  ) {
    this.inlineEditor = new InlineEditor(tokenStore);
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
      background: OVERLAY.info,
      color: '#fff',
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
        background: 'rgba(255, 255, 255, 0.08)',
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

    return section;
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

    // Annotation slot (hidden — future: rule source annotation)
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
