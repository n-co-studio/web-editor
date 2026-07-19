import type { TokenCategory } from '@nco-studio/shared';
import type { InferredOption, InferredOrigin } from './page-value-store';

/**
 * Page-value harvester (feature-011). Scans the live DOM + CSSOM for the CSS
 * values already in use on the page and returns the most common ones, bucketed
 * under the existing `TokenCategory` union, so the editor can offer an "On this
 * page" shortlist when a project has no discoverable design tokens.
 *
 * Three passes, run in order on idle (guarded by the caller's empty-token-store
 * predicate):
 *   1. `:root` custom-property pre-pass (highest confidence, floor-exempt).
 *   2. Bounded, chunked `getComputedStyle` over visible elements (~500 cap).
 *   3. CSSOM declared-value pass (per-sheet cross-origin `SecurityError` caught).
 *
 * The union is normalized, deduped, frequency-floored, and top-N capped before
 * being returned. The whole thing is wrapped so it never throws uncaught: a
 * total failure resolves to an empty, non-partial result and the editor falls
 * through to the feature-003 freeform floor.
 */

// ---------------------------------------------------------------------------
// Harvest configuration
// ---------------------------------------------------------------------------

const ELEMENT_CAP = 500;
const ELEMENT_CHUNK = 50;
const CSSOM_RULE_CEILING = 8_000;
const FREQUENCY_FLOOR = 2;

const COLOR_PROPS = [
  'color',
  'background-color',
  'border-top-color',
  'border-right-color',
  'border-bottom-color',
  'border-left-color',
  'outline-color',
  'fill',
  'stroke',
];
const SPACING_PROPS = [
  'margin-top',
  'margin-right',
  'margin-bottom',
  'margin-left',
  'padding-top',
  'padding-right',
  'padding-bottom',
  'padding-left',
  'gap',
  'row-gap',
  'column-gap',
];
const RADII_CORNERS = [
  'border-top-left-radius',
  'border-top-right-radius',
  'border-bottom-right-radius',
  'border-bottom-left-radius',
];

/**
 * A harvest bucket. `readProps` are the computed longhands sampled; `offerProps`
 * are the CSS properties the resulting option is offered for (mirrors
 * `DesignToken.cssProperties`). `cap` is the per-category top-N kept after
 * ranking. `key` is finer-grained than `category` so the four typography
 * properties get independent caps.
 */
interface Bucket {
  readonly key: string;
  readonly category: TokenCategory;
  readonly readProps: readonly string[];
  readonly offerProps: readonly string[];
  readonly cap: number;
  readonly normalize: (raw: string) => string | null;
}

const BUCKETS: Bucket[] = [
  { key: 'colors', category: 'colors', readProps: COLOR_PROPS, offerProps: COLOR_PROPS, cap: 12, normalize: normalizeColor },
  { key: 'font-size', category: 'typography', readProps: ['font-size'], offerProps: ['font-size'], cap: 8, normalize: normalizeLength },
  { key: 'font-family', category: 'typography', readProps: ['font-family'], offerProps: ['font-family'], cap: 6, normalize: normalizeFontFamily },
  { key: 'font-weight', category: 'typography', readProps: ['font-weight'], offerProps: ['font-weight'], cap: 6, normalize: normalizeFontWeight },
  { key: 'line-height', category: 'typography', readProps: ['line-height'], offerProps: ['line-height'], cap: 6, normalize: normalizeLineHeight },
  { key: 'spacing', category: 'spacing', readProps: SPACING_PROPS, offerProps: SPACING_PROPS, cap: 10, normalize: normalizeLength },
  { key: 'radii', category: 'radii', readProps: RADII_CORNERS, offerProps: ['border-radius', ...RADII_CORNERS], cap: 6, normalize: normalizeLength },
  { key: 'shadows', category: 'shadows', readProps: ['box-shadow'], offerProps: ['box-shadow'], cap: 6, normalize: normalizeShadow },
];

