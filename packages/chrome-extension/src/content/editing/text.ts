/**
 * TextEditor — inline text editing via contenteditable.
 *
 * When activated on a selected element, the editor:
 * 1. Saves the original textContent AND innerHTML (for markup restore)
 * 2. Makes the element contenteditable
 * 3. Focuses and selects all text
 * 4. Shows a mini-toolbar over the selection for bold/italic/underline/strike
 * 5. On blur or Enter, captures the new text + sanitized markup, reverts
 *    contenteditable, and fires the commit callback with a TextChange
 * 6. On Escape, restores exact pre-edit innerHTML (not just textContent)
 *
 * For newly inserted elements, call `editElement()` directly to
 * auto-focus for immediate text input.
 *
 * feature-012: Inline Text Styling
 */

import type { TextChange } from '@nco-studio/shared';
import { OVERLAY } from '../../shared/constants';
import {
  type FormatMark,
  toggleMark,
  clearFormatting,
  getFormatState,
  normalizeInlineMarkup,
  serializeAllowedHtml,
  clampRangeToRoot,
} from './inline-format';

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

// Tags whose native key handling synthesizes a click on Space — left to the
// browser, that click fires document-level handlers that re-select the
// element and tear down the editor mid-edit. We swallow the default and
// insert a space manually so typing continues normally.
const ACTIVATE_ON_SPACE = new Set(['BUTTON', 'SUMMARY']);

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
// Mini-toolbar constants
// ---------------------------------------------------------------------------

const TOOLBAR_HEIGHT_PX = 40;
const TOOLBAR_ABOVE_OFFSET_PX = 8;
const TOOLBAR_VIEWPORT_MARGIN_PX = 8;

// Keyboard shortcut map: key → FormatMark
const SHORTCUT_MAP: Record<string, FormatMark> = {
  b: 'bold',
  i: 'italic',
  u: 'underline',
};

// SVG icons (16×16, currentColor)
const ICONS: Record<FormatMark | 'clear', string> = {
  bold: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><text x="3" y="13" font-size="13" font-weight="700" font-family="serif" fill="currentColor">B</text></svg>',
  italic: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><text x="4" y="13" font-size="13" font-style="italic" font-family="serif" fill="currentColor">I</text></svg>',
  underline: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><text x="3" y="11" font-size="11" font-family="sans-serif" fill="currentColor" text-decoration="underline">U</text><line x1="2" y1="14" x2="14" y2="14" stroke="currentColor" stroke-width="1.5"/></svg>',
  strike: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><text x="3" y="12" font-size="11" font-family="sans-serif" fill="currentColor">S</text><line x1="1" y1="8" x2="15" y2="8" stroke="currentColor" stroke-width="1.5"/></svg>',
  clear: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><line x1="3" y1="3" x2="13" y2="13" stroke="currentColor" stroke-width="1.5"/><line x1="13" y1="3" x2="3" y2="13" stroke="currentColor" stroke-width="1.5"/></svg>',
};

const BUTTON_LABELS: Record<FormatMark | 'clear', string> = {
  bold: 'Bold (Cmd+B)',
  italic: 'Italic (Cmd+I)',
  underline: 'Underline (Cmd+U)',
  strike: 'Strikethrough',
  clear: 'Clear Formatting',
};

// ---------------------------------------------------------------------------
// TextEditor
// ---------------------------------------------------------------------------

export class TextEditor {
  private shadow: ShadowRoot | null = null;
  private activeElement: HTMLElement | null = null;
  private originalText: string = '';
  private originalHtml: string = '';
  private commitCb: TextCommitCallback | null = null;
  private closeCb: (() => void) | null = null;
  private blurHandler: (() => void) | null = null;
  private keydownHandler: ((e: KeyboardEvent) => void) | null = null;
  private selectionchangeHandler: (() => void) | null = null;
  private pasteHandler: ((e: ClipboardEvent) => void) | null = null;
  private keyShieldHandler: ((e: KeyboardEvent) => void) | null = null;
  private toolbar: HTMLElement | null = null;
  private toolbarButtons: Map<FormatMark, HTMLButtonElement> = new Map();

  constructor(shadow?: ShadowRoot) {
    this.shadow = shadow ?? null;
  }

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
    this.originalHtml = element.innerHTML;
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

    // Build mini-toolbar (attaches to shadow root)
    if (this.shadow) {
      this.toolbar = this.buildToolbar(element);
      this.shadow.appendChild(this.toolbar);
    }

