/**
 * inline-format.ts — pure Range/DOM inline text styling functions.
 *
 * Implements sub-range toggle commands for bold/italic/underline/strikethrough,
 * normalization, allowlist serialization, and format-state detection for
 * feature-012 (Inline Text Styling).
 *
 * Constraints (from spec + Pragmatist review):
 *  - Semantic tags only: strong/em/u/s — NEVER b/i (WCAG H49)
 *  - NEVER use Range.surroundContents() — throws on partial node containment
 *  - NEVER use document.execCommand for styling — deprecated, emits b/i
 *  - Mechanism: extractContents() → wrap fragment → insertNode()
 *  - No DOMPurify — input is operator-driven, paste forced to plain text
 */

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type FormatMark = 'bold' | 'italic' | 'underline' | 'strike';

/** Tag map: FormatMark → uppercase element tagName */
const TAG_UPPER: Record<FormatMark, string> = {
  bold: 'STRONG',
  italic: 'EM',
  underline: 'U',
  strike: 'S',
};

/** Tag map: FormatMark → lowercase element tagName (for createElement) */
const TAG_LOWER: Record<FormatMark, string> = {
  bold: 'strong',
  italic: 'em',
  underline: 'u',
  strike: 's',
};

/** Allowed tags for the allowlist serializer */
const ALLOWED_TAGS = new Set(['strong', 'em', 'u', 's', 'br']);

// ---------------------------------------------------------------------------
// Format-state detection
// ---------------------------------------------------------------------------

/**
 * Check whether a text node has an ancestor with the given tagName,
 * stopping at (but not including) `root`.
 */
function hasAncestorTag(node: Node, tagName: string, root: HTMLElement): boolean {
  let n: Node | null = node.parentNode;
  while (n && n !== root) {
    if (n.nodeType === Node.ELEMENT_NODE && (n as Element).tagName === tagName) return true;
    n = n.parentNode;
  }
  return false;
}

/**
 * Collect all text nodes inside `root` that intersect the given range.
 */
function getTextNodesInRange(range: Range, root: HTMLElement): Text[] {
  const nodes: Text[] = [];
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  let node: Node | null;
  while ((node = walker.nextNode())) {
    if (range.intersectsNode(node)) {
      nodes.push(node as Text);
    }
  }
  return nodes;
}

/**
 * Detect the format state for each mark across the current selection range.
 *
 * Returns a Map from FormatMark to:
 *  - 'none'    — no text in the range has this mark
 *  - 'partial' — some but not all text has this mark
 *  - 'full'    — all text in the range has this mark
 *
 * Collapsed ranges always return 'none' for all marks.
 */
export function getFormatState(
  range: Range,
  root: HTMLElement,
): Map<FormatMark, 'none' | 'partial' | 'full'> {
  const result = new Map<FormatMark, 'none' | 'partial' | 'full'>();

  if (range.collapsed) {
    for (const mark of Object.keys(TAG_UPPER) as FormatMark[]) {
      result.set(mark, 'none');
    }
    return result;
  }

  const textNodes = getTextNodesInRange(range, root);

  for (const mark of Object.keys(TAG_UPPER) as FormatMark[]) {
    const tag = TAG_UPPER[mark];
    if (textNodes.length === 0) {
      result.set(mark, 'none');
      continue;
    }
    let styledCount = 0;
    for (const tn of textNodes) {
      if (hasAncestorTag(tn, tag, root)) styledCount++;
    }
    if (styledCount === 0) result.set(mark, 'none');
    else if (styledCount === textNodes.length) result.set(mark, 'full');
    else result.set(mark, 'partial');
  }

  return result;
}

// ---------------------------------------------------------------------------
// Apply / remove helpers
// ---------------------------------------------------------------------------

/**
 * Remove all elements matching `tagName` from a fragment/element, unwrapping
 * their children in place. Returns the modified fragment/element.
 */
function unwrapTagInFragment(frag: DocumentFragment | Element, tagName: string): void {
  // querySelectorAll on DocumentFragment is valid
  const els = Array.from((frag as Element).querySelectorAll(tagName));
  for (const el of els) {
    const parent = el.parentNode;
    if (!parent) continue;
    while (el.firstChild) {
      parent.insertBefore(el.firstChild, el);
    }
    parent.removeChild(el);
  }
}

/**
 * Apply a format mark to the given range.
 * Uses extractContents() + wrap + insertNode() — safe for partial containment.
 * Runs normalizeInlineMarkup() after to merge adjacent identical wrappers.
 */
export function applyMark(range: Range, mark: FormatMark, root: HTMLElement): void {
  if (range.collapsed) return;

  const tag = TAG_LOWER[mark];
  const fragment = range.extractContents();
  const wrapper = document.createElement(tag);
  wrapper.appendChild(fragment);
  range.insertNode(wrapper);

  normalizeInlineMarkup(root);
}

/**
 * Remove a format mark from the given range.
 * Extracts the range, strips all instances of the mark's tag, and reinserts.
 * Handles the case where the selection is a sub-range of a larger wrapper
 * (extractContents() natively splits boundary nodes).
 */
export function removeMark(range: Range, mark: FormatMark, root: HTMLElement): void {
  if (range.collapsed) return;

  const tag = TAG_UPPER[mark];
  const tagLower = TAG_LOWER[mark];
  const fragment = range.extractContents();
  unwrapTagInFragment(fragment as unknown as Element, tagLower);
  // Also remove any uppercase matches (defensive)
  unwrapTagInFragment(fragment as unknown as Element, tag);
  range.insertNode(fragment);

  normalizeInlineMarkup(root);
}

