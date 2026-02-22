import { createElement } from '../../../../shared/ui-utils';
import { OVERLAY } from '../../../../shared/constants';
import type { ComputedStyleSnapshot } from '../../../../shared/dom-utils';

interface RGBA {
  r: number;
  g: number;
  b: number;
  a: number;
}

/** Parse computed CSS color (always rgb/rgba from getComputedStyle). */
function parseRGBA(color: string): RGBA | null {
  const match = color.match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([\d.]+))?\s*\)/);
  if (!match) return null;
  return {
    r: parseInt(match[1], 10),
    g: parseInt(match[2], 10),
    b: parseInt(match[3], 10),
    a: match[4] !== undefined ? parseFloat(match[4]) : 1,
  };
}

/** Simplified gamma expansion: (c/255)^2.2 */
function linearize(channel: number): number {
  return Math.pow(channel / 255, 2.2);
}

/** WCAG relative luminance. */
function luminance(color: RGBA): number {
  return 0.2126 * linearize(color.r) + 0.7152 * linearize(color.g) + 0.0722 * linearize(color.b);
}

/** WCAG contrast ratio. */
function contrastRatio(l1: number, l2: number): number {
  const lighter = Math.max(l1, l2);
  const darker = Math.min(l1, l2);
  return (lighter + 0.05) / (darker + 0.05);
}

/** Blend foreground RGBA over opaque background. */
function alphaBlend(fg: RGBA, bg: RGBA): RGBA {
  const a = fg.a;
  return {
    r: Math.round(fg.r * a + bg.r * (1 - a)),
    g: Math.round(fg.g * a + bg.g * (1 - a)),
    b: Math.round(fg.b * a + bg.b * (1 - a)),
    a: 1,
  };
}

/** Resolve effective background by walking ancestors (up to 10 levels). */
function resolveBackground(element: Element): RGBA | null {
  let current: Element | null = element;
  for (let depth = 0; current && depth < 10; depth++) {
    const cs = getComputedStyle(current);
    if (cs.backgroundImage && cs.backgroundImage !== 'none') {
      return null;
    }
    const bg = parseRGBA(cs.backgroundColor);
    if (bg && bg.a >= 1) return bg;
    current = current.parentElement;
  }
  // Assume white page background as ultimate fallback
  return { r: 255, g: 255, b: 255, a: 1 };
}

/** Per-element cache for resolved backgrounds. */
const bgCache = new WeakMap<Element, RGBA | null>();

function getResolvedBackground(element: Element): RGBA | null {
  if (bgCache.has(element)) return bgCache.get(element)!;
  const bg = resolveBackground(element);
  bgCache.set(element, bg);
  return bg;
}

/** Check if text is "large" per WCAG: >= 18px, or >= 14px and bold >= 700. */
function isLargeText(snapshot: ComputedStyleSnapshot): boolean {
  const size = parseFloat(snapshot.fontSize);
  if (isNaN(size)) return false;
  if (size >= 18) return true;
  const weight = parseInt(snapshot.fontWeight, 10);
  return size >= 14 && !isNaN(weight) && weight >= 700;
}

export interface ContrastResult {
  ratio: number;
  passes: boolean;
  label: string;
  computable: boolean;
}

/**
 * Compute WCAG contrast ratio for the `color` property.
 * Only meaningful when property === 'color'.
 */
export function computeContrast(
  property: string,
  snapshot: ComputedStyleSnapshot,
  element: Element,
): ContrastResult | null {
  if (property !== 'color') return null;

  const fg = parseRGBA(snapshot.color);
  if (!fg) return null;

  const bg = getResolvedBackground(element);
  if (!bg) {
    return {
      ratio: 0,
      passes: false,
      label: '\u2014', // em dash
      computable: false,
    };
  }

  const effectiveFg = fg.a < 1 ? alphaBlend(fg, bg) : fg;
  const fgL = luminance(effectiveFg);
  const bgL = luminance(bg);
  const ratio = contrastRatio(fgL, bgL);

  const threshold = isLargeText(snapshot) ? 3 : 4.5;
  const passes = ratio >= threshold;
  const roundedRatio = Math.round(ratio * 10) / 10;

  return {
    ratio: roundedRatio,
    passes,
    label: passes ? `${roundedRatio}:1 AA` : `${roundedRatio}:1 \u2717`,
    computable: true,
  };
}

/** Create a contrast ratio badge element for the badge-slot. */
export function createContrastBadge(result: ContrastResult): HTMLSpanElement {
  const color = result.computable
    ? (result.passes ? OVERLAY.success : OVERLAY.destructive)
    : OVERLAY.textMuted;

  const badge = createElement('span', {
    ...(result.computable ? {} : { title: 'Cannot determine contrast (gradient or image background)' }),
  }, {
    color,
    fontSize: '10px',
    fontFamily: OVERLAY.monoFamily,
    whiteSpace: 'nowrap',
    flexShrink: '0',
  }) as HTMLSpanElement;

  badge.textContent = result.label;
  return badge;
}
