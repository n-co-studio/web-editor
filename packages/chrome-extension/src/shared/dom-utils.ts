import type {
  BoundingRect,
  ElementInfo,
  NoteElementRef,
  PendingUpload,
  SiblingAnchor,
} from '@nco-studio/shared';
import { TEXT_CONTENT_TRUNCATE_LENGTH } from './constants';

// ---------------------------------------------------------------------------
// Stable element identity (data-fe-uid) — issue #27
// ---------------------------------------------------------------------------

/** DOM attribute carrying the stable, per-instance element identity. */
export const FE_UID_ATTR = 'data-fe-uid';

/**
 * Reconciliation-resilience sidecar (data-contracts § Stamping lifecycle 4):
 * React can replace a DOM node while preserving logical identity and may drop a
 * runtime-set attribute. The attribute remains the wire-format source of truth;
 * this WeakMap lets `ensureUid` recover a previously-minted uid and re-stamp the
 * node rather than mint a colliding new one.
 */
const uidSidecar = new WeakMap<Element, string>();

/** Mint a fresh, opaque per-instance uid. */
function mintUid(): string {
  const rnd =
    typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function'
      ? crypto.randomUUID()
      : `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
  return `fe-${rnd}`;
}

/**
 * Return the element's stable uid, assigning a fresh one if it has none.
 *
 * Build-time stamping (feature-006) is the primary source and survives React
 * reconciliation; this lazy runtime path covers `.map()` runtime instances,
 * `sourceVerified: false` nodes, and elements rendered before the content
 * script observed them (data-contracts § Stamping lifecycle 3). Idempotent —
 * an element already carrying `data-fe-uid` keeps it.
 */
export function ensureUid(el: Element): string {
  const existing = el.getAttribute(FE_UID_ATTR);
  if (existing) {
    uidSidecar.set(el, existing);
    return existing;
  }
  // Attribute absent — recover from the sidecar (reconciliation drop) or mint.
  const uid = uidSidecar.get(el) ?? mintUid();
  el.setAttribute(FE_UID_ATTR, uid);
  uidSidecar.set(el, uid);
  return uid;
}

/** Read the element's uid without minting (attribute, then sidecar). Undefined when none. */
export function readUid(el: Element): string | undefined {
  return el.getAttribute(FE_UID_ATTR) ?? uidSidecar.get(el) ?? undefined;
}

/**
 * One-shot synchronous sweep guaranteeing per-instance uid uniqueness across the
 * document before any element is exposed for selection (data-contracts § Stamping
 * lifecycle 3, normative "MUST"). Build-time stamping gives `.map()` runtime
 * instances a *shared* uid (one JSX node → N rendered nodes); this walk keeps the
 * first occurrence of each uid and re-stamps every subsequent duplicate with a
 * fresh one, so a captured diff can never reference a non-unique uid (issue #27).
 *
 * Bounded and single-pass — not a persistent MutationObserver (per the
 * Pragmatist's minimal-fix guidance). It runs at selection-mode activation, so
 * the page's initial `.map()` lists are disambiguated before the operator can
 * select; nodes rendered later are covered by the clone fresh-stamp and lazy
 * `ensureUid` paths. Returns the number of duplicates re-stamped.
 */
export function disambiguateUids(root: ParentNode = document): number {
  const seen = new Set<string>();
  let restamped = 0;
  for (const el of Array.from(root.querySelectorAll(`[${FE_UID_ATTR}]`))) {
    const uid = el.getAttribute(FE_UID_ATTR);
    if (uid == null) continue;
    if (seen.has(uid)) {
      stampFreshUid(el);
      restamped++;
    } else {
      seen.add(uid);
      uidSidecar.set(el, uid);
    }
  }
  return restamped;
}

/**
 * Force a *fresh* uid onto an element, replacing any existing one. Used by the
 * clone/paste path (data-contracts § Stamping lifecycle 2): a clone must never
 * reuse the origin's uid, or the issue-#27 collision returns. Updates the
 * sidecar so `readUid` stays consistent.
 */
export function stampFreshUid(el: Element): string {
  const uid = mintUid();
  el.setAttribute(FE_UID_ATTR, uid);
  uidSidecar.set(el, uid);
  return uid;
}

// ---------------------------------------------------------------------------
// Selector generation
// ---------------------------------------------------------------------------

/**
 * Build a reasonably unique CSS selector for an element.
 * Priority: [data-fe-uid] → #id → [data-source-*] → .classes:nth-of-type →
 * tag:nth-child path. The `data-fe-uid` preference is the single chokepoint that
 * makes every selector-based change type (ElementInfo.selector,
 * SiblingAnchor.selector, ChildSnapshotEntry.selector, ReorderChange /
 * ReparentChange siblingSelectors) target by stable per-instance identity
 * (issue #27). Traverses at most 5 levels to keep selectors readable.
 */
export function generateSelector(el: Element): string {
  // Prefer the stable per-instance identity when present.
  const uid = el.getAttribute(FE_UID_ATTR);
  if (uid) return `[${FE_UID_ATTR}="${CSS.escape(uid)}"]`;

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

/** Read data-source-* attributes injected by @nco-studio/web-editor-plugin. */
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
// Deployment-aware src/href normalization (issue #27, weakness 2)
// ---------------------------------------------------------------------------

/**
 * Normalize a captured `src`/`href`/background-url value so the path written to
 * source is correct on apply. Observed failure: a captured `/public/images/x.jpg`
 * where the served path is `/images/x.jpg` (Next.js / Vite serve `public/` at
 * the web root). See data-contracts § Deployment-aware src normalization.
 *
 * Rules:
 *  - `data:` URIs are left untouched (inline data has no deployment base).
 *  - absolute `http(s)://` (any scheme `://`) and protocol-relative `//` URLs are
 *    left untouched (already fully qualified).
 *  - otherwise strip **at most one** leading `/public` segment from root-relative
 *    paths; all other paths pass through unchanged.
 *
 * Convention-gated: stripping happens only when `base` (the element's resolved
 * `data-source-file`, i.e. a known project context) is non-empty. Without a
 * project context the value degrades to the literal captured path — this keeps
 * the rule scoped to the Next.js/Vite convention it targets and avoids
 * over-stripping elsewhere.
 *
 * @param rawSrc the captured attribute value
 * @param base   the element's resolved data-source-file (project context gate)
 */
export function resolvePublicSrc(rawSrc: string, base: string): string {
  if (!rawSrc) return rawSrc;
  const trimmed = rawSrc.trim();

  // Inline data, fully-qualified, and protocol-relative URLs are never rewritten.
  if (/^data:/i.test(trimmed)) return rawSrc;
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed)) return rawSrc;
  if (trimmed.startsWith('//')) return rawSrc;

  // Convention-gated: only normalize within a known project source context.
  if (!base) return rawSrc;

  if (trimmed === '/public') return '/';
  if (trimmed.startsWith('/public/')) return trimmed.slice('/public'.length);

  return rawSrc;
}

