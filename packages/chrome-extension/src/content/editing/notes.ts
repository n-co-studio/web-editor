import type { NoteElementRef, NoteEntry } from '@frontend-editor/shared';
import { createElement, createText, createButton, makeDraggable } from '../../shared/ui-utils';
import { OVERLAY, TOOLBAR_WIDTH, NOTES_PANEL_MAX_HEIGHT, NOTES_PANEL_WIDTH } from '../../shared/constants';
import type { PanelPosition } from '../../shared/types';
import type { NotesStore } from '../batching/notes-store';

type NotePositionMode = 'toolbar' | 'element' | 'detached';

/**
 * Notes editing mini-panel. Renders a text input for adding notes,
 * a scrollable list of existing notes with element pills, and
 * pick mode for attaching DOM elements to notes.
 */
export class NotesEditor {
  private container: HTMLDivElement | null = null;
  private closeCb: (() => void) | null = null;
  private pickCb: ((noteIndex: number) => void) | null = null;
  private addSelectedCb: ((noteIndex: number) => void) | null = null;
  private hasSelectedCb: (() => boolean) | null = null;
  private listEl: HTMLDivElement | null = null;
  private highlights = new Map<string, HTMLDivElement>();
  private activePickIndex: number | null = null;
  private positionMode: NotePositionMode = 'toolbar';
  private anchoredElement: Element | null = null;
  private anchoredElementRef: NoteElementRef | null = null;
  private resizeObserver: ResizeObserver | null = null;

  constructor(
    private readonly notesStore: NotesStore,
    private readonly shadow: ShadowRoot,
  ) {
    notesStore.onChange(() => {
      this.refreshList();
      this.rebuildHighlights();
    });
  }

  onClose(cb: () => void): void {
    this.closeCb = cb;
  }

  /** Register callback for when user clicks "+ Ref" to enter pick mode. */
  onStartPick(cb: (noteIndex: number) => void): void {
    this.pickCb = cb;
  }

  /** Register callback for when user clicks "+ Selected" to add current selection. */
  onAddSelected(cb: (noteIndex: number) => void): void {
    this.addSelectedCb = cb;
  }

  /** Register callback to check if there's a current selection. */
  setHasSelection(cb: () => boolean): void {
    this.hasSelectedCb = cb;
  }

  /** Update pick mode active state (called from index.ts). */
  setPickActive(noteIndex: number | null): void {
    this.activePickIndex = noteIndex;
    this.refreshList();
  }

  /** Return current positioning mode for external guards. */
  getPositionMode(): NotePositionMode {
    return this.positionMode;
  }

  /** Set the element to anchor to. Called from index.ts before render(). */
  setAnchoredElement(element: Element, ref: NoteElementRef): void {
    this.anchoredElement = element;
    this.anchoredElementRef = ref;
  }

  /** Clear element anchor (transitions to toolbar mode). */
  clearAnchoredElement(): void {
    this.disconnectResizeObserver();
    this.anchoredElement = null;
    this.anchoredElementRef = null;
    this.positionMode = 'toolbar';
  }

  /** Reposition panel to track the anchored element. Called from scroll handler. */
  repositionToElement(): void {
    if (!this.container || !this.anchoredElement || this.positionMode !== 'element') return;
    if (!document.contains(this.anchoredElement)) {
      this.clearAnchoredElement();
      return;
    }
    const rect = this.anchoredElement.getBoundingClientRect();
    const pos = computeElementAnchoredPosition(rect, NOTES_PANEL_WIDTH, NOTES_PANEL_MAX_HEIGHT);
    this.container.style.left = `${pos.x}px`;
    this.container.style.top = `${pos.y}px`;
  }

