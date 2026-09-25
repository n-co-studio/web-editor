import type { PropertyChange } from '@nco-studio/shared';
import { createElement } from '../../shared/ui-utils';
import { getComputedProperty } from '../../shared/dom-utils';
import { OVERLAY, SELECTION } from '../../shared/constants';
import type { PreviewManager } from './preview';

type ChangeCallback = (changes: PropertyChange[]) => void;

/**
 * Drag-to-reposition tool. Allows dragging positioned elements
 * (absolute, fixed, relative) to update their top/left values.
 * Shift+drag locks to horizontal or vertical axis.
 */
export class MoveEditor {
  private currentElement: Element | null = null;
  private currentOnCommit: ChangeCallback | null = null;

  // Drag state
  private dragging = false;
  private startPointerX = 0;
  private startPointerY = 0;
  private startTop = 0;
  private startLeft = 0;
  private axisLock: 'none' | 'x' | 'y' = 'none';

  // DOM
  private cursorOverlay: HTMLDivElement | null = null;
  private positionBadge: HTMLDivElement | null = null;

  // Bound handlers (for removal)
  private boundPointerDown: ((e: PointerEvent) => void) | null = null;
  private boundPointerMove: ((e: PointerEvent) => void) | null = null;
  private boundPointerUp: ((e: PointerEvent) => void) | null = null;

  constructor(
    private readonly shadow: ShadowRoot,
    private readonly preview: PreviewManager,
  ) {}

  /**
   * Activate move mode on the given element.
   * Sets up a cursor overlay and pointer handlers for drag interaction.
   */
  render(element: Element, onCommit: ChangeCallback): void {
    this.cleanup();
    this.currentElement = element;
    this.currentOnCommit = onCommit;

    // Cursor overlay matching the element's bounding rect
    const rect = element.getBoundingClientRect();
    this.cursorOverlay = createElement('div', {}, {
      position: 'fixed',
      left: `${rect.left}px`,
      top: `${rect.top}px`,
      width: `${rect.width}px`,
      height: `${rect.height}px`,
      cursor: 'move',
      pointerEvents: 'auto',
      zIndex: '58',
      background: 'rgba(6, 182, 212, 0.05)',
      border: `1px dashed ${SELECTION.ring}`,
      borderRadius: '2px',
    });
    this.shadow.appendChild(this.cursorOverlay);

    // Bind pointer handlers
    this.boundPointerDown = this.onPointerDown.bind(this);
    this.boundPointerMove = this.onPointerMove.bind(this);
    this.boundPointerUp = this.onPointerUp.bind(this);

    this.cursorOverlay.addEventListener('pointerdown', this.boundPointerDown);
    document.addEventListener('pointermove', this.boundPointerMove, true);
    document.addEventListener('pointerup', this.boundPointerUp, true);
  }

  /** Reposition the cursor overlay to track the element (e.g., after scroll). */
  refreshOverlay(): void {
    if (!this.currentElement || !this.cursorOverlay || this.dragging) return;
    const rect = this.currentElement.getBoundingClientRect();
    this.cursorOverlay.style.left = `${rect.left}px`;
    this.cursorOverlay.style.top = `${rect.top}px`;
    this.cursorOverlay.style.width = `${rect.width}px`;
    this.cursorOverlay.style.height = `${rect.height}px`;
  }

  cleanup(): void {
    this.cancelDrag();
    this.cursorOverlay?.remove();
    this.cursorOverlay = null;
    this.positionBadge?.remove();
    this.positionBadge = null;

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
    this.currentOnCommit = null;
  }

  isActive(): boolean {
    return this.currentElement !== null;
  }

  isDragging(): boolean {
    return this.dragging;
  }

  // -----------------------------------------------------------------------
  // Pointer handlers
  // -----------------------------------------------------------------------

  private onPointerDown(e: PointerEvent): void {
    if (!this.currentElement || !this.cursorOverlay) return;
    e.preventDefault();
    e.stopPropagation();

    this.cursorOverlay.setPointerCapture(e.pointerId);
    this.dragging = true;
    this.axisLock = 'none';

    this.startPointerX = e.clientX;
    this.startPointerY = e.clientY;

    this.startTop = parseFloat(getComputedProperty(this.currentElement, 'top')) || 0;
    this.startLeft = parseFloat(getComputedProperty(this.currentElement, 'left')) || 0;

    this.preview.begin(this.currentElement as HTMLElement);
    this.showPositionBadge(this.startLeft, this.startTop);
  }

