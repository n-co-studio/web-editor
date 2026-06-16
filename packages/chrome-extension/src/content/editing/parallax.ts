/**
 * Parallax editing — convert an <img> into a fixed-background <div> (and back),
 * so the operator can use an image as a full-width parallax banner whose height
 * is adjusted with the existing dimensions tool.
 *
 * Pure module (guard + DOM construction), mirroring duplicate.ts. The UI toggle
 * lives in media.ts; the commit/history wiring lives in index.ts.
 */

const PARALLAX_MARKER = 'data-parallax';
const PARALLAX_SRC = 'data-parallax-src';
const PARALLAX_ALT = 'data-parallax-alt';

/** Default banner height — operator adjusts via the dimensions tool afterwards. */
const DEFAULT_HEIGHT = '400px';

/** True when the element is a parallax block produced by toParallaxBlock(). */
export function isParallaxBlock(el: Element): boolean {
  return el instanceof HTMLElement && el.hasAttribute(PARALLAX_MARKER);
}

/**
 * Returns a reason why parallax can't toggle for this element, or null if it can.
 * Allowed for an `<img>` with a resolvable source and a parent, or for an
 * existing parallax block (which can be reverted to an `<img>`).
 */
export function getParallaxBlockReason(el: Element): string | null {
  if (!(el instanceof HTMLElement)) return 'Not an HTML element';
  if (!el.parentElement) return 'Element has no parent';
  if (isParallaxBlock(el)) return null;
  if (el.tagName !== 'IMG') return 'Parallax can only be applied to an image';
  const src = el.getAttribute('src') || (el as HTMLImageElement).src;
  if (!src) return 'Image has no source';
  return null;
}

/** Whether toggling parallax on this element would turn it ON (vs revert OFF). */
export function wouldEnableParallax(el: Element): boolean {
  return !isParallaxBlock(el);
}

/**
 * Build a fixed-background `<div>` reproducing `img`. Preserves the authored
 * `src` (for source rewrite), alt (as aria-label), id, and class. Stores the
 * original src/alt in data-* markers so fromParallaxBlock() can revert exactly.
 */
export function toParallaxBlock(img: HTMLImageElement): HTMLDivElement {
  // Prefer the authored attribute value (relative path) over the resolved .src.
  const src = img.getAttribute('src') || img.src;
  const alt = img.getAttribute('alt') || '';

  const div = document.createElement('div');
  div.setAttribute(PARALLAX_MARKER, '');
  div.setAttribute(PARALLAX_SRC, src);
  if (alt) div.setAttribute(PARALLAX_ALT, alt);
  if (img.id) div.id = img.id;
  if (img.className) div.className = img.className;
  div.setAttribute('role', 'img');
  if (alt) div.setAttribute('aria-label', alt);

  div.style.backgroundImage = `url("${src}")`;
  div.style.backgroundAttachment = 'fixed';
  div.style.backgroundSize = 'cover';
  div.style.backgroundPosition = 'center';
  div.style.backgroundRepeat = 'no-repeat';
  div.style.width = '100%';
  div.style.height = DEFAULT_HEIGHT;

  return div;
}

/** Reconstruct the original `<img>` from a parallax block's data-* markers. */
export function fromParallaxBlock(div: HTMLElement): HTMLImageElement {
  const img = document.createElement('img');
  const src = div.getAttribute(PARALLAX_SRC) || '';
  if (src) img.setAttribute('src', src);
  const alt = div.getAttribute(PARALLAX_ALT);
  if (alt) img.setAttribute('alt', alt);
  if (div.id) img.id = div.id;
  if (div.className) img.className = div.className;
  return img;
}