/**
 * The base64-free result of picking a local asset for an element (issue #28).
 * `previewUrl` is a blob URL for live in-DOM preview (never serialized into a
 * diff — blob URLs are not resolvable outside the page). `provisionalSrc` is
 * the served path written to the diff's `toValue`; the bridge confirms/persists
 * it server-side. `pendingUpload` is the metadata side-channel the bridge uses
 * to name/dedup the persisted asset without ever transmitting the raw bytes.
 */
export interface ResolvedAsset {
  readonly previewUrl: string;
  readonly provisionalSrc: string;
  readonly pendingUpload: PendingUpload;
}

/** Default served asset directory — mirrors the bridge's `public/images` fallback. */
const PROVISIONAL_ASSET_DIR = '/images';

/**
 * Reduce a picked file's name to a safe, path-free asset filename. Strips any
 * directory component and characters that have no business in a served path,
 * so the provisional `/images/<name>` (and the server-side dedup key) is stable.
 * Falls back to a generic name when nothing usable remains.
 */
export function sanitizeAssetName(rawName: string): string {
  const base = rawName.split(/[\\/]/).pop() ?? '';
  const cleaned = base.trim().replace(/[^A-Za-z0-9._-]/g, '-').replace(/-+/g, '-');
  return cleaned.replace(/^[-.]+/, '') || 'asset';
}

/**
 * Turn a locally-picked `File` into a base64-free {@link ResolvedAsset} (issue
 * #28). The blob URL drives live preview in the page; the provisional served
 * path (`/images/<filename>`) and `pendingUpload` metadata are what enter the
 * diff — the file's bytes are never read into a `data:` URI. The bridge later
 * persists/dedups the asset from `pendingUpload.filename` and finalizes the
 * served path. This is the single capture-layer chokepoint that guarantees no
 * base64 leaves the extension via the media picker.
 */
export function resolveElementAsset(file: File): ResolvedAsset {
  const filename = sanitizeAssetName(file.name);
  return {
    previewUrl: URL.createObjectURL(file),
    provisionalSrc: `${PROVISIONAL_ASSET_DIR}/${filename}`,
    pendingUpload: {
      filename,
      mimeType: file.type,
      sizeBytes: file.size,
    },
  };
}

// ---------------------------------------------------------------------------
// Element → resolved asset reference (issue #29)
// ---------------------------------------------------------------------------

