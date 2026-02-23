/**
 * Reorder editing — drag-to-reorder children within a flex/grid container.
 *
 * Phase 1: block-reason guard only. Phase 2: drag interaction. Phase 3: undo/redo.
 */

import { createElement } from '../../shared/ui-utils';
import { HANDLE_COLORS, DROP_INDICATOR, OVERLAY } from '../../shared/constants';
import { OrderPreview } from './order-preview';
import { detectContainerLayout, computeGapZones, hitTestGapZone, type ContainerLayout, type GapZone } from './gap-math';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/** Callback shape for reorder commit — carries reorder-specific data. */
export type ReorderCommitCallback = (
  element: HTMLElement,
  container: HTMLElement,
  fromIndex: number,
  toIndex: number,
  originalChildOrder: HTMLElement[],
) => void;

/** A drop zone with an attached visual indicator element. */
interface DropZone extends GapZone {
  /** DOM element for the visual indicator line. */
  indicator: HTMLDivElement | null;
}

// ---------------------------------------------------------------------------
// Block-reason guard (Phase 1)
// ---------------------------------------------------------------------------

/**
 * Returns a human-readable reason why reorder is blocked for this element,
 * or null if reorder is allowed.
 */
export function getReorderBlockReason(element: Element): string | null {
  const parent = element.parentElement;
  if (!parent) {
    return 'Element has no parent';
  }

  const parentStyle = getComputedStyle(parent);
  const parentDisplay = parentStyle.display;

  const isFlex = parentDisplay.includes('flex');
  const isGrid = parentDisplay.includes('grid');

  if (!isFlex && !isGrid) {
    return 'Parent is not a flex or grid container';
  }

  if (isFlex && parentStyle.flexWrap !== 'nowrap') {
    return 'Wrapped flex containers are not supported for reorder';
  }

  if (parent.children.length <= 1) {
    return 'Element is the only child — nothing to reorder';
  }

  return null;
}

// ---------------------------------------------------------------------------
// ReorderEditor (Phase 2)
// ---------------------------------------------------------------------------

export class ReorderEditor {
  // --- State ---
  private currentElement: HTMLElement | null = null;
  private container: HTMLElement | null = null;
  private onCommitCb: ReorderCommitCallback | null = null;
  private closeCb: (() => void) | null = null;
  private dragging = false;
  private originalIndex = -1;
  private currentInsertIndex = -1;
  private originalChildOrder: HTMLElement[] = [];
  private layout: ContainerLayout = { direction: 'row', isReversed: false };

  // --- Geometry ---
  private dropZones: DropZone[] = [];

  // --- Drag offset (pointer grab point relative to ghost) ---
  private grabOffsetX = 0;
  private grabOffsetY = 0;
  private activePointerId = -1;

  // --- DOM elements (in shadow) ---
  private cursorOverlay: HTMLDivElement | null = null;
  private ghostEl: HTMLDivElement | null = null;
  private modeBadge: HTMLDivElement | null = null;
  private indicators: HTMLDivElement[] = [];

  // --- Preview ---
  private orderPreview = new OrderPreview();

  // --- Pending FLIP rAF IDs (cancelled on drag abort) ---
  private pendingFlipRafs: number[] = [];

  // --- Bound handlers ---
  private boundPointerDown: ((e: PointerEvent) => void) | null = null;
  private boundPointerMove: ((e: PointerEvent) => void) | null = null;
  private boundPointerUp: ((e: PointerEvent) => void) | null = null;

  constructor(private readonly shadow: ShadowRoot) {}

  onClose(cb: () => void): void {
    this.closeCb = cb;
  }

  isActive(): boolean {
    return this.currentElement !== null;
  }

  isDragging(): boolean {
    return this.dragging;
  }

  /** No-op — ReorderEditor has no positioned mini panel. */
  reposition(_anchorPos: { x: number; y: number }): void {}

  // -----------------------------------------------------------------------
  // Activate
  // -----------------------------------------------------------------------

