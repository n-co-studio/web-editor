/**
 * Tests for handles.ts — getDimensionBlockReason() guard function.
 *
 * Uses linkedom for a real DOM and a mocked getComputedStyle that reflects
 * inline style properties (linkedom has no layout engine). The full
 * DragHandleManager class requires a live ShadowRoot and layout geometry
 * that are not available in Node; it is deferred (see bottom of file).
 *
 * What each test proves:
 *  - A normal block-level element in a non-grid, non-flex parent is not blocked.
 *  - An element in a grid parent is blocked (size controlled by grid).
 *  - A flex child with flex-grow set is blocked (size controlled by flexbox).
 *  - An inline element is blocked (inline elements cannot be resized).
 *  - An element using calc() dimensions is blocked (resize in code instead).
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { parseHTML } from 'linkedom';

// ---------------------------------------------------------------------------
// linkedom DOM environment
// ---------------------------------------------------------------------------

const { document } = parseHTML(
  '<!DOCTYPE html><html><head></head><body></body></html>',
);
(globalThis as any).document = document;

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
// Import module under test (getDimensionBlockReason only)
// ---------------------------------------------------------------------------

import { getDimensionBlockReason } from './handles';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeEl(display = 'block'): HTMLElement {
  const el = document.createElement('div') as unknown as HTMLElement;
  (el as any).style.display = display;
  return el;
}

function inParent(
  el: HTMLElement,
  parentDisplay = 'block',
): HTMLElement {
  const parent = document.createElement('div') as unknown as HTMLElement;
  (parent as any).style.display = parentDisplay;
  (parent as any).appendChild(el);
  return el;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('handles — getDimensionBlockReason()', () => {
  it('returns null for a block element in a plain block parent', () => {
    const el = inParent(makeEl('block'), 'block');
    assert.equal(getDimensionBlockReason(el as unknown as Element), null);
  });

  it('returns a reason when the parent is a grid container', () => {
    const el = inParent(makeEl('block'), 'grid');
    const reason = getDimensionBlockReason(el as unknown as Element);
    assert.ok(reason, 'must return a reason for grid children');
    assert.ok(
      reason!.toLowerCase().includes('grid'),
      `reason must mention grid, got: "${reason}"`,
    );
  });

  it('returns a reason when element has flex-grow set in a flex parent', () => {
    const parent = document.createElement('div') as unknown as HTMLElement;
    (parent as any).style.display = 'flex';
    const el = document.createElement('div') as unknown as HTMLElement;
    (el as any).style.display = 'block';
    (el as any).style.flexGrow = '1'; // flex-grow !== '0' → controlled by flex
    (parent as any).appendChild(el);

    const reason = getDimensionBlockReason(el as unknown as Element);
    assert.ok(reason, 'must return a reason when flex-grow is set');
    assert.ok(
      reason!.toLowerCase().includes('flex'),
      `reason must mention flex, got: "${reason}"`,
    );
  });

  it('returns a reason for an inline element', () => {
    const el = inParent(makeEl('inline'), 'block');
    const reason = getDimensionBlockReason(el as unknown as Element);
    assert.ok(reason, 'must return a reason for inline elements');
    assert.ok(
      reason!.toLowerCase().includes('inline'),
      `reason must mention inline, got: "${reason}"`,
    );
  });

  it('returns a reason when width uses calc()', () => {
    const el = inParent(makeEl('block'), 'block');
    (el as any).style.width = 'calc(100% - 20px)';
    const reason = getDimensionBlockReason(el as unknown as Element);
    assert.ok(reason, 'must return a reason when width uses calc()');
    assert.ok(
      reason!.toLowerCase().includes('calc'),
      `reason must mention calc, got: "${reason}"`,
    );
  });

  it('returns null for a flex child with flex-grow=0 and flex-basis=auto', () => {
    const parent = document.createElement('div') as unknown as HTMLElement;
    (parent as any).style.display = 'flex';
    const el = document.createElement('div') as unknown as HTMLElement;
    (el as any).style.display = 'block';
    (el as any).style.flexGrow = '0';
    (el as any).style.flexBasis = 'auto';
    (parent as any).appendChild(el);
    // flex-grow=0 + flex-basis=auto → not layout-controlled by flex
    assert.equal(getDimensionBlockReason(el as unknown as Element), null);
  });
});

// ---------------------------------------------------------------------------
// DragHandleManager — deferred
//
// DragHandleManager requires a live ShadowRoot (unavailable in linkedom) and
// relies on getBoundingClientRect() geometry for positioning handles. Testing
// its render() / hideHandles() cycle would require a full browser layout
// engine. This is recorded as deferred rather than skipped to make the
// escalation explicit.
// ---------------------------------------------------------------------------
