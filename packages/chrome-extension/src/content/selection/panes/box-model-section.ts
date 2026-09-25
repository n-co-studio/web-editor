import { createElement, createText } from '../../../shared/ui-utils';
import { BOX_MODEL, OVERLAY } from '../../../shared/constants';
import type { PanelSizeTier } from '../../../shared/constants';
import { snapshotGet } from '../../../shared/dom-utils';
import type { ComputedStyleSnapshot } from '../../../shared/dom-utils';

type PropertyChangeCb = (property: string, fromValue: string, toValue: string) => void;

/** Box model value zones mapped to their CSS properties and colors. */
const ZONES = [
  {
    label: 'margin',
    fill: BOX_MODEL.marginFill,
    text: BOX_MODEL.marginText,
    props: ['margin-top', 'margin-right', 'margin-bottom', 'margin-left'] as const,
  },
  {
    label: 'border',
    fill: BOX_MODEL.borderFill,
    text: BOX_MODEL.borderText,
    props: ['border-top-width', 'border-right-width', 'border-bottom-width', 'border-left-width'] as const,
  },
  {
    label: 'padding',
    fill: BOX_MODEL.paddingFill,
    text: BOX_MODEL.paddingText,
    props: ['padding-top', 'padding-right', 'padding-bottom', 'padding-left'] as const,
  },
] as const;

/** Strip units from a value for compact display: "16px" -> "16". */
function stripUnit(val: string): string {
  const n = parseFloat(val);
  return isNaN(n) ? val : String(n);
}

/**
 * Interactive box model diagram section.
 * Renders nested rectangles for margin → border → padding → content.
 * Supports full (≥300px), standard (compact summary), and compact (hidden) tiers.
 */
export class BoxModelSection {
  private propChangeCb: PropertyChangeCb | null = null;
  private activePopover: HTMLDivElement | null = null;

  onPropertyChange(cb: PropertyChangeCb): void {
    this.propChangeCb = cb;
  }

  /**
   * Build the box model visualization for the given tier.
   * Returns null when the tier is 'compact' (diagram hidden).
   */
  build(
    snapshot: ComputedStyleSnapshot,
    element: Element,
    tier: PanelSizeTier,
  ): HTMLDivElement | null {
    if (tier === 'compact') return null;
    if (tier === 'standard') return this.buildCompactSummary(snapshot, element);
    return this.buildFullDiagram(snapshot, element);
  }

  // ---------------------------------------------------------------------------
  // Full nested-rectangle diagram
  // ---------------------------------------------------------------------------

  private buildFullDiagram(snapshot: ComputedStyleSnapshot, element: Element): HTMLDivElement {
    const container = createElement('div', {}, {
      padding: '8px 10px',
      borderBottom: `1px solid ${OVERLAY.border}`,
    });

    const title = createText('div', 'Box Model', 'heading');
    title.style.fontSize = OVERLAY.monoSize;
    title.style.color = OVERLAY.textMuted;
    title.style.textTransform = 'uppercase';
    title.style.letterSpacing = '0.5px';
    title.style.marginBottom = '6px';
    container.appendChild(title);

    // Nested boxes: margin -> border -> padding -> content
    const marginBox = this.buildZoneBox(
      BOX_MODEL.marginFill, BOX_MODEL.marginText, 'margin',
      snapshot, element,
      ['margin-top', 'margin-right', 'margin-bottom', 'margin-left'],
    );

    const borderBox = this.buildZoneBox(
      BOX_MODEL.borderFill, BOX_MODEL.borderText, 'border',
      snapshot, element,
      ['border-top-width', 'border-right-width', 'border-bottom-width', 'border-left-width'],
    );

    const paddingBox = this.buildZoneBox(
      BOX_MODEL.paddingFill, BOX_MODEL.paddingText, 'padding',
      snapshot, element,
      ['padding-top', 'padding-right', 'padding-bottom', 'padding-left'],
    );

    const contentBox = this.buildContentBox(snapshot);

    paddingBox.querySelector('[data-box-inner]')!.appendChild(contentBox);
    borderBox.querySelector('[data-box-inner]')!.appendChild(paddingBox);
    marginBox.querySelector('[data-box-inner]')!.appendChild(borderBox);
    container.appendChild(marginBox);

    return container;
  }

