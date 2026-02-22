import { createElement } from '../shared/ui-utils';
import {
  OVERLAY,
  GUIDE_LINE_Z,
  RULER_BAR_Z,
  GUIDE_SNAP_THRESHOLD,
  MAX_GUIDES_PER_PAGE,
} from '../shared/constants';
import type { GridSettings } from './grid-settings';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface GuideData {
  readonly id: string;
  readonly axis: 'x' | 'y';
  /** For axis='x': viewport X coordinate. For axis='y': page Y coordinate. */
  position: number;
}

interface GuideDOM {
  line: HTMLDivElement;
  hitStrip: HTMLDivElement;
  label: HTMLDivElement;
}

interface EdgeEntry {
  position: number;
  rect: DOMRect;
  side: 'top' | 'bottom' | 'left' | 'right';
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const RULER_THICKNESS = 16;
const GUIDE_HIT_WIDTH = 6;
const STORAGE_PREFIX = 'fe-guides-';
const TICK_FALLBACK_SPACING = 8;

const TICK_COLOR = 'rgba(255, 255, 255, 0.35)';
const LABEL_COLOR = 'rgba(255, 255, 255, 0.6)';
const LABEL_FONT = '8px ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace';

// ---------------------------------------------------------------------------
// RulerOverlay
// ---------------------------------------------------------------------------

export class RulerOverlay {
  private visible = false;
  private _dragging = false;

  // DOM
  private topRuler: HTMLDivElement | null = null;
  private leftRuler: HTMLDivElement | null = null;
  private topCanvas: HTMLCanvasElement | null = null;
  private leftCanvas: HTMLCanvasElement | null = null;
  private cursorLabel: HTMLDivElement | null = null;
  private inProgressLine: HTMLDivElement | null = null;
  private edgeHighlight: HTMLDivElement | null = null;
  private resizeObserver: ResizeObserver | null = null;

  // Guides
  private guides: GuideData[] = [];
  private guideElements = new Map<string, GuideDOM>();

  // Active drag state
  private activeGuideId: string | null = null;
  private hoveredGuideId: string | null = null;
  private dragAxis: 'x' | 'y' | null = null;
  private isNewGuideDrag = false;
  private dragRafId: number | null = null;
  private edgeCache: EdgeEntry[] = [];
  private edgeCacheAxis: 'x' | 'y' | null = null;

  // Callbacks
  private suppressHover: (() => void) | null = null;
  private restoreHover: (() => void) | null = null;

  // Keyboard
  private keydownHandler: ((e: KeyboardEvent) => void) | null = null;

  constructor(
    private readonly shadow: ShadowRoot,
    private readonly getGridSettings: () => GridSettings,
    private readonly isGridVisible: () => boolean,
  ) {}

  // -----------------------------------------------------------------------
  // Public API
  // -----------------------------------------------------------------------

  async show(): Promise<void> {
    if (this.visible) return;
    this.visible = true;
    await this.loadGuides();
    this.renderRulers();
    this.renderAllGuides();
    this.attachKeyboard();

    this.resizeObserver = new ResizeObserver(() => {
      this.drawTopRuler();
      this.drawLeftRuler();
    });
    if (this.topRuler) this.resizeObserver.observe(this.topRuler);
    if (this.leftRuler) this.resizeObserver.observe(this.leftRuler);
  }

  hide(): void {
    if (!this.visible) return;
    this.visible = false;
    this.cancelDrag();
    this.removeRulers();
    this.removeAllGuideElements();
    this.detachKeyboard();
    this.resizeObserver?.disconnect();
    this.resizeObserver = null;
  }

  isVisible(): boolean {
    return this.visible;
  }

  isDragging(): boolean {
    return this._dragging;
  }

  cancelDrag(): void {
    if (!this._dragging) return;

    // If dragging a new guide, remove the in-progress line
    if (this.isNewGuideDrag && this.activeGuideId) {
      this.removeGuide(this.activeGuideId);
    }

    this.cleanupDrag();
  }

  getGuidePositions(): { x: number[]; y: number[] } {
    const x: number[] = [];
    const y: number[] = [];
    for (const g of this.guides) {
      if (g.axis === 'x') x.push(g.position);
      else y.push(g.position - window.scrollY); // page → viewport
    }
    return { x, y };
  }