  /**
   * Activate reorder mode on the given element.
   * Computes container info, sibling rects, drop zones.
   * Renders cursor overlay and mode badge.
   */
  render(element: Element, onCommit: ReorderCommitCallback): void {
    this.cleanup();

    const parent = element.parentElement;
    if (!parent || getReorderBlockReason(element) !== null) return;

    this.currentElement = element as HTMLElement;
    this.container = parent as HTMLElement;
    this.onCommitCb = onCommit;

    // Determine layout direction
    this.layout = detectContainerLayout(this.container);

    // Capture original child order (HTMLElement children only)
    this.originalChildOrder = Array.from(this.container.children)
      .filter((c): c is HTMLElement => c instanceof HTMLElement);
    this.originalIndex = this.originalChildOrder.indexOf(this.currentElement);
    this.currentInsertIndex = this.originalIndex;

    // Compute drop zones (gap-math returns GapZone[], extend with indicator field)
    this.dropZones = computeGapZones(this.container, this.originalChildOrder, this.layout)
      .map((gz) => ({ ...gz, indicator: null }));

    // Render cursor overlay
    this.renderCursorOverlay();

    // Render mode badge
    const rect = this.currentElement.getBoundingClientRect();
    this.renderModeBadge(rect);

    // Bind pointer handlers
    this.boundPointerDown = this.onPointerDown.bind(this);
    this.boundPointerMove = this.onPointerMove.bind(this);
    this.boundPointerUp = this.onPointerUp.bind(this);

    this.cursorOverlay!.addEventListener('pointerdown', this.boundPointerDown);
    document.addEventListener('pointermove', this.boundPointerMove, true);
    document.addEventListener('pointerup', this.boundPointerUp, true);
  }

  // -----------------------------------------------------------------------
  // Refresh & Cleanup
  // -----------------------------------------------------------------------

  /** Reposition cursor overlay and badge to track element on scroll. */
  refreshOverlay(): void {
    if (!this.currentElement || !this.cursorOverlay || this.dragging) return;
    const rect = this.currentElement.getBoundingClientRect();
    this.cursorOverlay.style.left = `${rect.left}px`;
    this.cursorOverlay.style.top = `${rect.top}px`;
    this.cursorOverlay.style.width = `${rect.width}px`;
    this.cursorOverlay.style.height = `${rect.height}px`;

    if (this.modeBadge) {
      this.modeBadge.style.left = `${rect.left}px`;
      this.modeBadge.style.top = `${rect.top - 24}px`;
    }
  }

  /** Full cleanup — remove all DOM, listeners, revert preview. */
  cleanup(): void {
    this.cancelDrag();

    this.cursorOverlay?.remove();
    this.cursorOverlay = null;
    this.modeBadge?.remove();
    this.modeBadge = null;

    if (this.boundPointerMove) {
      document.removeEventListener('pointermove', this.boundPointerMove, true);
      this.boundPointerMove = null;
    }
    if (this.boundPointerUp) {
      document.removeEventListener('pointerup', this.boundPointerUp, true);
      this.boundPointerUp = null;
    }
    this.boundPointerDown = null;

    this.currentElement = null;
    this.container = null;
    this.onCommitCb = null;
    this.dropZones = [];
    this.originalChildOrder = [];
  }

  // -----------------------------------------------------------------------
  // Visual order computation for FLIP
  // -----------------------------------------------------------------------

  /**
   * Compute CSS `order` values that produce the visual arrangement
   * as if the dragged element were moved from `draggedIdx` to `targetIdx`.
   */
  private computeVisualOrder(draggedIdx: number, targetIdx: number): number[] {
    const n = this.originalChildOrder.length;

    // Build desired sequence: remove dragged, insert at target
    const sequence: number[] = [];
    for (let i = 0; i < n; i++) {
      if (i === draggedIdx) continue;
      sequence.push(i);
    }
    const effectiveTarget = targetIdx > draggedIdx ? targetIdx - 1 : targetIdx;
    sequence.splice(Math.min(effectiveTarget, sequence.length), 0, draggedIdx);

    // Map sequence position → order value for each original index
    const orders = new Array<number>(n);
    for (let pos = 0; pos < sequence.length; pos++) {
      orders[sequence[pos]] = pos;
    }
    return orders;
  }