  private buildZoneBox(
    fill: string,
    textColor: string,
    label: string,
    snapshot: ComputedStyleSnapshot,
    element: Element,
    props: readonly string[],
  ): HTMLDivElement {
    const box = createElement('div', {}, {
      position: 'relative',
      background: fill,
      border: `1px dashed ${OVERLAY.border}`,
      padding: '14px 20px',
      textAlign: 'center',
    });

    // Zone label (top-left corner)
    const labelEl = createText('span', label, 'mono');
    labelEl.style.position = 'absolute';
    labelEl.style.top = '1px';
    labelEl.style.left = '3px';
    labelEl.style.fontSize = '9px';
    labelEl.style.color = textColor;
    labelEl.style.opacity = '0.7';
    box.appendChild(labelEl);

    // Values positioned at edges: top, right, bottom, left
    const positions: Array<{ prop: string; css: Partial<CSSStyleDeclaration> }> = [
      { prop: props[0], css: { position: 'absolute', top: '1px', left: '50%', transform: 'translateX(-50%)' } },
      { prop: props[1], css: { position: 'absolute', right: '3px', top: '50%', transform: 'translateY(-50%)' } },
      { prop: props[2], css: { position: 'absolute', bottom: '1px', left: '50%', transform: 'translateX(-50%)' } },
      { prop: props[3], css: { position: 'absolute', left: '3px', top: '50%', transform: 'translateY(-50%)' } },
    ];

    for (const pos of positions) {
      const val = snapshotGet(snapshot, pos.prop);
      const display = stripUnit(val);
      const valEl = createElement('span', { title: `${pos.prop}: ${val}` }, {
        ...pos.css,
        fontSize: '10px',
        fontFamily: OVERLAY.monoFamily,
        color: textColor,
        cursor: 'pointer',
        padding: '1px 3px',
        borderRadius: '2px',
        lineHeight: '1.2',
        pointerEvents: 'auto',
      });
      valEl.textContent = display;

      valEl.addEventListener('mouseenter', () => {
        valEl.style.background = 'rgba(255, 255, 255, 0.1)';
      });
      valEl.addEventListener('mouseleave', () => {
        valEl.style.background = '';
      });

      valEl.addEventListener('click', (e) => {
        e.stopPropagation();
        this.openPopoverEditor(valEl, pos.prop, val, element);
      });

      box.appendChild(valEl);
    }

    // Inner container for nesting
    const inner = createElement('div', { 'data-box-inner': '' }, {
      minHeight: '20px',
    });
    box.appendChild(inner);

    return box;
  }

  private buildContentBox(snapshot: ComputedStyleSnapshot): HTMLDivElement {
    const box = createElement('div', {}, {
      background: BOX_MODEL.contentFill,
      border: `1px dashed ${OVERLAY.border}`,
      padding: '6px 8px',
      textAlign: 'center',
      minHeight: '24px',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
    });

    const w = stripUnit(snapshot.width);
    const h = stripUnit(snapshot.height);
    const sizeEl = createText('span', `${w} \u00d7 ${h}`, 'mono');
    sizeEl.style.color = BOX_MODEL.contentText;
    sizeEl.style.fontSize = '10px';
    box.appendChild(sizeEl);

    return box;
  }

  // ---------------------------------------------------------------------------
  // Compact single-line summary
  // ---------------------------------------------------------------------------

