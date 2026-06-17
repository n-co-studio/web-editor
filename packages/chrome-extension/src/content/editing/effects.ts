import type { PropertyChange, RelatedChange, ElementInfo } from '@nco-studio/shared';
import { createElement, createText, createButton, makeDraggable } from '../../shared/ui-utils';
import { getComputedProperty, buildElementInfo } from '../../shared/dom-utils';
import { OVERLAY, TOOLBAR_WIDTH } from '../../shared/constants';
import type { PreviewManager } from './preview';

type ChangeCallback = (changes: PropertyChange[]) => void;
type RelatedChangeCallback = (changes: PropertyChange[], related: RelatedChange[]) => void;

const PANEL_WIDTH = 240;

// ---------------------------------------------------------------------------
// Filter presets (spec: feature-007)
// ---------------------------------------------------------------------------

interface FilterPreset {
  readonly name: string;
  readonly filters: Partial<Record<FilterFunction, number>>;
}

const FILTER_FUNCTIONS = [
  'hue-rotate', 'saturate', 'brightness', 'contrast',
  'blur', 'grayscale', 'sepia', 'invert',
] as const;
type FilterFunction = typeof FILTER_FUNCTIONS[number];

interface FilterConfig {
  readonly min: number;
  readonly max: number;
  readonly default: number;
  readonly step: number;
  readonly unit: string;
}

const FILTER_CONFIGS: Record<FilterFunction, FilterConfig> = {
  'hue-rotate': { min: -180, max: 180, default: 0, step: 1, unit: 'deg' },
  saturate:     { min: 0, max: 3, default: 1, step: 0.05, unit: '' },
  brightness:   { min: 0, max: 3, default: 1, step: 0.05, unit: '' },
  contrast:     { min: 0, max: 3, default: 1, step: 0.05, unit: '' },
  blur:         { min: 0, max: 20, default: 0, step: 0.5, unit: 'px' },
  grayscale:    { min: 0, max: 1, default: 0, step: 0.05, unit: '' },
  sepia:        { min: 0, max: 1, default: 0, step: 0.05, unit: '' },
  invert:       { min: 0, max: 1, default: 0, step: 0.05, unit: '' },
};

const PRESETS: FilterPreset[] = [
  { name: 'None', filters: {} },
  { name: 'Warm', filters: { saturate: 1.2, 'hue-rotate': 10, brightness: 1.05 } },
  { name: 'Cool', filters: { saturate: 0.9, 'hue-rotate': -15, brightness: 1.02 } },
  { name: 'Vintage', filters: { sepia: 0.3, contrast: 1.1, brightness: 0.95, saturate: 1.2 } },
  { name: 'High Contrast', filters: { contrast: 1.4, brightness: 1.05 } },
  { name: 'Soft', filters: { blur: 0.5, brightness: 1.1, contrast: 0.95 } },
  { name: 'Desaturate', filters: { grayscale: 0.7, brightness: 1.05 } },
];

// ---------------------------------------------------------------------------
// Blend mode values
// ---------------------------------------------------------------------------

const BLEND_MODES = [
  'normal', 'multiply', 'screen', 'overlay', 'darken', 'lighten',
  'color-dodge', 'color-burn', 'hard-light', 'soft-light',
  'difference', 'exclusion', 'hue', 'saturation', 'color', 'luminosity',
] as const;

// ---------------------------------------------------------------------------
// Filter string parsing
// ---------------------------------------------------------------------------

function parseFilterString(filter: string): Map<FilterFunction, number> {
  const values = new Map<FilterFunction, number>();
  if (!filter || filter === 'none') return values;

  for (const fn of FILTER_FUNCTIONS) {
    const pattern = fn === 'hue-rotate'
      ? /hue-rotate\(([^)]+)\)/
      : new RegExp(`${fn}\\(([^)]+)\\)`);
    const match = filter.match(pattern);
    if (match) {
      values.set(fn, parseFloat(match[1]));
    }
  }
  return values;
}