  // -----------------------------------------------------------------------
  // Pointer handlers
  // -----------------------------------------------------------------------

  private onPointerDown(e: PointerEvent): void {
    if (!this.currentElement || !this.cursorOverlay) return;
    e.preventDefault();
    e.stopPropagation();

    this.cursorOverlay.setPointerCapture(e.pointerId);
    this.activePointerId = e.pointerId;
    this.cursorOverlay.style.cursor = 'grabbing';
    this.dragging = true;

    const rect = this.currentElement.getBoundingClientRect();

    // Record grab offset so ghost tracks from the grab point
    this.grabOffsetX = e.clientX - rect.left;
    this.grabOffsetY = e.clientY - rect.top;

    // Init OrderPreview for all siblings
    this.orderPreview.begin(this.originalChildOrder);

    // Dim the dragged element
    this.orderPreview.apply(this.currentElement, 'opacity', '0.4');

    // Create ghost
    this.renderGhost(rect);

    // Render drop indicators
    this.renderDropIndicators();

    // Hide mode badge during drag
    if (this.modeBadge) this.modeBadge.style.opacity = '0';
  }

  private onPointerMove(e: PointerEvent): void {
    if (!this.dragging || !this.cursorOverlay) return;
    if (!this.cursorOverlay.hasPointerCapture(e.pointerId)) return;

    // Move ghost to follow pointer
    if (this.ghostEl) {
      this.ghostEl.style.left = `${e.clientX - this.grabOffsetX}px`;
      this.ghostEl.style.top = `${e.clientY - this.grabOffsetY}px`;
    }

    // Hit-test along layout axis
    const pos = this.layout.direction === 'row' ? e.clientX : e.clientY;
    const newIndex = hitTestGapZone(this.dropZones, pos);

    // Midpoint crossing throttle — only update on index change
    if (newIndex !== this.currentInsertIndex) {
      this.flipAnimate(newIndex);
      this.updateActiveIndicator(newIndex);
      this.currentInsertIndex = newIndex;
    }
  }

  private onPointerUp(e: PointerEvent): void {
    if (!this.dragging || !this.currentElement || !this.cursorOverlay) return;
    if (!this.cursorOverlay.hasPointerCapture(e.pointerId)) return;

    this.cursorOverlay.releasePointerCapture(e.pointerId);
    this.cursorOverlay.style.cursor = 'grab';

    const fromIndex = this.originalIndex;
    const toIndex = this.currentInsertIndex;
    const childOrderSnapshot = [...this.originalChildOrder];

    // Cancel in-flight FLIP rAFs before reverting
    for (const id of this.pendingFlipRafs) cancelAnimationFrame(id);
    this.pendingFlipRafs = [];

    // Revert all CSS order / transform / transition overrides
    this.orderPreview.revertAll();

    // Remove ghost and indicators
    this.ghostEl?.remove();
    this.ghostEl = null;
    this.removeIndicators();

    // Restore mode badge
    if (this.modeBadge) this.modeBadge.style.opacity = '1';

    this.dragging = false;

    // Commit if position changed
    if (toIndex !== fromIndex) {
      this.commitReorder(fromIndex, toIndex);
      this.onCommitCb?.(
        this.currentElement,
        this.container!,
        fromIndex,
        toIndex,
        childOrderSnapshot,
      );
    }

    this.refreshOverlay();
  }

  /** Cancel an in-progress drag — revert all preview styles, remove ghost + indicators. */
  cancelDrag(): void {
    if (!this.dragging) return;

    // Cancel any in-flight FLIP rAFs before reverting
    for (const id of this.pendingFlipRafs) cancelAnimationFrame(id);
    this.pendingFlipRafs = [];

    // Release pointer capture if held
    if (this.cursorOverlay && this.activePointerId >= 0) {
      try { this.cursorOverlay.releasePointerCapture(this.activePointerId); } catch { /* not captured */ }
      this.cursorOverlay.style.cursor = 'grab';
    }
    this.activePointerId = -1;

    this.orderPreview.revertAll();
    this.dragging = false;

    this.ghostEl?.remove();
    this.ghostEl = null;
    this.removeIndicators();

    this.currentInsertIndex = this.originalIndex;

    if (this.modeBadge) this.modeBadge.style.opacity = '1';
  }

