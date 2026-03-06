import { createElement, createText, createButton, makeDraggable } from '../shared/ui-utils';
import { OVERLAY, TOOLBAR_WIDTH } from '../shared/constants';

// ---------------------------------------------------------------------------
// Settings types
// ---------------------------------------------------------------------------

export interface GridSettings {
  baseSpacing: number;
  majorSpacing: number;
  opacity: number;
  lineColor: string;
  showHorizontal: boolean;
  showVertical: boolean;
}

export const DEFAULT_GRID_SETTINGS: GridSettings = {
  baseSpacing: 4,
  majorSpacing: 32,
  opacity: 0.15,
  lineColor: '#06b6d4',
  showHorizontal: true,
  showVertical: true,
};

export const COLOR_PRESETS: ReadonlyArray<{ label: string; value: string }> = [
  { label: 'Cyan', value: '#06b6d4' },
  { label: 'Blue', value: '#3b82f6' },
  { label: 'Pink', value: '#fb7185' },
  { label: 'Green', value: '#22c55e' },
  { label: 'Gray', value: '#71717a' },
];

// ---------------------------------------------------------------------------
// Grid Settings Panel
// ---------------------------------------------------------------------------

/**
 * Mini panel for adjusting grid overlay settings.
 * Follows the same render/reposition/cleanup pattern as other editors.
 */
export class GridSettingsPanel {
  private container: HTMLDivElement | null = null;
  private closeCb: (() => void) | null = null;
  private changeCb: ((settings: GridSettings) => void) | null = null;
  private settings: GridSettings;
  private userDragged = false;

  constructor(initialSettings: GridSettings) {
    this.settings = { ...initialSettings };
  }

  onClose(cb: () => void): void {
    this.closeCb = cb;
  }

  onChange(cb: (settings: GridSettings) => void): void {
    this.changeCb = cb;
  }

  /** Update defaults when tokens change (preserves user overrides). */
  updateDefaults(baseSpacing: number, majorSpacing: number): void {
    this.settings.baseSpacing = baseSpacing;
    this.settings.majorSpacing = majorSpacing;
    // If panel is open, re-render to show updated values
    if (this.container) {
      const pos = {
        x: parseFloat(this.container.style.left),
        y: parseFloat(this.container.style.top),
      };
      const wasDragged = this.userDragged;
      const parent = this.container.parentNode;
      this.cleanup();
      if (parent) {
        parent.appendChild(this.render(pos));
      }
      this.userDragged = wasDragged;
    }
  }

  getSettings(): GridSettings {
    return { ...this.settings };
  }

