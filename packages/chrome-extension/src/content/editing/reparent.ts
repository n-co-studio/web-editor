/**
 * Reparent editing — drag an element from one flex/grid container into another.
 *
 * Extends the reorder concept across container boundaries. The user drags
 * the selected element; as the pointer moves over other flex/grid containers
 * drop zones appear between their children. On drop the element is reparented
 * via moveBefore (Chrome 124+) or insertBefore fallback.
 */

import { createElement } from '../../shared/ui-utils';
import { HANDLE_COLORS, DROP_INDICATOR, OVERLAY } from '../../shared/constants';
import { detectContainerLayout, computeGapZones, hitTestGapZone, type ContainerLayout, type GapZone } from './gap-math';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/** Callback shape for reparent commit. */
export type ReparentCommitCallback = (
  element: HTMLElement,
  sourceContainer: HTMLElement,
  sourceIndex: number,
  targetContainer: HTMLElement,
  targetIndex: number,
) => void;

/** A drop zone with an attached visual indicator element. */
interface DropZone extends GapZone {
  indicator: HTMLDivElement | null;
}

/** A candidate target container with its layout and children. */
interface TargetCandidate {
  container: HTMLElement;
  layout: ContainerLayout;
  children: HTMLElement[];
  dropZones: DropZone[];
}

// ---------------------------------------------------------------------------
// Block-reason guard
// ---------------------------------------------------------------------------

/**
 * Returns a human-readable reason why reparent is blocked for this element,
 * or null if reparent is allowed.
 */
export function getReparentBlockReason(element: Element): string | null {
  if (!element.parentElement) {
    return 'Element has no parent';
  }

  const tag = element.tagName.toLowerCase();
  if (tag === 'html' || tag === 'body') {
    return 'Cannot reparent <html> or <body>';
  }

  return null;
}

// ---------------------------------------------------------------------------
// Container discovery
// ---------------------------------------------------------------------------

/**
 * Find all flex/grid containers on the page, excluding the source container
 * and the extension's shadow host.
 */
function discoverTargetContainers(
  sourceContainer: HTMLElement,
  draggedElement: HTMLElement,
  shadowHost: Element | null,
): TargetCandidate[] {
  const candidates: TargetCandidate[] = [];
  const all = document.querySelectorAll('*');

  for (const el of all) {
    if (el === sourceContainer) continue;
    if (shadowHost && (el === shadowHost || shadowHost.contains(el))) continue;
    if (!(el instanceof HTMLElement)) continue;

    const cs = getComputedStyle(el);
    const display = cs.display;
    if (!display.includes('flex') && !display.includes('grid')) continue;

    // Skip if the container is the dragged element or a descendant of it (would be circular)
    if (el === draggedElement || draggedElement.contains(el)) continue;

    const layout = detectContainerLayout(el);
    const children = Array.from(el.children)
      .filter((c): c is HTMLElement => c instanceof HTMLElement);

    candidates.push({
      container: el,
      layout,
      children,
      dropZones: computeGapZones(el, children, layout)
        .map((gz) => ({ ...gz, indicator: null })),
    });
  }

  return candidates;
}

// ---------------------------------------------------------------------------
// ReparentEditor
// ---------------------------------------------------------------------------

export class ReparentEditor {
  // --- State ---
  private currentElement: HTMLElement | null = null;
  private sourceContainer: HTMLElement | null = null;
  private sourceIndex = -1;
  private onCommitCb: ReparentCommitCallback | null = null;
  private dragging = false;

  // --- Target containers ---
  private targets: TargetCandidate[] = [];
  private activeTarget: TargetCandidate | null = null;
  private activeInsertIndex = -1;

  // --- Drag offset ---
  private grabOffsetX = 0;
  private grabOffsetY = 0;
  private activePointerId = -1;

  // --- DOM elements (in shadow) ---
  private cursorOverlay: HTMLDivElement | null = null;
  private ghostEl: HTMLDivElement | null = null;
  private modeBadge: HTMLDivElement | null = null;
  private indicators: HTMLDivElement[] = [];
  private containerHighlight: HTMLDivElement | null = null;

  // --- Bound handlers ---
  private boundPointerDown: ((e: PointerEvent) => void) | null = null;
  private boundPointerMove: ((e: PointerEvent) => void) | null = null;
  private boundPointerUp: ((e: PointerEvent) => void) | null = null;

  constructor(private readonly shadow: ShadowRoot) {}

  isActive(): boolean {
    return this.currentElement !== null;
  }

  isDragging(): boolean {
    return this.dragging;
  }

