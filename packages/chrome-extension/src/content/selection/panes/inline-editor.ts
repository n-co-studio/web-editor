import type { DesignToken } from '@nco-studio/shared';
import { createElement } from '../../../shared/ui-utils';
import { OVERLAY } from '../../../shared/constants';
import { getComputedProperty } from '../../../shared/dom-utils';
import type { TokenStore } from '../../tokens/store';
import type { ToggleManager } from '../../inspection/toggle-manager';
import { stepCssValue, getStepDelta } from './css-value-stepping';

/** Properties for which 'auto' should be offered as a first-class option. */
function propertyAcceptsAuto(property: string): boolean {
  return property.startsWith('margin') || property.startsWith('padding');
}

type SingleCommitCb = (property: string, fromValue: string, toValue: string, tokenName?: string) => void;
type MultiCommitCb = (property: string, toValue: string, elements: Element[], tokenName?: string) => void;

/**
 * Inline editor — replaces a value display with a token dropdown + freeform input.
 * Used by CssGroupsSection for both single-select and multi-select property editing.
 * Supports keyboard value stepping: Arrow Up/Down ±1, Shift ±10, Alt ±0.1, Cmd/Ctrl ±100.
 * Coordinates with ToggleManager: clears toggle when editing starts on a toggled property.
 */
export class InlineEditor {
  private toggleManager: ToggleManager | null = null;

  constructor(private readonly tokenStore: TokenStore) {}

  /** Set the toggle manager for coordination (lazily provided). */
  setToggleManager(tm: ToggleManager): void {
    this.toggleManager = tm;
  }

  // ---------------------------------------------------------------------------
  // Single-select editor
  // ---------------------------------------------------------------------------

