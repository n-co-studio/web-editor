import type { PropertyChange } from '@nco-studio/shared';
import { createElement, createText, createButton, makeDraggable } from '../../shared/ui-utils';
import { getComputedProperty } from '../../shared/dom-utils';
import { OVERLAY, TOOLBAR_WIDTH } from '../../shared/constants';
import type { TokenStore } from '../tokens/store';
import type { PageValueStore, InferredOption } from '../tokens/page-value-store';
import type { PreviewManager } from './preview';
import { extractUnit } from './token-select';
import { buildColorInput } from './color-input';
import { buildPageValueColorGroup, pageValueHeading, pageGroupLabel } from './colors';

type ChangeCallback = (changes: PropertyChange[]) => void;

/** A plain (non-token, non-page) value option in the freeform fallback list. */
interface ValueOption {
  readonly name: string;
  readonly value: string;
}

// Freeform fallback option lists (feature-003) — offered when no tokens exist,
// beneath any page-inferred "On this page" group (feature-011).
const FONT_SIZE_DEFAULTS: ValueOption[] = [
  '10px', '11px', '12px', '13px', '14px', '16px', '18px', '20px', '24px',
  '28px', '32px', '36px', '40px', '48px', '56px', '64px', '72px',
].map((v) => ({ name: v, value: v }));

const FONT_FAMILY_DEFAULTS: ValueOption[] = [
  { name: 'sans-serif', value: 'sans-serif' },
  { name: 'serif', value: 'serif' },
  { name: 'monospace', value: 'monospace' },
  { name: 'system-ui', value: 'system-ui' },
];

