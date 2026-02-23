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
  readonly center: number;
  readonly insertIndex: number;
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
