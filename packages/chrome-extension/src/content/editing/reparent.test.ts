/**
 * Tests for reparent.ts — getReparentBlockReason() guard function.
 *
 * Uses linkedom for a real DOM. getComputedStyle is mocked to reflect inline
 * style properties since linkedom has no layout engine.
 *
 * What each test proves:
 *  - A normal element with a parent is not blocked.
 *  - An orphan element (no parent) is blocked.
 *  - An <html> element is blocked (cannot reparent structural root elements).
 *  - A <body> element is blocked (cannot reparent structural root elements).
 *
 * Mutation check: removing the tagName guard from getReparentBlockReason makes
 * the html/body tests fail. Removing the parentElement check makes the orphan
 * test fail.
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
// Import module under test (getReparentBlockReason only)
// ---------------------------------------------------------------------------

import { getReparentBlockReason } from './reparent';

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('reparent — getReparentBlockReason()', () => {
  it('returns null for a normal element with a parent', () => {
    const parent = document.createElement('div');
    const el = document.createElement('div');
    parent.appendChild(el as any);
    assert.equal(getReparentBlockReason(el as unknown as Element), null);
  });

  it('returns a reason for an orphan element (no parent)', () => {
    const el = document.createElement('div');
    // el has no parent — parentElement is null
    const reason = getReparentBlockReason(el as unknown as Element);
    assert.ok(reason, 'must return a reason for an orphan element');
    assert.ok(
      reason!.toLowerCase().includes('parent'),
      `reason must mention parent, got: "${reason}"`,
    );
  });

  it('returns a reason for an <html> element', () => {
    // createElement('html') produces tagName='HTML'; tagName.toLowerCase()='html'.
    // Needs a parent so the tagName check is reached.
    const grandparent = document.createElement('div');
    const el = document.createElement('html');
    grandparent.appendChild(el as any);

    const reason = getReparentBlockReason(el as unknown as Element);
    assert.ok(reason, 'must return a reason for an <html> element');
    assert.ok(
      reason!.toLowerCase().includes('html') || reason!.toLowerCase().includes('body') ||
      reason!.toLowerCase().includes('reparent'),
      `reason must mention html/body or reparent, got: "${reason}"`,
    );
  });

  it('returns a reason for a <body> element', () => {
    const grandparent = document.createElement('div');
    const el = document.createElement('body');
    grandparent.appendChild(el as any);

    const reason = getReparentBlockReason(el as unknown as Element);
    assert.ok(reason, 'must return a reason for a <body> element');
    assert.ok(
      reason!.toLowerCase().includes('html') || reason!.toLowerCase().includes('body') ||
      reason!.toLowerCase().includes('reparent'),
      `reason must mention html/body or reparent, got: "${reason}"`,
    );
  });
});

// ---------------------------------------------------------------------------
// ReparentEditor — deferred
//
// ReparentEditor requires a live ShadowRoot (unavailable in linkedom), pointer
// events, getBoundingClientRect() geometry, and a running overlay scope.
// Testing its drag-session lifecycle (container discovery, drop-zone painting,
// moveBefore fallback) would require a full browser layout engine. This is
// recorded as deferred rather than skipped to make the escalation explicit.
// ---------------------------------------------------------------------------
