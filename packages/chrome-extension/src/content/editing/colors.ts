import type { PropertyChange } from '@nco-studio/shared';
import { createElement, createText, createButton, makeDraggable } from '../../shared/ui-utils';
import { getComputedProperty } from '../../shared/dom-utils';
import { OVERLAY, TOOLBAR_WIDTH } from '../../shared/constants';
import type { TokenStore } from '../tokens/store';
import type { SnappingEngine } from '../tokens/snapping';
import type { PageValueStore, InferredOption } from '../tokens/page-value-store';
import type { PreviewManager } from './preview';
import { buildColorInput } from './color-input';

type ChangeCallback = (changes: PropertyChange[]) => void;

/**
 * Label shown on page-inference option groups / optgroups when a token source
 * errored (feature-011 § Edge Cases — "degraded design system"). A trailing
 * marker so the operator sees these may be their own design variables surfaced
 * because a token source failed to load, not ordinary observed reality.
 */
export const PAGE_GROUP_LABEL = 'On this page';
export const PAGE_GROUP_LABEL_DEGRADED = 'On this page ⚠'; // ⚠

/** Optgroup label for a page-inference `<optgroup>`, degraded-aware. */
export function pageGroupLabel(degraded = false): string {
  return degraded ? PAGE_GROUP_LABEL_DEGRADED : PAGE_GROUP_LABEL;
}

/**
 * "On this page" heading for a page-inferred (feature-011) option group. Styled
 * distinctly from token headings so provenance is always legible. When
 * `degraded` is true, a muted note is appended flagging a possible failed token
 * source (feature-011 § Edge Cases).
 */
export function pageValueHeading(degraded = false): HTMLDivElement {
  const wrap = createElement('div', {}, {
    display: 'flex',
    flexDirection: 'column',
    gap: '2px',
  });
  const el = createText('div', PAGE_GROUP_LABEL, 'mono');
  el.style.color = OVERLAY.textMuted;
  el.style.fontSize = '10px';
  el.style.textTransform = 'uppercase';
  el.style.letterSpacing = '0.5px';
  wrap.appendChild(el);
  if (degraded) wrap.appendChild(buildDegradedNote());
  return wrap;
}

/** Muted advisory shown when a token source errored (feature-011 § Edge Cases). */
export function buildDegradedNote(): HTMLDivElement {
  const note = createText('div', '⚠ A token source may have failed to load — these may be your design system.', 'mono') as HTMLDivElement;
  note.style.color = OVERLAY.warning;
  note.style.fontSize = '9px';
  note.style.lineHeight = '1.3';
  note.style.textTransform = 'none';
  note.style.letterSpacing = '0';
  return note;
}

/**
 * Render an "On this page" swatch group of page-inferred color values
 * (feature-011). Swatches use a dashed "observed" border — deliberately
 * distinct from the token swatch treatment (2px solid) — so the operator can
 * always tell a page value from a design token. Selecting a swatch commits a
 * `PropertyChange` with `fromPageInference: true` and no `toToken`.
 */
export function buildPageValueColorGroup(
  property: string,
  options: readonly InferredOption[],
  element: Element,
  preview: PreviewManager,
  onCommit: ChangeCallback,
  degraded = false,
): HTMLDivElement {
  const group = createElement('div', {}, {
    display: 'flex',
    flexDirection: 'column',
    gap: '6px',
  });
  group.appendChild(pageValueHeading(degraded));

  const grid = createElement('div', {}, {
    display: 'grid',
    gridTemplateColumns: 'repeat(6, 1fr)',
    gap: '4px',
    pointerEvents: 'auto',
  });

  for (const opt of options) {
    const title = `${opt.value}${opt.label ? ` · ${opt.label}` : ''} · on this page`;
    const swatch = createElement('div', { role: 'button', tabindex: '0', title }, {
      width: '22px',
      height: '22px',
      borderRadius: OVERLAY.radiusSm,
      background: opt.value,
      // Dashed "observed" affordance — never the token swatch treatment.
      border: `1px dashed ${OVERLAY.textMuted}`,
      boxSizing: 'border-box',
      cursor: 'pointer',
    });

    const pick = (): void => {
      const fromValue = getComputedProperty(element, property);
      preview.begin(element as HTMLElement);
      preview.apply(property, opt.value);
      preview.commit();
      onCommit([{ property, fromValue, toValue: opt.value, fromPageInference: true }]);
    };
    swatch.addEventListener('click', pick);
    swatch.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault();
        pick();
      }
    });
    swatch.addEventListener('mouseenter', () => { swatch.style.borderColor = OVERLAY.primary; });
    swatch.addEventListener('mouseleave', () => { swatch.style.borderColor = OVERLAY.textMuted; });
    grid.appendChild(swatch);
  }

  group.appendChild(grid);
  return group;
}

