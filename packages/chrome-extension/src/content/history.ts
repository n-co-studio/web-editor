import type { VisualDiff, AttributeChange } from '@nco-studio/shared';

/**
 * Tracks committed edits for undo/redo/reset.
 *
 * Discriminated union on `type`:
 *  - 'css'       — inline style changes (spacing, dimensions, typography, etc.)
 *  - 'removal'   — element deleted from DOM
 *  - 'reorder'   — element moved within its parent container
 *  - 'insertion' — new element inserted into a container
 *
 * Stable-element-identity note (issue #27): replay resolves elements by the live
 * DOM node references held on each entry (`element`, `oldEl`/`newEl`, `parent`,
 * `container`), never by selector or source coordinate, so undo/redo is
 * inherently `data-fe-uid`-compatible — a re-inserted node keeps its uid
 * attribute, and the stored `diff` already carries the uid via its ElementInfo
 * (assigned in `buildElementInfo`). No uid-specific replay logic is required.
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

interface ReparentHistoryEntry {
  readonly type: 'reparent';
  readonly element: HTMLElement;
  readonly sourceContainer: HTMLElement;
  readonly sourceIndex: number;
  readonly targetContainer: HTMLElement;
  readonly targetIndex: number;
  readonly diff: VisualDiff;
}

interface AttributeHistoryEntry {
  readonly type: 'attribute';
  readonly element: HTMLElement;
  readonly attributeChanges: readonly AttributeChange[];
  readonly diff: VisualDiff;
}

interface TextHistoryEntry {
  readonly type: 'text';
  readonly element: HTMLElement;
  readonly fromText: string;
  readonly toText: string;
  /** Pre-edit innerHTML (feature-012). When present, undo restores innerHTML instead of textContent. */
  readonly fromHtml?: string;
  /** Post-edit innerHTML (feature-012). When present, redo restores innerHTML instead of textContent. */
  readonly toHtml?: string;
  readonly diff: VisualDiff;
}

/**
 * In-place element swap (e.g. parallax conversion: <img> ⇄ <div>).
 * `oldEl` was replaced by `newEl` within `parent`. Reversed via replaceChild.
 */
interface ReplaceHistoryEntry {
  readonly type: 'replace';
  readonly element: HTMLElement; // the new element (current in DOM after the edit)
  readonly parent: HTMLElement;
  readonly oldEl: HTMLElement;
  readonly newEl: HTMLElement;
  readonly diff: VisualDiff;
}

export type HistoryEntry = CssHistoryEntry | RemovalHistoryEntry | ReorderHistoryEntry | InsertionHistoryEntry | GroupHistoryEntry | ReparentHistoryEntry | AttributeHistoryEntry | TextHistoryEntry | ReplaceHistoryEntry;

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
      case 'reparent': {
        // Move element back to source container at original position
        const srcChildren = Array.from(entry.sourceContainer.children)
          .filter((c): c is HTMLElement => c instanceof HTMLElement);
        const refNode = entry.sourceIndex < srcChildren.length ? srcChildren[entry.sourceIndex] : null;
        if ('moveBefore' in entry.sourceContainer && typeof (entry.sourceContainer as any).moveBefore === 'function') {
          (entry.sourceContainer as any).moveBefore(entry.element, refNode);
        } else {
          entry.sourceContainer.insertBefore(entry.element, refNode);
        }
        break;
      }
      case 'attribute':
        for (const ac of entry.attributeChanges) {
          if (ac.fromValue) {
            entry.element.setAttribute(ac.attribute, ac.fromValue);
          } else {
            entry.element.removeAttribute(ac.attribute);
          }
        }
        break;
      case 'text':
        // feature-012: restore innerHTML when markup fields are present (backward compat)
        if (entry.fromHtml !== undefined) {
          entry.element.innerHTML = entry.fromHtml;
        } else {
          entry.element.textContent = entry.fromText;
        }
        break;
      case 'replace':
        // Undo: put the original element back in place of the new one.
        if (entry.newEl.parentNode === entry.parent) {
          entry.parent.replaceChild(entry.oldEl, entry.newEl);
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
      case 'reparent': {
        // Re-apply reparent: move element to target container
        const tgtChildren = Array.from(entry.targetContainer.children)
          .filter((c): c is HTMLElement => c instanceof HTMLElement && c !== entry.element);
        const tgtRef = entry.targetIndex < tgtChildren.length ? tgtChildren[entry.targetIndex] : null;
        if ('moveBefore' in entry.targetContainer && typeof (entry.targetContainer as any).moveBefore === 'function') {
          (entry.targetContainer as any).moveBefore(entry.element, tgtRef);
        } else {
          entry.targetContainer.insertBefore(entry.element, tgtRef);
        }
        break;
      }
      case 'attribute':
        for (const ac of entry.attributeChanges) {
          entry.element.setAttribute(ac.attribute, ac.toValue);
        }
        break;
      case 'text':
        // feature-012: restore innerHTML when markup fields are present (backward compat)
        if (entry.toHtml !== undefined) {
          entry.element.innerHTML = entry.toHtml;
        } else {
          entry.element.textContent = entry.toText;
        }
        break;
      case 'replace':
        // Redo: re-apply the swap (old → new).
        if (entry.oldEl.parentNode === entry.parent) {
          entry.parent.replaceChild(entry.newEl, entry.oldEl);
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
        case 'reparent': {
          const srcChildren = Array.from(entry.sourceContainer.children)
            .filter((c): c is HTMLElement => c instanceof HTMLElement);
          const refNode = entry.sourceIndex < srcChildren.length ? srcChildren[entry.sourceIndex] : null;
          if ('moveBefore' in entry.sourceContainer && typeof (entry.sourceContainer as any).moveBefore === 'function') {
            (entry.sourceContainer as any).moveBefore(entry.element, refNode);
          } else {
            entry.sourceContainer.insertBefore(entry.element, refNode);
          }
          break;
        }
        case 'attribute':
          for (const ac of entry.attributeChanges) {
            if (ac.fromValue) {
              entry.element.setAttribute(ac.attribute, ac.fromValue);
            } else {
              entry.element.removeAttribute(ac.attribute);
            }
          }
          break;
        case 'text':
          // feature-012: restore innerHTML when markup fields are present (backward compat)
          if (entry.fromHtml !== undefined) {
            entry.element.innerHTML = entry.fromHtml;
          } else {
            entry.element.textContent = entry.fromText;
          }
          break;
        case 'replace':
          if (entry.newEl.parentNode === entry.parent) {
            entry.parent.replaceChild(entry.oldEl, entry.newEl);
          }
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
