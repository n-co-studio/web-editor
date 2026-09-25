/**
 * ReorderPanel — toolbar-anchored drag-to-reorder list for the Reorder tool.
 *
 * Lists a container's direct element children as a flat vertical list, one row
 * per child (drag handle + label + 1-indexed position, plus a 16px thumbnail
 * when the child resolves to an asset). Dragging a row (pointer-capture, the
 * repo convention — not HTML5 DnD) or pressing Shift+Arrow on a focused row
 * emits exactly one `(fromIndex, toIndex)` move through the supplied commit
 * callback → `ReorderEditor.commitFromIndex` → the existing `ReorderChange`
 * pipeline. The panel never moves DOM itself.
 *
 * Complements the in-place drag reorder; both surfaces are kept in sync by the
 * caller re-rendering the panel after every commit / undo / redo.
 *
 * All styling is inline (Shadow DOM isolation — no external CSS).
 */

import { createElement } from '../../shared/ui-utils';
import {
  OVERLAY,
  DROP_INDICATOR,
  HANDLE_COLORS,
  TOOLBAR_WIDTH,
  TEXT_CONTENT_TRUNCATE_LENGTH,
} from '../../shared/constants';
import { getReorderBlockReason } from './reorder';
import type { SiblingAnchor } from '@nco-studio/shared';

// ---------------------------------------------------------------------------
// Layout constants
// ---------------------------------------------------------------------------

const PANEL_WIDTH = 224;
const PANEL_MAX_HEIGHT = 360;
const LABEL_MAX_LENGTH = 32;

type CommitCallback = (fromIndex: number, toIndex: number) => void;

// ---------------------------------------------------------------------------
// ReorderPanel
// ---------------------------------------------------------------------------

export class ReorderPanel {
  // --- DOM refs ---
  private container: HTMLDivElement | null = null;
  private listEl: HTMLDivElement | null = null;
  private dropIndicator: HTMLDivElement | null = null;
  /** Persistent, visually-hidden live region — survives re-render so screen
   *  readers announce successive moves against one stable node. */
  private liveRegion: HTMLDivElement | null = null;

  // --- Per-render data ---
  private childEls: HTMLElement[] = [];
  private anchors: readonly SiblingAnchor[] = [];
  private rowEls: HTMLDivElement[] = [];
  private onCommit: CommitCallback | null = null;
  private selectedEl: HTMLElement | null = null;
  private userDragged = false;

  // --- Drag state ---
  private draggingIndex = -1;
  private dropGap = -1;
  private dragHandle: HTMLElement | null = null;
  private boundDragMove: ((e: PointerEvent) => void) | null = null;
  private boundDragUp: ((e: PointerEvent) => void) | null = null;
  private boundDragKey: ((e: KeyboardEvent) => void) | null = null;

  // --- Deferred UI continuity (applied on the next render) ---
  private pendingFocusUid: string | null = null;
  private pendingAnnouncement: string | null = null;

  constructor(private readonly shadow: ShadowRoot) {}

  // -------------------------------------------------------------------------
  // Public API
  // -------------------------------------------------------------------------

  /**
   * Render the panel for `container`, listing `anchors` (one per element child,
   * index-aligned with the container's element children). `onCommit(from,to)`
   * fires exactly once per drag / keyboard move. `anchorPos` is the reorder
   * toolbar button position (`toolbar.getButtonPosition('reorder')`).
   */
  render(
    container: HTMLElement,
    anchors: readonly SiblingAnchor[],
    onCommit: CommitCallback,
    anchorPos: { x: number; y: number },
  ): void {
    this.cleanup();

    this.anchors = anchors;
    this.onCommit = onCommit;
    // Element-only children, filtered identically to the reorder editor's
    // snapshot so row indices line up 1:1 with the anchors and commit indices.
    this.childEls = Array.from(container.children).filter(
      (c): c is HTMLElement => c instanceof HTMLElement,
    );

    const panel = this.buildPanelShell(anchorPos);

    // A single non-reorderable child, or a blocked container, gets a short
    // message instead of a drag list (blocked/empty state).
    const blockReason = this.blockReason(container);
    if (blockReason) {
      panel.appendChild(this.buildMessage(blockReason));
    } else {
      panel.appendChild(this.buildList());
    }

    this.container = panel;
    this.shadow.appendChild(panel);

    this.ensureLiveRegion();
    if (this.pendingAnnouncement) {
      this.announce(this.pendingAnnouncement);
      this.pendingAnnouncement = null;
    }
    if (this.pendingFocusUid) {
      this.focusRowByUid(this.pendingFocusUid);
      this.pendingFocusUid = null;
    }
  }