    // Bind handlers
    this.blurHandler = () => this.finishEditing();
    this.keydownHandler = (e: KeyboardEvent) => this.handleKeydown(e, element);
    this.pasteHandler = (e: ClipboardEvent) => this.handlePaste(e);
    this.selectionchangeHandler = () => this.repositionToolbar(element);

    // Key shield: intercept key events at window capture phase so keys typed
    // in the editor never reach page-level shortcut listeners (e.g. arrow-key
    // overlay toggles). stopPropagation only — default caret/typing behavior
    // is unaffected. Capture delivery precedes the target, so the shield also
    // dispatches the editor's keydown logic (replaces the element binding).
    this.keyShieldHandler = (e: KeyboardEvent) => {
      const el = this.activeElement;
      if (!el) return;
      const target = e.target as Node | null;
      if (!target || (target !== el && !el.contains(target))) return;
      if (e.type === 'keydown') {
        this.keydownHandler?.(e);
      }
      e.stopPropagation();
    };

    element.addEventListener('blur', this.blurHandler);
    element.addEventListener('paste', this.pasteHandler);
    window.addEventListener('keydown', this.keyShieldHandler, true);
    window.addEventListener('keypress', this.keyShieldHandler, true);
    window.addEventListener('keyup', this.keyShieldHandler, true);
    document.addEventListener('selectionchange', this.selectionchangeHandler);
    window.addEventListener('scroll', this.selectionchangeHandler, { passive: true });
    window.addEventListener('resize', this.selectionchangeHandler, { passive: true });
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
    this.originalHtml = '';
    this.commitCb = null;
    this.blurHandler = null;
    this.keydownHandler = null;
    this.keyShieldHandler = null;
    this.selectionchangeHandler = null;
    this.pasteHandler = null;
    this.toolbarButtons.clear();
  }

  // -----------------------------------------------------------------------
  // Internal
  // -----------------------------------------------------------------------

  private handleKeydown(e: KeyboardEvent, element: HTMLElement): void {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      this.finishEditing();
    } else if (e.key === 'Escape') {
      e.preventDefault();
      this.cancelEditing();
    } else if (e.key === ' ' && ACTIVATE_ON_SPACE.has(element.tagName)) {
      // Suppress the browser's default click synthesis on Space, then
      // insert the literal space ourselves so the operator's typing
      // continues uninterrupted.
      e.preventDefault();
      document.execCommand('insertText', false, ' ');
    } else if ((e.metaKey || e.ctrlKey) && !e.shiftKey && !e.altKey) {
      const mark = SHORTCUT_MAP[e.key.toLowerCase()];
      if (mark) {
        e.preventDefault();
        this.applyFormatFromShortcut(mark, element);
      }
    }
  }

  private handlePaste(e: ClipboardEvent): void {
    // Force plain-text paste — never let rich HTML enter the contenteditable
    e.preventDefault();
    const text = e.clipboardData?.getData('text/plain') ?? '';
    if (text) {
      document.execCommand('insertText', false, text);
    }
  }

  private applyFormatFromShortcut(mark: FormatMark, element: HTMLElement): void {
    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0) return;
    const raw = sel.getRangeAt(0);
    const range = clampRangeToRoot(raw, element);
    if (!range) return;

    toggleMark(range, mark, element);

    // Re-assert selection after DOM mutation
    sel.removeAllRanges();
    sel.addRange(range);
    this.refreshToolbarState(element);
  }

  private finishEditing(): void {
    if (!this.activeElement) return;

    const element = this.activeElement;
    const originalText = this.originalText;
    const originalHtml = this.originalHtml;
    const commitCb = this.commitCb;

    // Run final normalization before reading the committed markup
    normalizeInlineMarkup(element);

    const newText = element.textContent ?? '';
    const newHtml = serializeAllowedHtml(element);

    // Sanitize the original for comparison — strip non-allowed markup
    // to match what we'd have committed if the session had started with markup
    const sanitizedOriginalHtml = this.sanitizeHtmlForComparison(originalHtml, element);

    this.removeEditableState(element);
    this.activeElement = null;
    this.commitCb = null;

    // fromHtml present when original had markup; toHtml present when result has markup.
    // "has markup" = serialized HTML differs from plain text (contains tags).
    const hasFromMarkup = sanitizedOriginalHtml !== originalText;
    const hasToMarkup = newHtml !== newText;
    const textChanged = newText !== originalText;
    const markupChanged = newHtml !== sanitizedOriginalHtml;

    if (textChanged || markupChanged) {
      const finalChange: TextChange = {
        type: 'text',
        fromText: originalText,
        toText: newText,
        ...(hasFromMarkup ? { fromHtml: sanitizedOriginalHtml } : {}),
        ...(hasToMarkup ? { toHtml: newHtml } : {}),
      };

      commitCb?.(finalChange);
    }

    this.closeCb?.();
  }

  /**
   * Sanitize a raw innerHTML string for comparison by running it through
   * the allowlist serializer. Uses a temporary element in the document.
   */
  private sanitizeHtmlForComparison(html: string, refElement: HTMLElement): string {
    // If the original HTML has no markup tags, just return the text
    if (!html.includes('<')) return escapeTextForHtml(html);

    // Use a detached element to parse and re-serialize
    const tmp = refElement.ownerDocument?.createElement('div') ?? document.createElement('div');
    tmp.innerHTML = html;
    return serializeAllowedHtml(tmp);
  }

  private cancelEditing(): void {
    if (!this.activeElement) return;

    // Restore exact pre-edit markup (not just textContent)
    this.activeElement.innerHTML = this.originalHtml;
    this.removeEditableState(this.activeElement);
    this.activeElement = null;
    this.commitCb = null;

    this.closeCb?.();
  }

  private removeEditableState(element: HTMLElement): void {
    if (this.blurHandler) {
      element.removeEventListener('blur', this.blurHandler);
    }
    if (this.keyShieldHandler) {
      window.removeEventListener('keydown', this.keyShieldHandler, true);
      window.removeEventListener('keypress', this.keyShieldHandler, true);
      window.removeEventListener('keyup', this.keyShieldHandler, true);
    }
    if (this.pasteHandler) {
      element.removeEventListener('paste', this.pasteHandler);
    }
    if (this.selectionchangeHandler) {
      document.removeEventListener('selectionchange', this.selectionchangeHandler);
      window.removeEventListener('scroll', this.selectionchangeHandler);
      window.removeEventListener('resize', this.selectionchangeHandler);
    }
    element.contentEditable = 'false';
    element.style.outline = '';
    element.style.outlineOffset = '';
    element.style.cursor = '';

    // Tear down toolbar
    if (this.toolbar) {
      this.toolbar.remove();
      this.toolbar = null;
    }
    this.toolbarButtons.clear();

    // Clear selection
    window.getSelection()?.removeAllRanges();
  }

  // -----------------------------------------------------------------------
  // Mini-toolbar
  // -----------------------------------------------------------------------

  private buildToolbar(element: HTMLElement): HTMLElement {
    const toolbar = document.createElement('div');
    toolbar.setAttribute('role', 'toolbar');
    toolbar.setAttribute('aria-label', 'Text formatting');

    Object.assign(toolbar.style, {
      position: 'fixed',
      display: 'none',
      alignItems: 'center',
      gap: '2px',
      padding: '4px',
      background: OVERLAY.bg,
      border: `1px solid ${OVERLAY.border}`,
      borderRadius: OVERLAY.radiusSm,
      boxShadow: '0 4px 12px rgba(0,0,0,0.3)',
      zIndex: '102',
      pointerEvents: 'auto',
    });

    // Add entry animation style (inject once per shadow root via querySelector)
    const styleId = 'fe-toolbar-animation';
    if (this.shadow && !this.shadow.querySelector(`#${styleId}`)) {
      const style = document.createElement('style');
      style.id = styleId;
      style.textContent = `
        @keyframes fe-toolbar-rise {
          from { opacity: 0; transform: translateY(4px); }
          to   { opacity: 1; transform: translateY(0); }
        }
        @media (prefers-reduced-motion: reduce) {
          .fe-format-toolbar { animation: none !important; }
        }
      `;
      this.shadow.appendChild(style);
    }
    toolbar.classList.add('fe-format-toolbar');
    toolbar.style.animation = 'fe-toolbar-rise 150ms ease-out';

    // Format buttons
    const marks: Array<FormatMark | 'clear'> = ['bold', 'italic', 'underline', 'strike', 'clear'];
    for (const mark of marks) {
      if (mark === 'clear' && marks.indexOf(mark) > 0) {
        // Divider before Clear
        const divider = document.createElement('div');
        Object.assign(divider.style, {
          width: '1px',
          height: '20px',
          background: OVERLAY.border,
          margin: '0 2px',
        });
        toolbar.appendChild(divider);
      }

      const btn = document.createElement('button');
      btn.setAttribute('type', 'button');
      btn.setAttribute('title', BUTTON_LABELS[mark]);
      btn.setAttribute('aria-pressed', 'false');
      btn.innerHTML = ICONS[mark];

      Object.assign(btn.style, {
        width: '32px',
        height: '32px',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        background: 'none',
        border: 'none',
        borderRadius: OVERLAY.radiusSm,
        color: OVERLAY.text,
        cursor: 'pointer',
        padding: '0',
        flexShrink: '0',
      });

      btn.addEventListener('mouseenter', () => {
        btn.style.background = 'rgba(255,255,255,0.1)';
      });
      btn.addEventListener('mouseleave', () => {
        this.refreshButtonBackground(btn);
      });

      // mousedown + preventDefault: never blur the contenteditable
      btn.addEventListener('mousedown', (e) => {
        e.preventDefault();
        this.handleToolbarClick(mark, element, btn);
      });

      if (mark !== 'clear') {
        this.toolbarButtons.set(mark, btn);
      }
      toolbar.appendChild(btn);
    }

    return toolbar;
  }

  private handleToolbarClick(
    mark: FormatMark | 'clear',
    element: HTMLElement,
    _btn: HTMLButtonElement,
  ): void {
    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0) return;
    const raw = sel.getRangeAt(0);
    const range = clampRangeToRoot(raw, element);
    if (!range) return;

    if (mark === 'clear') {
      clearFormatting(range, element);
    } else {
      toggleMark(range, mark, element);
    }

    // Re-assert selection after DOM mutation
    sel.removeAllRanges();
    sel.addRange(range);
    this.refreshToolbarState(element);
  }

  private refreshToolbarState(element: HTMLElement): void {
    if (!this.toolbar) return;

    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0) return;
    const range = sel.getRangeAt(0);

    if (range.collapsed || !element.contains(range.commonAncestorContainer)) {
      return;
    }

    const clamped = clampRangeToRoot(range, element);
    if (!clamped) return;

    const state = getFormatState(clamped, element);

    for (const [mark, btn] of this.toolbarButtons) {
      const s = state.get(mark) ?? 'none';
      if (s === 'full') {
        btn.setAttribute('aria-pressed', 'true');
        btn.style.background = 'rgba(6, 182, 212, 0.12)';
      } else if (s === 'partial') {
        btn.setAttribute('aria-pressed', 'mixed');
        btn.style.background = 'rgba(6, 182, 212, 0.08)';
      } else {
        btn.setAttribute('aria-pressed', 'false');
        btn.style.background = 'none';
      }
    }
  }

  private refreshButtonBackground(btn: HTMLButtonElement): void {
    const pressed = btn.getAttribute('aria-pressed');
    if (pressed === 'true') {
      btn.style.background = 'rgba(6, 182, 212, 0.12)';
    } else if (pressed === 'mixed') {
      btn.style.background = 'rgba(6, 182, 212, 0.08)';
    } else {
      btn.style.background = 'none';
    }
  }

  private repositionToolbar(element: HTMLElement): void {
    if (!this.toolbar) return;

    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0) {
      this.toolbar.style.display = 'none';
      return;
    }

    const range = sel.getRangeAt(0);

    // Hide when collapsed or outside the active element
    if (range.collapsed || !element.contains(range.commonAncestorContainer)) {
      this.toolbar.style.display = 'none';
      return;
    }

    const rect = range.getBoundingClientRect();
    if (!rect || rect.width === 0) {
      this.toolbar.style.display = 'none';
      return;
    }

    // Show toolbar
    this.toolbar.style.display = 'flex';

    // Measure toolbar dimensions (or use estimates before first paint)
    const toolbarW = this.toolbar.offsetWidth || 200;
    const toolbarH = this.toolbar.offsetHeight || TOOLBAR_HEIGHT_PX;

    // Position: 8px above selection, flip below when too close to viewport top
    let top: number;
    if (rect.top - toolbarH - TOOLBAR_ABOVE_OFFSET_PX < TOOLBAR_VIEWPORT_MARGIN_PX) {
      // Flip below
      top = rect.bottom + TOOLBAR_ABOVE_OFFSET_PX;
    } else {
      top = rect.top - toolbarH - TOOLBAR_ABOVE_OFFSET_PX;
    }

    // Horizontal: center over selection, clamp to viewport
    let left = rect.left + rect.width / 2 - toolbarW / 2;
    const vw = window.innerWidth;
    left = Math.max(TOOLBAR_VIEWPORT_MARGIN_PX, Math.min(left, vw - toolbarW - TOOLBAR_VIEWPORT_MARGIN_PX));

    this.toolbar.style.top = `${top}px`;
    this.toolbar.style.left = `${left}px`;

    this.refreshToolbarState(element);
  }
}

// ---------------------------------------------------------------------------
// Utility
// ---------------------------------------------------------------------------

function escapeTextForHtml(text: string): string {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}
