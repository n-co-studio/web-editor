import { describe, it, before } from 'node:test';
import assert from 'node:assert/strict';

// ---------------------------------------------------------------------------
// Minimal DOM (no jsdom — matches the package's mock-based test convention).
// Implements just the surface the capture-layer modules touch: attributes,
// children, parent/nextSibling, deep cloneNode, querySelectorAll('*'),
// outerHTML serialization, getBoundingClientRect, textContent.
// ---------------------------------------------------------------------------

class El {
  tagName: string;
  private _attrs = new Map<string, string>();
  childNodes: El[] = [];
  parent: El | null = null;
  private _text: string;

  constructor(tag: string, text = '') {
    this.tagName = tag.toUpperCase();
    this._text = text;
  }

  get id(): string { return this._attrs.get('id') ?? ''; }
  getAttribute(n: string): string | null { return this._attrs.has(n) ? this._attrs.get(n)! : null; }
  setAttribute(n: string, v: string): void { this._attrs.set(n, String(v)); }
  removeAttribute(n: string): void { this._attrs.delete(n); }
  hasAttribute(n: string): boolean { return this._attrs.has(n); }
  get attributes(): Array<{ name: string; value: string }> {
    return Array.from(this._attrs, ([name, value]) => ({ name, value }));
  }
  get children(): El[] { return this.childNodes; }
  get parentElement(): El | null { return this.parent; }
  get nextSibling(): El | null {
    if (!this.parent) return null;
    const i = this.parent.childNodes.indexOf(this);
    return i >= 0 ? (this.parent.childNodes[i + 1] ?? null) : null;
  }
  get textContent(): string {
    return this._text + this.childNodes.map((c) => c.textContent).join('');
  }
  getBoundingClientRect() {
    return { x: 0, y: 0, width: 10, height: 10, top: 0, right: 10, bottom: 10, left: 0 };
  }
  appendChild(node: El): El { node.parent = this; this.childNodes.push(node); return node; }
  insertBefore(node: El, ref: El | null): El {
    node.parent = this;
    if (ref == null) { this.childNodes.push(node); return node; }
    const i = this.childNodes.indexOf(ref);
    if (i < 0) this.childNodes.push(node); else this.childNodes.splice(i, 0, node);
    return node;
  }
  cloneNode(deep: boolean): El {
    const c = new El(this.tagName, this._text);
    for (const [k, v] of this._attrs) c.setAttribute(k, v);
    if (deep) for (const ch of this.childNodes) c.appendChild(ch.cloneNode(true));
    return c; // detached — no parent
  }
  querySelectorAll(_sel: string): El[] {
    const out: El[] = [];
    const walk = (n: El): void => { for (const ch of n.childNodes) { out.push(ch); walk(ch); } };
    walk(this);
    return out;
  }
  get outerHTML(): string {
    const attrs = Array.from(this._attrs, ([k, v]) => ` ${k}="${v}"`).join('');
    const tag = this.tagName.toLowerCase();
    const inner = this._text + this.childNodes.map((c) => c.outerHTML).join('');
    return `<${tag}${attrs}>${inner}</${tag}>`;
  }
}

/**
 * `El` is a minimal stand-in implementing only the surface these functions
 * touch, so TypeScript rightly refuses it where a real `Element` is expected.
 * Cast at the call boundary rather than widening the stub to all 150-odd
 * Element members — the narrowness is the point of the stub.
 */
const asElement = (e: El): Element => e as unknown as Element;

// Install globals the modules-under-test read at call time.
(globalThis as any).Element = El;
(globalThis as any).HTMLElement = El;
(globalThis as any).CSS = { escape: (s: string) => String(s) };

// ---------------------------------------------------------------------------
// Imports (after globals so `instanceof HTMLElement` etc. resolve correctly).
// ---------------------------------------------------------------------------

import {
  generateSelector,
  buildElementInfo,
  resolvePublicSrc,
  ensureUid,
  readUid,
  disambiguateUids,
  FE_UID_ATTR,
} from '../../shared/dom-utils';
import { duplicateElement, regenerateUidsDeep } from './duplicate';
import { buildInsertChange, collectChildSnapshot } from './insert-source';

// Small helpers ------------------------------------------------------------

function withSource(el: El, file: string, line: number, uid?: string): El {
  el.setAttribute('data-source-file', file);
  el.setAttribute('data-source-line', String(line));
  if (uid) el.setAttribute(FE_UID_ATTR, uid);
  return el;
}