  refreshGuides(): void {
    if (!this.visible) return;
    // Redraw ruler canvases (left ruler tracks scroll)
    this.drawTopRuler();
    this.drawLeftRuler();
    // Reposition horizontal guides (they track page scroll)
    for (const guide of this.guides) {
      if (guide.axis === 'y') this.updateGuideElement(guide);
    }
  }

  setHoverSuppressor(suppress: () => void, restore: () => void): void {
    this.suppressHover = suppress;
    this.restoreHover = restore;
  }

  // -----------------------------------------------------------------------
  // Coordinate helpers
  // -----------------------------------------------------------------------

  /** Convert guide position to viewport coordinate for CSS rendering. */
  private viewportPos(guide: GuideData): number {
    return guide.axis === 'y' ? guide.position - window.scrollY : guide.position;
  }

  // -----------------------------------------------------------------------
  // Ruler bars (canvas-based)
  // -----------------------------------------------------------------------

  private renderRulers(): void {
    // Top ruler (horizontal)
    this.topRuler = createElement('div', { 'aria-hidden': 'true' }, {
      position: 'fixed',
      top: '0',
      left: `${RULER_THICKNESS}px`,
      width: `calc(100vw - ${RULER_THICKNESS}px)`,
      height: `${RULER_THICKNESS}px`,
      background: OVERLAY.bg,
      borderBottom: `1px solid ${OVERLAY.border}`,
      zIndex: RULER_BAR_Z,
      pointerEvents: 'auto',
      cursor: 'row-resize',
      overflow: 'hidden',
    });
    this.topCanvas = document.createElement('canvas');
    Object.assign(this.topCanvas.style, {
      position: 'absolute', top: '0', left: '0',
      width: '100%', height: '100%', pointerEvents: 'none',
    });
    this.topRuler.appendChild(this.topCanvas);
    this.shadow.appendChild(this.topRuler);

    // Left ruler (vertical)
    this.leftRuler = createElement('div', { 'aria-hidden': 'true' }, {
      position: 'fixed',
      top: `${RULER_THICKNESS}px`,
      left: '0',
      width: `${RULER_THICKNESS}px`,
      height: `calc(100vh - ${RULER_THICKNESS}px)`,
      background: OVERLAY.bg,
      borderRight: `1px solid ${OVERLAY.border}`,
      zIndex: RULER_BAR_Z,
      pointerEvents: 'auto',
      cursor: 'col-resize',
      overflow: 'hidden',
    });
    this.leftCanvas = document.createElement('canvas');
    Object.assign(this.leftCanvas.style, {
      position: 'absolute', top: '0', left: '0',
      width: '100%', height: '100%', pointerEvents: 'none',
    });
    this.leftRuler.appendChild(this.leftCanvas);
    this.shadow.appendChild(this.leftRuler);

    // Corner block (dead zone)
    const corner = createElement('div', { 'aria-hidden': 'true' }, {
      position: 'fixed',
      top: '0',
      left: '0',
      width: `${RULER_THICKNESS}px`,
      height: `${RULER_THICKNESS}px`,
      background: OVERLAY.bg,
      borderRight: `1px solid ${OVERLAY.border}`,
      borderBottom: `1px solid ${OVERLAY.border}`,
      zIndex: RULER_BAR_Z,
      pointerEvents: 'auto',
    });
    this.shadow.appendChild(corner);
    (this.topRuler as any).__corner = corner;

    // Cursor coordinate label (follows mouse on ruler bars)
    this.cursorLabel = createElement('div', {}, {
      position: 'fixed',
      display: 'none',
      background: OVERLAY.guide,
      color: '#fff',
      fontFamily: OVERLAY.monoFamily,
      fontSize: '9px',
      fontWeight: '600',
      padding: '1px 4px',
      borderRadius: '2px',
      pointerEvents: 'none',
      zIndex: RULER_BAR_Z,
      whiteSpace: 'nowrap',
      lineHeight: '1.3',
    });
    this.shadow.appendChild(this.cursorLabel);

    // Draw initial tick marks
    this.drawTopRuler();
    this.drawLeftRuler();

    // Attach ruler interactions
    this.attachRulerEvents(this.topRuler, 'y');
    this.attachRulerEvents(this.leftRuler, 'x');
  }

