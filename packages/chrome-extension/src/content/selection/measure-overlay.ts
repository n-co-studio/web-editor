import { createElement } from '../../shared/ui-utils';
import { OVERLAY, MEASURE_INDICATOR } from '../../shared/constants';
import { getTopElementAt } from '../../shared/dom-utils';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface MeasurementLine {
  orientation: 'horizontal' | 'vertical';
  style: 'gap' | 'overlap' | 'offset';
  startX: number;
  startY: number;
  endX: number;
  endY: number;
  distance: number;
}

// Fixed, not OVERLAY.info: this draws on the page, so it must not flip
// with the panel theme. See MEASURE_INDICATOR in shared/constants.ts.
const MEASURE_COLOR = MEASURE_INDICATOR.color;

// ---------------------------------------------------------------------------
// Distance computation
// ---------------------------------------------------------------------------

/**
 * Compute measurement lines between two bounding rects.
 * Handles: side-by-side, above/below, diagonal, overlapping, nested.
 */
export function computeMeasurements(a: DOMRect, b: DOMRect): MeasurementLine[] {
  const lines: MeasurementLine[] = [];

  const hOverlap = Math.min(a.right, b.right) - Math.max(a.left, b.left);
  const vOverlap = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);

  // Check containment (one fully inside the other)
  const aContainsB = a.left <= b.left && a.right >= b.right && a.top <= b.top && a.bottom >= b.bottom;
  const bContainsA = b.left <= a.left && b.right >= a.right && b.top <= a.top && b.bottom >= a.bottom;

  if (aContainsB || bContainsA) {
    const outer = aContainsB ? a : b;
    const inner = aContainsB ? b : a;

    // Top offset
    const topDist = inner.top - outer.top;
    if (topDist > 0) {
      const midX = (inner.left + inner.right) / 2;
      lines.push({
        orientation: 'vertical', style: 'offset',
        startX: midX, startY: outer.top,
        endX: midX, endY: inner.top,
        distance: topDist,
      });
    }

    // Bottom offset
    const bottomDist = outer.bottom - inner.bottom;
    if (bottomDist > 0) {
      const midX = (inner.left + inner.right) / 2;
      lines.push({
        orientation: 'vertical', style: 'offset',
        startX: midX, startY: inner.bottom,
        endX: midX, endY: outer.bottom,
        distance: bottomDist,
      });
    }

    // Left offset
    const leftDist = inner.left - outer.left;
    if (leftDist > 0) {
      const midY = (inner.top + inner.bottom) / 2;
      lines.push({
        orientation: 'horizontal', style: 'offset',
        startX: outer.left, startY: midY,
        endX: inner.left, endY: midY,
        distance: leftDist,
      });
    }

    // Right offset
    const rightDist = outer.right - inner.right;
    if (rightDist > 0) {
      const midY = (inner.top + inner.bottom) / 2;
      lines.push({
        orientation: 'horizontal', style: 'offset',
        startX: inner.right, startY: midY,
        endX: outer.right, endY: midY,
        distance: rightDist,
      });
    }

    return lines;
  }

  // Non-containment cases
  const hasHGap = hOverlap <= 0; // separated horizontally
  const hasVGap = vOverlap <= 0; // separated vertically

  if (hasHGap && hasVGap) {
    // Diagonal — L-shape from closest corners
    const leftEl = a.right <= b.left ? a : b;
    const rightEl = leftEl === a ? b : a;
    const topEl = a.bottom <= b.top ? a : b;
    const bottomEl = topEl === a ? b : a;

    const cornerX = leftEl.right;
    const cornerY = topEl.bottom;

    // Horizontal leg
    lines.push({
      orientation: 'horizontal', style: 'gap',
      startX: cornerX, startY: cornerY,
      endX: rightEl.left, endY: cornerY,
      distance: rightEl.left - cornerX,
    });

    // Vertical leg
    lines.push({
      orientation: 'vertical', style: 'gap',
      startX: rightEl.left, startY: cornerY,
      endX: rightEl.left, endY: bottomEl.top,
      distance: bottomEl.top - cornerY,
    });
  } else if (hasHGap) {
    // Separated horizontally, overlapping vertically
    const overlapTop = Math.max(a.top, b.top);
    const overlapBottom = Math.min(a.bottom, b.bottom);
    const midY = (overlapTop + overlapBottom) / 2;

    const leftEl = a.right <= b.left ? a : b;
    const rightEl = leftEl === a ? b : a;

    lines.push({
      orientation: 'horizontal', style: 'gap',
      startX: leftEl.right, startY: midY,
      endX: rightEl.left, endY: midY,
      distance: rightEl.left - leftEl.right,
    });
  } else if (hasVGap) {
    // Separated vertically, overlapping horizontally
    const overlapLeft = Math.max(a.left, b.left);
    const overlapRight = Math.min(a.right, b.right);
    const midX = (overlapLeft + overlapRight) / 2;

    const topEl = a.bottom <= b.top ? a : b;
    const bottomEl = topEl === a ? b : a;

    lines.push({
      orientation: 'vertical', style: 'gap',
      startX: midX, startY: topEl.bottom,
      endX: midX, endY: bottomEl.top,
      distance: bottomEl.top - topEl.bottom,
    });
  } else {
    // Overlapping (not contained) — show overlap extents
    const overlapLeft = Math.max(a.left, b.left);
    const overlapRight = Math.min(a.right, b.right);
    const overlapTop = Math.max(a.top, b.top);
    const overlapBottom = Math.min(a.bottom, b.bottom);

    if (hOverlap > 0) {
      const midY = (overlapTop + overlapBottom) / 2;
      lines.push({
        orientation: 'horizontal', style: 'overlap',
        startX: overlapLeft, startY: midY,
        endX: overlapRight, endY: midY,
        distance: hOverlap,
      });
    }

    if (vOverlap > 0) {
      const midX = (overlapLeft + overlapRight) / 2;
      lines.push({
        orientation: 'vertical', style: 'overlap',
        startX: midX, startY: overlapTop,
        endX: midX, endY: overlapBottom,
        distance: vOverlap,
      });
    }
  }

  return lines;
}

