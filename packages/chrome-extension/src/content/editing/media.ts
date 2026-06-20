import type { PropertyChange, AttributeChange } from '@nco-studio/shared';
import { createElement, createText, createButton, makeDraggable } from '../../shared/ui-utils';
import { getComputedProperty } from '../../shared/dom-utils';
import { OVERLAY, TOOLBAR_WIDTH } from '../../shared/constants';
import type { PreviewManager } from './preview';
import {
  getParallaxBlockReason,
  resolveParallaxBlock,
  readParallaxMechanism,
  readParallaxStrength,
  readScrollSource,
  resolveScrollContainer,
  clampStrength,
  defaultStrengthFor,
  DEFAULT_MECHANISM,
  DEFAULT_STRENGTH,
  DEFAULT_SCROLL_SOURCE,
} from './parallax';
import type { ParallaxMechanism, ParallaxScrollSource } from './parallax';

// File System Access API types (not in standard TS lib)
declare global {
  interface Window {
    showOpenFilePicker?: (options?: OpenFilePickerOptions) => Promise<FileSystemFileHandle[]>;
  }
  interface OpenFilePickerOptions {
    types?: Array<{ description: string; accept: Record<string, string[]> }>;
    multiple?: boolean;
    startIn?: FileSystemDirectoryHandle | string;
  }
}

type ChangeCallback = (changes: PropertyChange[]) => void;
type AttributeCallback = (changes: AttributeChange[]) => void;
type ParallaxCallback = (element: Element, mechanism: ParallaxMechanism, strength: number, scrollSource: ParallaxScrollSource) => void;

const PANEL_WIDTH = 240;

interface MechanismOption {
  readonly value: ParallaxMechanism;
  readonly label: string;
}

const MECHANISM_OPTIONS: readonly MechanismOption[] = [
  { value: 'js-scroll', label: 'Background scan (default)' },
  { value: 'scroll-driven', label: 'Scroll-driven (CSS)' },
  { value: 'transform-3d', label: '3D depth' },
  { value: 'fixed', label: 'Fixed (page only)' },
];

const OBJECT_FIT_OPTIONS = ['fill', 'contain', 'cover', 'none', 'scale-down'] as const;
const OBJECT_POSITION_OPTIONS = ['center', 'top', 'bottom', 'left', 'right', 'top left', 'top right', 'bottom left', 'bottom right'] as const;
const ASPECT_RATIO_PRESETS = ['auto', '16 / 9', '4 / 3', '3 / 2', '1 / 1'] as const;

/**
 * Media editing panel — controls for image/video source, object-fit,
 * object-position, and aspect-ratio.
 * Renders as a positioned floating panel anchored to the toolbar.
 */
