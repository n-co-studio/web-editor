import { createElement } from '../../shared/ui-utils';
import { getTopElementAt, isElementVisible } from '../../shared/dom-utils';
import { OVERLAY } from '../../shared/constants';
import { createZoneOverlays } from '../editing/zone-overlays';

/**
 * Renders a highlight overlay on elements as the cursor moves.
 * Uses requestAnimationFrame gating to prevent layout thrashing.
 */
export class HoverHighlight {
  private overlay: HTMLDivElement;
  private tooltip: HTMLDivElement;
  private programmaticOverlay: HTMLDivElement;
  private programmaticTooltip: HTMLDivElement;
  private zoneOverlays: HTMLDivElement[] = [];
  private rafId: number | null = null;
  private active = false;
  private currentElement: Element | null = null;

  /** Callback invoked when an element is clicked during hover. */
  private clickHandler: ((el: Element) => void) | null = null;

  constructor(
    private readonly shadow: ShadowRoot,
    private readonly host: HTMLDivElement,
  ) {
    // Highlight overlay
    this.overlay = createElement('div', {}, {
      position: 'fixed',
      pointerEvents: 'none',
      border: `2px solid ${OVERLAY.primary}`,
      background: 'rgba(6, 182, 212, 0.08)',
      borderRadius: OVERLAY.radiusSm,
      transition: 'all 0.05s ease',
      display: 'none',
      zIndex: '1',
    });

    // Tag name tooltip
    this.tooltip = createElement('div', {}, {
      position: 'fixed',
      pointerEvents: 'none',
      background: OVERLAY.bgSubtle,
      color: OVERLAY.text,
      fontFamily: OVERLAY.monoFamily,
      fontSize: OVERLAY.monoSize,
      padding: '2px 6px',
      borderRadius: OVERLAY.radiusSm,
      whiteSpace: 'nowrap',
      display: 'none',
      zIndex: '2',
    });

    // Programmatic highlight (review panel click-to-highlight)
    this.programmaticOverlay = createElement('div', {}, {
      position: 'fixed',
      pointerEvents: 'none',
      border: `2px dashed ${OVERLAY.accent}`,
      background: 'rgba(251, 113, 133, 0.08)',
      borderRadius: OVERLAY.radiusSm,
      transition: 'all 0.15s ease',
      display: 'none',
      zIndex: '3',
    });

    this.programmaticTooltip = createElement('div', {}, {
      position: 'fixed',
      pointerEvents: 'none',
      background: 'rgba(251, 113, 133, 0.65)',
      color: '#fff',
      fontFamily: OVERLAY.monoFamily,
      fontSize: OVERLAY.monoSize,
      padding: '2px 6px',
      borderRadius: OVERLAY.radiusSm,
      whiteSpace: 'nowrap',
      display: 'none',
      zIndex: '4',
    });

    shadow.appendChild(this.overlay);
    shadow.appendChild(this.tooltip);
    shadow.appendChild(this.programmaticOverlay);
    shadow.appendChild(this.programmaticTooltip);
  }

  enable(): void {
    if (this.active) return;
    this.active = true;
    document.addEventListener('mousemove', this.handleMouseMove, true);
    document.addEventListener('click', this.handleClick, true);
  }

  disable(): void {
    this.active = false;
    document.removeEventListener('mousemove', this.handleMouseMove, true);
    document.removeEventListener('click', this.handleClick, true);
    if (this.rafId != null) {
      cancelAnimationFrame(this.rafId);
      this.rafId = null;
    }
    this.hideHighlight();
    this.currentElement = null;
  }

  onClick(handler: (el: Element) => void): void {
    this.clickHandler = handler;
  }

  getCurrentElement(): Element | null {
    return this.currentElement;
  }

  /** Show hover highlight on an element programmatically (e.g. from DOM inspector). */
  highlightElement(el: Element): void {
    this.showHighlight(el);
  }