  private removeRulers(): void {
    const corner = (this.topRuler as any)?.__corner;
    corner?.remove();
    this.topRuler?.remove();
    this.leftRuler?.remove();
    this.cursorLabel?.remove();
    this.inProgressLine?.remove();
    this.edgeHighlight?.remove();
    this.topRuler = null;
    this.leftRuler = null;
    this.topCanvas = null;
    this.leftCanvas = null;
    this.cursorLabel = null;
    this.inProgressLine = null;
    this.edgeHighlight = null;
  }

  // -----------------------------------------------------------------------
  // Canvas ruler drawing
  // -----------------------------------------------------------------------

  private drawTopRuler(): void {
    if (!this.topCanvas || !this.topRuler) return;
    const dpr = window.devicePixelRatio || 1;
    const cssWidth = this.topRuler.clientWidth;
    const cssHeight = RULER_THICKNESS;

    this.topCanvas.width = Math.round(cssWidth * dpr);
    this.topCanvas.height = Math.round(cssHeight * dpr);

    const ctx = this.topCanvas.getContext('2d');
    if (!ctx) return;
    ctx.scale(dpr, dpr);
    ctx.clearRect(0, 0, cssWidth, cssHeight);

    // Viewport X range: startX..endX
    const startX = RULER_THICKNESS;
    const endX = startX + cssWidth;

    // 1px base ticks — thin line along bottom
    ctx.fillStyle = 'rgba(255, 255, 255, 0.15)';
    ctx.fillRect(0, cssHeight - 1, cssWidth, 1);

    ctx.fillStyle = TICK_COLOR;

    // 5px ticks (3px tall)
    const first5 = Math.ceil(startX / 5) * 5;
    for (let vx = first5; vx <= endX; vx += 5) {
      if (vx % 10 === 0) continue; // drawn by 10px pass
      ctx.fillRect(vx - startX, cssHeight - 3, 1, 3);
    }

    // 10px ticks (5px tall)
    const first10 = Math.ceil(startX / 10) * 10;
    for (let vx = first10; vx <= endX; vx += 10) {
      if (vx % 50 === 0) continue;
      ctx.fillRect(vx - startX, cssHeight - 5, 1, 5);
    }

    // 50px ticks (8px tall)
    const first50 = Math.ceil(startX / 50) * 50;
    for (let vx = first50; vx <= endX; vx += 50) {
      if (vx % 100 === 0) continue;
      ctx.fillRect(vx - startX, cssHeight - 8, 1, 8);
    }

    // 100px ticks (full height) + labels
    const first100 = Math.ceil(startX / 100) * 100;
    for (let vx = first100; vx <= endX; vx += 100) {
      const cx = vx - startX;
      ctx.fillRect(cx, 0, 1, cssHeight);
      if (vx > 0) {
        ctx.fillStyle = LABEL_COLOR;
        ctx.font = LABEL_FONT;
        ctx.textAlign = 'left';
        ctx.fillText(`${vx}`, cx + 2, 9);
        ctx.fillStyle = TICK_COLOR;
      }
    }
  }

