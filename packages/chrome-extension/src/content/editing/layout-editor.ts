import type { PropertyChange } from '@nco-studio/shared';
import { createElement, createText, createButton, makeDraggable } from '../../shared/ui-utils';
import { getComputedProperty } from '../../shared/dom-utils';
import { OVERLAY, TOOLBAR_WIDTH } from '../../shared/constants';
import type { TokenStore } from '../tokens/store';
import type { PageValueStore, InferredOption } from '../tokens/page-value-store';
import type { PreviewManager } from './preview';
import { buildTokenSelect, extractUnit } from './token-select';
import { LAYOUT_RATIOS } from './insert-catalog';

type ChangeCallback = (changes: PropertyChange[]) => void;
type ProportionsCallback = (weights: number[]) => void;

const PANEL_WIDTH = 230;

/** Gutter properties exposed in the Gutters section. */
const GUTTER_PROPS: { property: string; label: string }[] = [
  { property: 'gap', label: 'Gap' },
  { property: 'row-gap', label: 'Row' },
  { property: 'column-gap', label: 'Column' },
];

/** Detect whether the element is a flex or grid container. */
function getContainerKind(element: Element): 'flex' | 'grid' | null {
  const display = getComputedStyle(element).display;
  if (display.includes('flex')) return 'flex';
  if (display.includes('grid')) return 'grid';
  return null;
}

/** Reduce a weight array to its simplest integer form (e.g. [2,2] → [1,1]). */
function normalizeWeights(weights: number[]): number[] {
  const gcd = (a: number, b: number): number => (b === 0 ? a : gcd(b, a % b));
  const divisor = weights.reduce((g, w) => gcd(g, Math.round(w)), 0) || 1;
  return weights.map((w) => Math.round(w) / divisor);
}

/**
 * Layout editing controls (floating mini-panel) for a flex/grid container:
 *  - Gutters: gap / row-gap / column-gap via spacing-token dropdowns.
 *  - Proportions: ratio presets matching the container's child count.
 * Commits flow through the same onCommit→commitEdit→queue path as other tools.
 */
export class LayoutEditor {
  private container: HTMLDivElement | null = null;
  private closeCb: (() => void) | null = null;
  private userDragged = false;

  constructor(
    private readonly tokenStore: TokenStore,
    private readonly preview: PreviewManager,
    private readonly pageValueStore: PageValueStore,
  ) {}

  onClose(cb: () => void): void {
    this.closeCb = cb;
  }