const FONT_WEIGHT_DEFAULTS: ValueOption[] = [
  { name: 'normal', value: '400' },
  { name: 'medium', value: '500' },
  { name: 'semibold', value: '600' },
  { name: 'bold', value: '700' },
];

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
    private readonly pageValueStore: PageValueStore,
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
    return this.buildTypographyValueControl(
      element, 'font-size', FONT_SIZE_DEFAULTS, onCommit,
      (value) => ({ unit: extractUnit(value) }),
    );
  }

  private buildFontFamilyControl(
    element: Element,
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    return this.buildTypographyValueControl(
      element, 'font-family', FONT_FAMILY_DEFAULTS, onCommit,
    );
  }

  private buildFontWeightControl(
    element: Element,
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    return this.buildTypographyValueControl(
      element, 'font-weight', FONT_WEIGHT_DEFAULTS, onCommit,
    );
  }

  /**
   * Shared builder for the token-or-freeform typography selects (font-size,
   * font-family, font-weight). Token mode uses the token dropdown. When no
   * tokens exist, page-inferred values (feature-011) are offered in an "On this
   * page" optgroup above the feature-003 freeform defaults; selecting a page
   * value emits `fromPageInference: true` with no `toToken`.
   */
  private buildTypographyValueControl(
    element: Element,
    property: string,
    fallback: readonly ValueOption[],
    onCommit: ChangeCallback,
    extra: (value: string) => Partial<PropertyChange> = () => ({}),
  ): HTMLDivElement {
    const tokens = this.tokenStore.getForProperty(property);
    const row = this.buildRow(property);
    const currentValue = getComputedProperty(element, property);

    const apply = (newValue: string, provenance: { toToken?: string; fromPageInference?: true }): void => {
      this.preview.begin(element as HTMLElement);
      this.preview.apply(property, newValue);
      this.preview.commit();
      onCommit([{
        property,
        fromValue: currentValue,
        toValue: newValue,
        ...extra(newValue),
        ...provenance,
      }]);
    };

    if (tokens.length > 0) {
      const select = this.buildTokenSelect(tokens, currentValue, (newValue, token) => {
        apply(newValue, { toToken: token?.name });
      });
      row.appendChild(select);
      return row;
    }

    const pageOptions = this.pageValueStore.getForProperty(property);
    const select = this.buildFallbackSelect(pageOptions, fallback, currentValue, (newValue, fromPage) => {
      apply(newValue, fromPage ? { fromPageInference: true } : {});
    }, this.tokenStore.hasDegradedDesignSystem());
    row.appendChild(select);
    return row;
  }

  private buildLineHeightControl(
    element: Element,
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    const currentValue = getComputedProperty(element, 'line-height');

    // When no line-height tokens exist but the page harvest found line-heights,
    // offer them as an "On this page" select above the slider (feature-011).
    // The slider below remains as the freeform escape.
    const tokens = this.tokenStore.getForProperty('line-height');
    const pageOptions = tokens.length === 0 ? this.pageValueStore.getForProperty('line-height') : [];
    if (pageOptions.length > 0) {
      const column = createElement('div', {}, {
        display: 'flex',
        flexDirection: 'column',
        gap: '6px',
      });
      column.appendChild(pageValueHeading(this.tokenStore.hasDegradedDesignSystem()));
      const select = this.buildFallbackSelect(pageOptions, [], currentValue, (newValue, fromPage) => {
        this.preview.begin(element as HTMLElement);
        this.preview.apply('line-height', newValue);
        this.preview.commit();
        onCommit([{
          property: 'line-height',
          fromValue: currentValue,
          toValue: newValue,
          ...(fromPage ? { fromPageInference: true as const } : {}),
        }]);
      }, this.tokenStore.hasDegradedDesignSystem());
      const pageRow = this.buildRow('line-height');
      pageRow.appendChild(select);
      column.appendChild(pageRow);
      column.appendChild(this.buildLineHeightSlider(element, currentValue, onCommit));
      return column;
    }

    return this.buildLineHeightSlider(element, currentValue, onCommit);
  }

  /** The line-height ratio slider (the feature-003 freeform control). */
  private buildLineHeightSlider(
    element: Element,
    currentValue: string,
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    const row = this.buildRow('line-height');
    const currentNum = parseFloat(currentValue);

    const slider = createElement('input', {
      type: 'range',
      min: '0.8',
      max: '3',
      step: '0.1',
      value: String(isNaN(currentNum) ? 1.5 : currentNum / parseFloat(getComputedProperty(element, 'font-size'))),
    }, {
      flex: '1',
      // Chrome gives range inputs a content-based automatic minimum width of
      // roughly 129px, which flex:1 alone cannot shrink past. Combined with the
      // 66px label and the readout, the row's minimum exceeded the 218px
      // content box and the overflow was sheared off by the panel's
      // overflow:hidden — taking the readout with it.
      minWidth: '0',
      pointerEvents: 'auto',
      cursor: 'pointer',
    });

    const valueDisplay = createText('span', currentValue, 'mono');
    valueDisplay.style.width = '40px';
    // Without this the readout is the flex item that loses the fight for space.
    valueDisplay.style.flexShrink = '0';
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

    if (tokens.length === 0) {
      // No color tokens. Offer page-inferred colors ("On this page") above the
      // freeform floor when the harvester found any (feature-011); otherwise
      // fall straight through to freeform (feature-003). buildColorInput carries
      // its own live swatch, so no separate preview chip is added here.
      const pageOptions = this.pageValueStore.getForProperty('color');
      if (pageOptions.length > 0) {
        // Stack the "On this page" group above the freeform input in a column so
        // the single-row layout still reads cleanly.
        const column = createElement('div', {}, {
          display: 'flex',
          flexDirection: 'column',
          gap: '8px',
          flex: '1',
          minWidth: '0',
        });
        column.appendChild(buildPageValueColorGroup('color', pageOptions, element, this.preview, onCommit, this.tokenStore.hasDegradedDesignSystem()));
        column.appendChild(buildColorInput('color', currentValue, element, this.preview, onCommit));
        row.appendChild(column);
        return row;
      }
      // Freeform floor — raw CSS, no toToken (feature-003).
      row.appendChild(buildColorInput('color', currentValue, element, this.preview, onCommit));
      return row;
    }

    // Token mode — static preview chip + snap-to-token dropdown.
    // Colour uses the colour control, not the generic token <select>.
    //
    // The select listed everything `getForProperty('color')` returned, and the
    // store indexes by `cssProperties`, which upstream populates loosely —
    // so the colour dropdown offered `100 (fw-thin)`, `1 (z-base)`,
    // `1052px (container-max)` and `cubic-bezier(…) (ease-link)` alongside
    // actual colours. Picking one of those applied a value the CSSOM
    // discarded, while still queuing a change for the agent.
    //
    // buildColorInput filters the same token list through `isColorValue` and
    // presents what survives as swatches in its popover, so colour is picked
    // the same way here as in the Colors and Appearance panels.
    row.appendChild(
      buildColorInput('color', currentValue, element, this.preview, onCommit, tokens),
    );

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
    // CSS property names contain hyphens, which are legal soft-break
    // opportunities. At 10px mono "font-family" and "line-height" are just
    // wider than this 66px box, so without nowrap they broke mid-word into
    // "font-" / "family". Nowrap keeps them on one line; the label is a fixed
    // width the panel already accounts for, so nothing else moves.
    labelEl.style.whiteSpace = 'nowrap';
    row.appendChild(labelEl);

    return row;
  }

  private buildTokenSelect(
    tokens: Array<{ name: string; value: string }>,
    currentValue: string,
    onChange: (value: string, token?: { name: string; value: string }) => void,
  ): HTMLSelectElement {
    const select = createElement('select', {}, {
      background: OVERLAY.inputBg,
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

    // The select is deliberately shrinkable (flex:1 / minWidth:0) so it never
    // widens the panel, which means a long value — a font stack runs to several
    // hundred pixels — is clipped by the native control with no ellipsis and no
    // way to read it. Mirroring the selection into `title` keeps it
    // recoverable, and keeping it in sync on change stops the tooltip going
    // stale against the visible value.
    const syncTitle = (): void => {
      const opt = select.selectedOptions[0];
      select.title = opt ? opt.textContent ?? select.value : select.value;
    };
    syncTitle();

    select.addEventListener('change', () => {
      syncTitle();
      const token = tokens.find((t) => t.value === select.value);
      onChange(select.value, token);
    });

    return select;
  }

  /**
   * Build a no-token <select> that groups page-inferred values (feature-011)
   * under an "On this page" optgroup above the feature-003 freeform defaults.
   * The change handler reports whether the chosen value was page-inferred so the
   * caller can stamp `fromPageInference` (and never `toToken`).
   */
  private buildFallbackSelect(
    pageOptions: readonly InferredOption[],
    fallback: readonly ValueOption[],
    currentValue: string,
    onChange: (value: string, fromPageInference: boolean) => void,
    degraded = false,
  ): HTMLSelectElement {
    const select = createElement('select', {}, {
      background: OVERLAY.inputBg,
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

    const pageValues = new Set(pageOptions.map((o) => o.value));

    // Surface the current value up-front when it matches neither a page value
    // nor a fallback default, so the select always shows the live value.
    const hasMatch = pageValues.has(currentValue) || fallback.some((f) => f.value === currentValue);
    if (!hasMatch) {
      const opt = document.createElement('option');
      opt.value = currentValue;
      opt.textContent = currentValue;
      opt.selected = true;
      select.appendChild(opt);
    }

    if (pageOptions.length > 0) {
      const group = document.createElement('optgroup');
      group.label = pageGroupLabel(degraded);
      for (const o of pageOptions) {
        const opt = document.createElement('option');
        opt.value = o.value;
        opt.textContent = o.label ? `${o.value} · ${o.label}` : o.value;
        if (o.value === currentValue) opt.selected = true;
        group.appendChild(opt);
      }
      select.appendChild(group);
    }

    // Freeform defaults (feature-003). Skipped entirely when there are none
    // (e.g. line-height, whose freeform escape is the slider, not this select).
    if (fallback.length > 0) {
      const fallbackGroup = document.createElement('optgroup');
      fallbackGroup.label = pageOptions.length > 0 ? 'Common' : 'Values';
      for (const f of fallback) {
        const opt = document.createElement('option');
        opt.value = f.value;
        opt.textContent = f.name === f.value ? f.value : `${f.value} (${f.name})`;
        if (f.value === currentValue) opt.selected = true;
        fallbackGroup.appendChild(opt);
      }
      select.appendChild(fallbackGroup);
    }

    select.addEventListener('change', () => {
      onChange(select.value, pageValues.has(select.value));
    });

    return select;
  }

}
