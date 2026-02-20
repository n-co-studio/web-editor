import type { VisualDiff } from '@frontend-editor/shared';

/**
 * Tracks committed CSS edits for undo/redo/reset.
 *
 * Each entry stores the target element and the CSS property changes
 * (fromValue/toValue) so we can revert or re-apply inline styles.
 * The VisualDiff is retained so callers can sync with the PendingQueue.
 */

export interface HistoryEntry {
  readonly element: HTMLElement;
  readonly changes: ReadonlyArray<{ property: string; fromValue: string; toValue: string }>;
  readonly diff: VisualDiff;
}

type HistoryCallback = () => void;

export class EditHistory {
  private undoStack: HistoryEntry[] = [];
  private redoStack: HistoryEntry[] = [];
  private changeCbs: HistoryCallback[] = [];

  /** Push a new edit onto the undo stack (clears redo). */
  push(entry: HistoryEntry): void {
    this.undoStack.push(entry);
    this.redoStack = [];
    this.notify();
  }

  /** Undo the most recent edit. Returns the entry that was undone, or null. */
  undo(): HistoryEntry | null {
    const entry = this.undoStack.pop();
    if (!entry) return null;

    // Revert inline styles
    for (const c of entry.changes) {
      if (c.fromValue) {
        entry.element.style.setProperty(c.property, c.fromValue);
      } else {
        entry.element.style.removeProperty(c.property);
      }
    }

    this.redoStack.push(entry);
    this.notify();
    return entry;
  }

  /** Redo the most recently undone edit. Returns the entry that was redone, or null. */
  redo(): HistoryEntry | null {
    const entry = this.redoStack.pop();
    if (!entry) return null;

    // Re-apply inline styles
    for (const c of entry.changes) {
      entry.element.style.setProperty(c.property, c.toValue);
    }

    this.undoStack.push(entry);
    this.notify();
    return entry;
  }

  /**
   * Reset all edits — reverts every inline style change in reverse order.
   * Returns the list of diff IDs that were undone.
   */
  resetAll(): string[] {
    const diffIds: string[] = [];

    // Revert undo stack in reverse (most recent first)
    for (let i = this.undoStack.length - 1; i >= 0; i--) {
      const entry = this.undoStack[i];
      for (const c of entry.changes) {
        if (c.fromValue) {
          entry.element.style.setProperty(c.property, c.fromValue);
        } else {
          entry.element.style.removeProperty(c.property);
        }
      }
      diffIds.push(entry.diff.id);
    }

    this.undoStack = [];
    this.redoStack = [];
    this.notify();
    return diffIds;
  }

  get canUndo(): boolean {
    return this.undoStack.length > 0;
  }

  get canRedo(): boolean {
    return this.redoStack.length > 0;
  }

  get undoCount(): number {
    return this.undoStack.length;
  }

  /** Register callback for stack changes. */
  onChange(cb: HistoryCallback): void {
    this.changeCbs.push(cb);
  }

  /** Clear all history without reverting styles. */
  clear(): void {
    this.undoStack = [];
    this.redoStack = [];
    this.notify();
  }

  private notify(): void {
    for (const cb of this.changeCbs) cb();
  }
}
