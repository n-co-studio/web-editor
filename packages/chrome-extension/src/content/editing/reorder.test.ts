/**
 * Tests for reorder.ts — getReorderBlockReason() guard function.
 *
 * Uses linkedom for a real DOM and a mocked getComputedStyle that reflects
 * inline style properties (linkedom has no layout engine). globalThis.HTMLElement
 * is set from the linkedom window so that `instanceof HTMLElement` filters inside
 * the module under test work correctly.
 *
 * What each test proves:
 *  - An element in a parent with an explicit data-fe-layout signal is not blocked.
 *  - An orphan element (no parent) is blocked.
 *  - A block-display parent (no signal) is blocked.
 *  - A positioned element (position:absolute) is blocked regardless of the parent.
 *  - A flex-parent single-child is blocked ("only child — nothing to reorder").
 *  - A flex-parent multi-child without a data-fe-layout signal and non-homogeneous
 *    children is blocked ("Container is not an editable list").
 *
 * Mutation check: removing the `parseLayoutSignal(parent) === null` guard or the
 * position check from getReorderBlockReason makes the corresponding test fail.
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { parseHTML } from 'linkedom';

// ---------------------------------------------------------------------------
// linkedom DOM environment
// ---------------------------------------------------------------------------

const { window, document } = parseHTML(
  '<!DOCTYPE html><html><head></head><body></body></html>',
);

(globalThis as any).document = document;
(globalThis as any).window = window;

// Expose linkedom's HTMLElement so that `instanceof HTMLElement` checks inside
// the module under test (reorder.ts child-count filter) work correctly.
(globalThis as any).HTMLElement = (window as any).HTMLElement;
(globalThis as any).Element = (window as any).Element;

// getComputedStyle: reflect inline style properties via a simple proxy
(globalThis as any).getComputedStyle = (el: any) => {
  const style = el?.style ?? {};
  return new Proxy(style, {
    get(target, prop: string) {
      if (prop === 'getPropertyValue') return (p: string) => target.getPropertyValue?.(p) ?? '';
      return target[prop] ?? '';
    },
  });
};

// ---------------------------------------------------------------------------
// Import module under test (getReorderBlockReason only)
// ---------------------------------------------------------------------------

import { getReorderBlockReason } from './reorder';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeEl(tag = 'div'): HTMLElement {
  return document.createElement(tag) as unknown as HTMLElement;
}

function inParent(el: HTMLElement, parentDisplay = 'block'): HTMLElement {
  const parent = document.createElement('div') as unknown as HTMLElement;
  (parent as any).style.display = parentDisplay;
  (parent as any).appendChild(el);
  return el;
}

function inParentWith(
  el: HTMLElement,
  { display = 'block', signal }: { display?: string; signal?: string },
): HTMLElement {
  const parent = document.createElement('div') as unknown as HTMLElement;
  (parent as any).style.display = display;
  if (signal) (parent as any).setAttribute('data-fe-layout', signal);
  (parent as any).appendChild(el);
  return el;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('reorder — getReorderBlockReason()', () => {
  it('returns null when parent has an explicit data-fe-layout signal', () => {
    // Explicit data-fe-layout='flex' makes parseLayoutSignal return non-null
    // (the explicit path in layout.ts), so reorder is allowed.
    const el = makeEl();
    inParentWith(el, { display: 'flex', signal: 'flex' });
    assert.equal(getReorderBlockReason(el as unknown as Element), null);
  });

  it('returns "no parent" reason for an orphan element', () => {
    const el = makeEl();
    // el has no parent — parentElement is null
    const reason = getReorderBlockReason(el as unknown as Element);
    assert.ok(reason, 'must return a reason for an orphan element');
    assert.ok(
      reason!.toLowerCase().includes('parent'),
      `reason must mention parent, got: "${reason}"`,
    );
  });

  it('returns reason when the parent is a non-flex/grid container (no signal)', () => {
    const el = makeEl();
    inParent(el, 'block'); // display:block, no data-fe-layout
    const reason = getReorderBlockReason(el as unknown as Element);
    assert.ok(reason, 'must return a reason for a block parent without signal');
    assert.ok(
      reason!.toLowerCase().includes('flex') || reason!.toLowerCase().includes('grid'),
      `reason must mention flex or grid, got: "${reason}"`,
    );
  });

  it('returns reason for a positioned (absolute) element — out of normal flow', () => {
    // classifyLayoutRole checks getComputedStyle(el).position; our mock reads
    // inline styles, so setting style.position = 'absolute' triggers the guard.
    const el = makeEl();
    (el as any).style.position = 'absolute';
    inParentWith(el, { display: 'flex', signal: 'flex' });
    const reason = getReorderBlockReason(el as unknown as Element);
    assert.ok(reason, 'must return a reason for a positioned element');
    assert.ok(
      reason!.toLowerCase().includes('position') || reason!.toLowerCase().includes('flow'),
      `reason must mention position or flow, got: "${reason}"`,
    );
  });

  it('returns "only child" reason in a flex parent with a single child (no signal)', () => {
    // parent is flex, no data-fe-layout → heuristic path in parseLayoutSignal
    // fails (< MIN_EDITABLE_LIST_CHILDREN = 2) → returns null → enters the if-block;
    // display is flex (passes flex check); childCount = 1 → "only child" reason.
    const parent = document.createElement('div') as unknown as HTMLElement;
    (parent as any).style.display = 'flex';
    const el = makeEl();
    (parent as any).appendChild(el);

    const reason = getReorderBlockReason(el as unknown as Element);
    assert.ok(reason, 'must return a reason for a single-child flex parent');
    assert.ok(
      reason!.toLowerCase().includes('child') || reason!.toLowerCase().includes('only'),
      `reason must mention child or only, got: "${reason}"`,
    );
  });

  it('returns "not an editable list" reason for non-homogeneous flex children (no signal)', () => {
    // parent is flex, 2+ children with different tagNames → homogeneity fails →
    // parseLayoutSignal heuristic returns null → "Container is not an editable list".
    const parent = document.createElement('div') as unknown as HTMLElement;
    (parent as any).style.display = 'flex';
    const el = makeEl('div');
    const sibling = makeEl('span'); // different tagName → not homogeneous
    (parent as any).appendChild(el);
    (parent as any).appendChild(sibling);

    const reason = getReorderBlockReason(el as unknown as Element);
    assert.ok(reason, 'must return a reason for non-homogeneous flex children');
    assert.ok(
      reason!.toLowerCase().includes('editable') || reason!.toLowerCase().includes('list') ||
      reason!.toLowerCase().includes('incidental'),
      `reason must mention editable list or incidental, got: "${reason}"`,
    );
  });
});

// ---------------------------------------------------------------------------
// ReorderEditor — deferred
//
// ReorderEditor requires a live ShadowRoot (unavailable in linkedom), pointer
// events, and getBoundingClientRect() geometry for gap-math and drop-indicator
// positioning. Testing its drag-session lifecycle would require a full browser
// layout engine. This is recorded as deferred rather than skipped to make the
// escalation explicit.
// ---------------------------------------------------------------------------