  private drawLeftRuler(): void {
    if (!this.leftCanvas || !this.leftRuler) return;
    const dpr = window.devicePixelRatio || 1;
    const cssWidth = RULER_THICKNESS;
    const cssHeight = this.leftRuler.clientHeight;

    this.leftCanvas.width = Math.round(cssWidth * dpr);
    this.leftCanvas.height = Math.round(cssHeight * dpr);

    const ctx = this.leftCanvas.getContext('2d');
    if (!ctx) return;
    ctx.scale(dpr, dpr);
    ctx.clearRect(0, 0, cssWidth, cssHeight);

    // Page Y range visible in the ruler
    const scrollY = window.scrollY;
    const startPageY = RULER_THICKNESS + scrollY;
    const endPageY = startPageY + cssHeight;

    // 1px base ticks — thin line along right edge
    ctx.fillStyle = 'rgba(255, 255, 255, 0.15)';
    ctx.fillRect(cssWidth - 1, 0, 1, cssHeight);

    ctx.fillStyle = TICK_COLOR;

    // 5px ticks (3px wide)
    const first5 = Math.ceil(startPageY / 5) * 5;
    for (let py = first5; py <= endPageY; py += 5) {
      if (py % 10 === 0) continue;
      const cy = py - startPageY;
      ctx.fillRect(cssWidth - 3, cy, 3, 1);
    }

    // 10px ticks (5px wide)
    const first10 = Math.ceil(startPageY / 10) * 10;
    for (let py = first10; py <= endPageY; py += 10) {
      if (py % 50 === 0) continue;
      const cy = py - startPageY;
      ctx.fillRect(cssWidth - 5, cy, 5, 1);
    }

    // 50px ticks (8px wide)
    const first50 = Math.ceil(startPageY / 50) * 50;
    for (let py = first50; py <= endPageY; py += 50) {
      if (py % 100 === 0) continue;
      const cy = py - startPageY;
      ctx.fillRect(cssWidth - 8, cy, 8, 1);
    }

    // 100px ticks (full width) + labels
    const first100 = Math.ceil(startPageY / 100) * 100;
    for (let py = first100; py <= endPageY; py += 100) {
      const cy = py - startPageY;
      ctx.fillRect(0, cy, cssWidth, 1);
      if (py > 0) {
        ctx.save();
        ctx.fillStyle = LABEL_COLOR;
        ctx.font = LABEL_FONT;
        ctx.translate(9, cy + 2);
        ctx.rotate(-Math.PI / 2);
        ctx.textAlign = 'right';
        ctx.fillText(`${py}`, 0, 0);
        ctx.restore();
        ctx.fillStyle = TICK_COLOR;
      }
    }
  }

  private getTickSpacing(): number {
    try {
      const settings = this.getGridSettings();
      return settings.baseSpacing > 0 ? settings.baseSpacing : TICK_FALLBACK_SPACING;
    } catch {
      return TICK_FALLBACK_SPACING;
    }
  }

  // -----------------------------------------------------------------------
  // Ruler events — guide creation
  // -----------------------------------------------------------------------

  private attachRulerEvents(ruler: HTMLDivElement, axis: 'x' | 'y'): void {
    let draggingFromRuler = false;

    const onMouseMove = (e: MouseEvent) => {
      if (draggingFromRuler || this._dragging) return;
      this.showCursorLabel(axis, e);
    };

    const onMouseLeave = () => {
      if (!draggingFromRuler && !this._dragging) {
        this.hideCursorLabel();
      }
    };

    const onPointerDown = (e: PointerEvent) => {
      if (e.button !== 0) return;
      e.preventDefault();
      e.stopPropagation();

      ruler.setPointerCapture(e.pointerId);
      draggingFromRuler = true;
      this._dragging = true;
      this.isNewGuideDrag = true;
      this.dragAxis = axis;

      // Suppress hover
      this.suppressHover?.();

      // Re-enable pointer events on the ruler itself
      ruler.style.pointerEvents = 'auto';

      // Create a new guide at the current position (page coords for Y)
      const pos = axis === 'x' ? e.clientX : e.clientY + window.scrollY;
      const guide = this.addGuide(axis, pos);
      this.activeGuideId = guide.id;

      // Pre-collect DOM element edges for snap
      this.collectEdges(axis);

      this.hideCursorLabel();
    };

    const onPointerMove = (e: PointerEvent) => {
      if (!ruler.hasPointerCapture(e.pointerId)) return;

      const pos = axis === 'x' ? e.clientX : e.clientY + window.scrollY;
      const snappedPos = this.snapPosition(axis, pos);

      // Update guide position
      const guide = this.guides.find((g) => g.id === this.activeGuideId);
      if (guide) {
        guide.position = snappedPos;
        this.updateGuideElement(guide);
      }
    };

    const onPointerUp = (e: PointerEvent) => {
      if (!ruler.hasPointerCapture(e.pointerId)) return;
      ruler.releasePointerCapture(e.pointerId);

      const pos = axis === 'x' ? e.clientX : e.clientY + window.scrollY;

      // If released back inside ruler bar area, discard the guide
      const insideRuler = this.isInsideRuler(axis, e.clientX, e.clientY);
      if (insideRuler && this.activeGuideId) {
        this.removeGuide(this.activeGuideId);
      } else {
        // Snap final position
        const snappedPos = this.snapPosition(axis, pos);
        const guide = this.guides.find((g) => g.id === this.activeGuideId);
        if (guide) {
          guide.position = snappedPos;
          this.updateGuideElement(guide);
        }
        this.saveGuides();
      }

      this.cleanupDrag();
      draggingFromRuler = false;
    };

    ruler.addEventListener('mousemove', onMouseMove);
    ruler.addEventListener('mouseleave', onMouseLeave);
    ruler.addEventListener('pointerdown', onPointerDown);
    ruler.addEventListener('pointermove', onPointerMove);
    ruler.addEventListener('pointerup', onPointerUp);
  }

