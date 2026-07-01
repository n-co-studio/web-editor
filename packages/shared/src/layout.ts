/**
 * Structural auto-layout — the machine-checkable form of the feature-010 contract.
 *
 * This is the single module both the capture layer and any convention validation
 * compile against, so the editable-list detection rule, the threshold constant,
 * and the homogeneity predicate have exactly one definition (compile-time drift
 * protection). The conceptual model, the code-gen convention, and the
 * acceptance-defining flat-data rule live in
 * `docs/spec/compiled/v1/features/feature-010-structural-contract.md`; the wire
 * contract lives in `docs/spec/compiled/v1/data-contracts.md` → Structural
 * Auto-Layout. The DOM-free wire types (`LayoutRole`, `LayoutContainerDescriptor`)
 * live in `./diff.ts`; this module owns the runtime detection that produces them.
 *
 * DOM-dependent: `parseLayoutSignal` / `classifyLayoutRole` read live computed
 * style, so this module is imported by the browser capture layer only (via
 * `@nco-studio/shared/layout`). The Node consumers (mcp-server) import the wire
 * types from `@nco-studio/shared` and never parse this file.
 */

import type { LayoutRole, LayoutContainerDescriptor } from './diff.js';

export type { LayoutRole, LayoutContainerDescriptor } from './diff.js';

/**
 * The runtime-assigned / opt-in-authored editable-list signal attribute. Its
 * value is the layout **kind** (`flex` | `grid`) — not a duplicate of `display`.
 * Absence means "fall back to the thresholded heuristic," not "not a list."
 */
export const DATA_FE_LAYOUT_ATTR = 'data-fe-layout';

/**
 * The per-instance identity attribute (`data-fe-uid`, issue #27) the descriptors
 * key on. Mirrored here as a literal so `shared` stays a leaf package (it cannot
 * import the chrome-extension `dom-utils` that also defines it); the value is the
 * ratified wire contract, not an implementation detail.
 */
export const FE_UID_ATTR = 'data-fe-uid';

/** Minimum direct-element-child count for the thresholded heuristic (feature-010). */
export const MIN_EDITABLE_LIST_CHILDREN = 2;

/** The layout kinds an editable list can be. */
export type LayoutKind = 'flex' | 'grid';

/** Read `data-fe-uid` off an element, or `undefined` when unstamped. */
function readUid(el: Element): string | undefined {
  return el.getAttribute(FE_UID_ATTR) ?? undefined;
}

/** Direct element children of a container, in DOM (visual) order. */
export function directElementChildren(el: Element): Element[] {
  return Array.from(el.children);
}

/**
 * Homogeneity gate for the thresholded heuristic. Children are homogeneous when
 * they share a `tagName`, **or** share a `.map()` source-origin family — the same
 * `data-source-file` + `data-source-line` pair (siblings emitted by one `.map()`
 * over one JSX line). Mixed one-off elements (a `<button><svg><span>` toolbar)
 * fail the gate, suppressing incidental flex wrappers.
 */
export function areChildrenHomogeneous(children: readonly Element[]): boolean {
  if (children.length < MIN_EDITABLE_LIST_CHILDREN) return false;

  const firstTag = children[0].tagName;
  const allSameTag = children.every((c) => c.tagName === firstTag);
  if (allSameTag) return true;

  const file = children[0].getAttribute('data-source-file');
  const line = children[0].getAttribute('data-source-line');
  if (!file || !line) return false;
  return children.every(
    (c) =>
      c.getAttribute('data-source-file') === file &&
      c.getAttribute('data-source-line') === line,
  );
}

/**
 * The layout kind explicitly authored on a container, or `null` when the
 * `data-fe-layout` attribute is absent or malformed. Authoritative when present.
 */
export function explicitLayoutSignal(el: Element): LayoutKind | null {
  const raw = el.getAttribute(DATA_FE_LAYOUT_ATTR);
  return raw === 'flex' || raw === 'grid' ? raw : null;
}