// ---------------------------------------------------------------------------
// MeasureOverlay
// ---------------------------------------------------------------------------

/**
 * Measurement overlay that renders distance lines between the selected
 * element and the element under the cursor. Activated by holding Option.
 */
export class MeasureOverlay {
  private container: HTMLDivElement | null = null;
  private active = false;
  private lastHoveredElement: Element | null = null;

  constructor(
    private readonly shadow: ShadowRoot,
    private readonly host: HTMLDivElement,
  ) {}

  enable(): void {
    this.active = true;
    this.ensureContainer();
  }

  disable(): void {
    this.active = false;
    this.lastHoveredElement = null;
  }

  isActive(): boolean {
    return this.active;
  }

  /**
   * Called on each mousemove while Option is held.
   * Finds the element at the cursor, computes distances from the
   * selected element, and renders measurement lines.
   */
  update(selectedElement: Element, mouseX: number, mouseY: number): void {
    if (!this.active) return;

    const hovered = getTopElementAt(mouseX, mouseY, this.host);
    if (!hovered || hovered === selectedElement || hovered === document.documentElement || hovered === document.body) {
      this.clearContainer();
      this.lastHoveredElement = null;
      return;
    }

    // Skip re-render if same element
    if (hovered === this.lastHoveredElement) return;
    this.lastHoveredElement = hovered;

    this.clearContainer();
    this.ensureContainer();

    const selectedRect = selectedElement.getBoundingClientRect();
    const hoveredRect = hovered.getBoundingClientRect();

    // Hovered element highlight
    this.renderHighlight(hoveredRect);

    // Compute and render measurement lines
    const measurements = computeMeasurements(selectedRect, hoveredRect);
    for (const m of measurements) {
      this.renderLine(m);
      this.renderLabel(m);
    }
  }

  /**
   * Render persistent measurement lines between all adjacent pairs
   * of multi-selected elements. Sorted by visual position (top then left).
   */
  renderPersistentLines(elements: Element[]): void {
    if (elements.length < 2) return;

    this.clearContainer();
    this.ensureContainer();

    // Sort by visual position: top first, then left
    const sorted = [...elements].sort((a, b) => {
      const ra = a.getBoundingClientRect();
      const rb = b.getBoundingClientRect();
      const dy = ra.top - rb.top;
      return Math.abs(dy) > 10 ? dy : ra.left - rb.left;
    });

    // Render lines between each consecutive pair
    for (let i = 0; i < sorted.length - 1; i++) {
      const rectA = sorted[i].getBoundingClientRect();
      const rectB = sorted[i + 1].getBoundingClientRect();
      const measurements = computeMeasurements(rectA, rectB);
      for (const m of measurements) {
        this.renderLine(m);
        this.renderLabel(m);
      }
    }
  }

