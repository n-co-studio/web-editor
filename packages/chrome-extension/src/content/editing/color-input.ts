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
 * Build a freeform color control: a clickable swatch that opens a picker
 * popover, plus a text input for manual entry (hex, rgb(), named colors).
 *
 * This is the "No Tokens → freeform editing" affordance (feature-003): edits
 * are emitted as raw CSS via `PropertyChange` with no `toToken`. The swatch
 * previews live via `PreviewManager.begin/apply` and commits on picker
 * `change`; the text input commits on Enter.
 *
 * The picker is a real, visibly sized `<input type="color">` inside a popover
 * anchored above the swatch — not a zero-size hidden input driven by
 * `.click()`, which Chromium declines to open a chooser for because there is
 * no box to anchor it to. The popover is appended to the shadow root so the
 * owning panel's `overflow: hidden` cannot clip it.
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
    border: `1px solid ${OVERLAY.swatchBorder}`,
    background: currentValue,
    flexShrink: '0',
    cursor: 'pointer',
  });
  swatch.addEventListener('mouseenter', () => { swatch.style.borderColor = OVERLAY.primary; });
  swatch.addEventListener('mouseleave', () => { swatch.style.borderColor = OVERLAY.swatchBorder; });
  swatch.addEventListener('focus', () => { swatch.style.outline = `2px solid ${OVERLAY.primary}`; });
  swatch.addEventListener('blur', () => { swatch.style.outline = 'none'; });

  // The picker lives in a popover anchored above the swatch, NOT in a hidden
  // input triggered by `.click()`.
  //
  // The previous approach gave the input `width:0; height:0; opacity:0;
  // pointer-events:none` and called `colorInput.click()` from the swatch.
  // Chromium anchors the native colour chooser to the input's box, and an
  // element with no geometry gives it nowhere to attach — so the swatch
  // appeared dead: no picker, no error, nothing. Rendering the input at a real
  // size inside a panel makes the chooser open reliably, and gives the control
  // somewhere to put a hex field and a preview that the inline row has no room
  // for.
  const colorInput = createElement('input', { type: 'color', 'aria-label': `Pick a colour for ${property}` }, {
    width: '100%',
    height: '28px',
    padding: '0',
    border: `1px solid ${OVERLAY.swatchBorder}`,
    borderRadius: OVERLAY.radiusSm,
    background: 'transparent',
    cursor: 'pointer',
    pointerEvents: 'auto',
  }) as HTMLInputElement;
  colorInput.value = toHex(currentValue);

  const popover = createElement('div', { role: 'dialog', 'aria-label': `${property} colour picker` }, {
    position: 'fixed',
    display: 'none',
    flexDirection: 'column',
    gap: '6px',
    width: '168px',
    padding: '8px',
    background: OVERLAY.bgRaised,
    border: `1px solid ${OVERLAY.border}`,
    borderRadius: OVERLAY.radiusMd,
    boxShadow: OVERLAY.shadowLg,
    // Above the panel that owns it; panels sit at 102.
    zIndex: '140',
    pointerEvents: 'auto',
  });

  const popoverLabel = createElement('div', {}, {
    fontSize: '9px',
    letterSpacing: '0.5px',
    color: OVERLAY.textMuted,
    fontFamily: OVERLAY.monoFamily,
  });
  popoverLabel.textContent = property.toUpperCase();
  popover.appendChild(popoverLabel);
  popover.appendChild(colorInput);

  let popoverOpen = false;

  /** Place the popover above the swatch, flipping below when it would clip. */
  const positionPopover = (): void => {
    const r = swatch.getBoundingClientRect();
    const h = popover.offsetHeight || 80;
    const w = popover.offsetWidth || 168;
    const above = r.top - h - 6;
    const top = above < 8 ? r.bottom + 6 : above;
    const left = Math.max(8, Math.min(r.left, window.innerWidth - w - 8));
    popover.style.top = `${top}px`;
    popover.style.left = `${left}px`;
  };

  // Dismissal is bound only while open, and in the capture phase so it runs
  // before the panel's own handlers. Without the `popover.contains` guard the
  // first click inside — including on the input itself — would close it.
  const onDocPointerDown = (e: Event): void => {
    const t = e.target as Node | null;
    if (t && (popover.contains(t) || swatch.contains(t))) return;
    closePopover();
  };
  const onDocKeydown = (e: KeyboardEvent): void => {
    if (e.key === 'Escape') { e.stopPropagation(); closePopover(); swatch.focus(); }
  };

  function closePopover(): void {
    if (!popoverOpen) return;
    popoverOpen = false;
    popover.style.display = 'none';
    swatch.setAttribute('aria-expanded', 'false');
    document.removeEventListener('pointerdown', onDocPointerDown, true);
    document.removeEventListener('keydown', onDocKeydown, true);
  }

  function openPopover(): void {
    if (popoverOpen) return;
    popoverOpen = true;
    popover.style.display = 'flex';
    swatch.setAttribute('aria-expanded', 'true');
    positionPopover();
    document.addEventListener('pointerdown', onDocPointerDown, true);
    document.addEventListener('keydown', onDocKeydown, true);
  }

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

  swatch.setAttribute('aria-haspopup', 'dialog');
  swatch.setAttribute('aria-expanded', 'false');
  swatch.title = 'Open colour picker';
  swatch.addEventListener('click', () => {
    if (popoverOpen) closePopover(); else openPopover();
  });
  swatch.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      if (popoverOpen) closePopover(); else openPopover();
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

  // Commit closes the popover: the native chooser has already gone by the time
  // `change` fires, so leaving the panel behind would strand an empty box.
  colorInput.addEventListener('change', () => closePopover());

  row.appendChild(swatch);
  row.appendChild(textInput);
  // The popover is position:fixed and must not be clipped by the owning
  // panel's overflow:hidden, so it is appended to the shadow root rather than
  // to the row. It is removed when the row leaves the DOM (see below).
  const root = swatch.getRootNode();
  if (root instanceof ShadowRoot) root.appendChild(popover);
  else row.appendChild(popover);

  // Panels tear down by removing their container, which would otherwise orphan
  // this popover in the shadow root along with its two document listeners.
  if (typeof MutationObserver !== 'undefined') {
    const mo = new MutationObserver(() => {
      if (!row.isConnected) {
        closePopover();
        popover.remove();
        mo.disconnect();
      }
    });
    const observeRoot = root instanceof ShadowRoot ? root : document;
    mo.observe(observeRoot, { childList: true, subtree: true });
  }

  return row;
}