export class MediaEditor {
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
    onAttributeCommit: AttributeCallback,
    onParallaxToggle?: ParallaxCallback,
    onParallaxUpdate?: ParallaxCallback,
  ): HTMLDivElement {
    this.cleanup();

    const panelLeft = Math.min(
      anchorPos.x + TOOLBAR_WIDTH + 8,
      window.innerWidth - (PANEL_WIDTH + 8),
    );
    const panelTop = Math.max(8, anchorPos.y);

    const container = createElement('div', { role: 'dialog', 'aria-label': 'Media editor' }, {
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
    const title = createText('span', 'Media', 'heading');
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
      gap: '10px',
      maxHeight: '400px',
      overflowY: 'auto',
    });

    const isMediaElement = this.isMediaElement(element);

    // Parallax section — toggle, mechanism picker, strength dial, Advanced attrs.
    // Shown for images and for existing parallax blocks (to retune / revert).
    if (onParallaxToggle && getParallaxBlockReason(element) === null) {
      body.appendChild(this.buildParallaxSection(element, onParallaxToggle, onParallaxUpdate, onCommit));
    }

    // Source URL (only for img, video, source elements)
    if (isMediaElement) {
      const srcValue = (element as HTMLImageElement).src || '';
      body.appendChild(this.buildTextInput(
        'Source URL',
        srcValue,
        (value) => {
          const oldSrc = (element as HTMLImageElement).src || '';
          (element as HTMLImageElement).src = value;
          onAttributeCommit([{
            type: 'attribute',
            attribute: 'src',
            fromValue: oldSrc,
            toValue: value,
          }]);
        },
        { filePicker: true },
      ));

      // Alt text (only for img)
      if (element.tagName === 'IMG') {
        const altValue = (element as HTMLImageElement).alt || '';
        body.appendChild(this.buildTextInput(
          'Alt text',
          altValue,
          (value) => {
            const oldAlt = (element as HTMLImageElement).alt || '';
            (element as HTMLImageElement).alt = value;
            onAttributeCommit([{
              type: 'attribute',
              attribute: 'alt',
              fromValue: oldAlt,
              toValue: value,
            }]);
          },
        ));
      }
    }

    // Background image URL (for non-media elements)
    if (!isMediaElement) {
      const bgImage = getComputedProperty(element, 'background-image');
      const bgUrl = this.extractUrl(bgImage);
      body.appendChild(this.buildTextInput(
        'Background URL',
        bgUrl,
        (value) => {
          const cssValue = value ? `url(${value})` : 'none';
          this.preview.begin(element as HTMLElement);
          this.preview.apply('background-image', cssValue);
          this.preview.commit();
          onCommit([{
            property: 'background-image',
            fromValue: bgImage,
            toValue: cssValue,
          }]);
        },
        { filePicker: true },
      ));

      // Background size
      body.appendChild(this.buildSelect(
        'background-size',
        element,
        ['auto', 'cover', 'contain', '100% 100%'],
        onCommit,
      ));

      // Background position
      body.appendChild(this.buildSelect(
        'background-position',
        element,
        ['center', 'top', 'bottom', 'left', 'right', 'top left', 'top right', 'bottom left', 'bottom right'],
        onCommit,
      ));

      // Background repeat
      body.appendChild(this.buildSelect(
        'background-repeat',
        element,
        ['repeat', 'no-repeat', 'repeat-x', 'repeat-y', 'space', 'round'],
        onCommit,
      ));
    }

    // Object-fit (for replaced elements: img, video, canvas, etc.)
    if (isMediaElement) {
      body.appendChild(this.buildSelect(
        'object-fit',
        element,
        [...OBJECT_FIT_OPTIONS],
        onCommit,
      ));

      // Object-position
      body.appendChild(this.buildSelect(
        'object-position',
        element,
        [...OBJECT_POSITION_OPTIONS],
        onCommit,
      ));
    }

    // Aspect-ratio (works on any element)
    body.appendChild(this.buildSelect(
      'aspect-ratio',
      element,
      [...ASPECT_RATIO_PRESETS],
      onCommit,
    ));

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
  // Helpers
  // ---------------------------------------------------------------------------

  private isMediaElement(el: Element): boolean {
    const tag = el.tagName;
    return tag === 'IMG' || tag === 'VIDEO' || tag === 'CANVAS' || tag === 'SVG' || tag === 'PICTURE';
  }

  private extractUrl(bgImage: string): string {
    const match = bgImage.match(/url\(["']?([^"')]+)["']?\)/);
    return match?.[1] ?? '';
  }

  /**
   * Parallax section: a Standard image / Parallax background segmented toggle,
   * and (when ON) a mechanism picker, a strength dial (slider + numeric), and an
   * Advanced disclosure for banner height / background-size / background-position.
   * Values are read from the block's data-* markers + computed --parallax-strength.
   */
  private buildParallaxSection(
    element: Element,
    onParallaxToggle: ParallaxCallback,
    onParallaxUpdate: ParallaxCallback | undefined,
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    const block = resolveParallaxBlock(element);
    const isOn = block !== null;
    const mechanism: ParallaxMechanism = block ? readParallaxMechanism(block) : DEFAULT_MECHANISM;
    const strength = block ? readParallaxStrength(block) : DEFAULT_STRENGTH;
    const scrollSource: ParallaxScrollSource = block ? readScrollSource(block) : DEFAULT_SCROLL_SOURCE;

    const section = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      gap: '6px',
    });

    const heading = createText('div', 'Parallax', 'mono');
    heading.style.color = OVERLAY.text;
    heading.style.fontSize = '11px';
    section.appendChild(heading);

    // --- Segmented toggle: Standard image | Parallax background ---
    const toggleRow = createElement('div', { role: 'group', 'aria-label': 'Parallax mode' }, {
      display: 'flex',
      gap: '4px',
    });
    const makeToggleBtn = (label: string, active: boolean, onClick: () => void): HTMLButtonElement => {
      const btn = createElement('button', {
        type: 'button',
        'aria-pressed': active ? 'true' : 'false',
      }, {
        flex: '1',
        padding: '2px 8px',
        fontSize: '10px',
        cursor: 'pointer',
        background: 'transparent',
        border: `1px solid ${active ? OVERLAY.primary : OVERLAY.border}`,
        borderRadius: OVERLAY.radiusSm,
        color: active ? OVERLAY.text : OVERLAY.textMuted,
        fontFamily: OVERLAY.fontFamily,
      }) as HTMLButtonElement;
      btn.textContent = label;
      btn.addEventListener('click', () => { if (!active) onClick(); });
      btn.addEventListener('focus', () => { btn.style.outline = `2px solid ${OVERLAY.primary}`; });
      btn.addEventListener('blur', () => { btn.style.outline = ''; });
      return btn;
    };
    toggleRow.appendChild(makeToggleBtn('Standard image', !isOn, () => {
      // Turn OFF — revert the block to an <img>.
      onParallaxToggle(element, mechanism, strength, scrollSource);
    }));
    toggleRow.appendChild(makeToggleBtn('Parallax background', isOn, () => {
      // Turn ON — convert with the default mechanism + its default strength + scroll source.
      onParallaxToggle(element, DEFAULT_MECHANISM, defaultStrengthFor(DEFAULT_MECHANISM), DEFAULT_SCROLL_SOURCE);
    }));
    section.appendChild(toggleRow);

    if (!isOn || !block) {
      return section; // OFF — only the toggle is shown.
    }

    // --- Mechanism picker ---
    const supportsScrollTimeline = this.supportsScrollTimeline();
    const reducedMotion = this.prefersReducedMotion();

    const mechRow = createElement('div', {}, { display: 'flex', flexDirection: 'column', gap: '4px' });
    const mechLabel = createText('div', 'Mechanism', 'mono');
    mechLabel.style.color = OVERLAY.textMuted;
    mechLabel.style.fontSize = '10px';
    mechRow.appendChild(mechLabel);

    const mechSelect = createElement('select', { 'aria-label': 'Parallax mechanism' }, {
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
    for (const opt of MECHANISM_OPTIONS) {
      const o = createElement('option', { value: opt.value }, {
        background: '#1a1a2e',
        color: OVERLAY.text,
      }) as HTMLOptionElement;
      o.textContent = opt.label;
      if (opt.value === mechanism) o.selected = true;
      o.title = this.mechanismNote(opt.value, supportsScrollTimeline, reducedMotion);
      mechSelect.appendChild(o);
    }
    mechRow.appendChild(mechSelect);

    // Live support note under the select.
    const note = createText('div', this.mechanismNote(mechanism, supportsScrollTimeline, reducedMotion), 'mono');
    note.style.color = OVERLAY.warning;
    note.style.fontSize = '9px';
    note.style.lineHeight = '1.3';
    mechRow.appendChild(note);

    mechSelect.addEventListener('change', () => {
      const next = mechSelect.value as ParallaxMechanism;
      note.textContent = this.mechanismNote(next, supportsScrollTimeline, reducedMotion);
      // Read the live strength (the slider writes --parallax-strength inline on
      // drag) so a dial adjustment made before switching mechanism is preserved.
      onParallaxUpdate?.(block, next, readParallaxStrength(block), scrollSource);
    });
    section.appendChild(mechRow);

    // --- Scroll source: which element's scrolling drives the effect ---
    section.appendChild(this.buildScrollSourceRow(block, mechanism, scrollSource, onParallaxUpdate));

    // --- Strength dial (slider + numeric) ---
    section.appendChild(this.buildStrengthControl(block, mechanism, strength, scrollSource, onParallaxUpdate));

    // --- Advanced disclosure: banner height / background-size / position ---
    section.appendChild(this.buildParallaxAdvanced(block, onCommit));

    return section;
  }

  private supportsScrollTimeline(): boolean {
    try {
      return typeof CSS !== 'undefined' && typeof CSS.supports === 'function'
        && CSS.supports('animation-timeline: scroll()');
    } catch {
      return false;
    }
  }

  private prefersReducedMotion(): boolean {
    try {
      return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    } catch {
      return false;
    }
  }

  private mechanismNote(
    mechanism: ParallaxMechanism,
    supportsScrollTimeline: boolean,
    reducedMotion: boolean,
  ): string {
    let base: string;
    switch (mechanism) {
      case 'js-scroll':
        base = 'Pins the image to the viewport so the box reveals a fixed slice — works in any scroll container (rAF + capture scroll).';
        break;
      case 'scroll-driven':
        base = supportsScrollTimeline
          ? 'Pure-CSS scan (background-position via animation-timeline).'
          : 'Requires Chrome 115+ — degrades to a static cover elsewhere.';
        break;
      case 'transform-3d':
        base = '3D depth via translateZ — static (no scroll motion).';
        break;
      case 'fixed':
        base = 'background-attachment: fixed — page/viewport scroll only; not iOS Safari, not inner scrollers.';
        break;
    }
    if (reducedMotion && mechanism !== 'fixed') {
      base += ' Motion disabled — prefers-reduced-motion active.';
    }
    return base;
  }

  private buildScrollSourceRow(
    block: HTMLElement,
    mechanism: ParallaxMechanism,
    current: ParallaxScrollSource,
    onParallaxUpdate: ParallaxCallback | undefined,
  ): HTMLDivElement {
    const row = createElement('div', {}, { display: 'flex', flexDirection: 'column', gap: '4px' });
    const label = createText('div', 'Scroll source', 'mono');
    label.style.color = OVERLAY.textMuted;
    label.style.fontSize = '10px';
    row.appendChild(label);

    const select = createElement('select', { 'aria-label': 'Scroll source' }, {
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
    const opts: ReadonlyArray<{ value: ParallaxScrollSource; label: string }> = [
      { value: 'auto', label: 'Auto (nearest scroller)' },
      { value: 'page', label: 'Page / viewport' },
      { value: 'container', label: 'This container' },
    ];
    for (const o of opts) {
      const option = createElement('option', { value: o.value }, {
        background: '#1a1a2e',
        color: OVERLAY.text,
      }) as HTMLOptionElement;
      option.textContent = o.label;
      if (o.value === current) option.selected = true;
      select.appendChild(option);
    }
    row.appendChild(select);

    const note = createText('div', this.scrollSourceNote(block, mechanism, current), 'mono');
    note.style.color = OVERLAY.warning;
    note.style.fontSize = '9px';
    note.style.lineHeight = '1.3';
    row.appendChild(note);

    select.addEventListener('change', () => {
      const next = select.value as ParallaxScrollSource;
      note.textContent = this.scrollSourceNote(block, mechanism, next);
      onParallaxUpdate?.(block, mechanism, readParallaxStrength(block), next);
    });
    return row;
  }

  private scrollSourceNote(block: HTMLElement, mechanism: ParallaxMechanism, source: ParallaxScrollSource): string {
    if (mechanism === 'fixed' && source !== 'page') {
      return 'Fixed tracks the viewport only — choose Page, or a scroll-linked mechanism (3D / Scroll-driven / JS) for inner-scroll parallax.';
    }
    if (source === 'page') return 'Tracks page / viewport scroll.';
    const container = resolveScrollContainer(block);
    return container
      ? 'Tracks the nearest scroll container (e.g. an inner overlay).'
      : 'No inner scroll container detected — falls back to page scroll.';
  }

  private buildStrengthControl(
    block: HTMLElement,
    mechanism: ParallaxMechanism,
    initial: number,
    scrollSource: ParallaxScrollSource,
    onParallaxUpdate: ParallaxCallback | undefined,
  ): HTMLDivElement {
    const row = createElement('div', {}, { display: 'flex', flexDirection: 'column', gap: '2px' });

    const labelRow = createElement('div', {}, {
      display: 'flex',
      justifyContent: 'space-between',
      alignItems: 'center',
    });
    const label = createText('span', 'Strength', 'mono');
    label.style.color = OVERLAY.textMuted;
    label.style.fontSize = '10px';
    labelRow.appendChild(label);
    const valueLabel = createText('span', `${Math.round(initial * 100)}%`, 'mono');
    valueLabel.style.color = OVERLAY.text;
    valueLabel.style.fontSize = '10px';
    labelRow.appendChild(valueLabel);
    row.appendChild(labelRow);

    const controlRow = createElement('div', {}, { display: 'flex', gap: '6px', alignItems: 'center' });

    const slider = createElement('input', {
      type: 'range',
      min: '0',
      max: '1',
      step: '0.05',
      value: String(initial),
      'aria-label': 'Parallax strength',
      'aria-valuenow': String(initial),
      'aria-valuetext': `${Math.round(initial * 100)} percent`,
    }, {
      flex: '1',
      minWidth: '0',
      height: '4px',
      cursor: 'pointer',
      accentColor: OVERLAY.primary,
    }) as HTMLInputElement;

    const numeric = createElement('input', {
      type: 'number',
      min: '0',
      max: '100',
      step: '5',
      value: String(Math.round(initial * 100)),
      'aria-label': 'Parallax strength percent',
    }, {
      width: '40px',
      flexShrink: '0',
      padding: '2px 4px',
      background: 'rgba(255, 255, 255, 0.08)',
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusSm,
      color: OVERLAY.text,
      fontSize: OVERLAY.monoSize,
      fontFamily: OVERLAY.monoFamily,
      outline: 'none',
      boxSizing: 'border-box',
    }) as HTMLInputElement;

    const syncDisplay = (s: number): void => {
      valueLabel.textContent = `${Math.round(s * 100)}%`;
      slider.setAttribute('aria-valuenow', String(s));
      slider.setAttribute('aria-valuetext', `${Math.round(s * 100)} percent`);
    };

    // Live preview on drag (fixed / 3D update via CSS calc; scroll/JS on release).
    slider.addEventListener('input', () => {
      const s = clampStrength(parseFloat(slider.value));
      numeric.value = String(Math.round(s * 100));
      syncDisplay(s);
      this.preview.begin(block);
      this.preview.apply('--parallax-strength', String(s));
    });
    slider.addEventListener('change', () => {
      const s = clampStrength(parseFloat(slider.value));
      this.preview.commit();
      onParallaxUpdate?.(block, mechanism, s, scrollSource);
    });
    slider.addEventListener('keydown', (e) => e.stopPropagation());

    numeric.addEventListener('keydown', (e) => e.stopPropagation());
    numeric.addEventListener('change', () => {
      const s = clampStrength((parseFloat(numeric.value) || 0) / 100);
      slider.value = String(s);
      numeric.value = String(Math.round(s * 100));
      syncDisplay(s);
      onParallaxUpdate?.(block, mechanism, s, scrollSource);
    });

    controlRow.appendChild(slider);
    controlRow.appendChild(numeric);
    row.appendChild(controlRow);
    return row;
  }

  private buildParallaxAdvanced(block: HTMLElement, onCommit: ChangeCallback): HTMLDivElement {
    const section = createElement('div', {}, { display: 'flex', flexDirection: 'column', gap: '4px' });

    const toggle = createElement('div', { role: 'button', tabindex: '0', 'aria-expanded': 'false' }, {
      display: 'flex',
      alignItems: 'center',
      gap: '4px',
      cursor: 'pointer',
    });
    const arrow = createText('span', '▶', 'mono');
    arrow.style.fontSize = '8px';
    arrow.style.transition = 'transform 0.15s';
    toggle.appendChild(arrow);
    const advLabel = createText('span', 'Advanced', 'mono');
    advLabel.style.color = OVERLAY.textMuted;
    advLabel.style.fontSize = '10px';
    toggle.appendChild(advLabel);
    section.appendChild(toggle);

    const content = createElement('div', {}, {
      display: 'none',
      flexDirection: 'column',
      gap: '6px',
    });

    // Banner height — text input committed as a PropertyChange via onCommit.
    content.appendChild(this.buildTextInput(
      'Banner height',
      getComputedProperty(block, 'height'),
      (value) => {
        if (!value) return;
        const fromValue = getComputedProperty(block, 'height');
        this.preview.begin(block);
        this.preview.apply('height', value);
        this.preview.commit();
        onCommit([{ property: 'height', fromValue, toValue: value }]);
      },
    ));

    // Background-size / zoom and position — reuse the select row pattern.
    content.appendChild(this.buildSelect(
      'background-size', block, ['auto', 'cover', 'contain', '100% 100%'], onCommit,
    ));
    content.appendChild(this.buildSelect(
      'background-position', block,
      ['center', 'top', 'bottom', 'left', 'right', 'top left', 'top right', 'bottom left', 'bottom right'],
      onCommit,
    ));

    const toggleAdvanced = (): void => {
      const open = content.style.display !== 'none';
      content.style.display = open ? 'none' : 'flex';
      arrow.style.transform = open ? '' : 'rotate(90deg)';
      toggle.setAttribute('aria-expanded', open ? 'false' : 'true');
    };
    toggle.addEventListener('click', toggleAdvanced);
    toggle.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggleAdvanced(); }
    });
    toggle.addEventListener('focus', () => { toggle.style.outline = `2px solid ${OVERLAY.primary}`; });
    toggle.addEventListener('blur', () => { toggle.style.outline = ''; });

    section.appendChild(content);
    return section;
  }

  private buildTextInput(
    label: string,
    value: string,
    onChange: (value: string) => void,
    options?: { filePicker?: boolean },
  ): HTMLDivElement {
    const row = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      gap: '4px',
    });

    const labelEl = createText('div', label, 'mono');
    labelEl.style.color = OVERLAY.textMuted;
    labelEl.style.fontSize = '10px';
    row.appendChild(labelEl);

    const inputRow = createElement('div', {}, {
      display: 'flex',
      gap: '4px',
      alignItems: 'center',
    });

    const input = createElement('input', { type: 'text', value, placeholder: label }, {
      flex: '1',
      minWidth: '0',
      padding: '4px 6px',
      background: 'rgba(255, 255, 255, 0.08)',
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusSm,
      color: OVERLAY.text,
      fontSize: OVERLAY.monoSize,
      fontFamily: OVERLAY.monoFamily,
      outline: 'none',
      boxSizing: 'border-box',
    }) as HTMLInputElement;

    input.addEventListener('focus', () => {
      input.style.borderColor = OVERLAY.primary;
    });
    input.addEventListener('blur', () => {
      input.style.borderColor = OVERLAY.border;
    });
    input.addEventListener('keydown', (e) => {
      e.stopPropagation();
      if (e.key === 'Enter') {
        onChange(input.value);
        input.blur();
      }
    });
    input.addEventListener('change', () => {
      onChange(input.value);
    });

    inputRow.appendChild(input);

    if (options?.filePicker) {
      const browseBtn = createElement('button', {}, {
        padding: '4px 8px',
        fontSize: '10px',
        flexShrink: '0',
        whiteSpace: 'nowrap',
        border: `1px solid ${OVERLAY.border}`,
        borderRadius: OVERLAY.radiusSm,
        background: 'rgba(255, 255, 255, 0.08)',
        color: OVERLAY.textMuted,
        cursor: 'pointer',
        fontFamily: OVERLAY.fontFamily,
      }) as HTMLButtonElement;
      browseBtn.textContent = 'Browse';
      browseBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        e.preventDefault();
        this.openFilePicker((dataUrl) => {
          input.value = dataUrl;
          onChange(dataUrl);
        });
      });
      browseBtn.addEventListener('mousedown', (e) => e.stopPropagation());
      browseBtn.addEventListener('pointerdown', (e) => e.stopPropagation());
      inputRow.appendChild(browseBtn);
    }

    row.appendChild(inputRow);
    return row;
  }

  /** Last file handle — browser uses its parent directory as startIn for the next pick. */
  private static lastFileHandle: FileSystemFileHandle | null = null;

  private async openFilePicker(onSelect: (dataUrl: string) => void): Promise<void> {
    // Try File System Access API first (remembers directory per project)
    if ('showOpenFilePicker' in window) {
      try {
        const opts: OpenFilePickerOptions = {
          types: [
            {
              description: 'Images',
              accept: { 'image/*': ['.png', '.jpg', '.jpeg', '.gif', '.svg', '.webp', '.avif', '.ico'] },
            },
            {
              description: 'Videos',
              accept: { 'video/*': ['.mp4', '.webm', '.ogg', '.mov'] },
            },
          ],
          multiple: false,
        };
        // Start in the same folder as the last picked file
        if (MediaEditor.lastFileHandle) {
          (opts as any).startIn = MediaEditor.lastFileHandle;
        }
        const [handle] = await window.showOpenFilePicker!(opts);
        MediaEditor.lastFileHandle = handle;
        // Persist handle to IndexedDB so it survives page reloads
        MediaEditor.persistHandle(handle);
        const file = await handle.getFile();
        this.readFileAsDataUrl(file, onSelect);
        return;
      } catch {
        // User cancelled or API not available — fall through
        return;
      }
    }

    // Fallback: detached file input
    const fileInput = document.createElement('input');
    fileInput.type = 'file';
    fileInput.accept = 'image/*,video/*';

    fileInput.addEventListener('change', () => {
      const file = fileInput.files?.[0];
      if (!file) return;
      this.readFileAsDataUrl(file, onSelect);
    });

    fileInput.click();
  }

  /** Persist the last file handle to IndexedDB (keyed by origin). */
  private static persistHandle(handle: FileSystemFileHandle): void {
    const dbReq = indexedDB.open('nco-web-editor-media', 1);
    dbReq.onupgradeneeded = () => {
      const db = dbReq.result;
      if (!db.objectStoreNames.contains('handles')) {
        db.createObjectStore('handles');
      }
    };
    dbReq.onsuccess = () => {
      const db = dbReq.result;
      const tx = db.transaction('handles', 'readwrite');
      tx.objectStore('handles').put(handle, 'lastFileHandle');
    };
  }

  /** Restore the last file handle from IndexedDB on first use. */
  static restoreHandle(): void {
    const dbReq = indexedDB.open('nco-web-editor-media', 1);
    dbReq.onupgradeneeded = () => {
      const db = dbReq.result;
      if (!db.objectStoreNames.contains('handles')) {
        db.createObjectStore('handles');
      }
    };
    dbReq.onsuccess = () => {
      const db = dbReq.result;
      const tx = db.transaction('handles', 'readonly');
      const getReq = tx.objectStore('handles').get('lastFileHandle');
      getReq.onsuccess = () => {
        if (getReq.result) {
          MediaEditor.lastFileHandle = getReq.result as FileSystemFileHandle;
        }
      };
    };
  }

  private readFileAsDataUrl(file: File, onSelect: (dataUrl: string) => void): void {
    const reader = new FileReader();
    reader.onload = () => {
      onSelect(reader.result as string);
    };
    reader.readAsDataURL(file);
  }

  private buildSelect(
    property: string,
    element: Element,
    options: string[],
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    const currentValue = getComputedProperty(element, property);

    const row = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      gap: '4px',
    });

    const label = createText('div', property, 'mono');
    label.style.color = OVERLAY.textMuted;
    label.style.fontSize = '10px';
    row.appendChild(label);

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

    for (const opt of options) {
      const option = createElement('option', { value: opt }, {
        background: '#1a1a2e',
        color: OVERLAY.text,
      }) as HTMLOptionElement;
      option.textContent = opt;
      if (this.normalizeValue(currentValue) === this.normalizeValue(opt)) {
        option.selected = true;
      }
      select.appendChild(option);
    }

    select.addEventListener('change', () => {
      const newValue = select.value;
      this.preview.begin(element as HTMLElement);
      this.preview.apply(property, newValue);
      this.preview.commit();
      onCommit([{
        property,
        fromValue: currentValue,
        toValue: newValue,
      }]);
    });

    row.appendChild(select);
    return row;
  }

  private normalizeValue(val: string): string {
    return val.replace(/\s+/g, ' ').trim().toLowerCase();
  }
}
