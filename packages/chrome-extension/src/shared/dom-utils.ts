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

// ---------------------------------------------------------------------------
// Batched computed style snapshot
// ---------------------------------------------------------------------------

/**
 * A snapshot of all computed CSS properties needed by DevTools panes.
 * Created once per updateElement() call to eliminate redundant getComputedStyle invocations.
 */
export interface ComputedStyleSnapshot {
  // Dimensions
  width: string;
  height: string;
  // Spacing
  paddingTop: string;
  paddingRight: string;
  paddingBottom: string;
  paddingLeft: string;
  marginTop: string;
  marginRight: string;
  marginBottom: string;
  marginLeft: string;
  // Typography
  fontFamily: string;
  fontSize: string;
  fontWeight: string;
  lineHeight: string;
  color: string;
  letterSpacing: string;
  textAlign: string;
  textDecoration: string;
  textTransform: string;
  // Background
  backgroundColor: string;
  backgroundImage: string;
  // Position
  position: string;
  top: string;
  right: string;
  bottom: string;
  left: string;
  zIndex: string;
  // Border
  borderRadius: string;
  borderColor: string;
  borderWidth: string;
  borderStyle: string;
  // Layout — container
  display: string;
  flexDirection: string;
  justifyContent: string;
  alignItems: string;
  flexWrap: string;
  gap: string;
  gridTemplateColumns: string;
  gridTemplateRows: string;
  gridAutoFlow: string;
  // Layout — child
  alignSelf: string;
  flexGrow: string;
  flexShrink: string;
  flexBasis: string;
  order: string;
  gridColumn: string;
  gridRow: string;
  // Visibility
  opacity: string;
  overflow: string;
  visibility: string;
  // Box model
  boxSizing: string;
}

/** Read all panel-relevant CSS properties in a single getComputedStyle call. */
export function createStyleSnapshot(el: Element): ComputedStyleSnapshot {
  const cs = getComputedStyle(el);
  return {
    width: cs.getPropertyValue('width').trim(),
    height: cs.getPropertyValue('height').trim(),
    paddingTop: cs.getPropertyValue('padding-top').trim(),
    paddingRight: cs.getPropertyValue('padding-right').trim(),
    paddingBottom: cs.getPropertyValue('padding-bottom').trim(),
    paddingLeft: cs.getPropertyValue('padding-left').trim(),
    marginTop: cs.getPropertyValue('margin-top').trim(),
    marginRight: cs.getPropertyValue('margin-right').trim(),
    marginBottom: cs.getPropertyValue('margin-bottom').trim(),
    marginLeft: cs.getPropertyValue('margin-left').trim(),
    fontFamily: cs.getPropertyValue('font-family').trim(),
    fontSize: cs.getPropertyValue('font-size').trim(),
    fontWeight: cs.getPropertyValue('font-weight').trim(),
    lineHeight: cs.getPropertyValue('line-height').trim(),
    color: cs.getPropertyValue('color').trim(),
    letterSpacing: cs.getPropertyValue('letter-spacing').trim(),
    textAlign: cs.getPropertyValue('text-align').trim(),
    textDecoration: cs.getPropertyValue('text-decoration').trim(),
    textTransform: cs.getPropertyValue('text-transform').trim(),
    backgroundColor: cs.getPropertyValue('background-color').trim(),
    backgroundImage: cs.getPropertyValue('background-image').trim(),
    position: cs.getPropertyValue('position').trim(),
    top: cs.getPropertyValue('top').trim(),
    right: cs.getPropertyValue('right').trim(),
    bottom: cs.getPropertyValue('bottom').trim(),
    left: cs.getPropertyValue('left').trim(),
    zIndex: cs.getPropertyValue('z-index').trim(),
    borderRadius: cs.getPropertyValue('border-radius').trim(),
    borderColor: cs.getPropertyValue('border-color').trim(),
    borderWidth: cs.getPropertyValue('border-width').trim(),
    borderStyle: cs.getPropertyValue('border-style').trim(),
    display: cs.getPropertyValue('display').trim(),
    flexDirection: cs.getPropertyValue('flex-direction').trim(),
    justifyContent: cs.getPropertyValue('justify-content').trim(),
    alignItems: cs.getPropertyValue('align-items').trim(),
    flexWrap: cs.getPropertyValue('flex-wrap').trim(),
    gap: cs.getPropertyValue('gap').trim(),
    gridTemplateColumns: cs.getPropertyValue('grid-template-columns').trim(),
    gridTemplateRows: cs.getPropertyValue('grid-template-rows').trim(),
    gridAutoFlow: cs.getPropertyValue('grid-auto-flow').trim(),
    alignSelf: cs.getPropertyValue('align-self').trim(),
    flexGrow: cs.getPropertyValue('flex-grow').trim(),
    flexShrink: cs.getPropertyValue('flex-shrink').trim(),
    flexBasis: cs.getPropertyValue('flex-basis').trim(),
    order: cs.getPropertyValue('order').trim(),
    gridColumn: cs.getPropertyValue('grid-column').trim(),
    gridRow: cs.getPropertyValue('grid-row').trim(),
    opacity: cs.getPropertyValue('opacity').trim(),
    overflow: cs.getPropertyValue('overflow').trim(),
    visibility: cs.getPropertyValue('visibility').trim(),
    boxSizing: cs.getPropertyValue('box-sizing').trim(),
  };
}

/** Look up a CSS property from a snapshot by its CSS property name (kebab-case). */
export function snapshotGet(snapshot: ComputedStyleSnapshot, property: string): string {
  const key = property.replace(/-([a-z])/g, (_, c: string) => c.toUpperCase()) as keyof ComputedStyleSnapshot;
  return snapshot[key] ?? '';
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