  private buildCompactSummary(snapshot: ComputedStyleSnapshot, element: Element): HTMLDivElement {
    const container = createElement('div', {}, {
      padding: '4px 10px',
      borderBottom: `1px solid ${OVERLAY.border}`,
      display: 'flex',
      alignItems: 'center',
      gap: '6px',
      fontFamily: OVERLAY.monoFamily,
      fontSize: '10px',
      flexWrap: 'wrap',
    });

    // M: top right bottom left
    const marginParts = ['margin-top', 'margin-right', 'margin-bottom', 'margin-left']
      .map((p) => stripUnit(snapshotGet(snapshot, p)));
    const marginEl = createText('span', `M: ${marginParts.join(' ')}`, 'mono');
    marginEl.style.color = BOX_MODEL.marginText;
    marginEl.style.fontSize = '10px';
    container.appendChild(marginEl);

    const sep1 = createText('span', '|', 'mono');
    sep1.style.color = OVERLAY.textMuted;
    sep1.style.fontSize = '10px';
    sep1.style.opacity = '0.5';
    container.appendChild(sep1);

    // P: top right bottom left
    const paddingParts = ['padding-top', 'padding-right', 'padding-bottom', 'padding-left']
      .map((p) => stripUnit(snapshotGet(snapshot, p)));
    const paddingEl = createText('span', `P: ${paddingParts.join(' ')}`, 'mono');
    paddingEl.style.color = BOX_MODEL.paddingText;
    paddingEl.style.fontSize = '10px';
    container.appendChild(paddingEl);

    const sep2 = createText('span', '|', 'mono');
    sep2.style.color = OVERLAY.textMuted;
    sep2.style.fontSize = '10px';
    sep2.style.opacity = '0.5';
    container.appendChild(sep2);

    // width × height
    const w = stripUnit(snapshot.width);
    const h = stripUnit(snapshot.height);
    const sizeEl = createText('span', `${w}\u00d7${h}`, 'mono');
    sizeEl.style.color = BOX_MODEL.contentText;
    sizeEl.style.fontSize = '10px';
    container.appendChild(sizeEl);

    return container;
  }

  // ---------------------------------------------------------------------------
  // Popover editor for click-to-edit
  // ---------------------------------------------------------------------------

  private openPopoverEditor(
    anchor: HTMLElement,
    property: string,
    currentValue: string,
    element: Element,
  ): void {
    this.closePopover();

    const popover = createElement('div', {}, {
      position: 'absolute',
      zIndex: '200',
      background: OVERLAY.bg,
      border: `1px solid ${OVERLAY.primary}`,
      borderRadius: OVERLAY.radiusSm,
      padding: '4px',
      boxShadow: OVERLAY.shadowLg ?? '0 10px 15px rgba(0, 0, 0, 0.10)',
      pointerEvents: 'auto',
    });

    const input = createElement('input', {
      type: 'text',
      value: currentValue,
    }, {
      background: 'rgba(255, 255, 255, 0.1)',
      color: OVERLAY.text,
      border: 'none',
      borderRadius: '2px',
      padding: '2px 4px',
      fontSize: '10px',
      fontFamily: OVERLAY.monoFamily,
      width: '60px',
      outline: 'none',
      pointerEvents: 'auto',
    }) as HTMLInputElement;

    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        const newValue = input.value.trim();
        if (newValue && newValue !== currentValue) {
          (element as HTMLElement).style.setProperty(property, newValue);
          anchor.textContent = stripUnit(newValue);
          this.propChangeCb?.(property, currentValue, newValue);
        }
        this.closePopover();
      }
      if (e.key === 'Escape') {
        e.preventDefault();
        this.closePopover();
      }
      e.stopPropagation();
    });

    popover.appendChild(input);

    // Position relative to anchor
    const anchorParent = anchor.offsetParent as HTMLElement;
    if (anchorParent) {
      const anchorRect = anchor.getBoundingClientRect();
      const parentRect = anchorParent.getBoundingClientRect();
      popover.style.left = `${anchorRect.left - parentRect.left}px`;
      popover.style.top = `${anchorRect.bottom - parentRect.top + 2}px`;
      anchorParent.style.position = 'relative';
      anchorParent.appendChild(popover);
    } else {
      anchor.parentElement?.appendChild(popover);
    }

    this.activePopover = popover;
    input.focus();
    input.select();
  }

  private closePopover(): void {
    this.activePopover?.remove();
    this.activePopover = null;
  }
}
