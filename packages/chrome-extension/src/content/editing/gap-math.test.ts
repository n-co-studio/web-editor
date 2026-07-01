import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';

import {
  computeGapZones,
  hitTestGapZone,
  computeGapZones2D,
  hitTestGapZone2D,
  detectWrapping,
  type ContainerLayout,
} from './gap-math';

// ---------------------------------------------------------------------------
// Minimal DOM stubs — the gap-math functions touch only getBoundingClientRect
// (on the container + children) and getComputedStyle (detectWrapping). Matches
// the package's mock-based test convention (no jsdom).
// ---------------------------------------------------------------------------

interface Rect {
  left: number;
  top: number;
  right: number;
  bottom: number;
  width: number;
  height: number;
}

function rect(left: number, top: number, width: number, height: number): Rect {
  return { left, top, width, height, right: left + width, bottom: top + height };
}

class El {
  constructor(
    private readonly _rect: Rect,
    private readonly _style: Record<string, string> = {},
  ) {}
  getBoundingClientRect(): Rect {
    return this._rect;
  }
  get __style(): Record<string, string> {
    return this._style;
  }
}

const ROW: ContainerLayout = { direction: 'row', isReversed: false };

// getComputedStyle shim: reads the mock element's `__style` bag.
let priorGCS: unknown;
before(() => {
  priorGCS = (globalThis as any).getComputedStyle;
  (globalThis as any).getComputedStyle = (el: El) => ({
    display: el.__style.display ?? 'flex',
    flexWrap: el.__style.flexWrap ?? 'nowrap',
    flexDirection: el.__style.flexDirection ?? 'row',
    gridAutoFlow: el.__style.gridAutoFlow ?? 'row',
  });
});
after(() => {
  (globalThis as any).getComputedStyle = priorGCS;
});

describe('gap-math 1D single-axis path (nowrap — unchanged)', () => {
  it('computes N+1 gap zones with monotonic centers for a row', () => {
    const container = new El(rect(0, 0, 300, 100));
    const children = [
      new El(rect(10, 10, 80, 80)),
      new El(rect(110, 10, 80, 80)),
      new El(rect(210, 10, 80, 80)),
    ];
    const zones = computeGapZones(container as any, children as any, ROW);
    assert.equal(zones.length, 4);
    assert.deepEqual(zones.map((z) => z.insertIndex), [0, 1, 2, 3]);
    // Centers strictly increasing along the primary axis.
    for (let i = 1; i < zones.length; i++) {
      assert.ok(zones[i].center > zones[i - 1].center);
    }
    // 2D fields absent on the single-axis path.
    assert.equal(zones[0].cx, undefined);
    assert.equal(zones[0].cy, undefined);
  });

  it('hit-tests to the nearest gap along the axis', () => {
    const container = new El(rect(0, 0, 300, 100));
    const children = [
      new El(rect(10, 10, 80, 80)),
      new El(rect(110, 10, 80, 80)),
      new El(rect(210, 10, 80, 80)),
    ];
    const zones = computeGapZones(container as any, children as any, ROW);
    // Pointer between child 0 and child 1 → insert index 1.
    assert.equal(hitTestGapZone(zones, 100), 1);
    // Far left → index 0.
    assert.equal(hitTestGapZone(zones, -50), 0);
    // Far right → last index.
    assert.equal(hitTestGapZone(zones, 999), 3);
  });
});

describe('gap-math 2D nearest-gap path (wrapping)', () => {
  // A 2-column wrapping gallery: 4 items on two rows.
  //   [0][1]
  //   [2][3]
  const container = new El(rect(0, 0, 200, 200));
  const children = [
    new El(rect(0, 0, 90, 90)),     // row 1, col 1  → center (45, 45)
    new El(rect(100, 0, 90, 90)),   // row 1, col 2  → center (145, 45)
    new El(rect(0, 100, 90, 90)),   // row 2, col 1  → center (45, 145)
    new El(rect(100, 100, 90, 90)), // row 2, col 2  → center (145, 145)
  ];

  it('produces a pip (cx/cy) per gap, N+1 total', () => {
    const zones = computeGapZones2D(container as any, children as any, ROW);
    assert.equal(zones.length, 5);
    for (const z of zones) {
      assert.equal(typeof z.cx, 'number');
      assert.equal(typeof z.cy, 'number');
    }
  });

  it('hit-tests by Euclidean distance across rows', () => {
    const zones = computeGapZones2D(container as any, children as any, ROW);
    // Near the gap between child 2 and child 3 (second row) → index 3.
    assert.equal(hitTestGapZone2D(zones, 95, 145), 3);
    // Near the gap between child 0 and child 1 (first row) → index 1.
    assert.equal(hitTestGapZone2D(zones, 95, 45), 1);
    // Past the last child (bottom-right) → index 4 (append).
    assert.equal(hitTestGapZone2D(zones, 200, 200), 4);
    // Before the first child (top-left) → index 0.
    assert.equal(hitTestGapZone2D(zones, -30, -30), 0);
  });

  it('resolves a second-row target to its correct DOM index, not a row-1 gap', () => {
    const zones = computeGapZones2D(container as any, children as any, ROW);
    // A pointer on row 2 must never collapse onto a row-1 gap (the single-axis
    // bug this fixes): dropping just before child 2 → index 2.
    assert.equal(hitTestGapZone2D(zones, 10, 130), 2);
  });
});

describe('detectWrapping gate', () => {
  it('is false for a nowrap flex row (stays on 1D path)', () => {
    const container = new El(rect(0, 0, 300, 100), { display: 'flex', flexWrap: 'nowrap' });
    const children = [new El(rect(10, 10, 80, 80)), new El(rect(110, 10, 80, 80))];
    assert.equal(detectWrapping(container as any, children as any, ROW), false);
  });

  it('is false for a single child', () => {
    const container = new El(rect(0, 0, 300, 100), { display: 'flex', flexWrap: 'wrap' });
    const children = [new El(rect(10, 10, 80, 80))];
    assert.equal(detectWrapping(container as any, children as any, ROW), false);
  });

  it('is false for a wrap-enabled row that fits on one line', () => {
    const container = new El(rect(0, 0, 300, 100), { display: 'flex', flexWrap: 'wrap' });
    const children = [new El(rect(10, 10, 80, 80)), new El(rect(110, 10, 80, 80))];
    assert.equal(detectWrapping(container as any, children as any, ROW), false);
  });

  it('is true for a genuinely multi-line wrapped flex', () => {
    const container = new El(rect(0, 0, 200, 200), { display: 'flex', flexWrap: 'wrap' });
    const children = [
      new El(rect(0, 0, 90, 90)),
      new El(rect(100, 0, 90, 90)),
      new El(rect(0, 100, 90, 90)), // second row → distinct cross-axis band
    ];
    assert.equal(detectWrapping(container as any, children as any, ROW), true);
  });

  it('is true for a multi-line grid', () => {
    const container = new El(rect(0, 0, 200, 200), { display: 'grid' });
    const children = [
      new El(rect(0, 0, 90, 90)),
      new El(rect(100, 0, 90, 90)),
      new El(rect(0, 100, 90, 90)),
      new El(rect(100, 100, 90, 90)),
    ];
    assert.equal(detectWrapping(container as any, children as any, ROW), true);
  });
});
