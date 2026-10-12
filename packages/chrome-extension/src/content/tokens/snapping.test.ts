import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';

import { isColorValue } from './snapping';

// ---------------------------------------------------------------------------
// isColorValue keeps mis-categorised tokens out of the colour swatch grid.
//
// The bug it exists for: an easing token
// (`ease-link: cubic-bezier(0, 0.56, 0.26, 0.88)`) arrived with
// `category: 'colors'`, rendered as a swatch with no visible fill, and clicking
// it queued a diff the CSSOM had already silently discarded. So the reject
// cases matter as much as the accepts — but over-rejecting empties a grid the
// user depends on, so the accepts are the ones that must not regress.
//
// Node has no `CSS`, so these tests install a stub that mirrors Chrome's
// behaviour for the values under test. The real implementation defers to the
// browser's own parser precisely so it keeps up with colour syntax this file
// does not enumerate.
// ---------------------------------------------------------------------------

const COLOR_LIKE =
  /^(#[0-9a-f]{3,8}|(rgb|rgba|hsl|hsla|hwb|lab|lch|oklab|oklch|color|color-mix)\(|var\(|transparent$|currentcolor$|[a-z]+$)/i;

const NAMED = new Set([
  'red', 'blue', 'rebeccapurple', 'transparent', 'currentcolor', 'inherit',
]);

declare global {
  // eslint-disable-next-line no-var
  var CSS: { supports(property: string, value: string): boolean } | undefined;
}

let hadCSS = false;
let originalCSS: typeof globalThis.CSS;

before(() => {
  hadCSS = typeof globalThis.CSS !== 'undefined';
  originalCSS = globalThis.CSS;
  globalThis.CSS = {
    supports(property: string, value: string): boolean {
      if (property !== 'color') return false;
      const v = value.trim().toLowerCase();
      if (!COLOR_LIKE.test(v)) return false;
      // A bare word is only a colour if it is a known keyword — this is what
      // rejects `cubic-bezier`-style garbage that happens to match \w+.
      if (/^[a-z-]+$/.test(v)) return NAMED.has(v);
      return true;
    },
  };
});

after(() => {
  if (hadCSS) globalThis.CSS = originalCSS;
  else delete (globalThis as { CSS?: unknown }).CSS;
});

describe('isColorValue', () => {
  it('accepts the colour formats a design system actually ships', () => {
    for (const v of [
      '#fff',
      '#06b6d4',
      '#ffffffcc',
      'rgb(15, 15, 15)',
      'rgba(0, 0, 0, 0.5)',
      'hsl(190 95% 39%)',
      'oklch(70% 0.1 200)',
      'color-mix(in srgb, red 50%, blue)',
      'transparent',
      'rebeccapurple',
    ]) {
      assert.equal(isColorValue(v), true, `expected ${v} to be accepted`);
    }
  });

  it('accepts var() references rather than resolving them', () => {
    // The value is valid CSS; what it resolves to is the page's business.
    // Rejecting these would empty the grid for any token set built on vars.
    assert.equal(isColorValue('var(--fe-primary)'), true);
    assert.equal(isColorValue('var(--brand, #fff)'), true);
  });

  it('rejects the mis-categorised token that caused the bug', () => {
    assert.equal(isColorValue('cubic-bezier(0, 0.56, 0.26, 0.88)'), false);
  });

  it('rejects other non-colour token values that can be mis-categorised', () => {
    for (const v of [
      '1.5rem',
      '200ms',
      'ease-in-out',
      '0 4px 6px rgba(0,0,0,0.07)',
      'Inter, system-ui, sans-serif',
      '600',
    ]) {
      assert.equal(isColorValue(v), false, `expected ${v} to be rejected`);
    }
  });

  it('rejects empty and whitespace-only values', () => {
    for (const v of ['', '   ', '\t']) {
      assert.equal(isColorValue(v), false, `expected ${JSON.stringify(v)} to be rejected`);
    }
  });

  it('tolerates surrounding whitespace on an otherwise valid colour', () => {
    assert.equal(isColorValue('  #fff  '), true);
  });

  it('accepts everything when CSS.supports is unavailable', () => {
    // Degrading to accept keeps the grid populated in a non-browser context
    // rather than silently emptying it — a wrong swatch is recoverable, a
    // blank panel is not.
    const saved = globalThis.CSS;
    delete (globalThis as { CSS?: unknown }).CSS;
    try {
      assert.equal(isColorValue('cubic-bezier(0, 0.56, 0.26, 0.88)'), true);
      assert.equal(isColorValue(''), false, 'empty is still rejected without CSS');
    } finally {
      globalThis.CSS = saved;
    }
  });
});
