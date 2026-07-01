/**
 * Gap-center geometry — pure layout math for computing drop/insert zones
 * in flex and grid containers. Shared by reorder and insert editors.
 */

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/** Layout direction and reversal state for a flex/grid container. */
export interface ContainerLayout {
  readonly direction: 'row' | 'column';
  readonly isReversed: boolean;
}

/** A computed gap zone between siblings (or at container edges). */
export interface GapZone {
  /** Primary-axis coordinate of the gap center (single-axis / 1D path). */
  readonly center: number;
  readonly insertIndex: number;
  /**
   * 2D pip center for wrapping/multi-line containers (issue #30). Set only by
   * [computeGapZones2D]; absent on the single-axis [computeGapZones] output.
   */
  readonly cx?: number;
  readonly cy?: number;
}

// ---------------------------------------------------------------------------
// Functions
// ---------------------------------------------------------------------------

/**
 * Detect the primary layout axis and reversal state of a flex/grid container.
 * Grid containers use `gridAutoFlow`; flex containers use `flexDirection`.
 */
export function detectContainerLayout(container: HTMLElement): ContainerLayout {
  const cs = getComputedStyle(container);

  if (cs.display.includes('grid')) {
    const flow = cs.gridAutoFlow || 'row';
    return {
      direction: flow.includes('column') ? 'column' : 'row',
      isReversed: false,
    };
  }

  const dir = cs.flexDirection || 'row';
  return {
    direction: dir.startsWith('column') ? 'column' : 'row',
    isReversed: dir.endsWith('-reverse'),
  };
}

/**
 * Gap-center algorithm: for N children, compute N+1 gap zones.
 * Each zone center is the midpoint of the gap between adjacent sibling edges
 * (or between container edge and first/last child).
 */
export function computeGapZones(
  container: HTMLElement,
  children: HTMLElement[],
  layout: ContainerLayout,
): GapZone[] {
  const isRow = layout.direction === 'row';
  const containerRect = container.getBoundingClientRect();

  // Empty container — single zone at the center (insert at index 0)
  if (children.length === 0) {
    const center = isRow
      ? (containerRect.left + containerRect.right) / 2
      : (containerRect.top + containerRect.bottom) / 2;
    return [{ center, insertIndex: 0 }];
  }
  const rects = children.map((c) => c.getBoundingClientRect());
  const zones: GapZone[] = [];

  for (let i = 0; i <= children.length; i++) {
    let center: number;

    if (i === 0) {
      // Before first child
      const firstStart = isRow ? rects[0].left : rects[0].top;
      const containerStart = isRow ? containerRect.left : containerRect.top;
      center = (containerStart + firstStart) / 2;
    } else if (i === children.length) {
      // After last child
      const lastEnd = isRow ? rects[i - 1].right : rects[i - 1].bottom;
      const containerEnd = isRow ? containerRect.right : containerRect.bottom;
      center = (lastEnd + containerEnd) / 2;
    } else {
      // Between child[i-1] and child[i]
      const prevEnd = isRow ? rects[i - 1].right : rects[i - 1].bottom;
      const nextStart = isRow ? rects[i].left : rects[i].top;
      center = (prevEnd + nextStart) / 2;
    }

    zones.push({ center, insertIndex: i });
  }

  // For reversed directions, invert the insertIndex mapping.
  // Physical positions stay the same but DOM indices are reversed.
  if (layout.isReversed) {
    const n = zones.length;
    for (let i = 0; i < n; i++) {
      zones[i] = { center: zones[i].center, insertIndex: n - 1 - i };
    }
  }

  return zones;
}

/** Find the closest gap zone to the pointer along the layout axis. */
export function hitTestGapZone(
  zones: readonly GapZone[],
  pointerPos: number,
): number {
  let bestIndex = zones.length > 0 ? zones[0].insertIndex : 0;
  let bestDist = Infinity;

  for (const zone of zones) {
    const dist = Math.abs(pointerPos - zone.center);
    if (dist < bestDist) {
      bestDist = dist;
      bestIndex = zone.insertIndex;
    }
  }

  return bestIndex;
}

// ---------------------------------------------------------------------------
// 2D gap-math — gated to wrapping / multi-line containers (issue #30)
//
// The single-axis functions above stay byte-for-byte unchanged and remain the
// path for `nowrap` flex containers (zero regression). The functions below add
// a 2D nearest-gap model for wrapped flex galleries and multi-track grids,
// where consecutive DOM siblings may sit on different visual rows so a single
// projected axis picks the wrong gap.
// ---------------------------------------------------------------------------

