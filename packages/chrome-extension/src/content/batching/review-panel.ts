import type { VisualDiff, NoteEntry } from '@nco-studio/shared';
import { createElement, createText, createButton } from '../../shared/ui-utils';
import {
  OVERLAY,
  SELECTOR_TRUNCATE_LENGTH,
  BATCH_CONFIRM_THRESHOLD,
  MAX_DIFFS_PER_BATCH,
  QUEUE_PANEL_DEFAULT_WIDTH,
  QUEUE_PANEL_MIN_WIDTH,
  QUEUE_PANEL_MAX_WIDTH_RATIO,
} from '../../shared/constants';
import type { ConnectionStatus, DiffLifecycle } from '../../shared/types';
import type { PendingQueue } from './queue';
import type { WebSocketClient } from '../websocket-client';
import type { DiffBuilder } from './diff-builder';
import type { NotesStore } from './notes-store';
import { serializeToPrompt } from './prompt-serializer';

type VoidCallback = () => void;

const STORAGE_KEY_WIDTH = 'nco-web-editor-queue-width';

/**
 * Review panel for pending changes. Renders inside the shadow DOM.
 * Docks full-height to the right edge of the viewport (mirroring the
 * bottom-docked DevTools panel), resizable via a left-edge handle with
 * width persisted to chrome.storage.session. Shows changes grouped by
 * element, with individual removal/restore, "Apply Changes" button, and
 * WebSocket status banners.
 */
export class ReviewPanel {
  private container: HTMLDivElement | null = null;
  private visible = false;
  private connectionStatus: ConnectionStatus = 'disconnected';
  private sending = false;
  private closeCb: VoidCallback | null = null;
  private panelWidth = QUEUE_PANEL_DEFAULT_WIDTH;

  constructor(
    private readonly shadow: ShadowRoot,
    private readonly queue: PendingQueue,
    private readonly wsClient: WebSocketClient,
    private readonly diffBuilder: DiffBuilder,
    private readonly notesStore: NotesStore,
    private readonly onHighlightElement?: (selector: string) => void,
  ) {
    // Auto-refresh when queue or notes change
    queue.onChange(() => {
      if (this.visible) this.refresh();
    });
    notesStore.onChange(() => {
      if (this.visible) this.refresh();
    });

    // Restore persisted width (async, non-blocking)
    void this.restoreWidth();
  }

  show(): void {
    this.visible = true;
    this.render();
  }

  hide(): void {
    this.container?.remove();
    this.container = null;
    this.visible = false;
  }

  refresh(): void {
    if (!this.visible) return;
    this.render();
  }

  updateConnectionStatus(status: ConnectionStatus): void {
    this.connectionStatus = status;
    if (this.visible) this.refresh();
  }

  /** Register callback for user-initiated close (× button). */
  onClose(cb: VoidCallback): void {
    this.closeCb = cb;
  }

  isOpen(): boolean {
    return this.visible;
  }

  /** Get the current batch note from the notes store. */
  getSessionNote(): string {
    return this.notesStore.toBatchNote() ?? '';
  }

  // -----------------------------------------------------------------------
  // Width drag + persistence (left-edge resize, mirrors DevTools panel)
  // -----------------------------------------------------------------------

  private clampWidth(width: number): number {
    const max = Math.floor(window.innerWidth * QUEUE_PANEL_MAX_WIDTH_RATIO);
    return Math.max(QUEUE_PANEL_MIN_WIDTH, Math.min(width, Math.max(QUEUE_PANEL_MIN_WIDTH, max)));
  }

  private initWidthDrag(handle: HTMLDivElement, panel: HTMLDivElement): void {
    let startX = 0;
    let startWidth = 0;

    const onPointerDown = (e: PointerEvent) => {
      e.preventDefault();
      handle.setPointerCapture(e.pointerId);
      startX = e.clientX;
      startWidth = this.panelWidth;
    };

    const onPointerMove = (e: PointerEvent) => {
      if (!handle.hasPointerCapture(e.pointerId)) return;
      // Dragging the left edge leftwards (decreasing clientX) widens the panel.
      const dx = startX - e.clientX;
      this.panelWidth = this.clampWidth(startWidth + dx);
      panel.style.width = `${this.panelWidth}px`;
    };

    const onPointerUp = (e: PointerEvent) => {
      if (!handle.hasPointerCapture(e.pointerId)) return;
      handle.releasePointerCapture(e.pointerId);
      void this.saveWidth(this.panelWidth);
    };

    handle.addEventListener('pointerdown', onPointerDown);
    handle.addEventListener('pointermove', onPointerMove);
    handle.addEventListener('pointerup', onPointerUp);
  }

  private async restoreWidth(): Promise<void> {
    try {
      const result = await chrome.storage.session.get([STORAGE_KEY_WIDTH]);
      const saved = result[STORAGE_KEY_WIDTH] as number | undefined;
      if (typeof saved === 'number' && saved >= QUEUE_PANEL_MIN_WIDTH) {
        this.panelWidth = this.clampWidth(saved);
        if (this.visible) this.render();
      }
    } catch {
      // Non-fatal — use default width
    }
  }

  private async saveWidth(width: number): Promise<void> {
    try {
      await chrome.storage.session.set({ [STORAGE_KEY_WIDTH]: width });
    } catch {
      // Non-fatal
    }
  }

  // -----------------------------------------------------------------------
  // Rendering
  // -----------------------------------------------------------------------