  // -----------------------------------------------------------------------
  // FLIP animation
  // -----------------------------------------------------------------------

  private flipAnimate(newInsertIndex: number): void {
    const children = this.originalChildOrder;

    // FIRST: snapshot current positions of all siblings (skip dragged element)
    const firstRects = new Map<HTMLElement, DOMRect>();
    for (const child of children) {
      if (child === this.currentElement) continue;
      firstRects.set(child, child.getBoundingClientRect());
    }

    // LAST: apply CSS order values to produce the target layout
    const orders = this.computeVisualOrder(this.originalIndex, newInsertIndex);
    for (let i = 0; i < children.length; i++) {
      this.orderPreview.apply(children[i], 'order', String(orders[i]));
    }
    // Keep dragged element dimmed
    this.orderPreview.apply(this.currentElement!, 'opacity', '0.4');

    // Force layout
    void this.container!.offsetHeight;

    // INVERT + PLAY: for each sibling, compute delta and animate
    for (const child of children) {
      if (child === this.currentElement) continue;

      const firstRect = firstRects.get(child)!;
      const lastRect = child.getBoundingClientRect();
      const dx = firstRect.left - lastRect.left;
      const dy = firstRect.top - lastRect.top;

      if (Math.abs(dx) < 0.5 && Math.abs(dy) < 0.5) {
        // No visible movement — clear any stale transform
        this.orderPreview.apply(child, 'transform', '');
        this.orderPreview.apply(child, 'transition', '');
        continue;
      }

      // INVERT: place at old position
      this.orderPreview.apply(child, 'transition', 'none');
      this.orderPreview.apply(child, 'transform', `translate(${dx}px, ${dy}px)`);

      // PLAY: animate to new position (next frame, tracked for cancellation)
      const rafId = requestAnimationFrame(() => {
        // Remove this rAF from pending list
        const idx = this.pendingFlipRafs.indexOf(rafId);
        if (idx !== -1) this.pendingFlipRafs.splice(idx, 1);

        this.orderPreview.apply(child, 'transition', 'transform 150ms ease');
        this.orderPreview.apply(child, 'transform', '');

        const onEnd = () => {
          this.orderPreview.apply(child, 'transition', '');
          child.removeEventListener('transitionend', onEnd);
        };
        child.addEventListener('transitionend', onEnd);
      });
      this.pendingFlipRafs.push(rafId);
    }
  }

  // -----------------------------------------------------------------------
  // DOM commit
  // -----------------------------------------------------------------------

  private commitReorder(fromIndex: number, toIndex: number): void {
    const el = this.currentElement!;
    const container = this.container!;

    // Compute reference node from the original child order
    const remaining = this.originalChildOrder.filter((_, i) => i !== fromIndex);
    const effectiveIdx = toIndex > fromIndex ? toIndex - 1 : toIndex;
    const refNode = effectiveIdx < remaining.length ? remaining[effectiveIdx] : null;

    // Use moveBefore if available (Chrome 124+), else insertBefore
    if ('moveBefore' in container && typeof (container as any).moveBefore === 'function') {
      (container as any).moveBefore(el, refNode);
    } else {
      container.insertBefore(el, refNode);
    }
  }

  // -----------------------------------------------------------------------
  // DOM rendering helpers
  // -----------------------------------------------------------------------

  private renderCursorOverlay(): void {
    const rect = this.currentElement!.getBoundingClientRect();
    this.cursorOverlay = createElement('div', {}, {
      position: 'fixed',
      left: `${rect.left}px`,
      top: `${rect.top}px`,
      width: `${rect.width}px`,
      height: `${rect.height}px`,
      cursor: 'grab',
      pointerEvents: 'auto',
      zIndex: '58',
      background: `${HANDLE_COLORS.reorder}08`,
      border: `1px dashed ${HANDLE_COLORS.reorder}`,
      borderRadius: '2px',
    });
    this.shadow.appendChild(this.cursorOverlay);
  }

