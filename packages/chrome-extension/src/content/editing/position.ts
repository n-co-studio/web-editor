import type { PropertyChange } from '@frontend-editor/shared';
import { createElement, createText, createButton } from '../../shared/ui-utils';
import { getComputedProperty } from '../../shared/dom-utils';
import { OVERLAY, TOOLBAR_WIDTH } from '../../shared/constants';
import type { PreviewManager } from './preview';

type ChangeCallback = (changes: PropertyChange[]) => void;

/** CSS position values we expose. */
const POSITION_VALUES = ['static', 'relative', 'absolute', 'fixed', 'sticky'] as const;

/** Inset properties shown when position is absolute or fixed. */
const INSET_PROPERTIES = ['top', 'right', 'bottom', 'left'] as const;

const INSET_LABELS: Record<string, string> = {
  top: 'T',
  right: 'R',
  bottom: 'B',
  left: 'L',
};

/**
 * Position editing controls rendered as a floating mini-panel.
 * Shows a position-type selector and, when the position is absolute or fixed,
 * editable inset fields (top, right, bottom, left).
 */
export class PositionEditor {
  private container: HTMLDivElement | null = null;
  private closeCb: (() => void) | null = null;
  private insetSection: HTMLDivElement | null = null;
  private currentElement: Element | null = null;
  private currentOnCommit: ChangeCallback | null = null;

  constructor(
    private readonly preview: PreviewManager,
  ) {}

  onClose(cb: () => void): void {
    this.closeCb = cb;
  }

  render(
    element: Element,
    anchorPos: { x: number; y: number },
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    this.cleanup();
    this.currentElement = element;
    this.currentOnCommit = onCommit;

    const panelLeft = Math.min(
      anchorPos.x + TOOLBAR_WIDTH + 8,
      window.innerWidth - 228,
    );
    const panelTop = Math.max(8, anchorPos.y);

    const container = createElement('div', { role: 'dialog', 'aria-label': 'Position editor' }, {
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
    const title = createText('span', 'Position', 'heading');
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

    // Body
    const body = createElement('div', {}, {
      padding: '8px 10px',
      display: 'flex',
      flexDirection: 'column',
      gap: '8px',
    });

    // Position type selector
    body.appendChild(this.buildPositionSelector(element, onCommit));

    // Inset section (conditionally visible)
    this.insetSection = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      gap: '6px',
    });
    this.buildInsetControls(element, onCommit);
    body.appendChild(this.insetSection);

    container.appendChild(body);
    this.container = container;
    return container;
  }

  reposition(anchorPos: { x: number; y: number }): void {
    if (!this.container) return;
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
    this.insetSection = null;
    this.currentElement = null;
    this.currentOnCommit = null;
  }

  // -----------------------------------------------------------------------
  // Position type selector
  // -----------------------------------------------------------------------

  private buildPositionSelector(
    element: Element,
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    const row = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      gap: '4px',
    });

    const labelRow = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
    });

    const label = createText('span', 'position', 'mono');
    label.style.color = OVERLAY.textMuted;
    label.style.fontSize = '10px';
    labelRow.appendChild(label);
    row.appendChild(labelRow);

    const currentValue = getComputedProperty(element, 'position');

    const btnRow = createElement('div', {}, {
      display: 'flex',
      gap: '2px',
    });

    for (const pos of POSITION_VALUES) {
      const isActive = pos === currentValue;
      const btn = createButton(pos, isActive ? 'primary' : 'ghost', () => {
        if (pos === currentValue) return;
        const fromValue = getComputedProperty(element, 'position');
        this.preview.begin(element as HTMLElement);
        this.preview.apply('position', pos);
        this.preview.commit();
        onCommit([{
          property: 'position',
          fromValue,
          toValue: pos,
        }]);

        // Refresh inset section visibility
        this.refreshInsetVisibility(pos);

        // Re-style all buttons in this row
        for (const child of Array.from(btnRow.children) as HTMLButtonElement[]) {
          const val = child.dataset.posValue;
          if (val === pos) {
            child.style.background = 'rgba(6, 182, 212, 0.12)';
            child.style.color = OVERLAY.primary;
          } else {
            child.style.background = 'transparent';
            child.style.color = OVERLAY.textMuted;
          }
        }
      });
      btn.dataset.posValue = pos;
      btn.style.flex = '1';
      btn.style.padding = '3px 0';
      btn.style.fontSize = '9px';
      btn.style.fontFamily = OVERLAY.monoFamily;
      btn.style.textTransform = 'uppercase';
      btn.style.letterSpacing = '0.3px';
      btnRow.appendChild(btn);
    }

    row.appendChild(btnRow);
    return row;
  }

  // -----------------------------------------------------------------------
  // Inset controls (top, right, bottom, left)
  // -----------------------------------------------------------------------

  private buildInsetControls(
    element: Element,
    onCommit: ChangeCallback,
  ): void {
    if (!this.insetSection) return;
    this.insetSection.innerHTML = '';

    const currentPosition = getComputedProperty(element, 'position');
    const showInsets = currentPosition === 'absolute' || currentPosition === 'fixed';

    if (!showInsets) {
      this.insetSection.style.display = 'none';
      return;
    }

    this.insetSection.style.display = 'flex';

    // Section header
    const headerRow = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '5px',
      marginTop: '2px',
    });
    const headerLabel = createText('span', 'Inset', 'heading');
    headerLabel.style.fontSize = '11px';
    headerLabel.style.color = OVERLAY.textMuted;
    headerLabel.style.textTransform = 'uppercase';
    headerLabel.style.letterSpacing = '0.5px';
    headerRow.appendChild(headerLabel);
    this.insetSection.appendChild(headerRow);

    // 2x2 grid: T R / B L
    const grid = createElement('div', {}, {
      display: 'grid',
      gridTemplateColumns: '1fr 1fr',
      gap: '3px',
    });

    for (const prop of INSET_PROPERTIES) {
      grid.appendChild(this.buildInsetCell(prop, element, onCommit));
    }

    this.insetSection.appendChild(grid);
  }

  private buildInsetCell(
    property: string,
    element: Element,
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    const cell = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '4px',
    });

    const sideLabel = createText('span', INSET_LABELS[property] ?? '', 'mono');
    sideLabel.style.color = OVERLAY.textMuted;
    sideLabel.style.fontSize = '10px';
    sideLabel.style.fontWeight = '600';
    sideLabel.style.width = '10px';
    sideLabel.style.flexShrink = '0';
    cell.appendChild(sideLabel);

    const currentValue = getComputedProperty(element, property);

    const input = createElement('input', {
      type: 'text',
      value: currentValue === 'auto' ? 'auto' : currentValue,
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

    cell.appendChild(input);
    return cell;
  }

  // -----------------------------------------------------------------------
  // Refresh inset section after position type change
  // -----------------------------------------------------------------------

  private refreshInsetVisibility(newPosition: string): void {
    if (!this.insetSection || !this.currentElement || !this.currentOnCommit) return;
    this.buildInsetControls(this.currentElement, this.currentOnCommit);
  }
}

function extractUnit(value: string): string | undefined {
  const match = value.match(/[\d.]+(.+)$/);
  return match?.[1] || undefined;
}