/** A figure>img subtree with build-time uids, mirroring a duplicated card. */
function makeFigure(file: string, figLine: number, imgLine: number, src: string): El {
  const fig = withSource(new El('figure'), file, figLine, `fe-build-fig-${figLine}`);
  const img = withSource(new El('img'), file, imgLine, `fe-build-img-${imgLine}`);
  img.setAttribute('src', src);
  fig.appendChild(img);
  return fig;
}

const isUidSelector = (s: string): boolean => s.startsWith(`[${FE_UID_ATTR}="`);

// ---------------------------------------------------------------------------

describe('stable element identity — capture layer (issue #27)', () => {
  before(() => {
    assert.equal(typeof (globalThis as any).crypto?.randomUUID, 'function',
      'crypto.randomUUID must be available for runtime uid minting');
  });

  it('generateSelector prefers [data-fe-uid] over data-source-* and #id', () => {
    const withUid = withSource(new El('div'), 'src/A.tsx', 3, 'fe-xyz');
    withUid.setAttribute('id', 'hero');
    assert.equal(generateSelector(asElement(withUid)), `[${FE_UID_ATTR}="fe-xyz"]`);

    const sourceOnly = withSource(new El('div'), 'src/A.tsx', 7);
    const sel = generateSelector(asElement(sourceOnly));
    assert.ok(sel.includes('data-source-file'), `expected data-source selector, got ${sel}`);
    assert.ok(!isUidSelector(sel));
  });

  it('resolvePublicSrc strips a single /public; leaves data:/http(s) untouched', () => {
    const base = 'src/Gallery.tsx';
    assert.equal(resolvePublicSrc('/public/images/a.jpg', base), '/images/a.jpg');
    assert.equal(resolvePublicSrc('/public', base), '/');
    // Only one leading segment stripped — a nested /public stays.
    assert.equal(resolvePublicSrc('/public/public/x.png', base), '/public/x.png');
    // Untouched cases.
    assert.equal(resolvePublicSrc('data:image/png;base64,AAAA', base), 'data:image/png;base64,AAAA');
    assert.equal(resolvePublicSrc('https://cdn.example.com/x.jpg', base), 'https://cdn.example.com/x.jpg');
    assert.equal(resolvePublicSrc('//cdn.example.com/x.jpg', base), '//cdn.example.com/x.jpg');
    assert.equal(resolvePublicSrc('/assets/x.jpg', base), '/assets/x.jpg');
    // Convention-gated: no project context → literal passthrough.
    assert.equal(resolvePublicSrc('/public/images/a.jpg', ''), '/public/images/a.jpg');
  });

  it('duplicateElement gives the clone (root + descendants) fresh uids; outerHTML carries them', () => {
    const container = withSource(new El('div'), 'src/Gallery.tsx', 10, 'fe-build-container');
    const fig = makeFigure('src/Gallery.tsx', 42, 43, '/public/images/a.jpg');
    container.appendChild(fig);

    const origFigUid = ensureUid(asElement(fig));
    const origImgUid = ensureUid(asElement(fig.childNodes[0]));

    const result = duplicateElement(fig as unknown as HTMLElement);
    const clone = result.clone as unknown as El;
    const cloneFigUid = readUid(asElement(clone))!;
    const cloneImgUid = readUid(asElement(clone.childNodes[0]))!;

    // Distinct identity for both twins, root and descendant.
    assert.notEqual(cloneFigUid, origFigUid);
    assert.notEqual(cloneImgUid, origImgUid);
    assert.notEqual(cloneFigUid, cloneImgUid);

    // outerHTML reflects the regenerated uids and never the origin's.
    assert.ok(result.outerHTML.includes(cloneFigUid));
    assert.ok(result.outerHTML.includes(cloneImgUid));
    assert.ok(!result.outerHTML.includes(origFigUid));
    assert.ok(!result.outerHTML.includes(origImgUid));

    // Inserted immediately after the original.
    assert.equal(container.childNodes.indexOf(clone), container.childNodes.indexOf(fig) + 1);
  });

  it('duplicate → edit clone src → reorder yields distinct uids + uid-keyed anchors/selectors', () => {
    // Container: [figure(original), trailing <p>]
    const container = withSource(new El('div'), 'src/Gallery.tsx', 10, 'fe-build-container2');
    const fig = makeFigure('src/Gallery.tsx', 42, 43, '/public/images/a.jpg');
    const tail = withSource(new El('p'), 'src/Gallery.tsx', 60, 'fe-build-tail');
    container.appendChild(fig);
    container.appendChild(tail);

    const insertIndex = container.childNodes.indexOf(fig) + 1;

    // Capture the InsertChange BEFORE the DOM mutation (mirrors index.ts).
    const baseChange = buildInsertChange(
      container as unknown as HTMLElement,
      insertIndex,
      'figure',
      [],
    );

    const origFigUid = readUid(asElement(fig))!; // stamped by buildInsertChange's anchor pass

    const result = duplicateElement(fig as unknown as HTMLElement);
    const clone = result.clone as unknown as El;
    const insertChange = { ...baseChange, outerHTML: result.outerHTML };

    // (1) Source-anchored insert keyed on the previous sibling (the original).
    assert.equal(insertChange.anchorUid, origFigUid);
    assert.equal(insertChange.anchorPosition, 'after');

    // (2) childSnapshot entries are per-instance distinct (no shared-line collision).
    const snapUids = (insertChange.childSnapshot ?? []).map((e) => e.uid);
    assert.equal(snapUids.length, 2);
    assert.ok(snapUids.every((u): u is string => typeof u === 'string' && u.length > 0));
    assert.equal(new Set(snapUids).size, snapUids.length, 'childSnapshot uids must be distinct');

    // (3) clone outerHTML carries fresh uids distinct from the original twin.
    const cloneFigUid = readUid(asElement(clone))!;
    assert.notEqual(cloneFigUid, origFigUid);
    assert.ok(insertChange.outerHTML!.includes(cloneFigUid));

    // (4) Edit the clone's src — deployment-aware capture, distinct identity.
    const cloneImg = clone.childNodes[0];
    const editInfo = buildElementInfo(cloneImg as unknown as Element);
    const origImgInfo = buildElementInfo(fig.childNodes[0] as unknown as Element);
    assert.notEqual(editInfo.uid, origImgInfo.uid, 'edited clone img must not collide with original');
    assert.equal(
      resolvePublicSrc(cloneImg.getAttribute('src')!, editInfo.sourceFile),
      '/images/a.jpg',
    );

    // (5) Reorder: sibling selectors are all uid-based and distinct per instance.
    const order = [...container.childNodes];
    const siblingSelectors = order.map((c) => {
      ensureUid(c as unknown as Element);
      return generateSelector(c as unknown as Element);
    });
    assert.ok(siblingSelectors.every(isUidSelector), `all selectors uid-based: ${siblingSelectors}`);
    assert.equal(new Set(siblingSelectors).size, siblingSelectors.length, 'selectors distinct per twin');
    // The two figure twins resolve to different selectors (the bug's core).
    const figSel = generateSelector(fig as unknown as Element);
    const cloneSel = generateSelector(clone as unknown as Element);
    assert.notEqual(figSel, cloneSel);
  });

  it('disambiguateUids re-stamps .map()-shared build-time uids so each instance is unique', () => {
    // Three list items sharing ONE build-time uid (one JSX node rendered x3).
    const list = withSource(new El('ul'), 'src/List.tsx', 5, 'fe-build-list');
    const shared = 'fe-build-item';
    for (let i = 0; i < 3; i++) {
      list.appendChild(withSource(new El('li'), 'src/List.tsx', 6, shared));
    }
    const restamped = disambiguateUids(list as unknown as ParentNode);
    assert.equal(restamped, 2, 'two of the three duplicates re-stamped');
    const uids = list.childNodes.map((c) => c.getAttribute(FE_UID_ATTR)!);
    assert.equal(new Set(uids).size, 3, 'all three list items now have distinct uids');
    assert.ok(uids.includes(shared), 'first occurrence keeps the build-time uid');
  });

  it('graceful degradation: an element with no data-source and no uid still produces a valid ElementInfo', () => {
    const orphan = new El('span', 'hi');
    const info = buildElementInfo(orphan as unknown as Element);
    assert.equal(info.sourceFile, ''); // no source hint
    assert.equal(info.sourceLine, 0);
    assert.ok(typeof info.uid === 'string' && info.uid.length > 0, 'lazy-minted uid present');
    assert.ok(info.selector.length > 0);
    // collectChildSnapshot tolerates unstamped containers without throwing.
    const box = new El('div');
    box.appendChild(orphan);
    const snap = collectChildSnapshot(box as unknown as HTMLElement);
    assert.equal(snap.length, 1);
    assert.ok(typeof snap[0].uid === 'string');
  });
});
