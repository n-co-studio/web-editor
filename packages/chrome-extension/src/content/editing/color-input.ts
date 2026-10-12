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
 * True when the browser would accept `value` as a CSS colour.
 *
 * Used to keep mis-categorised tokens out of the colour swatch grid. A token's
 * `category` is assigned upstream and is not authoritative — an easing curve
 * arriving as `category: 'colors'` rendered as a swatch with no fill, and
 * clicking it queued a change the CSSOM had already discarded.
 *
 * `CSS.supports` is the browser's own parser, so this stays correct for colour
 * syntax the extension has never heard of (`oklch()`, `color-mix()`, relative
 * colours) rather than drifting behind a hand-written pattern. `var(...)`
 * references are accepted: the value is valid CSS and resolving it is the
 * page's business, not ours.
 *
 * Exported for tests; `CSS.supports` is feature-detected so a non-browser test
 * environment degrades to accepting everything rather than emptying the grid.
 */
export function isColorValue(value: string): boolean {
  const v = value.trim();
  if (v === '') return false;
  if (typeof CSS === 'undefined' || typeof CSS.supports !== 'function') return true;
  return CSS.supports('color', v);
}

/**
 * Attach a colour-picker popover to a swatch element.
 *
 * Extracted so every colour control in the overlay behaves the same way. The
 * three that existed before each hid an `<input type="color">` at
 * `width:0; height:0; opacity:0; pointer-events:none` and called `.click()` on
 * it — Chromium anchors the native chooser to the input's box, so with no box
 * there was no chooser, no error, and a swatch that looked dead.
 *
 * Deliberately does NOT speak `PropertyChange`: the box-shadow and outline
 * controls mutate a shared object and commit through their own serialiser, so
 * this reports raw values and lets the caller decide what a commit means.
 *
 * Returns a handle so callers can keep the swatch in sync and tear the popover
 * down with their panel.
 */
