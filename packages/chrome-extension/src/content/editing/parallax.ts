/**
 * Parallax editing — convert an <img> into a tunable, multi-mechanism parallax
 * block (and back). Four mechanisms are supported:
 *
 *  - `fixed`        — background-attachment: fixed (no true depth; not iOS Safari)
 *  - `transform-3d` — perspective wrapper + translateZ inner (baseline, default)
 *  - `scroll-driven`— pure-CSS @keyframes + animation-timeline: scroll()
 *  - `js-scroll`    — requestAnimationFrame-batched scroll listener
 *
 * A single canonical custom property `--parallax-strength` (0–1, default 0.3)
 * drives every mechanism through per-mode `calc()` derivation, so mechanisms are
 * interchangeable without re-prompting. The mechanism persists on
 * `data-parallax-type`, the strength on `data-parallax-strength`.
 *
 * Every mechanism emits a mandatory `@media (prefers-reduced-motion: reduce)`
 * zeroing (WCAG 2.3.3); for `js-scroll` the generated handler short-circuits on
 * `matchMedia` instead (carried as a StylesheetChange for CSS mechanisms).
 *
 * Pure builders (guard + DOM construction + diff-payload assembly) plus a small
 * live runtime (`ParallaxRuntime`) that manages the injected stylesheet /
 * scroll-listener artifacts the CSS-3D and JS mechanisms need to render live.
 * The UI lives in media.ts; the commit/history wiring lives in index.ts.
 */

import type {
  StylesheetChange,
  StylesheetRule,
  ScriptBehaviorChange,
  PropertyChange,
} from '@nco-studio/shared';

export type ParallaxMechanism = 'fixed' | 'transform-3d' | 'scroll-driven' | 'js-scroll';

export const PARALLAX_MECHANISMS: readonly ParallaxMechanism[] = [
  'fixed',
  'transform-3d',
  'scroll-driven',
  'js-scroll',
];

/**
 * Default mechanism: the JS background-scan (`js-scroll`) — pins the image to the
 * viewport so the box reveals a fixed slice, works in any scroll container, and
 * matches a hand-built reference parallax. The other mechanisms remain available.
 */
export const DEFAULT_MECHANISM: ParallaxMechanism = 'js-scroll';

/** Canonical dial default (feature-009 Strength Model). */
export const DEFAULT_STRENGTH = 0.3;

/**
 * Per-mechanism default strength on first convert. The scan reads best near
 * fully-pinned (like the reference), so it defaults high; the others keep the
 * canonical 0.3.
 */
export function defaultStrengthFor(mechanism: ParallaxMechanism): number {
  return mechanism === 'js-scroll' ? 0.9 : DEFAULT_STRENGTH;
}

/**
 * Which element's scrolling drives the effect. `'auto'` resolves the nearest
 * scrollable ancestor (handles page scroll AND inner overlay/`<main>` scroll
 * common in SPAs); `'page'` forces the viewport; `'container'` forces the
 * nearest scroll container. The operator can override the auto choice in the UI.
 */
export type ParallaxScrollSource = 'auto' | 'page' | 'container';

export const PARALLAX_SCROLL_SOURCES: readonly ParallaxScrollSource[] = ['auto', 'page', 'container'];
export const DEFAULT_SCROLL_SOURCE: ParallaxScrollSource = 'auto';

const PARALLAX_MARKER = 'data-parallax';
const PARALLAX_TYPE = 'data-parallax-type';
const PARALLAX_STRENGTH = 'data-parallax-strength';
const PARALLAX_SCROLL = 'data-parallax-scroll';
const PARALLAX_SRC = 'data-parallax-src';
const PARALLAX_ALT = 'data-parallax-alt';
const PARALLAX_ID = 'data-parallax-id';
const PARALLAX_INNER = 'data-parallax-inner';

/** The canonical strength custom property (used as a property NAME). */
export const STRENGTH_VAR = '--parallax-strength';
/** The canonical strength as a `var()` REFERENCE for use inside calc() expressions. */
const STRENGTH_REF = `var(${STRENGTH_VAR})`;
/** The 3D perspective custom property (transform-3d only). */
const PERSPECTIVE_VAR = '--p-perspective';
const PERSPECTIVE_PX = '300px';

/** Default banner height — operator adjusts via the dimensions / Advanced tools. */
const DEFAULT_HEIGHT = '400px';

// ---------------------------------------------------------------------------
// Guards & accessors
// ---------------------------------------------------------------------------

