import type { VisualDiff, DiffServerStatus } from '@nco-studio/shared';
import { MAX_DIFFS_PER_BATCH } from '../../shared/constants';
import type { PendingEdit, DiffLifecycle } from '../../shared/types';

const STORAGE_KEY = 'nco-web-editor-pending-queue';

/**
 * Manages the pending edit queue with chrome.storage.session persistence.
 * Handles deduplication, collapse, lifecycle transitions, reconciliation
 * with the server, and the "Removed" section (soft-delete with restore).
 */
export class PendingQueue {
  private items: PendingEdit[] = [];
  private changeCallbacks: Array<() => void> = [];

  /** Number of active (non-removed) items in the queue (all statuses). */
  get count(): number {
    return this.items.filter((i) => !i.removedAt).length;
  }

  /** Number of pending (unsent, non-removed) items. */
  get pendingCount(): number {
    return this.items.filter(
      (i) => !i.removedAt && (!i.lifecycleStatus || i.lifecycleStatus === 'pending'),
    ).length;
  }

  /** Add a diff to the queue. Collapses duplicate property edits on same element. */
  add(diff: VisualDiff): void {
    const fullyCollapsed = this.collapseExisting(diff);
    if (!fullyCollapsed) {
      this.items.push({ diffId: diff.id, diff });
    }
    this.persist();
    this.notify();
  }

  /** Soft-remove a diff (moves to "Removed" section). */
  remove(diffId: string): void {
    const item = this.items.find((i) => i.diffId === diffId);
    if (item && !item.removedAt) {
      item.removedAt = Date.now();
      this.persist();
      this.notify();
    }
  }

  /** Restore a previously removed diff. */
  restoreItem(diffId: string): void {
    const item = this.items.find((i) => i.diffId === diffId);
    if (item?.removedAt) {
      delete item.removedAt;
      this.persist();
      this.notify();
    }
  }

  /** Get all active pending (non-removed, non-sent/applied) diffs. */
  getActive(): VisualDiff[] {
    return this.items
      .filter((i) => !i.removedAt && (!i.lifecycleStatus || i.lifecycleStatus === 'pending'))
      .map((i) => i.diff);
  }

  /** Get items that have been sent to the server (awaiting AI processing). */
  getSent(): PendingEdit[] {
    return this.items.filter((i) => !i.removedAt && i.lifecycleStatus === 'sent');
  }

  /** Get items that have been applied by the AI. */
  getApplied(): PendingEdit[] {
    return this.items.filter((i) => !i.removedAt && i.lifecycleStatus === 'applied');
  }

  /** Get removed items. */
  getRemoved(): PendingEdit[] {
    return this.items.filter((i) => i.removedAt);
  }

  /** Get all diff IDs (including removed — for reconciliation). */
  getDiffIds(): string[] {
    return this.items.map((i) => i.diffId);
  }

  /** Get the lifecycle status of a specific diff. */
  getLifecycleStatus(diffId: string): DiffLifecycle {
    const item = this.items.find((i) => i.diffId === diffId);
    return item?.lifecycleStatus ?? 'pending';
  }

  /**
   * Get active diffs ready to send, starting at `offset`.
   * Used by the loop-send path to iterate through all diffs in
   * MAX_DIFFS_PER_BATCH segments under one batchId.
   *
   * Returns the segment and whether more remain after this segment.
   */
  getBatch(offset = 0): { diffs: VisualDiff[]; hasMore: boolean } {
    const active = this.getActive();
    const segment = active.slice(offset, offset + MAX_DIFFS_PER_BATCH);
    const hasMore = offset + MAX_DIFFS_PER_BATCH < active.length;
    return { diffs: segment, hasMore };
  }

  /**
   * Get ALL active diffs (no segment cap). Used by the loop-send path
   * to count and iterate; callers are responsible for chunking.
   */
  getAllActive(): VisualDiff[] {
    return this.getActive();
  }

  /**
   * Stamp a batchId on all active pending diffs identified by `diffIds`.
   * Called at send time so that the outgoing diffs carry the id and the
   * queue items' `diff.batchId` is also populated for the acknowledge path.
   * Returns the stamped VisualDiff objects (new object per diff — batchId is readonly).
   */
  stampBatchId(batchId: string, diffIds: readonly string[]): VisualDiff[] {
    const idSet = new Set(diffIds);
    const stamped: VisualDiff[] = [];
    for (let i = 0; i < this.items.length; i++) {
      const item = this.items[i];
      if (!idSet.has(item.diffId) || item.removedAt) continue;
      const stampedDiff: VisualDiff = { ...item.diff, batchId };
      this.items[i] = { ...item, diff: stampedDiff };
      stamped.push(stampedDiff);
    }
    this.persist();
    this.notify();
    return stamped;
  }

