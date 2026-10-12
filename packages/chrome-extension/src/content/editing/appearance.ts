import type { PropertyChange } from '@nco-studio/shared';
import { createElement, createText, createButton, makeDraggable } from '../../shared/ui-utils';
import { getComputedProperty } from '../../shared/dom-utils';
import { OVERLAY, TOOLBAR_WIDTH } from '../../shared/constants';
import type { PreviewManager } from './preview';
import { buildColorInput, attachColorPopover } from './color-input';
import type { TokenStore } from '../tokens/store';

type ChangeCallback = (changes: PropertyChange[]) => void;

const PANEL_WIDTH = 260;

// ---------------------------------------------------------------------------
// Shadow parsing
// ---------------------------------------------------------------------------

interface ShadowValues {
  x: number;
  y: number;
  blur: number;
  spread: number;
  color: string;
  inset: boolean;
}

function parseShadow(shadow: string): ShadowValues {
  const defaults: ShadowValues = { x: 0, y: 0, blur: 0, spread: 0, color: 'rgba(0, 0, 0, 0.25)', inset: false };
  if (!shadow || shadow === 'none') return defaults;

  const inset = shadow.includes('inset');
  const cleaned = shadow.replace(/inset/g, '').trim();

  // Extract color (rgb/rgba/hsl/hex at start or end)
  let color = defaults.color;
  let rest = cleaned;

  const rgbaMatch = cleaned.match(/rgba?\([^)]+\)/);
  if (rgbaMatch) {
    color = rgbaMatch[0];
    rest = cleaned.replace(rgbaMatch[0], '').trim();
  } else {
    const hexMatch = cleaned.match(/#[0-9a-fA-F]{3,8}/);
    if (hexMatch) {
      color = hexMatch[0];
      rest = cleaned.replace(hexMatch[0], '').trim();
    } else {
      // Named color at start or end
      const parts = cleaned.split(/\s+/);
      if (parts.length > 2) {
        const last = parts[parts.length - 1];
        if (!/^-?\d/.test(last)) {
          color = last;
          rest = parts.slice(0, -1).join(' ');
        }
      }
    }
  }

  // Parse numeric values
  const nums = rest.match(/-?\d+(\.\d+)?/g);
  if (nums) {
    defaults.x = parseFloat(nums[0] ?? '0');
    defaults.y = parseFloat(nums[1] ?? '0');
    defaults.blur = parseFloat(nums[2] ?? '0');
    defaults.spread = parseFloat(nums[3] ?? '0');
  }

  return { x: defaults.x, y: defaults.y, blur: defaults.blur, spread: defaults.spread, color, inset };
}

function composeShadow(v: ShadowValues): string {
  if (v.x === 0 && v.y === 0 && v.blur === 0 && v.spread === 0) return 'none';
  const insetStr = v.inset ? 'inset ' : '';
  return `${insetStr}${v.x}px ${v.y}px ${v.blur}px ${v.spread}px ${v.color}`;
}

// ---------------------------------------------------------------------------
// Outline style options
// ---------------------------------------------------------------------------

const OUTLINE_STYLES = ['none', 'solid', 'dashed', 'dotted', 'double', 'groove', 'ridge', 'inset', 'outset'] as const;

// ---------------------------------------------------------------------------
// AppearanceEditor
// ---------------------------------------------------------------------------

/**
 * Appearance editing panel — cosmetic visual CSS properties.
 * Controls for background-color, box-shadow, border-radius, opacity, and outline.
 * Renders as a positioned floating panel anchored to the toolbar.
 */
export class AppearanceEditor {
  private container: HTMLDivElement | null = null;
  private closeCb: (() => void) | null = null;
  private userDragged = false;

