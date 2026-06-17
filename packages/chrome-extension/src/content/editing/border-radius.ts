import type { PropertyChange } from '@nco-studio/shared';
import { getComputedProperty } from '../../shared/dom-utils';

/** Border radius corner properties. */
export const BORDER_RADIUS_PROPERTIES = [
  'border-top-left-radius',
  'border-top-right-radius',
  'border-bottom-right-radius',
  'border-bottom-left-radius',
] as const;

/** Read current border radius values for an element. */
export function readBorderRadiusValues(
  element: Element,
): Record<string, string> {
  const values: Record<string, string> = {};
  for (const prop of BORDER_RADIUS_PROPERTIES) {
    values[prop] = getComputedProperty(element, prop);
  }
  return values;
}

/**
 * Build PropertyChange objects from before/after border radius values.
 * Only includes properties that actually changed.
 */
export function buildBorderRadiusChanges(
  before: Record<string, string>,
  after: Record<string, string>,
): PropertyChange[] {
  const changes: PropertyChange[] = [];

  for (const prop of BORDER_RADIUS_PROPERTIES) {
    const fromValue = before[prop] ?? '0px';
    const toValue = after[prop] ?? '0px';
    if (fromValue !== toValue) {
      changes.push({
        property: prop,
        fromValue,
        toValue,
        unit: extractUnit(toValue),
      });
    }
  }

  return changes;
}

function extractUnit(value: string): string | undefined {
  const match = value.match(/[\d.]+(.+)$/);
  return match?.[1] || undefined;
}
