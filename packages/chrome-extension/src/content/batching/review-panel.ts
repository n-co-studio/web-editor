import type { VisualDiff, NoteEntry } from '@frontend-editor/shared';
import { createElement, createText, createButton } from '../../shared/ui-utils';
import { OVERLAY, SELECTOR_TRUNCATE_LENGTH, BATCH_CONFIRM_THRESHOLD, TOOLBAR_WIDTH } from '../../shared/constants';
import type { ConnectionStatus, DiffLifecycle } from '../../shared/types';
import type { PendingQueue } from './queue';
import type { WebSocketClient } from '../websocket-client';
import type { DiffBuilder } from './diff-builder';
import type { NotesStore } from './notes-store';
import { serializeToPrompt } from './prompt-serializer';

type VoidCallback = () => void;

/**
 * Review panel for pending changes. Renders inside the shadow DOM.
 * Shows changes grouped by element, with individual removal/restore,
 * "Apply Changes" button, and WebSocket status banners.
 */
export class ReviewPanel {
  private container: HTMLDivElement | null = null;
  private visible = false;
  private connectionStatus: ConnectionStatus = 'disconnected';
  private sending = false;
  private closeCb: VoidCallback | null = null;
  private anchorPos: { x: number; y: number } = { x: 16, y: 16 };

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
  }

  show(anchorPos?: { x: number; y: number }): void {
    if (anchorPos) this.anchorPos = anchorPos;
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

  /** Reposition the panel relative to a new toolbar anchor. */
  reposition(anchorPos: { x: number; y: number }): void {
    this.anchorPos = anchorPos;
    if (!this.container) return;
    const panelLeft = Math.min(
      anchorPos.x + TOOLBAR_WIDTH + 8,
      window.innerWidth - 368,
    );
    const panelTop = Math.max(8, anchorPos.y);
    this.container.style.left = `${panelLeft}px`;
    this.container.style.top = `${panelTop}px`;
  }

  /** Get the current batch note from the notes store. */
  getSessionNote(): string {
    return this.notesStore.toBatchNote() ?? '';
  }

  // -----------------------------------------------------------------------
  // Rendering
  // -----------------------------------------------------------------------

  private render(): void {
    this.container?.remove();

    const panelLeft = Math.min(
      this.anchorPos.x + TOOLBAR_WIDTH + 8,
      window.innerWidth - 368,
    );
    const panelTop = Math.max(8, this.anchorPos.y);

    const panel = createElement('div', { role: 'dialog', 'aria-label': 'Review changes' }, {
      position: 'fixed',
      left: `${panelLeft}px`,
      top: `${panelTop}px`,
      width: '360px',
      maxHeight: '50vh',
      overflowY: 'auto',
      background: OVERLAY.bg,
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusMd,
      boxShadow: OVERLAY.shadowLg,
      pointerEvents: 'auto',
      zIndex: '200',
      fontFamily: OVERLAY.fontFamily,
    });

    // Header
    const header = createElement('div', {}, {
      display: 'flex',
      justifyContent: 'space-between',
      alignItems: 'center',
      padding: '8px 12px',
      borderBottom: `1px solid ${OVERLAY.border}`,
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

    // Connection warning
    if (this.connectionStatus !== 'connected') {
      panel.appendChild(this.renderConnectionWarning());
    }

    // Source unverified warning (if any diffs lack sourceVerified)
    const hasUnverified = active.some((d) => !d.sourceVerified);
    if (hasUnverified) {
      panel.appendChild(this.renderSourceWarning());
    }

    // Notes as change requests
    for (let i = 0; i < notes.length; i++) {
      panel.appendChild(this.renderNoteCard(notes[i], i));
    }

    // Grouped CSS changes (pending)
    const groups = this.groupByElement(active);
    for (const [selector, diffs] of groups) {
      panel.appendChild(this.renderGroup(selector, diffs));
    }

    // Sent changes section
    if (sent.length > 0) {
      panel.appendChild(this.renderSectionHeader('Sent to Server', sent.length, OVERLAY.warning));
      const sentDiffs = sent.map((s) => s.diff);
      const sentGroups = this.groupByElement(sentDiffs);
      for (const [selector, diffs] of sentGroups) {
        panel.appendChild(this.renderGroup(selector, diffs, 'sent'));
      }
      // Stale indicator
      const staleCount = sent.filter(
        (s) => s.sentAt && Date.now() - s.sentAt > 24 * 60 * 60 * 1000,
      ).length;
      if (staleCount > 0) {
        panel.appendChild(this.renderStaleNotice(staleCount));
      }
    }

    // Applied changes section
    if (applied.length > 0) {
      panel.appendChild(this.renderSectionHeader('Applied', applied.length, '#10b981'));
      const appliedDiffs = applied.map((a) => a.diff);
      const appliedGroups = this.groupByElement(appliedDiffs);
      for (const [selector, diffs] of appliedGroups) {
        panel.appendChild(this.renderGroup(selector, diffs, 'applied'));
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
      panel.appendChild(clearLink);
    }

    // Empty state
    if (totalCount === 0) {
      const empty = createText('div', 'No pending changes', 'body');
      empty.style.padding = '16px 12px';
      empty.style.color = OVERLAY.textMuted;
      empty.style.textAlign = 'center';
      panel.appendChild(empty);
    }

    // Removed section
    const removed = this.queue.getRemoved();
    if (removed.length > 0) {
      panel.appendChild(this.renderRemovedSection(removed));
    }

    // Action bar
    panel.appendChild(this.renderActionBar(active, notes.length, sent.length));

    this.container = panel;
    this.shadow.appendChild(panel);
  }

  private renderConnectionWarning(): HTMLDivElement {
    const banner = createElement('div', {}, {
      background: 'rgba(245, 158, 11, 0.15)',
      border: `1px solid ${OVERLAY.warning}`,
      borderRadius: OVERLAY.radiusSm,
      padding: '8px 12px',
      margin: '8px',
      fontSize: OVERLAY.bodySize,
      color: OVERLAY.warning,
      fontFamily: OVERLAY.fontFamily,
    });

    banner.textContent =
      'Not connected to MCP server \u2014 check that Claude Code is running with the frontend-editor MCP configured (port 7890).';

    const retryBtn = createButton('Retry', 'ghost', () => {
      this.wsClient.retryNow();
    });
    retryBtn.style.marginTop = '6px';
    retryBtn.style.fontSize = '11px';
    retryBtn.style.color = OVERLAY.warning;
    retryBtn.style.borderColor = OVERLAY.warning;
    banner.appendChild(retryBtn);

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

    const delBtn = createElement('button', { title: 'Remove note' }, {
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
      const changeCount = item.diff.changes.length + (item.diff.reorderChanges?.length ?? 0) + (item.diff.insertChanges?.length ?? 0);
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
    const sendDisabled =
      pendingTotal === 0 || this.connectionStatus !== 'connected' || this.sending;

    const sendBtn = createButton('Apply Changes', 'primary', () => {
      this.handleSend();
    });
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

  private async handleSend(): Promise<void> {
    if (this.sending) return;
    const { diffs } = this.queue.getBatch();
    const note = this.notesStore.toBatchNote();
    if (diffs.length === 0 && !note) return;

    // Confirm large batches
    if (diffs.length >= BATCH_CONFIRM_THRESHOLD) {
      console.log(
        `[frontend-editor] Sending batch of ${diffs.length} changes`,
      );
    }

    this.sending = true;
    this.refresh();

    const success = this.wsClient.sendDiffBatch(diffs, note);
    if (!success) {
      console.error('[frontend-editor] Failed to send batch — WebSocket not connected');
      this.sending = false;
      this.refresh();
      return;
    }

    // Clear notes after successful send
    this.notesStore.clear();

    // The queue will be updated when DIFF_ACK arrives (via queue.acknowledge)
    // Reset sending state after a reasonable timeout
    setTimeout(() => {
      this.sending = false;
      this.refresh();
    }, 5000);
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

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