/** True when the element is a parallax block produced by toParallaxBlock(). */
export function isParallaxBlock(el: Element): boolean {
  return el instanceof HTMLElement && el.hasAttribute(PARALLAX_MARKER);
}

/**
 * Resolve the outermost parallax block for an element: the element itself when
 * it carries the marker, otherwise the nearest ancestor that does (e.g. when the
 * CSS-3D inner div is selected). Returns null when there is no parallax block.
 */
export function resolveParallaxBlock(el: Element): HTMLElement | null {
  if (el instanceof HTMLElement && el.hasAttribute(PARALLAX_MARKER)) return el;
  const closest = el.closest?.(`[${PARALLAX_MARKER}]`);
  return closest instanceof HTMLElement ? closest : null;
}

/**
 * Returns a reason why parallax can't toggle for this element, or null if it can.
 * Allowed for an `<img>` with a resolvable source and a parent, or for an
 * existing parallax block / its inner (which can be reverted to an `<img>`).
 */
export function getParallaxBlockReason(el: Element): string | null {
  if (!(el instanceof HTMLElement)) return 'Not an HTML element';
  // An existing parallax block (or its inner) can always be reverted.
  if (resolveParallaxBlock(el)) return null;
  if (!el.parentElement) return 'Element has no parent';
  if (el.tagName !== 'IMG') return 'Parallax can only be applied to an image';
  const src = el.getAttribute('src') || (el as HTMLImageElement).src;
  if (!src) return 'Image has no source';
  return null;
}

/** Whether toggling parallax on this element would turn it ON (vs revert OFF). */
export function wouldEnableParallax(el: Element): boolean {
  return resolveParallaxBlock(el) === null;
}

/** Clamp an arbitrary strength input to the canonical 0–1 range; NaN → default. */
export function clampStrength(value: number): number {
  if (!Number.isFinite(value)) return DEFAULT_STRENGTH;
  return Math.min(1, Math.max(0, value));
}

/** Read the persisted mechanism off a parallax block (unknown → default + warn). */
export function readParallaxMechanism(block: Element): ParallaxMechanism {
  const raw = block.getAttribute(PARALLAX_TYPE);
  if (raw && (PARALLAX_MECHANISMS as readonly string[]).includes(raw)) {
    return raw as ParallaxMechanism;
  }
  if (raw) console.warn(`[parallax] unknown data-parallax-type "${raw}" — defaulting to ${DEFAULT_MECHANISM}`);
  return DEFAULT_MECHANISM;
}

/**
 * Read the current strength off a parallax block: prefer the computed
 * `--parallax-strength` custom property, fall back to data-parallax-strength,
 * then the default. Always returns a clamped 0–1 value.
 */
export function readParallaxStrength(block: Element): number {
  let raw = '';
  if (block instanceof HTMLElement) {
    raw = getComputedStyle(block).getPropertyValue(STRENGTH_VAR).trim();
  }
  if (!raw) raw = block.getAttribute(PARALLAX_STRENGTH) ?? '';
  const n = parseFloat(raw);
  return Number.isFinite(n) ? clampStrength(n) : DEFAULT_STRENGTH;
}

/** Stable per-block id used to key live runtime artifacts and @keyframes names. */
export function getParallaxId(block: Element): string {
  return block.getAttribute(PARALLAX_ID) ?? '';
}

/** Derive the unique @keyframes identifier for a block id. */
export function keyframesNameFor(id: string): string {
  return `nco-parallax-${id}`;
}

/** Read the persisted scroll-source intent off a parallax block. */
export function readScrollSource(block: Element): ParallaxScrollSource {
  const raw = block.getAttribute(PARALLAX_SCROLL);
  if (raw && (PARALLAX_SCROLL_SOURCES as readonly string[]).includes(raw)) {
    return raw as ParallaxScrollSource;
  }
  return DEFAULT_SCROLL_SOURCE;
}

/**
 * Resolve the nearest scrollable ancestor of `el` — an element whose overflow-y
 * is auto/scroll and whose content overflows. Returns null when the page
 * (viewport) is the effective scroller. Skips the block itself.
 */
export function resolveScrollContainer(el: Element): HTMLElement | null {
  let node = el.parentElement;
  while (node && node !== document.body && node !== document.documentElement) {
    const oy = getComputedStyle(node).overflowY;
    if ((oy === 'auto' || oy === 'scroll') && node.scrollHeight > node.clientHeight) {
      return node;
    }
    node = node.parentElement;
  }
  return null;
}

