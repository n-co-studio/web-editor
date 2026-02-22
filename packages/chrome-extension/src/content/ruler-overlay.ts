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
  position: number;
}

interface GuideDOM {
  line: HTMLDivElement;
  hitStrip: HTMLDivElement;
  label: HTMLDivElement;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const RULER_THICKNESS = 16;
const GUIDE_HIT_WIDTH = 6;
const STORAGE_PREFIX = 'fe-guides-';
const TICK_FALLBACK_SPACING = 8;

// ---------------------------------------------------------------------------
// RulerOverlay
// ---------------------------------------------------------------------------

export class RulerOverlay {
  private visible = false;
  private _dragging = false;

  // DOM
  private topRuler: HTMLDivElement | null = null;
  private leftRuler: HTMLDivElement | null = null;
  private cursorLabel: HTMLDivElement | null = null;
  private inProgressLine: HTMLDivElement | null = null;

  // Guides
  private guides: GuideData[] = [];
  private guideElements = new Map<string, GuideDOM>();

  // Active drag state
  private activeGuideId: string | null = null;
  private hoveredGuideId: string | null = null;
  private dragAxis: 'x' | 'y' | null = null;
  private isNewGuideDrag = false;
  private dragRafId: number | null = null;
  private edgeCache: number[] = [];
  private edgeCacheAxis: 'x' | 'y' | null = null;

  // Callbacks
  private suppressHover: (() => void) | null = null;
  private restoreHover: (() => void) | null = null;

  // Keyboard
  private keydownHandler: ((e: KeyboardEvent) => void) | null = null;

  constructor(
    private readonly shadow: ShadowRoot,
    private readonly getGridSettings: () => GridSettings,
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
  }

  hide(): void {
    if (!this.visible) return;
    this.visible = false;
    this.cancelDrag();
    this.removeRulers();
    this.removeAllGuideElements();
    this.detachKeyboard();
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
      else y.push(g.position);
    }
    return { x, y };
  }

  refreshGuides(): void {
    if (!this.visible) return;
    // Guide lines are position: fixed — no repositioning needed on scroll.
    // But ruler tick marks may need to update if grid settings changed.
    this.updateRulerTicks();
  }

  setHoverSuppressor(suppress: () => void, restore: () => void): void {
    this.suppressHover = suppress;
    this.restoreHover = restore;
  }

  // -----------------------------------------------------------------------
  // Ruler bars
  // -----------------------------------------------------------------------