/** Max length for a derived asset label — keep pills / prompt lines readable. */
const ASSET_LABEL_MAX_LENGTH = 40;

/**
 * Extract the element's own asset URL: the `src` attribute first (img / video /
 * source / iframe …), then an inline `background-image` `url(...)`. Reads only
 * cheap DOM attributes / inline style — no `getComputedStyle` — so it stays on
 * the hot `buildElementInfo` path without forcing style recalc. Class-driven
 * (computed-only) backgrounds are intentionally out of scope: they are usually
 * decorative, not the asset the operator is referencing.
 */
function extractAssetUrl(el: Element): string | undefined {
  const src = el.getAttribute('src');
  if (src && src.trim()) return src.trim();

  // `?.` guards elements without an inline style object (e.g. non-HTMLElement
  // nodes, or lightweight test doubles) — never force a getComputedStyle here.
  const inlineBg = el instanceof HTMLElement ? el.style?.backgroundImage : '';
  if (inlineBg && inlineBg !== 'none') {
    const match = inlineBg.match(/url\((['"]?)(.*?)\1\)/);
    if (match && match[2]) return match[2].trim();
  }
  return undefined;
}

/** Filename stem of a served path — `/images/hero.jpg` → `hero`. */
function assetFilenameStem(assetPath: string): string {
  const file = assetPath.split(/[?#]/)[0].split('/').pop() ?? '';
  const dot = file.lastIndexOf('.');
  return dot > 0 ? file.slice(0, dot) : file;
}

/**
 * Derive a short human label for a resolved asset (issue #29).
 * Priority: filename stem > `alt` > trimmed textContent (≤40) > tagName.
 * Always returns a value — tagName is the guaranteed fallback — so a resolved
 * asset never carries `assetPath` without a `label`.
 */
function deriveAssetLabel(el: Element, assetPath: string): string {
  const stem = assetFilenameStem(assetPath);
  if (stem) return stem.slice(0, ASSET_LABEL_MAX_LENGTH);
  const alt = el.getAttribute('alt')?.trim();
  if (alt) return alt.slice(0, ASSET_LABEL_MAX_LENGTH);
  const text = el.textContent?.trim().slice(0, ASSET_LABEL_MAX_LENGTH);
  if (text) return text;
  return el.tagName.toLowerCase();
}

/**
 * Resolve a live element's own asset reference to a served path + label (issue
 * #29). `assetPath` is the element's `src` / inline `background-image`,
 * normalized through {@link resolvePublicSrc} (single leading `/public` strip,
 * gated on a source-file context). Returns `{}` — **both fields absent** — when
 * no asset resolves, or when the resolved value is a `data:` / `blob:` URI
 * (inline bytes / page-local blobs are never a served path; Brief 1 / #28
 * guarantees the served form). Spread onto every element-reference shape so the
 * pair is present only when it is meaningful, never as a dead field on a
 * non-image carrier.
 *
 * Named `resolveElementAssetRef` to sit alongside — not shadow —
 * {@link resolveElementAsset}, which resolves a *picked `File`* into a
 * provisional served asset for the media picker.
 */
export function resolveElementAssetRef(el: Element): { assetPath?: string; label?: string } {
  const rawUrl = extractAssetUrl(el);
  if (!rawUrl) return {};

  const base = readSourceAttributes(el)?.file ?? '';
  const resolved = resolvePublicSrc(rawUrl, base).trim();

  // Never carry inline bytes or a page-local blob as a served asset path.
  if (!resolved || /^(?:data|blob):/i.test(resolved)) return {};

  return { assetPath: resolved, label: deriveAssetLabel(el, resolved) };
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

  // Mint/repair the stable per-instance uid first so the (uid-preferring)
  // selector and the attributes map below both reflect the assigned
  // data-fe-uid, keeping `uid`, `selector`, and `attributes['data-fe-uid']`
  // consistent (issue #27).
  const uid = ensureUid(el);

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
    uid,
    selector: generateSelector(el),
    tagName: el.tagName.toLowerCase(),
    textContent: text || undefined,
    sourceFile: source?.file ?? '',
    sourceLine: source?.line ?? 0,
    instanceIndex: source?.index,
    attributes: attrs,
    boundingRect: serializeBoundingRect(rect),
    // assetPath/label added only when the element resolves to a served asset
    // (issue #29) — spread of `{}` for non-image carriers adds nothing.
    ...resolveElementAssetRef(el),
  };
}

/**
 * Build a {@link NoteElementRef} for a live element, carrying the resolved
 * asset reference (issue #29) so a note over a gallery image is actionable from
 * the payload alone. Single construction chokepoint for the note-pick / anchor
 * sites in index.ts.
 */
export function buildNoteElementRef(el: Element): NoteElementRef {
  const info = buildElementInfo(el);
  const ref: NoteElementRef = {
    selector: info.selector,
    tagName: info.tagName,
    textContent: info.textContent,
    sourceFile: info.sourceFile,
    sourceLine: info.sourceLine,
    instanceIndex: info.instanceIndex,
  };
  return info.assetPath
    ? { ...ref, assetPath: info.assetPath, label: info.label }
    : ref;
}

/**
 * Build a {@link SiblingAnchor} for a live element, carrying `uid` + the
 * resolved asset reference (issue #29). Used for `ReorderChange.siblingAnchors`
 * so a gallery reorder renders `N → /images/<file>` per sibling.
 */
export function buildSiblingAnchor(el: Element): SiblingAnchor {
  const info = buildElementInfo(el);
  const anchor: SiblingAnchor = {
    uid: info.uid,
    selector: info.selector,
    sourceFile: info.sourceFile,
    sourceLine: info.sourceLine,
  };
  const withIndex =
    info.instanceIndex != null ? { ...anchor, instanceIndex: info.instanceIndex } : anchor;
  return info.assetPath
    ? { ...withIndex, assetPath: info.assetPath, label: info.label }
    : withIndex;
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
  rowGap: string;
  columnGap: string;
  padding: string;
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
    rowGap: cs.getPropertyValue('row-gap').trim(),
    columnGap: cs.getPropertyValue('column-gap').trim(),
    padding: cs.getPropertyValue('padding').trim(),
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
// HTML/SVG sanitization
// ---------------------------------------------------------------------------
//
// Markup entering the live page DOM from an untrusted source — a copied page
// element's outerHTML (clipboard paste), or a project-component icon delivered
// over the WebSocket bridge — must be scrubbed of script-execution vectors
// before insertion. Shadow DOM does not contain script execution, so an
// `<img onerror>` or `javascript:` URL would run in the host page's context.

/** Elements that can execute script or load external content — removed outright. */
// `animate` and `set` are here because SVG lets them rewrite another element's
// attribute at runtime — `<animate attributeName="href" values="javascript:…">`
// reintroduces a scripted URL after this function has already inspected the
// href it was given.
const DANGEROUS_ELEMENTS = 'script,iframe,object,embed,link,meta,base,animate,set,animateTransform';

/** Attributes carrying a URL that could hold a `javascript:` payload. */
const URL_ATTRS = new Set(['href', 'src', 'xlink:href', 'formaction', 'action']);

/**
 * True when a URL resolves to the `javascript:` scheme once the characters a
 * browser ignores are removed.
 *
 * A plain `/^\s*javascript:/` test is bypassable: browsers strip tabs, newlines
 * and C0 control characters from *inside* a scheme before resolving it, so
 * `java&#9;script:x` and `\u0001javascript:x` both execute while failing that
 * test. Normalize the same way the browser does, then compare.
 */
export function isScriptUrl(value: string): boolean {
  // eslint-disable-next-line no-control-regex
  const normalized = value.replace(/[\u0000-  ﻿]/g, '').toLowerCase();
  return normalized.startsWith('javascript:') || normalized.startsWith('data:text/html');
}

/**
 * Scrub a parsed fragment/subtree in place: drop dangerous elements, strip every
 * inline event handler (`on*`), and neutralize `javascript:` URLs. Operates on an
 * already-parsed tree (typically the inert content of a `<template>`), never on a
 * live-document node, so no handler fires during scrubbing.
 */
export function sanitizeFragment(root: ParentNode): void {
  root.querySelectorAll(DANGEROUS_ELEMENTS).forEach((el) => el.remove());
  root.querySelectorAll('*').forEach((el) => {
    for (const attr of Array.from(el.attributes)) {
      const name = attr.name.toLowerCase();
      if (name.startsWith('on')) {
        el.removeAttribute(attr.name);
      } else if (URL_ATTRS.has(name) && isScriptUrl(attr.value)) {
        el.removeAttribute(attr.name);
      }
    }
    // A nested <template> keeps its children in a separate .content fragment
    // that querySelectorAll does not descend into, so a payload parked there
    // survived scrubbing and became live the moment anything cloned it.
    if (el instanceof HTMLTemplateElement) {
      sanitizeFragment(el.content);
    }
  });
}

/**
 * Parse an untrusted HTML/SVG string into a sanitized, inert DocumentFragment
 * suitable for insertion via `replaceChildren`/`appendChild`. Parsing happens in
 * a detached `<template>`, whose content is inert (no resource loads, no script
 * execution) until the sanitized nodes are attached to the live document.
 */
export function sanitizeToFragment(markup: string): DocumentFragment {
  const template = document.createElement('template');
  template.innerHTML = markup;
  sanitizeFragment(template.content);
  return template.content;
}