/**
 * The element whose scroll drives the effect, given the block's scroll-source
 * intent. `null` means the page/viewport (`window`). `'page'` forces null;
 * `'container'`/`'auto'` resolve the nearest scroll container (null if none).
 */
export function effectiveScroller(block: Element, source: ParallaxScrollSource): HTMLElement | null {
  if (source === 'page') return null;
  return resolveScrollContainer(block);
}

// ---------------------------------------------------------------------------
// Block construction
// ---------------------------------------------------------------------------

/** data-source-* attributes carried across conversions to preserve the source mapping. */
const SOURCE_ATTRS = ['data-source-file', 'data-source-line', 'data-source-index'] as const;

interface ParallaxMeta {
  src: string;
  alt: string;
  id: string;
  className: string;
  /** Preserved data-source-* values (sparse) so every conversion keeps provenance. */
  source: Record<string, string>;
}

function readSourceAttrs(el: Element): Record<string, string> {
  const out: Record<string, string> = {};
  for (const attr of SOURCE_ATTRS) {
    const v = el.getAttribute(attr);
    if (v != null) out[attr] = v;
  }
  return out;
}

function metaFromImage(img: HTMLImageElement): ParallaxMeta {
  return {
    // Prefer the authored attribute value (relative path) over the resolved .src.
    src: img.getAttribute('src') || img.src,
    alt: img.getAttribute('alt') || '',
    id: img.id || '',
    className: img.className || '',
    source: readSourceAttrs(img),
  };
}

function metaFromBlock(block: HTMLElement): ParallaxMeta {
  return {
    src: block.getAttribute(PARALLAX_SRC) || '',
    alt: block.getAttribute(PARALLAX_ALT) || '',
    id: block.id || '',
    className: block.className || '',
    source: readSourceAttrs(block),
  };
}

function newParallaxId(): string {
  try {
    return crypto.randomUUID().replace(/-/g, '').slice(0, 8);
  } catch {
    return Math.random().toString(36).slice(2, 10);
  }
}

/** Apply the shared markers + identity (src/alt/id/class/role) to the outermost block. */
function applyMarkers(el: HTMLElement, meta: ParallaxMeta, mechanism: ParallaxMechanism, strength: number, id: string, scrollSource: ParallaxScrollSource): void {
  el.setAttribute(PARALLAX_MARKER, '');
  el.setAttribute(PARALLAX_TYPE, mechanism);
  el.setAttribute(PARALLAX_STRENGTH, String(strength));
  el.setAttribute(PARALLAX_SCROLL, scrollSource);
  el.setAttribute(PARALLAX_SRC, meta.src);
  if (meta.alt) el.setAttribute(PARALLAX_ALT, meta.alt);
  el.setAttribute(PARALLAX_ID, id);
  if (meta.id) el.id = meta.id;
  if (meta.className) el.className = meta.className;
  el.setAttribute('role', 'img');
  if (meta.alt) el.setAttribute('aria-label', meta.alt);
  // Carry the source mapping forward so block→block updates and the js-scroll
  // ScriptBehaviorChange.sourceFile keep their provenance (Risks: wrapper must
  // not orphan the source mapping).
  for (const [attr, value] of Object.entries(meta.source)) el.setAttribute(attr, value);
  el.style.setProperty(STRENGTH_VAR, String(strength));
}

/** Apply the static background paint shared by the single-div mechanisms. */
function paintBackground(el: HTMLElement, src: string): void {
  el.style.backgroundImage = `url("${src}")`;
  el.style.backgroundPosition = 'center';
  el.style.backgroundRepeat = 'no-repeat';
  el.style.display = 'block';
  el.style.width = '100%';
  setAuthoritativeHeight(el, DEFAULT_HEIGHT);
}

/**
 * Set the block's height so it survives the swap. A `<div>` has no intrinsic
 * size (unlike the `<img>` it replaces), so when it lands in a constrained flex
 * container it gets shrunk to its min-content height (0) — which is why a plain
 * `height` was collapsing. `flex-shrink: 0` keeps the block at its own height in
 * any flex context; `align-self: stretch` is left to the container. The height
 * stays a plain inline declaration so the Advanced "banner height" editor can
 * change it and so the source round-trip carries clean CSS (no !important).
 */
function setAuthoritativeHeight(el: HTMLElement, value: string): void {
  el.style.height = value;
  el.style.flexShrink = '0';
  // Last-resort floor for non-flex collapses (e.g. a zero-height ancestor);
  // well below any realistic banner height so it never fights the editor.
  el.style.minHeight = '40px';
}

