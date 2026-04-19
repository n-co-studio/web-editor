import type { PropertyChange } from '@frontend-editor/shared';
import { createElement, createText, createButton, makeDraggable } from '../../shared/ui-utils';
import { getComputedProperty } from '../../shared/dom-utils';
import { OVERLAY, TOOLBAR_WIDTH, HANDLE_COLORS } from '../../shared/constants';
import type { TokenStore } from '../tokens/store';
import type { PreviewManager } from './preview';

type ChangeCallback = (changes: PropertyChange[]) => void;

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

function extractUnit(value: string): string | undefined {
  const match = value.match(/[\d.]+(.+)$/);
  return match?.[1] || undefined;
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
      cell.appendChild(this.buildTokenSelect(property, tokens, currentValue, element, onCommit));
    } else {
      // Fallback: editable text input
      cell.appendChild(this.buildValueInput(property, currentValue, element, onCommit));
    }

    return cell;
  }

  private buildTokenSelect(
    property: string,
    tokens: Array<{ name: string; value: string }>,
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

    // "auto" is valid for margin and browsers accept it for padding; offer it up-front.
    const autoOpt = document.createElement('option');
    autoOpt.value = 'auto';
    autoOpt.textContent = 'auto';
    if (currentValue === 'auto') autoOpt.selected = true;
    select.appendChild(autoOpt);

    // Check if current value matches a token or auto
    const hasMatch =
      currentValue === 'auto' || tokens.some((t) => t.value === currentValue);
    if (!hasMatch) {
      const opt = document.createElement('option');
      opt.value = currentValue;
      opt.textContent = currentValue;
      select.appendChild(opt);
    }

    for (const token of tokens) {
      const opt = document.createElement('option');
      opt.value = token.value;
      opt.textContent = `${token.value} (${token.name})`;
      if (token.value === currentValue) opt.selected = true;
      select.appendChild(opt);
    }

    select.addEventListener('change', () => {
      const fromValue = getComputedProperty(element, property);
      const toValue = select.value;
      const token = tokens.find((t) => t.value === toValue);
      this.preview.begin(element as HTMLElement);
      this.preview.apply(property, toValue);
      this.preview.commit();
      onCommit([{
        property,
        fromValue,
        toValue,
        unit: extractUnit(toValue),
        toToken: token?.name,
      }]);
    });

    return select;
  }

  private buildValueInput(
    property: string,
    currentValue: string,
    element: Element,
    onCommit: ChangeCallback,
  ): HTMLInputElement {
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
          }]);
        }
      }
    });

    return input;
  }
}
