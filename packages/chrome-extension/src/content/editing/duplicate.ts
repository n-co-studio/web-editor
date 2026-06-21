/**
 * Duplicate editing — clones an element (with its full subtree) in place,
 * inserting the copy immediately after the original.
 *
 * Provides the block-reason guard and pure DOM mutation function, mirroring
 * the shape of group.ts. The UI wiring (toolbar button, multi-select button,
 * keyboard shortcut) lives in index.ts.
 */

import { stampFreshUid } from '../../shared/dom-utils';

// ---------------------------------------------------------------------------
// Fresh-uid regeneration for clones (issue #27)
// ---------------------------------------------------------------------------

/**
 * Strip and regenerate `data-fe-uid` on `root` **and every descendant** (deep).
 *
 * A clone is a verbatim DOM copy, so it inherits the origin's `data-fe-uid`s.
 * Reusing them would re-introduce the issue-#27 identity collision (two
 * instances sharing one uid), so the entire subtree is re-stamped with fresh
 * per-instance uids the moment the clone is created. The copied `data-source-*`
 * attributes are deliberately left intact — they remain code-map hints that
 * point the applier at the origin's source (data-contracts § uid → source
 * mapping, case b). Idempotent only in the sense that it always assigns *new*
 * uids; never call it on a node whose identity must be preserved.
 */
export function regenerateUidsDeep(root: Element): void {
  stampFreshUid(root);
  // Re-stamp every descendant — querySelectorAll('*') walks the full subtree.
  const descendants = root.querySelectorAll<Element>('*');
  for (const el of descendants) stampFreshUid(el);
}

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
  /**
   * The clone's serialized markup captured **after** uid regeneration — carries
   * the freshly minted `data-fe-uid`s (root + every descendant) so the diff's
   * `InsertChange.outerHTML` reproduces an independently-addressable instance
   * (issue #27). The caller should use this rather than re-reading the origin's
   * `outerHTML`.
   */
  readonly outerHTML: string;
}

/**
 * Deep-clone `element`, give the clone (and its whole subtree) fresh uids, then
 * insert the copy immediately after the original.
 *
 * Uses `cloneNode(true)` so the entire subtree (children, inline styles,
 * attributes, text) is reproduced verbatim, then `regenerateUidsDeep` replaces
 * the inherited `data-fe-uid`s with fresh per-instance ones — a clone must never
 * reuse the origin's uids. `outerHTML` is captured after regeneration so the
 * caller's diff carries the regenerated markup. The caller records history /
 * builds the diff.
 *
 * @returns The clone, its post-insertion container/index, and regenerated outerHTML.
 */
export function duplicateElement(element: HTMLElement): DuplicateResult {
  const parent = element.parentElement!;
  const clone = element.cloneNode(true) as HTMLElement;
  regenerateUidsDeep(clone);
  const insertIndex = Array.from(parent.children).indexOf(element) + 1;

  // Capture after regeneration, before insertion — markup is identical either
  // way, but capturing here keeps the "fresh uids in outerHTML" guarantee local.
  const outerHTML = clone.outerHTML;

  parent.insertBefore(clone, element.nextSibling);

  return { clone, container: parent, insertIndex, outerHTML };
}
