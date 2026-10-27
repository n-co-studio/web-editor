import { createElement } from '../../shared/ui-utils';
import { OVERLAY, ZONE_OVERLAY, HANDLE_COLORS } from '../../shared/constants';

export interface ZoneOverlayOptions {
  /** Fade-in animation on initial render. Default: true. */
  animate?: boolean;
  /** CSS z-index for zone divs. Default: '55'. */
  zIndex?: string;
  /** Show pixel value labels inside zones. Default: true. */
  showLabels?: boolean;
}

/**
 * Create padding/margin zone overlay divs for an element.
 * Returns the created divs — caller manages lifecycle (cleanup, storage).
 */
export function createZoneOverlays(
  element: Element,
  shadow: ShadowRoot,
  options?: ZoneOverlayOptions,
): HTMLDivElement[] {
  const animate = options?.animate ?? true;
  const zIndex = options?.zIndex ?? '55';
  const showLabels = options?.showLabels ?? true;

  const rect = element.getBoundingClientRect();
  const cs = getComputedStyle(element);
  const pt = parseFloat(cs.paddingTop) || 0;
  const pr = parseFloat(cs.paddingRight) || 0;
  const pb = parseFloat(cs.paddingBottom) || 0;
  const pl = parseFloat(cs.paddingLeft) || 0;
  const mt = parseFloat(cs.marginTop) || 0;
  const mr = parseFloat(cs.marginRight) || 0;
  const mb = parseFloat(cs.marginBottom) || 0;
  const ml = parseFloat(cs.marginLeft) || 0;

  const zones: HTMLDivElement[] = [];

  const add = (x: number, y: number, w: number, h: number, type: 'padding' | 'margin', value: number) => {
    const zone = createZoneDiv(x, y, w, h, type, value, animate, zIndex, showLabels);
    shadow.appendChild(zone);
    zones.push(zone);
  };

  // Padding zones — inside the border box
  if (pt > 0) add(rect.left, rect.top, rect.width, pt, 'padding', pt);
  if (pr > 0) add(rect.right - pr, rect.top, pr, rect.height, 'padding', pr);
  if (pb > 0) add(rect.left, rect.bottom - pb, rect.width, pb, 'padding', pb);
  if (pl > 0) add(rect.left, rect.top, pl, rect.height, 'padding', pl);

  // Margin zones — outside the border box
  if (mt > 0) add(rect.left - ml, rect.top - mt, rect.width + ml + mr, mt, 'margin', mt);
  if (mr > 0) add(rect.right, rect.top - mt, mr, rect.height + mt + mb, 'margin', mr);
  if (mb > 0) add(rect.left - ml, rect.bottom, rect.width + ml + mr, mb, 'margin', mb);
  if (ml > 0) add(rect.left - ml, rect.top - mt, ml, rect.height + mt + mb, 'margin', ml);

  return zones;
}

function createZoneDiv(
  x: number, y: number, w: number, h: number,
  type: 'padding' | 'margin',
  value: number,
  animate: boolean,
  zIndex: string,
  showLabels: boolean,
): HTMLDivElement {
  const isPadding = type === 'padding';
  const zone = createElement('div', {}, {
    position: 'fixed',
    left: `${x}px`,
    top: `${y}px`,
    width: `${w}px`,
    height: `${h}px`,
    background: isPadding ? ZONE_OVERLAY.paddingFill : ZONE_OVERLAY.marginFill,
    outline: `1px dashed ${isPadding ? ZONE_OVERLAY.paddingOutline : ZONE_OVERLAY.marginOutline}`,
    outlineOffset: '-1px',
    pointerEvents: 'none',
    zIndex,
    opacity: animate ? '0' : '1',
    transition: animate ? 'opacity 100ms ease-out' : 'none',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
  });

  // Value label — only show if zone is large enough to fit it
  const minDim = Math.min(w, h);
  if (showLabels && minDim >= 14) {
    const label = createElement('span', {}, {
      // A solid pill in the handle colour with black text, matching the
      // Padding / Margin handle pills (10.6:1 and 7.8:1). The value used to be
      // half-opacity rose text on the rose zone fill: 1.53:1.
      color: '#000',
      background: isPadding ? HANDLE_COLORS.padding : HANDLE_COLORS.margin,
      padding: '1px 3px',
      borderRadius: '3px',
      fontSize: '9px',
      fontWeight: '600',
      fontFamily: OVERLAY.monoFamily,
      lineHeight: '1',
      whiteSpace: 'nowrap',
      pointerEvents: 'none',
      userSelect: 'none',
    });
    label.textContent = `${Math.round(value)}`;
    zone.appendChild(label);
  }

  // Fade in
  if (animate) {
    requestAnimationFrame(() => { zone.style.opacity = '1'; });
  }

  return zone;
}