function buildFixedBlock(meta: ParallaxMeta, strength: number, id: string, scrollSource: ParallaxScrollSource): HTMLDivElement {
  const div = document.createElement('div');
  applyMarkers(div, meta, 'fixed', strength, id, scrollSource);
  paintBackground(div, meta.src);
  div.style.backgroundAttachment = 'fixed';
  // Strength zooms the background (apparent-depth proxy — fixed has no true depth).
  div.style.backgroundSize = `calc((1 + ${STRENGTH_REF} * 0.5) * 100%)`;
  return div;
}

function buildScrollLikeBlock(meta: ParallaxMeta, mechanism: ParallaxMechanism, strength: number, id: string, scrollSource: ParallaxScrollSource): HTMLDivElement {
  // scroll-driven uses a single, cover-painted div whose background-position is
  // animated by the injected stylesheet (CSS-only scan).
  const div = document.createElement('div');
  applyMarkers(div, meta, mechanism, strength, id, scrollSource);
  paintBackground(div, meta.src);
  div.style.backgroundSize = 'cover';
  div.style.overflow = 'hidden';
  return div;
}

/**
 * Background-scan block (default, `js-scroll`) — mirrors a hand-built parallax:
 * a fixed-height clip box (overflow hidden, flex-shrink 0) containing an
 * absolutely-positioned inner background-image layer. The box stays put in
 * layout; the runtime cover-sizes the inner to the viewport and counter-
 * translates it on scroll so the image is pinned to the viewport and the box
 * reveals a fixed slice (the "scan"). The 100%/cover inner is the pre-load /
 * reduced-motion fallback (a plain static cover).
 */
function buildScanBlock(meta: ParallaxMeta, strength: number, id: string, scrollSource: ParallaxScrollSource): HTMLDivElement {
  const outer = document.createElement('div');
  applyMarkers(outer, meta, 'js-scroll', strength, id, scrollSource);
  outer.style.position = 'relative';
  outer.style.overflow = 'hidden';
  outer.style.display = 'block';
  outer.style.width = '100%';
  setAuthoritativeHeight(outer, DEFAULT_HEIGHT);

  const inner = document.createElement('div');
  inner.setAttribute(PARALLAX_INNER, '');
  inner.style.position = 'absolute';
  inner.style.top = '0';
  inner.style.left = '0';
  inner.style.width = '100%';
  inner.style.height = '100%';
  inner.style.backgroundImage = `url("${meta.src}")`;
  inner.style.backgroundSize = 'cover';
  inner.style.backgroundPosition = 'center';
  inner.style.backgroundRepeat = 'no-repeat';
  inner.style.willChange = 'transform';
  outer.appendChild(inner);
  return outer;
}

function buildTransform3dBlock(meta: ParallaxMeta, strength: number, id: string, scrollSource: ParallaxScrollSource): HTMLDivElement {
  // Outer wrapper carries the markers (data-parallax on the OUTERMOST element)
  // and the perspective; the inner element carries the translateZ depth.
  const outer = document.createElement('div');
  applyMarkers(outer, meta, 'transform-3d', strength, id, scrollSource);
  outer.style.setProperty(PERSPECTIVE_VAR, PERSPECTIVE_PX);
  outer.style.perspective = `var(${PERSPECTIVE_VAR})`;
  outer.style.overflow = 'hidden';
  outer.style.position = 'relative';
  outer.style.display = 'block';
  outer.style.width = '100%';
  setAuthoritativeHeight(outer, DEFAULT_HEIGHT);

  const inner = document.createElement('div');
  inner.setAttribute(PARALLAX_INNER, '');
  inner.style.position = 'absolute';
  inner.style.inset = '0';
  inner.style.backgroundImage = `url("${meta.src}")`;
  inner.style.backgroundSize = 'cover';
  inner.style.backgroundPosition = 'center';
  inner.style.backgroundRepeat = 'no-repeat';
  // depth = strength * -300px; compensatory scale keeps the plane filling the frame.
  inner.style.setProperty('--p-depth', `calc(${STRENGTH_REF} * -300px)`);
  inner.style.setProperty('--p-scale', `calc((var(${PERSPECTIVE_VAR}) - var(--p-depth)) / var(${PERSPECTIVE_VAR}))`);
  inner.style.transform = 'translateZ(var(--p-depth)) scale(var(--p-scale))';
  inner.style.transformOrigin = 'center';
  outer.appendChild(inner);
  return outer;
}