  /** No-op — ReparentEditor has no positioned mini panel. */
  reposition(_anchorPos: { x: number; y: number }): void {}

  // -----------------------------------------------------------------------
  // Activate
  // -----------------------------------------------------------------------

  render(element: Element, onCommit: ReparentCommitCallback): void {
    this.cleanup();

    const parent = element.parentElement;
    if (!parent || getReparentBlockReason(element) !== null) return;

    this.currentElement = element as HTMLElement;
    this.sourceContainer = parent as HTMLElement;
    this.onCommitCb = onCommit;

    // Determine source index
    const siblings = Array.from(parent.children)
      .filter((c): c is HTMLElement => c instanceof HTMLElement);
    this.sourceIndex = siblings.indexOf(this.currentElement);

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
    this.sourceContainer = null;
    this.onCommitCb = null;
    this.targets = [];
    this.activeTarget = null;
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
    this.grabOffsetX = e.clientX - rect.left;
    this.grabOffsetY = e.clientY - rect.top;

    // Discover target containers
    const shadowHost = this.shadow.host;
    this.targets = discoverTargetContainers(this.sourceContainer!, this.currentElement!, shadowHost);

    // Also include source container as a valid drop target (for same-container reorder)
    const sourceLayout = detectContainerLayout(this.sourceContainer!);
    const sourceChildren = Array.from(this.sourceContainer!.children)
      .filter((c): c is HTMLElement => c instanceof HTMLElement);
    this.targets.push({
      container: this.sourceContainer!,
      layout: sourceLayout,
      children: sourceChildren,
      dropZones: computeGapZones(this.sourceContainer!, sourceChildren, sourceLayout)
        .map((gz) => ({ ...gz, indicator: null })),
    });

    // Dim the dragged element
    this.currentElement.style.opacity = '0.4';

    // Create ghost
    this.renderGhost(rect);

    // Hide mode badge during drag
    if (this.modeBadge) this.modeBadge.style.opacity = '0';
  }

  private onPointerMove(e: PointerEvent): void {
    if (!this.dragging || !this.cursorOverlay) return;
    if (!this.cursorOverlay.hasPointerCapture(e.pointerId)) return;

    // Move ghost
    if (this.ghostEl) {
      this.ghostEl.style.left = `${e.clientX - this.grabOffsetX}px`;
      this.ghostEl.style.top = `${e.clientY - this.grabOffsetY}px`;
    }

    // Hit-test: which container is the pointer over?
    const target = this.findTargetAtPoint(e.clientX, e.clientY);

    if (target !== this.activeTarget) {
      // Container changed — remove old indicators, render new ones
      this.removeIndicators();
      this.containerHighlight?.remove();
      this.containerHighlight = null;
      this.activeTarget = target;
      this.activeInsertIndex = -1;

      if (target) {
        this.renderContainerHighlight(target.container);
        this.renderDropIndicators(target);
      }
    }

    if (target) {
      // Hit-test within the target container
      const isRow = target.layout.direction === 'row';
      const pos = isRow ? e.clientX : e.clientY;
      const newIndex = hitTestGapZone(target.dropZones, pos);

      if (newIndex !== this.activeInsertIndex) {
        this.activeInsertIndex = newIndex;
        this.updateActiveIndicator(target, newIndex);
      }
    }
  }

  private onPointerUp(e: PointerEvent): void {
    if (!this.dragging || !this.currentElement || !this.cursorOverlay) return;
    if (!this.cursorOverlay.hasPointerCapture(e.pointerId)) return;

    this.cursorOverlay.releasePointerCapture(e.pointerId);
    this.cursorOverlay.style.cursor = 'grab';

    const target = this.activeTarget;
    const targetIndex = this.activeInsertIndex;
    const sourceContainer = this.sourceContainer!;
    const sourceIndex = this.sourceIndex;

    // Restore element opacity
    this.currentElement.style.opacity = '';

    // Remove ghost and indicators
    this.ghostEl?.remove();
    this.ghostEl = null;
    this.removeIndicators();
    this.containerHighlight?.remove();
    this.containerHighlight = null;

    // Restore mode badge
    if (this.modeBadge) this.modeBadge.style.opacity = '1';

    this.dragging = false;

    // Commit if we have a valid target and it's a real move
    if (target && targetIndex >= 0) {
      const isSameContainer = target.container === sourceContainer;
      const isSamePosition = isSameContainer && (
        targetIndex === sourceIndex || targetIndex === sourceIndex + 1
      );

      if (!isSamePosition) {
        // Fire callback BEFORE DOM move so it can capture pre-move sibling state
        this.onCommitCb?.(
          this.currentElement,
          sourceContainer,
          sourceIndex,
          target.container,
          targetIndex,
        );
        this.commitReparent(target.container, targetIndex);
      }
    }

    this.targets = [];
    this.activeTarget = null;
    this.activeInsertIndex = -1;

    this.refreshOverlay();
  }