  // -----------------------------------------------------------------------
  // Guide rendering
  // -----------------------------------------------------------------------

  private renderAllGuides(): void {
    for (const guide of this.guides) {
      this.renderGuideElement(guide);
    }
  }

  private renderGuideElement(guide: GuideData): void {
    // Remove existing if present
    this.removeGuideElement(guide.id);

    const isHorizontal = guide.axis === 'y';
    const vp = this.viewportPos(guide);

    // Guide line (visual, 1px)
    const line = createElement('div', { 'data-guide-id': guide.id }, {
      position: 'fixed',
      ...(isHorizontal
        ? { top: `${vp}px`, left: '0', width: '100vw', height: '1px' }
        : { top: '0', left: `${vp}px`, width: '1px', height: '100vh' }),
      background: OVERLAY.guide,
      zIndex: GUIDE_LINE_Z,
      pointerEvents: 'none',
    });

    // Hit strip for dragging (wider, transparent)
    const hitStrip = createElement('div', { 'data-guide-hit': guide.id }, {
      position: 'fixed',
      ...(isHorizontal
        ? {
            top: `${vp - GUIDE_HIT_WIDTH / 2}px`,
            left: '0',
            width: '100vw',
            height: `${GUIDE_HIT_WIDTH}px`,
            cursor: 'row-resize',
          }
        : {
            top: '0',
            left: `${vp - GUIDE_HIT_WIDTH / 2}px`,
            width: `${GUIDE_HIT_WIDTH}px`,
            height: '100vh',
            cursor: 'col-resize',
          }),
      background: 'transparent',
      zIndex: GUIDE_LINE_Z,
      pointerEvents: 'auto',
    });

    // Coordinate label at ruler edge
    const label = createElement('div', {}, {
      position: 'fixed',
      ...(isHorizontal
        ? { top: `${vp - 7}px`, left: '1px' }
        : { top: '1px', left: `${vp + 3}px` }),
      background: OVERLAY.guide,
      color: '#fff',
      fontFamily: OVERLAY.monoFamily,
      fontSize: '9px',
      fontWeight: '600',
      padding: '1px 3px',
      borderRadius: '2px',
      pointerEvents: 'none',
      zIndex: RULER_BAR_Z,
      whiteSpace: 'nowrap',
      lineHeight: '1.3',
    });
    label.textContent = `${Math.round(guide.position)}`;

    this.shadow.appendChild(line);
    this.shadow.appendChild(hitStrip);
    this.shadow.appendChild(label);

    this.guideElements.set(guide.id, { line, hitStrip, label });

    // Attach drag events to hit strip
    this.attachGuideDragEvents(hitStrip, guide);
  }

  private updateGuideElement(guide: GuideData): void {
    const dom = this.guideElements.get(guide.id);
    if (!dom) return;

    const isHorizontal = guide.axis === 'y';
    const vp = this.viewportPos(guide);

    if (isHorizontal) {
      dom.line.style.top = `${vp}px`;
      dom.hitStrip.style.top = `${vp - GUIDE_HIT_WIDTH / 2}px`;
      dom.label.style.top = `${vp - 7}px`;
    } else {
      dom.line.style.left = `${vp}px`;
      dom.hitStrip.style.left = `${vp - GUIDE_HIT_WIDTH / 2}px`;
      dom.label.style.left = `${vp + 3}px`;
    }
    dom.label.textContent = `${Math.round(guide.position)}`;
  }