  /**
   * Reconcile with server on reconnect.
   * Updates lifecycle status based on server-side state.
   */
  reconcile(pendingDiffIds: readonly string[], appliedDiffIds: readonly string[]): void {
    const serverPending = new Set(pendingDiffIds);
    const serverApplied = new Set(appliedDiffIds);
    const now = Date.now();
    for (const item of this.items) {
      if (serverApplied.has(item.diffId)) {
        item.lifecycleStatus = 'applied';
      } else if (serverPending.has(item.diffId)) {
        item.lifecycleStatus = 'sent';
        if (!item.sentAt) item.sentAt = now;
      }
      // Items not in either set remain at current status (likely 'pending')
    }
    this.persist();
    this.notify();
  }

  /**
   * Transition diffs to 'sent' status.
   * Called when DIFF_ACK is received from the server.
   * Stamps `batchId` from the diff itself onto the PendingEdit so the
   * review panel can group Sent/Applied sections without unwrapping diffs.
   */
  acknowledge(diffIds: readonly string[]): void {
    const acked = new Set(diffIds);
    const now = Date.now();
    for (const item of this.items) {
      if (acked.has(item.diffId) && !item.removedAt) {
        item.lifecycleStatus = 'sent';
        item.sentAt = now;
        if (item.diff.batchId && !item.batchId) {
          item.batchId = item.diff.batchId;
        }
      }
    }
    this.persist();
    this.notify();
  }

  /**
   * Transition diffs to 'applied' status.
   * Called when DIFF_APPLIED is received from the server.
   */
  markApplied(diffIds: readonly string[]): void {
    const applied = new Set(diffIds);
    for (const item of this.items) {
      if (applied.has(item.diffId)) {
        item.lifecycleStatus = 'applied';
      }
    }
    this.persist();
    this.notify();
  }

  /**
   * Update lifecycle status from server STATUS_RESPONSE.
   * Maps server statuses to extension lifecycle.
   */
  updateFromServerStatus(perDiff: readonly DiffServerStatus[]): void {
    const statusMap = new Map(perDiff.map((d) => [d.id, d.serverStatus]));
    let changed = false;
    for (const item of this.items) {
      const serverStatus = statusMap.get(item.diffId);
      if (!serverStatus) continue;
      const newLifecycle: DiffLifecycle =
        serverStatus === 'applied' || serverStatus === 'rejected' ? 'applied' : 'sent';
      if (item.lifecycleStatus !== newLifecycle) {
        item.lifecycleStatus = newLifecycle;
        if (newLifecycle === 'sent' && !item.sentAt) item.sentAt = Date.now();
        changed = true;
      }
    }
    if (changed) {
      this.persist();
      this.notify();
    }
  }

  /** Check if a diff was copied to clipboard. */
  isCopied(diffId: string): boolean {
    const item = this.items.find((i) => i.diffId === diffId);
    return item?.copiedToClipboard === true;
  }

  /** Mark diffs as copied to clipboard. */
  markCopied(diffIds: readonly string[]): void {
    const copied = new Set(diffIds);
    const now = Date.now();
    for (const item of this.items) {
      if (copied.has(item.diffId)) {
        item.copiedToClipboard = true;
        item.copiedAt = now;
      }
    }
    this.persist();
    this.notify();
  }

  /** Clear all items. */
  clear(): void {
    this.items = [];
    this.persist();
    this.notify();
  }

  /** Clear only pending items (keeps sent/applied). */
  clearPending(): void {
    this.items = this.items.filter(
      (i) => i.lifecycleStatus && i.lifecycleStatus !== 'pending',
    );
    this.persist();
    this.notify();
  }

  /** Remove all applied items. Returns count cleared. */
  clearApplied(): number {
    const before = this.items.length;
    this.items = this.items.filter((i) => i.lifecycleStatus !== 'applied');
    const cleared = before - this.items.length;
    if (cleared > 0) {
      this.persist();
      this.notify();
    }
    return cleared;
  }

