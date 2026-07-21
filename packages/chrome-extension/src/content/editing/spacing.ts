import type { PropertyChange } from '@nco-studio/shared';
import { createElement, createText, createButton, makeDraggable } from '../../shared/ui-utils';
import { getComputedProperty } from '../../shared/dom-utils';
import { OVERLAY, TOOLBAR_WIDTH, HANDLE_COLORS } from '../../shared/constants';
import type { TokenStore } from '../tokens/store';
import type { PageValueStore, InferredOption } from '../tokens/page-value-store';
import type { PreviewManager } from './preview';
import { buildTokenSelect, extractUnit } from './token-select';
import { pageValueHeading } from './colors';

type ChangeCallback = (changes: PropertyChange[]) => void;

/** Monotonic id source for per-input `<datalist>` elements (page suggestions). */
let datalistSeq = 0;

/** Spacing properties that the spacing edit mode handles. */
export const SPACING_PROPERTIES = [
  'padding-top',
  'padding-right',
  'padding-bottom',
  'padding-left',
  'margin-top',
  'margin-right',
  'margin-bottom',
  'margin-left',
] as const;

/** Read all current spacing values for an element. */
export function readSpacingValues(
  element: Element,
): Record<string, string> {
  const values: Record<string, string> = {};
  for (const prop of SPACING_PROPERTIES) {
    values[prop] = getComputedProperty(element, prop);
  }
  return values;
}

/**
 * Build PropertyChange objects from before/after spacing values.
 * Only includes properties that actually changed.
 */
export function buildSpacingChanges(
  before: Record<string, string>,
  after: Record<string, string>,
): PropertyChange[] {
  const changes: PropertyChange[] = [];

  for (const prop of SPACING_PROPERTIES) {
    const fromValue = before[prop] ?? '0px';
    const toValue = after[prop] ?? '0px';
    if (fromValue !== toValue) {
      changes.push({
        property: prop,
        fromValue,
        toValue,
        unit: extractUnit(toValue),
      });
    }
  }

  return changes;
}

// ---------------------------------------------------------------------------
// Short labels for the mini panel
// ---------------------------------------------------------------------------

const SIDE_LABELS: Record<string, string> = {
  'padding-top': 'T',
  'padding-right': 'R',
  'padding-bottom': 'B',
  'padding-left': 'L',
  'margin-top': 'T',
  'margin-right': 'R',
  'margin-bottom': 'B',
  'margin-left': 'L',
};

// ---------------------------------------------------------------------------
// SpacingEditor — floating mini-panel
// ---------------------------------------------------------------------------

/**
 * Spacing editing controls rendered as a floating mini-panel.
 * Shows padding and margin values with token dropdowns when available.
 * Positioned relative to the toolbar anchor point.
 */
export class SpacingEditor {
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

  /**
   * Render spacing controls for the selected element.
   * Returns the container element to append to the shadow root.
   */
  render(
    element: Element,
    anchorPos: { x: number; y: number },
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    this.cleanup();

    const panelLeft = Math.min(
      anchorPos.x + TOOLBAR_WIDTH + 8,
      window.innerWidth - 228,
    );
    const panelTop = Math.max(8, anchorPos.y);

    const container = createElement('div', { role: 'dialog', 'aria-label': 'Spacing editor' }, {
      position: 'fixed',
      left: `${panelLeft}px`,
      top: `${panelTop}px`,
      width: '220px',
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
    const title = createText('span', 'Spacing', 'heading');
    title.style.fontSize = '12px';
    header.appendChild(title);

    const closeBtn = createButton('\u00d7', 'ghost', () => {
      this.cleanup();
      this.closeCb?.();
    });
    closeBtn.style.padding = '2px 6px';
    closeBtn.style.fontSize = '14px';
    header.appendChild(closeBtn);
    container.appendChild(header);

    makeDraggable(header, container, undefined, () => { this.userDragged = true; });

    // Controls body
    const body = createElement('div', {}, {
      padding: '8px 10px',
      display: 'flex',
      flexDirection: 'column',
      gap: '10px',
    });

    // Page-inference hint (feature-011): when no spacing tokens exist but the
    // page harvest found spacing values, the T/R/B/L inputs below expose them as
    // `<datalist>` suggestions. A single header keeps the 2×2 grids uncluttered.
    if (this.tokenStore.getForProperty('padding-top').length === 0 &&
        this.pageValueStore.getForProperty('padding-top').length > 0) {
      body.appendChild(pageValueHeading(this.tokenStore.hasDegradedDesignSystem()));
    }

    // Padding group
    body.appendChild(this.buildGroup(
      'Padding',
      HANDLE_COLORS.padding,
      ['padding-top', 'padding-right', 'padding-bottom', 'padding-left'],
      element,
      onCommit,
    ));

    // Margin group
    body.appendChild(this.buildGroup(
      'Margin',
      HANDLE_COLORS.margin,
      ['margin-top', 'margin-right', 'margin-bottom', 'margin-left'],
      element,
      onCommit,
    ));

    container.appendChild(body);
    this.container = container;
    return container;
  }

  /** Reposition the floating panel relative to a new toolbar anchor. */
  reposition(anchorPos: { x: number; y: number }): void {
    if (!this.container) return;
    if (this.userDragged) return;
    const panelLeft = Math.min(
      anchorPos.x + TOOLBAR_WIDTH + 8,
      window.innerWidth - 228,
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
  // Controls
  // -----------------------------------------------------------------------

  private buildGroup(
    label: string,
    color: string,
    properties: string[],
    element: Element,
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    const group = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      gap: '4px',
    });

    // Group label with color dot
    const labelRow = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '5px',
    });

    const dot = createElement('div', {}, {
      width: '6px',
      height: '6px',
      borderRadius: '50%',
      background: color,
      flexShrink: '0',
    });
    labelRow.appendChild(dot);

    const labelEl = createText('span', label, 'heading');
    labelEl.style.fontSize = '11px';
    labelEl.style.color = OVERLAY.textMuted;
    labelEl.style.textTransform = 'uppercase';
    labelEl.style.letterSpacing = '0.5px';
    labelRow.appendChild(labelEl);
    group.appendChild(labelRow);

    // Property rows in a 2x2 grid: T R / B L
    const grid = createElement('div', {}, {
      display: 'grid',
      gridTemplateColumns: '1fr 1fr',
      gap: '3px',
    });

    for (const prop of properties) {
      grid.appendChild(this.buildPropertyCell(prop, element, onCommit));
    }

    group.appendChild(grid);
    return group;
  }