  constructor(
    private readonly preview: PreviewManager,
    /** Optional: supplies colour tokens to the colour popovers. */
    private readonly tokenStore?: TokenStore,
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

    const panelLeft = Math.min(
      anchorPos.x + TOOLBAR_WIDTH + 8,
      window.innerWidth - (PANEL_WIDTH + 8),
    );
    const panelTop = Math.max(8, anchorPos.y);

    const container = createElement('div', { role: 'dialog', 'aria-label': 'Appearance editor' }, {
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
    const title = createText('span', 'Appearance', 'heading');
    title.style.fontSize = '12px';
    header.appendChild(title);

    const closeBtn = createButton('\u00d7', 'ghost', () => {
      const cb = this.closeCb;
      this.cleanup();
      cb?.();
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
      maxHeight: '500px',
      overflowY: 'auto',
    });

    // --- Background Color ---
    body.appendChild(this.buildColorSection('Background', 'background-color', element, onCommit));

    // --- Opacity ---
    body.appendChild(this.buildOpacitySection(element, onCommit));

    // --- Box Shadow ---
    body.appendChild(this.buildBoxShadowSection(element, onCommit));

    // Border radius is intentionally omitted — owned by the dedicated
    // 'border-radius' EditMode with drag handles.

    // --- Outline ---
    body.appendChild(this.buildOutlineSection(element, onCommit));

    container.appendChild(body);
    this.container = container;
    return container;
  }

  reposition(anchorPos: { x: number; y: number }): void {
    if (!this.container) return;
    if (this.userDragged) return;
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

  // ---------------------------------------------------------------------------
  // Background Color
  // ---------------------------------------------------------------------------

  private buildColorSection(
    label: string,
    property: string,
    element: Element,
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    const section = createElement('div', {}, { display: 'flex', flexDirection: 'column', gap: '4px' });

    const sectionLabel = createText('div', label, 'heading');
    sectionLabel.style.fontSize = '11px';
    sectionLabel.style.color = OVERLAY.text;
    section.appendChild(sectionLabel);

    const currentValue = getComputedProperty(element, property);
    section.appendChild(buildColorInput(
      property, currentValue, element, this.preview, onCommit,
      this.tokenStore?.getForCategory('colors') ?? [],
    ));

    return section;
  }

  // ---------------------------------------------------------------------------
  // Opacity
  // ---------------------------------------------------------------------------

  private buildOpacitySection(element: Element, onCommit: ChangeCallback): HTMLDivElement {
    const section = createElement('div', {}, { display: 'flex', flexDirection: 'column', gap: '4px' });

    const currentValue = getComputedProperty(element, 'opacity');
    const currentNum = parseFloat(currentValue) || 1;

    const labelRow = createElement('div', {}, {
      display: 'flex',
      justifyContent: 'space-between',
      alignItems: 'center',
    });
    const label = createText('span', 'Opacity', 'heading');
    label.style.fontSize = '11px';
    label.style.color = OVERLAY.text;
    labelRow.appendChild(label);

    const valueLabel = createText('span', `${Math.round(currentNum * 100)}%`, 'mono');
    valueLabel.style.color = OVERLAY.text;
    valueLabel.style.fontSize = '10px';
    labelRow.appendChild(valueLabel);
    section.appendChild(labelRow);

    const slider = createElement('input', {
      type: 'range',
      min: '0',
      max: '1',
      step: '0.01',
      value: String(currentNum),
    }, {
      width: '100%',
      height: '4px',
      cursor: 'pointer',
      accentColor: OVERLAY.primary,
    }) as HTMLInputElement;

    slider.addEventListener('input', () => {
      const val = parseFloat(slider.value);
      valueLabel.textContent = `${Math.round(val * 100)}%`;
      this.preview.begin(element as HTMLElement);
      this.preview.apply('opacity', String(val));
    });

    slider.addEventListener('change', () => {
      const originals = this.preview.commit();
      const fromValue = originals.get('opacity') || currentValue;
      onCommit([{ property: 'opacity', fromValue, toValue: slider.value }]);
    });

    section.appendChild(slider);
    return section;
  }

  // ---------------------------------------------------------------------------
  // Box Shadow
  // ---------------------------------------------------------------------------

  private buildBoxShadowSection(element: Element, onCommit: ChangeCallback): HTMLDivElement {
    const section = createElement('div', {}, { display: 'flex', flexDirection: 'column', gap: '6px' });

    const sectionLabel = createText('div', 'Box Shadow', 'heading');
    sectionLabel.style.fontSize = '11px';
    sectionLabel.style.color = OVERLAY.text;
    section.appendChild(sectionLabel);

    const currentValue = getComputedProperty(element, 'box-shadow');
    const shadow = parseShadow(currentValue);

    const sliders: Array<{ key: keyof ShadowValues; label: string; min: number; max: number; step: number }> = [
      { key: 'x', label: 'X Offset', min: -50, max: 50, step: 1 },
      { key: 'y', label: 'Y Offset', min: -50, max: 50, step: 1 },
      { key: 'blur', label: 'Blur', min: 0, max: 100, step: 1 },
      { key: 'spread', label: 'Spread', min: -50, max: 50, step: 1 },
    ];

    const applyPreview = () => {
      this.preview.begin(element as HTMLElement);
      this.preview.apply('box-shadow', composeShadow(shadow));
    };

    const commitShadow = () => {
      const originals = this.preview.commit();
      const fromValue = originals.get('box-shadow') || currentValue;
      onCommit([{ property: 'box-shadow', fromValue, toValue: composeShadow(shadow) }]);
    };

    // Shadow color
    const colorRow = createElement('div', {}, {
      display: 'flex',
      gap: '6px',
      alignItems: 'center',
    });
    const colorLabel = createText('span', 'Color', 'mono');
    colorLabel.style.color = OVERLAY.textMuted;
    colorLabel.style.fontSize = '10px';
    colorLabel.style.width = '50px';
    colorLabel.style.flexShrink = '0';
    colorRow.appendChild(colorLabel);

    const colorSwatch = createElement('div', { title: 'Open colour picker' }, {
      width: '20px',
      height: '20px',
      borderRadius: OVERLAY.radiusSm,
      border: `1px solid ${OVERLAY.swatchBorder}`,
      background: shadow.color,
      flexShrink: '0',
      cursor: 'pointer',
    });

    // Popover, not a zero-size hidden input driven by .click(): Chromium
    // anchors the native chooser to the input's box, so the old control could
    // never open one. Commits go through commitShadow because the colour is
    // one component of a serialised box-shadow, not a property of its own.
    attachColorPopover(colorSwatch, {
      label: 'box-shadow color',
      initial: shadow.color,
      tokens: this.tokenStore?.getForCategory('colors') ?? [],
      onInput: (value) => {
        shadow.color = value;
        colorSwatch.style.background = value;
        applyPreview();
      },
      onCommit: (value) => {
        shadow.color = value;
        colorSwatch.style.background = value;
        applyPreview();
        commitShadow();
      },
    });

    colorRow.appendChild(colorSwatch);
    section.appendChild(colorRow);

    // Numeric sliders
    for (const cfg of sliders) {
      const row = createElement('div', {}, {
        display: 'flex',
        flexDirection: 'column',
        gap: '2px',
      });

      const labelRow = createElement('div', {}, {
        display: 'flex',
        justifyContent: 'space-between',
        alignItems: 'center',
      });
      const sliderLabel = createText('span', cfg.label, 'mono');
      sliderLabel.style.color = OVERLAY.textMuted;
      sliderLabel.style.fontSize = '9px';
      labelRow.appendChild(sliderLabel);

      const valLabel = createText('span', `${shadow[cfg.key]}px`, 'mono');
      valLabel.style.color = OVERLAY.text;
      valLabel.style.fontSize = '9px';
      labelRow.appendChild(valLabel);
      row.appendChild(labelRow);

      const slider = createElement('input', {
        type: 'range',
        min: String(cfg.min),
        max: String(cfg.max),
        step: String(cfg.step),
        value: String(shadow[cfg.key]),
      }, {
        width: '100%',
        height: '4px',
        cursor: 'pointer',
        accentColor: OVERLAY.primary,
      }) as HTMLInputElement;

      slider.addEventListener('input', () => {
        const val = parseFloat(slider.value);
        (shadow as any)[cfg.key] = val;
        valLabel.textContent = `${val}px`;
        applyPreview();
      });

      slider.addEventListener('change', () => {
        commitShadow();
      });

      row.appendChild(slider);
      section.appendChild(row);
    }

    // Inset toggle
    const insetRow = createElement('div', {}, {
      display: 'flex',
      gap: '6px',
      alignItems: 'center',
    });
    const insetLabel = createText('span', 'Inset', 'mono');
    insetLabel.style.color = OVERLAY.textMuted;
    insetLabel.style.fontSize = '10px';
    insetRow.appendChild(insetLabel);

    const insetToggle = createElement('button', {}, {
      padding: '2px 8px',
      fontSize: '10px',
      border: `1px solid ${shadow.inset ? OVERLAY.primary : OVERLAY.border}`,
      borderRadius: OVERLAY.radiusSm,
      background: shadow.inset ? 'rgba(6, 182, 212, 0.12)' : OVERLAY.hover,
      color: shadow.inset ? OVERLAY.primary : OVERLAY.textMuted,
      cursor: 'pointer',
      fontFamily: OVERLAY.monoFamily,
    }) as HTMLButtonElement;
    insetToggle.textContent = shadow.inset ? 'On' : 'Off';
    insetToggle.addEventListener('click', () => {
      shadow.inset = !shadow.inset;
      insetToggle.textContent = shadow.inset ? 'On' : 'Off';
      insetToggle.style.borderColor = shadow.inset ? OVERLAY.primary : OVERLAY.border;
      insetToggle.style.background = shadow.inset ? 'rgba(6, 182, 212, 0.12)' : OVERLAY.hover;
      insetToggle.style.color = shadow.inset ? OVERLAY.primary : OVERLAY.textMuted;
      this.preview.revert();
      const fromValue = getComputedProperty(element, 'box-shadow');
      (element as HTMLElement).style.setProperty('box-shadow', composeShadow(shadow));
      onCommit([{ property: 'box-shadow', fromValue, toValue: composeShadow(shadow) }]);
    });
    insetRow.appendChild(insetToggle);

    // Reset
    const resetBtn = createButton('Reset', 'ghost', () => {
      this.preview.revert();
      const fromValue = getComputedProperty(element, 'box-shadow');
      (element as HTMLElement).style.setProperty('box-shadow', 'none');
      onCommit([{ property: 'box-shadow', fromValue, toValue: 'none' }]);
    });
    resetBtn.style.fontSize = '9px';
    resetBtn.style.padding = '2px 6px';
    resetBtn.style.marginLeft = 'auto';
    insetRow.appendChild(resetBtn);

    section.appendChild(insetRow);
    return section;
  }

  // ---------------------------------------------------------------------------
  // Outline
  // ---------------------------------------------------------------------------

  private buildOutlineSection(element: Element, onCommit: ChangeCallback): HTMLDivElement {
    const section = createElement('div', {}, { display: 'flex', flexDirection: 'column', gap: '4px' });

    const sectionLabel = createText('div', 'Outline', 'heading');
    sectionLabel.style.fontSize = '11px';
    sectionLabel.style.color = OVERLAY.text;
    section.appendChild(sectionLabel);

    // Outline style dropdown
    const currentStyle = getComputedProperty(element, 'outline-style');
    const styleRow = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      gap: '2px',
    });
    const styleLabel = createText('span', 'Style', 'mono');
    styleLabel.style.color = OVERLAY.textMuted;
    styleLabel.style.fontSize = '10px';
    styleRow.appendChild(styleLabel);

    const styleSelect = createElement('select', {}, {
      width: '100%',
      padding: '4px 6px',
      background: OVERLAY.hover,
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusSm,
      color: OVERLAY.text,
      fontSize: OVERLAY.monoSize,
      fontFamily: OVERLAY.monoFamily,
      outline: 'none',
      cursor: 'pointer',
      boxSizing: 'border-box',
    }) as HTMLSelectElement;

    for (const style of OUTLINE_STYLES) {
      const opt = createElement('option', { value: style }, {
        background: '#1a1a2e',
        color: OVERLAY.text,
      }) as HTMLOptionElement;
      opt.textContent = style;
      if (currentStyle === style) opt.selected = true;
      styleSelect.appendChild(opt);
    }

    styleSelect.addEventListener('change', () => {
      const fromValue = getComputedProperty(element, 'outline-style');
      this.preview.begin(element as HTMLElement);
      this.preview.apply('outline-style', styleSelect.value);
      this.preview.commit();
      onCommit([{ property: 'outline-style', fromValue, toValue: styleSelect.value }]);
    });

    styleRow.appendChild(styleSelect);
    section.appendChild(styleRow);

    // Outline width
    const currentWidth = parseFloat(getComputedProperty(element, 'outline-width')) || 0;
    const widthRow = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      gap: '2px',
    });
    const widthLabelRow = createElement('div', {}, {
      display: 'flex',
      justifyContent: 'space-between',
      alignItems: 'center',
    });
    const widthLabel = createText('span', 'Width', 'mono');
    widthLabel.style.color = OVERLAY.textMuted;
    widthLabel.style.fontSize = '9px';
    widthLabelRow.appendChild(widthLabel);