  /** Highlight the row for the currently-selected child (by element identity). */
  highlight(el: HTMLElement | null): void {
    this.selectedEl = el;
    for (let i = 0; i < this.rowEls.length; i++) {
      this.paintRow(this.rowEls[i], i, this.childEls[i] === el && el !== null);
    }
  }

  /** Reposition next to the toolbar's reorder button on toolbar drag. */
  reposition(anchorPos: { x: number; y: number }): void {
    if (!this.container || this.userDragged) return;
    const { left, top } = this.computePosition(anchorPos);
    this.container.style.left = `${left}px`;
    this.container.style.top = `${top}px`;
  }

  /** Remove the panel DOM (drag list + indicator). Keeps the live region. */
  cleanup(): void {
    this.endDrag(true);
    this.container?.remove();
    this.container = null;
    this.listEl = null;
    this.dropIndicator = null;
    this.rowEls = [];
    this.childEls = [];
    this.anchors = [];
    this.onCommit = null;
    this.userDragged = false;
  }

  // -------------------------------------------------------------------------
  // Shell + positioning
  // -------------------------------------------------------------------------

  private computePosition(anchorPos: { x: number; y: number }): {
    left: number;
    top: number;
  } {
    // Anchored to the LEFT, next to the toolbar (matches the other mini-panels);
    // never right-docked — the right edge is owned by the review panel.
    const left = Math.min(
      anchorPos.x + TOOLBAR_WIDTH + 8,
      window.innerWidth - PANEL_WIDTH - 8,
    );
    const top = Math.max(
      8,
      Math.min(anchorPos.y, window.innerHeight - PANEL_MAX_HEIGHT - 8),
    );
    return { left, top };
  }

  private buildPanelShell(anchorPos: { x: number; y: number }): HTMLDivElement {
    const { left, top } = this.computePosition(anchorPos);

    const panel = createElement(
      'div',
      { role: 'dialog', 'aria-label': 'Reorder children' },
      {
        position: 'fixed',
        left: `${left}px`,
        top: `${top}px`,
        width: `${PANEL_WIDTH}px`,
        maxHeight: `${PANEL_MAX_HEIGHT}px`,
        background: OVERLAY.bg,
        border: `1px solid ${OVERLAY.border}`,
        borderRadius: OVERLAY.radiusMd,
        boxShadow: OVERLAY.shadowLg,
        fontFamily: OVERLAY.fontFamily,
        color: OVERLAY.text,
        pointerEvents: 'auto',
        zIndex: '102',
        display: 'flex',
        flexDirection: 'column',
        overflow: 'hidden',
      },
    );

    // Keep panel interaction out of the host page's selection system — a leaked
    // pointerdown would trip the SelectionManager deselect→reselect cycle and
    // tear down the active reorder tool.
    for (const type of ['pointerdown', 'mousedown', 'click'] as const) {
      panel.addEventListener(type, (e) => e.stopPropagation());
    }

    panel.appendChild(this.buildHeader());
    return panel;
  }