  private buildPropertyCell(
    property: string,
    element: Element,
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    const cell = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '4px',
    });

    // Side label (T/R/B/L)
    const sideLabel = createText('span', SIDE_LABELS[property] ?? '', 'mono');
    sideLabel.style.color = OVERLAY.textMuted;
    sideLabel.style.fontSize = '10px';
    sideLabel.style.fontWeight = '600';
    sideLabel.style.width = '10px';
    sideLabel.style.flexShrink = '0';
    cell.appendChild(sideLabel);

    const tokens = this.tokenStore.getForProperty(property);
    const currentValue = getComputedProperty(element, property);

    if (tokens.length > 0) {
      cell.appendChild(buildTokenSelect(property, tokens, currentValue, element, this.preview, onCommit));
    } else {
      // Freeform text input (feature-003 escape hatch — preserved), augmented
      // with a `<datalist>` of page-inferred spacing values for discoverability
      // (feature-011). A committed value that matches a harvested page value is
      // stamped `fromPageInference: true` (a grounded custom), never `toToken`.
      const pageOptions = this.pageValueStore.getForProperty(property);
      cell.appendChild(this.buildValueInput(property, currentValue, element, pageOptions, onCommit));
    }

    return cell;
  }

  private buildValueInput(
    property: string,
    currentValue: string,
    element: Element,
    pageOptions: readonly InferredOption[],
    onCommit: ChangeCallback,
  ): HTMLElement {
    const input = createElement('input', {
      type: 'text',
      value: currentValue,
    }, {
      background: 'rgba(255, 255, 255, 0.1)',
      color: OVERLAY.text,
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusSm,
      padding: '2px 3px',
      fontSize: '10px',
      fontFamily: OVERLAY.monoFamily,
      pointerEvents: 'auto',
      flex: '1',
      minWidth: '0',
      width: '100%',
    }) as HTMLInputElement;

    const pageValues = new Set(pageOptions.map((o) => o.value));

    // Attach page-inferred suggestions via a native <datalist> (freeform typing
    // remains fully available). The datalist lives in the same shadow tree.
    let datalist: HTMLDataListElement | null = null;
    if (pageOptions.length > 0) {
      const listId = `pv-spacing-${datalistSeq++}`;
      datalist = document.createElement('datalist');
      datalist.id = listId;
      for (const o of pageOptions) {
        const opt = document.createElement('option');
        opt.value = o.value;
        datalist.appendChild(opt);
      }
      input.setAttribute('list', listId);
      input.title = 'Type a value, or pick one already used on this page';
      // Dashed "observed" border echoes the color-swatch page-inference treatment
      // so provenance is legible at the input level, not just the panel header.
      input.style.borderStyle = 'dashed';
      input.style.borderColor = OVERLAY.textMuted;
    }

    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        const fromValue = getComputedProperty(element, property);
        const toValue = input.value.trim();
        if (toValue && toValue !== fromValue) {
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
        }
      }
    });

    if (!datalist) return input;
    // Wrap input + datalist so the cell receives a single element.
    const wrap = createElement('div', {}, { display: 'contents' });
    wrap.appendChild(input);
    wrap.appendChild(datalist);
    return wrap;
  }
}