  /** Remove all measurement visuals. */
  clear(): void {
    this.container?.remove();
    this.container = null;
    this.lastHoveredElement = null;
  }

  // -----------------------------------------------------------------------
  // Rendering
  // -----------------------------------------------------------------------

  private ensureContainer(): void {
    if (this.container) return;

    this.container = createElement('div', { 'aria-hidden': 'true' }, {
      position: 'fixed',
      top: '0',
      left: '0',
      width: '100vw',
      height: '100vh',
      pointerEvents: 'none',
      zIndex: '55',
      overflow: 'visible',
    });
    this.shadow.appendChild(this.container);
  }

  private clearContainer(): void {
    if (!this.container) return;
    this.container.innerHTML = '';
  }

  private renderHighlight(rect: DOMRect): void {
    if (!this.container) return;

    const highlight = createElement('div', {}, {
      position: 'fixed',
      left: `${rect.left}px`,
      top: `${rect.top}px`,
      width: `${rect.width}px`,
      height: `${rect.height}px`,
      border: `2px solid ${MEASURE_COLOR}`,
      background: MEASURE_INDICATOR.fill,
      borderRadius: '1px',
      pointerEvents: 'none',
    });
    this.container.appendChild(highlight);
  }

  private renderLine(m: MeasurementLine): void {
    if (!this.container || m.distance < 1) return;

    const isDashed = m.style === 'gap';

    if (m.orientation === 'horizontal') {
      const left = Math.min(m.startX, m.endX);
      const width = Math.abs(m.endX - m.startX);

      // Main line
      const line = createElement('div', {}, {
        position: 'fixed',
        left: `${left}px`,
        top: `${m.startY}px`,
        width: `${width}px`,
        height: '0',
        borderTop: `1px ${isDashed ? 'dashed' : 'solid'} ${MEASURE_COLOR}`,
        pointerEvents: 'none',
      });
      this.container.appendChild(line);

      // End caps (small vertical ticks)
      for (const x of [left, left + width]) {
        const cap = createElement('div', {}, {
          position: 'fixed',
          left: `${x}px`,
          top: `${m.startY - 4}px`,
          width: '0',
          height: '8px',
          borderLeft: `1px solid ${MEASURE_COLOR}`,
          pointerEvents: 'none',
        });
        this.container.appendChild(cap);
      }
    } else {
      const top = Math.min(m.startY, m.endY);
      const height = Math.abs(m.endY - m.startY);

      const line = createElement('div', {}, {
        position: 'fixed',
        left: `${m.startX}px`,
        top: `${top}px`,
        width: '0',
        height: `${height}px`,
        borderLeft: `1px ${isDashed ? 'dashed' : 'solid'} ${MEASURE_COLOR}`,
        pointerEvents: 'none',
      });
      this.container.appendChild(line);

      // End caps (small horizontal ticks)
      for (const y of [top, top + height]) {
        const cap = createElement('div', {}, {
          position: 'fixed',
          left: `${m.startX - 4}px`,
          top: `${y}px`,
          width: '8px',
          height: '0',
          borderTop: `1px solid ${MEASURE_COLOR}`,
          pointerEvents: 'none',
        });
        this.container.appendChild(cap);
      }
    }
  }

  private renderLabel(m: MeasurementLine): void {
    if (!this.container || m.distance < 1) return;

    const midX = (m.startX + m.endX) / 2;
    const midY = (m.startY + m.endY) / 2;

    const label = createElement('div', {}, {
      position: 'fixed',
      left: `${midX}px`,
      top: `${midY}px`,
      transform: m.orientation === 'horizontal'
        ? 'translate(-50%, -100%) translateY(-4px)'
        : 'translate(4px, -50%)',
      background: MEASURE_INDICATOR.labelBg,
      color: MEASURE_INDICATOR.labelText,
      fontFamily: OVERLAY.monoFamily,
      fontSize: '10px',
      fontWeight: '600',
      padding: '1px 4px',
      borderRadius: OVERLAY.radiusSm,
      whiteSpace: 'nowrap',
      pointerEvents: 'none',
      lineHeight: '1.4',
    });
    label.textContent = `${Math.round(m.distance)}`;
    this.container.appendChild(label);
  }
}