function buildBlock(meta: ParallaxMeta, mechanism: ParallaxMechanism, strength: number, id: string, scrollSource: ParallaxScrollSource): HTMLDivElement {
  switch (mechanism) {
    case 'fixed':
      return buildFixedBlock(meta, strength, id, scrollSource);
    case 'transform-3d':
      return buildTransform3dBlock(meta, strength, id, scrollSource);
    case 'scroll-driven':
      return buildScrollLikeBlock(meta, mechanism, strength, id, scrollSource);
    case 'js-scroll':
      return buildScanBlock(meta, strength, id, scrollSource);
  }
}

/**
 * Build a parallax block reproducing `img` for the given mechanism + strength.
 * Stores the original src/alt/id/class in data-* markers so fromParallaxBlock()
 * can revert exactly. `data-parallax` is set on the OUTERMOST element.
 */
export function toParallaxBlock(
  img: HTMLImageElement,
  mechanism: ParallaxMechanism = DEFAULT_MECHANISM,
  strength: number = DEFAULT_STRENGTH,
  scrollSource: ParallaxScrollSource = DEFAULT_SCROLL_SOURCE,
): HTMLDivElement {
  return buildBlock(metaFromImage(img), mechanism, clampStrength(strength), newParallaxId(), scrollSource);
}

/**
 * Rebuild a fresh parallax block from an existing block's stored identity, for a
 * new mechanism / strength / scroll source. A new id is minted so the live
 * runtime treats it as a distinct artifact (old block's artifacts are torn down
 * on replace).
 */
export function rebuildParallaxBlock(
  block: HTMLElement,
  mechanism: ParallaxMechanism,
  strength: number,
  scrollSource: ParallaxScrollSource = DEFAULT_SCROLL_SOURCE,
): HTMLDivElement {
  const newEl = buildBlock(metaFromBlock(block), mechanism, clampStrength(strength), newParallaxId(), scrollSource);
  // Preserve operator-customized banner height across a mechanism / strength
  // switch — otherwise the rebuild silently resets the banner to DEFAULT_HEIGHT.
  const customHeight = block.style.height;
  if (customHeight) newEl.style.height = customHeight;
  return newEl;
}

/** Reconstruct the original `<img>` from a parallax block's data-* markers. */
export function fromParallaxBlock(block: HTMLElement): HTMLImageElement {
  const meta = metaFromBlock(block);
  const img = document.createElement('img');
  if (meta.src) img.setAttribute('src', meta.src);
  if (meta.alt) img.setAttribute('alt', meta.alt);
  if (meta.id) img.id = meta.id;
  if (meta.className) img.className = meta.className;
  // Restore the source mapping so a reverted <img> remains editable in place.
  for (const [attr, value] of Object.entries(meta.source)) img.setAttribute(attr, value);
  return img;
}

// ---------------------------------------------------------------------------
// Diff payload builders (StylesheetChange / ScriptBehaviorChange)
// ---------------------------------------------------------------------------

/**
 * The scan keyframe pans the background WITHIN the fixed box (the box stays put
 * in layout; the image scans vertically, revealing different parts). Strength
 * widens the pan range around centre: `50% ± strength·50%`. At strength 1 it's a
 * full 0%→100% scan; at 0.3 a subtle 35%→65%.
 */
function keyframesRule(name: string): StylesheetRule {
  const from = `calc((0.5 - ${STRENGTH_REF} * 0.5) * 100%)`;
  const to = `calc((0.5 + ${STRENGTH_REF} * 0.5) * 100%)`;
  const cssText =
    `@keyframes ${name} {\n` +
    `  from { background-position-y: ${from}; }\n` +
    `  to { background-position-y: ${to}; }\n` +
    `}`;
  return { ruleType: 'keyframes', name, cssText };
}

function reducedMotionRule(mechanism: ParallaxMechanism, selector: string): StylesheetRule {
  let body: string;
  switch (mechanism) {
    case 'fixed':
      body = `  ${selector} { background-attachment: scroll; }`;
      break;
    case 'transform-3d':
      body = `  ${selector} > * { transform: none; }`;
      break;
    case 'js-scroll':
      // Defensive: js-scroll never reaches here (buildStylesheetChanges returns
      // early — it handles reduced-motion via the runtime matchMedia short-
      // circuit, not a StylesheetChange). Zero the inner transform if it ever does.
      body = `  ${selector} > * { transform: none; }`;
      break;
    case 'scroll-driven':
    default:
      body = `  ${selector} { animation: none; }`;
      break;
  }
  return {
    ruleType: 'media',
    condition: '(prefers-reduced-motion: reduce)',
    cssText: `@media (prefers-reduced-motion: reduce) {\n${body}\n}`,
  };
}