  private buildHeader(): HTMLDivElement {
    const header = createElement(
      'div',
      {},
      {
        flexShrink: '0',
        display: 'flex',
        alignItems: 'center',
        gap: '6px',
        padding: '6px 10px',
        borderBottom: `1px solid ${OVERLAY.border}`,
        cursor: 'grab',
      },
    );

    const dot = createElement('div', {}, {
      width: '6px',
      height: '6px',
      borderRadius: '50%',
      background: HANDLE_COLORS.reorder,
      flexShrink: '0',
    });
    header.appendChild(dot);

    const title = createElement('span', {}, {
      fontSize: '12px',
      fontWeight: '600',
      color: OVERLAY.text,
    });
    title.textContent = 'Reorder';
    header.appendChild(title);

    const count = createElement('span', {}, {
      marginLeft: 'auto',
      fontFamily: OVERLAY.monoFamily,
      fontSize: '10px',
      color: OVERLAY.textMuted,
    });
    count.textContent = `${this.childEls.length}`;
    header.appendChild(count);

    this.makeHeaderDraggable(header);
    return header;
  }

  private buildMessage(text: string): HTMLDivElement {
    const msg = createElement('div', {}, {
      padding: '14px 12px',
      fontSize: '11px',
      lineHeight: '1.5',
      color: OVERLAY.textMuted,
      textAlign: 'center',
    });
    msg.textContent = text;
    return msg;
  }