  /** Remove sent items older than 24h. Returns count cleared. */
  clearStale(): number {
    const cutoff = Date.now() - 24 * 60 * 60 * 1000;
    const before = this.items.length;
    this.items = this.items.filter(
      (i) => !(i.lifecycleStatus === 'sent' && i.sentAt && i.sentAt < cutoff),
    );
    const cleared = before - this.items.length;
    if (cleared > 0) {
      this.persist();
      this.notify();
    }
    return cleared;
  }

  /** Register callback for queue changes. */
  onChange(cb: () => void): void {
    this.changeCallbacks.push(cb);
  }

  // -----------------------------------------------------------------------
  // Persistence (chrome.storage.session)
  // -----------------------------------------------------------------------

  /** Restore queue from chrome.storage.session. */
  async restore(): Promise<void> {
    try {
      const result = await chrome.storage.session.get(STORAGE_KEY);
      if (result[STORAGE_KEY] && Array.isArray(result[STORAGE_KEY])) {
        this.items = result[STORAGE_KEY];
      }
    } catch {
      // Not in extension context or storage unavailable — start empty
    }
  }

  private persist(): void {
    this.persistAsync().catch((err) => {
      console.error('[nco-web-editor] Failed to persist queue:', err);
    });
  }

  private async persistAsync(): Promise<void> {
    try {
      await chrome.storage.session.set({ [STORAGE_KEY]: this.items });
    } catch {
      // Non-fatal
    }
  }

  // -----------------------------------------------------------------------
  // Deduplication
  // -----------------------------------------------------------------------

  /**
   * Collapse duplicate property edits on the same element.
   * If a pending diff already has a change for the same element+property,
   * update it to the latest value instead of adding a new diff.
   * Only collapses into pending items — sent/applied items are immutable.
   * Returns true if the newDiff was fully collapsed (should not be added).
   */
  private collapseExisting(newDiff: VisualDiff): boolean {
    for (let i = 0; i < this.items.length; i++) {
      const item = this.items[i];
      if (item.removedAt) continue;
      if (item.lifecycleStatus && item.lifecycleStatus !== 'pending') continue;
      if (item.diff.element.selector !== newDiff.element.selector) continue;

      // Same element — check for overlapping property changes
      const existingProps = new Set(item.diff.changes.map((c) => c.property));
      const overlapping = newDiff.changes.filter((c) => existingProps.has(c.property));

      let cssCollapsed = false;
      let updatedDiff = item.diff;

      if (overlapping.length > 0) {
        // Build a merged changes array: keep original fromValue, use new toValue
        const newPropsMap = new Map(newDiff.changes.map((c) => [c.property, c]));
        const mergedChanges = item.diff.changes.map((c) => {
          const updated = newPropsMap.get(c.property);
          if (updated) {
            return { ...c, toValue: updated.toValue, toToken: updated.toToken };
          }
          return c;
        });
        updatedDiff = { ...updatedDiff, changes: mergedChanges };
        const remaining = newDiff.changes.filter((c) => !existingProps.has(c.property));
        cssCollapsed = remaining.length === 0;
      }

      // Collapse overlapping attribute changes
      const newAttrs = newDiff.attributeChanges ?? [];
      const existingAttrs = item.diff.attributeChanges ?? [];
      let attrCollapsed = false;

      if (newAttrs.length > 0 && existingAttrs.length > 0) {
        const existingAttrNames = new Set(existingAttrs.map((a) => a.attribute));
        const attrOverlap = newAttrs.filter((a) => existingAttrNames.has(a.attribute));

        if (attrOverlap.length > 0) {
          const newAttrMap = new Map(newAttrs.map((a) => [a.attribute, a]));
          const mergedAttrs = existingAttrs.map((a) => {
            const updated = newAttrMap.get(a.attribute);
            return updated ? { ...a, toValue: updated.toValue } : a;
          });
          updatedDiff = { ...updatedDiff, attributeChanges: mergedAttrs };
          const remainingAttrs = newAttrs.filter((a) => !existingAttrNames.has(a.attribute));
          attrCollapsed = remainingAttrs.length === 0;
        }
      }

      if (updatedDiff !== item.diff) {
        this.items[i] = { ...item, diff: updatedDiff };
      }

      // Fully collapsed if both CSS and attribute changes were absorbed
      const cssDone = overlapping.length === 0 ? newDiff.changes.length === 0 : cssCollapsed;
      const attrDone = newAttrs.length === 0 || attrCollapsed;
      if (cssDone && attrDone) {
        return true;
      }
    }
    return false;
  }

  private notify(): void {
    for (const cb of this.changeCallbacks) cb();
  }
}
