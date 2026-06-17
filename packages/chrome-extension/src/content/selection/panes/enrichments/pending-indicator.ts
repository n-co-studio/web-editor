import type { VisualDiff } from '@nco-studio/shared';
import { createElement } from '../../../../shared/ui-utils';
import { OVERLAY } from '../../../../shared/constants';

/**
 * Look up pending changes for a specific element+property combination.
 * Returns the fromValue if a pending change exists, null otherwise.
 */
export function findPendingChange(
  activeDiffs: VisualDiff[],
  elementSelector: string,
  property: string,
): string | null {
  for (const diff of activeDiffs) {
    if (diff.element.selector !== elementSelector) continue;
    for (const change of diff.changes) {
      if (change.property === property) {
        return change.fromValue;
      }
    }
  }
  return null;
}

/**
 * Create and append a 4px cyan dot to the indicator-slot.
 * Adds a tooltip showing the previous value on hover.
 */
export function applyPendingDot(
  indicatorSlot: HTMLSpanElement,
  fromValue: string,
): void {
  const dot = createElement('span', { title: `Was: ${fromValue}` }, {
    display: 'inline-block',
    width: '4px',
    height: '4px',
    borderRadius: '50%',
    background: OVERLAY.primary,
    flexShrink: '0',
  });
  indicatorSlot.appendChild(dot);
}