  private renderGhost(rect: DOMRect): void {
    this.ghostEl = createElement('div', {}, {
      position: 'fixed',
      left: `${rect.left}px`,
      top: `${rect.top}px`,
      width: `${rect.width}px`,
      height: `${rect.height}px`,
      background: `${HANDLE_COLORS.reorder}22`,
      border: `2px solid ${HANDLE_COLORS.reorder}`,
      borderRadius: OVERLAY.radiusSm,
      pointerEvents: 'none',
      zIndex: '200',
      opacity: '0.8',
    });
    this.shadow.appendChild(this.ghostEl);
  }

  private renderDropIndicators(): void {
    const containerRect = this.container!.getBoundingClientRect();
    const isRow = this.layout.direction === 'row';

    for (const zone of this.dropZones) {
      const indicator = createElement('div', {}, {
        position: 'fixed',
        zIndex: '59',
        pointerEvents: 'none',
        borderRadius: '1px',
        background: DROP_INDICATOR.color,
        opacity: '0.4',
        transition: 'opacity 100ms, background 100ms',
      });

      if (isRow) {
        indicator.style.left = `${zone.center - DROP_INDICATOR.thickness / 2}px`;
        indicator.style.top = `${containerRect.top}px`;
        indicator.style.width = `${DROP_INDICATOR.thickness}px`;
        indicator.style.height = `${containerRect.height}px`;
      } else {
        indicator.style.left = `${containerRect.left}px`;
        indicator.style.top = `${zone.center - DROP_INDICATOR.thickness / 2}px`;
        indicator.style.width = `${containerRect.width}px`;
        indicator.style.height = `${DROP_INDICATOR.thickness}px`;
      }

      zone.indicator = indicator;
      this.shadow.appendChild(indicator);
      this.indicators.push(indicator);
    }
  }

  private updateActiveIndicator(insertIndex: number): void {
    const isRow = this.layout.direction === 'row';

    for (const zone of this.dropZones) {
      if (!zone.indicator) continue;

      if (zone.insertIndex === insertIndex) {
        zone.indicator.style.background = DROP_INDICATOR.activeColor;
        zone.indicator.style.opacity = '1';
        if (isRow) {
          zone.indicator.style.width = `${DROP_INDICATOR.activeThickness}px`;
        } else {
          zone.indicator.style.height = `${DROP_INDICATOR.activeThickness}px`;
        }
      } else {
        zone.indicator.style.background = DROP_INDICATOR.color;
        zone.indicator.style.opacity = '0.4';
        if (isRow) {
          zone.indicator.style.width = `${DROP_INDICATOR.thickness}px`;
        } else {
          zone.indicator.style.height = `${DROP_INDICATOR.thickness}px`;
        }
      }
    }
  }

  private renderModeBadge(rect: DOMRect): void {
    this.modeBadge = createElement('div', {}, {
      position: 'fixed',
      left: `${rect.left}px`,
      top: `${rect.top - 24}px`,
      zIndex: '61',
      display: 'flex',
      alignItems: 'center',
      gap: '4px',
      padding: '2px 8px',
      background: OVERLAY.bg,
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusSm,
      fontFamily: OVERLAY.fontFamily,
      fontSize: '10px',
      fontWeight: '600',
      color: OVERLAY.text,
      pointerEvents: 'none',
      whiteSpace: 'nowrap',
      transition: 'opacity 150ms',
    });

    // Colored dot
    const dot = createElement('div', {}, {
      width: '6px',
      height: '6px',
      borderRadius: '50%',
      background: HANDLE_COLORS.reorder,
      flexShrink: '0',
    });
    this.modeBadge.appendChild(dot);
    this.modeBadge.appendChild(document.createTextNode('REORDER'));
    this.shadow.appendChild(this.modeBadge);
  }

  private removeIndicators(): void {
    for (const ind of this.indicators) ind.remove();
    this.indicators = [];
    for (const zone of this.dropZones) zone.indicator = null;
  }
}