/**
 * The CSS `animation-timeline` for a scroll source. For nested/auto we use
 * `view()` — the scan progresses as the box passes through its nearest
 * scrollport (the overlay), which is the natural "scan" feel. For an explicit
 * page source we use `scroll(root)` so it tracks page scroll.
 */
function scrollTimelineValue(source: ParallaxScrollSource): string {
  return source === 'page' ? 'scroll(root)' : 'view()';
}

/**
 * The element-level animation longhands wired by scroll-driven (also live).
 * `animation-timeline` reflects the scroll source — `scroll(root)` for the page,
 * `scroll()` (nearest scroll container) for an inner overlay/`<main>`.
 */
function scrollAnimationLonghands(keyframesName: string, timelineValue: string): ReadonlyArray<{ property: string; value: string }> {
  return [
    { property: 'animation-name', value: keyframesName },
    { property: 'animation-timeline', value: timelineValue },
    { property: 'animation-duration', value: 'auto' },
    { property: 'animation-fill-mode', value: 'both' },
    { property: 'animation-timing-function', value: 'linear' },
  ];
}

function scrollDrivenElementChanges(keyframesName: string, timelineValue: string): PropertyChange[] {
  return scrollAnimationLonghands(keyframesName, timelineValue).map((d) => ({
    property: d.property,
    fromValue: 'none',
    toValue: d.value,
  }));
}

/**
 * Assemble the StylesheetChange[] for a mechanism. Every CSS mechanism carries a
 * reduced-motion zeroing rule; scroll-driven additionally carries the keyframes
 * + positive/negative `@supports` wiring. js-scroll carries none (handled by the
 * script handler's matchMedia short-circuit).
 */
export function buildStylesheetChanges(
  mechanism: ParallaxMechanism,
  strength: number,
  selector: string,
  id: string,
  scrollSource: ParallaxScrollSource = DEFAULT_SCROLL_SOURCE,
): StylesheetChange[] {
  if (mechanism === 'js-scroll') return [];

  const changes: StylesheetChange[] = [];

  if (mechanism === 'scroll-driven') {
    const name = keyframesNameFor(id);
    const timelineValue = scrollTimelineValue(scrollSource);
    const wiring = scrollAnimationLonghands(name, timelineValue)
      .map((d) => `    ${d.property}: ${d.value};`)
      .join('\n');
    const rules: StylesheetRule[] = [
      keyframesRule(name),
      {
        ruleType: 'supports',
        condition: '(animation-timeline: view())',
        cssText:
          `@supports (animation-timeline: view()) {\n` +
          `  ${selector} {\n${wiring}\n  }\n` +
          `}`,
      },
      {
        ruleType: 'supports',
        condition: 'not (animation-timeline: view())',
        cssText:
          `@supports not (animation-timeline: view()) {\n` +
          `  /* No scroll-driven support — degrade to a static centred background. */\n` +
          `  ${selector} { background-position-y: center; }\n` +
          `}`,
      },
    ];
    changes.push({
      type: 'stylesheet',
      rules,
      elementChanges: scrollDrivenElementChanges(name, timelineValue),
      reason: 'scroll-driven-parallax',
    });
  }

  // Mandatory prefers-reduced-motion zeroing (WCAG 2.3.3) for every CSS mechanism.
  changes.push({
    type: 'stylesheet',
    rules: [reducedMotionRule(mechanism, selector)],
    elementChanges: [],
    reason: 'reduced-motion-zeroing',
  });

  return changes;
}

/**
 * The defining inline declarations of the `fixed` mechanism, surfaced as
 * structured `PropertyChange[]` (feature-009 AC §2) so the source author has the
 * per-property intent, not only the `outerHTML` blob. The new block is delivered
 * via the replace `outerHTML` (authoritative markup); these mirror it.
 */
export function fixedPropertyChanges(): PropertyChange[] {
  return [
    { property: 'background-attachment', fromValue: '', toValue: 'fixed' },
    { property: 'background-size', fromValue: '', toValue: `calc((1 + ${STRENGTH_REF} * 0.5) * 100%)` },
    { property: 'background-position', fromValue: '', toValue: 'center' },
    { property: 'height', fromValue: '', toValue: DEFAULT_HEIGHT },
  ];
}

/**
 * Assemble the ScriptBehaviorChange for js-scroll (null for every other mode).
 * `strengthFactor` is a direct 1:1 mapping of the canonical dial value.
 */