  cancelDrag(): void {
    if (!this.dragging) return;

    if (this.cursorOverlay && this.activePointerId >= 0) {
      try { this.cursorOverlay.releasePointerCapture(this.activePointerId); } catch { /* not captured */ }
      this.cursorOverlay.style.cursor = 'grab';
    }
    this.activePointerId = -1;

    // Restore element opacity
    if (this.currentElement) {
      this.currentElement.style.opacity = '';
    }

    this.dragging = false;

    this.ghostEl?.remove();
    this.ghostEl = null;
    this.removeIndicators();
    this.containerHighlight?.remove();
    this.containerHighlight = null;

    this.targets = [];
    this.activeTarget = null;
    this.activeInsertIndex = -1;

    if (this.modeBadge) this.modeBadge.style.opacity = '1';
  }

  // -----------------------------------------------------------------------
  // Target hit-testing
  // -----------------------------------------------------------------------

  private findTargetAtPoint(x: number, y: number): TargetCandidate | null {
    let best: TargetCandidate | null = null;
    let bestArea = Infinity;

    for (const t of this.targets) {
      const rect = t.container.getBoundingClientRect();
      if (x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) {
        // Prefer the smallest container that contains the pointer (most specific)
        const area = rect.width * rect.height;
        if (area < bestArea) {
          bestArea = area;
          best = t;
        }
      }
    }

    return best;
  }

  // -----------------------------------------------------------------------
  // DOM commit
  // -----------------------------------------------------------------------

  private commitReparent(targetContainer: HTMLElement, targetIndex: number): void {
    const el = this.currentElement!;

    // Get target children (excluding the dragged element in case of same-container)
    const targetChildren = Array.from(targetContainer.children)
      .filter((c): c is HTMLElement => c instanceof HTMLElement && c !== el);

    const refNode = targetIndex < targetChildren.length ? targetChildren[targetIndex] : null;

    if ('moveBefore' in targetContainer && typeof (targetContainer as any).moveBefore === 'function') {
      (targetContainer as any).moveBefore(el, refNode);
    } else {
      targetContainer.insertBefore(el, refNode);
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
      background: `${HANDLE_COLORS.reparent}08`,
      border: `1px dashed ${HANDLE_COLORS.reparent}`,
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
      background: `${HANDLE_COLORS.reparent}22`,
      border: `2px solid ${HANDLE_COLORS.reparent}`,
      borderRadius: OVERLAY.radiusSm,
      pointerEvents: 'none',
      zIndex: '200',
      opacity: '0.8',
    });
    this.shadow.appendChild(this.ghostEl);
  }

  private renderContainerHighlight(container: HTMLElement): void {
    const rect = container.getBoundingClientRect();
    this.containerHighlight = createElement('div', {}, {
      position: 'fixed',
      left: `${rect.left}px`,
      top: `${rect.top}px`,
      width: `${rect.width}px`,
      height: `${rect.height}px`,
      border: `2px solid ${HANDLE_COLORS.reparent}60`,
      background: `${HANDLE_COLORS.reparent}08`,
      borderRadius: '4px',
      pointerEvents: 'none',
      zIndex: '57',
      transition: 'all 100ms ease',
    });
    this.shadow.appendChild(this.containerHighlight);
  }

  private renderDropIndicators(target: TargetCandidate): void {
    const containerRect = target.container.getBoundingClientRect();
    const isRow = target.layout.direction === 'row';

    for (const zone of target.dropZones) {
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

  private updateActiveIndicator(target: TargetCandidate, insertIndex: number): void {
    const isRow = target.layout.direction === 'row';

    for (const zone of target.dropZones) {
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

    const dot = createElement('div', {}, {
      width: '6px',
      height: '6px',
      borderRadius: '50%',
      background: HANDLE_COLORS.reparent,
      flexShrink: '0',
    });
    this.modeBadge.appendChild(dot);
    this.modeBadge.appendChild(document.createTextNode('REPARENT'));
    this.shadow.appendChild(this.modeBadge);
  }

  private removeIndicators(): void {
    for (const ind of this.indicators) ind.remove();
    this.indicators = [];
    for (const t of this.targets) {
      for (const zone of t.dropZones) zone.indicator = null;
    }
  }
}