  private removeGuideElement(id: string): void {
    const dom = this.guideElements.get(id);
    if (!dom) return;
    dom.line.remove();
    dom.hitStrip.remove();
    dom.label.remove();
    this.guideElements.delete(id);
  }

  private removeAllGuideElements(): void {
    for (const [, dom] of this.guideElements) {
      dom.line.remove();
      dom.hitStrip.remove();
      dom.label.remove();
    }
    this.guideElements.clear();
  }

  // -----------------------------------------------------------------------
  // Guide drag (existing guides)
  // -----------------------------------------------------------------------

  private attachGuideDragEvents(hitStrip: HTMLDivElement, guide: GuideData): void {
    const onPointerDown = (e: PointerEvent) => {
      if (e.button !== 0) return;
      e.preventDefault();
      e.stopPropagation();

      hitStrip.setPointerCapture(e.pointerId);
      this._dragging = true;
      this.isNewGuideDrag = false;
      this.activeGuideId = guide.id;
      this.dragAxis = guide.axis;

      this.suppressHover?.();
      this.collectEdges(guide.axis);
    };

    const onPointerMove = (e: PointerEvent) => {
      if (!hitStrip.hasPointerCapture(e.pointerId)) return;

      const pos = guide.axis === 'x' ? e.clientX : e.clientY + window.scrollY;
      const snappedPos = this.snapPosition(guide.axis, pos);
      guide.position = snappedPos;
      this.updateGuideElement(guide);
    };

    const onPointerUp = (e: PointerEvent) => {
      if (!hitStrip.hasPointerCapture(e.pointerId)) return;
      hitStrip.releasePointerCapture(e.pointerId);

      // If dragged back into ruler bar area, delete the guide
      const insideRuler = this.isInsideRuler(guide.axis, e.clientX, e.clientY);
      if (insideRuler) {
        this.removeGuide(guide.id);
      } else {
        const pos = guide.axis === 'x' ? e.clientX : e.clientY + window.scrollY;
        guide.position = this.snapPosition(guide.axis, pos);
        this.updateGuideElement(guide);
      }

      this.saveGuides();
      this.cleanupDrag();
    };

    // Hover tracking for Delete key
    hitStrip.addEventListener('mouseenter', () => {
      this.hoveredGuideId = guide.id;
      // Visual hover feedback
      const dom = this.guideElements.get(guide.id);
      if (dom) dom.line.style.background = OVERLAY.primaryHover;
    });
    hitStrip.addEventListener('mouseleave', () => {
      if (this.hoveredGuideId === guide.id) this.hoveredGuideId = null;
      const dom = this.guideElements.get(guide.id);
      if (dom) dom.line.style.background = OVERLAY.guide;
    });

    hitStrip.addEventListener('pointerdown', onPointerDown);
    hitStrip.addEventListener('pointermove', onPointerMove);
    hitStrip.addEventListener('pointerup', onPointerUp);
  }

  // -----------------------------------------------------------------------
  // Guide data management
  // -----------------------------------------------------------------------

  private addGuide(axis: 'x' | 'y', position: number): GuideData {
    if (this.guides.length >= MAX_GUIDES_PER_PAGE) {
      // Remove the oldest guide
      const oldest = this.guides.shift()!;
      this.removeGuideElement(oldest.id);
    }

    const guide: GuideData = {
      id: crypto.randomUUID(),
      axis,
      position,
    };
    this.guides.push(guide);
    this.renderGuideElement(guide);
    return guide;
  }

  private removeGuide(id: string): void {
    this.removeGuideElement(id);
    this.guides = this.guides.filter((g) => g.id !== id);
    if (this.hoveredGuideId === id) this.hoveredGuideId = null;
    if (this.activeGuideId === id) this.activeGuideId = null;
  }

  // -----------------------------------------------------------------------
  // Snap logic — mutually exclusive: grid OR edge
  // -----------------------------------------------------------------------

