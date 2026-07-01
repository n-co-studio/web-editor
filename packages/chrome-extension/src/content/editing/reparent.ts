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
import { detectContainerLayout, computeGapZones, hitTestGapZone, detectWrapping, computeGapZones2D, hitTestGapZone2D, type ContainerLayout, type GapZone } from './gap-math';
import { findOverlayRoot } from './overlay-scope';

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
  /** True when the container wraps / is 2D — gates 2D gap-math (issue #30). */
  is2D: boolean;
  dropZones: DropZone[];
}

/**
 * Build a target candidate for a container: layout, children, 2D gate, and drop
 * zones (2D nearest-gap when wrapping, single-axis otherwise). Children include
 * every element child so the source container's zones share the same
 * including-dragged index space the reorder path uses.
 */
function buildTargetCandidate(container: HTMLElement): TargetCandidate {
  const layout = detectContainerLayout(container);
  const children = Array.from(container.children)
    .filter((c): c is HTMLElement => c instanceof HTMLElement);
  const is2D = detectWrapping(container, children, layout);
  const zones = is2D
    ? computeGapZones2D(container, children, layout)
    : computeGapZones(container, children, layout);
  return {
    container,
    layout,
    children,
    is2D,
    dropZones: zones.map((gz) => ({ ...gz, indicator: null })),
  };
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
 * Find all flex/grid containers within the active overlay scope, excluding the
 * source container and the extension's shadow host.
 *
 * `scopeRoot` is the active overlay boundary from [findOverlayRoot] (issue #30):
 * a candidate is kept only when the scope is page-wide (`document.body` — no
 * overlay detected, previous unconstrained behavior) or the candidate lives
 * inside the overlay. This is what contains an in-overlay reparent drag: a
 * page-root container outside the overlay never becomes a drop target, so a drop
 * there resolves to "no target" and the element snaps back.
 */
function discoverTargetContainers(
  sourceContainer: HTMLElement,
  draggedElement: HTMLElement,
  shadowHost: Element | null,
  scopeRoot: HTMLElement,
): TargetCandidate[] {
  const candidates: TargetCandidate[] = [];
  const pageWide = scopeRoot === document.body;
  const all = document.querySelectorAll('*');

  for (const el of all) {
    if (el === sourceContainer) continue;
    if (shadowHost && (el === shadowHost || shadowHost.contains(el))) continue;
    if (!(el instanceof HTMLElement)) continue;

    // Overlay containment: outside-the-overlay containers are not valid targets.
    if (!pageWide && !scopeRoot.contains(el)) continue;

    const cs = getComputedStyle(el);
    const display = cs.display;
    if (!display.includes('flex') && !display.includes('grid')) continue;

    // Skip if the container is the dragged element or a descendant of it (would be circular)
    if (el === draggedElement || draggedElement.contains(el)) continue;

    candidates.push(buildTargetCandidate(el));
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

    // Discover target containers, contained to the active overlay (issue #30).
    const shadowHost = this.shadow.host;
    const overlayRoot = findOverlayRoot(this.currentElement!);
    this.targets = discoverTargetContainers(this.sourceContainer!, this.currentElement!, shadowHost, overlayRoot);

    // Always include the source container as a valid drop target (for a
    // same-container move, which commits as a reorder). It is inside the
    // overlay by construction, so it is never filtered out by scope.
    this.targets.push(buildTargetCandidate(this.sourceContainer!));

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

    // Reflect drop validity on the cursor (issue #30): no valid in-overlay
    // target under the pointer → not-allowed (the drop will snap back).
    this.cursorOverlay.style.cursor = target ? 'grabbing' : 'not-allowed';

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
      // Hit-test within the target container: 2D nearest-gap when wrapping,
      // else single-axis (issue #30).
      const newIndex = target.is2D
        ? hitTestGapZone2D(target.dropZones, e.clientX, e.clientY)
        : hitTestGapZone(target.dropZones, target.layout.direction === 'row' ? e.clientX : e.clientY);

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
        // Fire callback BEFORE DOM move so it can capture pre-move sibling state.
        // index.ts routes a same-container drop to a ReorderChange (issue #30).
        this.onCommitCb?.(
          this.currentElement,
          sourceContainer,
          sourceIndex,
          target.container,
          targetIndex,
        );
        // Same-container drop is an in-list reorder: use reorder DOM semantics
        // so the moved node lands at the index the ReorderChange describes.
        // Cross-container drop uses the reparent move.
        if (isSameContainer) {
          this.commitReorderInPlace(sourceContainer, sourceIndex, targetIndex);
        } else {
          this.commitReparent(target.container, targetIndex);
        }
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

  /**
   * Same-container move via the reparent tool — commit with reorder semantics
   * (issue #30). `fromIndex` is the element's child position and `toIndex` is
   * the gap insert index (0..N in including-dragged space), matching the
   * ReorderChange the commit callback emits, so the DOM lands where the diff
   * says it will. Mirrors `ReorderEditor.commitReorder`.
   */
  private commitReorderInPlace(container: HTMLElement, fromIndex: number, toIndex: number): void {
    const el = this.currentElement!;
    const original = Array.from(container.children)
      .filter((c): c is HTMLElement => c instanceof HTMLElement);
    const remaining = original.filter((_, i) => i !== fromIndex);
    const effectiveIdx = toIndex > fromIndex ? toIndex - 1 : toIndex;
    const refNode = effectiveIdx < remaining.length ? remaining[effectiveIdx] : null;

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
    // 2D containers get pips at each gap center; 1D keeps the full-span line.
    if (target.is2D) {
      this.renderDropPips(target);
      return;
    }

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

  /** Render wrap-aware drop pips at each 2D gap center (issue #30). */
  private renderDropPips(target: TargetCandidate): void {
    const size = DROP_INDICATOR.pipSize;
    for (const zone of target.dropZones) {
      const cx = zone.cx ?? zone.center;
      const cy = zone.cy ?? 0;
      const indicator = createElement('div', {}, {
        position: 'fixed',
        left: `${cx - size / 2}px`,
        top: `${cy - size / 2}px`,
        width: `${size}px`,
        height: `${size}px`,
        borderRadius: '50%',
        zIndex: '59',
        pointerEvents: 'none',
        background: DROP_INDICATOR.color,
        opacity: '0.4',
        transition: 'opacity 100ms, background 100ms, transform 100ms',
      });
      zone.indicator = indicator;
      this.shadow.appendChild(indicator);
      this.indicators.push(indicator);
    }
  }

  private updateActiveIndicator(target: TargetCandidate, insertIndex: number): void {
    if (target.is2D) {
      for (const zone of target.dropZones) {
        if (!zone.indicator) continue;
        const active = zone.insertIndex === insertIndex;
        zone.indicator.style.background = active ? DROP_INDICATOR.activeColor : DROP_INDICATOR.color;
        zone.indicator.style.opacity = active ? '1' : '0.4';
        zone.indicator.style.transform = active ? 'scale(1.7)' : 'scale(1)';
      }
      return;
    }

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
