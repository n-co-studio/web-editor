import type { ComputedStyleSnapshot } from '../../../../shared/dom-utils';
import { createElement } from '../../../../shared/ui-utils';

const FLEX_GRID_DISPLAYS = new Set([
  'flex', 'inline-flex', 'grid', 'inline-grid',
]);
const GRID_DISPLAYS = new Set(['grid', 'inline-grid']);

/**
 * Heuristic rules: property -> check function.
 * Returns a reason string if the property is conclusively inactive, null otherwise.
 * Errs on the side of NOT dimming (returns null when uncertain).
 */
const INACTIVE_RULES: Record<string, (s: ComputedStyleSnapshot) => string | null> = {
  'top':    (s) => s.position === 'static' ? 'position is static' : null,
  'right':  (s) => s.position === 'static' ? 'position is static' : null,
  'bottom': (s) => s.position === 'static' ? 'position is static' : null,
  'left':   (s) => s.position === 'static' ? 'position is static' : null,
  'z-index': (s) => s.position === 'static' ? 'position is static' : null,
  'width':  (s) => s.display === 'inline' ? 'display is inline' : null,
  'height': (s) => s.display === 'inline' ? 'display is inline' : null,
  'flex-direction':   (s) => !FLEX_GRID_DISPLAYS.has(s.display) ? `display is ${s.display}` : null,
  'justify-content':  (s) => !FLEX_GRID_DISPLAYS.has(s.display) ? `display is ${s.display}` : null,
  'align-items':      (s) => !FLEX_GRID_DISPLAYS.has(s.display) ? `display is ${s.display}` : null,
  'flex-wrap':        (s) => !FLEX_GRID_DISPLAYS.has(s.display) ? `display is ${s.display}` : null,
  'gap':              (s) => !FLEX_GRID_DISPLAYS.has(s.display) ? `display is ${s.display}` : null,
  'grid-template-columns': (s) => !GRID_DISPLAYS.has(s.display) ? `display is ${s.display}` : null,
  'grid-template-rows':    (s) => !GRID_DISPLAYS.has(s.display) ? `display is ${s.display}` : null,
};

/**
 * Check if a CSS property is inactive given the element's computed style.
 * Returns a reason string if inactive, null if active.
 */
export function checkInactive(
  property: string,
  snapshot: ComputedStyleSnapshot,
): string | null {
  const rule = INACTIVE_RULES[property];
  if (!rule) return null;
  return rule(snapshot);
}

/**
 * Apply inactive styling to a property row.
 * Sets opacity to 0.4, italicizes the property name,
 * and places an info icon in the indicator-slot with a tooltip.
 */
export function applyInactiveStyles(
  row: HTMLDivElement,
  nameEl: HTMLElement,
  indicatorSlot: HTMLSpanElement,
  reason: string,
): void {
  row.style.opacity = '0.4';
  nameEl.style.fontStyle = 'italic';

  const icon = createElement('span', { title: `Inactive: ${reason}` }, {
    fontSize: '10px',
    lineHeight: '1',
    cursor: 'help',
    userSelect: 'none',
  });
  icon.textContent = '\u24D8'; // ⓘ circled i
  indicatorSlot.appendChild(icon);
}