  private snapPosition(axis: 'x' | 'y', rawPos: number): number {
    let best = rawPos;
    let bestDist = Infinity;

    if (this.isGridVisible()) {
      // Grid mode: snap to grid lines ONLY
      if (gridSpacing >= 4) {
        const nearest = Math.round(rawPos / gridSpacing) * gridSpacing;
        const dist = Math.abs(rawPos - nearest);
        if (dist <= GUIDE_SNAP_THRESHOLD) {
          best = nearest;
          bestDist = dist;
        }
      }
      this.clearEdgeHighlight();
    } else {
      // Edge mode: snap to DOM element edges ONLY + highlight
      let snappedEntry: EdgeEntry | null = null;
      for (const entry of this.edgeCache) {
        const dist = Math.abs(rawPos - entry.position);
        if (dist <= GUIDE_SNAP_THRESHOLD && dist < bestDist) {
          best = entry.position;
          bestDist = dist;
          snappedEntry = entry;
        }
      }

      if (snappedEntry) {
        this.showEdgeHighlight(snappedEntry);
      } else {
        this.clearEdgeHighlight();
      }
    }

    return best;
  }

  private collectEdges(axis: 'x' | 'y'): void {
    if (this.edgeCacheAxis === axis && this.edgeCache.length > 0) return;

    this.edgeCacheAxis = axis;
    const entries: EdgeEntry[] = [];
    const seen = new Set<string>();
    const shadowHost = this.shadow.host;
    const scrollY = window.scrollY;

    const walker = document.createTreeWalker(
      document.body,
      NodeFilter.SHOW_ELEMENT,
      {
        acceptNode(node: Node): number {
          const el = node as Element;
          const tag = el.tagName;
          if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'HEAD') {
            return NodeFilter.FILTER_REJECT;
          }
          if (shadowHost && shadowHost.contains(el)) {
            return NodeFilter.FILTER_REJECT;
          }
          const style = getComputedStyle(el);
          if (style.visibility === 'hidden') {
            return NodeFilter.FILTER_SKIP;
          }
          const rect = el.getBoundingClientRect();
          if (rect.width < 4 || rect.height < 4) {
            return NodeFilter.FILTER_SKIP;
          }
          return NodeFilter.FILTER_ACCEPT;
        },
      },
    );

    while (walker.nextNode()) {
      const el = walker.currentNode as Element;
      const rect = el.getBoundingClientRect();
      if (axis === 'x') {
        const left = Math.round(rect.left);
        const right = Math.round(rect.right);
        const kl = `${left}-left`;
        const kr = `${right}-right`;
        if (!seen.has(kl)) { seen.add(kl); entries.push({ position: left, rect, side: 'left' }); }
        if (!seen.has(kr)) { seen.add(kr); entries.push({ position: right, rect, side: 'right' }); }
      } else {
        // Y-axis: store page coordinates
        const top = Math.round(rect.top + scrollY);
        const bottom = Math.round(rect.bottom + scrollY);
        const kt = `${top}-top`;
        const kb = `${bottom}-bottom`;
        if (!seen.has(kt)) { seen.add(kt); entries.push({ position: top, rect, side: 'top' }); }
        if (!seen.has(kb)) { seen.add(kb); entries.push({ position: bottom, rect, side: 'bottom' }); }
      }
    }

    this.edgeCache = entries;
  }

  // -----------------------------------------------------------------------
  // Edge highlight
  // -----------------------------------------------------------------------

  private showEdgeHighlight(entry: EdgeEntry): void {
    if (!this.edgeHighlight) {
      this.edgeHighlight = createElement('div', { 'aria-hidden': 'true' }, {
        position: 'fixed',
        pointerEvents: 'none',
        zIndex: GUIDE_LINE_Z,
        background: OVERLAY.guide,
        opacity: '0.5',
      });
      this.shadow.appendChild(this.edgeHighlight);
    }

    const rect = entry.rect;
    if (entry.side === 'top' || entry.side === 'bottom') {
      const y = entry.side === 'top' ? rect.top - 1 : rect.bottom - 1;
      Object.assign(this.edgeHighlight.style, {
        top: `${y}px`, left: `${rect.left}px`,
        width: `${rect.width}px`, height: '3px',
        display: 'block',
      });
    } else {
      const x = entry.side === 'left' ? rect.left - 1 : rect.right - 1;
      Object.assign(this.edgeHighlight.style, {
        top: `${rect.top}px`, left: `${x}px`,
        width: '3px', height: `${rect.height}px`,
        display: 'block',
      });
    }
  }

