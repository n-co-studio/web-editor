import type { PropertyChange } from '@nco-studio/shared';
import { createElement, createText, createButton, makeDraggable } from '../../shared/ui-utils';
import { getComputedProperty } from '../../shared/dom-utils';
import { OVERLAY, TOOLBAR_WIDTH } from '../../shared/constants';
import type { PreviewManager } from './preview';

type ChangeCallback = (changes: PropertyChange[]) => void;

/** Dimension properties handled by the dimensions edit mode. */
export const DIMENSION_PROPERTIES = ['width', 'height'] as const;

/** Read current dimension values for an element. */
export function readDimensionValues(
  element: Element,
): Record<string, string> {
  return {
    width: getComputedProperty(element, 'width'),
    height: getComputedProperty(element, 'height'),
  };
}

/**
 * Build PropertyChange objects from before/after dimension values.
 * Preserves unit type (%, rem, em, px).
 */
export function buildDimensionChanges(
  before: Record<string, string>,
  after: Record<string, string>,
): PropertyChange[] {
  const changes: PropertyChange[] = [];

  for (const prop of DIMENSION_PROPERTIES) {
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
// Preset definitions
// ---------------------------------------------------------------------------

const PRESETS: Array<{ label: string; value: string }> = [
  { label: 'Auto', value: 'auto' },
  { label: 'Hug', value: 'fit-content' },
  { label: 'Full', value: '100%' },
];

// ---------------------------------------------------------------------------
// DimensionsEditor — floating mini-panel
// ---------------------------------------------------------------------------

/**
 * Dimensions editing controls rendered as a floating mini-panel.
 * Provides width/height preset buttons (auto, hug, full) and current value display.
 * Positioned relative to the toolbar anchor point.
 */
export class DimensionsEditor {
  private container: HTMLDivElement | null = null;
  private closeCb: (() => void) | null = null;
  private userDragged = false;

  constructor(
    private readonly preview: PreviewManager,
  ) {}

  onClose(cb: () => void): void {
    this.closeCb = cb;
  }

  /**
   * Render dimension controls for the selected element.
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
      window.innerWidth - 208,
    );
    const panelTop = Math.max(8, anchorPos.y);

    const container = createElement('div', { role: 'dialog', 'aria-label': 'Dimensions editor' }, {
      position: 'fixed',
      left: `${panelLeft}px`,
      top: `${panelTop}px`,
      width: '200px',
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
    const title = createText('span', 'Size', 'heading');
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
      gap: '8px',
    });

    body.appendChild(this.buildAxisRow('width', element, onCommit));
    body.appendChild(this.buildAxisRow('height', element, onCommit));

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
      window.innerWidth - 208,
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

  private buildAxisRow(
    property: 'width' | 'height',
    element: Element,
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    const wrapper = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      gap: '4px',
    });

    // Label + current value
    const labelRow = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
    });

    const label = createText('span', property === 'width' ? 'W' : 'H', 'mono');
    label.style.color = OVERLAY.textMuted;
    label.style.fontSize = '10px';
    label.style.fontWeight = '600';
    labelRow.appendChild(label);

    const currentValue = getComputedProperty(element, property);
    const valueDisplay = createText('span', currentValue, 'mono');
    valueDisplay.style.fontSize = '10px';
    valueDisplay.style.color = OVERLAY.text;
    labelRow.appendChild(valueDisplay);

    wrapper.appendChild(labelRow);

    // Preset buttons row
    const btnRow = createElement('div', {}, {
      display: 'flex',
      gap: '4px',
    });

    for (const preset of PRESETS) {
      const btn = createButton(preset.label, 'ghost', () => {
        const fromValue = getComputedProperty(element, property);
        this.preview.begin(element as HTMLElement);
        this.preview.apply(property, preset.value);
        this.preview.commit();
        valueDisplay.textContent = preset.value;
        onCommit([{
          property,
          fromValue,
          toValue: preset.value,
        }]);
      });
      btn.style.flex = '1';
      btn.style.padding = '3px 0';
      btn.style.fontSize = '10px';
      btn.style.fontFamily = OVERLAY.monoFamily;
      btnRow.appendChild(btn);
    }

    wrapper.appendChild(btnRow);

    return wrapper;
  }
}