/**
 * Toggle a format mark on the range:
 *  - 'full'  → remove (all selected text already has the mark)
 *  - 'partial' or 'none' → apply
 *
 * No-op on collapsed ranges.
 */
export function toggleMark(range: Range, mark: FormatMark, root: HTMLElement): void {
  if (range.collapsed) return;

  const state = getFormatState(range, root);
  if (state.get(mark) === 'full') {
    removeMark(range, mark, root);
  } else {
    applyMark(range, mark, root);
  }
}

/**
 * Remove all four format marks from the range.
 */
export function clearFormatting(range: Range, root: HTMLElement): void {
  if (range.collapsed) return;

  const fragment = range.extractContents();
  for (const tagLower of Object.values(TAG_LOWER)) {
    unwrapTagInFragment(fragment as unknown as Element, tagLower);
  }
  range.insertNode(fragment);

  normalizeInlineMarkup(root);
}

// ---------------------------------------------------------------------------
// Normalization
// ---------------------------------------------------------------------------

/**
 * Normalize inline markup on `root`:
 * 1. Remove empty wrappers (elements with no text content).
 * 2. Merge adjacent identical inline wrappers (repeated until stable).
 * 3. Call Node.normalize() to merge adjacent text nodes.
 *
 * This is idempotent — toggle-storms converge to clean, minimal markup.
 */
export function normalizeInlineMarkup(root: HTMLElement): void {
  const inlineTags = ['STRONG', 'EM', 'U', 'S'];
  const inlineTagsLower = ['strong', 'em', 'u', 's'];

  // 1. Remove empty wrappers (no text content at all)
  for (const tag of inlineTagsLower) {
    const els = Array.from(root.querySelectorAll(tag));
    for (const el of els) {
      if (!el.textContent) {
        el.parentNode?.removeChild(el);
      }
    }
  }

  // 2. Merge adjacent identical wrappers (repeat until stable)
  let changed = true;
  while (changed) {
    changed = false;
    for (const tagName of inlineTags) {
      const els = Array.from(root.querySelectorAll(tagName));
      for (const el of els) {
        // Skip whitespace-only text nodes between siblings
        let next: Node | null = el.nextSibling;
        while (next && next.nodeType === Node.TEXT_NODE && !next.textContent?.trim()) {
          next = next.nextSibling;
        }
        if (next instanceof Element && next.tagName === tagName) {
          while (next.firstChild) {
            el.appendChild(next.firstChild);
          }
          next.parentNode?.removeChild(next);
          changed = true;
        }
      }
    }
  }

  // 3. Merge adjacent text nodes
  root.normalize();
}

// ---------------------------------------------------------------------------
// Range clamping
// ---------------------------------------------------------------------------

/**
 * Return the intersection of `range` with the content of `root`, or null
 * if the intersection is empty/collapsed. Used to guard against selections
 * that extend beyond the contenteditable element boundary.
 */
export function clampRangeToRoot(range: Range, root: HTMLElement): Range | null {
  const rootRange = document.createRange();
  rootRange.selectNodeContents(root);

  // Clamp start: take whichever boundary is further into the content
  const clampedStart = range.compareBoundaryPoints(Range.START_TO_START, rootRange) < 0
    ? rootRange
    : range;
  // Clamp end: take whichever boundary is earlier in the content
  const clampedEnd = range.compareBoundaryPoints(Range.END_TO_END, rootRange) > 0
    ? rootRange
    : range;

  const clamped = document.createRange();
  clamped.setStart(clampedStart.startContainer, clampedStart.startOffset);
  clamped.setEnd(clampedEnd.endContainer, clampedEnd.endOffset);

  if (clamped.collapsed) return null;
  return clamped;
}

// ---------------------------------------------------------------------------
// Allowlist serializer
// ---------------------------------------------------------------------------

/** HTML-escape text content */
function escapeHtml(text: string): string {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

/**
 * Serialize a single DOM node (recursively) to an allowlist-filtered HTML string.
 * Only strong/em/u/s/br tags survive — all others are unwrapped to their text.
 * Zero attributes are emitted on any tag.
 */
function serializeNode(node: Node): string {
  if (node.nodeType === Node.TEXT_NODE) {
    return escapeHtml(node.textContent ?? '');
  }
  if (node.nodeType === Node.ELEMENT_NODE) {
    const el = node as Element;
    const tag = el.tagName.toLowerCase();

    // Self-closing allowed tag
    if (tag === 'br') return '<br>';

    const children = Array.from(el.childNodes).map(serializeNode).join('');

    if (ALLOWED_TAGS.has(tag)) {
      return `<${tag}>${children}</${tag}>`;
    }

    // Non-allowed element — unwrap to children (text preserved)
    return children;
  }
  return '';
}

/**
 * Serialize the innerHTML of `root` to an allowlist-only HTML string.
 * Allowed tags: strong, em, u, s, br — with ZERO attributes.
 * All other elements are stripped (text content preserved).
 * Text is HTML-escaped.
 *
 * This is the ONLY path that produces fromHtml/toHtml values in TextChange.
 */
export function serializeAllowedHtml(root: HTMLElement): string {
  return Array.from(root.childNodes).map(serializeNode).join('');
}