export function buildScriptChange(
  mechanism: ParallaxMechanism,
  strength: number,
  selector: string,
  sourceFile: string,
  scrollSource: string,
): ScriptBehaviorChange | null {
  if (mechanism !== 'js-scroll') return null;
  const factor = clampStrength(strength);
  return {
    type: 'script-behavior',
    behavior: 'parallax-scroll',
    targetSelector: selector,
    sourceFile,
    params: { axis: 'y', strengthFactor: factor, throttle: 'raf', scrollSource },
    respectsReducedMotion: true,
    descriptor:
      `Background-scan parallax on ${selector}: a fixed-height clip box (position:relative; ` +
      `overflow:hidden; flex-shrink:0) containing an absolutely-positioned inner layer with the ` +
      `background-image (background-size:cover). In a requestAnimationFrame on scroll, size the ` +
      `inner to COVER THE VIEWPORT (scale = max(vw/naturalW, vh/naturalH); recompute on load+resize ` +
      `only) and set its transform to translate3d((baseX - boxRect.left)*${factor}, ` +
      `(baseY - boxRect.top)*${factor}, 0) where baseX=(vw-coverW)/2, baseY=(vh-coverH)/2 — pinning ` +
      `the image to the viewport so the box reveals a fixed slice (strengthFactor 1 = fully pinned). ` +
      `Attach the scroll listener in the CAPTURE phase on window so nested scroll containers ` +
      `(an inner overlay/<main>, see params.scrollSource) are caught. Disable under ` +
      `prefers-reduced-motion (leave the inner as a static CSS cover).`,
    reason: 'js-scroll-parallax',
  };
}

// ---------------------------------------------------------------------------
// Live runtime — manages the injected stylesheet / scroll-listener artifacts
// that scroll-driven and js-scroll need to render live in the editor.
// ---------------------------------------------------------------------------

const STYLE_FOR_ATTR = 'data-parallax-style-for';
const REDUCED_MOTION_QUERY = '(prefers-reduced-motion: reduce)';

interface RuntimeArtifact {
  styleEl?: HTMLStyleElement;
  /** Removes any scroll listener (from window or the resolved container). */
  cleanup?: () => void;
}

/**
 * Owns the per-block live effects that inline styles cannot express. Keyed by
 * `data-parallax-id`. `sync()` reconciles artifacts against the current DOM —
 * call it after any history change (undo/redo/reset) so artifacts for removed
 * blocks are torn down and restored blocks get their effect back. This keeps
 * history.ts generic (no parallax knowledge).
 */
export class ParallaxRuntime {
  private artifacts = new Map<string, RuntimeArtifact>();

  private prefersReducedMotion(): boolean {
    try {
      return window.matchMedia(REDUCED_MOTION_QUERY).matches;
    } catch {
      return false;
    }
  }

  /** (Re)build the live artifact for a block. Idempotent — tears down first. */
  applyLive(block: HTMLElement): void {
    const id = getParallaxId(block);
    if (!id) return;
    this.teardown(id);
    const mechanism = readParallaxMechanism(block);
    if (mechanism === 'scroll-driven') {
      this.applyScrollDriven(block, id);
    } else if (mechanism === 'js-scroll') {
      this.applyJsScroll(block, id);
    }
    // fixed / transform-3d need no runtime artifact (inline styles suffice).
  }

  private applyScrollDriven(block: HTMLElement, id: string): void {
    const strength = readParallaxStrength(block);
    const name = keyframesNameFor(id);
    const sel = `[${PARALLAX_ID}="${id}"]`;
    const timelineValue = scrollTimelineValue(readScrollSource(block));
    const styleEl = document.createElement('style');
    styleEl.setAttribute(STYLE_FOR_ATTR, id);
    const wiring = scrollAnimationLonghands(name, timelineValue)
      .map((d) => `  ${d.property}: ${d.value};`)
      .join('\n');
    const reduced = this.prefersReducedMotion()
      ? `\n@media ${REDUCED_MOTION_QUERY} { ${sel} { animation: none; } }`
      : '';
    const fromPos = `calc((0.5 - ${STRENGTH_REF} * 0.5) * 100%)`;
    const toPos = `calc((0.5 + ${STRENGTH_REF} * 0.5) * 100%)`;
    styleEl.textContent =
      `@keyframes ${name} { from { background-position-y: ${fromPos}; } ` +
      `to { background-position-y: ${toPos}; } }\n` +
      `@supports (animation-timeline: view()) {\n${sel} {\n${wiring}\n}\n}` +
      reduced;
    (document.head ?? document.documentElement).appendChild(styleEl);
    block.style.setProperty(STRENGTH_VAR, String(strength));
    this.artifacts.set(id, { styleEl });
  }

