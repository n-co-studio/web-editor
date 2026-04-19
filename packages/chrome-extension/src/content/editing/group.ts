/**
 * Group editing — wraps 1+ sibling elements in a flex container.
 *
 * Provides the block-reason guard and pure DOM mutation function.
 * Phase 2 wires these into the UI (toolbar button, keyboard shortcut).
 */

import { detectContainerLayout } from './gap-math';

// ---------------------------------------------------------------------------
// Block-reason guard
// ---------------------------------------------------------------------------

/**
 * Returns a human-readable reason why grouping is blocked for these elements,
 * or null if grouping is allowed.
 */
export function getGroupBlockReason(elements: Element[]): string | null {
  if (elements.length < 1) {
    return 'Select at least 1 element to group';
  }

  const parent = elements[0].parentElement;
  if (!parent) {
    return 'First element has no parent';
  }

  for (const el of elements) {
    if (el.parentElement !== parent) {
      return 'All elements must share the same parent';
    }
  }

  const tag = parent.tagName.toLowerCase();
  if (tag === 'html' || tag === 'body') {
    return 'Cannot group children of <html> or <body>';
  }

  return null;
}

// ---------------------------------------------------------------------------
// DOM mutation
// ---------------------------------------------------------------------------

/** Recorded original position of an element before grouping. */
export interface OriginalPosition {
  readonly element: HTMLElement;
  readonly nextSibling: Node | null;
}

/** Result of a groupElements() call — used to build history and diff. */
export interface GroupResult {
  readonly wrapper: HTMLElement;
  readonly originalPositions: OriginalPosition[];
}

/**
 * Wrap the given sibling elements in a new flex container div.
 *
 * 1. Sort elements by DOM order within their shared parent.
 * 2. Record each element's nextSibling before mutation.
 * 3. Detect parent's flex-direction (or default to row).
 * 4. Create wrapper div with display:flex, inherited flex-direction, gap:0.
 * 5. Insert wrapper before the first selected element.
 * 6. Move each element into wrapper (moveBefore if available, appendChild fallback).
 *
 * @param elements - 1+ sibling HTMLElements to wrap. Must share the same parent.
 * @param _shadow  - ShadowRoot for overlay rendering (reserved for Phase 2).
 * @returns The wrapper element and original positions for history.
 */
export function groupElements(elements: HTMLElement[], _shadow: ShadowRoot): GroupResult {
  const parent = elements[0].parentElement!;

  // Sort by DOM order within parent
  const childList = Array.from(parent.children);
  const sorted = [...elements].sort(
    (a, b) => childList.indexOf(a) - childList.indexOf(b),
  );

  // Record original positions before any DOM mutation
  const originalPositions: OriginalPosition[] = sorted.map((el) => ({
    element: el,
    nextSibling: el.nextSibling,
  }));

  // Detect parent's flex-direction (default to row for non-flex parents)
  const layout = detectContainerLayout(parent as HTMLElement);
  const flexDirection = layout.direction === 'column' ? 'column' : 'row';

  // Create wrapper
  const wrapper = document.createElement('div');
  wrapper.style.display = 'flex';
  wrapper.style.flexDirection = flexDirection;
  wrapper.style.gap = '0px';

  // Insert wrapper before the first selected element
  parent.insertBefore(wrapper, sorted[0]);

  // Move each element into wrapper
  for (const el of sorted) {
    if ('moveBefore' in wrapper && typeof (wrapper as any).moveBefore === 'function') {
      (wrapper as any).moveBefore(el, null);
    } else {
      wrapper.appendChild(el);
    }
  }

  return { wrapper, originalPositions };
}
