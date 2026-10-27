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

/**
 * A value assigned to the element by a matched CSS rule (including rules
 * matched via pseudo-classes like `:first-child` / `:nth-child(n)`), surfaced
 * as a selectable option labeled with its selector.
 */
export interface RuleValueOption {
  readonly value: string;
  readonly selector: string;
  /** True when this rule is the cascade winner for the property. */
  readonly isOwning: boolean;
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
 * Offers `auto`, the current value (when it matches no token), every token
 * value, and any rule-assigned values (`ruleOptions`) labeled with their
 * selector — same `value (label)` convention as tokens. On change it previews
 * the value, then commits a PropertyChange carrying the resolved `toToken`
 * when the chosen value maps to a token.
 */
export function buildTokenSelect(
  property: string,
  tokens: readonly TokenOption[],
  currentValue: string,
  element: Element,
  preview: PreviewManager,
  onCommit: ChangeCallback,
  ruleOptions: readonly RuleValueOption[] = [],
): HTMLSelectElement {
  const select = createElement('select', {}, {
    background: OVERLAY.inputBg,
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

  // Surface the current value when it matches neither a token nor auto,
  // labeled with the assigning rule's selector when one is known.
  const hasMatch =
    currentValue === 'auto' || tokens.some((t) => t.value === currentValue);
  if (!hasMatch) {
    const assigning =
      ruleOptions.find((r) => r.isOwning && r.value === currentValue) ??
      ruleOptions.find((r) => r.value === currentValue);
    const opt = document.createElement('option');
    opt.value = currentValue;
    opt.textContent = assigning
      ? `${currentValue} (${assigning.selector})`
      : currentValue;
    opt.selected = true;
    select.appendChild(opt);
  }

  for (const token of tokens) {
    const opt = document.createElement('option');
    opt.value = token.value;
    opt.textContent = `${token.value} (${token.name})`;
    if (token.value === currentValue) opt.selected = true;
    select.appendChild(opt);
  }

  // Rule-assigned values not already present as auto/current/token options.
  const present = new Set<string>(['auto', ...tokens.map((t) => t.value)]);
  if (!hasMatch) present.add(currentValue);
  for (const ruleOpt of ruleOptions) {
    if (present.has(ruleOpt.value)) continue;
    present.add(ruleOpt.value);
    const opt = document.createElement('option');
    opt.value = ruleOpt.value;
    opt.textContent = `${ruleOpt.value} (${ruleOpt.selector})`;
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