  openSingle(
    row: HTMLDivElement,
    valueContainer: HTMLDivElement,
    property: string,
    currentValue: string,
    onCommit: SingleCommitCb,
    currentElement: Element | null,
  ): void {
    // Clear toggle if property is toggled off — prevents conflict with element.style.setProperty
    if (currentElement && this.toggleManager?.isToggledOff(currentElement, property)) {
      this.toggleManager.clearPropertyToggle(currentElement, property);
    }

    const editor = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      gap: '4px',
      flex: '1',
      pointerEvents: 'auto',
    });

    const tokens = this.tokenStore.getForProperty(property);

    if (tokens.length > 0) {
      const select = createElement('select', {}, {
        background: OVERLAY.inputBg,
        color: OVERLAY.text,
        border: `1px solid ${OVERLAY.primary}`,
        borderRadius: OVERLAY.radiusSm,
        padding: '2px 4px',
        fontSize: OVERLAY.monoSize,
        fontFamily: OVERLAY.monoFamily,
        pointerEvents: 'auto',
        cursor: 'pointer',
        width: '100%',
      }) as HTMLSelectElement;

      const customOpt = document.createElement('option');
      customOpt.value = '__custom__';
      customOpt.textContent = 'Custom value...';
      select.appendChild(customOpt);

      let hasMatch = false;

      if (propertyAcceptsAuto(property)) {
        const autoOpt = document.createElement('option');
        autoOpt.value = 'auto';
        autoOpt.textContent = 'auto';
        if (currentValue === 'auto') {
          autoOpt.selected = true;
          hasMatch = true;
        }
        select.appendChild(autoOpt);
      }

      for (const t of tokens) {
        const opt = document.createElement('option');
        opt.value = t.value;
        opt.textContent = `${t.name} (${t.value})`;
        if (t.value === currentValue) {
          opt.selected = true;
          hasMatch = true;
        }
        select.appendChild(opt);
      }

      if (!hasMatch) {
        const currentOpt = document.createElement('option');
        currentOpt.value = currentValue;
        currentOpt.textContent = `${currentValue} (current)`;
        currentOpt.selected = true;
        select.insertBefore(currentOpt, customOpt.nextSibling);
      }

      select.addEventListener('change', () => {
        if (select.value === '__custom__') {
          select.style.display = 'none';
          freeform.style.display = '';
          freeform.focus();
          return;
        }
        const newValue = select.value;
        const selectedToken = tokens.find((t) => t.value === newValue);
        if (currentElement) {
          (currentElement as HTMLElement).style.setProperty(property, newValue);
        }
        onCommit(property, currentValue, newValue, selectedToken?.name);
        this.closeSingle(row, valueContainer, editor, property, currentElement);
      });

      editor.appendChild(select);
    }

    const freeform = createElement('input', {
      type: 'text',
      value: currentValue,
    }, {
      background: OVERLAY.inputBg,
      color: OVERLAY.text,
      border: `1px solid ${OVERLAY.primary}`,
      borderRadius: OVERLAY.radiusSm,
      padding: '2px 4px',
      fontSize: OVERLAY.monoSize,
      fontFamily: OVERLAY.monoFamily,
      width: '100%',
      pointerEvents: 'auto',
      display: tokens.length > 0 ? 'none' : '',
    }) as HTMLInputElement;

    freeform.addEventListener('keydown', (e) => {
      // Keyboard value stepping (Arrow Up/Down with modifiers)
      if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
        const delta = getStepDelta(e);
        if (delta !== 0) {
          const newValue = stepCssValue(freeform.value, delta);
          if (newValue !== freeform.value) {
            e.preventDefault();
            e.stopPropagation();
            freeform.value = newValue;
            if (currentElement) {
              (currentElement as HTMLElement).style.setProperty(property, newValue);
            }
          }
        }
        return;
      }

      if (e.key === 'Enter') {
        e.preventDefault();
        const newValue = freeform.value.trim();
        if (newValue && newValue !== currentValue) {
          if (currentElement) {
            (currentElement as HTMLElement).style.setProperty(property, newValue);
          }
          onCommit(property, currentValue, newValue);
        }
        this.closeSingle(row, valueContainer, editor, property, currentElement);
      }
      if (e.key === 'Escape') {
        e.preventDefault();
        // Revert any stepped (live preview) changes
        if (currentElement) {
          (currentElement as HTMLElement).style.setProperty(property, currentValue);
        }
        this.closeSingle(row, valueContainer, editor, property, currentElement);
      }
    });

    editor.appendChild(freeform);

    valueContainer.style.display = 'none';
    row.appendChild(editor);

    if (tokens.length > 0) {
      (editor.querySelector('select') as HTMLSelectElement)?.focus();
    } else {
      freeform.focus();
      freeform.select();
    }
  }

  closeSingle(
    row: HTMLDivElement,
    valueContainer: HTMLDivElement,
    editor: HTMLDivElement,
    property: string,
    currentElement: Element | null,
  ): void {
    editor.remove();
    valueContainer.style.display = '';

    if (currentElement) {
      const newValue = getComputedProperty(currentElement, property);
      const valueEl = valueContainer.querySelector('span');
      if (valueEl) valueEl.textContent = newValue;
    }
  }

  // ---------------------------------------------------------------------------
  // Multi-select editor
  // ---------------------------------------------------------------------------

  openMulti(
    row: HTMLDivElement,
    valueContainer: HTMLDivElement,
    property: string,
    currentValue: string,
    elements: Element[],
    onCommit: MultiCommitCb,
  ): void {
    const editor = createElement('div', {}, {
      display: 'flex',
      flexDirection: 'column',
      gap: '4px',
      flex: '1',
      pointerEvents: 'auto',
    });

    // Capture per-element original values for Escape revert
    const originalValues = new Map<Element, string>();
    for (const el of elements) {
      originalValues.set(el, getComputedProperty(el, property));
    }

    const tokens = this.tokenStore.getForProperty(property);

    if (tokens.length > 0) {
      const select = createElement('select', {}, {
        background: OVERLAY.inputBg,
        color: OVERLAY.text,
        border: `1px solid ${OVERLAY.primary}`,
        borderRadius: OVERLAY.radiusSm,
        padding: '2px 4px',
        fontSize: OVERLAY.monoSize,
        fontFamily: OVERLAY.monoFamily,
        pointerEvents: 'auto',
        cursor: 'pointer',
        width: '100%',
      }) as HTMLSelectElement;

      const customOpt = document.createElement('option');
      customOpt.value = '__custom__';
      customOpt.textContent = 'Custom value...';
      select.appendChild(customOpt);

      let hasMatch = false;

      if (propertyAcceptsAuto(property)) {
        const autoOpt = document.createElement('option');
        autoOpt.value = 'auto';
        autoOpt.textContent = 'auto';
        if (currentValue === 'auto') {
          autoOpt.selected = true;
          hasMatch = true;
        }
        select.appendChild(autoOpt);
      }

      for (const t of tokens) {
        const opt = document.createElement('option');
        opt.value = t.value;
        opt.textContent = `${t.name} (${t.value})`;
        if (t.value === currentValue) {
          opt.selected = true;
          hasMatch = true;
        }
        select.appendChild(opt);
      }

      if (!hasMatch && currentValue !== 'Mixed') {
        const currentOpt = document.createElement('option');
        currentOpt.value = currentValue;
        currentOpt.textContent = `${currentValue} (current)`;
        currentOpt.selected = true;
        select.insertBefore(currentOpt, customOpt.nextSibling);
      }

      select.addEventListener('change', () => {
        if (select.value === '__custom__') {
          select.style.display = 'none';
          freeform.style.display = '';
          freeform.focus();
          return;
        }
        const newValue = select.value;
        const selectedToken = tokens.find((t) => t.value === newValue);
        onCommit(property, newValue, elements, selectedToken?.name);
        this.closeMulti(row, valueContainer, editor, property, elements);
      });

      editor.appendChild(select);
    }

    const freeform = createElement('input', {
      type: 'text',
      value: currentValue === 'Mixed' ? '' : currentValue,
      placeholder: currentValue === 'Mixed' ? 'Set value for all\u2026' : '',
    }, {
      background: OVERLAY.inputBg,
      color: OVERLAY.text,
      border: `1px solid ${OVERLAY.primary}`,
      borderRadius: OVERLAY.radiusSm,
      padding: '2px 4px',
      fontSize: OVERLAY.monoSize,
      fontFamily: OVERLAY.monoFamily,
      width: '100%',
      pointerEvents: 'auto',
      display: tokens.length > 0 ? 'none' : '',
    }) as HTMLInputElement;

    freeform.addEventListener('keydown', (e) => {
      // Keyboard value stepping (Arrow Up/Down with modifiers)
      if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
        const delta = getStepDelta(e);
        if (delta !== 0) {
          const newValue = stepCssValue(freeform.value, delta);
          if (newValue !== freeform.value) {
            e.preventDefault();
            e.stopPropagation();
            freeform.value = newValue;
            for (const el of elements) {
              (el as HTMLElement).style.setProperty(property, newValue);
            }
          }
        }
        return;
      }

      if (e.key === 'Enter') {
        e.preventDefault();
        const newValue = freeform.value.trim();
        if (newValue) {
          onCommit(property, newValue, elements);
        }
        this.closeMulti(row, valueContainer, editor, property, elements);
      }
      if (e.key === 'Escape') {
        e.preventDefault();
        // Revert any stepped changes for all elements
        for (const [el, origVal] of originalValues) {
          (el as HTMLElement).style.setProperty(property, origVal);
        }
        this.closeMulti(row, valueContainer, editor, property, elements);
      }
    });

    editor.appendChild(freeform);

    valueContainer.style.display = 'none';
    row.appendChild(editor);

    if (tokens.length > 0) {
      (editor.querySelector('select') as HTMLSelectElement)?.focus();
    } else {
      freeform.focus();
      freeform.select();
    }
  }

  closeMulti(
    row: HTMLDivElement,
    valueContainer: HTMLDivElement,
    editor: HTMLDivElement,
    property: string,
    elements: Element[],
  ): void {
    editor.remove();
    valueContainer.style.display = '';

    const values = elements.map((el) => getComputedProperty(el, property));
    const allSame = values.every((v) => v === values[0]);
    const valueEl = valueContainer.querySelector('span');
    if (valueEl) {
      valueEl.textContent = allSame ? (values[0] ?? '') : 'Mixed';
      valueEl.style.fontStyle = allSame ? '' : 'italic';
      valueEl.style.color = allSame ? '' : OVERLAY.textMuted;
    }
  }

  // ---------------------------------------------------------------------------
  // Token resolution
  // ---------------------------------------------------------------------------

  resolveToken(property: string, value: string): DesignToken | null {
    if (!this.tokenStore.loaded) return null;
    const result = this.tokenStore.resolveValue(property, value);
    if (result.token) {
      const tokens = this.tokenStore.getAll();
      return tokens.find((t) => t.name === result.token) ?? null;
    }
    return null;
  }
}