  render(
    element: Element,
    anchorPos: { x: number; y: number },
    onCommit: ChangeCallback,
    onProportions: ProportionsCallback,
  ): HTMLDivElement {
    this.cleanup();

    const panelLeft = Math.min(
      anchorPos.x + TOOLBAR_WIDTH + 8,
      window.innerWidth - (PANEL_WIDTH + 8),
    );
    const panelTop = Math.max(8, anchorPos.y);

    const container = createElement('div', { role: 'dialog', 'aria-label': 'Layout editor' }, {
      position: 'fixed',
      left: `${panelLeft}px`,
      top: `${panelTop}px`,
      width: `${PANEL_WIDTH}px`,
      background: OVERLAY.bg,
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusMd,
      boxShadow: OVERLAY.shadowLg,
      pointerEvents: 'auto',
      zIndex: '102',
      fontFamily: OVERLAY.fontFamily,
      overflow: 'hidden',
    });

    // Header
    const header = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
      padding: '6px 10px',
      borderBottom: `1px solid ${OVERLAY.border}`,
    });
    const title = createText('span', 'Layout', 'heading');
    title.style.fontSize = '12px';
    header.appendChild(title);

    const closeBtn = createButton('×', 'ghost', () => {
      this.cleanup();
      this.closeCb?.();
    });
    closeBtn.style.padding = '2px 6px';
    closeBtn.style.fontSize = '14px';
    header.appendChild(closeBtn);
    container.appendChild(header);

    makeDraggable(header, container, undefined, () => { this.userDragged = true; });

    // Body
    const body = createElement('div', {}, {
      padding: '8px 10px',
      display: 'flex',
      flexDirection: 'column',
      gap: '12px',
    });

    const kind = getContainerKind(element);
    if (!kind) {
      const hint = createText('div', 'Select a flex or grid container to edit its gutters and proportions.', 'mono');
      hint.style.color = OVERLAY.textMuted;
      hint.style.fontSize = '11px';
      hint.style.lineHeight = '1.4';
      body.appendChild(hint);
    } else {
      body.appendChild(this.buildGuttersSection(element, onCommit));
      body.appendChild(this.buildProportionsSection(element, kind, onProportions));
    }

    container.appendChild(body);
    this.container = container;
    return container;
  }

  reposition(anchorPos: { x: number; y: number }): void {
    if (!this.container || this.userDragged) return;
    const panelLeft = Math.min(
      anchorPos.x + TOOLBAR_WIDTH + 8,
      window.innerWidth - (PANEL_WIDTH + 8),
    );
    const panelTop = Math.max(8, anchorPos.y);
    this.container.style.left = `${panelLeft}px`;
    this.container.style.top = `${panelTop}px`;
  }

  cleanup(): void {
    this.container?.remove();
    this.container = null;
    this.userDragged = false;
  }

  // -----------------------------------------------------------------------
  // Gutters
  // -----------------------------------------------------------------------

  private buildGuttersSection(element: Element, onCommit: ChangeCallback): HTMLDivElement {
    const group = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      gap: '4px',
    });
    group.appendChild(this.sectionLabel('Gutters'));

    for (const { property, label } of GUTTER_PROPS) {
      const row = createElement('div', {}, {
        display: 'flex',
        alignItems: 'center',
        gap: '6px',
      });

      const labelEl = createText('span', label, 'mono');
      labelEl.style.color = OVERLAY.textMuted;
      labelEl.style.fontSize = '10px';
      labelEl.style.width = '48px';
      labelEl.style.flexShrink = '0';
      row.appendChild(labelEl);

      // Prefer property-specific tokens; fall back to all spacing tokens since a
      // token may not declare `gap` in its cssProperties.
      const propTokens = this.tokenStore.getForProperty(property);
      const tokens = propTokens.length > 0 ? propTokens : this.tokenStore.getForCategory('spacing');
      const currentValue = getComputedProperty(element, property);

      if (tokens.length > 0) {
        row.appendChild(
          buildTokenSelect(property, tokens, currentValue, element, this.preview, onCommit),
        );
      } else {
        // No spacing tokens. Offer page-inferred spacing ("On this page") when the
        // harvester found any (feature-011); otherwise keep the feature-003
        // freeform floor (buildTokenSelect with an empty token set still offers
        // `auto` + the current value, so gutters never dead-end).
        const pageOptions = this.pageValueStore.getForProperty(property);
        if (pageOptions.length > 0) {
          row.appendChild(this.buildPageGutterSelect(property, pageOptions, currentValue, element, onCommit));
        } else {
          row.appendChild(
            buildTokenSelect(property, tokens, currentValue, element, this.preview, onCommit),
          );
        }
      }
      group.appendChild(row);
    }

    return group;
  }

  /**
   * A gutter <select> backed by page-inferred spacing values (feature-011),
   * grouped under an "On this page" optgroup above `auto`. Selecting a page
   * value emits `fromPageInference: true` with no `toToken`; the freeform
   * escape (`auto` / the live value) remains available.
   */
  private buildPageGutterSelect(
    property: string,
    pageOptions: readonly InferredOption[],
    currentValue: string,
    element: Element,
    onCommit: ChangeCallback,
  ): HTMLSelectElement {
    const select = createElement('select', {}, {
      background: 'rgba(255, 255, 255, 0.1)',
      color: OVERLAY.text,
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusSm,
      padding: '2px 3px',
      fontSize: '10px',
      fontFamily: OVERLAY.monoFamily,
      pointerEvents: 'auto',
      cursor: 'pointer',
      flex: '1',
      minWidth: '0',
    }) as HTMLSelectElement;

    const pageValues = new Set(pageOptions.map((o) => o.value));

    const autoOpt = document.createElement('option');
    autoOpt.value = 'auto';
    autoOpt.textContent = 'auto';
    if (currentValue === 'auto') autoOpt.selected = true;
    select.appendChild(autoOpt);

    const hasMatch = currentValue === 'auto' || pageValues.has(currentValue);
    if (!hasMatch) {
      const opt = document.createElement('option');
      opt.value = currentValue;
      opt.textContent = currentValue;
      opt.selected = true;
      select.appendChild(opt);
    }

    const group = document.createElement('optgroup');
    group.label = 'On this page';
    for (const o of pageOptions) {
      const opt = document.createElement('option');
      opt.value = o.value;
      opt.textContent = o.value;
      if (o.value === currentValue) opt.selected = true;
      group.appendChild(opt);
    }
    select.appendChild(group);

    select.addEventListener('change', () => {
      const toValue = select.value;
      const fromValue = getComputedProperty(element, property);
      this.preview.begin(element as HTMLElement);
      this.preview.apply(property, toValue);
      this.preview.commit();
      onCommit([{
        property,
        fromValue,
        toValue,
        unit: extractUnit(toValue),
        ...(pageValues.has(toValue) ? { fromPageInference: true as const } : {}),
      }]);
    });

    return select;
  }

  // -----------------------------------------------------------------------
  // Proportions
  // -----------------------------------------------------------------------

  private buildProportionsSection(
    element: Element,
    kind: 'flex' | 'grid',
    onProportions: ProportionsCallback,
  ): HTMLDivElement {
    const group = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      gap: '4px',
    });
    group.appendChild(this.sectionLabel('Proportions'));

    const children = Array.from(element.children).filter(
      (c): c is HTMLElement => c instanceof HTMLElement,
    );
    const trackCount = children.length;
    const presets = LAYOUT_RATIOS.filter((r) => r.weights.length === trackCount);

    if (presets.length === 0) {
      const hint = createText(
        'div',
        trackCount < 2
          ? 'Add at least two child blocks to set proportions.'
          : `No ratio presets for ${trackCount} blocks.`,
        'mono',
      );
      hint.style.color = OVERLAY.textMuted;
      hint.style.fontSize = '10px';
      group.appendChild(hint);
      return group;
    }

    const current = kind === 'flex'
      ? this.currentFlexWeights(children)
      : this.currentGridWeights(element, trackCount);

    const grid = createElement('div', {}, {
      display: 'grid',
      gridTemplateColumns: '1fr 1fr',
      gap: '4px',
    });

    for (const preset of presets) {
      const isActive = current != null && this.weightsMatch(current, preset.weights);
      const btn = createButton(preset.label, 'ghost', () => onProportions([...preset.weights]));
      btn.style.fontSize = '10px';
      btn.style.padding = '4px 2px';
      btn.style.border = `1px solid ${isActive ? OVERLAY.primary : OVERLAY.border}`;
      btn.style.borderRadius = OVERLAY.radiusSm;
      btn.style.justifyContent = 'center';
      if (isActive) btn.style.color = OVERLAY.primary;
      grid.appendChild(btn);
    }

    group.appendChild(grid);
    return group;
  }

  /** Current per-child flex-grow weights (used to highlight the active preset). */
  private currentFlexWeights(children: HTMLElement[]): number[] {
    return children.map((c) => {
      const grow = parseFloat(getComputedProperty(c, 'flex-grow'));
      return Number.isFinite(grow) && grow > 0 ? grow : 1;
    });
  }

  /**
   * Current grid `fr` weights from the container's inline grid-template (the
   * form this tool writes). Returns null when no fr-based template of the
   * expected length is set — computed px tracks can't be mapped back to fr.
   */
  private currentGridWeights(element: Element, count: number): number[] | null {
    const el = element as HTMLElement;
    for (const prop of ['grid-template-columns', 'grid-template-rows']) {
      const inline = el.style.getPropertyValue(prop).trim();
      const matches = inline.match(/(\d*\.?\d+)fr/g);
      if (matches && matches.length === count) {
        return matches.map((t) => parseFloat(t));
      }
    }
    return null;
  }

  private weightsMatch(a: number[], b: number[]): boolean {
    if (a.length !== b.length) return false;
    const na = normalizeWeights(a);
    const nb = normalizeWeights(b);
    return na.every((v, i) => v === nb[i]);
  }

  private sectionLabel(text: string): HTMLDivElement {
    const el = createText('div', text, 'heading') as HTMLDivElement;
    el.style.fontSize = '11px';
    el.style.color = OVERLAY.textMuted;
    el.style.textTransform = 'uppercase';
    el.style.letterSpacing = '0.5px';
    return el;
  }
}
