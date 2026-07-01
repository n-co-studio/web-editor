import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

// ---------------------------------------------------------------------------
// Minimal DOM double (mock convention, no jsdom) — just the surface the asset
// resolver + ElementInfo assembly touch, plus an inline `style` object so
// background-image resolution can be exercised.
// ---------------------------------------------------------------------------

class El {
  tagName: string;
  private _attrs = new Map<string, string>();
  childNodes: El[] = [];
  parent: El | null = null;
  style: { backgroundImage: string } = { backgroundImage: '' };
  private _text: string;

  constructor(tag: string, text = '') {
    this.tagName = tag.toUpperCase();
    this._text = text;
  }
  get id(): string { return this._attrs.get('id') ?? ''; }
  getAttribute(n: string): string | null { return this._attrs.has(n) ? this._attrs.get(n)! : null; }
  setAttribute(n: string, v: string): void { this._attrs.set(n, String(v)); }
  get attributes(): Array<{ name: string; value: string }> {
    return Array.from(this._attrs, ([name, value]) => ({ name, value }));
  }
  get children(): El[] { return this.childNodes; }
  get parentElement(): El | null { return this.parent; }
  get textContent(): string { return this._text; }
  getBoundingClientRect() {
    return { x: 0, y: 0, width: 10, height: 10, top: 0, right: 10, bottom: 10, left: 0 };
  }
  appendChild(node: El): El { node.parent = this; this.childNodes.push(node); return node; }
}

(globalThis as any).Element = El;
(globalThis as any).HTMLElement = El;
(globalThis as any).CSS = { escape: (s: string) => String(s) };

import {
  resolveElementAssetRef,
  buildElementInfo,
  buildSiblingAnchor,
  buildNoteElementRef,
} from './dom-utils';

const img = (src: string): El => { const e = new El('img'); e.setAttribute('src', src); return e; };

describe('resolveElementAssetRef (issue #29)', () => {
  it('resolves an <img> src to a served path + filename-stem label', () => {
    assert.deepEqual(resolveElementAssetRef(img('/images/hero.jpg') as unknown as Element), {
      assetPath: '/images/hero.jpg',
      label: 'hero',
    });
  });

  it('strips a single leading /public when a source-file context is present', () => {
    const e = img('/public/images/a.jpg');
    e.setAttribute('data-source-file', 'src/Gallery.tsx');
    e.setAttribute('data-source-line', '3');
    assert.equal(resolveElementAssetRef(e as unknown as Element).assetPath, '/images/a.jpg');
  });

  it('resolves an inline background-image url()', () => {
    const div = new El('div');
    div.style.backgroundImage = 'url("/images/bg.png")';
    assert.deepEqual(resolveElementAssetRef(div as unknown as Element), {
      assetPath: '/images/bg.png',
      label: 'bg',
    });
  });

  it('omits BOTH fields for a non-image element (absent, not empty)', () => {
    const ref = resolveElementAssetRef(new El('div', 'hello') as unknown as Element);
    assert.deepEqual(ref, {});
    assert.equal('assetPath' in ref, false);
    assert.equal('label' in ref, false);
  });

  it('never carries a data: URI as assetPath', () => {
    assert.deepEqual(resolveElementAssetRef(img('data:image/png;base64,AAAA') as unknown as Element), {});
  });

  it('never carries a blob: URI as assetPath', () => {
    assert.deepEqual(resolveElementAssetRef(img('blob:http://localhost/xyz') as unknown as Element), {});
  });

  it('falls back the label to alt when the path has no filename stem', () => {
    const e = img('/images/');
    e.setAttribute('alt', 'Company logo');
    assert.equal(resolveElementAssetRef(e as unknown as Element).label, 'Company logo');
  });
});

describe('ElementInfo / anchors carry the resolved asset ref (issue #29)', () => {
  it('buildElementInfo spreads assetPath + label for an image', () => {
    const info = buildElementInfo(img('/images/x.jpg') as unknown as Element);
    assert.equal(info.assetPath, '/images/x.jpg');
    assert.equal(info.label, 'x');
  });

  it('buildElementInfo omits assetPath/label for a non-image element', () => {
    const info = buildElementInfo(new El('div', 'hi') as unknown as Element);
    assert.equal('assetPath' in info, false);
    assert.equal('label' in info, false);
  });

  it('buildSiblingAnchor carries uid + assetPath for an image', () => {
    const a = buildSiblingAnchor(img('/images/s.jpg') as unknown as Element);
    assert.equal(a.assetPath, '/images/s.jpg');
    assert.ok(a.uid && a.uid.length > 0);
  });

  it('buildNoteElementRef carries assetPath for an image, omits for text', () => {
    assert.equal(buildNoteElementRef(img('/images/n.jpg') as unknown as Element).assetPath, '/images/n.jpg');
    assert.equal('assetPath' in buildNoteElementRef(new El('p', 'text') as unknown as Element), false);
  });
});
