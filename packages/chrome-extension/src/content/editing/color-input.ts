import type { PropertyChange } from '@nco-studio/shared';
import { createElement } from '../../shared/ui-utils';
import { getComputedProperty } from '../../shared/dom-utils';
import { OVERLAY } from '../../shared/constants';
import type { PreviewManager } from './preview';

type ChangeCallback = (changes: PropertyChange[]) => void;

/**
 * Convert a CSS color string to a `#rrggbb` hex value for a native
 * `<input type="color">`, which only accepts 6-digit hex. Falls back to
 * black when the input cannot be parsed (named colors, gradients, etc.).
 */
export function toHex(color: string): string {
  if (color.startsWith('#')) return color.length <= 7 ? color : color.slice(0, 7);

  const match = color.match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/);
  if (match) {
    const r = parseInt(match[1], 10);
    const g = parseInt(match[2], 10);
    const b = parseInt(match[3], 10);
    return `#${((1 << 24) + (r << 16) + (g << 8) + b).toString(16).slice(1)}`;
  }

  return '#000000';
}

/**
 * Build a freeform color control: a clickable swatch backed by a hidden native
 * color picker, plus a text input for manual entry (hex, rgb(), named colors).
 *
 * This is the "No Tokens → freeform editing" affordance (feature-003): edits
 * are emitted as raw CSS via `PropertyChange` with no `toToken`. The swatch
 * previews live via `PreviewManager.begin/apply` and commits on picker
 * `change`; the text input commits on Enter.
 *
 * Returns a flex row element for the caller to append into its panel body.
 */
export function buildColorInput(
  property: string,
  currentValue: string,
  element: Element,
  preview: PreviewManager,
  onCommit: ChangeCallback,
): HTMLElement {
  const row = createElement('div', {}, {
    display: 'flex',
    gap: '6px',
    alignItems: 'center',
    flex: '1',
    minWidth: '0',
  });

  // Color swatch preview — activating it (click, Enter, or Space) opens the
  // native picker. Exposed as a button with a tooltip so the picker affordance
  // is discoverable and keyboard-reachable.
  const swatch = createElement('div', {
    role: 'button',
    tabindex: '0',
    title: 'Open color picker',
    'aria-label': `Open color picker for ${property}`,
  }, {
    width: '24px',
    height: '24px',
    borderRadius: OVERLAY.radiusSm,
    border: `1px solid ${OVERLAY.border}`,
    background: currentValue,
    flexShrink: '0',
    cursor: 'pointer',
  });
  swatch.addEventListener('mouseenter', () => { swatch.style.borderColor = OVERLAY.primary; });
  swatch.addEventListener('mouseleave', () => { swatch.style.borderColor = OVERLAY.border; });
  swatch.addEventListener('focus', () => { swatch.style.outline = `2px solid ${OVERLAY.primary}`; });
  swatch.addEventListener('blur', () => { swatch.style.outline = 'none'; });

  // Native color picker, hidden but triggered by the swatch.
  const colorInput = createElement('input', { type: 'color' }, {
    position: 'absolute',
    opacity: '0',
    width: '0',
    height: '0',
    pointerEvents: 'none',
  }) as HTMLInputElement;
  colorInput.value = toHex(currentValue);

  // Text input for manual entry (hex, rgb(), named colors).
  const textInput = createElement('input', { type: 'text', value: currentValue }, {
    padding: '4px 6px',
    background: OVERLAY.hover,
    border: `1px solid ${OVERLAY.border}`,
    borderRadius: OVERLAY.radiusSm,
    color: OVERLAY.text,
    fontSize: OVERLAY.monoSize,
    fontFamily: OVERLAY.monoFamily,
    outline: 'none',
    boxSizing: 'border-box',
    minWidth: '0',
    flex: '1',
  }) as HTMLInputElement;

  swatch.addEventListener('click', () => colorInput.click());
  swatch.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      colorInput.click();
    }
  });

  colorInput.addEventListener('input', () => {
    swatch.style.background = colorInput.value;
    preview.begin(element as HTMLElement);
    preview.apply(property, colorInput.value);
  });
  colorInput.addEventListener('change', () => {
    const originals = preview.commit();
    const fromValue = originals.get(property) || currentValue;
    onCommit([{ property, fromValue, toValue: colorInput.value }]);
    textInput.value = colorInput.value;
  });

  textInput.addEventListener('keydown', (e) => {
    e.stopPropagation();
    if (e.key === 'Enter') {
      e.preventDefault();
      // Discard any live picker preview so the PreviewManager isn't left in an
      // orphaned session and fromValue reflects the true pre-edit value.
      preview.revert();
      const fromValue = getComputedProperty(element, property);
      (element as HTMLElement).style.setProperty(property, textInput.value);
      swatch.style.background = textInput.value;
      colorInput.value = toHex(textInput.value);
      onCommit([{ property, fromValue, toValue: textInput.value }]);
      textInput.blur();
    }
  });

  row.appendChild(swatch);
  row.appendChild(colorInput);
  row.appendChild(textInput);

  return row;
}
