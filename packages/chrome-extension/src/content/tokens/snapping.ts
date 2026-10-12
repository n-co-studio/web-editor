import type { DesignToken } from '@nco-studio/shared';
import { createElement } from '../../shared/ui-utils';
import { OVERLAY, SNAP_EASE_MS } from '../../shared/constants';
import { isColorValue } from '../editing/color-input';
import type { TokenStore } from './store';

export interface SnapResult {
  readonly snappedValue: number;
  readonly token: DesignToken | null;
  readonly isCustom: boolean;
}

/**
 * Constrains editing values to design token stops.
 * Renders token rulers on drag handles and provides
 * snap-on-release behavior.
 */
export class SnappingEngine {
  constructor(private readonly store: TokenStore) {}

  /**
   * Find the two nearest tokens to a given numeric value for a CSS property.
   * Returns them sorted by distance (closest first).
   */
  getNearestTokens(
    property: string,
    value: number,
  ): Array<{ token: DesignToken; distance: number; numericValue: number }> {
    const candidates = this.store.getForProperty(property);
    const withDistance = candidates
      .map((token) => {
        const num = parseFloat(token.value);
        if (isNaN(num)) return null;
        return { token, distance: Math.abs(num - value), numericValue: num };
      })
      .filter((x): x is NonNullable<typeof x> => x !== null)
      .sort((a, b) => a.distance - b.distance);

    return withDistance.slice(0, 2);
  }

  /** Snap a value to the nearest token stop. */
  snap(property: string, value: number): SnapResult {
    if (!this.store.loaded) {
      return { snappedValue: value, token: null, isCustom: true };
    }

    const nearest = this.getNearestTokens(property, value);
    if (nearest.length === 0) {
      return { snappedValue: value, token: null, isCustom: true };
    }

    const closest = nearest[0];
    // Snap threshold: within 3px of a token stop
    if (closest.distance <= 3) {
      return {
        snappedValue: closest.numericValue,
        token: closest.token,
        isCustom: false,
      };
    }

    return { snappedValue: value, token: null, isCustom: true };
  }

  // -----------------------------------------------------------------------
  // Token ruler rendering
  // -----------------------------------------------------------------------

  /**
   * Render a token ruler — a linear track with tick marks at token stops.
   * Shows only the two nearest labels to the current value to prevent overlap.
   */
  renderRuler(
    shadow: ShadowRoot,
    axis: 'x' | 'y',
    anchorRect: DOMRect,
    property: string,
    currentValue: number,
  ): HTMLDivElement {
    const candidates = this.store
      .getForProperty(property)
      .map((t) => ({ token: t, num: parseFloat(t.value) }))
      .filter((x) => !isNaN(x.num))
      .sort((a, b) => a.num - b.num);

    if (candidates.length === 0) {
      return createElement('div', {}, { display: 'none' });
    }

    const minVal = candidates[0].num;
    const maxVal = candidates[candidates.length - 1].num;
    const range = maxVal - minVal || 1;

    // Ruler track
    const isHorizontal = axis === 'x';
    const trackLength = 120;

    const ruler = createElement('div', {}, {
      position: 'fixed',
      left: isHorizontal ? `${anchorRect.left}px` : `${anchorRect.right + 8}px`,
      top: isHorizontal ? `${anchorRect.bottom + 8}px` : `${anchorRect.top}px`,
      width: isHorizontal ? `${trackLength}px` : '20px',
      height: isHorizontal ? '20px' : `${trackLength}px`,
      pointerEvents: 'none',
      zIndex: '50',
    });

    // Track line
    const track = createElement('div', {}, {
      position: 'absolute',
      background: OVERLAY.border,
      borderRadius: '1px',
      ...(isHorizontal
        ? { left: '0', right: '0', top: '9px', height: '2px' }
        : { top: '0', bottom: '0', left: '9px', width: '2px' }),
    });
    ruler.appendChild(track);

    // Find two nearest for label display
    const nearest = this.getNearestTokens(property, currentValue);
    const nearestNames = new Set(nearest.map((n) => n.token.name));

    // Tick marks for each token
    for (const { token, num } of candidates) {
      const ratio = (num - minVal) / range;
      const offset = ratio * (trackLength - 4);

      const tick = createElement('div', {}, {
        position: 'absolute',
        background: OVERLAY.textMuted,
        borderRadius: '50%',
        width: '4px',
        height: '4px',
        ...(isHorizontal
          ? { left: `${offset}px`, top: '8px' }
          : { top: `${offset}px`, left: '8px' }),
      });

      // Highlight snapped tick
      if (Math.abs(num - currentValue) <= 3) {
        tick.style.background = OVERLAY.success;
        tick.style.width = '6px';
        tick.style.height = '6px';
        tick.style.top = isHorizontal ? '7px' : `${offset}px`;
        tick.style.left = isHorizontal ? `${offset}px` : '7px';
      }

      ruler.appendChild(tick);

      // Label — only show for two nearest tokens
      if (nearestNames.has(token.name)) {
        const label = createElement('div', {}, {
          position: 'absolute',
          fontFamily: OVERLAY.monoFamily,
          fontSize: '9px',
          color: OVERLAY.textMuted,
          whiteSpace: 'nowrap',
          ...(isHorizontal
            ? { left: `${offset}px`, top: '14px', transform: 'translateX(-50%)' }
            : { top: `${offset}px`, left: '16px' }),
        });
        label.textContent = token.name;
        ruler.appendChild(label);
      }
    }

    shadow.appendChild(ruler);
    return ruler;
  }

  // -----------------------------------------------------------------------
  // Color swatches
  // -----------------------------------------------------------------------

  /**
   * Render a 5-column swatch grid of color tokens.
   * Each swatch shows the color with a tooltip of name + hex.
   */
  renderColorSwatches(
    onSelect: (token: DesignToken) => void,
  ): HTMLDivElement {
    // Filter to values the browser will actually accept as a colour.
    //
    // `category` is assigned upstream and is not always right: an easing token
    // (`ease-link: cubic-bezier(0, 0.56, 0.26, 0.88)`) was arriving in the
    // colours category and rendering as a swatch with no visible fill. Clicking
    // it looked like a dead control — `style.setProperty` silently discards an
    // invalid value — but it still queued a diff, so a bogus change reached the
    // agent. Validating here means a mis-categorised token is dropped from the
    // grid rather than becoming an invisible trap.
    const colors = this.store
      .getForCategory('colors')
      .filter((token) => isColorValue(token.value));

    const grid = createElement('div', {}, {
      display: 'grid',
      gridTemplateColumns: 'repeat(5, 1fr)',
      gap: '4px',
      padding: '8px',
      pointerEvents: 'auto',
    });

    for (const token of colors) {
      const swatch = createElement('div', { title: `${token.name}: ${token.value}` }, {
        width: '24px',
        height: '24px',
        borderRadius: OVERLAY.radiusSm,
        background: token.value,
        border: `2px solid ${OVERLAY.swatchBorder}`,
        cursor: 'pointer',
      });

      swatch.addEventListener('click', () => onSelect(token));

      swatch.addEventListener('mouseenter', () => {
        swatch.style.borderColor = OVERLAY.primary;
        swatch.style.transform = 'scale(1.15)';
      });
      swatch.addEventListener('mouseleave', () => {
        swatch.style.borderColor = 'rgba(255, 255, 255, 0.3)';
        swatch.style.transform = '';
      });

      grid.appendChild(swatch);
    }

    return grid;
  }

  /** Get the snap ease duration for CSS transitions. */
  get snapDuration(): number {
    return SNAP_EASE_MS;
  }
}
