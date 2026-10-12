import { createElement } from '../../../../shared/ui-utils';
import { OVERLAY } from '../../../../shared/constants';

/** CSS property names that should show a color swatch. */
function isColorProperty(property: string): boolean {
  return property.includes('color') || property === 'background';
}

/** Check if a computed CSS color value is renderable. */
function isValidColorValue(value: string): boolean {
  if (!value || value === 'inherit' || value === 'initial' || value === 'unset' || value === 'none') {
    return false;
  }
  return value.startsWith('rgb') || value.startsWith('#') || value.startsWith('hsl');
}

/**
 * Create a 12x12 color swatch element for insertion into the badge-slot.
 * Returns null if the property is not color-related or value is not a color.
 * Hit area expanded to ~24px via padding (consistent with HANDLE_HIT_AREA pattern).
 */
export function createColorSwatch(
  property: string,
  value: string,
  onClick: () => void,
): HTMLSpanElement | null {
  if (!isColorProperty(property) || !isValidColorValue(value)) return null;

  const swatch = createElement('span', {}, {
    display: 'inline-block',
    width: '12px',
    height: '12px',
    borderRadius: '2px',
    border: `1px solid ${OVERLAY.swatchBorder}`,
    background: value,
    flexShrink: '0',
    cursor: 'pointer',
    padding: '6px',
    margin: '-6px',
    backgroundClip: 'content-box',
  }) as HTMLSpanElement;

  swatch.addEventListener('click', (e) => {
    e.stopPropagation();
    onClick();
  });

  return swatch;
}
