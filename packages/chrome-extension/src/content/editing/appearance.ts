import type { PropertyChange } from '@frontend-editor/shared';
import { createElement, createText, createButton, makeDraggable } from '../../shared/ui-utils';
import { getComputedProperty } from '../../shared/dom-utils';
import { OVERLAY, TOOLBAR_WIDTH } from '../../shared/constants';
import type { PreviewManager } from './preview';

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
// Border radius parsing
// ---------------------------------------------------------------------------

interface RadiusValues {
  tl: number;
  tr: number;
  br: number;
  bl: number;
}

function parseRadius(value: string): RadiusValues {
  const nums = value.match(/\d+(\.\d+)?/g);
  if (!nums || nums.length === 0) return { tl: 0, tr: 0, br: 0, bl: 0 };
  const vals = nums.map(Number);
  if (vals.length === 1) return { tl: vals[0], tr: vals[0], br: vals[0], bl: vals[0] };
  if (vals.length === 2) return { tl: vals[0], tr: vals[1], br: vals[0], bl: vals[1] };
  if (vals.length === 3) return { tl: vals[0], tr: vals[1], br: vals[2], bl: vals[1] };
  return { tl: vals[0], tr: vals[1], br: vals[2], bl: vals[3] };
}

function composeRadius(r: RadiusValues): string {
  if (r.tl === r.tr && r.tr === r.br && r.br === r.bl) return `${r.tl}px`;
  return `${r.tl}px ${r.tr}px ${r.br}px ${r.bl}px`;
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

    // --- Border Radius ---
    body.appendChild(this.buildBorderRadiusSection(element, onCommit));

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

    const row = createElement('div', {}, {
      display: 'flex',
      gap: '6px',
      alignItems: 'center',
    });

    // Color swatch preview
    const swatch = createElement('div', {}, {
      width: '24px',
      height: '24px',
      borderRadius: OVERLAY.radiusSm,
      border: `1px solid ${OVERLAY.border}`,
      background: currentValue,
      flexShrink: '0',
      cursor: 'pointer',
    });

    // Color input (native picker)
    const colorInput = createElement('input', { type: 'color' }, {
      position: 'absolute',
      opacity: '0',
      width: '0',
      height: '0',
      pointerEvents: 'none',
    }) as HTMLInputElement;

    // Try to set initial hex value
    colorInput.value = this.toHex(currentValue);

    swatch.addEventListener('click', () => colorInput.click());
    colorInput.addEventListener('input', () => {
      swatch.style.background = colorInput.value;
      this.preview.begin(element as HTMLElement);
      this.preview.apply(property, colorInput.value);
    });
    colorInput.addEventListener('change', () => {
      const originals = this.preview.commit();
      const fromValue = originals.get(property) || currentValue;
      onCommit([{ property, fromValue, toValue: colorInput.value }]);
      textInput.value = colorInput.value;
    });

    row.appendChild(swatch);
    row.appendChild(colorInput);

    // Text input for manual entry
    const textInput = this.buildInput(currentValue);
    textInput.style.flex = '1';
    textInput.addEventListener('keydown', (e) => {
      e.stopPropagation();
      if (e.key === 'Enter') {
        e.preventDefault();
        const fromValue = getComputedProperty(element, property);
        (element as HTMLElement).style.setProperty(property, textInput.value);
        swatch.style.background = textInput.value;
        onCommit([{ property, fromValue, toValue: textInput.value }]);
        textInput.blur();
      }
    });
    row.appendChild(textInput);

    section.appendChild(row);
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

    const colorSwatch = createElement('div', {}, {
      width: '20px',
      height: '20px',
      borderRadius: OVERLAY.radiusSm,
      border: `1px solid ${OVERLAY.border}`,
      background: shadow.color,
      flexShrink: '0',
      cursor: 'pointer',
    });

    const colorPicker = createElement('input', { type: 'color' }, {
      position: 'absolute',
      opacity: '0',
      width: '0',
      height: '0',
      pointerEvents: 'none',
    }) as HTMLInputElement;
    colorPicker.value = this.toHex(shadow.color);

    colorSwatch.addEventListener('click', () => colorPicker.click());
    colorPicker.addEventListener('input', () => {
      shadow.color = colorPicker.value;
      colorSwatch.style.background = colorPicker.value;
      applyPreview();
    });
    colorPicker.addEventListener('change', () => {
      commitShadow();
    });

    colorRow.appendChild(colorSwatch);
    colorRow.appendChild(colorPicker);
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
      background: shadow.inset ? 'rgba(6, 182, 212, 0.12)' : 'rgba(255, 255, 255, 0.08)',
      color: shadow.inset ? OVERLAY.primary : OVERLAY.textMuted,
      cursor: 'pointer',
      fontFamily: OVERLAY.monoFamily,
    }) as HTMLButtonElement;
    insetToggle.textContent = shadow.inset ? 'On' : 'Off';
    insetToggle.addEventListener('click', () => {
      shadow.inset = !shadow.inset;
      insetToggle.textContent = shadow.inset ? 'On' : 'Off';
      insetToggle.style.borderColor = shadow.inset ? OVERLAY.primary : OVERLAY.border;
      insetToggle.style.background = shadow.inset ? 'rgba(6, 182, 212, 0.12)' : 'rgba(255, 255, 255, 0.08)';
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
  // Border Radius
  // ---------------------------------------------------------------------------

  private buildBorderRadiusSection(element: Element, onCommit: ChangeCallback): HTMLDivElement {
    const section = createElement('div', {}, { display: 'flex', flexDirection: 'column', gap: '4px' });

    const sectionLabel = createText('div', 'Border Radius', 'heading');
    sectionLabel.style.fontSize = '11px';
    sectionLabel.style.color = OVERLAY.text;
    section.appendChild(sectionLabel);

    const currentValue = getComputedProperty(element, 'border-radius');
    const radius = parseRadius(currentValue);

    let linked = radius.tl === radius.tr && radius.tr === radius.br && radius.br === radius.bl;

    const applyPreview = () => {
      this.preview.begin(element as HTMLElement);
      this.preview.apply('border-radius', composeRadius(radius));
    };

    const commitRadius = () => {
      const originals = this.preview.commit();
      const fromValue = originals.get('border-radius') || currentValue;
      onCommit([{ property: 'border-radius', fromValue, toValue: composeRadius(radius) }]);
    };

    // Link toggle
    const linkRow = createElement('div', {}, {
      display: 'flex',
      gap: '6px',
      alignItems: 'center',
      marginBottom: '2px',
    });
    const linkBtn = createButton(linked ? 'Linked' : 'Individual', 'ghost', () => {
      linked = !linked;
      linkBtn.textContent = linked ? 'Linked' : 'Individual';
      linkBtn.style.borderColor = linked ? OVERLAY.primary : OVERLAY.border;
      linkBtn.style.color = linked ? OVERLAY.primary : OVERLAY.textMuted;
    });
    linkBtn.style.fontSize = '9px';
    linkBtn.style.padding = '2px 6px';
    linkBtn.style.borderColor = linked ? OVERLAY.primary : OVERLAY.border;
    linkBtn.style.color = linked ? OVERLAY.primary : OVERLAY.textMuted;
    linkRow.appendChild(linkBtn);
    section.appendChild(linkRow);

    const corners: Array<{ key: keyof RadiusValues; label: string }> = [
      { key: 'tl', label: 'Top Left' },
      { key: 'tr', label: 'Top Right' },
      { key: 'br', label: 'Bottom Right' },
      { key: 'bl', label: 'Bottom Left' },
    ];

    const valueLabels = new Map<keyof RadiusValues, HTMLSpanElement>();
    const sliderInputs = new Map<keyof RadiusValues, HTMLInputElement>();

    for (const corner of corners) {
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
      const label = createText('span', corner.label, 'mono');
      label.style.color = OVERLAY.textMuted;
      label.style.fontSize = '9px';
      labelRow.appendChild(label);

      const valLabel = createText('span', `${radius[corner.key]}px`, 'mono');
      valLabel.style.color = OVERLAY.text;
      valLabel.style.fontSize = '9px';
      labelRow.appendChild(valLabel);
      valueLabels.set(corner.key, valLabel);
      row.appendChild(labelRow);

      const slider = createElement('input', {
        type: 'range',
        min: '0',
        max: '100',
        step: '1',
        value: String(radius[corner.key]),
      }, {
        width: '100%',
        height: '4px',
        cursor: 'pointer',
        accentColor: OVERLAY.primary,
      }) as HTMLInputElement;
      sliderInputs.set(corner.key, slider);

      slider.addEventListener('input', () => {
        const val = parseFloat(slider.value);
        if (linked) {
          for (const c of corners) {
            radius[c.key] = val;
            sliderInputs.get(c.key)!.value = String(val);
            valueLabels.get(c.key)!.textContent = `${val}px`;
          }
        } else {
          radius[corner.key] = val;
          valLabel.textContent = `${val}px`;
        }
        applyPreview();
      });

      slider.addEventListener('change', () => {
        commitRadius();
      });

      row.appendChild(slider);
      section.appendChild(row);
    }

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
      background: 'rgba(255, 255, 255, 0.08)',
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
      border: `1px solid ${OVERLAY.border}`,
      background: currentColor,
      flexShrink: '0',
      cursor: 'pointer',
    });

    const colorPicker = createElement('input', { type: 'color' }, {
      position: 'absolute',
      opacity: '0',
      width: '0',
      height: '0',
      pointerEvents: 'none',
    }) as HTMLInputElement;
    colorPicker.value = this.toHex(currentColor);

    colorSwatch.addEventListener('click', () => colorPicker.click());
    colorPicker.addEventListener('input', () => {
      colorSwatch.style.background = colorPicker.value;
      this.preview.begin(element as HTMLElement);
      this.preview.apply('outline-color', colorPicker.value);
    });
    colorPicker.addEventListener('change', () => {
      const originals = this.preview.commit();
      const fromValue = originals.get('outline-color') || currentColor;
      onCommit([{ property: 'outline-color', fromValue, toValue: colorPicker.value }]);
    });

    colorRow.appendChild(colorSwatch);
    colorRow.appendChild(colorPicker);
    section.appendChild(colorRow);

    return section;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  private buildInput(value: string): HTMLInputElement {
    return createElement('input', { type: 'text', value }, {
      padding: '4px 6px',
      background: 'rgba(255, 255, 255, 0.08)',
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusSm,
      color: OVERLAY.text,
      fontSize: OVERLAY.monoSize,
      fontFamily: OVERLAY.monoFamily,
      outline: 'none',
      boxSizing: 'border-box',
      minWidth: '0',
    }) as HTMLInputElement;
  }

  private toHex(color: string): string {
    // Attempt to convert CSS color to hex for the native color picker
    if (color.startsWith('#')) return color.length <= 7 ? color : color.slice(0, 7);

    const match = color.match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/);
    if (match) {
      const r = parseInt(match[1], 10);
      const g = parseInt(match[2], 10);
      const b = parseInt(match[3], 10);
      return `#${((1 << 24) + (r << 16) + (g << 8) + b).toString(16).slice(1)}`;
    }

    return '#000000';
  }
}
