import type { VisualDiff } from '@frontend-editor/shared';
import { MAX_DIFFS_PER_BATCH } from '../../shared/constants';
import type { PendingEdit } from '../../shared/types';

const STORAGE_KEY = 'frontend-editor-pending-queue';

/**
 * Manages the pending edit queue with chrome.storage.session persistence.
 * Handles deduplication, collapse, reconciliation with the server,
 * and the "Removed" section (soft-delete with restore).
 */
export class PendingQueue {
  private items: PendingEdit[] = [];
  private changeCallbacks: Array<() => void> = [];

  /** Number of active (non-removed) items in the queue. */
  get count(): number {
    return this.items.filter((i) => !i.removedAt).length;
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

  /** Get all active (non-removed) diffs. */
  getActive(): VisualDiff[] {
    return this.items.filter((i) => !i.removedAt).map((i) => i.diff);
  }

  /** Get removed items. */
  getRemoved(): PendingEdit[] {
    return this.items.filter((i) => i.removedAt);
  }

  /** Get all diff IDs (including removed — for reconciliation). */
  getDiffIds(): string[] {
    return this.items.map((i) => i.diffId);
  }

  /**
   * Get active diffs ready to send. Enforces MAX_DIFFS_PER_BATCH.
   * Returns the batch and whether more remain.
   */
  getBatch(): { diffs: VisualDiff[]; hasMore: boolean } {
    const active = this.getActive();
    if (active.length <= MAX_DIFFS_PER_BATCH) {
      return { diffs: active, hasMore: false };
    }
    return {
      diffs: active.slice(0, MAX_DIFFS_PER_BATCH),
      hasMore: true,
    };
  }

  /**
   * Reconcile with server on reconnect.
   * Removes diffs the server already has (by ID).
   */
  reconcile(serverKnownIds: readonly string[]): void {
    const known = new Set(serverKnownIds);
    this.items = this.items.filter((i) => !known.has(i.diffId));
    this.persist();
    this.notify();
  }

  /**
   * Acknowledge diffs that were successfully sent.
   * Called when DIFF_ACK is received.
   */
  acknowledge(diffIds: readonly string[]): void {
    const acked = new Set(diffIds);
    this.items = this.items.filter((i) => !acked.has(i.diffId));
    this.persist();
    this.notify();
  }

  /** Clear all items. */
  clear(): void {
    this.items = [];
    this.persist();
    this.notify();
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
      console.error('[frontend-editor] Failed to persist queue:', err);
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
   * Returns true if the newDiff was fully collapsed (should not be added).
   */
  private collapseExisting(newDiff: VisualDiff): boolean {
    for (let i = 0; i < this.items.length; i++) {
      const item = this.items[i];
      if (item.removedAt) continue;
      if (item.diff.element.selector !== newDiff.element.selector) continue;

      // Same element — check for overlapping property changes
      const existingProps = new Set(item.diff.changes.map((c) => c.property));
      const overlapping = newDiff.changes.filter((c) => existingProps.has(c.property));

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

        // Replace the item's diff with a new object (avoids readonly mutation)
        this.items[i] = {
          ...item,
          diff: { ...item.diff, changes: mergedChanges },
        };

        // Check if all new changes were collapsed
        const remaining = newDiff.changes.filter((c) => !existingProps.has(c.property));
        if (remaining.length === 0) {
          return true; // fully collapsed
        }
      }
    }
    return false;
  }

  private notify(): void {
    for (const cb of this.changeCallbacks) cb();
  }
}