  private render(): void {
    this.container?.remove();

    const width = this.clampWidth(this.panelWidth);
    this.panelWidth = width;

    const panel = createElement('div', { role: 'dialog', 'aria-label': 'Change request queue' }, {
      position: 'fixed',
      top: '0',
      right: '0',
      bottom: '0',
      width: `${width}px`,
      overflow: 'hidden',
      background: OVERLAY.bg,
      borderLeft: `1px solid ${OVERLAY.border}`,
      boxShadow: '-4px 0 12px rgba(0, 0, 0, 0.15)',
      pointerEvents: 'auto',
      zIndex: '200',
      fontFamily: OVERLAY.fontFamily,
      display: 'flex',
      flexDirection: 'column',
    });

    // Left-edge resize handle (mirrors the DevTools panel's top handle).
    // Transparent by default; a subtle accent appears on hover so the
    // affordance is discoverable.
    const resizeHandle = createElement('div', { 'aria-hidden': 'true' }, {
      position: 'absolute',
      top: '0',
      left: '0',
      bottom: '0',
      width: '5px',
      cursor: 'ew-resize',
      background: 'transparent',
      zIndex: '2',
    });
    resizeHandle.addEventListener('mouseenter', () => { resizeHandle.style.background = OVERLAY.border; });
    resizeHandle.addEventListener('mouseleave', () => { resizeHandle.style.background = 'transparent'; });
    resizeHandle.title = 'Drag to resize · double-click to reset';
    resizeHandle.addEventListener('dblclick', () => {
      this.panelWidth = QUEUE_PANEL_DEFAULT_WIDTH;
      panel.style.width = `${this.panelWidth}px`;
      void this.saveWidth(this.panelWidth);
    });
    this.initWidthDrag(resizeHandle, panel);
    panel.appendChild(resizeHandle);

    // Header (pinned to the top of the column)
    const header = createElement('div', {}, {
      display: 'flex',
      justifyContent: 'space-between',
      alignItems: 'center',
      padding: '8px 12px',
      borderBottom: `1px solid ${OVERLAY.border}`,
      flexShrink: '0',
    });
    const notes = this.notesStore.getAll();
    const active = this.queue.getActive();
    const sent = this.queue.getSent();
    const applied = this.queue.getApplied();
    const pendingCount = active.length + notes.length;
    const totalCount = pendingCount + sent.length + applied.length;

    const titleColumn = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
    });

    // Title with breakdown
    let titleText = `Changes (${totalCount})`;
    if (sent.length > 0 || applied.length > 0) {
      const parts: string[] = [];
      if (pendingCount > 0) parts.push(`${pendingCount} pending`);
      if (sent.length > 0) parts.push(`${sent.length} sent`);
      if (applied.length > 0) parts.push(`${applied.length} applied`);
      titleText = `Changes (${parts.join(', ')})`;
    }
    const title = createText('span', titleText, 'heading');
    titleColumn.appendChild(title);

    // Elapsed time since oldest pending change
    if (active.length > 0) {
      const oldest = active[0].timestamp;
      const elapsed = formatElapsed(oldest);
      if (elapsed) {
        const subtitle = createText('span', `oldest ${elapsed}`, 'mono');
        subtitle.style.color = OVERLAY.textMuted;
        subtitle.style.marginTop = '1px';
        titleColumn.appendChild(subtitle);
      }
    }
    header.appendChild(titleColumn);

    const closeBtn = createButton('\u00d7', 'ghost', () => {
      this.hide();
      this.closeCb?.();
    });
    closeBtn.style.padding = '2px 6px';
    closeBtn.style.fontSize = '16px';
    header.appendChild(closeBtn);
    panel.appendChild(header);

    // Scrollable body — the only region that scrolls, so the header and the
    // action bar stay pinned in the full-height docked column.
    const body = createElement('div', {}, {
      flex: '1 1 auto',
      minHeight: '0',
      overflowY: 'auto',
    });

    // Connection warning
    if (this.connectionStatus !== 'connected') {
      body.appendChild(this.renderConnectionWarning());
    }

    // Source unverified warning (if any diffs lack sourceVerified)
    const hasUnverified = active.some((d) => !d.sourceVerified);
    if (hasUnverified) {
      body.appendChild(this.renderSourceWarning());
    }

    // Notes as change requests
    for (let i = 0; i < notes.length; i++) {
      body.appendChild(this.renderNoteCard(notes[i], i));
    }

    // Grouped CSS changes (pending)
    const groups = this.groupByElement(active);
    for (const [selector, diffs] of groups) {
      body.appendChild(this.renderGroup(selector, diffs));
    }

    // Sent changes section — grouped by batch (Batch → Element → Property)
    if (sent.length > 0) {
      body.appendChild(this.renderSectionHeader('Sent to Server', sent.length, OVERLAY.warning));
      for (const batchBlock of this.groupByBatch(sent)) {
        body.appendChild(this.renderBatchBlock(batchBlock, 'sent'));
      }
    }

    // Applied changes section — grouped by batch (Batch → Element → Property)
    if (applied.length > 0) {
      body.appendChild(this.renderSectionHeader('Applied', applied.length, '#10b981'));
      for (const batchBlock of this.groupByBatch(applied)) {
        body.appendChild(this.renderBatchBlock(batchBlock, 'applied'));
      }
      // Clear applied link
      const clearLink = createElement('button', {}, {
        background: 'none',
        border: 'none',
        color: OVERLAY.textMuted,
        fontSize: '10px',
        cursor: 'pointer',
        padding: '2px 12px 6px',
        pointerEvents: 'auto',
        fontFamily: OVERLAY.fontFamily,
      });
      clearLink.textContent = `Clear ${applied.length} applied`;
      clearLink.addEventListener('click', () => this.queue.clearApplied());
      body.appendChild(clearLink);
    }

    // Empty state
    if (totalCount === 0) {
      const empty = createText('div', 'No pending changes', 'body');
      empty.style.padding = '16px 12px';
      empty.style.color = OVERLAY.textMuted;
      empty.style.textAlign = 'center';
      body.appendChild(empty);
    }

    // Removed section
    const removed = this.queue.getRemoved();
    if (removed.length > 0) {
      body.appendChild(this.renderRemovedSection(removed));
    }

    panel.appendChild(body);

    // Action bar (pinned to the bottom of the column)
    const actionBar = this.renderActionBar(active, notes.length, sent.length);
    actionBar.style.flexShrink = '0';
    actionBar.style.borderTop = `1px solid ${OVERLAY.border}`;
    panel.appendChild(actionBar);

    this.container = panel;
    this.shadow.appendChild(panel);
  }

  private renderConnectionWarning(): HTMLDivElement {
    const demoMode = (globalThis as any).__NCO_WEB_EDITOR_DEMO__ === true;

    const banner = createElement('div', {}, {
      background: demoMode ? 'rgba(255, 255, 255, 0.06)' : 'rgba(245, 158, 11, 0.15)',
      border: `1px solid ${demoMode ? 'rgba(255, 255, 255, 0.2)' : OVERLAY.warning}`,
      borderRadius: OVERLAY.radiusSm,
      padding: '8px 12px',
      margin: '8px',
      fontSize: OVERLAY.bodySize,
      color: demoMode ? 'rgba(255, 255, 255, 0.85)' : OVERLAY.warning,
      fontFamily: OVERLAY.fontFamily,
    });

    banner.textContent = demoMode
      ? 'Demo mode — this is a public embed, so change-request funnels are disconnected. Play around freely; a page refresh resets everything.'
      : 'Not connected to MCP server \u2014 check that Claude Code is running with the nco-web-editor MCP configured (port 7890).';

    if (!demoMode && !this.wsClient.hasEverConnected) {
      // Nothing has ever connected in this page session, so Chrome's Local
      // Network Access prompt (shipped in Chrome 142, extended to WebSockets
      // in 147) is a plausible cause: the editor reaches the MCP server over
      // ws://localhost, and a denied or dismissed prompt fails like any other
      // connection error. Worded as a hint, not a diagnosis — Chrome gives no
      // distinguishable signal.
      const lnaHint = createElement('div', {}, {
        marginTop: '6px',
        fontSize: '11px',
        opacity: '0.9',
      });
      lnaHint.textContent =
        'If Chrome asked to allow access to devices on your local network and it was blocked or dismissed, allow it in site settings and reload the page — the editor connects to the MCP server over ws://localhost.';
      banner.appendChild(lnaHint);
    }

    if (!demoMode) {
      const retryBtn = createButton('Retry', 'ghost', () => {
        this.wsClient.retryNow();
      });
      retryBtn.style.marginTop = '6px';
      retryBtn.style.fontSize = '11px';
      retryBtn.style.color = OVERLAY.warning;
      retryBtn.style.borderColor = OVERLAY.warning;
      banner.appendChild(retryBtn);
    }

    return banner;
  }

  private renderNoteCard(note: NoteEntry, index: number): HTMLDivElement {
    const card = createElement('div', {}, {
      padding: '8px 12px',
      borderBottom: `1px solid ${OVERLAY.border}`,
      borderLeft: note.elements.length > 0 ? `2px solid rgba(6, 182, 212, 0.4)` : 'none',
    });

    // Note header row: icon + text + delete button
    const row = createElement('div', {}, {
      display: 'flex',
      alignItems: 'flex-start',
      gap: '6px',
    });

    const icon = createText('span', '\u270e', 'body');
    icon.style.color = OVERLAY.primary;
    icon.style.fontSize = '11px';
    icon.style.flexShrink = '0';
    icon.style.marginTop = '1px';
    row.appendChild(icon);

    const text = createText('span', note.text, 'body');
    text.style.flex = '1';
    text.style.fontSize = '11px';
    text.style.color = OVERLAY.text;
    text.style.wordBreak = 'break-word';
    row.appendChild(text);

    const delBtn = createElement('button', { title: 'Remove note', 'aria-label': 'Remove note' }, {
      background: 'none',
      border: 'none',
      color: OVERLAY.textMuted,
      cursor: 'pointer',
      padding: '0 2px',
      fontSize: '11px',
      marginLeft: 'auto',
      pointerEvents: 'auto',
      flexShrink: '0',
    }) as HTMLButtonElement;
    delBtn.textContent = '\u00d7';
    delBtn.addEventListener('click', () => {
      this.notesStore.remove(index);
    });
    row.appendChild(delBtn);
    card.appendChild(row);

    // Element pills (read-only in review panel)
    if (note.elements.length > 0) {
      const pillRow = createElement('div', {}, {
        display: 'flex',
        flexWrap: 'wrap',
        gap: '3px',
        padding: '4px 0 0 17px',
      });
      for (const ref of note.elements) {
        const label = ref.textContent?.slice(0, 12) || ref.selector.slice(0, 20);
        const pill = createText('span', `<${ref.tagName}> ${label}`, 'mono');
        pill.style.fontSize = '9px';
        pill.style.padding = '1px 4px';
        pill.style.background = 'rgba(6, 182, 212, 0.15)';
        pill.style.border = `1px solid ${OVERLAY.primary}`;
        pill.style.borderRadius = '3px';
        pill.style.cursor = 'pointer';
        pill.title = ref.selector;
        pill.addEventListener('click', () => {
          this.onHighlightElement?.(ref.selector);
        });
        pillRow.appendChild(pill);
      }
      card.appendChild(pillRow);
    }

    return card;
  }

  private renderSourceWarning(): HTMLDivElement {
    const banner = createElement('div', {}, {
      background: 'rgba(245, 158, 11, 0.08)',
      padding: '6px 12px',
      margin: '4px 8px',
      fontSize: OVERLAY.bodySize,
      color: OVERLAY.warning,
      fontFamily: OVERLAY.fontFamily,
      borderRadius: OVERLAY.radiusSm,
    });
    banner.textContent =
      'Some changes have unverified source mapping \u2014 install the dev-plugin for precise file targeting. Changes will be sent with CSS selector only.';
    return banner;
  }

  private renderGroup(
    selector: string,
    diffs: VisualDiff[],
    lifecycle?: DiffLifecycle,
  ): HTMLDivElement {
    const isReadOnly = lifecycle === 'sent' || lifecycle === 'applied';
    const group = createElement('div', {}, {
      padding: '8px 12px',
      borderBottom: `1px solid ${OVERLAY.border}`,
      opacity: isReadOnly ? '0.65' : '1',
    });

    // Group header
    const headerRow = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '6px',
      marginBottom: '4px',
    });
    const headerText =
      selector.length > SELECTOR_TRUNCATE_LENGTH
        ? selector.slice(0, SELECTOR_TRUNCATE_LENGTH) + '\u2026'
        : selector;
    const header = createText('span', headerText, 'mono');
    header.style.color = OVERLAY.primary;
    header.style.cursor = 'pointer';
    header.title = selector;
    header.addEventListener('click', () => {
      this.onHighlightElement?.(selector);
    });
    header.addEventListener('mouseenter', () => { header.style.textDecoration = 'underline'; });
    header.addEventListener('mouseleave', () => { header.style.textDecoration = 'none'; });
    headerRow.appendChild(header);

    // Lifecycle badge
    if (lifecycle === 'sent') {
      headerRow.appendChild(this.renderLifecycleBadge('Sent', OVERLAY.warning));
    } else if (lifecycle === 'applied') {
      headerRow.appendChild(this.renderLifecycleBadge('\u2713 Applied', '#10b981'));
    } else if (!lifecycle && diffs.some((d) => this.queue.isCopied(d.id))) {
      headerRow.appendChild(this.renderLifecycleBadge('Copied', OVERLAY.textMuted));
    }
    group.appendChild(headerRow);

    // Property changes
    for (const diff of diffs) {
      for (const change of diff.changes) {
        const row = createElement('div', {}, {
          display: 'flex',
          alignItems: 'center',
          gap: '4px',
          padding: '2px 0',
          fontFamily: OVERLAY.monoFamily,
          fontSize: OVERLAY.monoSize,
        });

        // Property name
        const propEl = createElement('span', {}, { color: OVERLAY.textMuted });
        propEl.textContent = `${change.property}:`;
        row.appendChild(propEl);

        // Token badge (if toToken)
        if (change.toToken) {
          const badge = createElement('span', {}, {
            background: 'rgba(6, 182, 212, 0.2)',
            color: OVERLAY.primary,
            padding: '1px 3px',
            borderRadius: '2px',
            fontSize: '9px',
          });
          badge.textContent = change.toToken;
          row.appendChild(badge);
        }

        // before → after
        const values = createElement('span', {}, { color: OVERLAY.text });
        values.textContent = `${change.fromValue} \u2192 ${change.toValue}`;
        row.appendChild(values);

        // Remove button (hidden for sent/applied)
        if (!isReadOnly) {
          const removeBtn = createElement('button', {}, {
            background: 'none',
            border: 'none',
            color: OVERLAY.textMuted,
            cursor: 'pointer',
            padding: '0 2px',
            fontSize: '11px',
            marginLeft: 'auto',
            pointerEvents: 'auto',
          });
          removeBtn.textContent = '\u00d7';
          removeBtn.title = 'Remove this change';
          removeBtn.setAttribute('aria-label', 'Remove this change');
          removeBtn.addEventListener('click', () => {
            this.queue.remove(diff.id);
          });
          row.appendChild(removeBtn);
        }

        group.appendChild(row);
      }

      // Reorder changes
      if (diff.reorderChanges) {
        for (const rc of diff.reorderChanges) {
          const row = createElement('div', {}, {
            display: 'flex',
            alignItems: 'center',
            gap: '4px',
            padding: '2px 0',
            fontFamily: OVERLAY.monoFamily,
            fontSize: OVERLAY.monoSize,
          });

          const desc = createElement('span', {}, { color: OVERLAY.text });
          desc.textContent = `reorder: position ${rc.fromIndex + 1} \u2192 ${rc.toIndex + 1}`;
          row.appendChild(desc);

          const dirBadge = createElement('span', {}, {
            background: 'rgba(99, 102, 241, 0.2)',
            color: '#818cf8',
            padding: '1px 3px',
            borderRadius: '2px',
            fontSize: '9px',
          });
          dirBadge.textContent = rc.containerDirection;
          row.appendChild(dirBadge);

          if (!isReadOnly) {
            const removeBtn = createElement('button', {}, {
              background: 'none',
              border: 'none',
              color: OVERLAY.textMuted,
              cursor: 'pointer',
              padding: '0 2px',
              fontSize: '11px',
              marginLeft: 'auto',
              pointerEvents: 'auto',
            });
            removeBtn.textContent = '\u00d7';
            removeBtn.title = 'Remove this change';
            removeBtn.setAttribute('aria-label', 'Remove this change');
            removeBtn.addEventListener('click', () => {
              this.queue.remove(diff.id);
            });
            row.appendChild(removeBtn);
          }

          group.appendChild(row);
        }
      }

      // Insert changes
      if (diff.insertChanges) {
        for (const ic of diff.insertChanges) {
          const row = createElement('div', {}, {
            display: 'flex',
            alignItems: 'center',
            gap: '4px',
            padding: '2px 0',
            fontFamily: OVERLAY.monoFamily,
            fontSize: OVERLAY.monoSize,
          });

          const desc = createElement('span', {}, { color: OVERLAY.text });
          desc.textContent = `insert: <${ic.tagName}> at position ${ic.insertIndex + 1}`;
          row.appendChild(desc);

          const badge = createElement('span', {}, {
            background: 'rgba(16, 185, 129, 0.2)',
            color: '#10b981',
            padding: '1px 3px',
            borderRadius: '2px',
            fontSize: '9px',
          });
          badge.textContent = 'new';
          row.appendChild(badge);

          if (!isReadOnly) {
            const removeBtn = createElement('button', {}, {
              background: 'none',
              border: 'none',
              color: OVERLAY.textMuted,
              cursor: 'pointer',
              padding: '0 2px',
              fontSize: '11px',
              marginLeft: 'auto',
              pointerEvents: 'auto',
            });
            removeBtn.textContent = '\u00d7';
            removeBtn.title = 'Remove this change';
            removeBtn.setAttribute('aria-label', 'Remove this change');
            removeBtn.addEventListener('click', () => {
              this.queue.remove(diff.id);
            });
            row.appendChild(removeBtn);
          }

          group.appendChild(row);
        }
      }

      // Remove changes
      if (diff.removeChanges) {
        for (const rmc of diff.removeChanges) {
          const row = createElement('div', {}, {
            display: 'flex',
            alignItems: 'center',
            gap: '4px',
            padding: '2px 0',
            fontFamily: OVERLAY.monoFamily,
            fontSize: OVERLAY.monoSize,
          });

          const desc = createElement('span', {}, { color: OVERLAY.text });
          desc.textContent = `remove: <${rmc.tagName}> from position ${rmc.removedIndex + 1}`;
          row.appendChild(desc);

          const badge = createElement('span', {}, {
            background: 'rgba(239, 68, 68, 0.2)',
            color: '#ef4444',
            padding: '1px 3px',
            borderRadius: '2px',
            fontSize: '9px',
          });
          badge.textContent = 'del';
          row.appendChild(badge);

          if (!isReadOnly) {
            const removeBtn = createElement('button', {}, {
              background: 'none',
              border: 'none',
              color: OVERLAY.textMuted,
              cursor: 'pointer',
              padding: '0 2px',
              fontSize: '11px',
              marginLeft: 'auto',
              pointerEvents: 'auto',
            });
            removeBtn.textContent = '×';
            removeBtn.title = 'Remove this change';
            removeBtn.setAttribute('aria-label', 'Remove this change');
            removeBtn.addEventListener('click', () => {
              this.queue.remove(diff.id);
            });
            row.appendChild(removeBtn);
          }

          group.appendChild(row);
        }
      }

      // Group changes
      if (diff.groupChanges) {
        for (const gc of diff.groupChanges) {
          const row = createElement('div', {}, {
            display: 'flex',
            alignItems: 'center',
            gap: '4px',
            padding: '2px 0',
            fontFamily: OVERLAY.monoFamily,
            fontSize: OVERLAY.monoSize,
          });

          const desc = createElement('span', {}, { color: OVERLAY.text });
          desc.textContent = `group: ${gc.wrappedSelectors.length} elements into flex container`;
          row.appendChild(desc);

          const badge = createElement('span', {}, {
            background: 'rgba(168, 85, 247, 0.2)',
            color: '#a855f7',
            padding: '1px 3px',
            borderRadius: '2px',
            fontSize: '9px',
          });
          badge.textContent = 'wrap';
          row.appendChild(badge);

          if (!isReadOnly) {
            const removeBtn = createElement('button', {}, {
              background: 'none',
              border: 'none',
              color: OVERLAY.textMuted,
              cursor: 'pointer',
              padding: '0 2px',
              fontSize: '11px',
              marginLeft: 'auto',
              pointerEvents: 'auto',
            });
            removeBtn.textContent = '\u00d7';
            removeBtn.title = 'Remove this change';
            removeBtn.setAttribute('aria-label', 'Remove this change');
            removeBtn.addEventListener('click', () => {
              this.queue.remove(diff.id);
            });
            row.appendChild(removeBtn);
          }

          group.appendChild(row);
        }
      }

      // Attribute changes
      if (diff.attributeChanges) {
        for (const ac of diff.attributeChanges) {
          const row = createElement('div', {}, {
            display: 'flex',
            alignItems: 'center',
            gap: '4px',
            padding: '2px 0',
            fontFamily: OVERLAY.monoFamily,
            fontSize: OVERLAY.monoSize,
          });

          const attrEl = createElement('span', {}, { color: OVERLAY.textMuted });
          attrEl.textContent = `${ac.attribute}:`;
          row.appendChild(attrEl);

          const badge = createElement('span', {}, {
            background: 'rgba(245, 158, 11, 0.2)',
            color: '#f59e0b',
            padding: '1px 3px',
            borderRadius: '2px',
            fontSize: '9px',
          });
          badge.textContent = 'attr';
          row.appendChild(badge);

          const values = createElement('span', {}, {
            color: OVERLAY.text,
            overflow: 'hidden',
            textOverflow: 'ellipsis',
            whiteSpace: 'nowrap',
            maxWidth: '160px',
          });
          const fromDisplay = this.truncateValue(ac.fromValue);
          const toDisplay = this.truncateValue(ac.toValue);
          values.textContent = `${fromDisplay} \u2192 ${toDisplay}`;
          values.title = `${ac.fromValue} → ${ac.toValue}`;
          row.appendChild(values);

          if (!isReadOnly) {
            const removeBtn = createElement('button', {}, {
              background: 'none',
              border: 'none',
              color: OVERLAY.textMuted,
              cursor: 'pointer',
              padding: '0 2px',
              fontSize: '11px',
              marginLeft: 'auto',
              pointerEvents: 'auto',
            });
            removeBtn.textContent = '\u00d7';
            removeBtn.title = 'Remove this change';
            removeBtn.setAttribute('aria-label', 'Remove this change');
            removeBtn.addEventListener('click', () => {
              this.queue.remove(diff.id);
            });
            row.appendChild(removeBtn);
          }

          group.appendChild(row);
        }
      }
    }

    return group;
  }

  private renderRemovedSection(
    removed: Array<{ diffId: string; diff: VisualDiff }>,
  ): HTMLDivElement {
    const section = createElement('div', {}, {
      padding: '4px 12px',
      borderBottom: `1px solid ${OVERLAY.border}`,
    });

    // Collapsible header
    const toggle = createElement('button', {}, {
      background: 'none',
      border: 'none',
      color: OVERLAY.textMuted,
      fontFamily: OVERLAY.fontFamily,
      fontSize: OVERLAY.bodySize,
      cursor: 'pointer',
      padding: '4px 0',
      pointerEvents: 'auto',
    });
    toggle.textContent = `\u25b6 Removed (${removed.length})`;

    const content = createElement('div', {}, { display: 'none' });

    toggle.addEventListener('click', () => {
      const open = content.style.display !== 'none';
      content.style.display = open ? 'none' : '';
      toggle.textContent = `${open ? '\u25b6' : '\u25bc'} Removed (${removed.length})`;
    });

    for (const item of removed) {
      const row = createElement('div', {}, {
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        padding: '2px 0',
        opacity: '0.5',
        fontFamily: OVERLAY.monoFamily,
        fontSize: OVERLAY.monoSize,
        color: OVERLAY.textMuted,
      });

      const label = createElement('span');
      const changeCount = item.diff.changes.length + (item.diff.reorderChanges?.length ?? 0) + (item.diff.insertChanges?.length ?? 0) + (item.diff.removeChanges?.length ?? 0) + (item.diff.groupChanges?.length ?? 0);
      label.textContent = `${item.diff.element.selector.slice(0, 30)} (${changeCount} change${changeCount !== 1 ? 's' : ''})`;
      row.appendChild(label);

      const restoreBtn = createButton('Restore', 'ghost', () => {
        this.queue.restoreItem(item.diffId);
      });
      restoreBtn.style.fontSize = '10px';
      restoreBtn.style.padding = '1px 4px';
      row.appendChild(restoreBtn);

      content.appendChild(row);
    }

    section.appendChild(toggle);
    section.appendChild(content);
    return section;
  }

  private renderActionBar(active: VisualDiff[], noteCount: number, sentCount: number): HTMLDivElement {
    const bar = createElement('div', {}, {
      display: 'flex',
      justifyContent: 'space-between',
      alignItems: 'center',
      padding: '8px 12px',
    });

    const pendingTotal = active.length + noteCount;
    const countText = createText(
      'span',
      `${pendingTotal} pending`,
      'body',
    );
    countText.style.color = OVERLAY.textMuted;
    bar.appendChild(countText);

    // Button group (copy + check status + apply)
    const btnGroup = createElement('div', {}, {
      display: 'flex',
      gap: '6px',
      alignItems: 'center',
    });

    // "Copy as Prompt" — works regardless of connection status (copies pending only)
    const copyDisabled = pendingTotal === 0;
    const copyBtn = createButton('Copy as Prompt', 'ghost', () => {
      const notes = this.notesStore.getAll();
      const prompt = serializeToPrompt(active, notes.length > 0 ? notes : undefined);
      navigator.clipboard.writeText(prompt).then(() => {
        // Mark diffs as copied for clipboard reconciliation
        this.queue.markCopied(active.map((d) => d.id));
        // Green flash confirmation
        copyBtn.style.background = 'rgba(34, 197, 94, 0.15)';
        setTimeout(() => { copyBtn.style.background = 'transparent'; }, 300);
      }).catch(() => {
        // Silent fail — clipboard API may be unavailable
      });
    });
    copyBtn.style.fontSize = '11px';
    if (copyDisabled) {
      copyBtn.style.opacity = '0.5';
      copyBtn.style.pointerEvents = 'none';
    }
    btnGroup.appendChild(copyBtn);

    // "Check Status" — only shown when there are sent items
    if (sentCount > 0) {
      const checkDisabled = this.connectionStatus !== 'connected';
      const checkBtn = createButton('Check Status', 'ghost', () => {
        this.wsClient.sendStatusRequest();
      });
      checkBtn.style.fontSize = '11px';
      if (checkDisabled) {
        checkBtn.style.opacity = '0.5';
        checkBtn.style.pointerEvents = 'none';
      }
      btnGroup.appendChild(checkBtn);
    }

    // "Apply Changes" — requires connection, only counts pending items
    const demoMode = (globalThis as any).__NCO_WEB_EDITOR_DEMO__ === true;
    const sendDisabled =
      demoMode || pendingTotal === 0 || this.connectionStatus !== 'connected' || this.sending;

    const sendBtn = createButton('Apply Changes', 'primary', () => {
      this.handleSend();
    });
    if (demoMode) {
      sendBtn.title = 'Demo mode — this embed is not connected to a local MCP server, so changes cannot be submitted. Refresh the page to reset.';
    }
    if (sendDisabled) {
      sendBtn.style.opacity = '0.5';
      sendBtn.style.pointerEvents = 'none';
    }
    btnGroup.appendChild(sendBtn);

    bar.appendChild(btnGroup);

    return bar;
  }

  // -----------------------------------------------------------------------
  // Send logic
  // -----------------------------------------------------------------------

  /** Trigger the send flow programmatically (e.g., from keyboard shortcut). */
  async triggerSend(): Promise<void> {
    return this.handleSend();
  }

  private async handleSend(): Promise<void> {
    if (this.sending) return;
    const allActive = this.queue.getAllActive();
    const note = this.notesStore.toBatchNote();
    if (allActive.length === 0 && !note) return;

    if (allActive.length >= BATCH_CONFIRM_THRESHOLD) {
      console.log(
        `[nco-web-editor] Sending batch of ${allActive.length} changes`,
      );
    }

    this.sending = true;
    this.refresh();

    // Mint one batchId for the entire click — invariant: one click = one batchId.
    const batchId = makeBatchId();

    // Stamp batchId on ALL active diffs in the queue (updates queue items in place
    // so the diff.batchId is available when DIFF_ACK triggers acknowledge()).
    const allDiffIds = allActive.map((d) => d.id);
    const stampedDiffs = this.queue.stampBatchId(batchId, allDiffIds);

    // Loop-send in MAX_DIFFS_PER_BATCH segments under the same batchId.
    // The server ACKs each segment independently; the queue updates on each ACK.
    let sentAny = false;
    for (let offset = 0; offset < stampedDiffs.length; offset += MAX_DIFFS_PER_BATCH) {
      const segment = stampedDiffs.slice(offset, offset + MAX_DIFFS_PER_BATCH);
      // Only attach the note to the first segment (one note per logical batch)
      const segmentNote = offset === 0 ? note : undefined;
      const success = this.wsClient.sendDiffBatch(segment, segmentNote, batchId);
      if (!success) {
        console.error('[nco-web-editor] Failed to send batch — WebSocket not connected');
        this.sending = false;
        this.refresh();
        return;
      }
      sentAny = true;
    }

    // Note-only batch (no diffs)
    if (!sentAny && note) {
      const success = this.wsClient.sendDiffBatch([], note, batchId);
      if (!success) {
        console.error('[nco-web-editor] Failed to send note — WebSocket not connected');
        this.sending = false;
        this.refresh();
        return;
      }
    }

    // Clear notes after successful send
    this.notesStore.clear();

    // Reset sending state after a reasonable timeout
    // (The queue updates when DIFF_ACK arrives via queue.acknowledge)
    setTimeout(() => {
      this.sending = false;
      this.refresh();
    }, 5000);
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  private truncateValue(value: string): string {
    if (value.length > 40) return value.slice(0, 37) + '…';
    return value || '(empty)';
  }

  private renderLifecycleBadge(label: string, color: string): HTMLSpanElement {
    const badge = createElement('span', {}, {
      background: `${color}22`,
      color,
      padding: '1px 4px',
      borderRadius: '3px',
      fontSize: '9px',
      fontFamily: OVERLAY.fontFamily,
      flexShrink: '0',
    }) as HTMLSpanElement;
    badge.textContent = label;
    return badge;
  }

  private renderSectionHeader(label: string, count: number, color: string): HTMLDivElement {
    const header = createElement('div', {}, {
      padding: '6px 12px 2px',
      fontSize: '10px',
      fontFamily: OVERLAY.fontFamily,
      color,
      textTransform: 'uppercase',
      letterSpacing: '0.5px',
      borderTop: `1px solid ${OVERLAY.border}`,
    });
    header.textContent = `${label} (${count})`;
    return header;
  }

  private renderStaleNotice(staleCount: number): HTMLDivElement {
    const notice = createElement('div', {}, {
      display: 'flex',
      justifyContent: 'space-between',
      alignItems: 'center',
      padding: '4px 12px 6px',
      fontSize: '10px',
      fontFamily: OVERLAY.fontFamily,
      color: OVERLAY.warning,
    });
    const text = createElement('span');
    text.textContent = `${staleCount} change${staleCount !== 1 ? 's' : ''} sent >24h ago`;
    notice.appendChild(text);

    const clearBtn = createElement('button', {}, {
      background: 'none',
      border: 'none',
      color: OVERLAY.warning,
      fontSize: '10px',
      cursor: 'pointer',
      padding: '0 2px',
      pointerEvents: 'auto',
      fontFamily: OVERLAY.fontFamily,
      textDecoration: 'underline',
    });
    clearBtn.textContent = 'Clear stale';
    clearBtn.addEventListener('click', () => this.queue.clearStale());
    notice.appendChild(clearBtn);

    return notice;
  }

  private groupByElement(diffs: VisualDiff[]): Map<string, VisualDiff[]> {
    const groups = new Map<string, VisualDiff[]>();
    for (const diff of diffs) {
      const key = diff.element.selector;
      const existing = groups.get(key);
      if (existing) existing.push(diff);
      else groups.set(key, [diff]);
    }
    return groups;
  }

  /**
   * Group PendingEdit items by batchId (newest-first).
   * Items without a batchId are collected into a synthetic "legacy" group.
   */
  private groupByBatch(items: import('../../shared/types').PendingEdit[]): Array<{
    batchId: string | null;
    sentAt: number | undefined;
    diffs: VisualDiff[];
  }> {
    const batchMap = new Map<string, { sentAt: number | undefined; diffs: VisualDiff[] }>();
    const legacy: { sentAt: number | undefined; diffs: VisualDiff[] } = { sentAt: undefined, diffs: [] };

    for (const item of items) {
      const bid = item.batchId ?? item.diff.batchId;
      if (bid) {
        let entry = batchMap.get(bid);
        if (!entry) {
          entry = { sentAt: item.sentAt, diffs: [] };
          batchMap.set(bid, entry);
        } else if (item.sentAt && (!entry.sentAt || item.sentAt < entry.sentAt)) {
          entry.sentAt = item.sentAt;
        }
        entry.diffs.push(item.diff);
      } else {
        if (item.sentAt && (!legacy.sentAt || item.sentAt < legacy.sentAt)) {
          legacy.sentAt = item.sentAt;
        }
        legacy.diffs.push(item.diff);
      }
    }

    // Newest batch first (highest sentAt first)
    const result: Array<{ batchId: string | null; sentAt: number | undefined; diffs: VisualDiff[] }> = [];
    for (const [bid, entry] of batchMap) {
      result.push({ batchId: bid, ...entry });
    }
    result.sort((a, b) => (b.sentAt ?? 0) - (a.sentAt ?? 0));
    if (legacy.diffs.length > 0) {
      result.push({ batchId: null, ...legacy });
    }
    return result;
  }

  private renderBatchBlock(
    block: { batchId: string | null; sentAt: number | undefined; diffs: VisualDiff[] },
    lifecycle: 'sent' | 'applied',
  ): HTMLDivElement {
    const wrapper = createElement('div', {}, {
      borderBottom: `1px solid ${OVERLAY.border}`,
      marginBottom: '2px',
    });

    // Batch header
    const headerEl = createElement('div', {}, {
      display: 'flex',
      alignItems: 'center',
      gap: '6px',
      padding: '4px 12px',
      background: 'rgba(255,255,255,0.04)',
      fontFamily: OVERLAY.monoFamily,
      fontSize: '10px',
      color: OVERLAY.textMuted,
    });

    const idEl = createElement('span', {}, { color: OVERLAY.primary, fontWeight: '600' });
    idEl.textContent = block.batchId ?? 'legacy';
    headerEl.appendChild(idEl);

    if (block.sentAt) {
      const elapsed = formatElapsed(new Date(block.sentAt).toISOString());
      if (elapsed) {
        const timeEl = createElement('span');
        timeEl.textContent = `· ${elapsed}`;
        headerEl.appendChild(timeEl);
      }

      // Stale indicator — batch-level: oldest sentAt > 24h
      if (Date.now() - block.sentAt > 24 * 60 * 60 * 1000) {
        const staleEl = createElement('span', {}, { color: OVERLAY.warning });
        staleEl.textContent = '⚠ stale';
        staleEl.title = 'Batch sent more than 24 hours ago';
        headerEl.appendChild(staleEl);
      }
    }

    wrapper.appendChild(headerEl);

    // Element groups inside this batch
    const elementGroups = this.groupByElement(block.diffs);
    for (const [selector, diffs] of elementGroups) {
      const groupEl = this.renderGroup(selector, diffs, lifecycle);
      groupEl.style.borderBottom = 'none';
      groupEl.style.paddingLeft = '20px';
      wrapper.appendChild(groupEl);
    }

    return wrapper;
  }
}

/**
 * Mint a stable, human-readable batch ID for one Apply-Changes click.
 * Format: batch-YYYYMMDD-HHMMSS-xxxx (UTC date + time + 4-char hex suffix)
 * Example: batch-20260621-143052-a3f7
 */
function makeBatchId(): string {
  const now = new Date();
  const date = now.toISOString().slice(0, 10).replace(/-/g, '');
  const time = now.toISOString().slice(11, 19).replace(/:/g, '');
  const suffix = Math.floor(Math.random() * 0x10000).toString(16).padStart(4, '0');
  return `batch-${date}-${time}-${suffix}`;
}

/** Format elapsed time since an ISO timestamp as a compact string. */
function formatElapsed(isoTimestamp: string): string | null {
  const ms = Date.now() - new Date(isoTimestamp).getTime();
  if (ms < 0 || Number.isNaN(ms)) return null;
  const minutes = Math.floor(ms / 60_000);
  if (minutes < 1) return '<1m ago';
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  return `${days}d ago`;
}
