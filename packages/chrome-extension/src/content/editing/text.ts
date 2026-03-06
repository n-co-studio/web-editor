/**
 * TextEditor — inline text editing via contenteditable.
 *
 * When activated on a selected element, the editor:
 * 1. Saves the original textContent
 * 2. Makes the element contenteditable
 * 3. Focuses and selects all text
 * 4. On blur or Enter, captures the new text, reverts contenteditable,
 *    and fires the commit callback with a TextChange
 *
 * For newly inserted elements, call `editElement()` directly to
 * auto-focus for immediate text input.
 */

import type { TextChange } from '@frontend-editor/shared';

type TextCommitCallback = (change: TextChange) => void;

// ---------------------------------------------------------------------------
// Block-reason guard
// ---------------------------------------------------------------------------

/** Tags that typically contain direct text content and are safe to edit. */
const TEXT_TAGS = new Set([
  'P', 'SPAN', 'A', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6',
  'LABEL', 'BUTTON', 'LI', 'TD', 'TH', 'CAPTION', 'FIGCAPTION',
  'BLOCKQUOTE', 'CITE', 'EM', 'STRONG', 'SMALL', 'B', 'I', 'U',
  'CODE', 'PRE', 'MARK', 'DEL', 'INS', 'SUB', 'SUP', 'DT', 'DD',
  'SUMMARY', 'LEGEND', 'OPTION',
]);

/**
 * Returns a human-readable reason why text editing is blocked for this element,
 * or null if the element supports text editing.
 */
export function getTextBlockReason(element: Element): string | null {
  // Allow any element that has direct text content (text node children)
  if (TEXT_TAGS.has(element.tagName)) return null;

  // Also allow DIV elements that have direct text nodes
  if (element.tagName === 'DIV') {
    const hasTextNode = Array.from(element.childNodes).some(
      (n) => n.nodeType === Node.TEXT_NODE && n.textContent?.trim(),
    );
    if (hasTextNode) return null;
    // Empty divs are allowed too (for adding text)
    if (element.childNodes.length === 0) return null;
  }

  return 'Element does not contain editable text';
}

// ---------------------------------------------------------------------------
// TextEditor
// ---------------------------------------------------------------------------

export class TextEditor {
  private activeElement: HTMLElement | null = null;
  private originalText: string = '';
  private commitCb: TextCommitCallback | null = null;
  private closeCb: (() => void) | null = null;
  private blurHandler: (() => void) | null = null;
  private keydownHandler: ((e: KeyboardEvent) => void) | null = null;

  onClose(cb: () => void): void {
    this.closeCb = cb;
  }

  isActive(): boolean {
    return this.activeElement !== null;
  }

  /**
   * Begin editing text on the given element.
   * The element becomes contenteditable with text selected.
   */
  editElement(element: HTMLElement, onCommit: TextCommitCallback): void {
    this.cleanup();

    this.activeElement = element;
    this.originalText = element.textContent ?? '';
    this.commitCb = onCommit;

    // Make editable
    element.contentEditable = 'true';
    element.style.outline = '2px solid rgba(6, 182, 212, 0.6)';
    element.style.outlineOffset = '2px';
    element.style.cursor = 'text';

    // Focus and select all text
    element.focus();
    const range = document.createRange();
    range.selectNodeContents(element);
    const sel = window.getSelection();
    sel?.removeAllRanges();
    sel?.addRange(range);

    // Bind handlers
    this.blurHandler = () => this.finishEditing();
    this.keydownHandler = (e: KeyboardEvent) => {
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        this.finishEditing();
      } else if (e.key === 'Escape') {
        e.preventDefault();
        this.cancelEditing();
      }
    };

    element.addEventListener('blur', this.blurHandler);
    element.addEventListener('keydown', this.keydownHandler);
  }

  /** No-op — TextEditor has no positioned mini panel. */
  reposition(_anchorPos: { x: number; y: number }): void {}

  /** Clean up editing state without committing. */
  cleanup(): void {
    if (this.activeElement) {
      this.removeEditableState(this.activeElement);
    }
    this.activeElement = null;
    this.originalText = '';
    this.commitCb = null;
    this.blurHandler = null;
    this.keydownHandler = null;
  }

  // -----------------------------------------------------------------------
  // Internal
  // -----------------------------------------------------------------------

  private finishEditing(): void {
    if (!this.activeElement) return;

    const newText = this.activeElement.textContent ?? '';
    const element = this.activeElement;
    const originalText = this.originalText;
    const commitCb = this.commitCb;

    this.removeEditableState(element);
    this.activeElement = null;
    this.commitCb = null;

    // Only commit if text actually changed
    if (newText !== originalText) {
      commitCb?.({
        type: 'text',
        fromText: originalText,
        toText: newText,
      });
    }

    this.closeCb?.();
  }

  private cancelEditing(): void {
    if (!this.activeElement) return;

    // Revert to original text
    this.activeElement.textContent = this.originalText;
    this.removeEditableState(this.activeElement);
    this.activeElement = null;
    this.commitCb = null;

    this.closeCb?.();
  }

  private removeEditableState(element: HTMLElement): void {
    if (this.blurHandler) {
      element.removeEventListener('blur', this.blurHandler);
    }
    if (this.keydownHandler) {
      element.removeEventListener('keydown', this.keydownHandler);
    }
    element.contentEditable = 'false';
    element.style.outline = '';
    element.style.outlineOffset = '';
    element.style.cursor = '';

    // Clear selection
    window.getSelection()?.removeAllRanges();
  }
}
