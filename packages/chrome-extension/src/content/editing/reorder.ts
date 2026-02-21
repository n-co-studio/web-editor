/**
 * Reorder editing — drag-to-reorder children within a flex/grid container.
 *
 * Phase 1: block-reason guard only. Phase 2: drag interaction. Phase 3: undo/redo.
 */

/**
 * Returns a human-readable reason why reorder is blocked for this element,
 * or null if reorder is allowed.
 */
export function getReorderBlockReason(element: Element): string | null {
  const parent = element.parentElement;
  if (!parent) {
    return 'Element has no parent';
  }

  const parentStyle = getComputedStyle(parent);
  const parentDisplay = parentStyle.display;

  const isFlex = parentDisplay.includes('flex');
  const isGrid = parentDisplay.includes('grid');

  if (!isFlex && !isGrid) {
    return 'Parent is not a flex or grid container';
  }

  if (isFlex && parentStyle.flexWrap !== 'nowrap') {
    return 'Wrapped flex containers are not supported for reorder';
  }

  if (parent.children.length <= 1) {
    return 'Element is the only child — nothing to reorder';
  }

  return null;
}
