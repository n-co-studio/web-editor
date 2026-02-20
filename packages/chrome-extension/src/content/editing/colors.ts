import type { PropertyChange } from '@frontend-editor/shared';
import { createElement, createText, createButton } from '../../shared/ui-utils';
import { getComputedProperty } from '../../shared/dom-utils';
import { OVERLAY, TOOLBAR_WIDTH } from '../../shared/constants';
import type { TokenStore } from '../tokens/store';
import type { SnappingEngine } from '../tokens/snapping';
import type { PreviewManager } from './preview';

type ChangeCallback = (changes: PropertyChange[]) => void;

/**
 * Color editing panel — token swatch grid only.
 * Renders as a positioned floating panel anchored to the toolbar.
 */
export class ColorEditor {
  private container: HTMLDivElement | null = null;
  private closeCb: (() => void) | null = null;

  constructor(
    private readonly tokenStore: TokenStore,
    private readonly snapping: SnappingEngine,
    private readonly preview: PreviewManager,
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
      border: `1px solid ${OVERLAY.border}`,
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

    // Token swatches
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
      const noTokens = createText('div', 'No color tokens loaded', 'mono');
      noTokens.style.color = OVERLAY.textMuted;
      noTokens.style.fontSize = '10px';
      body.appendChild(noTokens);
    }

    container.appendChild(body);
    this.container = container;
    return container;
  }

  /** Reposition the floating panel relative to a new toolbar anchor. */
  reposition(anchorPos: { x: number; y: number }): void {
    if (!this.container) return;
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
  }
}