    const widthValLabel = createText('span', `${currentWidth}px`, 'mono');
    widthValLabel.style.color = OVERLAY.text;
    widthValLabel.style.fontSize = '9px';
    widthLabelRow.appendChild(widthValLabel);
    widthRow.appendChild(widthLabelRow);

    const widthSlider = createElement('input', {
      type: 'range',
      min: '0',
      max: '20',
      step: '1',
      value: String(currentWidth),
    }, {
      width: '100%',
      height: '4px',
      cursor: 'pointer',
      accentColor: OVERLAY.primary,
    }) as HTMLInputElement;

    widthSlider.addEventListener('input', () => {
      widthValLabel.textContent = `${widthSlider.value}px`;
      this.preview.begin(element as HTMLElement);
      this.preview.apply('outline-width', `${widthSlider.value}px`);
    });
    widthSlider.addEventListener('change', () => {
      const originals = this.preview.commit();
      const fromValue = originals.get('outline-width') || getComputedProperty(element, 'outline-width');
      onCommit([{ property: 'outline-width', fromValue, toValue: `${widthSlider.value}px` }]);
    });

    widthRow.appendChild(widthSlider);
    section.appendChild(widthRow);

    // Outline color
    const currentColor = getComputedProperty(element, 'outline-color');
    const colorRow = createElement('div', {}, {
      display: 'flex',
      gap: '6px',
      alignItems: 'center',
    });
    const colorLabel = createText('span', 'Color', 'mono');
    colorLabel.style.color = OVERLAY.textMuted;
    colorLabel.style.fontSize = '10px';
    colorLabel.style.width = '30px';
    colorLabel.style.flexShrink = '0';
    colorRow.appendChild(colorLabel);

    const colorSwatch = createElement('div', {}, {
      width: '20px',
      height: '20px',
      borderRadius: OVERLAY.radiusSm,
      border: `1px solid ${OVERLAY.swatchBorder}`,
      background: currentColor,
      flexShrink: '0',
      cursor: 'pointer',
    });

    // Same popover as every other colour control; the previous hidden input
    // had no box for Chromium to anchor a chooser to, so it never opened.
    attachColorPopover(colorSwatch, {
      label: 'outline-color',
      initial: currentColor,
      tokens: this.tokenStore?.getForCategory('colors') ?? [],
      onInput: (value) => {
        colorSwatch.style.background = value;
        this.preview.begin(element as HTMLElement);
        this.preview.apply('outline-color', value);
      },
      onCommit: (value, token) => {
        colorSwatch.style.background = value;
        this.preview.begin(element as HTMLElement);
        this.preview.apply('outline-color', value);
        const originals = this.preview.commit();
        const fromValue = originals.get('outline-color') || currentColor;
        onCommit([{ property: 'outline-color', fromValue, toValue: value, toToken: token?.name }]);
      },
    });

    colorRow.appendChild(colorSwatch);
    section.appendChild(colorRow);

    return section;
  }
}
