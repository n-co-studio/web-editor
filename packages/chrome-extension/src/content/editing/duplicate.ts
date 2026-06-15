/**
 * Duplicate editing — clones an element (with its full subtree) in place,
 * inserting the copy immediately after the original.
 *
 * Provides the block-reason guard and pure DOM mutation function, mirroring
 * the shape of group.ts. The UI wiring (toolbar button, multi-select button,
 * keyboard shortcut) lives in index.ts.
 */

// ---------------------------------------------------------------------------
// Block-reason guard
// ---------------------------------------------------------------------------

/**
 * Returns a human-readable reason why duplication is blocked for this element,
 * or null if duplication is allowed.
 */
export function getDuplicateBlockReason(element: Element): string | null {
  const parent = element.parentElement;
  if (!parent) {
    return 'Element has no parent';
  }

  const tag = parent.tagName.toLowerCase();
  if (tag === 'html' || tag === 'body') {
    return 'Cannot duplicate children of <html> or <body>';
  }

  return null;
}

// ---------------------------------------------------------------------------
// DOM mutation
// ---------------------------------------------------------------------------

/** Result of a duplicateElement() call. */
export interface DuplicateResult {
  /** The newly inserted clone. */
  readonly clone: HTMLElement;
  /** The element's parent (the container the clone was inserted into). */
  readonly container: HTMLElement;
  /** The clone's index among its parent's children after insertion. */
  readonly insertIndex: number;
}

/**
 * Deep-clone `element` and insert the copy immediately after it.
 *
 * Uses `cloneNode(true)` so the entire subtree (children, inline styles,
 * attributes, text) is reproduced verbatim. The caller is responsible for
 * recording history / building the diff (the clone's `outerHTML` carries the
 * full markup for source reproduction).
 *
 * @returns The clone plus its post-insertion container and index.
 */
export function duplicateElement(element: HTMLElement): DuplicateResult {
  const parent = element.parentElement!;
  const clone = element.cloneNode(true) as HTMLElement;
  const insertIndex = Array.from(parent.children).indexOf(element) + 1;

  parent.insertBefore(clone, element.nextSibling);

  return { clone, container: parent, insertIndex };
}