  private clearEdgeHighlight(): void {
    if (this.edgeHighlight) {
      this.edgeHighlight.style.display = 'none';
    }
  }

  // -----------------------------------------------------------------------
  // Drag helpers
  // -----------------------------------------------------------------------

  private isInsideRuler(axis: 'x' | 'y', clientX: number, clientY: number): boolean {
    if (axis === 'x') {
      // Vertical guide — created from left ruler, discard if back in left ruler
      return clientX <= RULER_THICKNESS;
    } else {
      // Horizontal guide — created from top ruler, discard if back in top ruler
      return clientY <= RULER_THICKNESS;
    }
  }

  private cleanupDrag(): void {
    this._dragging = false;
    this.activeGuideId = null;
    this.dragAxis = null;
    this.isNewGuideDrag = false;
    this.edgeCache = [];
    this.edgeCacheAxis = null;

    if (this.dragRafId != null) {
      cancelAnimationFrame(this.dragRafId);
      this.dragRafId = null;
    }

    this.inProgressLine?.remove();
    this.inProgressLine = null;

    this.clearEdgeHighlight();
    this.restoreHover?.();
  }

  // -----------------------------------------------------------------------
  // Cursor label
  // -----------------------------------------------------------------------

  private showCursorLabel(axis: 'x' | 'y', e: MouseEvent): void {
    if (!this.cursorLabel) return;
    this.cursorLabel.style.display = 'block';

    if (axis === 'x') {
      // Left ruler — show page Y coordinate
      const pageY = Math.round(e.clientY + window.scrollY);
      this.cursorLabel.textContent = `${pageY}`;
      this.cursorLabel.style.left = `${RULER_THICKNESS + 2}px`;
      this.cursorLabel.style.top = `${e.clientY - 6}px`;
    } else {
      // Top ruler — show X coordinate
      this.cursorLabel.textContent = `${Math.round(e.clientX)}`;
      this.cursorLabel.style.left = `${e.clientX + 4}px`;
      this.cursorLabel.style.top = `${RULER_THICKNESS + 2}px`;
    }
  }

  private hideCursorLabel(): void {
    if (!this.cursorLabel) return;
    this.cursorLabel.style.display = 'none';
  }

  // -----------------------------------------------------------------------
  // Keyboard — Delete hovered guide
  // -----------------------------------------------------------------------

  private attachKeyboard(): void {
    this.keydownHandler = (e: KeyboardEvent) => {
      if (e.key === 'Delete' || e.key === 'Backspace') {
        if (this.hoveredGuideId) {
          e.preventDefault();
          e.stopPropagation();
          this.removeGuide(this.hoveredGuideId);
          this.saveGuides();
        }
      }
    };
    document.addEventListener('keydown', this.keydownHandler, true);
  }

  private detachKeyboard(): void {
    if (this.keydownHandler) {
      document.removeEventListener('keydown', this.keydownHandler, true);
      this.keydownHandler = null;
    }
  }

  // -----------------------------------------------------------------------
  // Persistence
  // -----------------------------------------------------------------------

  private getStorageKey(): string {
    return STORAGE_PREFIX + location.origin + location.pathname;
  }

  private async loadGuides(): Promise<void> {
    try {
      const key = this.getStorageKey();
      const result = await chrome.storage.session.get(key);
      const stored = result[key];
      if (Array.isArray(stored)) {
        this.guides = stored
          .filter((g: any) =>
            g && typeof g.id === 'string' &&
            (g.axis === 'x' || g.axis === 'y') &&
            typeof g.position === 'number',
          )
          .slice(0, MAX_GUIDES_PER_PAGE);
      }
    } catch {
      // Non-fatal
    }
  }

  private async saveGuides(): Promise<void> {
    try {
      const key = this.getStorageKey();
      const data = this.guides.map((g) => ({
        id: g.id,
        axis: g.axis,
        position: g.position,
      }));
      await chrome.storage.session.set({ [key]: data });
    } catch {
      // Non-fatal
    }
  }
}
