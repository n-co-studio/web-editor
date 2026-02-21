import type { VisualDiff } from '@frontend-editor/shared';

/**
 * Tracks committed edits for undo/redo/reset.
 *
 * Discriminated union on `type`:
 *  - 'css'     — inline style changes (spacing, dimensions, typography, etc.)
 *  - 'removal' — element deleted from DOM
 *  - 'reorder' — element moved within its parent container (stub: Phase 2 adds drag, Phase 3 adds undo/redo)
 */

interface CssHistoryEntry {
  readonly type: 'css';
  readonly element: HTMLElement;
  readonly changes: ReadonlyArray<{ property: string; fromValue: string; toValue: string }>;
  readonly diff: VisualDiff;
}

interface RemovalHistoryEntry {
  readonly type: 'removal';
  readonly element: HTMLElement;
  readonly changes: ReadonlyArray<{ property: string; fromValue: string; toValue: string }>;
  readonly diff: VisualDiff;
  readonly parent: Node;
  readonly nextSibling: Node | null;
}

interface ReorderHistoryEntry {
  readonly type: 'reorder';
  readonly element: HTMLElement;
  readonly container: HTMLElement;
  readonly fromIndex: number;
  readonly toIndex: number;
  readonly originalChildOrder: HTMLElement[];
  readonly diff: VisualDiff;
}

export type HistoryEntry = CssHistoryEntry | RemovalHistoryEntry | ReorderHistoryEntry;

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

    switch (entry.type) {
      case 'css':
        for (const c of entry.changes) {
          if (c.fromValue) {
            entry.element.style.setProperty(c.property, c.fromValue);
          } else {
            entry.element.style.removeProperty(c.property);
          }
        }
        break;
      case 'removal':
        entry.parent.insertBefore(entry.element, entry.nextSibling);
        break;
      case 'reorder':
        // Stub — Phase 3 implements reorder undo logic
        console.warn('[frontend-editor] Reorder undo not yet implemented');
        break;
    }

    this.redoStack.push(entry);
    this.notify();
    return entry;
  }

  /** Redo the most recently undone edit. Returns the entry that was redone, or null. */
  redo(): HistoryEntry | null {
    const entry = this.redoStack.pop();
    if (!entry) return null;

    switch (entry.type) {
      case 'css':
        for (const c of entry.changes) {
          entry.element.style.setProperty(c.property, c.toValue);
        }
        break;
      case 'removal':
        entry.element.remove();
        break;
      case 'reorder':
        // Stub — Phase 3 implements reorder redo logic
        console.warn('[frontend-editor] Reorder redo not yet implemented');
        break;
    }

    this.undoStack.push(entry);
    this.notify();
    return entry;
  }

  /**
   * Reset all edits — reverts every change in reverse order.
   * Returns the list of diff IDs that were undone.
   */
  resetAll(): string[] {
    const diffIds: string[] = [];

    // Revert undo stack in reverse (most recent first)
    for (let i = this.undoStack.length - 1; i >= 0; i--) {
      const entry = this.undoStack[i];
      switch (entry.type) {
        case 'css':
          for (const c of entry.changes) {
            if (c.fromValue) {
              entry.element.style.setProperty(c.property, c.fromValue);
            } else {
              entry.element.style.removeProperty(c.property);
            }
          }
          break;
        case 'removal':
          entry.parent.insertBefore(entry.element, entry.nextSibling);
          break;
        case 'reorder':
          // Stub — Phase 3 implements reorder reset logic
          console.warn('[frontend-editor] Reorder reset not yet implemented');
          break;
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
