/**
 * Tests for parallax.ts — pure DOM builders and ParallaxRuntime.
 *
 * Uses linkedom to provide a real DOM environment (document.createElement,
 * querySelector, style, attributes). getComputedStyle and window APIs are
 * mocked globally since linkedom has no layout engine.
 *
 * Each test drives the module through its public API and asserts on observable
 * DOM state (attributes, style values, child count, style-element presence),
 * NOT on internal implementation details.
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

// Expose linkedom's HTMLElement/Element so that `instanceof HTMLElement` checks
// inside parallax.ts (e.g. readParallaxStrength) work correctly in Node.
(globalThis as any).HTMLElement = (window as any).HTMLElement;
(globalThis as any).Element = (window as any).Element;

// getComputedStyle: reflect inline style properties (linkedom has no CSS engine)
(globalThis as any).getComputedStyle = (el: any) => {
  const style = el?.style ?? {};
  return new Proxy(style, {
    get(target, prop: string) {
      if (prop === 'getPropertyValue') return (p: string) => target.getPropertyValue?.(p) ?? '';
      return target[prop] ?? '';
    },
  });
};

// window extensions not provided by linkedom
window.matchMedia = (_query: string) => ({ matches: false } as any);
window.innerWidth = 1024;
window.innerHeight = 768;
window.requestAnimationFrame = (cb: FrameRequestCallback) => { setTimeout(cb as any, 0); return 1; };
window.cancelAnimationFrame = (id: number) => { clearTimeout(id as any); };

// ---------------------------------------------------------------------------
// Import module under test (after globals are set)
// ---------------------------------------------------------------------------

import {
  toParallaxBlock,
  fromParallaxBlock,
  isParallaxBlock,
  getParallaxBlockReason,
  rebuildParallaxBlock,
  ParallaxRuntime,
  DEFAULT_MECHANISM,
  DEFAULT_STRENGTH,
  DEFAULT_SCROLL_SOURCE,
  STRENGTH_VAR,
} from './parallax';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeImg(src = '/images/hero.jpg', alt = 'Hero image'): HTMLImageElement {
  const img = document.createElement('img') as unknown as HTMLImageElement;
  img.setAttribute('src', src);
  img.setAttribute('alt', alt);
  return img;
}

function makeImgWithParent(src = '/images/hero.jpg'): HTMLImageElement {
  const parent = document.createElement('div');
  const img = makeImg(src);
  parent.appendChild(img as any);
  return img;
}

// ---------------------------------------------------------------------------
// Block builders
// ---------------------------------------------------------------------------

describe('parallax — toParallaxBlock() block structure', () => {
  it('returns a div with data-parallax marker', () => {
    const img = makeImgWithParent();
    const block = toParallaxBlock(img);
    assert.ok(block, 'block should be created');
    assert.ok((block as any).hasAttribute('data-parallax'), 'must have data-parallax marker');
  });

  it('js-scroll (default) creates outer clip box + inner background layer', () => {
    const img = makeImgWithParent('/images/banner.jpg');
    const block = toParallaxBlock(img);

    // Outer box: overflow hidden, relative positioning, explicit display
    assert.equal((block as any).style.overflow, 'hidden', 'outer must clip overflow');
    assert.equal((block as any).style.position, 'relative', 'outer must be relative');

    // Inner layer must exist with data-parallax-inner
    const inner = (block as any).querySelector('[data-parallax-inner]');
    assert.ok(inner, 'inner background layer must be created');
    assert.ok(
      (inner as any).style.backgroundImage.includes('banner.jpg'),
      'inner must have the background-image set to the source image',
    );
  });

  it('preserves src and alt from the original image', () => {
    const img = makeImgWithParent('/images/photo.jpg');
    img.setAttribute('alt', 'A photo');
    const block = toParallaxBlock(img);
    assert.equal((block as any).getAttribute('data-parallax-src'), '/images/photo.jpg');
    assert.equal((block as any).getAttribute('data-parallax-alt'), 'A photo');
  });

  it('sets data-parallax-type to the requested mechanism', () => {
    const img = makeImgWithParent();
    assert.equal((toParallaxBlock(img, 'fixed') as any).getAttribute('data-parallax-type'), 'fixed');
    assert.equal((toParallaxBlock(img, 'transform-3d') as any).getAttribute('data-parallax-type'), 'transform-3d');
    assert.equal((toParallaxBlock(img, 'scroll-driven') as any).getAttribute('data-parallax-type'), 'scroll-driven');
    assert.equal((toParallaxBlock(img, 'js-scroll') as any).getAttribute('data-parallax-type'), 'js-scroll');
  });

  it('sets a non-empty data-parallax-id on every block', () => {
    const img = makeImgWithParent();
    const id = (toParallaxBlock(img) as any).getAttribute('data-parallax-id');
    assert.ok(id && id.length > 0, 'data-parallax-id must be a non-empty string');
  });

  it('sets --parallax-strength custom property with the given strength', () => {
    const img = makeImgWithParent();
    const block = toParallaxBlock(img, DEFAULT_MECHANISM, 0.7) as any;
    const val = block.style.getPropertyValue(STRENGTH_VAR);
    assert.ok(val.includes('0.7'), `--parallax-strength must reflect strength 0.7, got "${val}"`);
  });

  // Regression lock (SE: display='' bug): block containers must have an explicit
  // display value, never the empty string that clears the inline style and falls
  // back to the browser default (which could destroy flex/grid layouts in callers).
  it('regression lock: outer div style.display is never the empty string on any mechanism', () => {
    const mechanisms = ['fixed', 'transform-3d', 'scroll-driven', 'js-scroll'] as const;
    for (const mech of mechanisms) {
      const img = makeImgWithParent();
      const block = toParallaxBlock(img, mech) as any;
      assert.notEqual(
        block.style.display,
        '',
        `style.display must not be '' for mechanism "${mech}" — ` +
        `that would clear the inline style and revert to CSS default, potentially breaking layout`,
      );
    }
  });
});

// ---------------------------------------------------------------------------
// Block revert
// ---------------------------------------------------------------------------

describe('parallax — fromParallaxBlock() restores the original image', () => {
  it('returns an <img> with the stored src and alt', () => {
    const img = makeImgWithParent('/images/orig.jpg');
    img.setAttribute('alt', 'Original');
    const block = toParallaxBlock(img) as unknown as HTMLElement;
    const restored = fromParallaxBlock(block) as unknown as HTMLImageElement;

    assert.equal((restored as any).tagName.toLowerCase(), 'img');
    assert.equal((restored as any).getAttribute('src'), '/images/orig.jpg');
    assert.equal((restored as any).getAttribute('alt'), 'Original');
  });

  it('does not carry data-parallax markers on the restored image', () => {
    const img = makeImgWithParent();
    const block = toParallaxBlock(img) as unknown as HTMLElement;
    const restored = fromParallaxBlock(block);
    assert.equal(
      (restored as any).hasAttribute('data-parallax'),
      false,
      'restored image must not carry the parallax marker',
    );
  });
});

// ---------------------------------------------------------------------------
// Guards
// ---------------------------------------------------------------------------

describe('parallax — isParallaxBlock() and getParallaxBlockReason()', () => {
  it('isParallaxBlock: true for a constructed block, false for a plain element', () => {
    const img = makeImgWithParent();
    const block = toParallaxBlock(img);
    assert.equal(isParallaxBlock(block as unknown as Element), true);
    assert.equal(isParallaxBlock(document.createElement('div') as unknown as Element), false);
  });

  it('getParallaxBlockReason: null for an <img> with src and a parent', () => {
    const img = makeImgWithParent('/images/hero.jpg');
    assert.equal(getParallaxBlockReason(img as unknown as Element), null);
  });

  it('getParallaxBlockReason: reason when element is not an <img>', () => {
    const div = document.createElement('div');
    const parent = document.createElement('div');
    parent.appendChild(div as any);
    const reason = getParallaxBlockReason(div as unknown as Element);
    assert.ok(reason && reason.length > 0, 'should return a reason for non-img');
    assert.ok(reason.toLowerCase().includes('image') || reason.toLowerCase().includes('img'));
  });

  it('getParallaxBlockReason: reason when img has no src', () => {
    const img = document.createElement('img') as unknown as HTMLImageElement;
    const parent = document.createElement('div');
    parent.appendChild(img as any);
    const reason = getParallaxBlockReason(img as unknown as Element);
    assert.ok(reason, 'should return a reason for img without src');
    assert.ok(reason!.toLowerCase().includes('source') || reason!.toLowerCase().includes('src'));
  });

  it('getParallaxBlockReason: null for an existing parallax block (can be reverted)', () => {
    const img = makeImgWithParent();
    const block = toParallaxBlock(img);
    assert.equal(getParallaxBlockReason(block as unknown as Element), null);
  });
});

// ---------------------------------------------------------------------------
// rebuildParallaxBlock
// ---------------------------------------------------------------------------

describe('parallax — rebuildParallaxBlock() preserves banner height', () => {
  it('copies a custom height from the old block to the rebuilt block', () => {
    const img = makeImgWithParent();
    const block = toParallaxBlock(img) as unknown as HTMLElement;
    (block as any).style.height = '600px';
    const rebuilt = rebuildParallaxBlock(block, 'fixed', 0.5) as any;
    assert.equal(rebuilt.style.height, '600px', 'custom height must survive a mechanism switch');
  });
});

// ---------------------------------------------------------------------------
// ParallaxRuntime — inject and remove stylesheet artifacts
// ---------------------------------------------------------------------------

describe('ParallaxRuntime — inject and teardown style elements', () => {
  it('applyLive(scroll-driven block) injects a <style> element into document.head', () => {
    const runtime = new ParallaxRuntime();
    const img = makeImgWithParent();
    const block = toParallaxBlock(img, 'scroll-driven', 0.3) as unknown as HTMLElement;
    document.body.appendChild(block as any);

    const stylesBefore = (document.head as any).querySelectorAll('style[data-parallax-style-for]').length;
    runtime.applyLive(block);
    const stylesAfter = (document.head as any).querySelectorAll('style[data-parallax-style-for]').length;

    assert.ok(stylesAfter > stylesBefore, 'applyLive must inject a style element for scroll-driven');

    // teardown must remove it
    const id = block.getAttribute('data-parallax-id')!;
    runtime.teardown(id);
    const stylesPost = (document.head as any).querySelectorAll('style[data-parallax-style-for]').length;
    assert.equal(stylesPost, stylesBefore, 'teardown must remove the injected style element');

    (block as any).remove();
  });

  it('destroy() removes all injected style elements', () => {
    const runtime = new ParallaxRuntime();
    const styleAttr = 'data-parallax-style-for';

    // Create two scroll-driven blocks
    const block1 = toParallaxBlock(makeImgWithParent(), 'scroll-driven') as unknown as HTMLElement;
    const block2 = toParallaxBlock(makeImgWithParent(), 'transform-3d') as unknown as HTMLElement;
    document.body.appendChild(block1 as any);
    document.body.appendChild(block2 as any);

    runtime.applyLive(block1);
    runtime.applyLive(block2);

    const countAfterApply = (document.head as any).querySelectorAll(`style[${styleAttr}]`).length;
    assert.ok(countAfterApply >= 2, 'both blocks must have injected style elements');

    runtime.destroy();

    const countAfterDestroy = (document.head as any).querySelectorAll(`style[${styleAttr}]`).length;
    assert.equal(countAfterDestroy, 0, 'destroy() must remove all injected style elements');

    (block1 as any).remove();
    (block2 as any).remove();
  });

  it('sync() tears down artifacts for blocks removed from the DOM', () => {
    const runtime = new ParallaxRuntime();
    const styleAttr = 'data-parallax-style-for';

    const block = toParallaxBlock(makeImgWithParent(), 'scroll-driven') as unknown as HTMLElement;
    document.body.appendChild(block as any);
    runtime.applyLive(block);

    const countBefore = (document.head as any).querySelectorAll(`style[${styleAttr}]`).length;
    assert.ok(countBefore > 0);

    // Remove the block from the DOM, then sync()
    (block as any).remove();
    runtime.sync();

    const countAfter = (document.head as any).querySelectorAll(`style[${styleAttr}]`).length;
    assert.equal(countAfter, 0, 'sync() must teardown artifacts for removed blocks');
  });
});