  render(anchorPos: { x: number; y: number }): HTMLDivElement {
    // Save anchoring state before cleanup (which resets it)
    const savedElement = this.anchoredElement;
    const savedRef = this.anchoredElementRef;
    this.cleanup();
    this.anchoredElement = savedElement;
    this.anchoredElementRef = savedRef;

    let panelLeft: number;
    let panelTop: number;

    if (this.anchoredElement && document.contains(this.anchoredElement)) {
      this.positionMode = 'element';
      const rect = this.anchoredElement.getBoundingClientRect();
      const pos = computeElementAnchoredPosition(rect, NOTES_PANEL_WIDTH, NOTES_PANEL_MAX_HEIGHT);
      panelLeft = pos.x;
      panelTop = pos.y;
    } else {
      this.positionMode = 'toolbar';
      this.anchoredElement = null;
      this.anchoredElementRef = null;
      panelLeft = Math.min(
        anchorPos.x + TOOLBAR_WIDTH + 8,
        window.innerWidth - (NOTES_PANEL_WIDTH + 8),
      );
      panelTop = Math.max(8, anchorPos.y);
    }

    const container = createElement('div', {
      role: 'dialog',
      'aria-label': 'Session notes',
    }, {
      position: 'fixed',
      left: `${panelLeft}px`,
      top: `${panelTop}px`,
      width: `${NOTES_PANEL_WIDTH}px`,
      maxHeight: `${NOTES_PANEL_MAX_HEIGHT}px`,
      background: OVERLAY.bg,
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusMd,
      boxShadow: OVERLAY.shadowLg,
      pointerEvents: 'auto',
      zIndex: '102',
      fontFamily: OVERLAY.fontFamily,
      overflow: 'hidden',
      display: 'flex',
      flexDirection: 'column',
    });

    // Header
    const header = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
      padding: '6px 10px',
      borderBottom: `1px solid ${OVERLAY.border}`,
      flexShrink: '0',
    });
    const title = createText('span', 'Notes', 'heading');
    title.style.fontSize = '12px';
    header.appendChild(title);

    const closeBtn = createButton('\u00d7', 'ghost', () => {
      this.cleanup();
      this.closeCb?.();
    });
    closeBtn.style.padding = '2px 6px';
    closeBtn.style.fontSize = '14px';
    header.appendChild(closeBtn);
    container.appendChild(header);

    // Make panel draggable via header
    makeDraggable(header, container, undefined, () => {
      if (this.positionMode !== 'detached') {
        this.positionMode = 'detached';
        this.disconnectResizeObserver();
        this.anchoredElement = null;
      }
    });

    // Input row
    const inputRow = createElement('div', {}, {
      display: 'flex',
      gap: '4px',
      padding: '8px 10px',
      borderBottom: `1px solid ${OVERLAY.border}`,
      flexShrink: '0',
    });

    const input = createElement('input', {
      type: 'text',
      placeholder: 'Add a note for Claude Code\u2026',
    }, {
      flex: '1',
      background: 'rgba(255, 255, 255, 0.1)',
      color: OVERLAY.text,
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusSm,
      padding: '4px 8px',
      fontSize: OVERLAY.bodySize,
      fontFamily: OVERLAY.fontFamily,
      pointerEvents: 'auto',
      outline: 'none',
      minWidth: '0',
    }) as HTMLInputElement;

    const addNote = () => {
      const value = input.value.trim();
      if (value) {
        this.notesStore.add(value);
        // Auto-assign the anchored element to the newly created note
        if (this.anchoredElementRef) {
          const noteIndex = this.notesStore.count - 1;
          this.notesStore.addElementToNote(noteIndex, this.anchoredElementRef);
        }
        input.value = '';
      }
    };

    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        e.stopPropagation();
        addNote();
      }
    });

    const addBtn = createButton('+', 'ghost', addNote);
    addBtn.style.padding = '4px 8px';
    addBtn.style.fontSize = '14px';
    addBtn.style.flexShrink = '0';
    inputRow.appendChild(input);
    inputRow.appendChild(addBtn);
    container.appendChild(inputRow);

    // Notes list (scrollable)
    this.listEl = createElement('div', {}, {
      flex: '1',
      overflowY: 'auto',
      padding: '4px 0',
    });
    this.renderNotesList();
    container.appendChild(this.listEl);

    this.container = container;
    if (this.positionMode === 'element') {
      this.connectResizeObserver();
    }
    this.rebuildHighlights();
    return container;
  }

  reposition(anchorPos: { x: number; y: number }): void {
    if (!this.container || this.positionMode !== 'toolbar') return;
    const panelLeft = Math.min(
      anchorPos.x + TOOLBAR_WIDTH + 8,
      window.innerWidth - (NOTES_PANEL_WIDTH + 8),
    );
    const panelTop = Math.max(8, anchorPos.y);
    this.container.style.left = `${panelLeft}px`;
    this.container.style.top = `${panelTop}px`;
  }

  cleanup(): void {
    this.container?.remove();
    this.container = null;
    this.listEl = null;
    this.activePickIndex = null;
    this.disconnectResizeObserver();
    this.anchoredElement = null;
    this.anchoredElementRef = null;
    this.positionMode = 'toolbar';
    this.clearHighlights();
  }

  isOpen(): boolean {
    return this.container !== null;
  }

  getContainerElement(): HTMLDivElement | null {
    return this.container;
  }

  /** Re-resolve selectors and reposition highlights (call on scroll). */
  refreshHighlights(): void {
    for (const [selector, div] of this.highlights) {
      const el = document.querySelector(selector);
      if (!el) {
        div.remove();
        this.highlights.delete(selector);
        continue;
      }
      const rect = el.getBoundingClientRect();
      div.style.left = `${rect.left}px`;
      div.style.top = `${rect.top}px`;
      div.style.width = `${rect.width}px`;
      div.style.height = `${rect.height}px`;
    }
  }

  /** Remove all highlight overlays. */
  clearHighlights(): void {
    for (const div of this.highlights.values()) {
      div.remove();
    }
    this.highlights.clear();
  }

  // -----------------------------------------------------------------------
  // ResizeObserver lifecycle
  // -----------------------------------------------------------------------

  private connectResizeObserver(): void {
    if (!this.anchoredElement) return;
    this.disconnectResizeObserver();
    this.resizeObserver = new ResizeObserver(() => {
      this.repositionToElement();
    });
    this.resizeObserver.observe(this.anchoredElement);
  }

  private disconnectResizeObserver(): void {
    if (this.resizeObserver) {
      this.resizeObserver.disconnect();
      this.resizeObserver = null;
    }
  }

  // -----------------------------------------------------------------------
  // List rendering
  // -----------------------------------------------------------------------

  private refreshList(): void {
    if (!this.listEl) return;
    this.renderNotesList();
  }

  private renderNotesList(): void {
    if (!this.listEl) return;
    this.listEl.innerHTML = '';

    const notes = this.notesStore.getAll();

    if (notes.length === 0) {
      const empty = createText('div', 'No notes yet', 'body');
      empty.style.padding = '12px 10px';
      empty.style.color = OVERLAY.textMuted;
      empty.style.textAlign = 'center';
      this.listEl.appendChild(empty);
      return;
    }

    for (let i = 0; i < notes.length; i++) {
      this.listEl.appendChild(this.renderNoteRow(notes[i], i));
    }
  }

  private renderNoteRow(note: NoteEntry, index: number): HTMLDivElement {
    const hasElements = note.elements.length > 0;

    const row = createElement('div', {}, {
      padding: '4px 10px',
      borderLeft: hasElements ? '2px solid rgba(6, 182, 212, 0.4)' : '2px solid transparent',
    });

    // Top line: number + text + delete button
    const topLine = createElement('div', {}, {
      display: 'flex',
      alignItems: 'flex-start',
      gap: '6px',
    });

    const num = createText('span', `${index + 1}.`, 'mono');
    num.style.color = OVERLAY.textMuted;
    num.style.flexShrink = '0';
    num.style.fontSize = '10px';
    num.style.marginTop = '2px';
    topLine.appendChild(num);

    const text = createText('span', note.text, 'body');
    text.style.flex = '1';
    text.style.fontSize = '11px';
    text.style.lineHeight = '1.4';
    text.style.wordBreak = 'break-word';
    topLine.appendChild(text);

    const delBtn = createElement('button', {
      title: 'Remove note',
      'aria-label': `Remove note ${index + 1}`,
    }, {
      background: 'none',
      border: 'none',
      color: OVERLAY.textMuted,
      cursor: 'pointer',
      padding: '0 2px',
      fontSize: '11px',
      flexShrink: '0',
      pointerEvents: 'auto',
      lineHeight: '1',
    }) as HTMLButtonElement;
    delBtn.textContent = '\u00d7';
    delBtn.addEventListener('click', () => {
      this.notesStore.remove(index);
    });
    topLine.appendChild(delBtn);
    row.appendChild(topLine);

    // Element pills (if any)
    if (hasElements) {
      const pillRow = createElement('div', {}, {
        display: 'flex',
        gap: '3px',
        overflowX: 'auto',
        overflowY: 'hidden',
        padding: '3px 0 2px 16px',
      });

      for (let ei = 0; ei < note.elements.length; ei++) {
        pillRow.appendChild(this.renderPill(note.elements[ei], index, ei));
      }

      row.appendChild(pillRow);
    }

    // Action row: + Ref, + Selected
    const actionRow = createElement('div', {}, {
      display: 'flex',
      gap: '4px',
      padding: '2px 0 0 16px',
    });

    const isPicking = this.activePickIndex === index;
    const refBtn = createElement('button', {
      title: 'Click to point at an element on the page \u2014 it will be attached to this note as context for Claude',
      'aria-pressed': isPicking ? 'true' : 'false',
    }, {
      background: isPicking ? OVERLAY.primary : 'rgba(255, 255, 255, 0.08)',
      color: isPicking ? '#fff' : OVERLAY.textMuted,
      border: `1px solid ${isPicking ? OVERLAY.primary : OVERLAY.border}`,
      borderRadius: OVERLAY.radiusSm,
      padding: '1px 6px',
      fontSize: '9px',
      fontFamily: OVERLAY.fontFamily,
      cursor: 'pointer',
      pointerEvents: 'auto',
    }) as HTMLButtonElement;
    refBtn.textContent = '+ Ref';
    refBtn.addEventListener('click', () => {
      this.pickCb?.(index);
    });
    actionRow.appendChild(refBtn);

    // + Selected button (only if something is selected)
    if (this.hasSelectedCb?.()) {
      const selBtn = createElement('button', {
        title: 'Add the currently selected element(s) to this note',
      }, {
        background: 'rgba(255, 255, 255, 0.08)',
        color: OVERLAY.textMuted,
        border: `1px solid ${OVERLAY.border}`,
        borderRadius: OVERLAY.radiusSm,
        padding: '1px 6px',
        fontSize: '9px',
        fontFamily: OVERLAY.fontFamily,
        cursor: 'pointer',
        pointerEvents: 'auto',
      }) as HTMLButtonElement;
      selBtn.textContent = '+ Selected';
      selBtn.addEventListener('click', () => {
        this.addSelectedCb?.(index);
      });
      actionRow.appendChild(selBtn);
    }

    row.appendChild(actionRow);
    return row;
  }

  private renderPill(
    ref: NoteElementRef,
    noteIndex: number,
    elementIndex: number,
  ): HTMLDivElement {
    const label = getPillLabel(ref);

    const pill = createElement('div', {
      title: ref.selector,
      'aria-label': `Remove ${ref.tagName} reference from note`,
    }, {
      display: 'flex',
      alignItems: 'center',
      gap: '2px',
      background: 'rgba(6, 182, 212, 0.15)',
      border: `1px solid ${OVERLAY.primary}`,
      borderRadius: '3px',
      padding: '1px 4px',
      maxWidth: '70px',
      flexShrink: '0',
      cursor: 'default',
    });

    const text = createText('span', label, 'mono');
    text.style.fontSize = '9px';
    text.style.overflow = 'hidden';
    text.style.textOverflow = 'ellipsis';
    text.style.whiteSpace = 'nowrap';
    pill.appendChild(text);

    const removeBtn = createElement('button', {
      'aria-label': `Remove ${ref.tagName} reference from note`,
    }, {
      background: 'none',
      border: 'none',
      color: OVERLAY.textMuted,
      cursor: 'pointer',
      padding: '0 1px',
      fontSize: '9px',
      lineHeight: '1',
      flexShrink: '0',
      pointerEvents: 'auto',
    }) as HTMLButtonElement;
    removeBtn.textContent = '\u00d7';
    removeBtn.addEventListener('click', () => {
      this.notesStore.removeElementFromNote(noteIndex, elementIndex);
    });
    pill.appendChild(removeBtn);

    return pill;
  }

  // -----------------------------------------------------------------------
  // Highlights
  // -----------------------------------------------------------------------

  private rebuildHighlights(): void {
    this.clearHighlights();
    if (!this.container) return;

    const notes = this.notesStore.getAll();
    const selectors = new Set<string>();

    for (const note of notes) {
      for (const ref of note.elements) {
        selectors.add(ref.selector);
      }
    }

    for (const selector of selectors) {
      const el = document.querySelector(selector);
      if (!el) continue;

      const rect = el.getBoundingClientRect();
      const highlight = createElement('div', { 'aria-hidden': 'true' }, {
        position: 'fixed',
        left: `${rect.left}px`,
        top: `${rect.top}px`,
        width: `${rect.width}px`,
        height: `${rect.height}px`,
        border: `1px dashed ${OVERLAY.primary}`,
        background: 'rgba(6, 182, 212, 0.05)',
        pointerEvents: 'none',
        zIndex: '2',
        borderRadius: '1px',
      });
      this.shadow.appendChild(highlight);
      this.highlights.set(selector, highlight);
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Build a short pill label from a NoteElementRef. */
function getPillLabel(ref: NoteElementRef): string {
  // Priority: textContent > #id > .class > selector tail
  if (ref.textContent) {
    return ref.textContent.slice(0, 12);
  }
  const idMatch = ref.selector.match(/#([\w-]+)/);
  if (idMatch) {
    return `#${idMatch[1].slice(0, 10)}`;
  }
  const classMatch = ref.selector.match(/\.([\w-]+)/);
  if (classMatch) {
    return `.${classMatch[1].slice(0, 10)}`;
  }
  // Last segment of selector
  const parts = ref.selector.split(/\s*>\s*/);
  return parts[parts.length - 1].slice(0, 16);
}

/**
 * Compute fixed-position coordinates for element-anchored placement.
 *
 * Strategy:
 *   1. Element height >= panelMaxHeight → INSET at top-left + offset
 *   2. Element height < panelMaxHeight → BELOW bottom-left + offset
 *   3. Always clamp to keep panel fully within viewport
 */
function computeElementAnchoredPosition(
  elementRect: DOMRect,
  panelWidth: number,
  panelMaxHeight: number,
): PanelPosition {
  const OFFSET = 8;
  const vw = window.innerWidth;
  const vh = window.innerHeight;

  let x: number;
  let y: number;

  if (elementRect.height >= panelMaxHeight) {
    // Inset: top-left corner of element, offset inward
    x = elementRect.left + OFFSET;
    y = elementRect.top + OFFSET;
  } else {
    // Below: under element's bottom-left corner
    x = elementRect.left;
    y = elementRect.bottom + OFFSET;
  }

  // Clamp to viewport (8px padding from edges)
  x = Math.max(OFFSET, Math.min(x, vw - panelWidth - OFFSET));
  y = Math.max(OFFSET, Math.min(y, vh - panelMaxHeight - OFFSET));

  return { x, y };
}