  private onPointerMove(e: PointerEvent): void {
    if (!this.dragging || !this.currentElement || !this.cursorOverlay) return;
    if (!this.cursorOverlay.hasPointerCapture(e.pointerId)) return;

    let dx = e.clientX - this.startPointerX;
    let dy = e.clientY - this.startPointerY;

    // Shift key: lock to axis with greatest initial delta
    if (e.shiftKey) {
      if (this.axisLock === 'none' && (Math.abs(dx) > 3 || Math.abs(dy) > 3)) {
        this.axisLock = Math.abs(dx) >= Math.abs(dy) ? 'x' : 'y';
      }
      if (this.axisLock === 'x') dy = 0;
      if (this.axisLock === 'y') dx = 0;
    } else {
      this.axisLock = 'none';
    }

    const newLeft = this.startLeft + dx;
    const newTop = this.startTop + dy;

    this.preview.apply('left', `${newLeft}px`);
    this.preview.apply('top', `${newTop}px`);

    // Track the element with the overlay
    const rect = this.currentElement.getBoundingClientRect();
    this.cursorOverlay.style.left = `${rect.left}px`;
    this.cursorOverlay.style.top = `${rect.top}px`;

    this.updatePositionBadge(newLeft, newTop);
  }

  private onPointerUp(e: PointerEvent): void {
    if (!this.dragging || !this.currentElement || !this.cursorOverlay) return;
    if (!this.cursorOverlay.hasPointerCapture(e.pointerId)) return;

    this.cursorOverlay.releasePointerCapture(e.pointerId);

    let dx = e.clientX - this.startPointerX;
    let dy = e.clientY - this.startPointerY;

    // Final axis-lock
    if (this.axisLock === 'x') dy = 0;
    if (this.axisLock === 'y') dx = 0;

    const newLeft = this.startLeft + dx;
    const newTop = this.startTop + dy;

    this.preview.apply('left', `${newLeft}px`);
    this.preview.apply('top', `${newTop}px`);

    const originals = this.preview.commit();

    const fromLeft = originals.get('left') ?? getComputedProperty(this.currentElement, 'left');
    const fromTop = originals.get('top') ?? getComputedProperty(this.currentElement, 'top');

    const changes: PropertyChange[] = [];
    if (`${newLeft}px` !== fromLeft) {
      changes.push({
        property: 'left',
        fromValue: fromLeft,
        toValue: `${newLeft}px`,
        unit: 'px',
      });
    }
    if (`${newTop}px` !== fromTop) {
      changes.push({
        property: 'top',
        fromValue: fromTop,
        toValue: `${newTop}px`,
        unit: 'px',
      });
    }

    if (changes.length > 0) {
      this.currentOnCommit?.(changes);
    }

    this.dragging = false;
    this.axisLock = 'none';
    this.positionBadge?.remove();
    this.positionBadge = null;

    this.refreshOverlay();
  }

  private cancelDrag(): void {
    if (this.dragging) {
      this.preview.revert();
      this.dragging = false;
      this.axisLock = 'none';
      this.positionBadge?.remove();
      this.positionBadge = null;
    }
  }

  // -----------------------------------------------------------------------
  // Position badge
  // -----------------------------------------------------------------------

  private showPositionBadge(left: number, top: number): void {
    this.positionBadge?.remove();

    this.positionBadge = createElement('div', {}, {
      position: 'fixed',
      bottom: '48px',
      left: '50%',
      transform: 'translateX(-50%)',
      background: OVERLAY.bg,
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusSm,
      padding: '4px 10px',
      fontFamily: OVERLAY.monoFamily,
      fontSize: '11px',
      color: OVERLAY.text,
      pointerEvents: 'none',
      zIndex: '200',
      whiteSpace: 'nowrap',
      boxShadow: OVERLAY.shadowMd,
    });
    this.positionBadge.textContent = `left: ${Math.round(left)}px  top: ${Math.round(top)}px`;
    this.shadow.appendChild(this.positionBadge);
  }

  private updatePositionBadge(left: number, top: number): void {
    if (!this.positionBadge) return;
    this.positionBadge.textContent = `left: ${Math.round(left)}px  top: ${Math.round(top)}px`;
  }
}

// ---------------------------------------------------------------------------
// Block reason
// ---------------------------------------------------------------------------

/**
 * Check if an element's position prevents drag-to-move.
 * Returns a reason string if blocked, null if movable.
 */
export function getMoveBlockReason(element: Element): string | null {
  const position = getComputedStyle(element).position;
  if (position === 'static') {
    return 'Element has position: static \u2014 set to relative, absolute, or fixed first';
  }
  if (position === 'sticky') {
    return 'Element has position: sticky \u2014 move is not supported for sticky elements';
  }
  return null;
}
