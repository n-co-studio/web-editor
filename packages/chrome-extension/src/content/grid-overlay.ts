import { createElement } from '../shared/ui-utils';
import { OVERLAY } from '../shared/constants';
import type { TokenStore } from './tokens/store';
import type { GridSettings } from './grid-settings';
import { DEFAULT_GRID_SETTINGS } from './grid-settings';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function hexToRgba(hex: string, alpha: number): string {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return `rgba(${r}, ${g}, ${b}, ${Math.min(1, Math.max(0, alpha))})`;
}

/**
 * Full-viewport grid overlay using spacing tokens.
 * Renders vertical column lines and horizontal baseline lines
 * at intervals derived from the project's design tokens.
 * Uses CSS repeating-linear-gradient for performance.
 */
export class GridOverlay {
  private container: HTMLDivElement | null = null;
  private visible = false;
  private resizeObserver: ResizeObserver | null = null;
  private externalSettings: GridSettings | null = null;

  constructor(
    private readonly shadow: ShadowRoot,
    private readonly tokenStore: TokenStore,
  ) {}

  show(): void {
    if (this.visible) return;
    this.visible = true;
    this.render();

    this.resizeObserver = new ResizeObserver(() => {
      if (this.visible) this.render();
    });
    this.resizeObserver.observe(document.documentElement);
  }

  hide(): void {
    this.visible = false;
    this.container?.remove();
    this.container = null;
    this.resizeObserver?.disconnect();
    this.resizeObserver = null;
  }

  refresh(): void {
    if (!this.visible) return;
    this.render();
  }

  isVisible(): boolean {
    return this.visible;
  }

  toggle(): boolean {
    if (this.visible) {
      this.hide();
      return false;
    } else {
      this.show();
      return true;
    }
  }

  /**
   * Check if grid can be shown.
   * Returns null if OK, or a reason string if blocked.
   * When external settings are set, grid is never blocked.
   */
  getBlockReason(): string | null {
    if (this.externalSettings) return null;
    if (!this.tokenStore.loaded) {
      return 'No design tokens loaded';
    }
    const spacingTokens = this.tokenStore.getForCategory('spacing');
    if (spacingTokens.length === 0) {
      return 'No spacing tokens available';
    }
    return null;
  }

  /** Apply external settings that override token-derived defaults. */
  applySettings(settings: GridSettings): void {
    this.externalSettings = { ...settings };
    if (this.visible) this.render();
  }

  /** Get the current effective settings (for initializing the settings panel). */
  getEffectiveSettings(): GridSettings {
    if (this.externalSettings) return { ...this.externalSettings };

    const spacing = this.resolveGridSpacing();
    return {
      baseSpacing: spacing?.base ?? DEFAULT_GRID_SETTINGS.baseSpacing,
      majorSpacing: spacing?.major ?? DEFAULT_GRID_SETTINGS.majorSpacing,
      opacity: DEFAULT_GRID_SETTINGS.opacity,
      lineColor: DEFAULT_GRID_SETTINGS.lineColor,
      showHorizontal: DEFAULT_GRID_SETTINGS.showHorizontal,
      showVertical: DEFAULT_GRID_SETTINGS.showVertical,
    };
  }

  // -----------------------------------------------------------------------
  // Rendering
  // -----------------------------------------------------------------------

  private render(): void {
    this.container?.remove();

    const settings = this.getEffectiveSettings();
    const { baseSpacing, majorSpacing, opacity, lineColor, showHorizontal, showVertical } = settings;

    if (baseSpacing <= 0) return;
    if (!showHorizontal && !showVertical) return;

    const baseLineColor = hexToRgba(lineColor, opacity * 0.8);
    const majorLineColor = hexToRgba(lineColor, opacity * 1.7);

    const container = createElement('div', { 'aria-hidden': 'true' }, {
      position: 'fixed',
      top: '0',
      left: '0',
      width: '100vw',
      height: '100vh',
      pointerEvents: 'none',
      zIndex: '50',
      overflow: 'hidden',
    });

    const gradients: string[] = [];
    const sizes: string[] = [];

    if (showVertical) {
      if (majorSpacing > 0) {
        gradients.push(
          `repeating-linear-gradient(to right, ${majorLineColor} 0px, ${majorLineColor} 1px, transparent 1px, transparent ${majorSpacing}px)`,
        );
        sizes.push(`${majorSpacing}px 100%`);
      }
      gradients.push(
        `repeating-linear-gradient(to right, ${baseLineColor} 0px, ${baseLineColor} 1px, transparent 1px, transparent ${baseSpacing}px)`,
      );
      sizes.push(`${baseSpacing}px 100%`);
    }

    if (showHorizontal) {
      if (majorSpacing > 0) {
        gradients.push(
          `repeating-linear-gradient(to bottom, ${majorLineColor} 0px, ${majorLineColor} 1px, transparent 1px, transparent ${majorSpacing}px)`,
        );
        sizes.push(`100% ${majorSpacing}px`);
      }
      gradients.push(
        `repeating-linear-gradient(to bottom, ${baseLineColor} 0px, ${baseLineColor} 1px, transparent 1px, transparent ${baseSpacing}px)`,
      );
      sizes.push(`100% ${baseSpacing}px`);
    }

    container.style.backgroundImage = gradients.join(', ');
    container.style.backgroundSize = sizes.join(', ');

    // Label showing the grid spacing
    const label = createElement('div', {}, {
      position: 'absolute',
      bottom: '8px',
      right: '8px',
      background: OVERLAY.bg,
      color: OVERLAY.textMuted,
      fontFamily: OVERLAY.monoFamily,
      fontSize: '9px',
      padding: '2px 6px',
      borderRadius: OVERLAY.radiusSm,
      border: `1px solid ${OVERLAY.border}`,
      opacity: '0.7',
    });
    label.textContent = majorSpacing > 0
      ? `Grid: ${baseSpacing}px / ${majorSpacing}px`
      : `Grid: ${baseSpacing}px`;
    container.appendChild(label);

    this.container = container;
    this.shadow.appendChild(container);
  }

  // -----------------------------------------------------------------------
  // Token resolution
  // -----------------------------------------------------------------------

  /**
   * Resolve grid spacing from spacing tokens.
   * - Base = smallest spacing token (commonly 4px)
   * - Major = nearest token to 8× base that's a multiple of base
   */
  private resolveGridSpacing(): { base: number; major: number | null } | null {
    const spacingTokens = this.tokenStore.getForCategory('spacing');
    if (spacingTokens.length === 0) return null;

    const values = spacingTokens
      .map((t) => parseFloat(t.value))
      .filter((v) => !isNaN(v) && v > 0)
      .sort((a, b) => a - b);

    if (values.length === 0) return null;

    const base = values[0];

    // Find a major interval: prefer something close to 8× base that's a multiple
    let major: number | null = null;
    const candidates = values.filter((v) => v > base && v % base === 0 && v >= base * 4);
    if (candidates.length > 0) {
      const idealMajor = base * 8;
      major = candidates.reduce((best, v) =>
        Math.abs(v - idealMajor) < Math.abs(best - idealMajor) ? v : best
      );
    }

    return { base, major };
  }
}
