import { OVERLAY } from './constants';
import type { PanelPosition } from './types';

// ---------------------------------------------------------------------------
// Element creation helpers
// ---------------------------------------------------------------------------

/** Create a DOM element with optional attributes and inline styles. */
export function createElement<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attrs?: Record<string, string>,
  styles?: Partial<CSSStyleDeclaration>,
): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  if (attrs) {
    for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
  }
  if (styles) Object.assign(el.style, styles);
  return el;
}

type TextVariant = 'heading' | 'body' | 'mono';

const TEXT_STYLES: Record<TextVariant, Partial<CSSStyleDeclaration>> = {
  heading: {
    fontFamily: OVERLAY.fontFamily,
    fontSize: OVERLAY.headingSize,
    fontWeight: OVERLAY.headingWeight,
    color: OVERLAY.text,
    lineHeight: '1.4',
  },
  body: {
    fontFamily: OVERLAY.fontFamily,
    fontSize: OVERLAY.bodySize,
    fontWeight: OVERLAY.bodyWeight,
    color: OVERLAY.text,
    lineHeight: '1.4',
  },
  mono: {
    fontFamily: OVERLAY.monoFamily,
    fontSize: OVERLAY.monoSize,
    fontWeight: OVERLAY.monoWeight,
    color: OVERLAY.text,
    lineHeight: '1.4',
  },
};

/** Create a text element styled with an overlay type token. */
export function createText(
  tag: keyof HTMLElementTagNameMap,
  text: string,
  variant: TextVariant,
): HTMLElement {
  const el = createElement(tag, {}, TEXT_STYLES[variant]);
  el.textContent = text;
  return el;
}

// ---------------------------------------------------------------------------
// Overlay styling
// ---------------------------------------------------------------------------

/** Batch-apply styles to an element. */
export function setOverlayStyles(
  el: HTMLElement,
  styles: Partial<CSSStyleDeclaration>,
): void {
  Object.assign(el.style, styles);
}

// ---------------------------------------------------------------------------
// Buttons
// ---------------------------------------------------------------------------

type ButtonVariant = 'primary' | 'ghost' | 'destructive';

const BUTTON_BASE: Partial<CSSStyleDeclaration> = {
  border: 'none',
  borderRadius: OVERLAY.radiusSm,
  padding: '4px 8px',
  fontSize: OVERLAY.bodySize,
  fontFamily: OVERLAY.fontFamily,
  fontWeight: '500',
  cursor: 'pointer',
  transition: 'background 0.15s',
  lineHeight: '1.4',
};

const BUTTON_VARIANTS: Record<ButtonVariant, Partial<CSSStyleDeclaration>> = {
  primary: {
    background: OVERLAY.primary,
    color: OVERLAY.onPrimary,
  },
  ghost: {
    background: 'transparent',
    color: OVERLAY.text,
    border: `1px solid ${OVERLAY.border}`,
  },
  destructive: {
    background: OVERLAY.destructiveFill,
    color: OVERLAY.onDestructive,
  },
};

/**
 * Create a styled button.
 *
 * When the visible label is a glyph with no textual meaning (e.g. the "×" close
 * glyph, which assistive tech announces as "times"), pass `ariaLabel` to give the
 * button a real accessible name. As a convenience, a bare "×" label defaults its
 * accessible name to "Close" so the many panel close buttons need no extra wiring.
 */
export function createButton(
  label: string,
  variant: ButtonVariant,
  onClick: () => void,
  ariaLabel?: string,
): HTMLButtonElement {
  const btn = createElement('button', {}, { ...BUTTON_BASE, ...BUTTON_VARIANTS[variant] });
  btn.textContent = label;
  const accessibleName = ariaLabel ?? (label === '×' ? 'Close' : undefined);
  if (accessibleName) btn.setAttribute('aria-label', accessibleName);
  btn.style.pointerEvents = 'auto';
  btn.addEventListener('click', onClick);

  // Hover styles
  const hoverBg =
    variant === 'primary'
      ? OVERLAY.primaryHover
      : variant === 'destructive'
        ? OVERLAY.destructiveFillHover
        : OVERLAY.hover;

  btn.addEventListener('mouseenter', () => {
    btn.style.background = hoverBg;
  });
  btn.addEventListener('mouseleave', () => {
    btn.style.background = BUTTON_VARIANTS[variant].background ?? '';
  });

  return btn;
}

