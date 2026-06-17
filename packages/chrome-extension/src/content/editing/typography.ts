import type { PropertyChange } from '@nco-studio/shared';
import { createElement, createText, createButton, makeDraggable } from '../../shared/ui-utils';
import { getComputedProperty } from '../../shared/dom-utils';
import { OVERLAY, TOOLBAR_WIDTH } from '../../shared/constants';
import type { TokenStore } from '../tokens/store';
import type { PreviewManager } from './preview';

type ChangeCallback = (changes: PropertyChange[]) => void;

/**
 * Typography editing controls rendered as a floating mini-panel.
 * Provides font-size, font-family, font-weight, line-height, and color controls.
 * Positioned relative to the toolbar anchor point.
 */
export class TypographyEditor {
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
   * Render typography controls for the selected element.
   * Returns the container element to append to the shadow root.
   */
  render(
    element: Element,
    anchorPos: { x: number; y: number },
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    this.cleanup();

    // Floating panel wrapper
    const panelLeft = Math.min(
      anchorPos.x + TOOLBAR_WIDTH + 8,
      window.innerWidth - 248,
    );
    const panelTop = Math.max(8, anchorPos.y);

    const container = createElement('div', { role: 'dialog', 'aria-label': 'Typography editor' }, {
      position: 'fixed',
      left: `${panelLeft}px`,
      top: `${panelTop}px`,
      width: '240px',
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
    const title = createText('span', 'Typography', 'heading');
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

    // Font size
    body.appendChild(this.buildFontSizeControl(element, onCommit));

    // Font family
    body.appendChild(this.buildFontFamilyControl(element, onCommit));

    // Font weight
    body.appendChild(this.buildFontWeightControl(element, onCommit));

    // Line height
    body.appendChild(this.buildLineHeightControl(element, onCommit));

    // Color
    body.appendChild(this.buildColorControl(element, onCommit));

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
      window.innerWidth - 248,
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

  private buildFontSizeControl(
    element: Element,
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    const tokens = this.tokenStore.getForProperty('font-size');
    const row = this.buildRow('font-size');
    const currentValue = getComputedProperty(element, 'font-size');

    const options = tokens.length > 0
      ? tokens
      : [
          { name: '10px', value: '10px' },
          { name: '11px', value: '11px' },
          { name: '12px', value: '12px' },
          { name: '13px', value: '13px' },
          { name: '14px', value: '14px' },
          { name: '16px', value: '16px' },
          { name: '18px', value: '18px' },
          { name: '20px', value: '20px' },
          { name: '24px', value: '24px' },
          { name: '28px', value: '28px' },
          { name: '32px', value: '32px' },
          { name: '36px', value: '36px' },
          { name: '40px', value: '40px' },
          { name: '48px', value: '48px' },
          { name: '56px', value: '56px' },
          { name: '64px', value: '64px' },
          { name: '72px', value: '72px' },
        ];

    const select = this.buildTokenSelect(options, currentValue, (newValue, token) => {
      this.preview.begin(element as HTMLElement);
      this.preview.apply('font-size', newValue);
      this.preview.commit();
      onCommit([{
        property: 'font-size',
        fromValue: currentValue,
        toValue: newValue,
        unit: extractUnit(newValue),
        toToken: token?.name,
      }]);
    });
    row.appendChild(select);

    return row;
  }

  private buildFontFamilyControl(
    element: Element,
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    const tokens = this.tokenStore.getForProperty('font-family');
    const row = this.buildRow('font-family');
    const currentValue = getComputedProperty(element, 'font-family');

    const options = tokens.length > 0
      ? tokens
      : [
          { name: 'sans-serif', value: 'sans-serif' },
          { name: 'serif', value: 'serif' },
          { name: 'monospace', value: 'monospace' },
          { name: 'system-ui', value: 'system-ui' },
        ];

    const select = this.buildTokenSelect(options, currentValue, (newValue, token) => {
      this.preview.begin(element as HTMLElement);
      this.preview.apply('font-family', newValue);
      this.preview.commit();
      onCommit([{
        property: 'font-family',
        fromValue: currentValue,
        toValue: newValue,
        toToken: token?.name,
      }]);
    });
    row.appendChild(select);

    return row;
  }

  private buildFontWeightControl(
    element: Element,
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    const tokens = this.tokenStore.getForProperty('font-weight');
    const row = this.buildRow('font-weight');
    const currentValue = getComputedProperty(element, 'font-weight');

    // Use token dropdown if tokens available, otherwise fall back to hardcoded weights
    const options = tokens.length > 0
      ? tokens
      : [
          { name: 'normal', value: '400' },
          { name: 'medium', value: '500' },
          { name: 'semibold', value: '600' },
          { name: 'bold', value: '700' },
        ];

    const select = this.buildTokenSelect(options, currentValue, (newValue, token) => {
      this.preview.begin(element as HTMLElement);
      this.preview.apply('font-weight', newValue);
      this.preview.commit();
      onCommit([{
        property: 'font-weight',
        fromValue: currentValue,
        toValue: newValue,
        toToken: token?.name,
      }]);
    });
    row.appendChild(select);

    return row;
  }

  private buildLineHeightControl(
    element: Element,
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    const row = this.buildRow('line-height');
    const currentValue = getComputedProperty(element, 'line-height');
    const currentNum = parseFloat(currentValue);

    const slider = createElement('input', {
      type: 'range',
      min: '0.8',
      max: '3',
      step: '0.1',
      value: String(isNaN(currentNum) ? 1.5 : currentNum / parseFloat(getComputedProperty(element, 'font-size'))),
    }, {
      flex: '1',
      pointerEvents: 'auto',
      cursor: 'pointer',
    });

    const valueDisplay = createText('span', currentValue, 'mono');
    valueDisplay.style.width = '40px';
    valueDisplay.style.textAlign = 'right';
    valueDisplay.style.fontSize = '10px';

    slider.addEventListener('input', () => {
      const ratio = parseFloat((slider as HTMLInputElement).value);
      const fontSize = parseFloat(getComputedProperty(element, 'font-size'));
      const newLh = `${Math.round(ratio * fontSize)}px`;
      this.preview.begin(element as HTMLElement);
      this.preview.apply('line-height', newLh);
      valueDisplay.textContent = newLh;
    });

    slider.addEventListener('change', () => {
      const ratio = parseFloat((slider as HTMLInputElement).value);
      const fontSize = parseFloat(getComputedProperty(element, 'font-size'));
      const newLh = `${Math.round(ratio * fontSize)}px`;
      this.preview.commit();
      onCommit([{
        property: 'line-height',
        fromValue: currentValue,
        toValue: newLh,
        unit: 'px',
      }]);
    });

    row.appendChild(slider);
    row.appendChild(valueDisplay);
    return row;
  }

  private buildColorControl(
    element: Element,
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    const tokens = this.tokenStore.getForProperty('color');
    const row = this.buildRow('color');
    const currentValue = getComputedProperty(element, 'color');

    // Color preview chip
    const chip = createElement('div', {}, {
      width: '20px',
      height: '20px',
      borderRadius: '3px',
      border: `1px solid ${OVERLAY.border}`,
      background: currentValue,
      flexShrink: '0',
    });
    row.appendChild(chip);

    if (tokens.length === 0) {
      row.appendChild(this.buildReadOnlyValue(currentValue));
      return row;
    }

    const select = this.buildTokenSelect(tokens, currentValue, (newValue, token) => {
      this.preview.begin(element as HTMLElement);
      this.preview.apply('color', newValue);
      this.preview.commit();
      chip.style.background = newValue;
      onCommit([{
        property: 'color',
        fromValue: currentValue,
        toValue: newValue,
        toToken: token?.name,
      }]);
    });
    row.appendChild(select);

    return row;
  }

  // -----------------------------------------------------------------------
  // Shared builders
  // -----------------------------------------------------------------------

  private buildRow(label: string): HTMLDivElement {
    const row = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '6px',
    });

    const labelEl = createText('span', label, 'mono');
    labelEl.style.color = OVERLAY.textMuted;
    labelEl.style.width = '66px';
    labelEl.style.flexShrink = '0';
    labelEl.style.fontSize = '10px';
    row.appendChild(labelEl);

    return row;
  }

  private buildReadOnlyValue(value: string): HTMLElement {
    const el = createText('span', value, 'mono');
    el.style.color = OVERLAY.textMuted;
    el.style.fontSize = '10px';
    el.style.flex = '1';
    el.style.overflow = 'hidden';
    el.style.textOverflow = 'ellipsis';
    el.style.whiteSpace = 'nowrap';
    return el;
  }

  private buildTokenSelect(
    tokens: Array<{ name: string; value: string }>,
    currentValue: string,
    onChange: (value: string, token?: { name: string; value: string }) => void,
  ): HTMLSelectElement {
    const select = createElement('select', {}, {
      background: 'rgba(255, 255, 255, 0.1)',
      color: OVERLAY.text,
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusSm,
      padding: '2px 4px',
      fontSize: '10px',
      fontFamily: OVERLAY.monoFamily,
      pointerEvents: 'auto',
      cursor: 'pointer',
      flex: '1',
      minWidth: '0',
    }) as HTMLSelectElement;

    const hasMatch = tokens.some((t) => t.value === currentValue);
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
      const token = tokens.find((t) => t.value === select.value);
      onChange(select.value, token);
    });

    return select;
  }

}

function extractUnit(value: string): string | undefined {
  const match = value.match(/[\d.]+(.+)$/);
  return match?.[1] || undefined;
}