  /**
   * Returns a short blocked/empty message when the container should not present
   * a drag list, or null when a list is appropriate. Fewer than 2 element
   * children (nothing to reorder) and any active reorder block both qualify.
   */
  private blockReason(container: HTMLElement): string | null {
    if (this.childEls.length < 2) {
      return 'Only one item here — nothing to reorder.';
    }
    // Probe the block guard against the first child (the guard inspects the
    // parent container's layout, so any child is representative).
    const reason = getReorderBlockReason(this.childEls[0]);
    if (reason && !/only child/i.test(reason)) {
      return `Can't reorder: ${reason.toLowerCase()}.`;
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // List + rows
  // -------------------------------------------------------------------------

  private buildList(): HTMLDivElement {
    const list = createElement(
      'div',
      { role: 'list', 'aria-label': 'Reorderable children' },
      {
        position: 'relative',
        flex: '1',
        overflowY: 'auto',
        padding: '6px',
        display: 'flex',
        flexDirection: 'column',
        gap: '3px',
      },
    );

    this.rowEls = [];
    for (let i = 0; i < this.childEls.length; i++) {
      const row = this.buildRow(i);
      this.rowEls.push(row);
      list.appendChild(row);
    }

    // Absolutely-positioned drop indicator line (hidden until a drag starts).
    this.dropIndicator = createElement('div', {}, {
      position: 'absolute',
      left: '6px',
      right: '6px',
      height: `${DROP_INDICATOR.activeThickness}px`,
      borderRadius: '1px',
      background: DROP_INDICATOR.activeColor,
      boxShadow: `0 0 4px ${DROP_INDICATOR.activeColor}`,
      pointerEvents: 'none',
      display: 'none',
      zIndex: '1',
    });
    list.appendChild(this.dropIndicator);

    this.listEl = list;
    return list;
  }

  private buildRow(index: number): HTMLDivElement {
    const anchor = this.anchors[index];
    const el = this.childEls[index];
    const isSelected = el === this.selectedEl && this.selectedEl !== null;

    const row = createElement(
      'div',
      {
        role: 'listitem',
        tabindex: '0',
        'aria-posinset': String(index + 1),
        'aria-setsize': String(this.childEls.length),
        'aria-label': `${this.rowText(el, anchor, index)}, position ${index + 1} of ${this.childEls.length}. Shift plus arrow keys to move.`,
      },
      {
        display: 'flex',
        alignItems: 'center',
        gap: '7px',
        padding: '5px 7px',
        borderRadius: OVERLAY.radiusSm,
        outline: 'none',
        cursor: 'default',
        userSelect: 'none',
      },
    );
    this.paintRow(row, index, isSelected);

    // Drag handle (grip) — the only pointer-drag affordance.
    const handle = createElement('div', { 'aria-hidden': 'true' }, {
      flexShrink: '0',
      width: '12px',
      textAlign: 'center',
      fontFamily: OVERLAY.monoFamily,
      fontSize: '13px',
      lineHeight: '1',
      color: OVERLAY.textMuted,
      cursor: 'grab',
      touchAction: 'none',
    });
    handle.textContent = '⋮⋮'; // ⋮⋮
    handle.addEventListener('pointerdown', (e) => this.onHandlePointerDown(e, index));
    row.appendChild(handle);

    // Optional 16px thumbnail for asset-backed children.
    if (anchor?.assetPath) {
      const thumb = createElement('img', { src: anchor.assetPath, alt: '' }, {
        flexShrink: '0',
        width: '16px',
        height: '16px',
        objectFit: 'cover',
        borderRadius: '2px',
        background: OVERLAY.hover,
      }) as HTMLImageElement;
      // Broken/unreachable asset → degrade to label-only.
      thumb.addEventListener('error', () => thumb.remove());
      row.appendChild(thumb);
    } else {
      // Muted mono <tag> chip keeps generic / duplicate / empty labels distinct.
      const tag = createElement('span', {}, {
        flexShrink: '0',
        fontFamily: OVERLAY.monoFamily,
        fontSize: '9px',
        color: OVERLAY.textMuted,
        opacity: '0.85',
      });
      tag.textContent = `<${el.tagName.toLowerCase()}>`;
      row.appendChild(tag);
    }

    // Label (flex, ellipsized).
    const label = createElement('span', {}, {
      flex: '1',
      minWidth: '0',
      overflow: 'hidden',
      textOverflow: 'ellipsis',
      whiteSpace: 'nowrap',
      fontSize: '11px',
    });
    label.textContent = this.rowText(el, anchor, index);
    row.appendChild(label);

    // 1-indexed position.
    const pos = createElement('span', {}, {
      flexShrink: '0',
      fontFamily: OVERLAY.monoFamily,
      fontSize: '10px',
      color: OVERLAY.textMuted,
    });
    pos.textContent = String(index + 1);
    row.appendChild(pos);

    row.addEventListener('keydown', (e) => this.onRowKeyDown(e, index));
    return row;
  }

  /** Apply base / selected / dragging visuals to a row. */
  private paintRow(row: HTMLDivElement, index: number, isSelected: boolean): void {
    const dragging = index === this.draggingIndex;
    row.style.background = isSelected
      ? `${HANDLE_COLORS.reorder}22`
      : 'transparent';
    row.style.border = `1px solid ${
      isSelected ? HANDLE_COLORS.reorder : 'transparent'
    }`;
    row.style.opacity = dragging ? '0.4' : '1';
  }

  /**
   * Row label: the anchor's asset label when present, else aria-label, else
   * truncated text content, else the 1-indexed position. `buildSiblingAnchor`
   * only sets `label` for asset-backed elements, so the fallback is mandatory.
   */
  private rowText(el: HTMLElement, anchor: SiblingAnchor | undefined, index: number): string {
    if (anchor?.assetPath && anchor.label) return anchor.label;

    const aria = el.getAttribute('aria-label');
    if (aria && aria.trim()) return truncate(aria.trim(), LABEL_MAX_LENGTH);

    const text = (el.textContent ?? '').replace(/\s+/g, ' ').trim();
    if (text) return truncate(text, LABEL_MAX_LENGTH);

    return `#${index + 1}`;
  }

  // -------------------------------------------------------------------------
  // Pointer drag
  // -------------------------------------------------------------------------

  private onHandlePointerDown(e: PointerEvent, index: number): void {
    if (!this.onCommit || this.draggingIndex !== -1) return;
    e.preventDefault();
    e.stopPropagation();

    const handle = e.currentTarget as HTMLElement;
    handle.setPointerCapture(e.pointerId);
    handle.style.cursor = 'grabbing';

    this.dragHandle = handle;
    this.draggingIndex = index;
    this.dropGap = index;
    this.paintRow(this.rowEls[index], index, this.childEls[index] === this.selectedEl);

    this.boundDragMove = (ev) => this.onDragMove(ev);
    this.boundDragUp = (ev) => this.onDragUp(ev, handle);
    this.boundDragKey = (ev) => {
      // Escape aborts the drag and reverts the preview.
      if (ev.key === 'Escape') {
        ev.preventDefault();
        try { handle.releasePointerCapture(e.pointerId); } catch { /* released */ }
        this.endDrag(true);
      }
    };
    handle.addEventListener('pointermove', this.boundDragMove);
    handle.addEventListener('pointerup', this.boundDragUp);
    document.addEventListener('keydown', this.boundDragKey, true);

    this.updateDropIndicator(this.dropGap);
  }

  private onDragMove(e: PointerEvent): void {
    if (this.draggingIndex === -1) return;
    const gap = this.hitTestGap(e.clientY);
    if (gap !== this.dropGap) {
      this.dropGap = gap;
      this.updateDropIndicator(gap);
    }
  }

  private onDragUp(e: PointerEvent, handle: HTMLElement): void {
    if (this.draggingIndex === -1) return;
    try { handle.releasePointerCapture(e.pointerId); } catch { /* released */ }
    const from = this.draggingIndex;
    const to = this.dropGap;
    this.endDrag(true);
    // commitFromIndex null-guards no-op moves; the resulting re-render rebuilds
    // this panel in the new order (one drag = one ReorderChange).
    if (to !== from && to !== from + 1) {
      this.stageAnnouncement(from, to);
      this.onCommit?.(from, to);
    }
  }

  /** Nearest insertion gap (0..n) for a pointer Y, from the row midpoints. */
  private hitTestGap(clientY: number): number {
    const n = this.rowEls.length;
    for (let i = 0; i < n; i++) {
      const rect = this.rowEls[i].getBoundingClientRect();
      if (clientY < rect.top + rect.height / 2) return i;
    }
    return n;
  }

  private updateDropIndicator(gap: number): void {
    if (!this.dropIndicator || !this.listEl) return;
    const n = this.rowEls.length;
    let top: number;
    if (gap <= 0) {
      top = this.rowEls[0].offsetTop - 2;
    } else if (gap >= n) {
      const last = this.rowEls[n - 1];
      top = last.offsetTop + last.offsetHeight;
    } else {
      top = this.rowEls[gap].offsetTop - 2;
    }
    this.dropIndicator.style.top = `${top}px`;
    this.dropIndicator.style.display = 'block';
  }

  /** Tear down drag listeners; `revert` clears the preview visuals. */
  private endDrag(revert: boolean): void {
    if (this.boundDragKey) {
      document.removeEventListener('keydown', this.boundDragKey, true);
      this.boundDragKey = null;
    }
    // Symmetric teardown of the handle's pointer listeners (mirrors boundDragKey).
    if (this.dragHandle) {
      if (this.boundDragMove) this.dragHandle.removeEventListener('pointermove', this.boundDragMove);
      if (this.boundDragUp) this.dragHandle.removeEventListener('pointerup', this.boundDragUp);
      this.dragHandle.style.cursor = 'grab';
      this.dragHandle = null;
    }
    const dragged = this.draggingIndex;
    this.boundDragMove = null;
    this.boundDragUp = null;
    this.draggingIndex = -1;
    this.dropGap = -1;

    if (this.dropIndicator) this.dropIndicator.style.display = 'none';
    if (revert && dragged !== -1 && this.rowEls[dragged]) {
      this.paintRow(this.rowEls[dragged], dragged, this.childEls[dragged] === this.selectedEl);
    }
  }

  // -------------------------------------------------------------------------
  // Keyboard reorder
  // -------------------------------------------------------------------------

  private onRowKeyDown(e: KeyboardEvent, index: number): void {
    const n = this.childEls.length;

    // Shift+Arrow moves the focused row one slot via the same commit path.
    if (e.shiftKey && (e.key === 'ArrowUp' || e.key === 'ArrowDown')) {
      e.preventDefault();
      if (e.key === 'ArrowUp' && index > 0) {
        this.keyboardMove(index, index - 1);
      } else if (e.key === 'ArrowDown' && index < n - 1) {
        // Insert-gap two ahead lands the row one slot lower.
        this.keyboardMove(index, index + 2);
      }
      return;
    }

    // Plain Arrow roves focus without moving anything.
    if (e.key === 'ArrowUp' && index > 0) {
      e.preventDefault();
      this.rowEls[index - 1]?.focus();
    } else if (e.key === 'ArrowDown' && index < n - 1) {
      e.preventDefault();
      this.rowEls[index + 1]?.focus();
    }
  }

  private keyboardMove(from: number, to: number): void {
    if (!this.onCommit) return;
    // Keep focus + announce on the moved item across the rebuild.
    this.pendingFocusUid = this.anchors[from]?.uid ?? null;
    this.stageAnnouncement(from, to);
    this.onCommit(from, to);
  }

  // -------------------------------------------------------------------------
  // Accessibility helpers
  // -------------------------------------------------------------------------

  private ensureLiveRegion(): void {
    if (this.liveRegion && this.liveRegion.isConnected) return;
    this.liveRegion = createElement(
      'div',
      { role: 'status', 'aria-live': 'polite', 'aria-atomic': 'true' },
      {
        position: 'absolute',
        width: '1px',
        height: '1px',
        margin: '-1px',
        padding: '0',
        overflow: 'hidden',
        clip: 'rect(0 0 0 0)',
        whiteSpace: 'nowrap',
        border: '0',
      },
    );
    this.shadow.appendChild(this.liveRegion);
  }

  /** Compute where the item lands and defer the announcement to next render. */
  private stageAnnouncement(from: number, to: number): void {
    const el = this.childEls[from];
    if (!el) return;
    const landing = to > from ? to - 1 : to; // resolved 0-based position
    const label = this.rowText(el, this.anchors[from], from);
    this.pendingAnnouncement = `Moved ${label} to position ${landing + 1} of ${this.childEls.length}.`;
  }

  private announce(message: string): void {
    if (this.liveRegion) this.liveRegion.textContent = message;
  }

  private focusRowByUid(uid: string): void {
    const idx = this.anchors.findIndex((a) => a.uid === uid);
    if (idx !== -1) this.rowEls[idx]?.focus();
  }

  // -------------------------------------------------------------------------
  // Dragging the panel by its header
  // -------------------------------------------------------------------------

  private makeHeaderDraggable(header: HTMLElement): void {
    let startX = 0;
    let startY = 0;
    let startLeft = 0;
    let startTop = 0;

    header.addEventListener('pointerdown', (e) => {
      e.preventDefault();
      header.setPointerCapture(e.pointerId);
      header.style.cursor = 'grabbing';
      startX = e.clientX;
      startY = e.clientY;
      const rect = this.container!.getBoundingClientRect();
      startLeft = rect.left;
      startTop = rect.top;
    });
    header.addEventListener('pointermove', (e) => {
      if (!header.hasPointerCapture(e.pointerId) || !this.container) return;
      this.userDragged = true;
      const left = Math.max(
        0,
        Math.min(startLeft + (e.clientX - startX), window.innerWidth - PANEL_WIDTH),
      );
      const top = Math.max(
        0,
        Math.min(startTop + (e.clientY - startY), window.innerHeight - 40),
      );
      this.container.style.left = `${left}px`;
      this.container.style.top = `${top}px`;
    });
    header.addEventListener('pointerup', (e) => {
      if (!header.hasPointerCapture(e.pointerId)) return;
      header.releasePointerCapture(e.pointerId);
      header.style.cursor = 'grab';
    });
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function truncate(text: string, max: number): string {
  const limit = Math.min(max, TEXT_CONTENT_TRUNCATE_LENGTH);
  return text.length > limit ? `${text.slice(0, limit - 1)}…` : text;
}