// ---------------------------------------------------------------------------
// Draggable
// ---------------------------------------------------------------------------

/**
 * Make an element draggable by its "handle" area (e.g. panel header).
 * The container bounds the drag target. Calls onMove with the new position.
 */
export function makeDraggable(
  handle: HTMLElement,
  target: HTMLElement,
  onMove?: (pos: PanelPosition) => void,
  onDragging?: (pos: PanelPosition) => void,
): void {
  let startX = 0;
  let startY = 0;
  let startLeft = 0;
  let startTop = 0;

  handle.style.cursor = 'grab';

  const onPointerDown = (e: PointerEvent) => {
    // Skip drag for interactive child elements (buttons, inputs, etc.)
    const el = e.target as HTMLElement;
    if (el.closest('button, input, select, textarea, a')) return;

    e.preventDefault();
    handle.setPointerCapture(e.pointerId);
    handle.style.cursor = 'grabbing';
    startX = e.clientX;
    startY = e.clientY;
    const rect = target.getBoundingClientRect();
    startLeft = rect.left;
    startTop = rect.top;
  };

  const onPointerMove = (e: PointerEvent) => {
    if (!handle.hasPointerCapture(e.pointerId)) return;
    const dx = e.clientX - startX;
    const dy = e.clientY - startY;

    // Clamp within viewport
    const newLeft = Math.max(
      0,
      Math.min(startLeft + dx, window.innerWidth - target.offsetWidth),
    );
    const newTop = Math.max(
      0,
      Math.min(startTop + dy, window.innerHeight - target.offsetHeight),
    );

    target.style.left = `${newLeft}px`;
    target.style.top = `${newTop}px`;
    target.style.right = 'auto';
    target.style.bottom = 'auto';
    onDragging?.({ x: newLeft, y: newTop });
  };

  const onPointerUp = (e: PointerEvent) => {
    if (!handle.hasPointerCapture(e.pointerId)) return;
    handle.releasePointerCapture(e.pointerId);
    handle.style.cursor = 'grab';
    const rect = target.getBoundingClientRect();
    onMove?.({ x: rect.left, y: rect.top });
  };

  handle.addEventListener('pointerdown', onPointerDown);
  handle.addEventListener('pointermove', onPointerMove);
  handle.addEventListener('pointerup', onPointerUp);
}

// ---------------------------------------------------------------------------
// Animation
// ---------------------------------------------------------------------------

/** Animate a CSS transition for snap-on-release. */
export function animateSnap(
  el: HTMLElement,
  property: string,
  toValue: string,
  durationMs: number,
): void {
  const camelProp = property.replace(/-([a-z])/g, (_, c: string) => c.toUpperCase());
  el.style.transition = `${property} ${durationMs}ms ease`;
  (el.style as unknown as Record<string, string>)[camelProp] = toValue;

  // Clean up transition after animation completes
  const cleanup = () => {
    el.style.transition = '';
    el.removeEventListener('transitionend', cleanup);
  };
  el.addEventListener('transitionend', cleanup);
}

/**
 * Mute every text-bearing element in a row to the themed muted colour.
 * Used for inactive and overridden CSS declarations instead of lowering the
 * row's opacity, which dropped their text below WCAG AA contrast.
 */
export function muteRowText(row: HTMLElement): void {
  for (const el of [row, ...Array.from(row.querySelectorAll<HTMLElement>('*'))]) {
    if (Array.from(el.childNodes).some((n) => n.nodeType === 3 && (n.textContent ?? '').trim())) {
      el.style.color = OVERLAY.textMuted;
    }
  }
}