  private applyJsScroll(block: HTMLElement, id: string): void {
    // Background-scan: pin the inner image layer to the viewport so the box
    // reveals a fixed slice (mirrors the hand-built reference). Operates on the
    // inner `[data-parallax-inner]`, NOT the box (the box stays put in layout).
    const inner = block.querySelector<HTMLElement>(`[${PARALLAX_INNER}]`);
    if (!inner) { this.artifacts.set(id, {}); return; }

    if (this.prefersReducedMotion()) {
      // Honor reduced motion: static cover, no listener.
      inner.style.transform = '';
      inner.style.width = '100%';
      inner.style.height = '100%';
      this.artifacts.set(id, {});
      return;
    }

    const factor = readParallaxStrength(block);
    const src = block.getAttribute(PARALLAX_SRC) || '';
    let nat: { w: number; h: number } | null = null;
    let baseX = 0;
    let baseY = 0;
    let raf = 0;

    // Cover the VIEWPORT (recomputed on load/resize only), centred.
    const size = () => {
      if (!nat) return;
      const vw = window.innerWidth;
      const vh = window.innerHeight;
      const scale = Math.max(vw / nat.w, vh / nat.h);
      const bw = nat.w * scale;
      const bh = nat.h * scale;
      baseX = (vw - bw) / 2;
      baseY = (vh - bh) / 2;
      inner.style.width = `${bw}px`;
      inner.style.height = `${bh}px`;
    };
    // Per-frame: place the inner so the box reveals the viewport-fixed slice.
    // `factor` (strength) scales the pin: 1 = fully viewport-fixed, 0 = scrolls
    // with the box.
    const position = () => {
      raf = 0;
      if (!block.isConnected) { this.teardown(id); return; }
      const rect = block.getBoundingClientRect();
      inner.style.transform =
        `translate3d(${((baseX - rect.left) * factor).toFixed(1)}px, ${((baseY - rect.top) * factor).toFixed(1)}px, 0)`;
    };
    const onScroll = () => { if (!raf) raf = requestAnimationFrame(position); };
    const onResize = () => { size(); position(); };

    // `window.Image` — next/image and other shims can shadow the bare `Image`.
    const img = new window.Image();
    img.onload = () => { nat = { w: img.naturalWidth, h: img.naturalHeight }; size(); position(); };
    img.src = src;

    // Capture-phase window scroll catches inner scrollers (overlays/<main>) too,
    // so this works regardless of which container actually scrolls.
    window.addEventListener('scroll', onScroll, true);
    window.addEventListener('resize', onResize);
    this.artifacts.set(id, {
      cleanup: () => {
        window.removeEventListener('scroll', onScroll, true);
        window.removeEventListener('resize', onResize);
        if (raf) cancelAnimationFrame(raf);
      },
    });
  }

  /** Remove the live artifact (style element / listener) for a block id. */
  teardown(id: string): void {
    const art = this.artifacts.get(id);
    if (!art) {
      // Defensive: remove any orphaned style element for this id.
      document.head.querySelector(`style[${STYLE_FOR_ATTR}="${id}"]`)?.remove();
      return;
    }
    art.styleEl?.remove();
    art.cleanup?.();
    this.artifacts.delete(id);
  }

  /**
   * Reconcile artifacts against the live DOM: tear down artifacts whose block is
   * gone, and (re)apply the effect for every parallax block currently present.
   */
  sync(): void {
    const present = new Set<string>();
    document.querySelectorAll<HTMLElement>(`[${PARALLAX_MARKER}][${PARALLAX_ID}]`).forEach((block) => {
      const id = getParallaxId(block);
      if (id) present.add(id);
    });
    for (const id of Array.from(this.artifacts.keys())) {
      if (!present.has(id)) this.teardown(id);
    }
    document.querySelectorAll<HTMLElement>(`[${PARALLAX_MARKER}][${PARALLAX_ID}]`).forEach((block) => {
      this.applyLive(block);
    });
  }

  /** Tear down every artifact (editor deactivation). */
  destroy(): void {
    for (const id of Array.from(this.artifacts.keys())) this.teardown(id);
    document.head.querySelectorAll(`style[${STYLE_FOR_ATTR}]`).forEach((el) => el.remove());
    this.artifacts.clear();
  }
}
