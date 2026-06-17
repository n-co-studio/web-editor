import type { PropertyChange } from '@nco-studio/shared';
import { createElement } from '../../shared/ui-utils';
import { getComputedProperty } from '../../shared/dom-utils';
import { OVERLAY } from '../../shared/constants';
import type { PreviewManager } from './preview';

/** A token option as consumed by the select (name + CSS value). */
export interface TokenOption {
  readonly name: string;
  readonly value: string;
}

type ChangeCallback = (changes: PropertyChange[]) => void;

/** Extract the unit suffix (px, %, rem, …) from a CSS value, if any. */
export function extractUnit(value: string): string | undefined {
  const match = value.match(/[\d.]+(.+)$/);
  return match?.[1] || undefined;
}

/**
 * Build a token-aware <select> for a single CSS property. Shared by the Spacing
 * tool (padding/margin) and the Layout tool (gap/row-gap/column-gap).
 *
 * Offers `auto`, the current value (when it matches no token), and every token
 * value. On change it previews the value, then commits a PropertyChange
 * carrying the resolved `toToken` when the chosen value maps to a token.
 */
export function buildTokenSelect(
  property: string,
  tokens: readonly TokenOption[],
  currentValue: string,
  element: Element,
  preview: PreviewManager,
  onCommit: ChangeCallback,
): HTMLSelectElement {
  const select = createElement('select', {}, {
    background: 'rgba(255, 255, 255, 0.1)',
    color: OVERLAY.text,
    border: `1px solid ${OVERLAY.border}`,
    borderRadius: OVERLAY.radiusSm,
    padding: '2px 3px',
    fontSize: '10px',
    fontFamily: OVERLAY.monoFamily,
    pointerEvents: 'auto',
    cursor: 'pointer',
    flex: '1',
    minWidth: '0',
  }) as HTMLSelectElement;

  // "auto" is valid for margin and browsers accept it for padding; offer it up-front.
  const autoOpt = document.createElement('option');
  autoOpt.value = 'auto';
  autoOpt.textContent = 'auto';
  if (currentValue === 'auto') autoOpt.selected = true;
  select.appendChild(autoOpt);

  // Surface the current value when it matches neither a token nor auto.
  const hasMatch =
    currentValue === 'auto' || tokens.some((t) => t.value === currentValue);
  if (!hasMatch) {
    const opt = document.createElement('option');
    opt.value = currentValue;
    opt.textContent = currentValue;
    select.appendChild(opt);
  }

  for (const token of tokens) {
    const opt = document.createElement('option');
    opt.value = token.value;
    opt.textContent = `${token.value} (${token.name})`;
    if (token.value === currentValue) opt.selected = true;
    select.appendChild(opt);
  }

  select.addEventListener('change', () => {
    const fromValue = getComputedProperty(element, property);
    const toValue = select.value;
    const token = tokens.find((t) => t.value === toValue);
    preview.begin(element as HTMLElement);
    preview.apply(property, toValue);
    preview.commit();
    onCommit([{
      property,
      fromValue,
      toValue,
      unit: extractUnit(toValue),
      toToken: token?.name,
    }]);
  });

  return select;
}