  /** Clear a programmatic hover highlight. */
  unhighlightElement(): void {
    this.hideHighlight();
  }

  /** Refresh the hover highlight to match the current element's position. */
  refreshHighlight(): void {
    if (!this.currentElement || !this.active) return;
    this.showHighlight(this.currentElement);
  }

  // -----------------------------------------------------------------------
  // Event handlers
  // -----------------------------------------------------------------------

  private handleMouseMove = (e: MouseEvent): void => {
    if (this.rafId != null) return; // rAF gate — one update per frame
    this.rafId = requestAnimationFrame(() => {
      this.rafId = null;
      if (!this.active) return;

      const target = getTopElementAt(e.clientX, e.clientY, this.host);
      if (target && target !== this.currentElement && isElementVisible(target)) {
        this.currentElement = target;
        this.showHighlight(target);
      } else if (!target) {
        this.currentElement = null;
        this.hideHighlight();
      }
    });
  };

  private handleClick = (e: MouseEvent): void => {
    if (!this.active) return;

    // Alt+click — pass through to host page
    if (e.altKey) return;

    // Don't intercept clicks on overlay UI (panel, handles, etc.)
    // In shadow DOM, e.target is retargeted to the host element at the
    // document scope. So if target === host, the click is on our UI.
    if (e.target === this.host) return;

    const target = getTopElementAt(e.clientX, e.clientY, this.host);
    if (!target) return;

    e.preventDefault();
    e.stopPropagation();
    this.clickHandler?.(target);
  };

  // -----------------------------------------------------------------------
  // Programmatic highlight (for review panel click-to-highlight)
  // -----------------------------------------------------------------------

  /** Highlight an element programmatically (e.g. from review panel click). */
  showProgrammaticHighlight(el: Element): void {
    const rect = el.getBoundingClientRect();

    this.programmaticOverlay.style.left = `${rect.left}px`;
    this.programmaticOverlay.style.top = `${rect.top}px`;
    this.programmaticOverlay.style.width = `${rect.width}px`;
    this.programmaticOverlay.style.height = `${rect.height}px`;
    this.programmaticOverlay.style.display = 'block';

    const tag = `<${el.tagName.toLowerCase()}>`;
    this.programmaticTooltip.textContent = tag;
    this.programmaticTooltip.style.left = `${rect.left}px`;
    this.programmaticTooltip.style.top = `${Math.max(0, rect.top - 22)}px`;
    this.programmaticTooltip.style.display = 'block';

    el.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }

  /** Clear programmatic highlight. */
  clearProgrammaticHighlight(): void {
    this.programmaticOverlay.style.display = 'none';
    this.programmaticTooltip.style.display = 'none';
  }

  // -----------------------------------------------------------------------
  // Rendering
  // -----------------------------------------------------------------------

  private showHighlight(el: Element): void {
    const rect = el.getBoundingClientRect();

    // Position overlay
    this.overlay.style.left = `${rect.left}px`;
    this.overlay.style.top = `${rect.top}px`;
    this.overlay.style.width = `${rect.width}px`;
    this.overlay.style.height = `${rect.height}px`;
    this.overlay.style.display = 'block';

    // Position tooltip above the element
    const tag = `<${el.tagName.toLowerCase()}>`;
    this.tooltip.textContent = tag;
    this.tooltip.style.left = `${rect.left}px`;
    this.tooltip.style.top = `${Math.max(0, rect.top - 22)}px`;
    this.tooltip.style.display = 'block';

    // Zone overlays — destroy previous, create new
    for (const z of this.zoneOverlays) z.remove();
    this.zoneOverlays = createZoneOverlays(el, this.shadow, {
      animate: false,
      zIndex: '50',
      showLabels: false,
    });
  }

  private hideHighlight(): void {
    this.overlay.style.display = 'none';
    this.tooltip.style.display = 'none';
    for (const z of this.zoneOverlays) z.remove();
    this.zoneOverlays = [];
  }
}