  render(anchorPos: { x: number; y: number }): HTMLDivElement {
    this.cleanup();

    const panelLeft = Math.min(
      anchorPos.x + TOOLBAR_WIDTH + 8,
      window.innerWidth - 216,
    );
    const panelTop = Math.max(8, anchorPos.y);

    const container = createElement('div', {
      role: 'dialog',
      'aria-label': 'Grid settings',
    }, {
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
      display: 'flex',
      flexDirection: 'column',
    });

    // Header
    const header = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
      padding: '6px 10px',
      borderBottom: `1px solid ${OVERLAY.border}`,
      flexShrink: '0',
    });
    const title = createText('span', 'Grid Settings', 'heading');
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

    // Body
    const body = createElement('div', {}, {
      padding: '8px 10px',
      display: 'flex',
      flexDirection: 'column',
      gap: '8px',
    });

    // Base spacing
    body.appendChild(this.buildNumberRow('Base spacing', this.settings.baseSpacing, 1, 100, (v) => {
      this.settings.baseSpacing = v;
      this.emitChange();
    }));

    // Major spacing
    body.appendChild(this.buildNumberRow('Major spacing', this.settings.majorSpacing, 0, 200, (v) => {
      this.settings.majorSpacing = v;
      this.emitChange();
    }));

    // Opacity
    body.appendChild(this.buildSliderRow('Opacity', this.settings.opacity, (v) => {
      this.settings.opacity = v;
      this.emitChange();
    }));

    // Color
    body.appendChild(this.buildColorRow(this.settings.lineColor, (c) => {
      this.settings.lineColor = c;
      this.emitChange();
    }));

    // Toggles
    body.appendChild(this.buildToggleRow('Horizontal lines', this.settings.showHorizontal, (v) => {
      this.settings.showHorizontal = v;
      this.emitChange();
    }));
    body.appendChild(this.buildToggleRow('Vertical lines', this.settings.showVertical, (v) => {
      this.settings.showVertical = v;
      this.emitChange();
    }));

    container.appendChild(body);

    this.container = container;
    return container;
  }

  reposition(anchorPos: { x: number; y: number }): void {
    if (!this.container) return;
    if (this.userDragged) return;
    const panelLeft = Math.min(
      anchorPos.x + TOOLBAR_WIDTH + 8,
      window.innerWidth - 216,
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

  isOpen(): boolean {
    return this.container !== null;
  }

  // -----------------------------------------------------------------------
  // Control builders
  // -----------------------------------------------------------------------

  private buildNumberRow(
    label: string,
    value: number,
    min: number,
    max: number,
    onChange: (v: number) => void,
  ): HTMLDivElement {
    const row = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      gap: '2px',
    });

    const lbl = createText('span', label, 'body');
    lbl.style.fontSize = '10px';
    lbl.style.color = OVERLAY.textMuted;
    row.appendChild(lbl);

    const inputRow = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '4px',
    });

    const input = createElement('input', {
      type: 'number',
      min: String(min),
      max: String(max),
      value: String(value),
    }, {
      width: '52px',
      background: 'rgba(255, 255, 255, 0.1)',
      color: OVERLAY.text,
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusSm,
      padding: '3px 6px',
      fontSize: '10px',
      fontFamily: OVERLAY.monoFamily,
      textAlign: 'right',
      pointerEvents: 'auto',
      outline: 'none',
    }) as HTMLInputElement;

    input.addEventListener('input', () => {
      const v = parseInt(input.value, 10);
      if (!isNaN(v) && v >= min && v <= max) {
        onChange(v);
      }
    });

    const unit = createText('span', 'px', 'mono');
    unit.style.fontSize = '10px';
    unit.style.color = OVERLAY.textMuted;

    inputRow.appendChild(input);
    inputRow.appendChild(unit);
    row.appendChild(inputRow);
    return row;
  }

  private buildSliderRow(
    label: string,
    value: number,
    onChange: (v: number) => void,
  ): HTMLDivElement {
    const row = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      gap: '2px',
    });

    const headerRow = createElement('div', {}, {
      display: 'flex',
      justifyContent: 'space-between',
      alignItems: 'center',
    });

    const lbl = createText('span', label, 'body');
    lbl.style.fontSize = '10px';
    lbl.style.color = OVERLAY.textMuted;
    headerRow.appendChild(lbl);

    const pct = createText('span', `${Math.round(value * 100)}%`, 'mono');
    pct.style.fontSize = '10px';
    pct.style.color = OVERLAY.textMuted;
    headerRow.appendChild(pct);

    row.appendChild(headerRow);

    const slider = createElement('input', {
      type: 'range',
      min: '0',
      max: '100',
      value: String(Math.round(value * 100)),
    }, {
      width: '100%',
      height: '4px',
      pointerEvents: 'auto',
      cursor: 'pointer',
      accentColor: OVERLAY.primary,
    }) as HTMLInputElement;

    slider.addEventListener('input', () => {
      const v = parseInt(slider.value, 10) / 100;
      pct.textContent = `${Math.round(v * 100)}%`;
      onChange(v);
    });

    row.appendChild(slider);
    return row;
  }

  private buildColorRow(
    selected: string,
    onChange: (color: string) => void,
  ): HTMLDivElement {
    const row = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      gap: '4px',
    });

    const lbl = createText('span', 'Color', 'body');
    lbl.style.fontSize = '10px';
    lbl.style.color = OVERLAY.textMuted;
    row.appendChild(lbl);

    const swatches = createElement('div', {}, {
      display: 'flex',
      gap: '6px',
    });

    for (const preset of COLOR_PRESETS) {
      const swatch = createElement('div', { title: preset.label }, {
        width: '18px',
        height: '18px',
        borderRadius: '50%',
        background: preset.value,
        cursor: 'pointer',
        pointerEvents: 'auto',
        border: preset.value === selected
          ? '2px solid #fff'
          : '2px solid transparent',
        boxSizing: 'border-box',
        transition: 'border-color 0.1s',
      });

      swatch.addEventListener('click', () => {
        // Update all swatch borders
        for (const child of swatches.children) {
          (child as HTMLElement).style.border = '2px solid transparent';
        }
        swatch.style.border = '2px solid #fff';
        onChange(preset.value);
      });

      swatches.appendChild(swatch);
    }

    row.appendChild(swatches);
    return row;
  }

  private buildToggleRow(
    label: string,
    checked: boolean,
    onChange: (v: boolean) => void,
  ): HTMLDivElement {
    const row = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '6px',
      cursor: 'pointer',
      pointerEvents: 'auto',
    });

    const box = createElement('div', {}, {
      width: '14px',
      height: '14px',
      borderRadius: '3px',
      border: `1.5px solid ${checked ? OVERLAY.primary : OVERLAY.border}`,
      background: checked ? OVERLAY.primary : 'transparent',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      flexShrink: '0',
      transition: 'background 0.1s, border-color 0.1s',
    });

    // Checkmark SVG
    const check = createElement('span', {}, {
      display: checked ? 'block' : 'none',
      width: '10px',
      height: '10px',
    });
    check.innerHTML = `<svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="#000" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="2,5.5 4,7.5 8,3"/></svg>`;
    box.appendChild(check);

    const lbl = createText('span', label, 'body');
    lbl.style.fontSize = '11px';
    lbl.style.color = OVERLAY.text;

    let state = checked;
    row.addEventListener('click', () => {
      state = !state;
      box.style.border = `1.5px solid ${state ? OVERLAY.primary : OVERLAY.border}`;
      box.style.background = state ? OVERLAY.primary : 'transparent';
      check.style.display = state ? 'block' : 'none';
      onChange(state);
    });

    row.appendChild(box);
    row.appendChild(lbl);
    return row;
  }

  private emitChange(): void {
    this.changeCb?.({ ...this.settings });
  }
}