export function attachColorPopover(
  swatch: HTMLElement,
  opts: {
    label: string;
    initial: string;
    tokens?: readonly { name: string; value: string }[];
    /** Live preview as the user drags in the native chooser. */
    onInput: (value: string) => void;
    /** Settled choice — the point at which a change should be recorded. */
    onCommit: (value: string, token?: { name: string; value: string }) => void;
  },
): { popover: HTMLElement; close: () => void; setValue: (v: string) => void } {
  const colorInput = createElement('input', {
    type: 'color',
    'aria-label': `Pick a colour for ${opts.label}`,
  }, {
    width: '100%',
    height: '28px',
    padding: '0',
    border: `1px solid ${OVERLAY.swatchBorder}`,
    borderRadius: OVERLAY.radiusSm,
    background: 'transparent',
    cursor: 'pointer',
    pointerEvents: 'auto',
  }) as HTMLInputElement;
  colorInput.value = toHex(opts.initial);

  const popover = createElement('div', {
    role: 'dialog',
    'aria-label': `${opts.label} colour picker`,
  }, {
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
    zIndex: '140',
    pointerEvents: 'auto',
  });

  const heading = createElement('div', {}, {
    fontSize: '9px',
    letterSpacing: '0.5px',
    color: OVERLAY.textMuted,
    fontFamily: OVERLAY.monoFamily,
  });
  heading.textContent = opts.label.toUpperCase();
  popover.appendChild(heading);

  // Token swatches, filtered to values the browser accepts as a colour. The
  // store indexes by `cssProperties`, which upstream fills loosely enough that
  // font weights and easing curves arrive under `color`.
  const colorTokens = (opts.tokens ?? []).filter((t) => isColorValue(t.value));
  if (colorTokens.length > 0) {
    const grid = createElement('div', {}, {
      display: 'grid',
      gridTemplateColumns: 'repeat(5, 1fr)',
      gap: '4px',
    });
    for (const token of colorTokens) {
      const chip = createElement('div', {
        role: 'button',
        tabindex: '0',
        title: `${token.name}: ${token.value}`,
        'aria-label': `${token.name}, ${token.value}`,
      }, {
        width: '100%',
        aspectRatio: '1',
        borderRadius: OVERLAY.radiusSm,
        border: `1px solid ${OVERLAY.swatchBorder}`,
        background: token.value,
        cursor: 'pointer',
      });
      const pick = (): void => {
        colorInput.value = toHex(token.value);
        opts.onCommit(token.value, token);
        close();
      };
      chip.addEventListener('click', pick);
      chip.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); pick(); }
      });
      grid.appendChild(chip);
    }
    popover.appendChild(grid);
    popover.appendChild(createElement('div', {}, {
      height: '1px', background: OVERLAY.border, margin: '2px 0',
    }));
  }

  popover.appendChild(colorInput);

  let open = false;

  const position = (): void => {
    const r = swatch.getBoundingClientRect();
    const h = popover.offsetHeight || 80;
    const w = popover.offsetWidth || 168;
    const above = r.top - h - 6;
    popover.style.top = `${above < 8 ? r.bottom + 6 : above}px`;
    popover.style.left = `${Math.max(8, Math.min(r.left, window.innerWidth - w - 8))}px`;
  };

  const onDocPointerDown = (e: Event): void => {
    // If the owning panel was torn down while this was open, the swatch is
    // gone and the popover is pointing at nothing — close on the next click
    // rather than leaving it floating.
    if (!swatch.isConnected) { close(); return; }
    const t = e.target as Node | null;
    if (t && (popover.contains(t) || swatch.contains(t))) return;
    close();
  };
  const onDocKeydown = (e: KeyboardEvent): void => {
    if (e.key === 'Escape') { e.stopPropagation(); close(); swatch.focus(); }
  };

  function close(): void {
    if (!open) return;
    open = false;
    popover.style.display = 'none';
    // Removed from the DOM rather than just hidden. The popover lives in the
    // shadow root, outside the panel that owns it, so panel teardown cannot
    // collect it — taking it out on close is what makes a MutationObserver
    // unnecessary and leaves nothing to orphan.
    popover.remove();
    swatch.setAttribute('aria-expanded', 'false');
    document.removeEventListener('pointerdown', onDocPointerDown, true);
    document.removeEventListener('keydown', onDocKeydown, true);
  }

  function show(): void {
    if (open) return;
    open = true;
    // Resolve the host HERE, not at construction.
    //
    // Panels build their whole subtree and append it to the shadow root last,
    // so at the time this control is built the swatch is still detached and
    // `getRootNode()` returns that detached subtree — not the ShadowRoot. An
    // earlier version resolved the host once, up front, and silently appended
    // the popover nowhere: clicking set display:flex on a node that was not in
    // any document, so nothing appeared and nothing errored.
    //
    // By the time the swatch can be clicked it is connected, so resolving on
    // open always finds the real root.
    // `typeof` guards before each `instanceof`: a bare `x instanceof ShadowRoot`
    // throws ReferenceError wherever the constructor is not defined, which
    // turns a missing global into a crash inside a click handler rather than a
    // graceful fallback.
    const root = swatch.getRootNode() as ParentNode & { body?: HTMLElement | null };
    const inShadow = typeof ShadowRoot !== 'undefined' && root instanceof ShadowRoot;
    const host: ParentNode = inShadow ? root : (root.body ?? document.body);
    // position:fixed, so it has to escape the owning panel's overflow:hidden —
    // hence the shadow root rather than the panel.
    host.appendChild(popover);

    popover.style.display = 'flex';
    swatch.setAttribute('aria-expanded', 'true');
    position();
    document.addEventListener('pointerdown', onDocPointerDown, true);
    document.addEventListener('keydown', onDocKeydown, true);
  }

  colorInput.addEventListener('input', () => opts.onInput(colorInput.value));
  colorInput.addEventListener('change', () => { opts.onCommit(colorInput.value); close(); });

  swatch.setAttribute('role', 'button');
  if (!swatch.hasAttribute('tabindex')) swatch.setAttribute('tabindex', '0');
  swatch.setAttribute('aria-haspopup', 'dialog');
  swatch.setAttribute('aria-expanded', 'false');
  swatch.style.cursor = 'pointer';
  swatch.addEventListener('click', () => { if (open) close(); else show(); });
  swatch.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); if (open) close(); else show(); }
  });

  return {
    popover,
    close,
    setValue: (v: string) => { colorInput.value = toHex(v); },
  };
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
  /**
   * Project colour tokens to offer inside the popover, above the picker.
   *
   * Optional because not every caller has a token store to hand. Values are
   * filtered through `isColorValue` before rendering: the store indexes tokens
   * by `cssProperties`, which upstream populates loosely enough that a font
   * weight, a z-index and an easing curve all arrive under `color` — so
   * trusting the index would put `100 (fw-thin)` and
   * `cubic-bezier(…) (ease-link)` in a colour picker.
   */
  tokens: readonly { name: string; value: string }[] = [],
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

  // One shared popover implementation — see attachColorPopover for why the
  // old hidden-input approach could never open a chooser.
  const picker = attachColorPopover(swatch, {
    label: property,
    initial: currentValue,
    tokens,
    onInput: (value) => {
      swatch.style.background = value;
      preview.begin(element as HTMLElement);
      preview.apply(property, value);
    },
    onCommit: (value, token) => {
      swatch.style.background = value;
      preview.begin(element as HTMLElement);
      preview.apply(property, value);
      const originals = preview.commit();
      const fromValue = originals.get(property) || currentValue;
      textInput.value = value;
      onCommit([{ property, fromValue, toValue: value, toToken: token?.name }]);
    },
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
      picker.setValue(textInput.value);
      onCommit([{ property, fromValue, toValue: textInput.value }]);
      textInput.blur();
    }
  });

  row.appendChild(swatch);
  row.appendChild(textInput);

  return row;
}