/**
 * Color editing panel — token swatch grid only.
 * Renders as a positioned floating panel anchored to the toolbar.
 */
export class ColorEditor {
  private container: HTMLDivElement | null = null;
  private closeCb: (() => void) | null = null;
  private userDragged = false;

  constructor(
    private readonly tokenStore: TokenStore,
    private readonly snapping: SnappingEngine,
    private readonly preview: PreviewManager,
    private readonly pageValueStore: PageValueStore,
  ) {}

  onClose(cb: () => void): void {
    this.closeCb = cb;
  }

  /**
   * Render color controls for the selected element and property.
   * Returns the container element to append to the shadow root.
   */
  render(
    element: Element,
    property: string,
    anchorPos: { x: number; y: number },
    onCommit: ChangeCallback,
  ): HTMLDivElement {
    this.cleanup();

    const currentValue = getComputedProperty(element, property);

    // Floating panel wrapper — positioned relative to toolbar
    const panelLeft = Math.min(
      anchorPos.x + TOOLBAR_WIDTH + 8,
      window.innerWidth - 248,
    );
    const panelTop = Math.max(8, anchorPos.y);

    const container = createElement('div', { role: 'dialog', 'aria-label': 'Color editor' }, {
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
    const title = createText('span', 'Colors', 'heading');
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

    // Label
    const label = createText('div', property, 'mono');
    label.style.color = OVERLAY.textMuted;
    body.appendChild(label);

    // Current color preview
    const previewRow = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '8px',
    });

    const colorChip = createElement('div', {}, {
      width: '24px',
      height: '24px',
      borderRadius: OVERLAY.radiusSm,
      background: currentValue,
      border: `1px solid ${OVERLAY.swatchBorder}`,
      flexShrink: '0',
    });
    previewRow.appendChild(colorChip);

    const valueText = createText('span', currentValue, 'mono');
    valueText.style.flex = '1';
    valueText.style.minWidth = '0';
    valueText.style.overflow = 'hidden';
    valueText.style.textOverflow = 'ellipsis';
    valueText.style.whiteSpace = 'nowrap';
    previewRow.appendChild(valueText);
    body.appendChild(previewRow);

    const reflectPick = (changes: PropertyChange[]): void => {
      const last = changes[changes.length - 1];
      if (last) {
        colorChip.style.background = last.toValue;
        valueText.textContent = last.toValue;
      }
      onCommit(changes);
    };

    // Token swatches, when the project has any.
    if (this.tokenStore.loaded) {
      const swatches = this.snapping.renderColorSwatches(
        (token) => {
          this.preview.begin(element as HTMLElement);
          this.preview.apply(property, token.value);
          this.preview.commit();
          colorChip.style.background = token.value;
          valueText.textContent = `${token.value} (${token.name})`;
          onCommit([
            {
              property,
              fromValue: currentValue,
              toValue: token.value,
              toToken: token.name,
            },
          ]);
        },
      );
      body.appendChild(swatches);
    } else {
      // Page-inferred colours ("On this page") sit above the freeform floor
      // when the harvester found any (feature-011). Only offered when there are
      // no tokens — with tokens, the swatches are the curated answer.
      const pageOptions = this.pageValueStore.getForProperty(property);
      if (pageOptions.length > 0) {
        body.appendChild(
          buildPageValueColorGroup(property, pageOptions, element, this.preview, reflectPick, this.tokenStore.hasDegradedDesignSystem()),
        );
      }
    }

    // Freeform floor — raw CSS, no toToken (feature-003). UNCONDITIONAL.
    //
    // This used to live inside the else above, under a comment claiming the
    // escape hatch is never suppressed. It was: `tokenStore.loaded` is true
    // when the project has tokens of ANY category, so a project with only
    // spacing or type tokens rendered an empty colour-swatch grid and no
    // picker at all — the panel had nothing clickable in it. Even with real
    // colour tokens, a palette is a shortlist and picking a colour outside it
    // has to stay possible.
    body.appendChild(
      buildColorInput(property, currentValue, element, this.preview, reflectPick),
    );

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
}