/**
 * Whether a flex/grid container lays its children out on more than one visual
 * line (wrapped flex or a multi-track grid). This is the gate for the 2D
 * gap-math: callers use [computeGapZones2D]/[hitTestGapZone2D] only when this
 * returns true, and stay on the single-axis path otherwise.
 *
 * Returns false for `nowrap` flex (keeps that path unchanged) and for a
 * wrap-enabled container whose children happen to fit on one line (the 1D and
 * 2D results coincide there, so the cheaper path is fine).
 */
export function detectWrapping(
  container: HTMLElement,
  children: HTMLElement[],
  layout: ContainerLayout,
): boolean {
  if (children.length < 2) return false;

  const cs = getComputedStyle(container);
  const isGrid = cs.display.includes('grid');
  const isWrapFlex = cs.display.includes('flex') && cs.flexWrap !== 'nowrap';
  if (!isGrid && !isWrapFlex) return false;

  // Confirm the container is genuinely multi-line by clustering children on the
  // cross axis: same-line children share a cross-axis start (within tolerance);
  // a wrap introduces a new cluster.
  const isRow = layout.direction === 'row';
  const crossStarts = children
    .map((c) => {
      const r = c.getBoundingClientRect();
      return isRow ? r.top : r.left;
    })
    .sort((a, b) => a - b);

  const tolerance = 4; // px — jitter within a single visual line
  let lines = 1;
  for (let i = 1; i < crossStarts.length; i++) {
    if (crossStarts[i] - crossStarts[i - 1] > tolerance) lines++;
  }
  return lines > 1;
}

/**
 * 2D nearest-gap zones for a wrapping container. Each zone carries an (x, y) pip
 * center (`cx`/`cy`) placed at the *insert-before* edge of `child[i]` — the
 * child's leading edge along the primary axis, at its cross-axis center — with
 * the final zone at the trailing edge of the last child. Placing the pip on the
 * child's edge (rather than a midpoint of two centers) keeps "start of the next
 * row" distinct from "end of the previous row" in a wrapped gallery, so a drop
 * at the far side of a row resolves to that row's boundary, not a diagonal
 * center between rows.
 *
 * Direction-aware: the leading/trailing edge flips for `-reverse` layouts, so a
 * reversed wrap still maps the pointer to the correct DOM index.
 *
 * Gated: use only when [detectWrapping] is true.
 */
export function computeGapZones2D(
  container: HTMLElement,
  children: HTMLElement[],
  layout: ContainerLayout,
): GapZone[] {
  const containerRect = container.getBoundingClientRect();

  if (children.length === 0) {
    const cx = (containerRect.left + containerRect.right) / 2;
    const cy = (containerRect.top + containerRect.bottom) / 2;
    return [{ center: cx, insertIndex: 0, cx, cy }];
  }

  const isRow = layout.direction === 'row';
  const rev = layout.isReversed;
  const rects = children.map((c) => c.getBoundingClientRect());
  const n = children.length;
  const zones: GapZone[] = [];

  for (let i = 0; i <= n; i++) {
    let cx: number;
    let cy: number;
    if (i < n) {
      // Insert-before edge of child[i] (leading edge along the primary axis).
      const r = rects[i];
      if (isRow) {
        cx = rev ? r.right : r.left;
        cy = (r.top + r.bottom) / 2;
      } else {
        cx = (r.left + r.right) / 2;
        cy = rev ? r.bottom : r.top;
      }
    } else {
      // After the last DOM child — its trailing edge.
      const r = rects[n - 1];
      if (isRow) {
        cx = rev ? r.left : r.right;
        cy = (r.top + r.bottom) / 2;
      } else {
        cx = (r.left + r.right) / 2;
        cy = rev ? r.top : r.bottom;
      }
    }
    zones.push({ center: cx, insertIndex: i, cx, cy });
  }
  return zones;
}

/** Find the nearest 2D gap zone to the pointer by Euclidean distance. */
export function hitTestGapZone2D(
  zones: readonly GapZone[],
  px: number,
  py: number,
): number {
  let bestIndex = zones.length > 0 ? zones[0].insertIndex : 0;
  let bestDist = Infinity;

  for (const zone of zones) {
    const zx = zone.cx ?? zone.center;
    const zy = zone.cy ?? 0;
    const dx = px - zx;
    const dy = py - zy;
    const dist = dx * dx + dy * dy; // squared distance — monotonic, avoids sqrt
    if (dist < bestDist) {
      bestDist = dist;
      bestIndex = zone.insertIndex;
    }
  }

  return bestIndex;
}