/** Base primary-axis direction for a container's layout kind (axis token only). */
function computeBaseDirection(el: Element, layout: LayoutKind): string {
  const cs = getComputedStyle(el);
  if (layout === 'grid') {
    return (cs.gridAutoFlow || 'row').includes('column') ? 'column' : 'row';
  }
  return cs.flexDirection || 'row';
}

/**
 * Resolve a container to its {@link LayoutContainerDescriptor}, or `null` when the
 * element is not an editable list. Detection order (feature-010):
 *   1. Explicit `data-fe-layout` — authoritative (`signalSource: 'explicit'`).
 *   2. Thresholded heuristic — `display ∈ {flex, grid}` ∧ ≥ 2 direct element
 *      children ∧ tag/source homogeneity (`signalSource: 'heuristic'`).
 *
 * The returned descriptor's `uid`/`childUids` read existing `data-fe-uid`s (the
 * caller is responsible for stamping them first); `parentUid`/`role` are set by
 * the caller for a nested (`group`) container. `direction` is the base axis token
 * — the capture layer may refine it with the wrap suffix (issue #30).
 */
export function parseLayoutSignal(el: Element): LayoutContainerDescriptor | null {
  const explicit = explicitLayoutSignal(el);
  let layout: LayoutKind;
  let signalSource: 'explicit' | 'heuristic';

  if (explicit) {
    layout = explicit;
    signalSource = 'explicit';
  } else {
    const display = getComputedStyle(el).display;
    const isGrid = display.includes('grid');
    const isFlex = display.includes('flex');
    if (!isGrid && !isFlex) return null;

    const children = directElementChildren(el);
    if (children.length < MIN_EDITABLE_LIST_CHILDREN) return null;
    if (!areChildrenHomogeneous(children)) return null;

    layout = isGrid ? 'grid' : 'flex';
    signalSource = 'heuristic';
  }

  const children = directElementChildren(el);
  return {
    uid: readUid(el) ?? '',
    layout,
    direction: computeBaseDirection(el, layout),
    childUids: children.map((c) => readUid(c) ?? ''),
    signalSource,
  };
}

/** Whether a container is an editable list (explicit signal or heuristic). */
export function isEditableList(el: Element): boolean {
  return parseLayoutSignal(el) !== null;
}

/** A grid child placed explicitly (line/area placement, not auto-flow / span). */
function isExplicitGridChild(el: Element): boolean {
  const cs = getComputedStyle(el);
  const placed = (v: string): boolean =>
    Boolean(v) && v !== 'auto' && !v.startsWith('span');
  return placed(cs.gridColumnStart) || placed(cs.gridRowStart);
}

/**
 * Classify a direct child of an editable list (feature-010):
 *   - `absolute` — `position: absolute|fixed` (the parallax case), or an
 *     explicitly-placed grid child. A visible, selectable, never-diff-hidden peer
 *     that is excluded from reorder index math and gap-math.
 *   - `group` — the child is itself an editable-list container (nested flex/grid).
 *   - `flow` — a normal in-flow reorder/group target (the default).
 *
 * `absolute` is checked first: a positioned nested container is out of flow, so it
 * is a positioned peer, not a group.
 */
export function classifyLayoutRole(el: Element, container: Element): LayoutRole {
  const position = getComputedStyle(el).position;
  if (position === 'absolute' || position === 'fixed') return 'absolute';

  if (getComputedStyle(container).display.includes('grid') && isExplicitGridChild(el)) {
    return 'absolute';
  }

  if (isEditableList(el)) return 'group';

  return 'flow';
}

/**
 * The `layoutRole: flow | group` children of a container, in visual order —
 * the reorderable peer list. `absolute` peers (parallax / explicitly-placed) are
 * excluded, so they never enter reorder index math or gap-math (they remain
 * visible in a `LayoutContainerDescriptor.childUids[]`, never diff-hidden).
 */
export function flowChildren(container: Element): Element[] {
  return directElementChildren(container).filter(
    (c) => classifyLayoutRole(c, container) !== 'absolute',
  );
}
