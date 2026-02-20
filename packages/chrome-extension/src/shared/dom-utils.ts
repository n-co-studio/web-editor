import type { BoundingRect, ElementInfo } from '@frontend-editor/shared';
import { TEXT_CONTENT_TRUNCATE_LENGTH } from './constants';

// ---------------------------------------------------------------------------
// Selector generation
// ---------------------------------------------------------------------------

/**
 * Build a reasonably unique CSS selector for an element.
 * Priority: #id → [data-source-*] → .classes:nth-of-type → tag:nth-child path.
 * Traverses at most 5 levels to keep selectors readable.
 */
export function generateSelector(el: Element): string {
  if (el.id) return `#${CSS.escape(el.id)}`;

  // data-source attributes give a stable identity
  const srcFile = el.getAttribute('data-source-file');
  const srcLine = el.getAttribute('data-source-line');
  if (srcFile && srcLine) {
    const srcIndex = el.getAttribute('data-source-index');
    let sel = `[data-source-file="${CSS.escape(srcFile)}"][data-source-line="${CSS.escape(srcLine)}"]`;
    if (srcIndex) sel += `[data-source-index="${CSS.escape(srcIndex)}"]`;
    return sel;
  }

  // Fall back to a structural path
  const parts: string[] = [];
  let current: Element | null = el;
  for (let depth = 0; current && depth < 5; depth++) {
    if (current.id) {
      parts.unshift(`#${CSS.escape(current.id)}`);
      break;
    }

    const tag = current.tagName.toLowerCase();
    const parentEl: Element | null = current.parentElement;
    if (parentEl) {
      const currentTag = current.tagName;
      const siblings = Array.from(parentEl.children).filter(
        (c: Element) => c.tagName === currentTag,
      );
      if (siblings.length > 1) {
        const idx = siblings.indexOf(current) + 1;
        parts.unshift(`${tag}:nth-of-type(${idx})`);
      } else {
        parts.unshift(tag);
      }
    } else {
      parts.unshift(tag);
    }
    current = parentEl;
  }
  return parts.join(' > ');
}

// ---------------------------------------------------------------------------
// Source attributes
// ---------------------------------------------------------------------------

export interface SourceAttrs {
  readonly file: string;
  readonly line: number;
  readonly index?: number;
}

/** Read data-source-* attributes injected by @frontend-editor/dev-plugin. */
export function readSourceAttributes(el: Element): SourceAttrs | null {
  const file = el.getAttribute('data-source-file');
  const line = el.getAttribute('data-source-line');
  if (!file || !line) return null;

  const indexAttr = el.getAttribute('data-source-index');
  return {
    file,
    line: parseInt(line, 10),
    index: indexAttr != null ? parseInt(indexAttr, 10) : undefined,
  };
}

// ---------------------------------------------------------------------------
// ElementInfo assembly
// ---------------------------------------------------------------------------

/** Convert a native DOMRect to a serializable BoundingRect. */
export function serializeBoundingRect(rect: DOMRect): BoundingRect {
  return {
    x: rect.x,
    y: rect.y,
    width: rect.width,
    height: rect.height,
    top: rect.top,
    right: rect.right,
    bottom: rect.bottom,
    left: rect.left,
  };
}

/** Assemble a full ElementInfo from a DOM element. */
export function buildElementInfo(el: Element): ElementInfo {
  const source = readSourceAttributes(el);
  const rect = el.getBoundingClientRect();
  const text = el.textContent?.trim().slice(0, TEXT_CONTENT_TRUNCATE_LENGTH);

  // Gather useful attributes
  const attrs: Record<string, string> = {};
  for (const attr of el.attributes) {
    if (
      attr.name === 'class' ||
      attr.name === 'id' ||
      attr.name.startsWith('data-') ||
      attr.name.startsWith('aria-') ||
      attr.name === 'role'
    ) {
      attrs[attr.name] = attr.value;
    }
  }

  return {
    selector: generateSelector(el),
    tagName: el.tagName.toLowerCase(),
    textContent: text || undefined,
    sourceFile: source?.file ?? '',
    sourceLine: source?.line ?? 0,
    instanceIndex: source?.index,
    attributes: attrs,
    boundingRect: serializeBoundingRect(rect),
  };
}