function composeFilterString(values: Map<FilterFunction, number>): string {
  const parts: string[] = [];
  for (const fn of FILTER_FUNCTIONS) {
    const val = values.get(fn);
    if (val === undefined) continue;
    const cfg = FILTER_CONFIGS[fn];
    if (val === cfg.default) continue;
    parts.push(`${fn}(${val}${cfg.unit})`);
  }
  return parts.length > 0 ? parts.join(' ') : 'none';
}

// ---------------------------------------------------------------------------
// EffectsEditor
// ---------------------------------------------------------------------------

export class EffectsEditor {
  private container: HTMLDivElement | null = null;
  private closeCb: (() => void) | null = null;
  private userDragged = false;
  private sliderInputs = new Map<FilterFunction, HTMLInputElement>();
  private sliderValueLabels = new Map<FilterFunction, HTMLSpanElement>();
  private filterValues = new Map<FilterFunction, number>();
  private parentIsolationState: { parent: HTMLElement; originalValue: string; committed: boolean } | null = null;

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
    onCommitWithRelated: RelatedChangeCallback,
  ): HTMLDivElement {
    this.cleanup();

    const panelLeft = Math.min(
      anchorPos.x + TOOLBAR_WIDTH + 8,
      window.innerWidth - (PANEL_WIDTH + 8),
    );
    const panelTop = Math.max(8, anchorPos.y);

    const container = createElement('div', { role: 'dialog', 'aria-label': 'Effects editor' }, {
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
    const title = createText('span', 'Effects', 'heading');
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
      gap: '10px',
      maxHeight: '500px',
      overflowY: 'auto',
    });

    // --- Filters section ---
    body.appendChild(this.buildFiltersSection(element, onCommit));

    // --- Blend Mode section ---
    body.appendChild(this.buildBlendModeSection(element, onCommit, onCommitWithRelated));

    // --- Clip Path section ---
    body.appendChild(this.buildClipPathSection(element, onCommit));

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
    // Only revert parent isolation if it was not committed as a real edit
    if (this.parentIsolationState && !this.parentIsolationState.committed) {
      const { parent, originalValue } = this.parentIsolationState;
      if (originalValue) {
        parent.style.setProperty('isolation', originalValue);
      } else {
        parent.style.removeProperty('isolation');
      }
    }
    this.parentIsolationState = null;
    this.container?.remove();
    this.container = null;
    this.userDragged = false;
    this.sliderInputs.clear();
    this.sliderValueLabels.clear();
    this.filterValues.clear();
  }

  // ---------------------------------------------------------------------------
  // Filters
  // ---------------------------------------------------------------------------

  private buildFiltersSection(element: Element, onCommit: ChangeCallback): HTMLDivElement {
    const section = createElement('div', {}, { display: 'flex', flexDirection: 'column', gap: '6px' });

    const sectionLabel = createText('div', 'Filters', 'heading');
    sectionLabel.style.fontSize = '11px';
    sectionLabel.style.color = OVERLAY.text;
    section.appendChild(sectionLabel);

    // Parse existing filter
    const currentFilter = getComputedProperty(element, 'filter');
    const parsed = parseFilterString(currentFilter);
    this.filterValues = new Map<FilterFunction, number>();
    for (const fn of FILTER_FUNCTIONS) {
      this.filterValues.set(fn, parsed.get(fn) ?? FILTER_CONFIGS[fn].default);
    }

    // Preset row
    const presetRow = createElement('div', {}, {
      display: 'flex',
      gap: '4px',
      overflowX: 'auto',
      paddingBottom: '4px',
    });
    for (const preset of PRESETS) {
      const btn = createButton(preset.name, 'ghost', () => {
        // Reset all to defaults, then apply preset values
        for (const fn of FILTER_FUNCTIONS) {
          const val = preset.filters[fn] ?? FILTER_CONFIGS[fn].default;
          this.filterValues.set(fn, val);
          this.sliderInputs.get(fn)!.value = String(val);
          this.updateSliderLabel(fn, val);
        }
        this.applyFilterPreview(element, onCommit);
      });
      btn.style.padding = '2px 6px';
      btn.style.fontSize = '9px';
      btn.style.whiteSpace = 'nowrap';
      btn.style.flexShrink = '0';
      presetRow.appendChild(btn);
    }
    section.appendChild(presetRow);

    // Advanced disclosure
    const advancedToggle = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '4px',
      cursor: 'pointer',
    });
    const arrow = createText('span', '\u25b6', 'mono');
    arrow.style.fontSize = '8px';
    arrow.style.transition = 'transform 0.15s';
    advancedToggle.appendChild(arrow);
    const advLabel = createText('span', 'Advanced', 'mono');
    advLabel.style.color = OVERLAY.textMuted;
    advLabel.style.fontSize = '10px';
    advancedToggle.appendChild(advLabel);
    section.appendChild(advancedToggle);

    const slidersContainer = createElement('div', {}, {
      display: 'none',
      flexDirection: 'column',
      gap: '6px',
    });

    advancedToggle.addEventListener('click', () => {
      const isOpen = slidersContainer.style.display !== 'none';
      slidersContainer.style.display = isOpen ? 'none' : 'flex';
      arrow.style.transform = isOpen ? '' : 'rotate(90deg)';
    });

    // Build sliders for each filter function
    for (const fn of FILTER_FUNCTIONS) {
      slidersContainer.appendChild(
        this.buildFilterSlider(fn, element, onCommit),
      );
    }

    // Reset button
    const resetBtn = createButton('Reset', 'ghost', () => {
      for (const fn of FILTER_FUNCTIONS) {
        const def = FILTER_CONFIGS[fn].default;
        this.filterValues.set(fn, def);
        this.sliderInputs.get(fn)!.value = String(def);
        this.updateSliderLabel(fn, def);
      }
      this.applyFilterPreview(element, onCommit);
    });
    resetBtn.style.fontSize = '9px';
    resetBtn.style.padding = '2px 6px';
    resetBtn.style.alignSelf = 'flex-start';
    slidersContainer.appendChild(resetBtn);

    section.appendChild(slidersContainer);
    return section;
  }

  private buildFilterSlider(
    fn: FilterFunction,
    element: Element,
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    const cfg = FILTER_CONFIGS[fn];
    const currentVal = this.filterValues.get(fn) ?? cfg.default;

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
    const label = createText('span', fn, 'mono');
    label.style.color = OVERLAY.textMuted;
    label.style.fontSize = '9px';
    labelRow.appendChild(label);

    const valueLabel = createText('span', this.formatFilterValue(fn, currentVal), 'mono');
    valueLabel.style.color = OVERLAY.text;
    valueLabel.style.fontSize = '9px';
    labelRow.appendChild(valueLabel);
    this.sliderValueLabels.set(fn, valueLabel);

    row.appendChild(labelRow);

    const slider = createElement('input', {
      type: 'range',
      min: String(cfg.min),
      max: String(cfg.max),
      step: String(cfg.step),
      value: String(currentVal),
    }, {
      width: '100%',
      height: '4px',
      cursor: 'pointer',
      accentColor: OVERLAY.primary,
    }) as HTMLInputElement;

    this.sliderInputs.set(fn, slider);

    slider.addEventListener('input', () => {
      const val = parseFloat(slider.value);
      this.filterValues.set(fn, val);
      this.updateSliderLabel(fn, val);
      // Live preview
      const filterStr = composeFilterString(this.filterValues);
      this.preview.begin(element as HTMLElement);
      this.preview.apply('filter', filterStr);
    });

    slider.addEventListener('change', () => {
      // Commit returns original values captured by begin()
      const originals = this.preview.commit();
      const fromValue = originals.get('filter') || getComputedProperty(element, 'filter');
      const filterStr = composeFilterString(this.filterValues);
      onCommit([{ property: 'filter', fromValue, toValue: filterStr }]);
    });

    row.appendChild(slider);
    return row;
  }

  private updateSliderLabel(fn: FilterFunction, val: number): void {
    const label = this.sliderValueLabels.get(fn);
    if (label) label.textContent = this.formatFilterValue(fn, val);
  }

  private formatFilterValue(fn: FilterFunction, val: number): string {
    const cfg = FILTER_CONFIGS[fn];
    const rounded = Math.round(val * 100) / 100;
    return cfg.unit ? `${rounded}${cfg.unit}` : String(rounded);
  }

  private applyFilterPreview(
    element: Element,
    onCommit: ChangeCallback,
  ): void {
    // Drain any active preview session (e.g., from a slider input event)
    this.preview.revert();
    const fromValue = getComputedProperty(element, 'filter');
    const filterStr = composeFilterString(this.filterValues);
    (element as HTMLElement).style.setProperty('filter', filterStr);
    onCommit([{
      property: 'filter',
      fromValue,
      toValue: filterStr,
    }]);
  }

  // ---------------------------------------------------------------------------
  // Blend Mode
  // ---------------------------------------------------------------------------

  private buildBlendModeSection(
    element: Element,
    onCommit: ChangeCallback,
    onCommitWithRelated: RelatedChangeCallback,
  ): HTMLDivElement {
    const section = createElement('div', {}, { display: 'flex', flexDirection: 'column', gap: '4px' });

    const sectionLabel = createText('div', 'Blend Mode', 'heading');
    sectionLabel.style.fontSize = '11px';
    sectionLabel.style.color = OVERLAY.text;
    section.appendChild(sectionLabel);

    const currentValue = getComputedProperty(element, 'mix-blend-mode');

    const select = createElement('select', {}, {
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

    for (const mode of BLEND_MODES) {
      const option = createElement('option', { value: mode }, {
        background: '#1a1a2e',
        color: OVERLAY.text,
      }) as HTMLOptionElement;
      option.textContent = mode;
      if (currentValue === mode) option.selected = true;
      select.appendChild(option);
    }

    // Isolation indicator
    const isolationNote = createText('div', '', 'mono');
    isolationNote.style.color = OVERLAY.textMuted;
    isolationNote.style.fontSize = '9px';
    isolationNote.style.display = 'none';

    select.addEventListener('change', () => {
      const newValue = select.value;
      const fromValue = getComputedProperty(element, 'mix-blend-mode');
      this.preview.begin(element as HTMLElement);
      this.preview.apply('mix-blend-mode', newValue);
      this.preview.commit();

      const change: PropertyChange = {
        property: 'mix-blend-mode',
        fromValue,
        toValue: newValue,
      };

      // Check if parent needs isolation
      const parent = (element as HTMLElement).parentElement;
      if (newValue !== 'normal' && parent) {
        const parentIsolation = getComputedProperty(parent, 'isolation');
        if (parentIsolation !== 'isolate') {
          // Track for revert on cleanup (only if not committed)
          this.parentIsolationState = {
            parent,
            originalValue: parent.style.getPropertyValue('isolation'),
            committed: false,
          };
          parent.style.setProperty('isolation', 'isolate');

          const parentInfo = buildElementInfo(parent);
          const relatedChange: RelatedChange = {
            element: parentInfo,
            changes: [{
              property: 'isolation',
              fromValue: parentIsolation,
              toValue: 'isolate',
            }],
            reason: 'blend-mode-isolation',
          };

          isolationNote.textContent = 'Parent isolation: isolate added';
          isolationNote.style.display = 'block';

          onCommitWithRelated([change], [relatedChange]);
          // Mark as committed — cleanup will not revert this
          this.parentIsolationState.committed = true;
          return;
        }
      }

      // Clear parent isolation tracking if switching back to normal
      if (newValue === 'normal' && this.parentIsolationState) {
        const { parent: p, originalValue } = this.parentIsolationState;
        if (originalValue) {
          p.style.setProperty('isolation', originalValue);
        } else {
          p.style.removeProperty('isolation');
        }
        this.parentIsolationState = null;
      }

      isolationNote.style.display = 'none';
      onCommit([change]);
    });

    section.appendChild(select);
    section.appendChild(isolationNote);
    return section;
  }

  // ---------------------------------------------------------------------------
  // Clip Path
  // ---------------------------------------------------------------------------

  private buildClipPathSection(element: Element, onCommit: ChangeCallback): HTMLDivElement {
    const section = createElement('div', {}, { display: 'flex', flexDirection: 'column', gap: '4px' });

    const sectionLabel = createText('div', 'Clip Path', 'heading');
    sectionLabel.style.fontSize = '11px';
    sectionLabel.style.color = OVERLAY.text;
    section.appendChild(sectionLabel);

    const currentClipPath = getComputedProperty(element, 'clip-path');

    // Check for unsupported clip-path values
    if (currentClipPath && currentClipPath !== 'none' &&
        !currentClipPath.startsWith('circle') &&
        !currentClipPath.startsWith('inset')) {
      const readOnly = createText('div', currentClipPath, 'mono');
      readOnly.style.color = OVERLAY.textMuted;
      readOnly.style.fontSize = '9px';
      readOnly.style.wordBreak = 'break-all';
      const note = createText('div', 'Unsupported shape (read-only)', 'mono');
      note.style.color = OVERLAY.textMuted;
      note.style.fontSize = '9px';
      note.style.fontStyle = 'italic';
      section.appendChild(readOnly);
      section.appendChild(note);
      return section;
    }

    // Shape selector
    const shapeRow = createElement('div', {}, {
      display: 'flex',
      gap: '4px',
      marginBottom: '4px',
    });

    const controlsContainer = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      gap: '6px',
    });

    let activeShape: 'none' | 'circle' | 'inset' = 'none';
    if (currentClipPath.startsWith('circle')) activeShape = 'circle';
    else if (currentClipPath.startsWith('inset')) activeShape = 'inset';

    const shapeButtons: HTMLButtonElement[] = [];
    for (const shape of ['none', 'circle', 'inset'] as const) {
      const btn = createButton(shape === 'none' ? 'None' : shape.charAt(0).toUpperCase() + shape.slice(1), 'ghost', () => {
        activeShape = shape;
        shapeButtons.forEach(b => {
          b.style.borderColor = OVERLAY.border;
          b.style.color = OVERLAY.textMuted;
        });
        btn.style.borderColor = OVERLAY.primary;
        btn.style.color = OVERLAY.text;
        controlsContainer.innerHTML = '';
        if (shape === 'none') {
          // Drain any active preview session (e.g., from a slider input event)
          this.preview.revert();
          const fromClip = getComputedProperty(element, 'clip-path');
          (element as HTMLElement).style.setProperty('clip-path', 'none');
          onCommit([{ property: 'clip-path', fromValue: fromClip, toValue: 'none' }]);
        } else if (shape === 'circle') {
          controlsContainer.appendChild(this.buildCircleControls(element, currentClipPath, onCommit));
        } else {
          controlsContainer.appendChild(this.buildInsetControls(element, currentClipPath, onCommit));
        }
      });
      btn.style.padding = '2px 8px';
      btn.style.fontSize = '10px';
      btn.style.flex = '1';
      if (shape === activeShape) {
        btn.style.borderColor = OVERLAY.primary;
        btn.style.color = OVERLAY.text;
      }
      shapeButtons.push(btn);
      shapeRow.appendChild(btn);
    }

    section.appendChild(shapeRow);

    // Show controls for current shape
    if (activeShape === 'circle') {
      controlsContainer.appendChild(this.buildCircleControls(element, currentClipPath, onCommit));
    } else if (activeShape === 'inset') {
      controlsContainer.appendChild(this.buildInsetControls(element, currentClipPath, onCommit));
    }

    section.appendChild(controlsContainer);
    return section;
  }

  private buildCircleControls(
    element: Element,
    originalClipPath: string,
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    const container = createElement('div', {}, { display: 'flex', flexDirection: 'column', gap: '4px' });

    // Parse existing circle value
    let radius = 50;
    const match = originalClipPath.match(/circle\((\d+(?:\.\d+)?)(%|px)/);
    if (match) radius = parseFloat(match[1]);

    const row = createElement('div', {}, {
      display: 'flex',
      justifyContent: 'space-between',
      alignItems: 'center',
    });
    const label = createText('span', 'Radius', 'mono');
    label.style.color = OVERLAY.textMuted;
    label.style.fontSize = '9px';
    row.appendChild(label);

    const valueLabel = createText('span', `${radius}%`, 'mono');
    valueLabel.style.color = OVERLAY.text;
    valueLabel.style.fontSize = '9px';
    row.appendChild(valueLabel);
    container.appendChild(row);

    const slider = createElement('input', {
      type: 'range',
      min: '0',
      max: '100',
      step: '1',
      value: String(radius),
    }, {
      width: '100%',
      height: '4px',
      cursor: 'pointer',
      accentColor: OVERLAY.primary,
    }) as HTMLInputElement;

    slider.addEventListener('input', () => {
      const val = parseFloat(slider.value);
      valueLabel.textContent = `${val}%`;
      const clipValue = `circle(${val}% at 50% 50%)`;
      this.preview.begin(element as HTMLElement);
      this.preview.apply('clip-path', clipValue);
    });

    slider.addEventListener('change', () => {
      const originals = this.preview.commit();
      const val = parseFloat(slider.value);
      const clipValue = `circle(${val}% at 50% 50%)`;
      const fromValue = originals.get('clip-path') || getComputedProperty(element, 'clip-path');
      onCommit([{ property: 'clip-path', fromValue, toValue: clipValue }]);
    });

    container.appendChild(slider);
    return container;
  }

  private buildInsetControls(
    element: Element,
    originalClipPath: string,
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    const container = createElement('div', {}, { display: 'flex', flexDirection: 'column', gap: '6px' });

    // Parse existing inset values
    let top = 0, right = 0, bottom = 0, left = 0;
    const match = originalClipPath.match(/inset\((\d+(?:\.\d+)?)px\s+(\d+(?:\.\d+)?)px\s+(\d+(?:\.\d+)?)px\s+(\d+(?:\.\d+)?)px/);
    if (match) {
      top = parseFloat(match[1]);
      right = parseFloat(match[2]);
      bottom = parseFloat(match[3]);
      left = parseFloat(match[4]);
    }

    const values = { top, right, bottom, left };

    const applyInset = () => {
      const clipValue = `inset(${values.top}px ${values.right}px ${values.bottom}px ${values.left}px)`;
      this.preview.begin(element as HTMLElement);
      this.preview.apply('clip-path', clipValue);
    };

    const commitInset = () => {
      const originals = this.preview.commit();
      const clipValue = `inset(${values.top}px ${values.right}px ${values.bottom}px ${values.left}px)`;
      const fromValue = originals.get('clip-path') || getComputedProperty(element, 'clip-path');
      onCommit([{ property: 'clip-path', fromValue, toValue: clipValue }]);
    };

    for (const edge of ['top', 'right', 'bottom', 'left'] as const) {
      const row = createElement('div', {}, {
        display: 'flex',
        justifyContent: 'space-between',
        alignItems: 'center',
      });
      const label = createText('span', edge, 'mono');
      label.style.color = OVERLAY.textMuted;
      label.style.fontSize = '9px';
      row.appendChild(label);

      const valueLabel = createText('span', `${values[edge]}px`, 'mono');
      valueLabel.style.color = OVERLAY.text;
      valueLabel.style.fontSize = '9px';
      row.appendChild(valueLabel);
      container.appendChild(row);

      const slider = createElement('input', {
        type: 'range',
        min: '0',
        max: '200',
        step: '1',
        value: String(values[edge]),
      }, {
        width: '100%',
        height: '4px',
        cursor: 'pointer',
        accentColor: OVERLAY.primary,
      }) as HTMLInputElement;

      slider.addEventListener('input', () => {
        values[edge] = parseFloat(slider.value);
        valueLabel.textContent = `${values[edge]}px`;
        applyInset();
      });

      slider.addEventListener('change', () => {
        commitInset();
      });

      container.appendChild(slider);
    }

    return container;
  }
}
