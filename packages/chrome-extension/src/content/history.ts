import type { VisualDiff, AttributeChange } from '@frontend-editor/shared';

/**
 * Tracks committed edits for undo/redo/reset.
 *
 * Discriminated union on `type`:
 *  - 'css'       — inline style changes (spacing, dimensions, typography, etc.)
 *  - 'removal'   — element deleted from DOM
 *  - 'reorder'   — element moved within its parent container
 *  - 'insertion' — new element inserted into a container
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

interface InsertionHistoryEntry {
  readonly type: 'insertion';
  readonly element: HTMLElement;
  readonly container: HTMLElement;
  readonly insertIndex: number;
  readonly diff: VisualDiff;
}

interface GroupHistoryEntry {
  readonly type: 'group';
  readonly wrapper: HTMLElement;
  readonly originalParent: HTMLElement;
  readonly originalPositions: ReadonlyArray<{ element: HTMLElement; nextSibling: Node | null }>;
  readonly diff: VisualDiff;
}

interface AttributeHistoryEntry {
  readonly type: 'attribute';
  readonly element: HTMLElement;
  readonly attributeChanges: readonly AttributeChange[];
  readonly diff: VisualDiff;
}

export type HistoryEntry = CssHistoryEntry | RemovalHistoryEntry | ReorderHistoryEntry | InsertionHistoryEntry | GroupHistoryEntry | AttributeHistoryEntry;

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
      case 'reorder': {
        const container = entry.container;
        for (const child of entry.originalChildOrder) {
          if ('moveBefore' in container && typeof (container as any).moveBefore === 'function') {
            (container as any).moveBefore(child, null);
          } else {
            container.insertBefore(child, null);
          }
        }
        break;
      }
      case 'insertion':
        entry.element.remove();
        break;
      case 'group':
        // Iterate in reverse so each nextSibling is already back in the parent
        for (let gi = entry.originalPositions.length - 1; gi >= 0; gi--) {
          const pos = entry.originalPositions[gi];
          entry.originalParent.insertBefore(pos.element, pos.nextSibling);
        }
        entry.wrapper.remove();
        break;
      case 'attribute':
        for (const ac of entry.attributeChanges) {
          if (ac.fromValue) {
            entry.element.setAttribute(ac.attribute, ac.fromValue);
          } else {
            entry.element.removeAttribute(ac.attribute);
          }
        }
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
      case 'reorder': {
        const container = entry.container;
        const el = entry.element;
        const remaining = entry.originalChildOrder.filter((_, i) => i !== entry.fromIndex);
        const effectiveIdx = entry.toIndex > entry.fromIndex ? entry.toIndex - 1 : entry.toIndex;
        const refNode = effectiveIdx < remaining.length ? remaining[effectiveIdx] : null;
        if ('moveBefore' in container && typeof (container as any).moveBefore === 'function') {
          (container as any).moveBefore(el, refNode);
        } else {
          container.insertBefore(el, refNode);
        }
        break;
      }
      case 'insertion':
        entry.container.insertBefore(entry.element, entry.container.children[entry.insertIndex] || null);
        break;
      case 'group': {
        // Insert wrapper before the first grouped element (back in parent after undo)
        const firstEl = entry.originalPositions[0]?.element ?? null;
        entry.originalParent.insertBefore(entry.wrapper, firstEl);
        // Move elements into wrapper in DOM order
        for (const pos of entry.originalPositions) {
          entry.wrapper.appendChild(pos.element);
        }
        break;
      }
      case 'attribute':
        for (const ac of entry.attributeChanges) {
          entry.element.setAttribute(ac.attribute, ac.toValue);
        }
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
        case 'reorder': {
          const container = entry.container;
          for (const child of entry.originalChildOrder) {
            if ('moveBefore' in container && typeof (container as any).moveBefore === 'function') {
              (container as any).moveBefore(child, null);
            } else {
              container.insertBefore(child, null);
            }
          }
          break;
        }
        case 'insertion':
          entry.element.remove();
          break;
        case 'group':
          for (let gi = entry.originalPositions.length - 1; gi >= 0; gi--) {
            const pos = entry.originalPositions[gi];
            entry.originalParent.insertBefore(pos.element, pos.nextSibling);
          }
          entry.wrapper.remove();
          break;
      }
      diffIds.push(entry.diff.id);
    }

    this.undoStack = [];
    this.redoStack = [];
    this.notify();
    return diffIds;
  }

  /** Peek at the top undo entry without modifying the stack. */
  peekUndo(): HistoryEntry | null {
    return this.undoStack.length > 0 ? this.undoStack[this.undoStack.length - 1] : null;
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