/** Map every read longhand → its owning bucket (computed-pass dispatch). */
const PROP_TO_BUCKET = new Map<string, Bucket>();
for (const bucket of BUCKETS) {
  for (const prop of bucket.readProps) PROP_TO_BUCKET.set(prop, bucket);
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

export interface HarvestOptions {
  /** An element (e.g. the extension's shadow host) to skip during the DOM walk. */
  readonly excludeRoot?: Element;
  /**
   * Cooperative abort — polled between idle chunks and before each pass. When it
   * returns true (e.g. real tokens arrived mid-harvest), the harvest stops and
   * resolves with `aborted: true` so the caller does not load the store.
   */
  readonly isAborted?: () => boolean;
}

export interface HarvestResult {
  /** Ranked, capped page values ready for `PageValueStore.load`. */
  readonly options: InferredOption[];
  /** True when some stylesheets were cross-origin or the element cap was hit — a degraded harvest. */
  readonly partial: boolean;
  /** How many visible elements were dropped by the ~500 cap (0 when under the cap). */
  readonly droppedElements: number;
  /** True when the harvest was cut short by `isAborted` (caller should discard). */
  readonly aborted: boolean;
}

/**
 * Run the full harvest on idle and resolve with the ranked page values. Never
 * throws: any unexpected failure resolves to an empty, non-partial result.
 */
export async function harvestPageValues(opts: HarvestOptions = {}): Promise<HarvestResult> {
  const isAborted = opts.isAborted ?? (() => false);
  const acc = new Map<string, Accum>();
  let partial = false;
  let droppedElements = 0;

  try {
    // Pass 1 — :root custom-property pre-pass (highest confidence).
    if (isAborted()) return abortedResult();
    partial = collectCustomProperties(acc) || partial;

    // Pass 2 — bounded, chunked getComputedStyle over visible elements.
    if (isAborted()) return abortedResult();
    const dom = await collectComputed(acc, opts.excludeRoot, isAborted);
    if (dom.aborted) return abortedResult();
    droppedElements = dom.dropped;
    partial = partial || dom.dropped > 0;

    // Pass 3 — CSSOM declared-value pass.
    if (isAborted()) return abortedResult();
    await idle();
    partial = collectCssom(acc) || partial;

    if (isAborted()) return abortedResult();

    return {
      options: rankAndCap(acc),
      partial,
      droppedElements,
      aborted: false,
    };
  } catch {
    // Total failure → empty store; editor falls through to the freeform floor.
    return { options: [], partial: false, droppedElements: 0, aborted: false };
  }
}

// ---------------------------------------------------------------------------
// Accumulation
// ---------------------------------------------------------------------------

/** Per-(bucket,value) tally accumulated across the three passes. */
interface Accum {
  bucketKey: string;
  value: string;
  frequency: number;
  origin: InferredOrigin;
  label?: string;
}

const ORIGIN_RANK: Record<InferredOrigin, number> = {
  computed: 0,
  cssom: 1,
  'custom-property': 2,
};

function accumKey(bucketKey: string, value: string): string {
  return `${bucketKey} ${value}`;
}

function record(
  acc: Map<string, Accum>,
  bucket: Bucket,
  rawValue: string,
  origin: InferredOrigin,
  label?: string,
): void {
  const value = bucket.normalize(rawValue);
  if (value == null) return;
  const key = accumKey(bucket.key, value);
  const existing = acc.get(key);
  if (existing) {
    existing.frequency += 1;
    // Keep the highest-confidence origin (custom-property > cssom > computed).
    if (ORIGIN_RANK[origin] > ORIGIN_RANK[existing.origin]) {
      existing.origin = origin;
      if (label) existing.label = label;
    }
  } else {
    acc.set(key, { bucketKey: bucket.key, value, frequency: 1, origin, label });
  }
}

// ---------------------------------------------------------------------------
// Pass 1 — :root custom-property pre-pass
// ---------------------------------------------------------------------------

const ROOT_SELECTOR_RE = /(^|,)\s*(:root|html)\b/i;

/** Returns true if any sheet was cross-origin (partial signal). */
function collectCustomProperties(acc: Map<string, Accum>): boolean {
  let partial = false;
  for (const sheet of collectSheets()) {
    let rules: CSSRuleList;
    try {
      rules = sheet.cssRules;
    } catch {
      partial = true;
      continue;
    }
    for (let i = 0; i < rules.length; i++) {
      const rule = rules[i];
      if (rule instanceof CSSStyleRule && ROOT_SELECTOR_RE.test(rule.selectorText)) {
        collectCustomPropsFromStyle(rule.style, acc);
      }
    }
  }
  return partial;
}

function collectCustomPropsFromStyle(style: CSSStyleDeclaration, acc: Map<string, Accum>): void {
  for (let i = 0; i < style.length; i++) {
    const prop = style[i];
    if (!prop.startsWith('--')) continue;
    const raw = style.getPropertyValue(prop).trim();
    if (!raw || raw.includes('var(')) continue;
    const bucket = categorizeCustomProperty(prop, raw);
    if (bucket) record(acc, bucket, raw, 'custom-property', prop);
  }
}

/**
 * Best-effort categorization of a `--custom-property` by value shape, with a
 * property-name hint as a tiebreaker. Declared custom properties are the page
 * author's design values, so the pre-pass is intentionally generous.
 */
function categorizeCustomProperty(name: string, raw: string): Bucket | null {
  const hint = name.toLowerCase();
  const bucketByKey = (key: string): Bucket => BUCKETS.find((b) => b.key === key)!;

  // Value-shape first: a color-valued property is unambiguous.
  if (normalizeColor(raw) != null && !/\d+px|\d+rem|\d+em/.test(raw)) {
    return bucketByKey('colors');
  }
  // A multi-part value ending in a color is a shadow.
  if (normalizeShadow(raw) != null && /\s/.test(raw) && normalizeColor(raw) == null) {
    if (hint.includes('shadow')) return bucketByKey('shadows');
  }
  // Name hints for the remaining categories.
  if (hint.includes('radius') || hint.includes('radii')) return bucketByKey('radii');
  if (hint.includes('shadow')) return bucketByKey('shadows');
  if (hint.includes('font-family') || hint.includes('family') || hint.includes('typeface')) return bucketByKey('font-family');
  if (hint.includes('weight')) return bucketByKey('font-weight');
  if (hint.includes('line-height') || hint.includes('leading')) return bucketByKey('line-height');
  if (hint.includes('font-size') || hint.includes('text-size') || hint.includes('fontsize')) return bucketByKey('font-size');
  if (hint.includes('space') || hint.includes('spacing') || hint.includes('gap') || hint.includes('margin') || hint.includes('padding') || hint.includes('size')) {
    if (normalizeLength(raw) != null) return bucketByKey('spacing');
  }
  // A bare font stack (comma-separated with a generic or quote).
  if (raw.includes(',') && /["']|serif|sans-serif|monospace|system-ui|ui-/.test(raw)) {
    return bucketByKey('font-family');
  }
  // Fallback: a single length is spacing.
  if (normalizeLength(raw) != null) return bucketByKey('spacing');
  return null;
}

// ---------------------------------------------------------------------------
// Pass 2 — bounded chunked getComputedStyle
// ---------------------------------------------------------------------------

async function collectComputed(
  acc: Map<string, Accum>,
  excludeRoot: Element | undefined,
  isAborted: () => boolean,
): Promise<{ dropped: number; aborted: boolean }> {
  const root = document.body ?? document.documentElement;
  if (!root) return { dropped: 0, aborted: false };

  // Single chunked walk: visibility test + sampling share one getComputedStyle
  // per element, and elements beyond the ~500 cap are counted (not sampled) so
  // the dropped remainder can be surfaced rather than silently truncated.
  const all = Array.from(root.querySelectorAll('*'));
  let sampled = 0;
  let dropped = 0;

  for (let i = 0; i < all.length; i += ELEMENT_CHUNK) {
    if (isAborted()) return { dropped, aborted: true };
    const end = Math.min(i + ELEMENT_CHUNK, all.length);
    for (let j = i; j < end; j++) {
      const el = all[j];
      if (excludeRoot && (el === excludeRoot || excludeRoot.contains(el))) continue;

      let cs: CSSStyleDeclaration;
      try {
        cs = getComputedStyle(el);
      } catch {
        continue;
      }
      if (cs.display === 'none' || cs.visibility === 'hidden' || cs.visibility === 'collapse') continue;
      const rect = el.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) continue;

      // Visible. Sample up to the cap; count the rest as dropped.
      if (sampled < ELEMENT_CAP) {
        sampleFromComputed(cs, acc);
        sampled++;
      } else {
        dropped++;
      }
    }
    if (end < all.length) await idle();
  }

  return { dropped, aborted: false };
}

function sampleFromComputed(cs: CSSStyleDeclaration, acc: Map<string, Accum>): void {
  for (const bucket of BUCKETS) {
    for (const prop of bucket.readProps) {
      const raw = cs.getPropertyValue(prop);
      if (raw) record(acc, bucket, raw, 'computed');
    }
  }
}

// ---------------------------------------------------------------------------
// Pass 3 — CSSOM declared-value pass
// ---------------------------------------------------------------------------

/** Returns true if any sheet was cross-origin (partial signal). */
function collectCssom(acc: Map<string, Accum>): boolean {
  let partial = false;
  let ruleCount = 0;
  const sheets = collectSheets();

  const walk = (rules: CSSRuleList): void => {
    for (let i = 0; i < rules.length; i++) {
      if (ruleCount >= CSSOM_RULE_CEILING) return;
      const rule = rules[i];
      if (rule instanceof CSSStyleRule) {
        ruleCount++;
        collectFromDeclaration(rule.style, acc);
      } else if (
        rule instanceof CSSMediaRule ||
        rule instanceof CSSSupportsRule ||
        ('cssRules' in rule && (rule as { cssRules?: unknown }).cssRules instanceof CSSRuleList)
      ) {
        // Recurse into grouping rules (@media / @supports / @layer).
        const nested = (rule as unknown as { cssRules?: CSSRuleList }).cssRules;
        if (nested) walk(nested);
      }
    }
  };

  for (const sheet of sheets) {
    if (ruleCount >= CSSOM_RULE_CEILING) {
      partial = true;
      break;
    }
    let rules: CSSRuleList;
    try {
      rules = sheet.cssRules;
    } catch {
      // Cross-origin SecurityError — the exact inspection/css-rules.ts pattern.
      partial = true;
      continue;
    }
    walk(rules);
  }
  // Ceiling hit mid-/end-of-walk also degrades the harvest — surface it even
  // when the break above didn't fire (ceiling reached on the last sheet).
  if (ruleCount >= CSSOM_RULE_CEILING) partial = true;
  return partial;
}

/**
 * Collect harvestable values from a declared style block. Reads each declared
 * property directly and expands the common box/gap/radius/border-color
 * shorthands into their longhands (skipping any value containing `(` — a var()
 * or calc() that can't be split safely).
 */
function collectFromDeclaration(style: CSSStyleDeclaration, acc: Map<string, Accum>): void {
  for (let i = 0; i < style.length; i++) {
    const prop = style[i];
    const raw = style.getPropertyValue(prop);
    if (!raw) continue;

    const direct = PROP_TO_BUCKET.get(prop);
    if (direct) {
      record(acc, direct, raw, 'cssom');
      continue;
    }

    // Shorthand expansion (best-effort; skip values with functions).
    if (raw.includes('(') && (prop === 'margin' || prop === 'padding' || prop === 'gap' || prop === 'border-radius' || prop === 'border-color')) {
      continue;
    }
    switch (prop) {
      case 'margin':
      case 'padding': {
        // Each expanded value maps to its OWN longhand (top/right/bottom/left).
        recordExpanded(acc, [`${prop}-top`, `${prop}-right`, `${prop}-bottom`, `${prop}-left`], raw);
        break;
      }
      case 'gap': {
        const parts = raw.trim().split(/\s+/);
        if (parts.length === 1) {
          recordByProp(acc, 'gap', parts[0]);
        } else if (parts.length >= 2) {
          recordByProp(acc, 'row-gap', parts[0]);
          recordByProp(acc, 'column-gap', parts[1]);
        }
        break;
      }
      case 'border-radius': {
        // `border-radius` fills TL/TR/BR/BL with the same 1–4 rule as a box; take
        // the horizontal radii before any `/` (elliptical) and map to the corners.
        recordExpanded(acc, RADII_CORNERS, raw.split('/')[0].trim());
        break;
      }
      case 'border-color': {
        recordExpanded(
          acc,
          ['border-top-color', 'border-right-color', 'border-bottom-color', 'border-left-color'],
          raw,
        );
        break;
      }
      default:
        break;
    }
  }
}

function recordByProp(acc: Map<string, Accum>, prop: string, raw: string): void {
  const bucket = PROP_TO_BUCKET.get(prop);
  if (bucket) record(acc, bucket, raw, 'cssom');
}

/**
 * Expand a 1–4 value box/corner shorthand and record each resolved value under
 * its OWN longhand — `longhands` is positional [top,right,bottom,left] for box
 * properties, or [TL,TR,BR,BL] for `border-radius` corners.
 */
function recordExpanded(acc: Map<string, Accum>, longhands: readonly string[], raw: string): void {
  const values = expandBox(raw);
  for (let i = 0; i < 4; i++) recordByProp(acc, longhands[i], values[i]);
}

/** Expand a 1–4 value box shorthand into a 4-slot array by the CSS fill rule. */
function expandBox(raw: string): string[] {
  const p = raw.trim().split(/\s+/);
  if (p.length === 1) return [p[0], p[0], p[0], p[0]];
  if (p.length === 2) return [p[0], p[1], p[0], p[1]];
  if (p.length === 3) return [p[0], p[1], p[2], p[1]];
  return [p[0], p[1], p[2], p[3]];
}

// ---------------------------------------------------------------------------
// Rank / floor / cap
// ---------------------------------------------------------------------------

function rankAndCap(acc: Map<string, Accum>): InferredOption[] {
  const byBucket = new Map<string, Accum[]>();
  for (const entry of acc.values()) {
    // Frequency floor — custom-property origin is exempt (declared intent).
    if (entry.origin !== 'custom-property' && entry.frequency < FREQUENCY_FLOOR) continue;
    const list = byBucket.get(entry.bucketKey);
    if (list) list.push(entry);
    else byBucket.set(entry.bucketKey, [entry]);
  }

  const out: InferredOption[] = [];
  for (const bucket of BUCKETS) {
    const list = byBucket.get(bucket.key);
    if (!list) continue;
    list.sort((a, b) => {
      if (b.frequency !== a.frequency) return b.frequency - a.frequency;
      return a.value < b.value ? -1 : a.value > b.value ? 1 : 0;
    });
    for (const entry of list.slice(0, bucket.cap)) {
      out.push({
        value: entry.value,
        category: bucket.category,
        cssProperties: bucket.offerProps,
        frequency: entry.frequency,
        origin: entry.origin,
        fromPageInference: true,
        label: entry.label,
      });
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Normalization
// ---------------------------------------------------------------------------

/**
 * Colors → lowercase hex (`#rrggbb`, or `#rrggbbaa` when alpha < 1). Handles
 * rgb()/rgba()/hsl()/hsla()/hex; fully-transparent and unparseable values are
 * dropped. Named colors that aren't hex/rgb are kept lowercased (a valid CSS
 * value and a stable dedup key) rather than guessed at.
 */
function normalizeColor(raw: string): string | null {
  const v = raw.trim().toLowerCase();
  if (!v || v === 'transparent' || v === 'currentcolor' || v === 'none' || v === 'inherit' || v === 'initial' || v === 'unset') {
    return null;
  }

  const rgb = parseRgb(v) ?? parseHsl(v) ?? parseHex(v);
  if (rgb) {
    if (rgb.a <= 0) return null; // fully transparent — not a useful default
    return rgbToHex(rgb);
  }

  // Named / keyword color — keep as-is if it's a plain identifier.
  if (/^[a-z]+$/.test(v)) return v;
  return null;
}

interface Rgba { r: number; g: number; b: number; a: number }

function parseRgb(v: string): Rgba | null {
  const m = v.match(/^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)(?:[\s,/]+([\d.%]+))?\s*\)$/);
  if (!m) return null;
  const a = m[4] == null ? 1 : m[4].endsWith('%') ? parseFloat(m[4]) / 100 : parseFloat(m[4]);
  return { r: clamp255(+m[1]), g: clamp255(+m[2]), b: clamp255(+m[3]), a };
}

function parseHex(v: string): Rgba | null {
  const m = v.match(/^#([0-9a-f]{3,8})$/);
  if (!m) return null;
  const h = m[1];
  const exp = (s: string): number => parseInt(s.length === 1 ? s + s : s, 16);
  if (h.length === 3) return { r: exp(h[0]), g: exp(h[1]), b: exp(h[2]), a: 1 };
  if (h.length === 4) return { r: exp(h[0]), g: exp(h[1]), b: exp(h[2]), a: exp(h[3]) / 255 };
  if (h.length === 6) return { r: exp(h.slice(0, 2)), g: exp(h.slice(2, 4)), b: exp(h.slice(4, 6)), a: 1 };
  if (h.length === 8) return { r: exp(h.slice(0, 2)), g: exp(h.slice(2, 4)), b: exp(h.slice(4, 6)), a: exp(h.slice(6, 8)) / 255 };
  return null;
}

function parseHsl(v: string): Rgba | null {
  const m = v.match(/^hsla?\(\s*([\d.]+)(?:deg)?[\s,]+([\d.]+)%[\s,]+([\d.]+)%(?:[\s,/]+([\d.%]+))?\s*\)$/);
  if (!m) return null;
  const h = ((+m[1] % 360) + 360) % 360 / 360;
  const s = clamp01(+m[2] / 100);
  const l = clamp01(+m[3] / 100);
  const a = m[4] == null ? 1 : m[4].endsWith('%') ? parseFloat(m[4]) / 100 : parseFloat(m[4]);
  if (s === 0) {
    const g = Math.round(l * 255);
    return { r: g, g, b: g, a };
  }
  const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  const p = 2 * l - q;
  return {
    r: Math.round(hueToRgb(p, q, h + 1 / 3) * 255),
    g: Math.round(hueToRgb(p, q, h) * 255),
    b: Math.round(hueToRgb(p, q, h - 1 / 3) * 255),
    a,
  };
}

function hueToRgb(p: number, q: number, t: number): number {
  if (t < 0) t += 1;
  if (t > 1) t -= 1;
  if (t < 1 / 6) return p + (q - p) * 6 * t;
  if (t < 1 / 2) return q;
  if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
  return p;
}

function rgbToHex({ r, g, b, a }: Rgba): string {
  const h = (n: number): string => Math.round(n).toString(16).padStart(2, '0');
  const base = `#${h(r)}${h(g)}${h(b)}`;
  if (a >= 1) return base;
  return `${base}${h(Math.round(clamp01(a) * 255))}`;
}

function clamp255(n: number): number {
  return Math.max(0, Math.min(255, n));
}
function clamp01(n: number): number {
  return Math.max(0, Math.min(1, n));
}

/**
 * Lengths (spacing / radii / font-size) → trimmed, lowercase unit, authored unit
 * preserved; `0<unit>` collapses to `0`. Non-length keywords are dropped.
 */
function normalizeLength(raw: string): string | null {
  const v = raw.trim().toLowerCase();
  if (!v || v === 'auto' || v === 'normal' || v === 'none' || v === 'inherit' || v === 'initial' || v === 'unset') {
    return null;
  }
  const m = v.match(/^(-?[\d.]+)(px|rem|em|%|vh|vw|vmin|vmax|ch)?$/);
  if (!m) return null;
  const num = parseFloat(m[1]);
  if (!Number.isFinite(num)) return null;
  if (num === 0) return '0';
  const unit = m[2] ?? 'px';
  return `${num}${unit}`;
}

/** font-family → whitespace-collapsed, preserving the full stack as one option. */
function normalizeFontFamily(raw: string): string | null {
  const v = raw.trim().replace(/\s*,\s*/g, ', ').replace(/\s+/g, ' ');
  if (!v || v === 'inherit' || v === 'initial' || v === 'unset') return null;
  return v;
}

/** font-weight → numeric (`normal` → 400, `bold` → 700); numeric preserved. */
function normalizeFontWeight(raw: string): string | null {
  const v = raw.trim().toLowerCase();
  if (v === 'normal') return '400';
  if (v === 'bold') return '700';
  if (/^[1-9]00$|^(1000|[1-9]\d{0,2})$/.test(v)) {
    const n = parseInt(v, 10);
    if (n >= 1 && n <= 1000) return String(n);
  }
  return null;
}

/** line-height → unitless preserved; px preserved; `normal` dropped. */
function normalizeLineHeight(raw: string): string | null {
  const v = raw.trim().toLowerCase();
  if (!v || v === 'normal' || v === 'inherit' || v === 'initial' || v === 'unset') return null;
  const m = v.match(/^([\d.]+)(px|rem|em|%)?$/);
  if (!m) return null;
  const num = parseFloat(m[1]);
  if (!Number.isFinite(num)) return null;
  return m[2] ? `${num}${m[2]}` : String(num);
}

/**
 * box-shadow → whitespace-normalized layer list, layer order preserved.
 * Visual-equivalence dedup is out of scope for v1 (feature-011): only
 * whitespace normalization is applied.
 */
function normalizeShadow(raw: string): string | null {
  const v = raw.trim();
  if (!v || v.toLowerCase() === 'none' || v.toLowerCase() === 'inherit' || v.toLowerCase() === 'initial' || v.toLowerCase() === 'unset') {
    return null;
  }
  // Only accept values that look like a shadow (contain a length or a color).
  if (!/\d/.test(v) && !/rgb|hsl|#/.test(v)) return null;
  return v.replace(/\s*,\s*/g, ', ').replace(/\s+/g, ' ');
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/** Author + adopted stylesheets, in document order. */
function collectSheets(): CSSStyleSheet[] {
  const sheets: CSSStyleSheet[] = [];
  for (const sheet of Array.from(document.styleSheets)) sheets.push(sheet);
  for (const sheet of Array.from(document.adoptedStyleSheets ?? [])) sheets.push(sheet);
  return sheets;
}

/** Yield to the main thread, resuming on the next idle callback. */
function idle(): Promise<void> {
  return new Promise((resolve) => {
    if (typeof requestIdleCallback === 'function') {
      requestIdleCallback(() => resolve(), { timeout: 500 });
    } else {
      setTimeout(resolve, 0);
    }
  });
}

function abortedResult(): HarvestResult {
  return { options: [], partial: false, droppedElements: 0, aborted: true };
}