  private renderRulers(): void {
    const tickSpacing = this.getTickSpacing();

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
      cursor: 'col-resize',
      overflow: 'hidden',
      backgroundImage: this.buildTickGradient('vertical', tickSpacing),
      backgroundSize: `${tickSpacing}px 100%`,
    });
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
      cursor: 'row-resize',
      overflow: 'hidden',
      backgroundImage: this.buildTickGradient('horizontal', tickSpacing),
      backgroundSize: `100% ${tickSpacing}px`,
    });
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
    // Store corner on topRuler for cleanup
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

    // Attach ruler interactions
    this.attachRulerEvents(this.topRuler, 'x');
    this.attachRulerEvents(this.leftRuler, 'y');
  }

  private removeRulers(): void {
    const corner = (this.topRuler as any)?.__corner;
    corner?.remove();
    this.topRuler?.remove();
    this.leftRuler?.remove();
    this.cursorLabel?.remove();
    this.inProgressLine?.remove();
    this.topRuler = null;
    this.leftRuler = null;
    this.cursorLabel = null;
    this.inProgressLine = null;
  }

  private updateRulerTicks(): void {
    const tickSpacing = this.getTickSpacing();
    if (this.topRuler) {
      this.topRuler.style.backgroundImage = this.buildTickGradient('vertical', tickSpacing);
      this.topRuler.style.backgroundSize = `${tickSpacing}px 100%`;
    }
    if (this.leftRuler) {
      this.leftRuler.style.backgroundImage = this.buildTickGradient('horizontal', tickSpacing);
      this.leftRuler.style.backgroundSize = `100% ${tickSpacing}px`;
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

  private buildTickGradient(direction: 'horizontal' | 'vertical', spacing: number): string {
    const dir = direction === 'horizontal' ? 'to bottom' : 'to right';
    const color = `rgba(255, 255, 255, 0.2)`;
    return `repeating-linear-gradient(${dir}, ${color} 0px, ${color} 1px, transparent 1px, transparent ${spacing}px)`;
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

      // Create a new guide at the current position
      const pos = axis === 'x' ? e.clientX : e.clientY;
      const guide = this.addGuide(axis, pos);
      this.activeGuideId = guide.id;

      // Pre-collect DOM element edges for snap
      this.collectEdges(axis);

      this.hideCursorLabel();
    };

    const onPointerMove = (e: PointerEvent) => {
      if (!ruler.hasPointerCapture(e.pointerId)) return;

      const pos = axis === 'x' ? e.clientX : e.clientY;
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

      const pos = axis === 'x' ? e.clientX : e.clientY;

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

    // Guide line (visual, 1px)
    const line = createElement('div', { 'data-guide-id': guide.id }, {
      position: 'fixed',
      ...(isHorizontal
        ? { top: `${guide.position}px`, left: '0', width: '100vw', height: '1px' }
        : { top: '0', left: `${guide.position}px`, width: '1px', height: '100vh' }),
      background: OVERLAY.guide,
      zIndex: GUIDE_LINE_Z,
      pointerEvents: 'none',
    });

    // Hit strip for dragging (wider, transparent)
    const hitStrip = createElement('div', { 'data-guide-hit': guide.id }, {
      position: 'fixed',
      ...(isHorizontal
        ? {
            top: `${guide.position - GUIDE_HIT_WIDTH / 2}px`,
            left: '0',
            width: '100vw',
            height: `${GUIDE_HIT_WIDTH}px`,
            cursor: 'row-resize',
          }
        : {
            top: '0',
            left: `${guide.position - GUIDE_HIT_WIDTH / 2}px`,
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
        ? { top: `${guide.position - 7}px`, left: '1px' }
        : { top: '1px', left: `${guide.position + 3}px` }),
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
    const pos = guide.position;

    if (isHorizontal) {
      dom.line.style.top = `${pos}px`;
      dom.hitStrip.style.top = `${pos - GUIDE_HIT_WIDTH / 2}px`;
      dom.label.style.top = `${pos - 7}px`;
    } else {
      dom.line.style.left = `${pos}px`;
      dom.hitStrip.style.left = `${pos - GUIDE_HIT_WIDTH / 2}px`;
      dom.label.style.left = `${pos + 3}px`;
    }
    dom.label.textContent = `${Math.round(pos)}`;
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

      const pos = guide.axis === 'x' ? e.clientX : e.clientY;
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
        const pos = guide.axis === 'x' ? e.clientX : e.clientY;
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
  // Snap logic
  // -----------------------------------------------------------------------

  private snapPosition(axis: 'x' | 'y', rawPos: number): number {
    let best = rawPos;
    let bestDist = Infinity;

    // Snap to grid lines
    const gridSpacing = this.getTickSpacing();
    if (gridSpacing > 0) {
      const nearest = Math.round(rawPos / gridSpacing) * gridSpacing;
      const dist = Math.abs(rawPos - nearest);
      if (dist <= GUIDE_SNAP_THRESHOLD && dist < bestDist) {
        best = nearest;
        bestDist = dist;
      }
    }

    // Snap to DOM element edges (pre-collected)
    for (const edge of this.edgeCache) {
      const dist = Math.abs(rawPos - edge);
      if (dist <= GUIDE_SNAP_THRESHOLD && dist < bestDist) {
        best = edge;
        bestDist = dist;
      }
    }

    return best;
  }

  private collectEdges(axis: 'x' | 'y'): void {
    if (this.edgeCacheAxis === axis && this.edgeCache.length > 0) return;

    this.edgeCacheAxis = axis;
    const edges = new Set<number>();
    const shadowHost = this.shadow.host;

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
        edges.add(Math.round(rect.left));
        edges.add(Math.round(rect.right));
      } else {
        edges.add(Math.round(rect.top));
        edges.add(Math.round(rect.bottom));
      }
    }

    this.edgeCache = Array.from(edges);
  }

  // -----------------------------------------------------------------------
  // Drag helpers
  // -----------------------------------------------------------------------

  private isInsideRuler(axis: 'x' | 'y', clientX: number, clientY: number): boolean {
    if (axis === 'x') {
      // Vertical guide — check if inside top ruler
      return clientY <= RULER_THICKNESS;
    } else {
      // Horizontal guide — check if inside left ruler
      return clientX <= RULER_THICKNESS;
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

    this.restoreHover?.();
  }

  // -----------------------------------------------------------------------
  // Cursor label
  // -----------------------------------------------------------------------

  private showCursorLabel(axis: 'x' | 'y', e: MouseEvent): void {
    if (!this.cursorLabel) return;
    this.cursorLabel.style.display = 'block';

    if (axis === 'x') {
      // Top ruler — show X coordinate
      this.cursorLabel.textContent = `${Math.round(e.clientX)}`;
      this.cursorLabel.style.left = `${e.clientX + 4}px`;
      this.cursorLabel.style.top = `${RULER_THICKNESS + 2}px`;
    } else {
      // Left ruler — show Y coordinate
      this.cursorLabel.textContent = `${Math.round(e.clientY)}`;
      this.cursorLabel.style.left = `${RULER_THICKNESS + 2}px`;
      this.cursorLabel.style.top = `${e.clientY - 6}px`;
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