// ---------------------------------------------------------------------------
// Computed style helpers
// ---------------------------------------------------------------------------

/** Get a computed CSS property value for an element. */
export function getComputedProperty(el: Element, prop: string): string {
  return getComputedStyle(el).getPropertyValue(prop).trim();
}

/** Check if an element is visible (non-zero size, not hidden). */
export function isElementVisible(el: Element): boolean {
  const style = getComputedStyle(el);
  if (style.display === 'none' || style.visibility === 'hidden') return false;
  const rect = el.getBoundingClientRect();
  return rect.width > 0 && rect.height > 0;
}

/**
 * Get the topmost element at a point, excluding the overlay shadow host.
 * Temporarily hides the host to let elementFromPoint see through.
 */
export function getTopElementAt(
  x: number,
  y: number,
  overlayHost: HTMLElement,
): Element | null {
  const prev = overlayHost.style.display;
  overlayHost.style.display = 'none';
  const el = document.elementFromPoint(x, y);
  overlayHost.style.display = prev;
  return el;
}

// ---------------------------------------------------------------------------
// CSS shorthand expansion
// ---------------------------------------------------------------------------

/**
 * Expand a CSS shorthand property to its longhands.
 * Returns an array of { property, value } pairs.
 * If the property is already a longhand, returns it as-is.
 */
export function expandShorthand(
  property: string,
  value: string,
): Array<{ property: string; value: string }> {
  const expander = SHORTHAND_MAP[property];
  if (!expander) return [{ property, value }];
  return expander(value);
}

type Expander = (value: string) => Array<{ property: string; value: string }>;

/** Parse 1–4 value shorthand into [top, right, bottom, left]. */
function parseFourValues(value: string): [string, string, string, string] {
  const parts = value.trim().split(/\s+/);
  switch (parts.length) {
    case 1:
      return [parts[0], parts[0], parts[0], parts[0]];
    case 2:
      return [parts[0], parts[1], parts[0], parts[1]];
    case 3:
      return [parts[0], parts[1], parts[2], parts[1]];
    default:
      return [parts[0], parts[1], parts[2], parts[3]];
  }
}

function expandFourSided(prefix: string): Expander {
  return (value: string) => {
    const [top, right, bottom, left] = parseFourValues(value);
    return [
      { property: `${prefix}-top`, value: top },
      { property: `${prefix}-right`, value: right },
      { property: `${prefix}-bottom`, value: bottom },
      { property: `${prefix}-left`, value: left },
    ];
  };
}

/** Parse 1–4 value border-radius into [tl, tr, br, bl]. */
function expandBorderRadius(value: string): Array<{ property: string; value: string }> {
  // Handle potential slash notation (horizontal / vertical)
  const [h] = value.split('/').map((s) => s.trim());
  const parts = h.split(/\s+/);
  let tl: string, tr: string, br: string, bl: string;
  switch (parts.length) {
    case 1:
      [tl, tr, br, bl] = [parts[0], parts[0], parts[0], parts[0]];
      break;
    case 2:
      [tl, tr, br, bl] = [parts[0], parts[1], parts[0], parts[1]];
      break;
    case 3:
      [tl, tr, br, bl] = [parts[0], parts[1], parts[2], parts[1]];
      break;
    default:
      [tl, tr, br, bl] = [parts[0], parts[1], parts[2], parts[3]];
  }
  return [
    { property: 'border-top-left-radius', value: tl },
    { property: 'border-top-right-radius', value: tr },
    { property: 'border-bottom-right-radius', value: br },
    { property: 'border-bottom-left-radius', value: bl },
  ];
}

function expandBorderWidth(value: string): Array<{ property: string; value: string }> {
  const [top, right, bottom, left] = parseFourValues(value);
  return [
    { property: 'border-top-width', value: top },
    { property: 'border-right-width', value: right },
    { property: 'border-bottom-width', value: bottom },
    { property: 'border-left-width', value: left },
  ];
}

const SHORTHAND_MAP: Record<string, Expander> = {
  margin: expandFourSided('margin'),
  padding: expandFourSided('padding'),
  'border-width': expandBorderWidth,
  'border-radius': expandBorderRadius,
};
